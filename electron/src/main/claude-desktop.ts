import { execFile } from 'node:child_process'

// Detects whether the Claude Desktop app is running, so the popover and Discord
// presence can show that Claude is active. Only a boolean leaves this module.
// Claude Code's own CLI is a different process and is deliberately not matched:
// on Windows it is also called claude.exe, so Windows matches by install path.
export const DESKTOP_POLL_INTERVAL = 30_000
const MAC_PATTERN = 'Claude\\.app/Contents/MacOS/Claude$'
// Squirrel (AnthropicClaude), MSIX (WindowsApps\Claude_*) and per-user installs.
const WINDOWS_PATH = /\\(AnthropicClaude|Claude_[^\\]+|Programs\\Claude)\\/i
const WINDOWS_SCRIPT =
  'Get-Process -Name Claude -ErrorAction SilentlyContinue | ForEach-Object { $_.Path }'

export type Runner = (file: string, args: string[]) => Promise<string>

const run: Runner = (file, args) =>
  new Promise((resolve, reject) =>
    execFile(file, args, { timeout: 5_000, windowsHide: true }, (error, stdout) =>
      error ? reject(error) : resolve(stdout),
    ),
  )

export function matchesWindowsDesktop(output: string): boolean {
  return output.split(/\r?\n/).some((line) => WINDOWS_PATH.test(line.trim()))
}

export async function isClaudeDesktopRunning(
  platform: NodeJS.Platform = process.platform,
  runner: Runner = run,
): Promise<boolean> {
  try {
    if (platform === 'darwin')
      return (await runner('pgrep', ['-f', MAC_PATTERN])).trim().length > 0
    if (platform === 'win32')
      return matchesWindowsDesktop(
        await runner('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', WINDOWS_SCRIPT]),
      )
  } catch {
    // pgrep exits 1 when nothing matches; any failure means "not detected".
  }
  return false // Claude Desktop has no Linux build.
}

interface Options {
  // Idle stays idle: nothing is scanned unless something would show the result.
  needed: () => boolean
  changed: (active: boolean) => void
  detect?: () => Promise<boolean>
}

export class ClaudeDesktopService {
  active = false
  private timer: ReturnType<typeof setInterval> | null = null
  private running: Promise<void> | null = null
  private stopped = false

  constructor(private readonly options: Options) {}

  start(): Promise<void> {
    this.stopped = false
    this.timer ??= setInterval(() => void this.tick(), DESKTOP_POLL_INTERVAL)
    return this.tick()
  }

  stop(): void {
    this.stopped = true
    if (this.timer) clearInterval(this.timer)
    this.timer = null
  }

  /** One scan; concurrent callers share it. Skipped when nothing needs the result. */
  tick(): Promise<void> {
    if (this.stopped || !this.options.needed()) return Promise.resolve()
    this.running ??= this.scan().finally(() => (this.running = null))
    return this.running
  }

  private async scan(): Promise<void> {
    const active = await (this.options.detect ?? isClaudeDesktopRunning)()
    if (this.stopped || active === this.active) return
    this.active = active
    this.options.changed(active)
  }
}
