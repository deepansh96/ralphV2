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
isolation note. Use exactly this format (documented in `docs/qa-delegation.md`);
Ralph hashes each item's ID and instruction text, so QA execution can update
progress without changing the instructions:

```md
<!-- ralph:qa-checklist -->
## Local QA Checklist

- [ ] [PENDING] QA-01: <behavior>
  - Setup: ...
  - Action: ...
  - Expected: ...
  - Isolation: ...
```

- Put `## Local QA Checklist` directly under `<!-- ralph:qa-checklist -->`.
- Item IDs are `QA-` plus two or more digits, unique within the comment.
- Each item line is `- [ ] [PENDING] QA-NN: <behavior>`. Optional instruction
  lines use two-space `  - Setup:`, `  - Action:`, `  - Expected:`, or
  `  - Isolation:` prefixes; a longer value continues on lines indented by four
  spaces.
- No other lines: no notes, `Result` or `Evidence` lines, or summary. QA
  execution adds those as progress.

Post this as one PR comment. On rerun, find the comment containing
`<!-- ralph:qa-checklist -->` and edit it instead of adding another comment.
Temporary files used to submit the comment must be deleted. Save no checklist
artifact locally.

Fail if the PR cannot be found, the requirements cannot be read, or the
comment cannot be created or updated.
