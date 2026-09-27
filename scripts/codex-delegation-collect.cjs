// Read-only Codex App Server evidence for one exec parent thread. Starts a
// fresh `codex app-server`, initializes with the experimental API, paginates
// direct children and all descendants, reads each thread's turns, and prints
// allowlisted facts only. It never starts turns, writes, lists items, uses the
// state-DB shortcut, or touches rollout files. Any failure exits nonzero with a
// fixed message; provider text, paths and diagnostics never reach stdout/stderr.
const { spawn } = require('node:child_process');
const readline = require('node:readline');
const KINDS = ['subAgent', 'subAgentReview', 'subAgentCompact', 'subAgentThreadSpawn', 'subAgentOther'];
const LIMIT = 100;
const TIMEOUT_MS = 1000 * Number(process.env.RALPH_CODEX_COLLECT_TIMEOUT || 120);
const token = value => (typeof value === 'string' && /^[a-zA-Z0-9_-]{1,200}$/.test(value) ? value : null);
const setting = value => (typeof value === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,199}$/.test(value) ? value : null);
const optionalToken = value => { if (value == null) return null; const clean = token(value); if (clean === null) throw new Error(); return clean; };
const integer = value => (Number.isInteger(value) ? value : null);
const STATUSES = ['completed', 'interrupted', 'failed', 'inProgress'];
function facts(thread, direct) {
  if (!thread || typeof thread !== 'object' || !Array.isArray(thread.turns)) throw new Error();
  const id = token(thread.id);
  if (id === null) throw new Error();
  const spawn = thread.source && thread.source.subAgent && thread.source.subAgent.thread_spawn;
  const agentPath = spawn && typeof spawn.agent_path === 'string' ? spawn.agent_path : null;
  const segment = agentPath === null ? null : agentPath.split('/').pop();
  return {
    id,
    parentId: optionalToken(thread.parentThreadId),
    direct,
    depth: spawn ? integer(spawn.depth) : null,
    spawnParent: spawn ? optionalToken(spawn.parent_thread_id) : null,
    task: segment === null ? null : token(segment),
    model: setting(thread.model),
    reasoningEffort: setting(thread.reasoningEffort),
    turns: thread.turns.map(turn => {
      if (!turn || typeof turn !== 'object') throw new Error();
      return {
        status: STATUSES.includes(turn.status) ? turn.status : 'unknown',
        startedAt: integer(turn.startedAt),
        completedAt: integer(turn.completedAt),
        failed: turn.error != null,
      };
    }),
  };
}
async function main() {
  const parent = token(process.argv[2]);
  if (parent === null || process.argv.length !== 3) throw new Error();
  const child = spawn(process.env.CODEX_BIN || 'codex', ['app-server'], { stdio: ['pipe', 'pipe', 'ignore'], env: process.env });
  const pending = new Map();
  let failure = null;
  let nextId = 1;
  const fail = error => { failure ||= error; for (const waiter of pending.values()) waiter.reject(error); pending.clear(); };
  child.once('error', () => fail(new Error()));
  child.once('exit', () => fail(new Error()));
  const send = message => { try { child.stdin.write(`${JSON.stringify(message)}\n`); } catch { fail(new Error()); } };
  const request = (method, params) => new Promise((resolve, reject) => {
    if (failure) return reject(failure);
    const id = nextId++;
    pending.set(id, { resolve, reject });
    send({ id, method, params });
  });
  readline.createInterface({ input: child.stdout }).on('line', line => {
    let message;
    try { message = JSON.parse(line); } catch { return; }
    if (message.id == null) return;
    if (message.method) { send({ id: message.id, error: { code: -32601, message: 'read-only evidence collector' } }); return; }
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    if (message.error || !('result' in message)) waiter.reject(new Error()); else waiter.resolve(message.result);
  });
  const timer = setTimeout(() => fail(new Error()), TIMEOUT_MS);
  try {
    await request('initialize', { clientInfo: { name: 'ralph-codex-delegation', version: '1' }, capabilities: { experimentalApi: true } });
    send({ method: 'initialized', params: {} });
    const list = async relation => {
      const summaries = new Map();
      let cursor;
      for (;;) {
        const params = { [relation]: parent, sourceKinds: KINDS, limit: LIMIT };
        if (cursor !== undefined) params.cursor = cursor;
        const page = await request('thread/list', params);
        if (!page || !Array.isArray(page.data) || (page.nextCursor != null && typeof page.nextCursor !== 'string')) throw new Error();
        for (const summary of page.data) {
          const id = token(summary && summary.id);
          if (id === null) throw new Error();
          summaries.set(id, summary);
        }
        if (page.nextCursor == null) return summaries;
        cursor = page.nextCursor;
      }
    };
    const direct = await list('parentThreadId');
    const descendants = await list('ancestorThreadId');
    for (const id of direct.keys()) if (!descendants.has(id)) throw new Error();
    const threads = [];
    for (const [id, summary] of [...descendants.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) {
      const read = await request('thread/read', { threadId: id, includeTurns: true });
      const thread = read && read.thread;
      if (!thread || thread.id !== id || thread.parentThreadId !== summary.parentThreadId) throw new Error();
      threads.push(facts(thread, direct.has(id)));
    }
    process.stdout.write(`${JSON.stringify({ parentId: parent, threads })}\n`);
  } finally {
    clearTimeout(timer);
    try { child.stdin.end(); } catch {}
    child.kill('SIGTERM');
  }
}
main().catch(() => {
  process.stderr.write('Codex delegation evidence unavailable\n');
  process.exitCode = 1;
});
