import {
  app,
  BrowserWindow,
  ipcMain,
  Menu,
  Tray,
  nativeImage,
  nativeTheme,
  screen,
} from 'electron'
import { join } from 'node:path'
import { CodexUsageService } from './codex-usage'
import { ClaudeUsageService } from './claude-usage'
import { PresenceService } from './presence'
import { runSmokeTest } from './smoke'
import {
  getLaunchAtLogin,
  setLaunchAtLogin,
  startedAtLogin,
  type LoginItemHost,
} from './login-item'
import { iconFilename, type IconRole } from './icon-path'

const POPOVER_WIDTH = 330
const loginItemHost: LoginItemHost = {
  get platform() {
    return process.platform
  },
  get isPackaged() {
    return app.isPackaged
  },
  env: process.env,
  execPath: process.execPath,
  getLoginItemSettings: (options) => app.getLoginItemSettings(options),
  setLoginItemSettings: (settings) => app.setLoginItemSettings(settings),
}
let window: BrowserWindow | null = null
let tray: Tray | null = null
let service: CodexUsageService | null = null
let claude: ClaudeUsageService | null = null
let presence: PresenceService | null = null
let quitting = false
let anchored = true
let lastDeactivated = 0
const smoke = process.argv.includes('--smoke-test')
if (smoke)
  app.setPath('userData', join(app.getPath('temp'), 'agentcord-electron-smoke'))
