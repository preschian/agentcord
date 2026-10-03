import { randomUUID } from 'node:crypto'
import { connect, type Socket } from 'node:net'
import { join } from 'node:path'

// A hand-written Discord RPC IPC client; no third-party dependencies. Only the
// Rich Presence subset is implemented: socket discovery, handshake,
// SET_ACTIVITY, ping/pong, reconnect with backoff, and clearing. Port of
// windows/DiscordIpc.cs.
//
// Transport: a Unix domain socket at <runtime dir>/discord-ipc-{0..9} on
// macOS/Linux, a named pipe at \\.\pipe\discord-ipc-{0..9} on Windows. Node's
// `net` module opens both through the same API.
//
// Frame format on the wire:
//   [ opcode: UInt32 LE ][ payloadLength: UInt32 LE ][ JSON bytes ]

export type DiscordConnection = 'disconnected' | 'connecting' | 'connected'
export const Opcode = {
  Handshake: 0,
  Frame: 1,
  Close: 2,
  Ping: 3,
  Pong: 4,
} as const
export interface Activity {
  type?: number
  details?: string
  state?: string
  timestamps?: { start?: number; end?: number }
  assets?: {
    large_image?: string
    large_text?: string
    small_image?: string
    small_text?: string
  }
  buttons?: { label: string; url: string }[]
}
export interface DiscordFrame {
  opcode: number
  payload: Buffer
}
// Discord never sends anything close to this; a larger length means the stream
// is not speaking the protocol.
const MAX_PAYLOAD = 1024 * 1024
const SOCKET_COUNT = 10

export function encodeFrame(opcode: number, payload: unknown): Buffer {
  const body = Buffer.from(JSON.stringify(payload), 'utf8')
  const frame = Buffer.alloc(8 + body.length)
  frame.writeUInt32LE(opcode, 0)
  frame.writeUInt32LE(body.length, 4)
  body.copy(frame, 8)
  return frame
}

/** Reassembles frames from arbitrary stream chunks. */
export class FrameDecoder {
  private buffer: Buffer = Buffer.alloc(0)

  /** Throws when the stream announces an impossible payload length. */
  push(chunk: Buffer): DiscordFrame[] {
    this.buffer =
      this.buffer.length === 0 ? chunk : Buffer.concat([this.buffer, chunk])
    const frames: DiscordFrame[] = []
    while (this.buffer.length >= 8) {
      const length = this.buffer.readUInt32LE(4)
      if (length > MAX_PAYLOAD) throw new Error('Invalid Discord frame length')
      if (this.buffer.length < 8 + length) break
      frames.push({
        opcode: this.buffer.readUInt32LE(0),
        payload: this.buffer.subarray(8, 8 + length),
      })
      this.buffer = this.buffer.subarray(8 + length)
    }
    return frames
  }
}

/** Candidate socket paths in the order Discord clients try them. */
export function ipcPaths(
  platform: NodeJS.Platform = process.platform,
  env: NodeJS.ProcessEnv = process.env,
): string[] {
  if (platform === 'win32')
    return Array.from(
      { length: SOCKET_COUNT },
      (_, i) => `\\\\.\\pipe\\discord-ipc-${i}`,
    )
  const runtime = env.XDG_RUNTIME_DIR
  const directories = [
    runtime,
    // Flatpak and Snap builds of Discord keep the socket in a sandbox subdirectory.
    runtime && join(runtime, 'app/com.discordapp.Discord'),
    runtime && join(runtime, 'snap.discord'),
    env.TMPDIR,
    env.TMP,
    env.TEMP,
    '/tmp',
  ].filter((value): value is string => !!value)
  const unique = [...new Set(directories)]
  const paths: string[] = []
  for (let i = 0; i < SOCKET_COUNT; i++)
    for (const directory of unique) paths.push(join(directory, `discord-ipc-${i}`))
  return paths
}

/** Exponential backoff capped at 30 seconds: 2s, 4s, 8s, 16s, 30s. */
export function backoffDelay(attempt: number): number {
  return Math.min(2 ** Math.min(attempt, 5), 30) * 1000
}

interface Options {
  clientId: string
  onState?: (state: DiscordConnection) => void
  paths?: () => string[]
  pid?: number
  backoff?: (attempt: number) => number
}

export class DiscordIpc {
  state: DiscordConnection = 'disconnected'
  private readonly paths: () => string[]
  private readonly pid: number
  private readonly backoff: (attempt: number) => number
  private running = false
  private ready = false
  private attempt = 0
  private socket: Socket | null = null
  private timer: ReturnType<typeof setTimeout> | null = null
  private activity: Activity | null = null
  // Signature of what Discord currently displays; null until READY.
  private sent: string | null = null

