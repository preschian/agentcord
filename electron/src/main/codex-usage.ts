import { readFile, mkdir, writeFile, rename, rm } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import type { UsageSnapshot, UsageState } from '../shared/types'
import { codexHome, findCodex } from './codex-paths'
import { object, text, parseAccount, parseRateLimits } from './codex-parser'
import { CodexRpc } from './codex-rpc'

export const POLL_INTERVAL = 5 * 60_000
export const MIN_REFRESH_INTERVAL = 60_000
export const MAX_CACHE_AGE = 24 * 60 * 60_000
// Invalidate the previous Indonesian display labels on offline relaunches.
const CACHE_VERSION = 2
export type Identity = { kind: 'chatgpt'; key: string } | { kind: 'api-key' | 'signed-out'; key: null }
type Probe = { account: ReturnType<typeof parseAccount>; usage: ReturnType<typeof parseRateLimits> | null }
interface Options {
  cachePath: string
  visible: () => boolean
  changed: (state: UsageState) => void
  home?: string
  identity?: () => Promise<Identity>
  executable?: () => Promise<string | null>
  probe?: (executable: string) => Promise<Probe>
  now?: () => number
}

export async function readIdentity(home: string): Promise<Identity> {
  try {
    // Inspect identity only. OAuth refresh/access tokens are never used,
    // forwarded, cached, or exposed to the renderer; Codex owns authentication.
    const auth = object(JSON.parse(await readFile(join(home, 'auth.json'), 'utf8')))
    const key = text(object(auth?.tokens)?.account_id)
    if (key) return { kind: 'chatgpt', key }
    if (text(auth?.OPENAI_API_KEY)) return { kind: 'api-key', key: null }
  } catch { /* Missing or invalid auth is signed out. */ }
  return { kind: 'signed-out', key: null }
}
export function validSnapshot(value: unknown, now: number): value is UsageSnapshot {
  const data = object(value)
  return !!data && typeof data.fetchedAt === 'number' && Number.isFinite(data.fetchedAt)
    && data.fetchedAt <= now && now - data.fetchedAt <= MAX_CACHE_AGE
    && (data.email === null || typeof data.email === 'string')
    && (data.plan === null || typeof data.plan === 'string')
    && Array.isArray(data.windows) && data.windows.length > 0
    && data.windows.every(value => {
      const window = object(value)
      return window && typeof window.id === 'string' && typeof window.label === 'string'
        && typeof window.usedPercent === 'number' && Number.isFinite(window.usedPercent)
        && window.usedPercent >= 0 && window.usedPercent <= 100
        && (window.resetsAt === null || (typeof window.resetsAt === 'number' && Number.isFinite(window.resetsAt)))
        && ['normal', 'warning', 'critical'].includes(String(window.severity))
    })
    && (data.credits === null || (() => {
      const credits = object(data.credits)
      return !!credits && (credits.balance === null || typeof credits.balance === 'string')
        && typeof credits.unlimited === 'boolean' && typeof credits.hasCredits === 'boolean'
    })())
}

