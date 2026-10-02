import { readFile, mkdir, writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { resolve } from 'node:path'

// One source of truth: use the exact PNG frames already embedded in the
// Windows ICO. No new artwork, conversion dependency, or committed duplicates.
export async function prepareAssets() {
  const source = new URL('../../windows/assets/agentcord.ico', import.meta.url)
  const destination = new URL('../out/assets/', import.meta.url)
  const ico = await readFile(source)
  if (ico.length < 6 || ico.readUInt16LE(0) !== 0 || ico.readUInt16LE(2) !== 1) {
    throw new Error('Invalid AgentCord ICO header')
  }
  const count = ico.readUInt16LE(4)
  if (!count || 6 + count * 16 > ico.length) throw new Error('Invalid ICO directory')
  const frames = []
  for (let i = 0; i < count; i++) {
    const entry = 6 + i * 16
    const size = ico.readUInt32LE(entry + 8)
    const offset = ico.readUInt32LE(entry + 12)
    if (offset < 6 + count * 16 || offset + size > ico.length) throw new Error('Invalid ICO frame bounds')
    const png = ico.subarray(offset, offset + size)
    if (png.subarray(0, 8).toString('hex') !== '89504e470d0a1a0a') continue
    frames.push({ width: ico[entry] || 256, png })
  }
  frames.sort((a, b) => b.width - a.width)
  const largest = frames[0]
  const normal = frames.find(frame => frame.width === 16)
  const retina = frames.find(frame => frame.width === 32)
  if (!largest || !normal || !retina) throw new Error('AgentCord ICO must contain PNG frames at 16px and 32px')
  await mkdir(destination, { recursive: true })
  await Promise.all([
    writeFile(new URL('agentcord.ico', destination), ico),
    writeFile(new URL('agentcord.png', destination), largest.png),
    writeFile(new URL('agentcord-tray.png', destination), normal.png),
    writeFile(new URL('agentcord-tray@2x.png', destination), retina.png),
  ])
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  await prepareAssets()
}
