import { readFile, mkdir, writeFile, rename } from 'node:fs/promises'
import { dirname } from 'node:path'
import type {
  ClaudeUsageState,
  PresenceState,
  UsageState,
} from '../shared/types'
import { object } from './codex-parser'
import { DiscordIpc, type Activity, type DiscordConnection } from './discord-ipc'

// Discord application ID shared with the Windows and macOS apps. Not a secret.
// Its art assets provide the `discord-presence-icon` image key used below.
export const DISCORD_CLIENT_ID = '1517099756063686677'

/**
 * Subscription usage shown on the user's Discord profile. Only provider names
 * and used percentages leave the app: no email, plan, account ID or credits.
 * Cached or signed-out usage is skipped, so a stale number is never advertised.
 */
export function buildActivity(
  codex: Pick<UsageState, 'status' | 'snapshot'> | null,
  claude: Pick<ClaudeUsageState, 'status' | 'snapshot'> | null,
): Activity | null {
  const parts: string[] = []
  for (const [name, usage] of [
    ['Claude', claude],
    ['Codex', codex],
  ] as const) {
    const primary = usage?.status === 'ready' ? usage.snapshot?.windows[0] : null
    if (primary) parts.push(`${name} ${Math.round(primary.usedPercent)}% used`)
  }
  if (!parts.length) return null
  return {
    type: 0,
    details: 'Subscription usage',
    state: parts.join(' · '),
    assets: { large_image: 'discord-presence-icon', large_text: 'agentcord' },
    buttons: [
      {
        label: 'AgentCord on GitHub',
        url: 'https://github.com/preschian/agentcord',
      },
    ],
  }
}

/** Rich Presence is opt-in: a missing or unreadable file means disabled. */
export async function readPresenceEnabled(path: string): Promise<boolean> {
  try {
    return object(JSON.parse(await readFile(path, 'utf8')))?.presenceEnabled === true
  } catch {
    return false
  }
}
async function writePresenceEnabled(path: string, enabled: boolean): Promise<void> {
  await mkdir(dirname(path), { recursive: true })
  const tmp = `${path}.${process.pid}.tmp`
  await writeFile(tmp, JSON.stringify({ presenceEnabled: enabled }), { mode: 0o600 })
  await rename(tmp, path)
}

interface Options {
  settingsPath: string
  changed: (state: PresenceState) => void
  // Injectable for tests.
  createIpc?: (onState: (state: DiscordConnection) => void) => DiscordIpc
}

export class PresenceService {
  state: PresenceState = { enabled: false, status: 'off' }
  private readonly ipc: DiscordIpc
  private codex: UsageState | null = null
  private claude: ClaudeUsageState | null = null

  constructor(private readonly options: Options) {
    const onState = () => this.publish()
    this.ipc =
      options.createIpc?.(onState) ??
      new DiscordIpc({ clientId: DISCORD_CLIENT_ID, onState })
  }

  async start(): Promise<void> {
    if (await readPresenceEnabled(this.options.settingsPath)) this.apply(true)
  }

  /** Feed the latest usage; unchanged activity is dropped by the IPC client. */
  update(usage: { codex?: UsageState; claude?: ClaudeUsageState }): void {
    if (usage.codex) this.codex = usage.codex
    if (usage.claude) this.claude = usage.claude
    if (this.state.enabled)
      this.ipc.setActivity(buildActivity(this.codex, this.claude))
  }

  async setEnabled(enabled: boolean): Promise<PresenceState> {
    if (enabled === this.state.enabled) return this.state
    this.apply(enabled)
    try {
      await writePresenceEnabled(this.options.settingsPath, enabled)
    } catch {
      // Best-effort: the toggle still works for this run.
    }
    return this.state
  }

  /** Clear the presence and close the socket. Called on quit. */
  stop(): void {
    this.ipc.stop()
  }

  private apply(enabled: boolean): void {
    this.state = { enabled, status: enabled ? 'waiting' : 'off' }
    if (enabled) {
      this.ipc.setActivity(buildActivity(this.codex, this.claude))
      this.ipc.start()
    } else this.ipc.stop()
    this.options.changed(this.state)
  }

  private status(): PresenceState['status'] {
    return this.ipc.state === 'connected' ? 'connected' : 'waiting'
  }

  private publish(): void {
    const next: PresenceState = {
      enabled: this.state.enabled,
      status: this.state.enabled ? this.status() : 'off',
    }
    if (next.enabled === this.state.enabled && next.status === this.state.status)
      return
    this.state = next
    this.options.changed(next)
  }
}
