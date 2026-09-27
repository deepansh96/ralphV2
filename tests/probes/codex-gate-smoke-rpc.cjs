// JSON-RPC recorder for tests/probes/codex-gate-smoke.sh, used as CODEX_BIN.
// Relays `codex app-server` stdio unchanged except that every `thread/list`
// page size is forced to PAGE_LIMIT, so a real server must paginate. Appends
// one line per request and response to RECORD: method and params going in;
// only listed thread IDs, cursors, read thread IDs, and error flags coming out.
// Usage: node codex-gate-smoke-rpc.cjs RECORD PAGE_LIMIT <codex arguments...>
const fs = require('node:fs');
const readline = require('node:readline');
const { spawn } = require('node:child_process');

const [record, pageLimit, ...args] = process.argv.slice(2);
const session = process.pid;
const log = entry => fs.appendFileSync(record, `${JSON.stringify({ session, ...entry })}\n`, { mode: 0o600 });
const child = spawn('codex', args, { stdio: ['pipe', 'pipe', 'ignore'] });
const methods = new Map();

readline.createInterface({ input: process.stdin }).on('line', line => {
  let message;
  try { message = JSON.parse(line); } catch { child.stdin.write(`${line}\n`); return; }
  if (message.method === 'thread/list' && message.params) message.params.limit = Number(pageLimit);
  if (message.method) {
    if (message.id != null) methods.set(message.id, message.method);
    log({ dir: 'request', id: message.id ?? null, method: message.method, params: message.params ?? null });
  }
  child.stdin.write(`${JSON.stringify(message)}\n`);
}).on('close', () => child.stdin.end());

readline.createInterface({ input: child.stdout }).on('line', line => {
  process.stdout.write(`${line}\n`);
  let message;
  try { message = JSON.parse(line); } catch { return; }
  if (message.id == null || message.method || !methods.has(message.id)) return;
  const method = methods.get(message.id);
  const result = message.result || {};
  const entry = { dir: 'response', id: message.id, method, error: message.error != null };
  if (method === 'thread/list' && Array.isArray(result.data)) {
    Object.assign(entry, { ids: result.data.map(t => t && t.id), nextCursor: result.nextCursor ?? null });
  }
  if (method === 'thread/read' && result.thread) entry.threadId = result.thread.id;
  log(entry);
});

child.on('exit', code => process.exit(code ?? 1));
child.on('error', () => process.exit(1));
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => child.kill(signal));
