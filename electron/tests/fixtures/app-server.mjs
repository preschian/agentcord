import { createInterface } from 'node:readline'
const mode = process.argv[2]
createInterface({ input: process.stdin }).on('line', line => {
  const request = JSON.parse(line)
  if (mode === 'timeout') return
  if (mode === 'exit') { process.exit(0); return }
  if (request.method === 'initialized') return
  if (mode === 'error') {
    console.log(JSON.stringify({ id: request.id, error: { code: -32001, message: 'secret account data' } }))
    return
  }
  console.log('malformed diagnostic line')
  console.log(JSON.stringify({ method: 'notification', params: {} }))
  console.log(JSON.stringify({ id: request.id, result: { method: request.method } }))
})