  constructor(private readonly options: Options) {
    this.paths = options.paths ?? (() => ipcPaths())
    this.pid = options.pid ?? process.pid
    this.backoff = options.backoff ?? backoffDelay
  }

  /** Begin connecting, and keep reconnecting, until `stop`. Idempotent. */
  start(): void {
    if (this.running) return
    this.running = true
    this.attempt = 0
    void this.open()
  }

  /** Stop reconnecting, clear the presence, and close the socket. */
  stop(): void {
    this.running = false
    if (this.timer) clearTimeout(this.timer)
    this.timer = null
    const socket = this.socket
    this.socket = null
    if (socket) {
      if (this.ready && !socket.destroyed) {
        // Politely clear first; closing the socket would clear it anyway.
        socket.end(this.activityFrame(null))
        setTimeout(() => socket.destroy(), 500).unref()
      } else socket.destroy()
    }
    this.ready = false
    this.sent = null
    this.setState('disconnected')
  }

  /** Set, or with null clear, the presence. Unchanged payloads are not re-sent. */
  setActivity(activity: Activity | null): void {
    this.activity = activity
    this.flush()
  }

  private flush(): void {
    if (!this.ready || !this.socket || this.socket.destroyed) return
    const signature = JSON.stringify(this.activity)
    if (signature === this.sent) return
    this.sent = signature
    this.socket.write(this.activityFrame(this.activity))
  }

  private activityFrame(activity: Activity | null): Buffer {
    // An explicit `activity: null` is what clears the presence.
    return encodeFrame(Opcode.Frame, {
      cmd: 'SET_ACTIVITY',
      nonce: randomUUID(),
      args: { pid: this.pid, activity },
    })
  }

  private setState(state: DiscordConnection): void {
    if (this.state === state) return
    this.state = state
    this.options.onState?.(state)
  }

  private async open(): Promise<void> {
    this.setState('connecting')
    const socket = await this.connectFirst()
    // stop() may have been called while connecting.
    if (!this.running) {
      socket?.destroy()
      return
    }
    if (!socket) return this.retry()
    this.socket = socket
    const decoder = new FrameDecoder()
    let closed = false
    const lost = () => {
      if (closed) return
      closed = true
      socket.destroy()
      if (this.socket !== socket) return
      this.socket = null
      this.ready = false
      this.sent = null
      if (this.running) this.retry()
    }
    socket.on('error', lost)
    socket.on('close', lost)
    socket.on('data', (chunk: Buffer) => {
      try {
        for (const frame of decoder.push(chunk)) this.handle(socket, frame, lost)
      } catch {
        lost()
      }
    })
    socket.write(
      encodeFrame(Opcode.Handshake, { v: 1, client_id: this.options.clientId }),
    )
  }

  private handle(socket: Socket, frame: DiscordFrame, lost: () => void): void {
    if (frame.opcode === Opcode.Ping) {
      socket.write(rawFrame(Opcode.Pong, frame.payload))
    } else if (frame.opcode === Opcode.Close) {
      lost()
    } else if (frame.opcode === Opcode.Frame) {
      let message: unknown
      try {
        message = JSON.parse(frame.payload.toString('utf8'))
      } catch {
        return
      }
      if ((message as { evt?: unknown } | null)?.evt === 'READY') {
        this.ready = true
        this.attempt = 0
        this.setState('connected')
        this.flush()
      }
    }
  }

  private retry(): void {
    this.setState('disconnected')
    if (!this.running) return
    this.timer = setTimeout(() => {
      this.timer = null
      if (this.running) void this.open()
    }, this.backoff(++this.attempt))
    this.timer.unref()
  }

  private async connectFirst(): Promise<Socket | null> {
    for (const path of this.paths()) {
      if (!this.running) return null
      const socket = await tryConnect(path)
      if (socket) return socket
    }
    return null
  }
}

function rawFrame(opcode: number, payload: Buffer): Buffer {
  const header = Buffer.alloc(8)
  header.writeUInt32LE(opcode, 0)
  header.writeUInt32LE(payload.length, 4)
  return Buffer.concat([header, payload])
}

function tryConnect(path: string): Promise<Socket | null> {
  return new Promise((resolve) => {
    const socket = connect(path)
    const fail = () => {
      socket.destroy()
      resolve(null)
    }
    socket.once('error', fail)
    socket.once('connect', () => {
      socket.removeListener('error', fail)
      socket.removeListener('timeout', fail)
      socket.setTimeout(0)
      resolve(socket)
    })
    // A stuck pipe must not hold the reconnect loop.
    socket.setTimeout(500, fail)
  })
}
