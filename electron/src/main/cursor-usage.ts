import { readFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import type { UsageWindow } from '../shared/types'
import { object, text } from './codex-parser'
import { type Credentials, type ServiceOptions, TokenUsageService, hash, requestJson, usageWindow } from './token-usage'

// Undocumented endpoints the Cursor app itself calls; ported from windows/CursorUsage.cs.
// The token comes from the IDE's state.vscdb or the cursor-agent CLI's auth.json, whichever
// expires last. Cursor renews its own token; we only read it.
const API = 'https://api2.cursor.sh'
const EXPIRED = 'Cursor sign-in has expired. Open Cursor or run cursor-agent to renew it, then refresh.'
type Fetcher = (url: string, token: string, post: boolean) => Promise<unknown>
interface CursorCredentials extends Credentials { email: string | null; plan: string | null }

export function cursorDir(): string {
  const base = process.platform === 'win32' ? process.env.APPDATA || join(homedir(), 'AppData', 'Roaming')
    : process.platform === 'darwin' ? join(homedir(), 'Library', 'Application Support') : process.env.XDG_CONFIG_HOME || join(homedir(), '.config')
  return join(base, 'Cursor')
}
function jwtClaims(token: string) {
  try { return object(JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8'))) } catch { return undefined }
}
function credential(accessToken: string | null, email: string | null = null, plan: string | null = null): CursorCredentials | null {
  if (!accessToken) return null
  const claims = jwtClaims(accessToken)
  const exp = typeof claims?.exp === 'number' ? claims.exp * 1000 : undefined
  return { accessToken, expiresAt: exp, key: hash(text(claims?.sub) ?? accessToken), email, plan }
}
function readState(dir: string): CursorCredentials | null {
  try {
    const db = new DatabaseSync(join(dir, 'User', 'globalStorage', 'state.vscdb'), { readOnly: true })
    try {
      const get = db.prepare('SELECT value FROM ItemTable WHERE key = ?')
      const value = (key: string) => text(get.get(`cursorAuth/${key}`)?.value)
      return credential(value('accessToken'), value('cachedEmail'), value('stripeMembershipType'))
    } finally { db.close() }
  } catch { return null }
}
export async function readCursorCredentials(dir = cursorDir()): Promise<CursorCredentials | null> {
  let cli: CursorCredentials | null = null
  try { cli = credential(text(object(JSON.parse(await readFile(join(dir, 'auth.json'), 'utf8')))?.accessToken)) } catch { /* No CLI login. */ }
  const ide = readState(dir)
  if (!cli || !ide) return ide ?? cli
  return (ide.expiresAt ?? Infinity) >= (cli.expiresAt ?? Infinity) ? ide : { ...cli, email: ide.email, plan: ide.plan }
}
function fetchJson(url: string, token: string, post: boolean): Promise<unknown> {
  return requestJson('Cursor', EXPIRED, url, post
    ? { method: 'POST', body: '{}', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'Connect-Protocol-Version': '1' } }
    : { headers: { Authorization: `Bearer ${token}` } })
}

const percent = (value: unknown) => typeof value === 'number' && Number.isFinite(value) ? value : null
export function parseCursorPeriod(value: unknown): UsageWindow[] | null {
  const root = object(value)
  const plan = object(root?.planUsage)
  if (!plan) return null
  const limit = percent(plan.limit)
  const spend = percent(plan.includedSpend) ?? percent(plan.totalSpend)
  const total = percent(plan.totalPercentUsed) ?? (limit && spend !== null ? spend / limit * 100 : null)
  if (total === null) return null
  const end = Number(root?.billingCycleEnd)
  // Accept seconds or milliseconds.
  const resetsAt = Number.isFinite(end) && end > 0 ? (end > 1e12 ? end : end * 1000) : null
  const windows = [usageWindow('cursor-included', 'Included usage', total, resetsAt)]
  const auto = percent(plan.autoPercentUsed)
  if (auto && Math.round(auto) !== Math.round(total)) windows.push(usageWindow('cursor-auto', 'Auto', auto, resetsAt))
  const api = percent(plan.apiPercentUsed)
  if (api && Math.round(api) !== Math.round(total)) windows.push(usageWindow('cursor-api', 'API', api, resetsAt))
  const onDemand = object(root?.spendLimitUsage)
  const cap = percent(onDemand?.individualLimit)
  if (cap && cap > 0) {
    const remaining = percent(onDemand?.individualRemaining) ?? cap
    windows.push(usageWindow('cursor-on-demand', 'On-demand', Math.max(0, cap - remaining) / cap * 100, resetsAt))
  }
  return windows
}
/** Legacy request buckets (`gpt-4: { numRequests, maxRequestUsage }`); the largest bucket wins. */
export function parseCursorLegacy(value: unknown): UsageWindow[] | null {
  const root = object(value)
  let best: { used: number; max: number } | null = null
  for (const bucket of Object.values(root ?? {}).map(object)) {
    const max = percent(bucket?.maxRequestUsage)
    if (max && max > 0 && (!best || max > best.max)) best = { used: percent(bucket?.numRequests) ?? 0, max }
  }
  if (!best) return null
  const start = new Date(String(root?.startOfMonth))
  const resetsAt = Number.isNaN(start.getTime()) ? null : start.setUTCMonth(start.getUTCMonth() + 1)
  return [usageWindow('cursor-requests', 'Monthly requests', best.used / best.max * 100, resetsAt)]
}

export function createCursorUsage(options: ServiceOptions & { credentials?: () => Promise<CursorCredentials | null>; fetchJson?: Fetcher }) {
  const get = options.fetchJson ?? fetchJson
  return new TokenUsageService<CursorCredentials>(options, {
    credentials: options.credentials ?? (() => readCursorCredentials()),
    profile: async c => {
      if (c.email && c.plan) return { email: c.email, plan: c.plan }
      const [email, plan] = await Promise.all([
        c.email ?? get(`${API}/aiserver.v1.AuthService/GetEmail`, c.accessToken, true).then(v => text(object(v)?.email)).catch(() => null),
        c.plan ?? get(`${API}/auth/full_stripe_profile`, c.accessToken, false).then(v => text(object(v)?.membershipType)).catch(() => null),
      ])
      return { email, plan }
    },
    usage: async c => {
      const period = await get(`${API}/aiserver.v1.DashboardService/GetCurrentPeriodUsage`, c.accessToken, true).then(parseCursorPeriod, () => null)
      const windows = period ?? parseCursorLegacy(await get(`${API}/auth/usage`, c.accessToken, false))
      if (!windows) throw new Error('Cursor has not returned valid usage limit data.')
      return windows
    },
    signedOut: 'Sign in to Cursor (or run cursor-agent login), then refresh to see your Cursor usage.',
    expired: EXPIRED,
  })
}
