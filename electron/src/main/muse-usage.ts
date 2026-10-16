import { readFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'
import type { UsageWindow } from '../shared/types'
import { object, text } from './codex-parser'
import { type Credentials, type Profile, type ServiceOptions, TokenUsageService, hash, requestJson, usageWindow } from './token-usage'

// Undocumented endpoint the Muse Code CLI itself calls with its device-code login (same one CodexBar uses).
// The token comes from ~/.config/muse/auth.json. The response also carries an inference key and payment
// info: only the plan, email and quota windows are read from it.
// ponytail: macOS keeps the token in the keychain (ai.meta.dev.credentials), not read here; add when macOS is validated.
const KEY_URL = 'https://api.meta.ai/muse-code/key'
const EXPIRED = 'Muse Code sign-in was rejected. Run muse login again, then refresh.'
type Fetcher = (credentials: Credentials) => Promise<unknown>

export async function readMuseCredentials(home = homedir()): Promise<Credentials | null> {
  try {
    const meta = object(object(object(JSON.parse(await readFile(join(home, '.config', 'muse', 'auth.json'), 'utf8')))?.providers)?.meta)
    const accessToken = text(meta?.access_token)
    // The email outlives token rotation; only its hash is kept.
    return accessToken ? { accessToken, key: hash(text(meta?.user_email) ?? accessToken) } : null
  } catch { return null }
}
function fetchJson(c: Credentials): Promise<unknown> {
  return requestJson('Muse Code', EXPIRED, KEY_URL, {
    method: 'POST',
    headers: { Authorization: `Bearer ${c.accessToken}`, 'Content-Type': 'application/json', 'x-api-version': '1.0.0' },
    body: '{}',
    redirect: 'error', // Never follow the token anywhere else.
  })
}

function subscription(value: unknown) {
  const root = object(value)
  if (root?.require_payment === true) throw new Error('Muse Code needs a payment method. Finish billing at dev.meta.ai, then refresh.')
  if (root?.is_subs_active !== true) throw new Error('No Muse Code subscription is active on this login.')
  return root
}
export function parseMuseProfile(value: unknown): Profile {
  const root = subscription(value)
  return { email: text(root.user_email), plan: text(root.subs_tier_name)?.replace(/^Muse Code\s+/i, '') ?? null }
}
function window(id: string, label: string, minutes: number, raw: unknown): UsageWindow | null {
  const value = object(raw)
  const percent = value?.used_percent
  if (typeof percent !== 'number' || !Number.isFinite(percent)) return null // Missing data is not 0% usage.
  const reset = value?.resets_at
  return usageWindow(id, label, percent, typeof reset === 'number' && reset > 0 ? reset * 1000 : null, minutes)
}
export function parseMuseUsage(value: unknown): UsageWindow[] {
  const usage = object(subscription(value).subs_usage)
  // Meta omits the quota while the 5-hour window is idle, even if the weekly limit has usage:
  // the login is valid, there are just no numbers to show (the row says Idle).
  if (!usage) return []
  const duration = object(usage.window)?.window_duration_mins
  const minutes = typeof duration === 'number' && duration > 0 ? Math.round(duration) : 300
  const windows = [
    window('muse-session', minutes === 300 ? '5-hour session' : `${Math.round(minutes / 60)}-hour session`, minutes, usage.window),
    window('muse-weekly', 'Weekly limit', 10080, usage.weekly),
  ].filter(w => !!w)
  if (!windows.length) throw new Error('Muse Code has not returned valid usage limit data.')
  return windows
}

export function createMuseUsage(options: ServiceOptions & { credentials?: () => Promise<Credentials | null>; fetchJson?: Fetcher }) {
  const get = options.fetchJson ?? fetchJson
  return new TokenUsageService(options, {
    credentials: options.credentials ?? (() => readMuseCredentials()),
    // ponytail: profile and usage come from the same response, so the daily profile refresh costs one extra call.
    profile: async c => parseMuseProfile(await get(c)),
    usage: async c => parseMuseUsage(await get(c)),
    signedOut: 'Run muse login, then refresh to see your Muse Code usage.',
    expired: EXPIRED,
  })
}
