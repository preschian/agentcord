import test from 'node:test'
import assert from 'node:assert/strict'
import { ClaudeDesktopService, isClaudeDesktopRunning, matchesWindowsDesktop } from '../src/main/claude-desktop.ts'

test('macOS matches the Claude.app main process only', async () => {
  const calls: string[][] = []
  assert.equal(await isClaudeDesktopRunning('darwin', async (file, args) => { calls.push([file, ...args]); return '4242\n' }), true)
  assert.deepEqual(calls, [['pgrep', '-f', 'Claude\\.app/Contents/MacOS/Claude$']])
  assert.equal(await isClaudeDesktopRunning('darwin', async () => ''), false)
  // pgrep exits 1 when nothing matches.
  assert.equal(await isClaudeDesktopRunning('darwin', async () => { throw new Error('exit 1') }), false)
})

test('Windows matches Claude Desktop install paths but not the Claude Code CLI', async () => {
  assert.equal(matchesWindowsDesktop('C:\\Users\\a\\AppData\\Local\\AnthropicClaude\\app-1.0.0\\claude.exe\r\n'), true)
  assert.equal(matchesWindowsDesktop('C:\\Program Files\\WindowsApps\\Claude_1.0.0.0_x64__abc\\app\\Claude.exe'), true)
  assert.equal(matchesWindowsDesktop('C:\\Users\\a\\.local\\bin\\claude.exe\r\n'), false)
  assert.equal(matchesWindowsDesktop(''), false)
  assert.equal(await isClaudeDesktopRunning('win32', async () => 'C:\\Users\\a\\.local\\bin\\claude.exe'), false)
  assert.equal(await isClaudeDesktopRunning('win32', async () => { throw new Error('no powershell') }), false)
})

test('other platforms never report Claude Desktop', async () => {
  let ran = false
  assert.equal(await isClaudeDesktopRunning('linux', async () => { ran = true; return 'x' }), false)
  assert.equal(ran, false)
})

test('service only scans when needed and reports changes once', async () => {
  let needed = false, running = true, scans = 0
  const changes: boolean[] = []
  const service = new ClaudeDesktopService({
    needed: () => needed,
    changed: (a) => changes.push(a),
    detect: async () => { scans++; return running },
  })
  await service.tick()
  assert.equal(scans, 0, 'idle stays idle')
  needed = true
  await Promise.all([service.tick(), service.tick()])
  assert.equal(scans, 1, 'concurrent ticks share one scan')
  await service.tick()
  assert.deepEqual(changes, [true], 'unchanged result is not re-reported')
  running = false
  await service.tick()
  assert.deepEqual(changes, [true, false])
  assert.equal(service.active, false)
  service.stop()
  running = true
  await service.tick()
  assert.deepEqual(changes, [true, false], 'stopped service does not scan')
})
