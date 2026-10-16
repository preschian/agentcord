import type {
  Agent,
  ClaudeUsageState,
  PresenceState,
  UsageState,
} from '../shared/types'
import { DiscordIpc, type Activity, type DiscordConnection } from './discord-ipc'
import { readSettings, updateSettings } from './settings'

// Discord application ID shared with the Windows and macOS apps. Not a secret.
// Its art assets provide the `discord-presence-icon` image key used below.
export const DISCORD_CLIENT_ID = '1517099756063686677'

/**
 * Subscription usage shown on the user's Discord profile. Only provider names
 * and used percentages leave the app: no email, plan, account ID or credits.
 * Cached or signed-out usage is skipped, so a stale number is never advertised.
 * `claudeActive` (Claude Desktop is running) is a bare boolean, nothing more.
 */
export function buildActivity(
  codex: Pick<UsageState, 'status' | 'snapshot'> | null,
  claude: Pick<ClaudeUsageState, 'status' | 'snapshot'> | null,
  claudeActive = false,
): Activity | null {
  const parts: string[] = []
  for (const [name, usage] of [
    ['Claude', claude],
    ['Codex', codex],
  ] as const) {
    const primary = usage?.status === 'ready' ? usage.snapshot?.windows[0] : null
    if (primary) parts.push(`${name} ${Math.round(primary.usedPercent)}% used`)
  }
  if (!parts.length && !claudeActive) return null
  return {
    type: 0,
    details: claudeActive ? 'Using Claude Desktop' : 'Subscription usage',
    state: parts.length ? parts.join(' · ') : undefined,
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
  return (await readSettings(path)).presenceEnabled
}

interface Options {
  settingsPath: string
  changed: (state: PresenceState) => void
  /** Agents switched off in Settings are left out of the activity. */
  agentEnabled?: (agent: Agent) => boolean
  // Injectable for tests.
  createIpc?: (onState: (state: DiscordConnection) => void) => DiscordIpc
}

export class PresenceService {
  state: PresenceState = { enabled: false, status: 'off' }
  private readonly ipc: DiscordIpc
  private codex: UsageState | null = null
  private claude: ClaudeUsageState | null = null
  private claudeActive = false

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
  update(usage: {
    codex?: UsageState
    claude?: ClaudeUsageState
    claudeActive?: boolean
  }): void {
    if (usage.codex) this.codex = usage.codex
    if (usage.claude) this.claude = usage.claude
    if (usage.claudeActive !== undefined) this.claudeActive = usage.claudeActive
    if (this.state.enabled) this.ipc.setActivity(this.activity())
  }

  async setEnabled(enabled: boolean): Promise<PresenceState> {
    if (enabled === this.state.enabled) return this.state
    this.apply(enabled)
    try {
      await updateSettings(this.options.settingsPath, (settings) => {
        settings.presenceEnabled = enabled
      })
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
      this.ipc.setActivity(this.activity())
      this.ipc.start()
    } else this.ipc.stop()
    this.options.changed(this.state)
  }

  private activity(): Activity | null {
    const on = this.options.agentEnabled ?? (() => true)
    return buildActivity(
      on('codex') ? this.codex : null,
      on('claude') ? this.claude : null,
      on('claude') && this.claudeActive,
    )
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
