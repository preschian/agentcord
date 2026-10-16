import { execFile } from 'node:child_process'
import { existsSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'
import type { UsageWindow } from '../shared/types'
import { object, text } from './codex-parser'
import { type Credentials, type ServiceOptions, TokenUsageService, hash, requestJson, usageWindow } from './token-usage'

// Weekly SuperGrok credits, the same endpoint as the Grok CLI `/usage` view; ported from
// windows/GrokUsage.cs, except we never use the refresh token. xAI rotates it, and spending
// it here leaves the CLI with a rejected token that it answers by deleting auth.json. An
// expired token is renewed by the CLI itself (`grok models`), like `claude auth status`.
const API = 'https://cli-chat-proxy.grok.com/v1'
const EXPIRED = 'Grok sign-in has expired and could not be renewed. Run grok login, then refresh.'
type Fetcher = (url: string, credentials: GrokCredentials) => Promise<unknown>
interface GrokCredentials extends Credentials { email: string | null; userId: string | null }

export async function readGrokCredentials(home = grokHome()): Promise<GrokCredentials | null> {
  try {
    const root = object(JSON.parse(await readFile(join(home, 'auth.json'), 'utf8')))
    for (const entry of Object.values(root ?? {}).map(object)) {
      const accessToken = text(entry?.key)
      if (!accessToken) continue
      const expiresAt = Date.parse(String(entry?.expires_at))
      const userId = text(entry?.user_id)
      return { accessToken, userId, email: text(entry?.email), expiresAt: Number.isNaN(expiresAt) ? undefined : expiresAt, key: hash(userId ?? text(entry?.principal_id) ?? accessToken) }
    }
  } catch { /* Missing or malformed auth is signed out. */ }
  return null
}
const grokHome = () => process.env.GROK_HOME?.trim() || join(homedir(), '.grok')
export function renewGrok(): Promise<void> {
  const local = join(grokHome(), 'bin', process.platform === 'win32' ? 'grok.exe' : 'grok')
  const exe = existsSync(local) ? local : 'grok'
  return new Promise(resolve => execFile(exe, ['models'],
    { timeout: 30_000, windowsHide: true, shell: exe === 'grok' && process.platform === 'win32' }, () => resolve()))
}
function fetchJson(url: string, c: GrokCredentials): Promise<unknown> {
  const headers: Record<string, string> = { Authorization: `Bearer ${c.accessToken}`, Accept: 'application/json', 'X-XAI-Token-Auth': 'xai-grok-cli', 'User-Agent': 'GrokCLI' }
  if (c.userId) headers['x-userid'] = c.userId
  return requestJson('Grok', EXPIRED, url, { headers })
}

const TIERS: Record<string, string> = { SuperGrokPro: 'SuperGrok Heavy', SuperGrokHeavy: 'SuperGrok Heavy', GrokHeavy: 'SuperGrok Heavy', GrokPro: 'SuperGrok', SuperGrok: 'SuperGrok', Free: 'Free', GrokFree: 'Free' }
/** Prefer the brand string from /settings; fall back to mapping `subscriptionTier`. */
export function parseGrokPlan(value: unknown): string | null {
  const root = object(value)
  const tier = text(root?.subscriptionTier)?.trim()
  return text(root?.subscription_tier_display)?.trim() || (tier ? TIERS[tier] ?? tier : null)
}
const money = (value: unknown) => typeof value === 'number' ? value : typeof object(value)?.val === 'number' ? object(value)!.val as number : null
export function parseGrokBilling(value: unknown): UsageWindow[] {
  const root = object(value)
  const config = object(root?.config)
  const end = Date.parse(String(text(object(config?.currentPeriod)?.end) ?? text(config?.billingPeriodEnd) ?? text(root?.billingPeriodEnd)))
  const resetsAt = Number.isNaN(end) ? null : end
  // Unified-billing accounts omit the percent but still report the weekly period; the CLI shows 0%.
  const used = config?.creditUsagePercent ?? root?.creditUsagePercent ?? (resetsAt !== null ? 0 : null)
  if (typeof used !== 'number' || !Number.isFinite(used)) throw new Error('Grok has not returned valid usage limit data.')
  const windows = [usageWindow('grok-weekly', 'Weekly credits', used, resetsAt, 10080)]
  const cap = money(config?.onDemandCap)
  if (cap && cap > 0) windows.push(usageWindow('grok-on-demand', 'On-demand', (money(config?.onDemandUsed) ?? 0) / cap * 100, resetsAt))
  return windows
}

export function createGrokUsage(options: ServiceOptions & { credentials?: () => Promise<GrokCredentials | null>; fetchJson?: Fetcher; renew?: () => Promise<void> }) {
  const get = options.fetchJson ?? fetchJson
  return new TokenUsageService<GrokCredentials>(options, {
    credentials: options.credentials ?? (() => readGrokCredentials()),
    renew: options.renew ?? renewGrok,
    profile: async c => ({
      email: c.email,
      plan: parseGrokPlan(await get(`${API}/settings`, c).catch(() => null)) ?? parseGrokPlan(await get(`${API}/user?include=subscription`, c)),
    }),
    usage: async c => parseGrokBilling(await get(`${API}/billing?format=credits`, c)),
    signedOut: 'Run grok login, then refresh to see your Grok usage.',
    expired: EXPIRED,
  })
}
