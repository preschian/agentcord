export type IconRole = 'app' | 'tray'

export function iconFilename(platform: NodeJS.Platform, role: IconRole): string {
  // Windows Tray::SetImage asks NativeImage for an HICON of the system's small
  // icon size. PNGs use their base bitmap there, ignoring @2x representations.
  // Preserve the ICO path so Windows selects a native frame at the target size.
  if (platform === 'win32') return 'agentcord.ico'
  return role === 'tray' ? 'agentcord-tray.png' : 'agentcord.png'
}
