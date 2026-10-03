import type { BrowserWindow } from 'electron'
import { app, nativeImage, Tray } from 'electron'
import assert from 'node:assert/strict'
import { writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import type { UsageState } from '../shared/types'
import { iconFilename } from './icon-path'
import { materialSymbols } from '../renderer/icon-names'

export async function runSmokeTest(
  window: BrowserWindow,
  state: UsageState,
): Promise<void> {
  const pause = () => new Promise((resolve) => setTimeout(resolve, 250))
  const evaluate = (code: string) => window.webContents.executeJavaScript(code)
  const capture = async (suffix: string) => {
    const path = join(
      app.getPath('temp'),
      `agentcord-electron-smoke${suffix}.png`,
    )
    await writeFile(path, (await window.webContents.capturePage()).toPNG())
    return path
  }
  const fontLoaded = await evaluate(`(async () => {
    const weights = await Promise.all([400, 500, 600].map(weight =>
      document.fonts.load(weight + ' 13px "Noto Sans Mono Variable"', 'agentcord 0123456789 •')
    ));
    await document.fonts.ready;
    return weights.every(faces => faces.length > 0 && faces.every(face => face.status === 'loaded'));
  })()`)
  assert.equal(
    fontLoaded,
    true,
    'Bundled Noto Sans Mono must load at all UI weights',
  )
  const symbolsLoaded = await evaluate(`(async () => {
    const names = ${JSON.stringify(Object.values(materialSymbols))};
    const faces = await document.fonts.load('400 20px "Material Symbols Rounded Variable"', names.join(' '));
    const context = document.createElement('canvas').getContext('2d');
    context.font = '400 20px "Material Symbols Rounded Variable"';
    // A supported ligature renders as one square glyph, not a row of letters.
    return faces.length > 0 && faces.every(face => face.status === 'loaded')
      && names.every(name => context.measureText(name).width <= 21);
  })()`)
  assert.equal(
    symbolsLoaded,
    true,
    'Every UI symbol must resolve to a bundled Google icon',
  )
  await pause()
  const renderer = await evaluate(`({
    title: document.querySelector('h1')?.textContent,
    language: document.documentElement.lang,
    bridge: typeof window.agentcord?.refreshUsage,
    isolated: typeof window.require === 'undefined' && typeof window.process === 'undefined',
    width: window.innerWidth,
    logoLoaded: document.querySelector('.brand-mark')?.naturalWidth === 256,
    fontFamily: getComputedStyle(document.querySelector('.popover')).fontFamily,
    iconFamily: getComputedStyle(document.querySelector('.material-icon')).fontFamily
  })`)
  assert.equal(renderer.title, 'agentcord')
  assert.equal(renderer.language, 'en')
  assert.equal(renderer.bridge, 'function')
  assert.equal(renderer.isolated, true)
  assert.equal(renderer.width, 330)
  assert.equal(renderer.logoLoaded, true)
  assert.ok(renderer.fontFamily.startsWith('"Noto Sans Mono Variable"'))
  assert.equal(renderer.iconFamily, '"Material Symbols Rounded Variable"')
  for (const role of ['app', 'tray'] as const) {
    const path = join(
      __dirname,
      '../assets',
      iconFilename(process.platform, role),
    )
    assert.equal(nativeImage.createFromPath(path).isEmpty(), false)
  }
  // Exercise actual native tray construction, not just PNG decoding. In a
  // packaged Windows smoke test this also covers the ICO-inside-ASAR path.
  const trayPath = join(
    __dirname,
    '../assets',
    iconFilename(process.platform, 'tray'),
  )
  const nativeTray = new Tray(trayPath)
  try {
    assert.equal(nativeTray.isDestroyed(), false)
    nativeTray.setImage(trayPath)
  } finally {
    nativeTray.destroy()
  }
  const mainHeight = window.getBounds().height
  const screenshots = [await capture('')]
  await evaluate(`document.querySelector('[data-open-codex]').click()`)
  await pause()
  assert.equal(
    await evaluate(`document.querySelector('h1').textContent`),
    'Codex',
  )
  assert.equal(
    await evaluate(`document.querySelectorAll('[data-usage-card]').length`),
    state.snapshot?.windows.length ?? 0,
  )
  if (state.snapshot?.email) {
    assert.equal(
      await evaluate(
        `!!document.querySelector('button[aria-label="Show email"]')`,
      ),
      true,
    )
    await evaluate(
      `document.querySelector('button[aria-label="Show email"]').click()`,
    )
    await pause()
    assert.equal(
      await evaluate(
        `!!document.querySelector('button[aria-label="Hide email"]')`,
      ),
      true,
    )
    await evaluate(`document.querySelector('[data-back]').click()`)
    await pause()
    await evaluate(`document.querySelector('[data-open-codex]').click()`)
    await pause()
    const reopened = await evaluate(`({
      screen: document.querySelector('.popover')?.dataset.screen,
      title: document.querySelector('h1')?.textContent,
      emailAction: document.querySelector('.account-button')?.getAttribute('aria-label')
    })`)
    assert.equal(reopened.emailAction, 'Show email', JSON.stringify(reopened))
  }
  await evaluate(`document.dispatchEvent(new Event('visibilitychange'))`)
  await pause()
  assert.equal(
    await evaluate(`document.querySelector('h1').textContent`),
    'Codex',
    'Occlusion changes must not reset the current screen',
  )
  screenshots.push(await capture('-detail'))
  await evaluate(
    `document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))`,
  )
  await pause()
  assert.equal(
    await evaluate(`document.querySelector('h1').textContent`),
    'agentcord',
  )
  await evaluate(`document.querySelector('[data-open-settings]').click()`)
  await pause()
  assert.equal(
    await evaluate(`document.querySelector('h1').textContent`),
    'Settings',
  )
  assert.ok(
    window.getBounds().height > mainHeight,
    'Settings must grow the popover',
  )
  // Smoke runs unpackaged, so the OS login item is unsupported and untouched.
  assert.deepEqual(await evaluate(`window.agentcord.getLaunchAtLogin()`), {
    supported: false,
    enabled: false,
  })
  assert.equal(
    await evaluate(`document.querySelector('[data-launch-at-login]') === null`),
    true,
  )
  screenshots.push(await capture('-settings'))
  await evaluate(`document.querySelector('[aria-expanded]').click()`)
  await pause()
  assert.equal(await evaluate(`document.querySelectorAll('dd').length`), 4)
  await evaluate(`document.querySelector('[data-back]').click()`)
  await pause()
  assert.equal(window.getBounds().height, mainHeight)
  window.webContents.send('usage:changed', {
    ...state,
    status: 'signed-out',
    snapshot: null,
    refreshing: false,
    message: 'Run codex login, then refresh to see your ChatGPT usage.',
  })
  await pause()
  await evaluate(`document.querySelector('[data-open-codex]').click()`)
  await pause()
  assert.equal(
    await evaluate(`document.querySelector('.login-help code')?.textContent`),
    'codex login',
  )
  assert.equal(
    await evaluate(`document.querySelectorAll('[data-usage-card]').length`),
    0,
  )
  if (state.snapshot) {
    window.webContents.send('usage:changed', {
      ...state,
      status: 'cached',
      refreshing: false,
      message: 'Could not refresh. Showing cached usage.',
    })
    await pause()
    assert.equal(
      await evaluate(
        `document.querySelector('.usage-summary small')?.textContent`,
      ),
      'cached',
    )
    assert.equal(
      await evaluate(`document.querySelectorAll('[data-usage-card]').length`),
      state.snapshot.windows.length,
    )
  }
  window.webContents.send('usage:changed', state)
  await evaluate(`document.querySelector('[data-back]').click()`)
  await pause()
  await evaluate(`document.querySelector('[data-open-codex]').click()`)
  await pause()
  window.hide()
  window.show()
  await pause()
  assert.equal(
    await evaluate(`document.querySelector('h1').textContent`),
    'agentcord',
    'A native reopen must return to the main screen',
  )
  // Exercise the rejected IPC input path without allowing arbitrary bounds.
  assert.equal(
    await evaluate(
      `window.agentcord.resizeWindow(-1).then(() => false, () => true)`,
    ),
    true,
  )
  console.log(
    JSON.stringify({
      status: state.status,
      windows: state.snapshot?.windows.length ?? 0,
      renderer,
      screens: 3,
      screenshots,
    }),
  )
}
