import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { ClaudeUsageState, PresenceState, UsageSnapshot, UsageState } from '../src/shared/types.ts'
import type { Activity, DiscordConnection } from '../src/main/discord-ipc.ts'
import { buildActivity, PresenceService, readPresenceEnabled } from '../src/main/presence.ts'

const snapshot = (percent: number): UsageSnapshot => ({
  email: 'someone@example.com',
  plan: 'pro',
  credits: { balance: '9.00', unlimited: false, hasCredits: true },
  fetchedAt: 1,
  windows: [{ id: 'a', label: '5-hour', usedPercent: percent, resetsAt: null, durationMinutes: 300, severity: 'normal' }],
})
const claude = (status: ClaudeUsageState['status'], percent: number | null): ClaudeUsageState => ({
  status, snapshot: percent === null ? null : snapshot(percent), refreshing: false, message: null, nextRefreshAt: 0,
})
const codex = (status: UsageState['status'], percent: number | null): UsageState => ({
  ...claude(status, percent), codexHome: '', executable: null,
})

test('activity shows rounded used percentages per provider', () => {
  const activity = buildActivity(codex('ready', 46.4), claude('ready', 12.6))!
  assert.equal(activity.details, 'Subscription usage')
  assert.equal(activity.state, 'Claude 13% used · Codex 46% used')
  assert.equal(activity.assets?.large_image, 'discord-presence-icon')
  assert.equal(buildActivity(null, claude('ready', 5))!.state, 'Claude 5% used')
})

test('activity never carries account details', () => {
  const text = JSON.stringify(buildActivity(codex('ready', 1), claude('ready', 2)))
  for (const secret of ['example.com', '"pro"', '9.00']) assert.ok(!text.includes(secret), secret)
})

test('cached, signed-out or empty usage is not advertised', () => {
  assert.equal(buildActivity(codex('cached', 40), claude('cached', 40)), null)
  assert.equal(buildActivity(codex('signed-out', null), claude('loading', null)), null)
  assert.equal(buildActivity(null, null), null)
  assert.equal(buildActivity(codex('cached', 40), claude('ready', 7))!.state, 'Claude 7% used')
})

test('Claude Desktop being active changes the headline and needs no usage', () => {
  const both = buildActivity(codex('ready', 46), claude('ready', 13), true)!
  assert.equal(both.details, 'Using Claude Desktop')
  assert.equal(both.state, 'Claude 13% used · Codex 46% used')
  const bare = buildActivity(null, null, true)!
  assert.equal(bare.details, 'Using Claude Desktop')
  assert.equal(bare.state, undefined)
  assert.equal(buildActivity(null, null, false), null)
  assert.equal(buildActivity(null, claude('ready', 5))!.details, 'Subscription usage')
})

class FakeIpc {
  state: DiscordConnection = 'disconnected'
  calls: string[] = []
  activity: Activity | null | undefined
  constructor(readonly onState: (s: DiscordConnection) => void) {}
  start() { this.calls.push('start'); this.state = 'connecting'; this.onState(this.state) }
  stop() { this.calls.push('stop'); this.state = 'disconnected'; this.onState(this.state) }
  setActivity(activity: Activity | null) { this.activity = activity }
  connect() { this.state = 'connected'; this.onState(this.state) }
}
async function setup(initial?: unknown) {
  const dir = await mkdtemp(join(tmpdir(), 'agentcord-presence-'))
  const settingsPath = join(dir, 'settings.json')
  if (initial !== undefined) await writeFile(settingsPath, typeof initial === 'string' ? initial : JSON.stringify(initial))
  const states: PresenceState[] = []
  let ipc!: FakeIpc
  const service = new PresenceService({
    settingsPath,
    changed: (s) => states.push(s),
    createIpc: (onState) => (ipc = new FakeIpc(onState)) as never,
  })
  return { service, ipc, states, settingsPath, cleanup: () => rm(dir, { recursive: true, force: true }) }
}

test('presence is disabled by default and never connects until enabled', async () => {
  const t = await setup()
  try {
    await t.service.start()
    t.service.update({ claude: claude('ready', 10) })
    assert.deepEqual(t.service.state, { enabled: false, status: 'off' })
    assert.deepEqual(t.ipc.calls, [])
    assert.equal(t.ipc.activity, undefined)
  } finally { await t.cleanup() }
})

test('malformed settings fall back to disabled', async () => {
  const t = await setup('{not json')
  try {
    assert.equal(await readPresenceEnabled(t.settingsPath), false)
    await t.service.start()
    assert.equal(t.service.state.enabled, false)
  } finally { await t.cleanup() }
})

test('enabling persists, connects, and reports connection status', async () => {
  const t = await setup()
  try {
    t.service.update({ claude: claude('ready', 10) })
    assert.deepEqual(await t.service.setEnabled(true), { enabled: true, status: 'waiting' })
    assert.deepEqual(t.ipc.calls, ['start'])
    assert.equal(t.ipc.activity?.state, 'Claude 10% used')
    assert.equal(JSON.parse(await readFile(t.settingsPath, 'utf8')).presenceEnabled, true)
    t.ipc.connect()
    assert.deepEqual(t.service.state, { enabled: true, status: 'connected' })
    t.service.update({ claude: claude('ready', 20) })
    assert.equal(t.ipc.activity?.state, 'Claude 20% used')
    assert.deepEqual(t.states.map((s) => s.status), ['waiting', 'connected'])
  } finally { await t.cleanup() }
})

test('presence follows Claude Desktop activity while enabled', async () => {
  const t = await setup()
  try {
    await t.service.setEnabled(true)
    t.service.update({ claudeActive: true })
    assert.equal(t.ipc.activity?.details, 'Using Claude Desktop')
    t.service.update({ claudeActive: false })
    assert.equal(t.ipc.activity, null)
  } finally { await t.cleanup() }
})

test('disabling clears the presence and disconnects', async () => {
  const t = await setup({ presenceEnabled: true })
  try {
    await t.service.start()
    assert.equal(t.service.state.enabled, true)
    assert.deepEqual(await t.service.setEnabled(false), { enabled: false, status: 'off' })
    assert.deepEqual(t.ipc.calls, ['start', 'stop'])
    assert.equal(await readPresenceEnabled(t.settingsPath), false)
    t.service.update({ claude: claude('ready', 50) })
    assert.deepEqual(t.service.state, { enabled: false, status: 'off' })
  } finally { await t.cleanup() }
})

test('a Discord that goes away shows as waiting and returns to connected', async () => {
  const t = await setup({ presenceEnabled: true })
  try {
    await t.service.start()
    t.ipc.connect()
    t.ipc.state = 'disconnected'; t.ipc.onState('disconnected')
    assert.equal(t.service.state.status, 'waiting')
    t.ipc.connect()
    assert.equal(t.service.state.status, 'connected')
  } finally { await t.cleanup() }
})
