# Run Through QA Checklist

Execute the PR's local QA checklist.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Branch: {{BRANCH}}
Base branch: {{BASE_BRANCH}}
Step: {{STEP_ID}}

Agent: {{AGENT}}
Mode: AFK, no HITL

{{NATIVE_DELEGATION_CONTRACT}}

## Prepare

- Read the whole PR, its diff, the parent issue, linked sub-issues, and project
  instructions.
- Fetch origin, check out `{{BRANCH}}`, resolve the actual PR head revision,
  and verify `git rev-parse HEAD` equals it.
- Require an empty `git status --porcelain`. Fail before QA if the checkout is
  stale or the worktree contains uncommitted changes.
- Find the PR comment containing `<!-- ralph:qa-checklist -->`.
- Turn every checklist item into an ordered todo.

## Required Delegation

The parent is the QA orchestrator. It owns Prepare, work allocation, progress
comment updates, cleanup, and evidence validation. It must not execute checklist
items itself.

Prepare one shared QA packet containing the PR scope, actual head revision,
checklist, local environment details, project instructions, and Local-Only Rules.
Delegate execution of every checklist item through the exact provider-native
mechanism in the injected contract above. The parent may assign one item or a
dependency-safe group of items to each top-level worker. Workers must not spawn
further subagents.

Use multiple top-level workers when the checklist contains independent groups.
Do not give the whole checklist to one worker unless every item genuinely shares
one execution context or forms one strict dependency chain. Assign every item to
exactly one active worker per attempt.

The parent decides the batches and concurrency:

- Independent read-only checks may run concurrently.
- Serialize work that shares or mutates a service, database, browser session,
  worktree, temporary path, or the local-resource ledger.
- Run only one resource-mutating worker at a time. It must record owned resources
  before starting them and clean them when its assigned work is done.

Each worker must return this result for every assigned item:

- checklist item ID and exact item text
- `PASS`, `FAIL`, or `BLOCKED`
- the action it performed and the behavior it observed
- concise evidence, including relevant output or artifact paths
- resources started, ledger entries made, and cleanup completed

Workers return results only to the parent. They must not edit GitHub comments or
product code. After results return, the parent validates that every checklist
item has one supported status and enough evidence, then updates the marked PR
comment in original checklist order.

Evidence validation is not QA execution. The parent must not rerun a command,
open a browser, call the application, start a service, or query a database to
confirm a worker result. It may perform only the orchestration operations in
Prepare, Progress, cleanup, and the final worktree integrity check. If a worker
fails or returns an unusable result, the parent may retry or delegate the item
again, but must not replace the missing work by performing the QA item itself.

## Local-Only Rules

- Use only local services and free local ports.
- Stub all external calls.
- Use only local databases. A fresh seeded database is allowed.
- Use a local browser for browser items.
- Do not change product code or commit fixes during QA.

Before starting a process, container, browser/computer-use session, or creating
a temporary path, append enough ownership information to
`{{WORKSPACE}}/local-resources.json` for the cleanup step to remove it safely.
Use names prefixed with `ralph-{{ISSUE}}-` where the tool supports names.

## Progress

After each completed item result, the parent edits the same marked PR comment:

- `[x] [PASS]` when observed behavior matches
- `[x] [FAIL]` when behavior is wrong
- `[x] [BLOCKED]` when the local environment cannot exercise it

Include the observed result under the item. Do not create progress-comment
spam.

After all items, add a concise summary to the same comment: what passed,
failed, or was blocked; issues found; and possible fix directions.

Clean resources started by this step before completing, including on failure.
Verify the worktree is still clean. Product failures and blocked items are
reported but do not fail this step; fail only if the checklist cannot be read
or the QA workflow itself cannot be completed and reported.
