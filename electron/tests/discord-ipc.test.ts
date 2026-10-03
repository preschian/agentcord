import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { createServer, type Server, type Socket } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  backoffDelay,
  DiscordIpc,
  encodeFrame,
  FrameDecoder,
  ipcPaths,
  type Activity,
} from '../src/main/discord-ipc.ts'

const activity: Activity = { type: 0, details: 'Subscription usage', state: 'Claude 12% used' }

test('frames use an 8-byte little-endian header and reassemble across chunks', () => {
  const frame = encodeFrame(1, { a: 'é' })
  assert.equal(frame.readUInt32LE(0), 1)
  assert.equal(frame.readUInt32LE(4), frame.length - 8)
  const decoder = new FrameDecoder()
  const two = Buffer.concat([frame, encodeFrame(3, { b: 2 })])
  assert.deepEqual(decoder.push(two.subarray(0, 5)), [])
  const frames = decoder.push(two.subarray(5))
  assert.deepEqual(frames.map((f) => f.opcode), [1, 3])
  assert.deepEqual(JSON.parse(frames[0].payload.toString()), { a: 'é' })
})

test('decoder rejects an impossible payload length', () => {
  const header = Buffer.alloc(8)
  header.writeUInt32LE(0xffffffff, 4)
  assert.throws(() => new FrameDecoder().push(header), /length/)
})

test('socket discovery covers pipes, runtime and temp directories', () => {
  assert.equal(ipcPaths('win32', {})[0], '\\\\.\\pipe\\discord-ipc-0')
  assert.equal(ipcPaths('win32', {}).length, 10)
  const unix = ipcPaths('linux', { XDG_RUNTIME_DIR: '/run/user/1', TMPDIR: '/var/tmp' })
  assert.deepEqual(unix.slice(0, 5), [
    '/run/user/1/discord-ipc-0',
    '/run/user/1/app/com.discordapp.Discord/discord-ipc-0',
    '/run/user/1/snap.discord/discord-ipc-0',
    '/var/tmp/discord-ipc-0',
    '/tmp/discord-ipc-0',
  ])
  assert.equal(unix.length, 50)
  assert.equal(ipcPaths('darwin', {}).at(-1), '/tmp/discord-ipc-9')
})

test('backoff doubles up to 30 seconds', () => {
  assert.deepEqual([1, 2, 3, 4, 5, 6, 9].map(backoffDelay), [2000, 4000, 8000, 16000, 30000, 30000, 30000])
})

