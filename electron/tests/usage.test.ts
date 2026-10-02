import test, { type TestContext } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { CodexUsageService, readIdentity, MIN_REFRESH_INTERVAL, MAX_CACHE_AGE, POLL_INTERVAL, type Identity } from '../src/main/codex-usage.ts'
import { parseRateLimits } from '../src/main/codex-parser.ts'

const usage = parseRateLimits({ rateLimits: { planType: 'plus', primary: { usedPercent: 30, windowDurationMins: 300 } } })
const response = { account: { type: 'chatgpt', email: 'test@example.invalid', plan: 'plus' }, usage }
async function fixture(t: TestContext) {
  const dir = await mkdtemp(join(tmpdir(), 'agentcord-test-'))
  t.after(() => rm(dir, { recursive: true, force: true }))
  let now = 1_800_000_000_000
  let identity: Identity = { kind: 'chatgpt', key: 'account-a' }
  let visible = true
  let probes = 0
  let fail = false
  let duringProbe: (() => void) | undefined
  const services: CodexUsageService[] = []
  const cachePath = join(dir, 'usage.json')
  function create() {
    const service = new CodexUsageService({ cachePath, visible: () => visible, changed: () => {}, now: () => now,
      identity: async () => identity, executable: async () => 'fake-codex',
      probe: async () => { probes++; duringProbe?.(); if (fail) throw new Error('Offline'); return response },
    })
    services.push(service)
    return service
  }
  t.after(() => services.forEach(service => service.stop()))
  return { create, cachePath, dir,
    advance: (ms: number) => { now += ms },
    switchAccount: (value: Identity) => { identity = value },
    hidden: () => { visible = false }, fail: () => { fail = true },
    duringProbe: (callback: () => void) => { duringProbe = callback },
    probes: () => probes,
  }
}

