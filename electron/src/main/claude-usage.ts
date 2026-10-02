import { createHash } from 'node:crypto'
import { readFile, mkdir, writeFile, rename, rm } from 'node:fs/promises'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import type { ClaudeUsageState, UsageSnapshot, UsageWindow } from '../shared/types'
import { object, text } from './codex-parser'
import { MAX_CACHE_AGE, MIN_REFRESH_INTERVAL, POLL_INTERVAL, validSnapshot } from './codex-usage'

// Undocumented OAuth endpoints that Claude Code itself calls; ported from
// windows/ClaudeUsage.cs. We reuse Claude Code's access token (read-only, never
// refreshed, cached or sent to the renderer) from ~/.claude/.credentials.json.
// ponytail: macOS keeps the token in the keychain, not read here; add when macOS is validated.
const USAGE_URL = 'https://api.anthropic.com/api/oauth/usage'
const PROFILE_URL = 'https://api.anthropic.com/api/oauth/profile'
const CACHE_VERSION = 1
export interface Credentials { accessToken: string; key: string }
type Fetcher = (url: string, token: string) => Promise<unknown>
interface Options {
  cachePath: string
  visible: () => boolean
  changed: (state: ClaudeUsageState) => void
  credentials?: () => Promise<Credentials | null>
  fetchJson?: Fetcher
  now?: () => number
}

export async function readCredentials(): Promise<Credentials | null> {
  try {
    const dir = process.env.CLAUDE_CONFIG_DIR?.trim() || join(homedir(), '.claude')
    const oauth = object(object(JSON.parse(await readFile(join(dir, '.credentials.json'), 'utf8')))?.claudeAiOauth)
    const accessToken = text(oauth?.accessToken)
    if (!accessToken) return null
    // The refresh token is stable across access-token rotation; only its hash is kept.
    return { accessToken, key: createHash('sha256').update(text(oauth?.refreshToken) ?? accessToken).digest('hex') }
  } catch { return null }
}
async function fetchJson(url: string, token: string): Promise<unknown> {
  const response = await fetch(url, {
    headers: { Authorization: `Bearer ${token}`, 'anthropic-beta': 'oauth-2025-04-20', 'anthropic-version': '2023-06-01' },
    signal: AbortSignal.timeout(15_000),
  })
  if (!response.ok) throw new Error(response.status === 429
    ? 'Claude is rate-limiting usage requests. Try again in a few minutes.'
    : `Claude usage request failed (HTTP ${response.status}).`)
  return response.json()
}
function usageWindow(id: string, label: string, minutes: number, percent: unknown, resetsAt: unknown, severity: unknown): UsageWindow | null {
  if (typeof percent !== 'number' || !Number.isFinite(percent)) return null // Missing data is not 0% usage.
  const usedPercent = Math.min(100, Math.max(0, percent))
  const reset = typeof resetsAt === 'string' ? Date.parse(resetsAt) : NaN
  return {
    id, label, usedPercent, durationMinutes: minutes, resetsAt: Number.isNaN(reset) ? null : reset,
    severity: severity === 'warning' || severity === 'critical' ? severity : usedPercent >= 90 ? 'critical' : usedPercent >= 70 ? 'warning' : 'normal',
  }
}
export function parseClaudeUsage(value: unknown): UsageWindow[] {
  const root = object(value)
  const limits = (Array.isArray(root?.limits) ? root.limits : []).map(object).filter(l => !!l)
  // Prefer the structured `limits` array (it carries severity); fall back to the flat windows.
  const pick = (limit: Record<string, unknown> | undefined, flat: unknown) => {
    const fallback = object(flat)
    return { percent: limit?.percent ?? fallback?.utilization, resetsAt: limit?.resets_at ?? fallback?.resets_at, severity: limit?.severity }
  }
  const session = pick(limits.find(l => l.kind === 'session' || l.group === 'session'), root?.five_hour)
  const weekly = pick(limits.find(l => l.kind === 'weekly_all' || (l.group === 'weekly' && !object(l.scope))), root?.seven_day)
  const windows = [
    usageWindow('claude-session', '5-hour session', 300, session.percent, session.resetsAt, session.severity),
    usageWindow('claude-weekly', 'Weekly limit', 10080, weekly.percent, weekly.resetsAt, weekly.severity),
  ]
  // Weekly limits scoped to one model carry the model's display name.
  for (const l of limits) {
    const name = text(object(object(l.scope)?.model)?.display_name)
    if (l.group === 'weekly' && name) windows.push(usageWindow(`claude-weekly-${name}`, `${name} · Weekly limit`, 10080, l.percent, l.resets_at, l.severity))
  }
  const result = windows.filter(w => !!w)
  if (!result.length) throw new Error('Claude has not returned valid usage limit data.')
  return result
}
export function parseClaudeProfile(value: unknown): { email: string | null; plan: string | null } {
  const root = object(value)
  const account = object(root?.account)
  const type = text(object(root?.organization)?.organization_type)
  const plan = type ? type.replace(/^claude_/, '').replace(/_/g, ' ')
    : account?.has_claude_max === true ? 'max' : account?.has_claude_pro === true ? 'pro' : null
  return { email: text(account?.email), plan: plan && plan[0].toUpperCase() + plan.slice(1).toLowerCase() }
}

