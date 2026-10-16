import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm, readFile, mkdir, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createMuseUsage, parseMuseProfile, parseMuseUsage, readMuseCredentials } from '../src/main/muse-usage.ts'

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
  assert.deepEqual(parseMuseProfile(response), { email: 'a@b.invalid', plan: 'Power Usage' })
  const [session, weekly] = parseMuseUsage(response)
  assert.deepEqual(session, { id: 'muse-session', label: '5-hour session', usedPercent: 25, durationMinutes: 300, resetsAt: 1_800_000_000_000, severity: 'normal' })
  assert.equal(weekly.severity, 'critical')
  assert.equal(weekly.resetsAt, 1_800_300_000_000)
})
test('missing data is an error or idle, never 0% usage', () => {
  assert.throws(() => parseMuseUsage({ ...response, is_subs_active: false }), /No Muse Code subscription/)
  assert.throws(() => parseMuseProfile({ ...response, require_payment: true }), /payment method/)
  assert.deepEqual(parseMuseUsage({ ...response, subs_usage: null }), []) // Idle 5-hour window.
  assert.throws(() => parseMuseUsage({ ...response, subs_usage: { window: { used_percent: 'x' } } }), /valid usage/)
  assert.equal(parseMuseUsage({ ...response, subs_usage: { weekly: { used_percent: 10 } } }).length, 1)
})
test('reads the CLI token and keys the account by email', async t => {
  const home = await mkdtemp(join(tmpdir(), 'agentcord-muse-home-'))
  t.after(() => rm(home, { recursive: true, force: true }))
  assert.equal(await readMuseCredentials(home), null)
  await mkdir(join(home, '.config', 'muse'), { recursive: true })
  await writeFile(join(home, '.config', 'muse', 'auth.json'), JSON.stringify({ providers: { meta: { access_token: 'dca:t', user_email: 'a@b.invalid' } } }))
  const credentials = await readMuseCredentials(home)
  assert.equal(credentials?.accessToken, 'dca:t')
  assert.doesNotMatch(credentials?.key ?? '', /a@b/)
})
test('idle window keeps the plan with no windows; cache never holds the key', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'agentcord-muse-'))
  t.after(() => rm(dir, { recursive: true, force: true }))
  const cachePath = join(dir, 'muse.json')
  let now = 1_800_000_000_000
  let body: unknown = response
  const service = createMuseUsage({
    cachePath, visible: () => true, changed: () => {}, now: () => now,
    credentials: async () => ({ accessToken: 't', key: 'a' }), fetchJson: async () => body,
  })
  t.after(() => service.stop())
  await service.refresh()
  assert.equal(service.state.status, 'ready')
  assert.equal(service.state.snapshot?.windows.length, 2)
  assert.doesNotMatch(await readFile(cachePath, 'utf8'), /LLM|last4|a@b/)
  now += 60_000
  body = { ...response, subs_usage: undefined }
  await service.refresh()
  assert.equal(service.state.status, 'ready')
  assert.equal(service.state.snapshot?.plan, 'Power Usage')
  assert.deepEqual(service.state.snapshot?.windows, [])
})
