import { spawn, execFile, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { createInterface } from 'node:readline'
import { object } from './codex-parser'

export interface RpcOptions { executable: string; args?: string[]; home: string; timeoutMs?: number }
export class CodexRpc {
  private child: ChildProcessWithoutNullStreams
  private nextId = 0
  private pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void }>()
  private timer: ReturnType<typeof setTimeout>
  private closed = false
  constructor(options: RpcOptions) {
    this.child = spawn(options.executable, [...(options.args ?? []), 'app-server'], {
      stdio: 'pipe', windowsHide: true, shell: false,
      detached: process.platform !== 'win32',
      env: { ...process.env, CODEX_HOME: options.home },
    })
    const lines = createInterface({ input: this.child.stdout, crlfDelay: Infinity })
    lines.on('line', (line) => {
      let message: Record<string, unknown> | null
      try { message = object(JSON.parse(line)) } catch { return }
      const id = message?.id
      if (typeof id !== 'number') return
      const request = this.pending.get(id)
      if (!request) return
      this.pending.delete(id)
      const error = object(message?.error)
      // Do not expose raw server messages: they may contain account details.
      if (error) request.reject(new Error(`Codex rejected the request (${String(error.code ?? 'unknown')}).`))
      else request.resolve(message?.result)
    })
    this.child.stderr.resume() // Never log credentials or block on a full stderr pipe.
    this.child.stdin.on('error', () => this.fail(new Error('The connection to Codex app-server was lost.')))
    this.child.on('error', () => this.fail(new Error('Codex could not be started. Check your CLI installation.')))
    this.child.on('exit', () => {
      lines.close()
      this.fail(new Error('Codex app-server exited before responding.'))
    })
    this.timer = setTimeout(() => {
      this.fail(new Error('Codex did not respond before the timeout. Try refreshing again.'))
      this.close()
    }, options.timeoutMs ?? 15_000)
  }
  request(method: string, params: unknown): Promise<unknown> {
    if (this.closed) return Promise.reject(new Error('The Codex connection is already closed.'))
    const id = this.nextId++
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject })
      this.child.stdin.write(`${JSON.stringify({ id, method, params })}\n`)
    })
  }
  notify(method: string): void {
    if (!this.closed) this.child.stdin.write(`${JSON.stringify({ method })}\n`)
  }
  private fail(error: Error): void {
    for (const request of this.pending.values()) request.reject(error)
    this.pending.clear()
    this.closed = true
  }
  close(): void {
    clearTimeout(this.timer)
    this.fail(new Error('The Codex connection was closed.'))
    if (this.child.exitCode !== null || this.child.signalCode !== null) return
    // Also reap native children of npm launchers on Windows; no console flash.
    if (process.platform === 'win32' && this.child.pid) {
      execFile('taskkill', ['/pid', String(this.child.pid), '/T', '/F'], { windowsHide: true }, () => {
        if (this.child.exitCode === null) this.child.kill()
      })
    } else if (this.child.pid) {
      // npm's Unix launcher can spawn a native child. Reap its process group.
      try { process.kill(-this.child.pid, 'SIGTERM') } catch { this.child.kill() }
    }
  }
}