export class CodexUsageService {
  state: UsageState
  private options: Options
  private key: string | null = null
  private now: () => number
  private timer: ReturnType<typeof setInterval> | null = null
  private flight: Promise<UsageState> | null = null
  private rpc: CodexRpc | null = null
  private stopped = false
  constructor(options: Options) {
    this.options = options
    this.now = options.now ?? Date.now
    this.state = {
      status: 'loading', snapshot: null, refreshing: false, message: null,
      nextRefreshAt: 0, codexHome: options.home ?? codexHome(), executable: null,
    }
  }
  private identity(): Promise<Identity> {
    return this.options.identity?.() ?? readIdentity(this.state.codexHome)
  }
  private emit(): void { if (!this.stopped) this.options.changed({ ...this.state }) }
  async start(): Promise<void> {
    const identity = await this.identity()
    this.key = identity.key
    try {
      const cache = object(JSON.parse(await readFile(this.options.cachePath, 'utf8')))
      if (identity.key && cache?.version === CACHE_VERSION && cache.accountKey === identity.key && validSnapshot(cache.snapshot, this.now())) {
        this.state.snapshot = cache.snapshot
        this.state.status = 'cached'
        this.emit()
      } else await this.clearCache()
    } catch { /* Cache is best-effort. */ }
    await this.refresh()
    if (!this.stopped) this.timer = setInterval(() => void this.tick(), POLL_INTERVAL)
  }
  async tick(): Promise<void> {
    if (this.stopped) return
    const identity = await this.identity()
    if (identity.kind !== 'chatgpt' && this.state.status === identity.kind && !this.state.snapshot) return
    if (identity.key !== this.key || identity.kind !== 'chatgpt') {
      await this.invalidate(identity)
      if (identity.kind === 'chatgpt' && this.options.visible()) await this.refresh()
      return
    }
    if (this.state.snapshot && this.now() - this.state.snapshot.fetchedAt > MAX_CACHE_AGE) {
      this.state.snapshot = null
      this.state.status = 'unavailable'
      this.state.message = 'The usage cache has expired. Refresh to get the latest limits.'
      await this.clearCache()
      this.emit()
    }
    // A hidden/idle tray app does not spawn a server just to poll usage.
    if (this.options.visible() && (!this.state.snapshot || this.now() - this.state.snapshot.fetchedAt >= POLL_INTERVAL)) {
      await this.refresh()
    }
  }
  refresh(): Promise<UsageState> {
    if (this.flight) return this.flight
    if (this.stopped || this.now() < this.state.nextRefreshAt) return Promise.resolve(this.state)
    this.flight = this.fetch().finally(() => { this.flight = null })
    return this.flight
  }
  private async invalidate(identity: Identity): Promise<void> {
    this.key = identity.key
    this.state.snapshot = null
    this.state.status = identity.kind === 'api-key' ? 'api-key' : identity.kind === 'signed-out' ? 'signed-out' : 'loading'
    this.state.message = identity.kind === 'api-key'
      ? 'Sign in to Codex with a ChatGPT account to view subscription limits. API-key billing is not supported in this preview.'
      : identity.kind === 'signed-out' ? 'Run codex login, then refresh to see your ChatGPT usage.' : null
    await this.clearCache()
    this.emit()
  }
  private async probe(executable: string): Promise<Probe> {
    if (this.options.probe) return this.options.probe(executable)
    const rpc = new CodexRpc({ executable, home: this.state.codexHome })
    this.rpc = rpc
    try {
      await rpc.request('initialize', {
        clientInfo: { name: 'agentcord_electron', title: 'AgentCord Electron', version: '0.1.0' },
        capabilities: { experimentalApi: false },
      })
      rpc.notify('initialized')
      const account = parseAccount(await rpc.request('account/read', { refreshToken: false }))
      if (account.type !== 'chatgpt' && account.type !== 'personalAccessToken') return { account, usage: null }
      const usage = parseRateLimits(await rpc.request('account/rateLimits/read', null))
      return { account, usage }
    } finally { rpc.close(); this.rpc = null }
  }
  private async fetch(): Promise<UsageState> {
    this.state.refreshing = true
    this.state.nextRefreshAt = this.now() + MIN_REFRESH_INTERVAL
    this.state.message = null
    this.emit()
    try {
      const identity = await this.identity()
      if (identity.key !== this.key || identity.kind !== 'chatgpt') await this.invalidate(identity)
      if (identity.kind !== 'chatgpt') return this.state
      const executable = await (this.options.executable?.() ?? findCodex())
      this.state.executable = executable
      if (!executable) throw new Error('Codex CLI was not found. Install Codex or set CODEX_BINARY to the Codex executable.')
      const { account, usage } = await this.probe(executable)
      if (this.stopped) return this.state
      // Account may have switched while the server was running. Never publish
      // an old account's response under the new account's cache key.
      const current = await this.identity()
      if (current.key !== identity.key || current.kind !== 'chatgpt') {
        await this.invalidate(current)
        return this.state
      }
      if (!account.type || account.type === 'apiKey') {
        await this.invalidate({ kind: account.type === 'apiKey' ? 'api-key' : 'signed-out', key: null })
        return this.state
      }
      if (!usage) throw new Error('This account does not provide Codex subscription limits.')
      this.state.snapshot = { ...usage, email: account.email, plan: usage.plan ?? account.plan, fetchedAt: this.now() }
      this.state.status = 'ready'
      await this.saveCache(identity.key, this.state.snapshot)
    } catch (error) {
      // Invalidate even on failure if logout/account switch happened in flight.
      const identity = await this.identity()
      if (identity.key !== this.key || identity.kind !== 'chatgpt') await this.invalidate(identity)
      else {
        if (this.state.snapshot && this.now() - this.state.snapshot.fetchedAt > MAX_CACHE_AGE) {
          this.state.snapshot = null
          await this.clearCache()
        }
        this.state.status = this.state.snapshot ? 'cached' : 'unavailable'
        this.state.message = error instanceof Error ? error.message : 'Usage could not be retrieved. Please try again later.'
      }
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
    this.rpc?.close()
  }
}
