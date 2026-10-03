import test from 'node:test'
import assert from 'node:assert/strict'
import {
  getLaunchAtLogin,
  setLaunchAtLogin,
  startedAtLogin,
  HIDDEN_ARG,
  type LoginItemHost,
} from '../src/main/login-item.ts'

function host(overrides: Partial<LoginItemHost> = {}) {
  const calls: unknown[] = []
  let openAtLogin = false
  const fake: LoginItemHost = {
    platform: 'win32',
    isPackaged: true,
    env: {},
    execPath: 'C:\\Apps\\AgentCord.exe',
    getLoginItemSettings: (options) => {
      calls.push(['get', options])
      return { openAtLogin, wasOpenedAtLogin: false }
    },
    setLoginItemSettings: (settings) => {
      calls.push(['set', settings])
      openAtLogin = settings.openAtLogin
    },
    ...overrides,
  }
  return { fake, calls }
}

test('launch at login is off by default and read from the OS', () => {
  const { fake } = host()
  assert.deepEqual(getLaunchAtLogin(fake), { supported: true, enabled: false })
})
test('enabling registers the hidden launch argument and reads the state back', () => {
  const { fake, calls } = host()
  assert.deepEqual(setLaunchAtLogin(fake, true), {
    supported: true,
    enabled: true,
  })
  assert.deepEqual(calls[0], [
    'set',
    { path: 'C:\\Apps\\AgentCord.exe', args: [HIDDEN_ARG], openAtLogin: true },
  ])
  assert.deepEqual(setLaunchAtLogin(fake, false), {
    supported: true,
    enabled: false,
  })
})
test('portable Windows builds register the launcher, not the temp extraction', () => {
  const { fake, calls } = host({
    env: { PORTABLE_EXECUTABLE_FILE: 'D:\\agentcord-electron.exe' },
  })
  setLaunchAtLogin(fake, true)
  assert.deepEqual(calls[0], [
    'set',
    { path: 'D:\\agentcord-electron.exe', args: [HIDDEN_ARG], openAtLogin: true },
  ])
})
test('macOS uses the default login item without custom path or args', () => {
  const { fake, calls } = host({ platform: 'darwin' })
  setLaunchAtLogin(fake, true)
  assert.deepEqual(calls[0], ['set', { openAtLogin: true }])
})
test('Linux and unpackaged runs are unsupported and never touch the OS', () => {
  for (const overrides of [{ platform: 'linux' as const }, { isPackaged: false }]) {
    const { fake, calls } = host(overrides)
    assert.deepEqual(setLaunchAtLogin(fake, true), {
      supported: false,
      enabled: false,
    })
    assert.deepEqual(getLaunchAtLogin(fake), { supported: false, enabled: false })
    assert.equal(calls.length, 0)
  }
})
test('a login launch is detected by argument or by the macOS flag', () => {
  const { fake } = host()
  assert.equal(startedAtLogin(fake, ['app.exe']), false)
  assert.equal(startedAtLogin(fake, ['app.exe', HIDDEN_ARG]), true)
  const mac = host({
    platform: 'darwin',
    getLoginItemSettings: () => ({ openAtLogin: true, wasOpenedAtLogin: true }),
  })
  assert.equal(startedAtLogin(mac.fake, []), true)
})
