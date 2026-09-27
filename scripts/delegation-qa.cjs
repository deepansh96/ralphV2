// Internal QA checklist parser and canonical digests. Public callers use
// delegation-qa.sh. Diagnostics never echo checklist or provider content.
const { createHash } = require('node:crypto');
const fs = require('node:fs');

class Invalid extends Error {}

const MARKER = '<!-- ralph:qa-checklist -->';
const SUMMARY = '<!-- ralph:qa-summary -->';
const HEADER = /^- \[( |x)\] \[(PENDING|PASS|FAIL|BLOCKED)\] (QA-[0-9]{2,}): (.*)$/;
const INSTRUCTION = /^  - (Setup|Action|Expected|Isolation): /;
const PROGRESS = /^  - (Result|Evidence): /;

const sha256 = (text) => `sha256:${createHash('sha256').update(text, 'utf8').digest('hex')}`;
const exact = (value, fields) => value !== null && typeof value === 'object' && !Array.isArray(value)
  && JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...fields].sort());
const text = (value) => typeof value === 'string' && value.length > 0;
const byId = (a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

// Canonical form: items sorted by id, each object exactly id then text.
function checklistDigest(items) {
  if (!Array.isArray(items) || !items.every((item) => exact(item, ['id', 'text']) && text(item.id) && text(item.text))) {
    throw new Error('items');
  }
  return sha256(JSON.stringify([...items].sort(byId).map(({ id, text: body }) => ({ id, text: body }))));
}

// Canonical form: exactly taskId then sorted checklistItemIds.
function assignmentDigest(assignment) {
  if (!exact(assignment, ['taskId', 'checklistItemIds']) || !text(assignment.taskId)
    || !Array.isArray(assignment.checklistItemIds) || !assignment.checklistItemIds.every(text)) {
    throw new Error('assignment');
  }
  return sha256(JSON.stringify({ taskId: assignment.taskId, checklistItemIds: [...assignment.checklistItemIds].sort() }));
}

// Instruction items from one marked comment body; mutable checkbox state,
// status tags, Result/Evidence blocks, and the summary are excluded.
function checklistItems(body) {
  const lines = body.replace(/\r\n?/g, '\n').split('\n');
  if (body.split(MARKER).length !== 2) throw new Invalid();
  const marker = lines.findIndex((line) => line.trim() === MARKER);
  if (marker < 0 || lines.slice(0, marker).some((line) => line.trim() !== '')) throw new Invalid();
  let index = marker + 1;
  while (index < lines.length && lines[index].trim() === '') index += 1;
  if (lines[index] !== '## Local QA Checklist') throw new Invalid();
  const items = [];
  let current;
  let mode;
  for (const line of lines.slice(index + 1)) {
    if (line.trim() === SUMMARY) break;
    if (line.trim() === '') continue;
    const header = HEADER.exec(line);
    if (header) {
      current = { id: header[3], lines: [header[4]] };
      items.push(current);
      mode = 'instruction';
    } else if (current && INSTRUCTION.test(line)) {
      current.lines.push(line);
      mode = 'instruction';
    } else if (current && PROGRESS.test(line)) {
      mode = 'progress';
    } else if (current && line.startsWith('    ')) {
      if (mode === 'instruction') current.lines.push(line);
    } else {
      throw new Invalid();
    }
  }
  const result = items.map((item) => ({ id: item.id, text: item.lines.join('\n').trim() }));
  const ids = result.map((item) => item.id);
  if (result.length === 0 || new Set(ids).size !== ids.length || result.some((item) => item.text === '')) throw new Invalid();
  return result.sort(byId);
}

// The exact #37 plan from a fetched snapshot and the parent's assignments.
// Refuses anything but exact, unique, complete coverage of the snapshot IDs.
function plan({ stepId, attemptId, snapshot, assignments }) {
  if (!Array.isArray(assignments) || assignments.length === 0) throw new Error('assignments');
  const ids = snapshot.items.map((item) => item.id);
  const assigned = assignments.flatMap((assignment) => {
    if (!exact(assignment, ['taskId', 'checklistItemIds']) || !Array.isArray(assignment.checklistItemIds)) throw new Error('assignment');
    return assignment.checklistItemIds;
  });
  const tasks = assignments.map((assignment) => assignment.taskId);
  if (new Set(tasks).size !== tasks.length || new Set(assigned).size !== assigned.length
    || assigned.length !== ids.length || !assigned.every((id) => ids.includes(id))) {
    throw new Error('coverage');
  }
  return {
    schemaVersion: 1,
    stepId,
    attemptId,
    checklist: { commentId: snapshot.commentId, updatedAt: snapshot.updatedAt, digest: checklistDigest(snapshot.items), items: snapshot.items },
    assignments: assignments
      .map(({ taskId, checklistItemIds }) => ({ taskId, checklistItemIds: [...checklistItemIds].sort() }))
      .sort((a, b) => (a.taskId < b.taskId ? -1 : a.taskId > b.taskId ? 1 : 0))
      .map((assignment) => ({ ...assignment, assignmentDigest: assignmentDigest(assignment) })),
  };
}

try {
  const input = fs.readFileSync(0, 'utf8');
  const command = process.argv[2];
  if (command === 'items') {
    process.stdout.write(`${JSON.stringify(checklistItems(input))}\n`);
  } else if (command === 'checklist-digest') {
    process.stdout.write(`${checklistDigest(JSON.parse(input))}\n`);
  } else if (command === 'assignment-digest') {
    process.stdout.write(`${assignmentDigest(JSON.parse(input))}\n`);
  } else if (command === 'digests') {
    // Recomputed digests for a schema-valid plan and the refetched items.
    const { plan: value, items } = JSON.parse(input);
    process.stdout.write(`${JSON.stringify({
      checklist: value ? checklistDigest(value.checklist.items) : null,
      assignments: value ? Object.fromEntries(value.assignments.map(({ taskId, checklistItemIds }) => [taskId, assignmentDigest({ taskId, checklistItemIds })])) : null,
      refetched: items ? checklistDigest(items) : null,
    })}\n`);
  } else if (command === 'plan') {
    process.stdout.write(`${JSON.stringify(plan(JSON.parse(input)))}\n`);
  } else {
    throw new Error('command');
  }
} catch (error) {
  process.stderr.write('Delegation QA input rejected\n');
  process.exitCode = error instanceof Invalid ? 2 : 1;
}
