import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { iconFilename } from '../src/main/icon-path.ts'

test('Windows uses native ICO for the tray and app, never the 16px PNG', () => {
  assert.equal(iconFilename('win32', 'tray'), 'agentcord.ico')
  assert.equal(iconFilename('win32', 'app'), 'agentcord.ico')
})
test('non-Windows platforms retain supported PNG icons', () => {
  for (const platform of ['darwin', 'linux'] as const) {
    assert.equal(iconFilename(platform, 'tray'), 'agentcord-tray.png')
    assert.equal(iconFilename(platform, 'app'), 'agentcord.png')
  }
})
test('source ICO provides native sizes for standard and high-DPI trays', () => {
  const ico = readFileSync(new URL('../../windows/assets/agentcord.ico', import.meta.url))
  assert.equal(ico.readUInt16LE(2), 1)
  const sizes = []
  for (let i = 0; i < ico.readUInt16LE(4); i++) {
    const entry = 6 + i * 16
    const size = ico.readUInt32LE(entry + 8)
    const offset = ico.readUInt32LE(entry + 12)
    assert.ok(offset + size <= ico.length)
    sizes.push(ico[entry] || 256)
  }
  for (const size of [16, 32, 64, 128, 256]) assert.ok(sizes.includes(size))
})