export class ClaudeUsageService {
  state: ClaudeUsageState = { status: 'loading', snapshot: null, refreshing: false, message: null, nextRefreshAt: 0 }
  private options: Options
  private key: string | null = null
  private profile: { email: string | null; plan: string | null; token: string; at: number } | null = null
  private now: () => number
  private timer: ReturnType<typeof setInterval> | null = null
  private flight: Promise<ClaudeUsageState> | null = null
  private stopped = false
  constructor(options: Options) {
    this.options = options
    this.now = options.now ?? Date.now
  }
  private emit(): void { if (!this.stopped) this.options.changed({ ...this.state }) }
  private credentials() { return (this.options.credentials ?? readCredentials)() }
  async start(): Promise<void> {
    const credentials = await this.credentials()
    this.key = credentials?.key ?? null
    try {
      const cache = object(JSON.parse(await readFile(this.options.cachePath, 'utf8')))
      if (this.key && cache?.version === CACHE_VERSION && cache.accountKey === this.key && validSnapshot(cache.snapshot, this.now())) {
        this.state.snapshot = cache.snapshot as UsageSnapshot
        this.state.status = 'cached'
        this.emit()
      } else await this.clearCache()
    } catch { /* Cache is best-effort. */ }
    await this.refresh()
    if (!this.stopped) this.timer = setInterval(() => void this.tick(), POLL_INTERVAL)
  }
  async tick(): Promise<void> {
    // A hidden tray app does not hit the network just to poll usage.
    if (this.stopped || !this.options.visible()) return
    const snapshot = this.state.snapshot
    if (!snapshot || this.now() - snapshot.fetchedAt >= POLL_INTERVAL) await this.refresh()
  }
  refresh(): Promise<ClaudeUsageState> {
    if (this.flight) return this.flight
    if (this.stopped || this.now() < this.state.nextRefreshAt) return Promise.resolve(this.state)
    this.flight = this.fetch().finally(() => { this.flight = null })
    return this.flight
  }
  private async invalidate(): Promise<void> {
    this.state.snapshot = null
    this.profile = null
    await this.clearCache()
  }
  private async fetch(): Promise<ClaudeUsageState> {
    this.state.refreshing = true
    this.state.nextRefreshAt = this.now() + MIN_REFRESH_INTERVAL
    this.state.message = null
    this.emit()
    try {
      const credentials = await this.credentials()
      // Logout or account switch: never keep showing another account's numbers.
      if ((credentials?.key ?? null) !== this.key) { this.key = credentials?.key ?? null; await this.invalidate() }
      if (!credentials) {
        this.state.status = 'signed-out'
        this.state.message = 'Run claude and sign in with /login, then refresh to see your Claude usage.'
        return this.state
      }
      const get = this.options.fetchJson ?? fetchJson
      // Plan and email change rarely: refresh at most daily, or when the token rotates.
      if (!this.profile || this.profile.token !== credentials.accessToken || this.now() - this.profile.at >= MAX_CACHE_AGE) {
        try { this.profile = { ...parseClaudeProfile(await get(PROFILE_URL, credentials.accessToken)), token: credentials.accessToken, at: this.now() } }
        catch { /* Best-effort: keep the last known profile. */ }
      }
      const windows = parseClaudeUsage(await get(USAGE_URL, credentials.accessToken))
      this.state.snapshot = {
        email: this.profile?.email ?? null, plan: this.profile?.plan ?? null, windows, credits: null, fetchedAt: this.now(),
      }
      this.state.status = 'ready'
      await this.saveCache(credentials.key, this.state.snapshot)
    } catch (error) {
      if (this.state.snapshot && this.now() - this.state.snapshot.fetchedAt > MAX_CACHE_AGE) await this.invalidate()
      this.state.status = this.state.snapshot ? 'cached' : 'unavailable'
      this.state.message = error instanceof Error ? error.message : 'Usage could not be retrieved. Please try again later.'
    } finally {
      this.state.refreshing = false
      this.emit()
    }
    return this.state
  }
  private async saveCache(accountKey: string, snapshot: UsageSnapshot): Promise<void> {
    try {
      await mkdir(dirname(this.options.cachePath), { recursive: true })
      const tmp = `${this.options.cachePath}.tmp`
      // Email is display-only; do not persist it in the usage cache.
      await writeFile(tmp, JSON.stringify({ version: CACHE_VERSION, accountKey, snapshot: { ...snapshot, email: null } }), { mode: 0o600 })
      await rename(tmp, this.options.cachePath)
    } catch { /* Disk failure must not break live usage. */ }
  }
  private async clearCache(): Promise<void> {
    await Promise.all([this.options.cachePath, `${this.options.cachePath}.tmp`].map(path => rm(path, { force: true }).catch(() => {})))
  }
  stop(): void {
    this.stopped = true
    if (this.timer) clearInterval(this.timer)
  }
}
