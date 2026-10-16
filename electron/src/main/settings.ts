import { readFile, mkdir, writeFile, rename } from 'node:fs/promises'
import { dirname } from 'node:path'
import type { Agent, AppSettings } from '../shared/types'
import { object } from './codex-parser'

export const AGENTS: readonly Agent[] = ['codex', 'claude', 'cursor', 'grok', 'muse']
export const isAgent = (value: unknown): value is Agent =>
  AGENTS.includes(value as Agent)

/** Missing or malformed fields fall back to defaults: presence off, every agent and display option on. */
export async function readSettings(path: string): Promise<AppSettings> {
  let raw: Record<string, unknown> | null = null
  try {
    raw = object(JSON.parse(await readFile(path, 'utf8')))
  } catch {
    // Missing or unreadable file: defaults.
  }
  const agents = object(raw?.agents)
  return {
    presenceEnabled: raw?.presenceEnabled === true,
    agents: Object.fromEntries(
      AGENTS.map((agent) => [agent, agents?.[agent] !== false]),
    ) as Record<Agent, boolean>,
    unifiedUsage: raw?.unifiedUsage !== false,
  }
}

let queue: Promise<unknown> = Promise.resolve()
/** Read, change and write back, serialized so concurrent toggles never drop each other's change. */
export function updateSettings(
  path: string,
  change: (settings: AppSettings) => void,
): Promise<AppSettings> {
  const next = queue.then(async () => {
    const settings = await readSettings(path)
    change(settings)
    await mkdir(dirname(path), { recursive: true })
    const tmp = `${path}.${process.pid}.tmp`
    await writeFile(tmp, JSON.stringify(settings), { mode: 0o600 })
    await rename(tmp, path)
    return settings
  })
  queue = next.catch(() => {})
  return next
}
