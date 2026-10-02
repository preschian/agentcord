import { access } from 'node:fs/promises'
import { constants } from 'node:fs'
import { delimiter, join, resolve } from 'node:path'
import { homedir } from 'node:os'

export function codexHome(): string {
  return process.env.CODEX_HOME?.trim() ? resolve(process.env.CODEX_HOME.trim()) : join(homedir(), '.codex')
}
export async function findCodex(): Promise<string | null> {
  const home = homedir()
  const win = process.platform === 'win32'
  const binary = win ? 'codex.exe' : 'codex'
  const candidates = [
    process.env.CODEX_BINARY?.trim(),
    ...(process.env.PATH ?? '').split(delimiter).filter(Boolean).map(dir => join(dir.replace(/^"|"$/g, ''), binary)),
    ...(win ? [
      join(process.env.LOCALAPPDATA ?? join(home, 'AppData', 'Local'), 'Programs', 'OpenAI', 'Codex', 'bin', binary),
    ] : ['/opt/homebrew/bin/codex', '/usr/local/bin/codex', '/usr/bin/codex']),
    join(home, '.local', 'bin', binary), join(home, 'bin', binary),
  ].filter((path): path is string => Boolean(path))
  // npm on Windows exposes a .cmd wrapper, not an executable. Resolve the
  // native optional package instead of enabling shell execution for IPC input.
  if (win) {
    const arch = process.arch === 'arm64' ? 'arm64' : 'x64'
    const target = arch === 'arm64' ? 'aarch64-pc-windows-msvc' : 'x86_64-pc-windows-msvc'
    const roots = [
      ...(process.env.PATH ?? '').split(delimiter).filter(Boolean).map(dir => dir.replace(/^"|"$/g, '')),
      process.env.APPDATA ? join(process.env.APPDATA, 'npm') : join(home, 'AppData', 'Roaming', 'npm'),
    ]
    for (const root of roots) {
      const pkg = join(root, 'node_modules', '@openai', 'codex')
      candidates.push(
        join(pkg, 'node_modules', '@openai', `codex-win32-${arch}`, 'vendor', target, 'bin', binary),
        join(pkg, 'vendor', target, 'codex', binary),
      )
    }
  }
  for (const path of new Set(candidates)) {
    try {
      if (win && !path.toLowerCase().endsWith('.exe')) continue
      await access(path, win ? constants.F_OK : constants.X_OK)
      return path
    } catch { /* Try the next installation. */ }
  }
  return null
}
