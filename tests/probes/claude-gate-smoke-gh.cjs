// Local `gh` stand-in for tests/probes/claude-gate-smoke.sh and
// tests/probes/codex-gate-smoke.sh: one PR, its issue, and one mutable QA
// checklist comment. Nothing leaves the machine.
// Usage: node claude-gate-smoke-gh.cjs DATA_DIR <gh arguments...>
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');

const [dir, ...args] = process.argv.slice(2);
const load = name => JSON.parse(fs.readFileSync(path.join(dir, name), 'utf8'));
const meta = load('meta.json');
const comments = load('comments.json');

function unsupported() {
  process.stderr.write(`gh smoke stub: unsupported command: ${args.slice(0, 2).join(' ')}\n`);
  process.exit(1);
}
function option(names) {
  for (let i = 0; i < args.length; i++) {
    for (const name of names) {
      if (args[i] === name) return args[i + 1];
      if (args[i].startsWith(`${name}=`)) return args[i].slice(name.length + 1);
    }
  }
  return undefined;
}
function fields() {
  const found = [];
  for (let i = 0; i < args.length; i++) {
    if (['-f', '-F', '--field', '--raw-field'].includes(args[i])) found.push([args[i], args[++i]]);
  }
  return found;
}
function emit(value) {
  const names = option(['--json']);
  const pick = o => Object.fromEntries(names.split(',').map(f => [f, o[f] ?? null]));
  if (names) value = Array.isArray(value) ? value.map(pick) : pick(value);
  const jq = option(['--jq', '-q']);
  if (!jq) return process.stdout.write(`${JSON.stringify(value)}\n`);
  const r = cp.spawnSync('jq', ['-r', jq], { input: JSON.stringify(value), encoding: 'utf8' });
  process.stdout.write(r.stdout);
  process.stderr.write(r.stderr);
  process.exit(r.status);
}
function readValue(value) {
  if (!value.startsWith('@')) return value;
  return fs.readFileSync(value === '@-' ? 0 : value.slice(1), 'utf8');
}
function editComment(comment, body) {
  let now = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
  if (now <= comment.updated_at) now = new Date(Date.parse(comment.updated_at) + 1000).toISOString().replace(/\.\d+Z$/, 'Z');
  Object.assign(comment, { body, updated_at: now });
  const tmp = path.join(dir, 'comments.json.tmp');
  fs.writeFileSync(tmp, JSON.stringify(comments));
  fs.renameSync(tmp, path.join(dir, 'comments.json'));
  return comment;
}
function diff() {
  return cp.execFileSync('git', ['-C', meta.project, 'diff', `${meta.base}...${meta.head}`], { encoding: 'utf8' });
}

const pr = {
  number: 1, title: meta.title, body: meta.body, url: `https://github.com/${meta.repo}/pull/1`,
  state: 'OPEN', isDraft: false, headRefName: meta.branch, headRefOid: meta.head, baseRefName: meta.base,
  author: { login: 'ralph' }, closingIssuesReferences: [{ number: meta.issue }],
  files: [{ path: 'README.md', additions: 1, deletions: 0 }],
  comments: comments.map(c => ({ id: `IC_${c.id}`, url: c.html_url, body: c.body, author: { login: 'ralph' },
    createdAt: c.created_at, updatedAt: c.updated_at })),
};
const issue = { number: meta.issue, title: meta.title, body: meta.issueBody, state: 'OPEN',
  url: `https://github.com/${meta.repo}/issues/${meta.issue}`, comments: [] };
const text = o => `title:\t${o.title}\nstate:\t${o.state}\nurl:\t${o.url}\n--\n${o.body}\n`;

const [group, command] = args;
if (group === 'auth' && command === 'status') {
  process.stdout.write('Logged in to github.com (local smoke stub)\n');
} else if (group === 'repo' && command === 'view') {
  emit({ nameWithOwner: meta.repo, url: `https://github.com/${meta.repo}`, defaultBranchRef: { name: meta.base } });
} else if (group === 'pr' && command === 'view') {
  if (option(['--json'])) emit(pr); else process.stdout.write(text(pr));
} else if (group === 'pr' && command === 'list') {
  emit([pr]);
} else if (group === 'pr' && command === 'diff') {
  process.stdout.write(diff());
} else if (group === 'pr' && command === 'comment' && args.includes('--edit-last')) {
  const body = option(['--body', '-b']) ?? readValue(`@${option(['--body-file', '-F'])}`);
  editComment(comments[comments.length - 1], body);
  process.stdout.write(`${comments[comments.length - 1].html_url}\n`);
} else if (group === 'issue' && command === 'view') {
  if (option(['--json'])) emit(issue); else process.stdout.write(text(issue));
} else if (group === 'api') {
  const valued = ['-X', '--method', '-f', '-F', '--field', '--raw-field', '-H', '--header', '--input', '--jq', '-q', '-t', '--template', '--hostname', '--cache'];
  let route = '';
  for (let i = 1; i < args.length; i++) {
    if (valued.includes(args[i])) i++;
    else if (!args[i].startsWith('-')) { route = args[i].replace(/^\//, ''); break; }
  }
  const given = fields();
  const input = option(['--input']);
  const method = (option(['-X', '--method']) || (given.length || input ? 'POST' : 'GET')).toUpperCase();
  const repo = `repos/${meta.repo}`;
  const comment = route.match(new RegExp(`^${repo}/issues/comments/(\\d+)$`));
  if (comment) {
    const target = comments.find(c => String(c.id) === comment[1]);
    if (!target) { process.stderr.write('gh: Not Found (HTTP 404)\n'); process.exit(1); }
    if (method === 'GET') emit(target);
    else if (method === 'PATCH') {
      let body = input ? JSON.parse(readValue(`@${input === '-' ? '-' : input}`)).body : undefined;
      for (const [flag, pair] of given) {
        const at = pair.indexOf('=');
        if (pair.slice(0, at) === 'body') body = flag === '-F' || flag === '--field' ? readValue(pair.slice(at + 1)) : pair.slice(at + 1);
      }
      if (typeof body !== 'string') unsupported();
      emit(editComment(target, body));
    } else unsupported();
  } else if (method !== 'GET') {
    unsupported();
  } else if (route.startsWith(`${repo}/issues/1/comments`) || route.startsWith(`${repo}/issues/${meta.issue}/comments`)) {
    emit(route.includes(`/issues/1/`) ? comments : []);
  } else if (route === `${repo}/pulls/1`) {
    emit({ number: 1, title: meta.title, body: meta.body, state: 'open', html_url: pr.url,
      head: { ref: meta.branch, sha: meta.head }, base: { ref: meta.base, sha: meta.baseSha } });
  } else if (route.startsWith(`${repo}/pulls/1/files`)) {
    emit([{ filename: 'README.md', status: 'modified', additions: 1, deletions: 0 }]);
  } else if (/^repos\/[^/]+\/[^/]+\/pulls\/1\/(comments|reviews)/.test(route)) {
    emit([]);
  } else if (route === `${repo}/issues/${meta.issue}`) {
    emit({ number: meta.issue, title: meta.title, body: meta.issueBody, state: 'open', html_url: issue.url });
  } else if (route === repo) {
    emit({ full_name: meta.repo, default_branch: meta.base });
  } else unsupported();
} else unsupported();
