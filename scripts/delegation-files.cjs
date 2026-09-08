// Internal atomic writer. Public callers validate the schema in delegation.sh.
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');

let temporary;
let fd;
try {
  const [workspace, name] = process.argv.slice(2);
  if (!name || name === '.' || name === '..' || path.basename(name) !== name) {
    throw new Error('Invalid artifact name');
  }
  const root = fs.realpathSync(workspace);
  const target = path.join(root, name);
  if (fs.existsSync(target) || fs.lstatSync(target, { throwIfNoEntry: false })) {
    if (!fs.lstatSync(target).isFile()) throw new Error('Artifact must be a regular file');
  }
  const value = JSON.parse(fs.readFileSync(0, 'utf8'));
  temporary = path.join(root, `.${name}.tmp-${randomUUID()}`);
  fd = fs.openSync(temporary, 'wx', 0o600);
  fs.fchmodSync(fd, 0o600);
  fs.writeFileSync(fd, JSON.stringify(value) + '\n');
  fs.fsyncSync(fd);
  fs.closeSync(fd);
  fd = undefined;
  fs.renameSync(temporary, target);
  temporary = undefined;
} catch {
  if (fd !== undefined) fs.closeSync(fd);
  if (temporary) fs.rmSync(temporary, { force: true });
  // Do not leak provider content or paths in diagnostics.
  process.stderr.write('Delegation artifact write failed\n');
  process.exitCode = 1;
}
