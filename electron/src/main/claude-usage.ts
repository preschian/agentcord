import { execFile } from 'node:child_process'
import { existsSync } from 'node:fs'
import { readFile, readdir } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'
import type { UsageWindow } from '../shared/types'
import { object, text } from './codex-parser'
import { type Credentials, type ServiceOptions, TokenUsageService, hash, requestJson, severity as bySeverity } from './token-usage'

// Undocumented OAuth endpoints that Claude Code itself calls; ported from
// windows/ClaudeUsage.cs. We reuse Claude Code's access token (read-only, never
// cached or sent to the renderer) from ~/.claude/.credentials.json. When it expires we let
// the claude CLI renew it (`claude auth status`), so the rotating refresh token stays its own.
// ponytail: macOS keeps the token in the keychain, not read here; add when macOS is validated.
const USAGE_URL = 'https://api.anthropic.com/api/oauth/usage'
const PROFILE_URL = 'https://api.anthropic.com/api/oauth/profile'
// Claude Desktop authenticates Claude Code itself, so this file only renews when the `claude` CLI runs.
const EXPIRED = 'Claude Code sign-in has expired and could not be renewed. Run claude to sign in again, then refresh.'
type Fetcher = (url: string, token: string) => Promise<unknown>
interface Options extends ServiceOptions {
  credentials?: () => Promise<Credentials | null>
  fetchJson?: Fetcher
  renew?: () => Promise<void>
  desktop?: () => Promise<DesktopSample | null>
}

