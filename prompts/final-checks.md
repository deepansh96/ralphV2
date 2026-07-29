# Final Checks

Check the completed implementation for GitHub issue `{{ISSUE}}` in `{{REPO}}`.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Branch: {{BRANCH}}
Base branch: {{BASE_BRANCH}}
Step: {{STEP_ID}}

Default agent: codex
Mode: AFK, no HITL

## Goal

Verify the whole feature branch before a PR is created. This is a read-only
check: do not change project files, commit, push, or fix findings.

## Inputs

- Read project `CONTEXT.md`, `CLAUDE.md`, and relevant ADRs.
- Read the parent issue with `gh issue view {{ISSUE}} --repo {{REPO}}`.
- Read `{{WORKSPACE}}/state.json`.
- Read every sub-issue referenced by an `implement-slice` step.
- Work from the project root in state and check out `{{BRANCH}}`.

## Checks

1. Read the complete change from `git diff {{BASE_BRANCH}}...HEAD`.
2. Run the exact quality commands in `CLAUDE.md`. If none are documented, run
   the focused tests and existing lint or format checks relevant to the diff.
3. Verify every sub-issue acceptance criterion against the implementation and
   observed behavior.
4. Check cross-slice integration, regressions, side effects, missing work, and
   scope creep.

If a check needs a temporary service, container, browser session, or file,
record it in `{{WORKSPACE}}/local-resources.json` before continuing and clean
it before this step completes.

## Output

Write `{{WORKSPACE}}/final-checks.md` with:

- changed files checked
- commands run and results
- acceptance criteria results by sub-issue
- findings
- `PASS` or `FAIL`

On any failed required check or unmet acceptance criterion, set this step to
`failed` in state with a concise note. Do not implement a fix. Otherwise
complete normally.
