import test from 'node:test'
import assert from 'node:assert/strict'
import { materialSymbols } from '../src/renderer/icon-names.ts'

test('all current UI actions map to Google Material Symbols', () => {
  assert.deepEqual(materialSymbols, {
    arrow: 'chevron_right',
    settings: 'settings',
    eye: 'visibility',
    'eye-off': 'visibility_off',
    clock: 'schedule',
    refresh: 'refresh',
    hide: 'dock_to_right',
  })
})
test('icon mapping is a UI-only set; AgentCord branding remains separate', () => {
  assert.equal(Object.values(materialSymbols).length, 7)
  assert.ok(
    Object.values(materialSymbols).every((name) => /^[a-z_]+$/.test(name)),
  )
  assert.equal('logo' in materialSymbols, false)
})