export async function readCredentials(): Promise<Credentials | null> {
  try {
    const dir = process.env.CLAUDE_CONFIG_DIR?.trim() || join(homedir(), '.claude')
    const oauth = object(object(JSON.parse(await readFile(join(dir, '.credentials.json'), 'utf8')))?.claudeAiOauth)
    const accessToken = text(oauth?.accessToken)
    if (!accessToken) return null
    // The refresh token is stable across access-token rotation; only its hash is kept.
    const expiresAt = typeof oauth?.expiresAt === 'number' ? oauth.expiresAt : undefined
    return { accessToken, expiresAt, key: hash(text(oauth?.refreshToken) ?? accessToken) }
  } catch { return null }
}
// Claude Desktop keeps its sign-in encrypted (never read here) but logs its own usage percentages
// next to it. Without a usable CLI login we show the latest of those, with no reset time.
// ponytail: percentages are as of the last sample; a 5-hour or weekly window that has since reset
// shows stale numbers until Desktop writes a new one, so samples older than the window are dropped.
export interface DesktopSample { at: number; org: string; fiveHour: unknown; weekly: unknown }
const HISTORY = 'plan-usage-history.json'
// The Store (MSIX) build moves its data out of %APPDATA%\Claude to %LOCALAPPDATA%\Claude-Data\claude_<publisher>.
async function desktopUsageFiles(): Promise<string[]> {
  if (process.platform === 'darwin') return [join(homedir(), 'Library', 'Application Support', 'Claude', HISTORY)]
  if (process.platform !== 'win32') return [join(process.env.XDG_CONFIG_HOME ?? join(homedir(), '.config'), 'Claude', HISTORY)]
  const files = [join(process.env.APPDATA ?? join(homedir(), 'AppData', 'Roaming'), 'Claude', HISTORY)]
  const moved = join(process.env.LOCALAPPDATA ?? join(homedir(), 'AppData', 'Local'), 'Claude-Data')
  const dirs = await readdir(moved).catch(() => [])
  return [...files, ...dirs.filter(d => d.startsWith('claude_')).map(d => join(moved, d, HISTORY))]
}
export function parseDesktopUsage(value: unknown): DesktopSample | null {
  const root = object(value)
  const last = object(Array.isArray(root?.samples) ? root.samples.at(-1) : null)
  const u = object(last?.u)
  if (typeof last?.t !== 'number' || !u) return null
  return { at: last.t, org: text(last.org) ?? 'desktop', fiveHour: u.fh, weekly: u.sd }
}
// Several installs can leave a history behind; the newest sample is the one in use.
export async function readDesktopUsage(): Promise<DesktopSample | null> {
  const samples = await Promise.all((await desktopUsageFiles()).map(async f => {
    try { return parseDesktopUsage(JSON.parse(await readFile(f, 'utf8'))) } catch { return null }
  }))
  return samples.reduce<DesktopSample | null>((a, s) => s && (!a || s.at > a.at) ? s : a, null)
}
export function desktopWindows(sample: DesktopSample | null, now: number): UsageWindow[] {
  const age = sample ? now - sample.at : Infinity
  const windows = [
    age < 300 * 60_000 ? usageWindow('claude-session', '5-hour session', 300, sample?.fiveHour, null, null) : null,
    age < 10080 * 60_000 ? usageWindow('claude-weekly', 'Weekly limit', 10080, sample?.weekly, null, null) : null,
  ].filter(w => !!w)
  if (!windows.length) throw new Error('Claude Desktop has not recorded recent usage. Use Claude Desktop, then refresh.')
  return windows
}
// `claude auth status` refreshes an expired token and writes it back; it starts no session or model call.
export function renewCredentials(): Promise<void> {
  const local = join(homedir(), '.local', 'bin', process.platform === 'win32' ? 'claude.exe' : 'claude')
  const exe = existsSync(local) ? local : 'claude'
  // shell on Windows so an npm `claude.cmd` on PATH resolves too; args are constant.
  return new Promise(resolve => execFile(exe, ['auth', 'status', '--json'],
    { timeout: 30_000, windowsHide: true, shell: exe === 'claude' && process.platform === 'win32' }, () => resolve()))
}
function fetchJson(url: string, token: string): Promise<unknown> {
  return requestJson('Claude', EXPIRED, url, {
    headers: { Authorization: `Bearer ${token}`, 'anthropic-beta': 'oauth-2025-04-20', 'anthropic-version': '2023-06-01' },
  })
}
function usageWindow(id: string, label: string, minutes: number, percent: unknown, resetsAt: unknown, severity: unknown): UsageWindow | null {
  if (typeof percent !== 'number' || !Number.isFinite(percent)) return null // Missing data is not 0% usage.
  const usedPercent = Math.min(100, Math.max(0, percent))
  const reset = typeof resetsAt === 'string' ? Date.parse(resetsAt) : NaN
  return {
    id, label, usedPercent, durationMinutes: minutes, resetsAt: Number.isNaN(reset) ? null : reset,
    severity: severity === 'warning' || severity === 'critical' ? severity : bySeverity(usedPercent),
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

export class ClaudeUsageService extends TokenUsageService {
  constructor(options: Options) {
    const get = options.fetchJson ?? fetchJson
    const cli = options.credentials ?? readCredentials
    const renew = options.renew ?? renewCredentials
    const desktop = options.desktop ?? readDesktopUsage
    const now = options.now ?? Date.now
    const stale = (c: Credentials) => c.expiresAt !== undefined && now() >= c.expiresAt
    let renewFailed = false // the CLI could not renew, so use Claude Desktop until it signs in again
    super(options, {
      credentials: async () => {
        const c = await cli()
        if (c && !stale(c)) { renewFailed = false; return c }
        if (c && !renewFailed) return c // expired: let the poller try renewing it first
        const sample = await desktop()
        return sample ? { accessToken: '', key: hash(`desktop:${sample.org}`) } : c
      },
      renew: async () => {
        await renew()
        const c = await cli()
        renewFailed = !!c && stale(c)
      },
      // An empty access token marks the Claude Desktop fallback: no network, no profile.
      profile: async c => c.accessToken ? parseClaudeProfile(await get(PROFILE_URL, c.accessToken)) : { email: null, plan: null },
      usage: async c => c.accessToken ? parseClaudeUsage(await get(USAGE_URL, c.accessToken)) : desktopWindows(await desktop(), now()),
      signedOut: 'Open Claude Desktop, or run claude and sign in with /login, then refresh to see your Claude usage.',
      expired: EXPIRED,
    })
  }
}
