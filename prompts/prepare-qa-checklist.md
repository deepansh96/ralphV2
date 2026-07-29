# Prepare QA Checklist

Prepare local manual QA for the PR created from `{{BRANCH}}`.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Branch: {{BRANCH}}
Base branch: {{BASE_BRANCH}}
Step: {{STEP_ID}}

Default agent: codex
Mode: AFK, no HITL

Read the whole PR, its diff, the parent issue, linked sub-issues, and relevant
project instructions. Build only QA items that can run locally:

- never test a deployed environment
- never call a real external service; require a stub or local fake
- never read or write a remote database; use a local or fresh seeded database
- use a local browser for browser behavior
- include only behavior worth checking manually, not checks already covered by
  an automated command

Each item must have a stable ID and concise setup, action, expected result, and
isolation note:

```md
<!-- ralph:qa-checklist -->
## Local QA Checklist

- [ ] [PENDING] QA-01: <behavior>
  - Setup: ...
  - Action: ...
  - Expected: ...
  - Isolation: ...
```

Post this as one PR comment. On rerun, find the comment containing
`<!-- ralph:qa-checklist -->` and edit it instead of adding another comment.
Temporary files used to submit the comment must be deleted. Save no checklist
artifact locally.

Fail if the PR cannot be found, the requirements cannot be read, or the
comment cannot be created or updated.
