import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm, readFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { ClaudeUsageService, desktopWindows, parseClaudeProfile, parseClaudeUsage } from '../src/main/claude-usage.ts'

const usage = {
  limits: [
    { kind: 'session', percent: 42, resets_at: '2026-10-02T15:00:00Z', severity: 'normal' },
    { kind: 'weekly_all', group: 'weekly', percent: 75, resets_at: '2026-10-08T00:00:00Z' },
    { group: 'weekly', percent: 10, scope: { model: { display_name: 'Opus' } } },
  ],
}
test('parses structured limits, per-model weekly, and flat fallback', () => {
  const [session, weekly, opus] = parseClaudeUsage(usage)
  assert.equal(session.usedPercent, 42)
  assert.equal(session.resetsAt, Date.parse('2026-10-02T15:00:00Z'))
  assert.equal(weekly.severity, 'warning')
  assert.equal(opus.label, 'Opus · Weekly limit')
  assert.equal(parseClaudeUsage({ five_hour: { utilization: 5 }, seven_day: { utilization: 95 } })[1].severity, 'critical')
  assert.throws(() => parseClaudeUsage({}))
})
test('parses plan and email from the profile', () => {
  assert.deepEqual(parseClaudeProfile({ account: { email: 'a@b.invalid' }, organization: { organization_type: 'claude_max' } }), { email: 'a@b.invalid', plan: 'Max' })
  assert.equal(parseClaudeProfile({ account: { has_claude_pro: true } }).plan, 'Pro')
})
test('fetch caches without email; account switch and logout drop old data', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'agentcord-claude-'))
  t.after(() => rm(dir, { recursive: true, force: true }))
  const cachePath = join(dir, 'claude.json')
  let credentials: { accessToken: string; key: string } | null = { accessToken: 't', key: 'a' }
  let now = 1_800_000_000_000
  const service = new ClaudeUsageService({
    cachePath, visible: () => true, changed: () => {}, now: () => now, credentials: async () => credentials, desktop: async () => null,
    fetchJson: async url => url.endsWith('/profile') ? { account: { email: 'a@b.invalid' } } : usage,
  })
  t.after(() => service.stop())
  await service.refresh()
  assert.equal(service.state.status, 'ready')
  assert.equal(service.state.snapshot?.email, 'a@b.invalid')
  assert.equal(JSON.parse(await readFile(cachePath, 'utf8')).snapshot.email, null)
  now += 60_000
  credentials = { accessToken: 't2', key: 'b' }
  await service.refresh()
  assert.equal(service.state.snapshot?.windows.length, 3) // refetched under the new account
  now += 60_000
  credentials = null
  await service.refresh()
  assert.equal(service.state.status, 'signed-out')
  assert.equal(service.state.snapshot, null)
  await assert.rejects(readFile(cachePath))
})
test('expired token keeps the cache without hitting the network', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'agentcord-claude-'))
  t.after(() => rm(dir, { recursive: true, force: true }))
  let now = 1_800_000_000_000
  let calls = 0
  let renewals = 0
  let renew = async () => {}
  let credentials = { accessToken: 't', key: 'a', expiresAt: now + 60_000 }
  const service = new ClaudeUsageService({
    cachePath: join(dir, 'claude.json'), visible: () => true, changed: () => {}, now: () => now, credentials: async () => credentials, desktop: async () => null,
    renew: async () => { renewals++; await renew() },
    fetchJson: async url => { calls++; return url.endsWith('/profile') ? {} : usage },
  })
  t.after(() => service.stop())
  await service.refresh()
  assert.equal(service.state.status, 'ready')
  now += 120_000
  calls = 0
  await service.refresh()
  assert.equal(renewals, 1) // renewal failed, so the cached numbers stay
  assert.equal(calls, 0)
  assert.equal(service.state.status, 'cached')
  assert.match(service.state.message ?? '', /expired/)
  now += 120_000
  renew = async () => { credentials = { ...credentials, accessToken: 't2', expiresAt: now + 3_600_000 } } // claude CLI renewed it
  await service.refresh()
  assert.equal(renewals, 2)
  assert.equal(service.state.status, 'ready')
  now += 120_000
  await service.refresh() // valid token: no renewal
  assert.equal(renewals, 2)
})
test('falls back to Claude Desktop usage when the CLI cannot renew', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'agentcord-claude-'))
  t.after(() => rm(dir, { recursive: true, force: true }))
  const now = 1_800_000_000_000
  let renewals = 0
  const service = new ClaudeUsageService({
    cachePath: join(dir, 'claude.json'), visible: () => true, changed: () => {}, now: () => now,
    credentials: async () => ({ accessToken: 'old', key: 'a', expiresAt: now - 1 }),
    renew: async () => { renewals++ },
    desktop: async () => ({ at: now - 60_000, org: 'o', fiveHour: 2, weekly: 20 }),
    fetchJson: async () => { throw new Error('no network for Desktop usage') },
  })
  t.after(() => service.stop())
  await service.refresh()
  assert.equal(service.state.status, 'ready')
  assert.deepEqual(service.state.snapshot?.windows.map(w => [w.id, w.usedPercent, w.resetsAt]), [['claude-session', 2, null], ['claude-weekly', 20, null]])
  assert.equal(renewals, 1)
})
test('Desktop samples older than their window are dropped', () => {
  const sample = { at: 0, org: 'o', fiveHour: 5, weekly: 9 }
  assert.deepEqual(desktopWindows(sample, 400 * 60_000).map(w => w.id), ['claude-weekly'])
  assert.throws(() => desktopWindows(sample, 8 * 86_400_000))
  assert.throws(() => desktopWindows(null, 0))
})
