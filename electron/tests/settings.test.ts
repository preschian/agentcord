import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { isAgent, readSettings, updateSettings } from '../src/main/settings.ts'

async function temp() {
  const dir = await mkdtemp(join(tmpdir(), 'agentcord-settings-'))
  return { path: join(dir, 'settings.json'), cleanup: () => rm(dir, { recursive: true, force: true }) }
}

test('missing or malformed settings fall back to defaults', async () => {
  const t = await temp()
  try {
    const defaults = {
      presenceEnabled: false,
      agents: { codex: true, claude: true, cursor: true, grok: true, muse: true },
      unifiedUsage: true,
    }
    assert.deepEqual(await readSettings(t.path), defaults)
    await writeFile(t.path, '{not json')
    assert.deepEqual(await readSettings(t.path), defaults)
    // An old file with only presence keeps it and fills the rest.
    await writeFile(t.path, JSON.stringify({ presenceEnabled: true, agents: { grok: false, codex: 'no' } }))
    const old = await readSettings(t.path)
    assert.equal(old.presenceEnabled, true)
    assert.deepEqual(old.agents, { ...defaults.agents, grok: false })
  } finally { await t.cleanup() }
})

test('concurrent updates keep every change', async () => {
  const t = await temp()
  try {
    await Promise.all([
      updateSettings(t.path, (s) => { s.presenceEnabled = true }),
      updateSettings(t.path, (s) => { s.agents.cursor = false }),
      updateSettings(t.path, (s) => { s.unifiedUsage = false }),
    ])
    const saved = JSON.parse(await readFile(t.path, 'utf8'))
    assert.equal(saved.presenceEnabled, true)
    assert.equal(saved.agents.cursor, false)
    assert.equal(saved.unifiedUsage, false)
  } finally { await t.cleanup() }
})

test('only known agents are accepted', () => {
  assert.equal(isAgent('codex'), true)
  assert.equal(isAgent('muse'), true)
  assert.equal(isAgent('antigravity'), false)
  assert.equal(isAgent('__proto__'), false)
})
