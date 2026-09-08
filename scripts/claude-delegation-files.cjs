const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const crypto = require('node:crypto');
const quote = s => "'" + s.replaceAll("'", "'\\''") + "'";
const safe = s => typeof s === 'string' && /^[a-zA-Z0-9_-]{1,200}$/.test(s);
function regular(p) {
  const st = fs.lstatSync(p);
  if (!st.isFile() || (st.mode & 0o777) !== 0o600) throw Error();
}
function write(p, value) {
  fs.writeFileSync(p, value, {flag:'wx', mode:0o600});
}
try {
  const [mode, dir, attempt, parent, model, effort] = process.argv.slice(2);
  if (mode === 'prepare') {
    if (!safe(attempt) || !safe(parent)) throw Error();
    const root = fs.realpathSync(dir);
    const inputs = path.join(root, 'ralph-37-claude-' + crypto.randomUUID());
    fs.mkdirSync(inputs, {mode:0o700});
    write(path.join(inputs,'context.json'), JSON.stringify({attempt, parent, requested:{model:model || null,reasoningEffort:effort || null}}));
    write(path.join(inputs,'events.jsonl'), '');
    const command = [process.execPath, __filename, 'hook', inputs].map(quote).join(' ');
    const hooks = {};
    for (const event of ['PreToolUse','PostToolUse','PostToolUseFailure','SubagentStart','SubagentStop']) {
      hooks[event] = [{matcher:event.startsWith('Subagent') ? '*' : 'Agent|Workflow',
        hooks:[{type:'command',command,timeout:10}]}];
    }
    write(path.join(inputs,'settings.json'), JSON.stringify({hooks}));
    process.stdout.write(inputs+'\n');
  } else if (mode === 'check') {
    for (const name of ['context.json','events.jsonl','settings.json']) regular(path.join(dir,name));
  } else if (mode === 'hook') {
    regular(path.join(dir,'context.json'));
    const context = JSON.parse(fs.readFileSync(path.join(dir,'context.json'),'utf8'));
    const raw = JSON.parse(fs.readFileSync(0,'utf8'));
    if (raw.session_id !== context.parent) process.exit(0); // stale session is never accepted
    const clean = cp.spawnSync('jq',['-ce','-f',path.join(__dirname,'claude-delegation-sanitize.jq')],
      {input:JSON.stringify(raw),encoding:'utf8'});
    if (clean.status === 4 && !clean.stdout) process.exit(0); // unrelated hook
    if (clean.status !== 0) throw Error();
    const target = path.join(dir,'events.jsonl');
    regular(target);
    const fd = fs.openSync(target,fs.constants.O_APPEND|fs.constants.O_WRONLY|fs.constants.O_NOFOLLOW);
    try { fs.writeSync(fd,clean.stdout); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  } else if (mode === 'cleanup') {
    if (!path.basename(dir).startsWith('ralph-37-claude-') || !fs.lstatSync(dir).isDirectory()) throw Error();
    regular(path.join(dir,'context.json'));
    for (const name of ['stream.jsonl','hook-error']) {
      if (fs.existsSync(path.join(dir,name))) fs.unlinkSync(path.join(dir,name));
    }
    for (const name of ['settings.json','events.jsonl','context.json']) fs.unlinkSync(path.join(dir,name));
    fs.rmdirSync(dir);
  } else throw Error();
} catch {
  if (process.argv[2] === 'hook') {
    try { fs.writeFileSync(path.join(process.argv[3],'hook-error'), 'HOOK_FAILED\n', {flag:'wx',mode:0o600}); } catch {}
  }
  process.stderr.write('Claude delegation input unavailable\n');
  process.exitCode = 1;
}
