import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises'
import { DatabaseSync } from 'node:sqlite'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createCursorUsage, parseCursorLegacy, parseCursorPeriod, readCursorCredentials } from '../src/main/cursor-usage.ts'
import { createGrokUsage, parseGrokBilling, parseGrokPlan, readGrokCredentials } from '../src/main/grok-usage.ts'

const jwt = (claims: object) => `x.${Buffer.from(JSON.stringify(claims)).toString('base64url')}.y`

test('parses Cursor period usage and legacy request buckets', () => {
  const [included, auto, onDemand] = parseCursorPeriod({
    billingCycleEnd: '1800000000000',
    planUsage: { totalPercentUsed: 75, autoPercentUsed: 20, apiPercentUsed: 75 },
    spendLimitUsage: { individualLimit: 2000, individualRemaining: 500 },
  })!
  assert.equal(included.usedPercent, 75)
  assert.equal(included.severity, 'warning')
  assert.equal(included.resetsAt, 1_800_000_000_000)
  assert.equal(auto.label, 'Auto') // API equals the total, so it is skipped
  assert.equal(onDemand.usedPercent, 75)
  assert.equal(parseCursorPeriod({ planUsage: { limit: 2000, includedSpend: 1000 }, billingCycleEnd: 1_800_000_000 })![0].resetsAt, 1_800_000_000_000)
  assert.equal(parseCursorPeriod({}), null)
  const [legacy] = parseCursorLegacy({ startOfMonth: '2026-10-01T00:00:00Z', 'gpt-4': { numRequests: 450, maxRequestUsage: 500 }, 'gpt-3.5': { numRequests: 1, maxRequestUsage: null } })!
  assert.equal(legacy.usedPercent, 90)
  assert.equal(legacy.resetsAt, Date.parse('2026-11-01T00:00:00Z'))
})
test('picks the Cursor token that expires last and keeps the IDE profile', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'agentcord-cursor-'))
  t.after(() => rm(dir, { recursive: true, force: true }))
  assert.equal(await readCursorCredentials(dir), null)
  await mkdir(join(dir, 'User', 'globalStorage'), { recursive: true })
  const db = new DatabaseSync(join(dir, 'User', 'globalStorage', 'state.vscdb'))
  db.exec('CREATE TABLE ItemTable (key TEXT, value TEXT)')
  const insert = db.prepare('INSERT INTO ItemTable VALUES (?, ?)')
  insert.run('cursorAuth/accessToken', jwt({ sub: 'u1', exp: 100 }))
  insert.run('cursorAuth/cachedEmail', 'a@b.invalid')
  insert.run('cursorAuth/stripeMembershipType', 'pro')
  db.close()
  const ide = await readCursorCredentials(dir)
  assert.equal(ide?.expiresAt, 100_000)
  assert.equal(ide?.email, 'a@b.invalid')
  await writeFile(join(dir, 'auth.json'), JSON.stringify({ accessToken: jwt({ sub: 'u1', exp: 200 }) }))
  const both = await readCursorCredentials(dir)
  assert.equal(both?.expiresAt, 200_000)
  assert.equal(both?.plan, 'pro')
  assert.equal(both?.key, ide?.key) // same account across sources
})
test('Cursor falls back to legacy usage and API profile', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'agentcord-cursor-'))
  t.after(() => rm(dir, { recursive: true, force: true }))
  const urls: string[] = []
  const service = createCursorUsage({
    cachePath: join(dir, 'c.json'), visible: () => true, changed: () => {},
    credentials: async () => ({ accessToken: 't', key: 'k', email: null, plan: null }),
    fetchJson: async url => {
      urls.push(url)
      if (url.endsWith('GetCurrentPeriodUsage')) throw new Error('HTTP 404')
      if (url.endsWith('GetEmail')) return { email: 'a@b.invalid' }
      if (url.endsWith('full_stripe_profile')) return { membershipType: 'ultra' }
      return { 'gpt-4': { numRequests: 5, maxRequestUsage: 10 } }
    },
  })
  t.after(() => service.stop())
  await service.refresh()
  assert.equal(service.state.status, 'ready')
  assert.equal(service.state.snapshot?.plan, 'ultra')
  assert.equal(service.state.snapshot?.windows[0].usedPercent, 50)
  assert.ok(urls.some(url => url.endsWith('/auth/usage')))
})

test('parses Grok billing and plan labels', () => {
  const [weekly, onDemand] = parseGrokBilling({ config: { creditUsagePercent: 95, currentPeriod: { end: '2026-10-20T00:00:00Z' }, onDemandCap: { val: 10 }, onDemandUsed: { val: 2.5 } } })
  assert.equal(weekly.label, 'Weekly credits')
  assert.equal(weekly.severity, 'critical')
  assert.equal(weekly.resetsAt, Date.parse('2026-10-20T00:00:00Z'))
  assert.equal(onDemand.usedPercent, 25)
  assert.equal(parseGrokBilling({ billingPeriodEnd: '2026-10-20T00:00:00Z' })[0].usedPercent, 0) // unified billing
  assert.throws(() => parseGrokBilling({}))
  assert.equal(parseGrokPlan({ subscription_tier_display: ' SuperGrok ' }), 'SuperGrok')
  assert.equal(parseGrokPlan({ subscriptionTier: 'SuperGrokPro' }), 'SuperGrok Heavy')
  assert.equal(parseGrokPlan(null), null)
})
test('reads Grok auth without the refresh token; expired tokens renew through the CLI', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'agentcord-grok-'))
  t.after(() => rm(dir, { recursive: true, force: true }))
  assert.equal(await readGrokCredentials(dir), null)
  let expiresAt = '2026-10-06T00:48:19.889050100Z'
  const write = () => writeFile(join(dir, 'auth.json'), JSON.stringify({ 'https://auth.x.ai::id': { key: 'access', refresh_token: 'r', user_id: 'u', email: 'a@b.invalid', expires_at: expiresAt } }))
  await write()
  const credentials = await readGrokCredentials(dir)
  assert.equal(credentials?.expiresAt, Date.parse('2026-10-06T00:48:19.889Z'))
  assert.equal(JSON.stringify(credentials).includes('"r"'), false)
  let renewals = 0
  const service = createGrokUsage({
    cachePath: join(dir, 'g.json'), visible: () => true, changed: () => {}, now: () => Date.parse('2026-10-16T00:00:00Z'),
    credentials: () => readGrokCredentials(dir),
    renew: async () => { renewals++; expiresAt = '2026-10-16T06:00:00Z'; await write() },
    fetchJson: async url => url.includes('/billing') ? { config: { creditUsagePercent: 12 } } : { subscription_tier_display: 'SuperGrok' },
  })
  t.after(() => service.stop())
  await service.refresh()
  assert.equal(renewals, 1)
  assert.equal(service.state.status, 'ready')
  assert.equal(service.state.snapshot?.email, 'a@b.invalid')
  assert.equal(service.state.snapshot?.plan, 'SuperGrok')
})
