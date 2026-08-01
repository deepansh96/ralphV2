# Run Through QA Checklist

Execute the PR's local QA checklist.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Branch: {{BRANCH}}
Base branch: {{BASE_BRANCH}}
Step: {{STEP_ID}}

Default agent: codex
Mode: AFK, no HITL

## Prepare

- Read the whole PR, its diff, the parent issue, linked sub-issues, and project
  instructions.
- Fetch origin, check out `{{BRANCH}}`, resolve the actual PR head revision,
  and verify `git rev-parse HEAD` equals it.
- Require an empty `git status --porcelain`. Fail before QA if the checkout is
  stale or the worktree contains uncommitted changes.
- Find the PR comment containing `<!-- ralph:qa-checklist -->`.
- Turn every checklist item into a todo and work through them in order.

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

After each item, edit the same marked PR comment:

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
