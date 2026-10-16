import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm, readFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { MuseUsageService, parseMuseUsage } from '../src/main/muse-usage.ts'

// Shape of POST https://api.meta.ai/muse-code/key (the inference key and payment fields are ignored).
const response = {
  api_key: 'LLM|ignored', payment_method: { brand: 'visa', last4: '0000' },
  is_subs_active: true, subs_tier_name: 'Muse Code Power Usage', user_email: 'a@b.invalid',
  subs_usage: {
    window: { used_percent: 25, resets_at: 1_800_000_000, window_duration_mins: 300 },
    weekly: { used_percent: 95, resets_at: 1_800_300_000 },
  },
}
test('parses the 5-hour and weekly windows, plan and email', () => {
  const { email, plan, windows: [session, weekly] } = parseMuseUsage(response)
  assert.equal(email, 'a@b.invalid')
  assert.equal(plan, 'Power Usage')
  assert.deepEqual(session, { id: 'muse-session', label: '5-hour session', usedPercent: 25, durationMinutes: 300, resetsAt: 1_800_000_000_000, severity: 'normal' })
  assert.equal(weekly.severity, 'critical')
  assert.equal(weekly.resetsAt, 1_800_300_000_000)
})
test('missing data is an error, never 0% usage', () => {
  assert.throws(() => parseMuseUsage({ ...response, is_subs_active: false }), /No Muse Code subscription/)
  assert.throws(() => parseMuseUsage({ ...response, require_payment: true }), /payment method/)
  // Idle 5-hour window: valid login with plan, but no windows.
  assert.deepEqual(parseMuseUsage({ ...response, subs_usage: null }), { email: 'a@b.invalid', plan: 'Power Usage', windows: [] })
  assert.throws(() => parseMuseUsage({ ...response, subs_usage: { window: { used_percent: 'x' } } }), /valid usage/)
  assert.equal(parseMuseUsage({ ...response, subs_usage: { weekly: { used_percent: 10 } } }).windows.length, 1)
})
test('cache drops email and api key; logout drops old data', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'agentcord-muse-'))
  t.after(() => rm(dir, { recursive: true, force: true }))
  const cachePath = join(dir, 'muse.json')
  let credentials: { accessToken: string; key: string } | null = { accessToken: 't', key: 'a' }
  let now = 1_800_000_000_000
  let body: unknown = response
  const service = new MuseUsageService({
    cachePath, visible: () => true, changed: () => {}, now: () => now, credentials: async () => credentials, fetchJson: async () => body,
  })
  t.after(() => service.stop())
  await service.refresh()
  assert.equal(service.state.status, 'ready')
  assert.equal(service.state.snapshot?.email, 'a@b.invalid')
  const cached = await readFile(cachePath, 'utf8')
  assert.equal(JSON.parse(cached).snapshot.email, null)
  assert.doesNotMatch(cached, /LLM|last4/)
  now += 60_000
  body = { ...response, subs_usage: undefined } // Window went idle.
  await service.refresh()
  assert.equal(service.state.status, 'ready')
  assert.equal(service.state.snapshot?.plan, 'Power Usage')
  assert.deepEqual(service.state.snapshot?.windows, [])
  assert.match(service.state.message ?? '', /5-hour window is active/)
  await assert.rejects(readFile(cachePath)) // Stale window numbers are not kept.
  now += 60_000
  credentials = null
  await service.refresh()
  assert.equal(service.state.status, 'signed-out')
  assert.equal(service.state.snapshot, null)
  await assert.rejects(readFile(cachePath))
})
