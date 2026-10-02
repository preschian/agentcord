import test from 'node:test'
import assert from 'node:assert/strict'
import { parseRateLimits, parseAccount } from '../src/main/codex-parser.ts'

const window = { usedPercent: 22.5, windowDurationMins: 300, resetsAt: 1_800_000_000 }
test('parses primary/secondary, thresholds, Unix timestamps, credits and plan', () => {
  const result = parseRateLimits({ rateLimits: {
    planType: 'plus', primary: window,
    secondary: { usedPercent: 71, windowDurationMins: 10080, resetsAt: 1_800_000_000_000 },
    credits: { balance: '10.50', unlimited: false, hasCredits: true },
  } })
  assert.equal(result.plan, 'plus')
  assert.equal(result.windows[0].usedPercent, 22.5)
  assert.equal(result.windows[0].resetsAt, 1_800_000_000_000)
  assert.equal(result.windows[0].label, '5-hour session')
  assert.equal(result.windows[1].label, 'Weekly limit')
  assert.equal(result.windows[1].severity, 'warning')
  assert.equal(result.windows[1].resetsAt, 1_800_000_000_000)
  assert.equal(result.credits?.balance, '10.50')
})
test('by-ID fallback, deduplication, additional windows and reached flags', () => {
  const main = { limitId: 'codex', primary: window }
  const result = parseRateLimits({ rateLimitsByLimitId: {
    codex: main,
    codex_other: { limitName: 'Codex Other', primary: { ...window, usedPercent: 92 }, secondary: window },
    broken: null,
  } })
  assert.equal(result.windows.length, 3)
  assert.equal(result.windows[1].severity, 'critical')
  assert.equal(result.windows[1].label, 'Codex Other · 5-hour session')
  assert.equal(parseRateLimits({ rateLimits: { ...main, rateLimitReachedType: 'primary' } }).windows[0].severity, 'critical')
  const custom = { limitId: 'custom', primary: window }
  assert.equal(parseRateLimits({ rateLimits: custom, rateLimitsByLimitId: { custom, codex: main } }).windows.length, 1)
})
test('clamps percentages, preserves absent reset, and labels actual duration', () => {
  const result = parseRateLimits({ rateLimits: {
    primary: { usedPercent: -4, windowDurationMins: 60 }, secondary: { usedPercent: 112, resetsAt: null },
  } })
  assert.equal(result.windows[0].usedPercent, 0)
  assert.equal(result.windows[0].label, '1-hour limit')
  assert.equal(result.windows[0].resetsAt, null)
  assert.equal(result.windows[1].usedPercent, 100)
})
test('missing/invalid usage is never invented as zero percent', () => {
  for (const value of [null, {}, { rateLimits: { primary: {} } }, { rateLimits: { primary: { usedPercent: '20' } } }, { rateLimits: { primary: { usedPercent: NaN } } }]) {
    assert.throws(() => parseRateLimits(value))
  }
})
test('reads only account display fields and handles missing account', () => {
  assert.deepEqual(parseAccount({ account: { type: 'chatgpt', email: 'test@example.invalid', planType: 'pro', secret: 'not exposed' } }), {
    type: 'chatgpt', email: 'test@example.invalid', plan: 'pro',
  })
  assert.deepEqual(parseAccount({ account: null }), { type: null, email: null, plan: null })
})
