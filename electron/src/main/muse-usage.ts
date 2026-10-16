import { createHash } from 'node:crypto'
import { readFile, mkdir, writeFile, rename, rm } from 'node:fs/promises'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import type { MuseUsageState, UsageSnapshot, UsageWindow } from '../shared/types'
import { object, text } from './codex-parser'
import { MAX_CACHE_AGE, MIN_REFRESH_INTERVAL, POLL_INTERVAL, validSnapshot } from './codex-usage'

// Undocumented endpoint the Muse Code CLI itself calls with its device-code login (same one CodexBar uses).
// We reuse the CLI's access token (read-only, never cached or sent to the renderer) from
// ~/.config/muse/auth.json. The response also carries an inference key and payment info: only the
// plan, email and quota windows are read from it.
// ponytail: macOS keeps the token in the keychain (ai.meta.dev.credentials), not read here; add when macOS is validated.
const KEY_URL = 'https://api.meta.ai/muse-code/key'
const CACHE_VERSION = 1
export interface Credentials { accessToken: string; key: string }
type Fetcher = (token: string) => Promise<unknown>
interface Options {
  cachePath: string
  visible: () => boolean
  changed: (state: MuseUsageState) => void
  credentials?: () => Promise<Credentials | null>
  fetchJson?: Fetcher
  now?: () => number
}

export async function readCredentials(): Promise<Credentials | null> {
  try {
    const meta = object(object(object(JSON.parse(await readFile(join(homedir(), '.config', 'muse', 'auth.json'), 'utf8')))?.providers)?.meta)
    const accessToken = text(meta?.access_token)
    if (!accessToken) return null
    // The email outlives token rotation; only its hash is kept.
    return { accessToken, key: createHash('sha256').update(text(meta?.user_email) ?? accessToken).digest('hex') }
  } catch { return null }
}
async function fetchJson(token: string): Promise<unknown> {
  const response = await fetch(KEY_URL, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'x-api-version': '1.0.0' },
    body: '{}',
    redirect: 'error', // Never follow the token anywhere else.
    signal: AbortSignal.timeout(15_000),
  })
  if (!response.ok) throw new Error(response.status === 401 || response.status === 403
    ? 'Muse Code sign-in was rejected. Run muse login again, then refresh.'
    : response.status === 429 ? 'Muse Code is rate-limiting usage requests. Try again in a few minutes.'
      : `Muse Code usage request failed (HTTP ${response.status}).`)
  return response.json()
}
function usageWindow(id: string, label: string, minutes: number, raw: unknown): UsageWindow | null {
  const value = object(raw)
  const percent = value?.used_percent
  if (typeof percent !== 'number' || !Number.isFinite(percent)) return null // Missing data is not 0% usage.
  const usedPercent = Math.min(100, Math.max(0, percent))
  const reset = value?.resets_at
  return {
    id, label, usedPercent, durationMinutes: minutes,
    resetsAt: typeof reset === 'number' && reset > 0 ? reset * 1000 : null,
    severity: usedPercent >= 90 ? 'critical' : usedPercent >= 70 ? 'warning' : 'normal',
  }
}
export function parseMuseUsage(value: unknown): Pick<UsageSnapshot, 'email' | 'plan' | 'windows'> {
  const root = object(value)
  if (root?.require_payment === true) throw new Error('Muse Code needs a payment method. Finish billing at dev.meta.ai, then refresh.')
  if (root?.is_subs_active !== true) throw new Error('No Muse Code subscription is active on this login.')
  const email = text(root.user_email)
  const plan = text(root.subs_tier_name)?.replace(/^Muse Code\s+/i, '') ?? null
  const usage = object(root.subs_usage)
  // Meta omits the quota while the 5-hour window is idle, even if the weekly limit has usage:
  // the login is valid, there are just no numbers to show.
  if (!usage) return { email, plan, windows: [] }
  const duration = object(usage.window)?.window_duration_mins
  const minutes = typeof duration === 'number' && duration > 0 ? Math.round(duration) : 300
  const windows = [
    usageWindow('muse-session', minutes === 300 ? '5-hour session' : `${Math.round(minutes / 60)}-hour session`, minutes, usage.window),
    usageWindow('muse-weekly', 'Weekly limit', 10080, usage.weekly),
  ].filter(w => !!w)
  if (!windows.length) throw new Error('Muse Code has not returned valid usage limit data.')
  return { email, plan, windows }
}

export class MuseUsageService {
  state: MuseUsageState = { status: 'loading', snapshot: null, refreshing: false, message: null, nextRefreshAt: 0 }
  private options: Options
  private key: string | null = null
  private now: () => number
  private timer: ReturnType<typeof setInterval> | null = null
  private flight: Promise<MuseUsageState> | null = null
  private stopped = false
  constructor(options: Options) {
    this.options = options
    this.now = options.now ?? Date.now
  }
  private emit(): void { if (!this.stopped) this.options.changed({ ...this.state }) }
  private credentials() { return (this.options.credentials ?? readCredentials)() }
  async start(): Promise<void> {
    this.key = (await this.credentials())?.key ?? null
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
  refresh(): Promise<MuseUsageState> {
    if (this.flight) return this.flight
    if (this.stopped || this.now() < this.state.nextRefreshAt) return Promise.resolve(this.state)
    this.flight = this.fetch().finally(() => { this.flight = null })
    return this.flight
  }
  private async invalidate(): Promise<void> {
    this.state.snapshot = null
    await this.clearCache()
  }
  private async fetch(): Promise<MuseUsageState> {
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
        this.state.message = 'Run muse login, then refresh to see your Muse Code usage.'
        return this.state
      }
      const parsed = parseMuseUsage(await (this.options.fetchJson ?? fetchJson)(credentials.accessToken))
      this.state.snapshot = { ...parsed, credits: null, fetchedAt: this.now() }
      this.state.status = 'ready'
      if (parsed.windows.length) await this.saveCache(credentials.key, this.state.snapshot)
      else {
        this.state.message = 'Muse Code reports usage only while a 5-hour window is active. Send a prompt, then refresh.'
        await this.clearCache() // Old window numbers must not come back on relaunch.
      }
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
