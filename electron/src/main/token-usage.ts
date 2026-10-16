import { createHash } from 'node:crypto'
import { readFile, mkdir, writeFile, rename, rm } from 'node:fs/promises'
import { dirname } from 'node:path'
import type { ProviderUsageState, UsageSnapshot, UsageWindow } from '../shared/types'
import { object } from './codex-parser'
import { MAX_CACHE_AGE, MIN_REFRESH_INTERVAL, POLL_INTERVAL, validSnapshot } from './codex-usage'

// Shared poller for providers whose CLI/IDE leaves an access token on disk (Claude, Cursor, Grok).
// The token is read-only: never cached, forwarded to the renderer, or refreshed by us, so a
// rotating refresh token stays with the tool that owns it.
const CACHE_VERSION = 1
export interface Credentials { accessToken: string; key: string; expiresAt?: number }
export interface Profile { email: string | null; plan: string | null }
export interface Provider<C extends Credentials = Credentials> {
  credentials: () => Promise<C | null>
  /** Ask the owning tool to renew an expired token on disk. */
  renew?: () => Promise<void>
  profile: (credentials: C) => Promise<Profile>
  usage: (credentials: C) => Promise<UsageWindow[]>
  signedOut: string
  expired: string
}
export interface ServiceOptions {
  cachePath: string
  visible: () => boolean
  changed: (state: ProviderUsageState) => void
  now?: () => number
}

export const hash = (value: string) => createHash('sha256').update(value).digest('hex')
export function severity(usedPercent: number): UsageWindow['severity'] {
  return usedPercent >= 90 ? 'critical' : usedPercent >= 70 ? 'warning' : 'normal'
}
export function usageWindow(id: string, label: string, percent: number, resetsAt: number | null, durationMinutes: number | null = null): UsageWindow {
  const usedPercent = Math.min(100, Math.max(0, percent))
  return { id, label, usedPercent, durationMinutes, resetsAt, severity: severity(usedPercent) }
}
export async function requestJson(name: string, expired: string, url: string, init: RequestInit): Promise<unknown> {
  const response = await fetch(url, { ...init, signal: AbortSignal.timeout(15_000) })
  if (!response.ok) throw new Error(response.status === 401 ? expired : response.status === 429
    ? `${name} is rate-limiting usage requests. Try again in a few minutes.`
    : `${name} usage request failed (HTTP ${response.status}).`)
  return response.json()
}

export class TokenUsageService<C extends Credentials = Credentials> {
  state: ProviderUsageState = { status: 'loading', snapshot: null, refreshing: false, message: null, nextRefreshAt: 0 }
  private options: ServiceOptions
  private provider: Provider<C>
  private key: string | null = null
  private profile: Profile & { token: string; at: number } | null = null
  private now: () => number
  private timer: ReturnType<typeof setInterval> | null = null
  private flight: Promise<ProviderUsageState> | null = null
  private stopped = false
  constructor(options: ServiceOptions, provider: Provider<C>) {
    this.options = options
    this.provider = provider
    this.now = options.now ?? Date.now
  }
  private emit(): void { if (!this.stopped) this.options.changed({ ...this.state }) }
  private expired(c: Credentials) { return c.expiresAt !== undefined && this.now() >= c.expiresAt }
  async start(): Promise<void> {
    const credentials = await this.provider.credentials()
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
  refresh(): Promise<ProviderUsageState> {
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
  private async fetch(): Promise<ProviderUsageState> {
    this.state.refreshing = true
    this.state.nextRefreshAt = this.now() + MIN_REFRESH_INTERVAL
    this.state.message = null
    this.emit()
    try {
      let credentials = await this.provider.credentials()
      if (credentials && this.expired(credentials) && this.provider.renew) {
        await this.provider.renew()
        credentials = await this.provider.credentials()
      }
      // Logout or account switch: never keep showing another account's numbers.
      if ((credentials?.key ?? null) !== this.key) { this.key = credentials?.key ?? null; await this.invalidate() }
      if (!credentials) {
        this.state.status = 'signed-out'
        this.state.message = this.provider.signedOut
        return this.state
      }
      // An expired token only earns a 401; keep the cached numbers instead.
      if (this.expired(credentials)) throw new Error(this.provider.expired)
      // Plan and email change rarely: refresh at most daily, or when the token rotates.
      if (!this.profile || this.profile.token !== credentials.accessToken || this.now() - this.profile.at >= MAX_CACHE_AGE) {
        try { this.profile = { ...await this.provider.profile(credentials), token: credentials.accessToken, at: this.now() } }
        catch { /* Best-effort: keep the last known profile. */ }
      }
      const windows = await this.provider.usage(credentials)
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
