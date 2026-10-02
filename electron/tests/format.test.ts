import test from 'node:test'
import assert from 'node:assert/strict'
import { ago, maskEmail, resetIn, windowValue } from '../src/renderer/format.ts'

const now = 1_800_000_000_000
test('reset countdown matches Windows units and boundary behavior', () => {
  assert.equal(resetIn(now - 1, now), 'now')
  assert.equal(resetIn(now + 1, now), '<1m')
  assert.equal(resetIn(now + 45 * 60_000, now), '45m')
  assert.equal(resetIn(now + 137 * 60_000, now), '2h 17m')
  assert.equal(resetIn(now + (6 * 24 + 22) * 3600_000, now), '6d 22h')
})
test('usage values match Windows rows rather than dashboard cards', () => {
  const window = {
    id: 'codex-primary',
    label: '5-hour session',
    usedPercent: 46,
    resetsAt: null,
    durationMinutes: 300,
    severity: 'normal' as const,
  }
  assert.equal(windowValue(window, now), '46%')
  assert.equal(
    windowValue({ ...window, resetsAt: now }, now),
    '46% · resets now',
  )
  assert.equal(
    windowValue({ ...window, resetsAt: now + 60_000 }, now),
    '46% · 1m',
  )
})
test('email masking matches the Windows detail view', () => {
  assert.equal(maskEmail('pres@example.com'), 'p•••@e••••••.com')
  assert.equal(maskEmail('a@b.io'), 'a•••@b••.io')
  assert.equal(maskEmail('abc@localhost'), 'a•••@•••••••••')
  assert.equal(maskEmail('invalid'), '•••••••')
  assert.equal(maskEmail('@.com'), '•••@••.com')
})
test('freshness labels use English and clamp future timestamps', () => {
  assert.equal(ago(now + 1000, now), 'just now')
  assert.equal(ago(now - 5 * 60_000, now), '5m ago')
  assert.equal(ago(now - 2 * 3600_000, now), '2h ago')
  assert.equal(ago(now - 3 * 86400_000, now), '3d ago')
})