const locked = smoke || app.requestSingleInstanceLock()
if (!locked) app.quit()
else {
  app.on('second-instance', () => {
    void showWindow()
  })
  app.on('before-quit', () => {
    quitting = true
    service?.stop()
    claude?.stop()
    presence?.stop()
  })
  app.on('window-all-closed', () => {
    if (quitting) app.quit()
  })
  app.on('activate', () => {
    void showWindow()
  })
  void app
    .whenReady()
    .then(start)
    .catch((error: unknown) => {
      console.error(
        error instanceof Error
          ? smoke
            ? error.stack
            : error.message
          : 'AgentCord startup failed',
      )
      app.exit(1)
    })
}
async function showWindow(): Promise<void> {
  // Check identity before revealing potentially cached account data.
  await Promise.all([service?.tick(), claude?.tick()])
  window?.show()
  window?.focus()
  if (
    service &&
    (!service.state.snapshot ||
      Date.now() - service.state.snapshot.fetchedAt >= 5 * 60_000)
  ) {
    void service.refresh()
  }
}
function resizePopover(height: number): void {
  if (!window) return
  const current = window.getBounds()
  const area = screen.getDisplayMatching(current).workArea
  const clamped = Math.min(Math.max(160, height), area.height - 4)
  window.setBounds({
    width: POPOVER_WIDTH,
    height: clamped,
    x: anchored
      ? area.x + area.width - POPOVER_WIDTH - 2
      : Math.min(
          Math.max(current.x, area.x),
          area.x + area.width - POPOVER_WIDTH,
        ),
    y: anchored
      ? area.y + area.height - clamped - 2
      : Math.min(Math.max(current.y, area.y), area.y + area.height - clamped),
  })
}
function loadIcon(role: IconRole) {
  const path = join(
    __dirname,
    '../assets',
    iconFilename(process.platform, role),
  )
  const image = nativeImage.createFromPath(path)
  if (image.isEmpty()) throw new Error(`The ${role} icon could not be loaded`)
  return image
}
async function start(): Promise<void> {
  nativeTheme.themeSource = 'light'
  Menu.setApplicationMenu(null)
  const area = screen.getDisplayNearestPoint(
    screen.getCursorScreenPoint(),
  ).workArea
  window = new BrowserWindow({
    title: 'agentcord',
    width: POPOVER_WIDTH,
    height: 220,
    x: area.x + area.width - POPOVER_WIDTH - 2,
    y: area.y + area.height - 222,
    resizable: false,
    maximizable: false,
    fullscreenable: false,
    frame: false,
    transparent: true,
    hasShadow: false,
    show: false,
    backgroundColor: '#00000000',
    autoHideMenuBar: true,
    icon: loadIcon('app'),
    webPreferences: {
      preload: join(__dirname, '../preload/index.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  })
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
  window.webContents.on('will-navigate', (event) => event.preventDefault())
  window.webContents.session.setPermissionRequestHandler(
    (_contents, _permission, callback) => callback(false),
  )
  window.webContents.session.setPermissionCheckHandler(() => false)
  window.on('show', () => {
    window?.webContents.send('window:shown')
  })
  window.on('will-move', () => {
    anchored = false
  })
  window.on('blur', () => {
    lastDeactivated = Date.now()
  })
  window.webContents.on('before-input-event', (event, input) => {
    if (input.type === 'keyDown' && input.alt && input.key === 'F4') {
      event.preventDefault()
      app.quit()
    }
  })
  window.on('close', (event) => {
    if (!quitting && tray) {
      event.preventDefault()
      window?.hide()
    }
  })
  presence = new PresenceService({
    settingsPath: join(app.getPath('userData'), 'settings.json'),
    changed: (state) => {
      if (!window?.isDestroyed())
        window?.webContents.send('presence:changed', state)
    },
  })
  service = new CodexUsageService({
    cachePath: join(app.getPath('userData'), 'codex-usage-cache.json'),
    visible: () => !!window?.isVisible() && !window.isMinimized(),
    changed: (state) => {
      if (!window?.isDestroyed())
        window?.webContents.send('usage:changed', state)
      presence?.update({ codex: state })
      tray?.setToolTip(
        `AgentCord · ${state.snapshot ? `${Math.round(state.snapshot.windows[0]?.usedPercent ?? 0)}% Codex used` : 'Codex usage'}`,
      )
    },
  })
  claude = new ClaudeUsageService({
    cachePath: join(app.getPath('userData'), 'claude-usage-cache.json'),
    visible: () => !!window?.isVisible() && !window.isMinimized(),
    changed: (state) => {
      if (!window?.isDestroyed()) window?.webContents.send('claude:changed', state)
      presence?.update({ claude: state })
    },
  })
  const authorize = (event: Electron.IpcMainInvokeEvent) => {
    if (
      !window ||
      event.sender !== window.webContents ||
      event.senderFrame !== window.webContents.mainFrame
    ) {
      throw new Error('IPC sender not permitted')
    }
  }
  ipcMain.handle('usage:get', (event) => {
    authorize(event)
    return service!.state
  })
  ipcMain.handle('usage:refresh', (event) => {
    authorize(event)
    return service!.refresh()
  })
  ipcMain.handle('claude:get', (event) => {
    authorize(event)
    return claude!.state
  })
  ipcMain.handle('claude:refresh', (event) => {
    authorize(event)
    return claude!.refresh()
  })
  ipcMain.handle('presence:get', (event) => {
    authorize(event)
    return presence!.state
  })
  ipcMain.handle('presence:set', (event, enabled: unknown) => {
    authorize(event)
    if (typeof enabled !== 'boolean') throw new Error('Invalid presence setting')
    return presence!.setEnabled(enabled)
  })
  ipcMain.handle('window:resize', (event, height: unknown) => {
    authorize(event)
    if (
      typeof height !== 'number' ||
      !Number.isInteger(height) ||
      height < 0 ||
      height > 10_000
    ) {
      throw new Error('Invalid popover height')
    }
    resizePopover(height)
  })
  ipcMain.handle('login-item:get', (event) => {
    authorize(event)
    return getLaunchAtLogin(loginItemHost)
  })
  ipcMain.handle('login-item:set', (event, enabled: unknown) => {
    authorize(event)
    if (typeof enabled !== 'boolean') throw new Error('Invalid login setting')
    return setLaunchAtLogin(loginItemHost, enabled)
  })
  ipcMain.handle('window:hide', (event) => {
    authorize(event)
    window?.hide()
  })
  ipcMain.handle('app:quit', (event) => {
    authorize(event)
    app.quit()
  })
  if (!smoke) {
    tray = new Tray(loadIcon('tray'))
    // No polling: refresh the native icon only when display DPI changes.
    screen.on('display-metrics-changed', (_event, _display, metrics) => {
      if (metrics.includes('scaleFactor') && tray && !tray.isDestroyed()) {
        tray.setImage(loadIcon('tray'))
      }
    })
    tray.setToolTip('AgentCord · Codex usage')
    tray.setContextMenu(
      Menu.buildFromTemplate([
        {
          label: 'Open AgentCord',
          click: () => {
            void showWindow()
          },
        },
        {
          label: 'Refresh Codex usage',
          click: () => {
            void service?.refresh()
          },
        },
        {
          label: 'Refresh Claude usage',
          click: () => {
            void claude?.refresh()
          },
        },
        { type: 'separator' },
        { label: 'Quit', click: () => app.quit() },
      ]),
    )
    tray.on('click', () => {
      if (
        window?.isVisible() &&
        (window.isFocused() || Date.now() - lastDeactivated < 300)
      )
        window.hide()
      else void showWindow()
    })
  }
  const rendererUrl = !app.isPackaged
    ? process.env.AGENTCORD_RENDERER_URL
    : undefined
  if (rendererUrl) {
    const url = new URL(rendererUrl)
    if (url.hostname !== '127.0.0.1' || url.protocol !== 'http:')
      throw new Error('Invalid development URL')
    await window.loadURL(rendererUrl)
  } else await window.loadFile(join(__dirname, '../renderer/index.html'))
  // A login launch stays in the tray; the popover opens when the user asks.
  if (smoke || !startedAtLogin(loginItemHost, process.argv)) window.show()
  await Promise.all([service.start(), claude.start(), presence.start()])
  if (smoke) {
    await runSmokeTest(window, service.state)
    service.stop()
    claude.stop()
    presence.stop()
    app.exit(0)
  }
}
