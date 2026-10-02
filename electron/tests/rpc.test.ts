import test from 'node:test'
import assert from 'node:assert/strict'
import { fileURLToPath } from 'node:url'
import { CodexRpc } from '../src/main/codex-rpc.ts'
const fixture = fileURLToPath(new URL('./fixtures/app-server.mjs', import.meta.url))
function create(mode: string) {
  return new CodexRpc({ executable: process.execPath, args: [fixture, mode], home: process.cwd(), timeoutMs: 1000 })
}
test('JSONL handles diagnostics, notifications and multiple response IDs', async () => {
  const rpc = create('success')
  try {
    assert.deepEqual(await rpc.request('initialize', {}), { method: 'initialize' })
    rpc.notify('initialized')
    assert.deepEqual(await Promise.all([rpc.request('account/read', {}), rpc.request('account/rateLimits/read', null)]), [
      { method: 'account/read' }, { method: 'account/rateLimits/read' },
    ])
  } finally { rpc.close() }
})
test('RPC errors are surfaced without raw server details', async () => {
  const rpc = create('error')
  try { await assert.rejects(rpc.request('initialize', {}), error => error instanceof Error && error.message.includes('-32001') && !error.message.includes('secret')) }
  finally { rpc.close() }
})
test('timeout rejects pending requests and terminates the process', async () => {
  const rpc = create('timeout')
  try { await assert.rejects(rpc.request('initialize', {}), /timeout/) }
  finally { rpc.close() }
})
test('early process exit rejects requests instead of hanging', async () => {
  const rpc = create('exit')
  try { await assert.rejects(rpc.request('initialize', {}), /exited/) }
  finally { rpc.close() }
})
test('missing executable is handled', async () => {
  const rpc = new CodexRpc({ executable: 'agentcord-no-such-executable', home: process.cwd(), timeoutMs: 1000 })
  try { await assert.rejects(rpc.request('initialize', {}), /could not be started/) }
  finally { rpc.close() }
})