test('successful fetch is cached without email or credentials; refresh is deduplicated and throttled', async t => {
  const f = await fixture(t)
  const service = f.create()
  await service.start()
  assert.equal(service.state.status, 'ready')
  const cache = JSON.parse(await readFile(f.cachePath, 'utf8'))
  assert.equal(cache.accountKey, 'account-a')
  assert.equal(cache.snapshot.email, null)
  assert.equal(cache.snapshot.windows[0].usedPercent, 30)
  await service.refresh()
  assert.equal(f.probes(), 1)
  f.advance(MIN_REFRESH_INTERVAL)
  const one = service.refresh()
  const two = service.refresh()
  assert.equal(one, two)
  await one
  assert.equal(f.probes(), 2)
})
test('visible polling waits for the five-minute boundary; reopening does not over-poll', async t => {
  const f = await fixture(t)
  const service = f.create()
  await service.start()
  f.advance(MIN_REFRESH_INTERVAL)
  await service.tick()
  assert.equal(f.probes(), 1)
  f.advance(POLL_INTERVAL - MIN_REFRESH_INTERVAL)
  await service.tick()
  assert.equal(f.probes(), 2)
})
test('same-account relaunch keeps recent cache when probe fails', async t => {
  const f = await fixture(t)
  const service = f.create()
  await service.start()
  service.stop()
  f.fail()
  const relaunched = f.create()
  await relaunched.start()
  assert.equal(relaunched.state.status, 'cached')
  assert.equal(relaunched.state.snapshot?.windows[0].usedPercent, 30)
  assert.equal(relaunched.state.snapshot?.email, null)
})
test('old-account cache is rejected on relaunch', async t => {
  const f = await fixture(t)
  await f.create().start()
  f.switchAccount({ kind: 'chatgpt', key: 'account-b' })
  f.fail()
  const service = f.create()
  await service.start()
  assert.equal(service.state.status, 'unavailable')
  assert.equal(service.state.snapshot, null)
  await assert.rejects(readFile(f.cachePath))
})
test('logout and account switching clear cached usage even while hidden', async t => {
  const f = await fixture(t)
  const service = f.create()
  await service.start()
  f.hidden()
  f.advance(MIN_REFRESH_INTERVAL)
  await service.tick()
  assert.equal(f.probes(), 1)
  f.switchAccount({ kind: 'chatgpt', key: 'account-b' })
  await service.tick()
  assert.equal(service.state.snapshot, null)
  assert.equal(f.probes(), 1)
  await assert.rejects(readFile(f.cachePath))
  f.switchAccount({ kind: 'signed-out', key: null })
  await service.tick()
  assert.equal(service.state.status, 'signed-out')
})
test('account switch during a probe cannot publish or persist the old result', async t => {
  const f = await fixture(t)
  f.duringProbe(() => f.switchAccount({ kind: 'chatgpt', key: 'account-b' }))
  const service = f.create()
  await service.start()
  assert.equal(service.state.snapshot, null)
  await assert.rejects(readFile(f.cachePath))
})
test('API-key login never spawns a subscription usage probe', async t => {
  const f = await fixture(t)
  f.switchAccount({ kind: 'api-key', key: null })
  const service = f.create()
  await service.start()
  assert.equal(service.state.status, 'api-key')
  assert.equal(f.probes(), 0)
})
test('cache older than 24 hours is removed on failure and hidden ticks', async t => {
  const f = await fixture(t)
  const service = f.create()
  await service.start()
  f.advance(MAX_CACHE_AGE + 1)
  f.hidden()
  await service.tick()
  assert.equal(service.state.snapshot, null)
  assert.equal(service.state.status, 'unavailable')
  await assert.rejects(readFile(f.cachePath))
})
test('failed refresh clears expired snapshots rather than retaining stale numbers', async t => {
  const f = await fixture(t)
  const service = f.create()
  await service.start()
  f.advance(MAX_CACHE_AGE + 1)
  f.fail()
  await service.refresh()
  assert.equal(service.state.status, 'unavailable')
  assert.equal(service.state.snapshot, null)
  await assert.rejects(readFile(f.cachePath))
})
test('a failed in-flight probe cannot retain a logged-out account', async t => {
  const f = await fixture(t)
  const service = f.create()
  await service.start()
  f.advance(MIN_REFRESH_INTERVAL)
  f.fail()
  f.duringProbe(() => f.switchAccount({ kind: 'signed-out', key: null }))
  await service.refresh()
  assert.equal(service.state.status, 'signed-out')
  assert.equal(service.state.snapshot, null)
  await assert.rejects(readFile(f.cachePath))
})
test('previous display-language cache is rejected on an offline relaunch', async t => {
  const f = await fixture(t)
  const first = f.create()
  await first.start()
  first.stop()
  const cache = JSON.parse(await readFile(f.cachePath, 'utf8'))
  cache.version = 1
  cache.snapshot.windows[0].label = 'Sesi 5 jam'
  await writeFile(f.cachePath, JSON.stringify(cache))
  f.fail()
  const service = f.create()
  await service.start()
  assert.equal(service.state.status, 'unavailable')
  assert.equal(service.state.snapshot, null)
  await assert.rejects(readFile(f.cachePath))
})
test('corrupted cache never reaches the UI', async t => {
  const f = await fixture(t)
  await writeFile(f.cachePath, JSON.stringify({ accountKey: 'account-a', snapshot: { fetchedAt: 1_800_000_000_000, windows: [{ usedPercent: 999 }] } }))
  f.fail()
  const service = f.create()
  await service.start()
  assert.equal(service.state.snapshot, null)
  await assert.rejects(readFile(f.cachePath))
})
test('identity honors auth.json without returning token material', async t => {
  const f = await fixture(t)
  await writeFile(join(f.dir, 'auth.json'), JSON.stringify({ tokens: { account_id: 'a', access_token: 'private', refresh_token: 'private' } }))
  assert.deepEqual(await readIdentity(f.dir), { kind: 'chatgpt', key: 'a' })
  await writeFile(join(f.dir, 'auth.json'), JSON.stringify({ OPENAI_API_KEY: 'private' }))
  assert.deepEqual(await readIdentity(f.dir), { kind: 'api-key', key: null })
  await writeFile(join(f.dir, 'auth.json'), '{')
  assert.deepEqual(await readIdentity(f.dir), { kind: 'signed-out', key: null })
})