interface Fake {
  server: Server
  path: string
  frames: { opcode: number; payload: any }[]
  sockets: Socket[]
  close: () => Promise<void>
}
async function fakeDiscord(options: { ready?: boolean; onFrame?: (socket: Socket, opcode: number, payload: any) => void } = {}): Promise<Fake> {
  const dir = await mkdtemp(join(tmpdir(), 'agentcord-ipc-'))
  const path = process.platform === 'win32' ? `\\\\.\\pipe\\agentcord-test-${process.pid}-${Date.now()}` : join(dir, 'discord-ipc-0')
  const frames: Fake['frames'] = []
  const sockets: Socket[] = []
  const server = createServer((socket) => {
    sockets.push(socket)
    const decoder = new FrameDecoder()
    socket.on('error', () => {})
    socket.on('data', (chunk: Buffer) => {
      for (const frame of decoder.push(chunk)) {
        const payload = JSON.parse(frame.payload.toString() || 'null')
        frames.push({ opcode: frame.opcode, payload })
        if (frame.opcode === 0 && options.ready !== false)
          socket.write(encodeFrame(1, { cmd: 'DISPATCH', evt: 'READY', data: { v: 1 } }))
        options.onFrame?.(socket, frame.opcode, payload)
      }
    })
  })
  await new Promise<void>((resolve) => server.listen(path, resolve))
  return {
    server, path, frames, sockets,
    close: async () => {
      for (const socket of sockets) socket.destroy()
      await new Promise((resolve) => server.close(resolve))
      await rm(dir, { recursive: true, force: true })
    },
  }
}
const until = async (condition: () => boolean, message: string) => {
  for (let i = 0; i < 200; i++) {
    if (condition()) return
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  assert.fail(message)
}
const activities = (fake: Fake) =>
  fake.frames.filter((f) => f.opcode === 1 && f.payload.cmd === 'SET_ACTIVITY').map((f) => f.payload.args)

test('handshake, READY, SET_ACTIVITY with dedupe, and clear on stop', async () => {
  const fake = await fakeDiscord()
  const states: string[] = []
  const ipc = new DiscordIpc({ clientId: '123', pid: 42, paths: () => [fake.path], onState: (s) => states.push(s) })
  try {
    ipc.setActivity(activity) // queued until READY
    ipc.start()
    await until(() => ipc.state === 'connected', 'connected')
    assert.deepEqual(fake.frames[0], { opcode: 0, payload: { v: 1, client_id: '123' } })
    await until(() => activities(fake).length === 1, 'activity after READY')
    assert.deepEqual(activities(fake)[0], { pid: 42, activity })
    ipc.setActivity({ ...activity })
    ipc.setActivity({ ...activity, state: 'Claude 13% used' })
    await until(() => activities(fake).length === 2, 'changed activity')
    assert.equal(activities(fake)[1].activity.state, 'Claude 13% used')
    ipc.stop()
    await until(() => activities(fake).length === 3, 'clear')
    assert.equal(activities(fake)[2].activity, null)
    assert.equal(ipc.state, 'disconnected')
    assert.deepEqual(states, ['connecting', 'connected', 'disconnected'])
  } finally {
    ipc.stop()
    await fake.close()
  }
})

test('PING is answered with a matching PONG', async () => {
  const fake = await fakeDiscord()
  const ipc = new DiscordIpc({ clientId: '1', paths: () => [fake.path] })
  try {
    ipc.start()
    await until(() => ipc.state === 'connected', 'connected')
    fake.sockets[0].write(encodeFrame(3, { nonce: 'x' }))
    await until(() => fake.frames.some((f) => f.opcode === 4), 'pong')
    assert.deepEqual(fake.frames.find((f) => f.opcode === 4)!.payload, { nonce: 'x' })
  } finally {
    ipc.stop()
    await fake.close()
  }
})

test('a missing Discord fails silently and retries until it appears', async () => {
  const missing = join(tmpdir(), `agentcord-missing-${process.pid}`, 'discord-ipc-0')
  const fake = await fakeDiscord()
  let target = missing
  const ipc = new DiscordIpc({ clientId: '1', paths: () => [target], backoff: () => 20 })
  try {
    ipc.setActivity(activity)
    ipc.start() // must not throw or reject while Discord is absent
    await new Promise((resolve) => setTimeout(resolve, 100))
    assert.notEqual(ipc.state, 'connected')
    target = fake.path
    await until(() => ipc.state === 'connected', 'connect once Discord starts')
    await until(() => activities(fake).length === 1, 'activity sent after late connect')
  } finally {
    ipc.stop()
    await fake.close()
  }
})

test('reconnects after Discord drops the connection and re-sends the activity', async () => {
  const fake = await fakeDiscord()
  const ipc = new DiscordIpc({ clientId: '1', paths: () => [fake.path], backoff: () => 20 })
  try {
    ipc.setActivity(activity)
    ipc.start()
    await until(() => activities(fake).length === 1, 'first activity')
    fake.sockets[0].destroy()
    await until(() => fake.sockets.length === 2 && activities(fake).length === 2, 'activity re-sent after reconnect')
    assert.equal(ipc.state, 'connected')
  } finally {
    ipc.stop()
    await fake.close()
  }
})

test('a CLOSE frame (for example an invalid client ID) triggers a retry, not a crash', async () => {
  let rejected = 0
  const fake = await fakeDiscord({
    ready: false,
    onFrame: (socket, opcode) => {
      if (opcode === 0 && rejected++ === 0)
        socket.write(encodeFrame(2, { code: 4000, message: 'Invalid Client ID' }))
      else if (opcode === 0) socket.write(encodeFrame(1, { evt: 'READY' }))
    },
  })
  const ipc = new DiscordIpc({ clientId: 'bad', paths: () => [fake.path], backoff: () => 20 })
  try {
    ipc.start()
    await until(() => ipc.state === 'connected', 'connected on the second attempt')
    assert.equal(rejected, 2)
  } finally {
    ipc.stop()
    await fake.close()
  }
})

test('stop cancels pending reconnects', async () => {
  const missing = join(tmpdir(), `agentcord-missing-${process.pid}`, 'discord-ipc-0')
  const ipc = new DiscordIpc({ clientId: '1', paths: () => [missing], backoff: () => 20 })
  ipc.start()
  await new Promise((resolve) => setTimeout(resolve, 50))
  ipc.stop()
  assert.equal(ipc.state, 'disconnected')
  await new Promise((resolve) => setTimeout(resolve, 80))
  assert.equal(ipc.state, 'disconnected')
})
