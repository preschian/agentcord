import type { LaunchAtLoginState } from '../shared/types'

// Marker passed to the login entry so a login launch can start hidden in the
// tray instead of popping the window open (macOS reports this via
// `wasOpenedAtLogin`; Windows has no such flag, so it uses this argument).
export const HIDDEN_ARG = '--hidden'

interface LoginItemOptions {
  path?: string
  args?: string[]
}
// The slice of Electron's `app` used here, so tests can fake it.
export interface LoginItemHost {
  platform: NodeJS.Platform
  isPackaged: boolean
  env: Record<string, string | undefined>
  execPath: string
  getLoginItemSettings(options?: LoginItemOptions): {
    openAtLogin: boolean
    wasOpenedAtLogin?: boolean
    executableWillLaunchAtLogin?: boolean
  }
  setLoginItemSettings(
    settings: LoginItemOptions & { openAtLogin: boolean },
  ): void
}

// Electron does not implement login items on Linux, and an unpackaged dev run
// would register the bare electron binary rather than AgentCord.
export function loginItemSupported(host: LoginItemHost): boolean {
  return (
    host.isPackaged && (host.platform === 'darwin' || host.platform === 'win32')
  )
}
function options(host: LoginItemHost): LoginItemOptions {
  if (host.platform !== 'win32') return {}
  // A portable build runs from a temporary extraction folder; the stable
  // launcher path is the one that must be registered.
  return {
    path: host.env.PORTABLE_EXECUTABLE_FILE || host.execPath,
    args: [HIDDEN_ARG],
  }
}
// The OS is the source of truth: the state is read back on every call and
// nothing is persisted by the app.
export function getLaunchAtLogin(host: LoginItemHost): LaunchAtLoginState {
  if (!loginItemSupported(host)) return { supported: false, enabled: false }
  try {
    const settings = host.getLoginItemSettings(options(host))
    return { supported: true, enabled: settings.openAtLogin }
  } catch {
    return { supported: false, enabled: false }
  }
}
export function setLaunchAtLogin(
  host: LoginItemHost,
  enabled: boolean,
): LaunchAtLoginState {
  if (!loginItemSupported(host)) return { supported: false, enabled: false }
  host.setLoginItemSettings({ ...options(host), openAtLogin: enabled })
  return getLaunchAtLogin(host)
}
export function startedAtLogin(host: LoginItemHost, argv: string[]): boolean {
  if (!loginItemSupported(host)) return false
  if (argv.includes(HIDDEN_ARG)) return true
  try {
    return host.getLoginItemSettings().wasOpenedAtLogin === true
  } catch {
    return false
  }
}
