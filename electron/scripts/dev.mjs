import { build, createServer } from 'vite'
import electron from 'electron'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { prepareAssets } from './prepare-assets.mjs'

await prepareAssets()
process.chdir(fileURLToPath(new URL('..', import.meta.url)))
const server = await createServer()
await server.listen()
const url = server.resolvedUrls.local[0]
let child
let restartTimer
let stopping = false
const watchers = []
function launch() {
  if (stopping) return
  clearTimeout(restartTimer)
  const previous = child
  child = undefined
  if (previous && previous.exitCode === null) {
    previous.once('exit', startElectron)
    previous.kill()
  } else startElectron()
}
function startElectron() {
  if (stopping) return
  const current = spawn(electron, ['.', ...process.argv.slice(2)], {
    stdio: 'inherit', windowsHide: true,
    env: { ...process.env, AGENTCORD_RENDERER_URL: url },
  })
  child = current
  current.on('error', error => { console.error(error.message); void stop(1) })
  current.on('exit', () => { if (child === current && !restartTimer) void stop(0) })
  restartTimer = undefined
}
let ready = false
for (const mode of ['main', 'preload']) {
  const watcher = await build({
    configFile: 'vite.electron.config.ts', mode, build: { watch: {} },
  })
  watchers.push(watcher)
  await new Promise((resolve, reject) => {
    watcher.on('event', event => {
      if (event.code === 'ERROR') { console.error(event.error); if (!ready) reject(event.error) }
      if (event.code === 'END') {
        resolve()
        if (ready) { clearTimeout(restartTimer); restartTimer = setTimeout(launch, 200) }
      }
    })
  })
}
ready = true
server.printUrls()
launch()
async function stop(code) {
  if (stopping) return
  stopping = true
  clearTimeout(restartTimer)
  child?.kill()
  await Promise.all(watchers.map(watcher => watcher.close()))
  await server.close()
  process.exit(code)
}
process.on('SIGINT', () => void stop(0))
process.on('SIGTERM', () => void stop(0))
