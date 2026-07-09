# Review Slice

Review and fix the implementation of GitHub sub-issue `{{SUB_ISSUE}}` for parent issue `{{ISSUE}}` in repo `{{REPO}}`.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Branch: {{BRANCH}}
Base branch: {{BASE_BRANCH}}
Step: {{STEP_ID}}
Sub-issue: {{SUB_ISSUE}}
Skills: {{SKILLS_DIR}}

Default agent: codex
Mode: AFK, no HITL

## Failure Protocol

If any operation fails irrecoverably (checkout, tests, quality checks, push), set this step's status to `failed` in `{{WORKSPACE}}/state.json` with a note explaining the failure, then stop.

## Goal

Run a two-axis code review of the slice just implemented for sub-issue `#{{SUB_ISSUE}}` — Standards and Spec, per the bundled code-review skill — then fix what the review finds, re-run quality checks, commit, and push. This step owns the review and cleanup that the implement-slice step deliberately defers.

## Required Inputs

- Read the code review skill: `{{SKILLS_DIR}}/code-review/SKILL.md`. Follow its two axes — Standards (documented repo standards plus its Fowler smell baseline) and Spec.
- Read project `CONTEXT.md`.
- Read project `CLAUDE.md`.
- Read any ADRs under `docs/adr/` if that directory exists.
- Read the parent issue's PRD:
  `gh issue view {{ISSUE}} --repo {{REPO}}`
- Read the reviewed sub-issue:
  `gh issue view {{SUB_ISSUE}} --repo {{REPO}}`
- Read the current workspace state:
  `{{WORKSPACE}}/state.json`

## Branch

**CRITICAL**: Run ALL git commands from the project root recorded in `{{WORKSPACE}}/state.json`. Do NOT run git commands from inside the workspace directory.

First, change to the project root:

```bash
cd $(jq -r '.projectRoot' {{WORKSPACE}}/state.json)
```

Then checkout the feature branch:

```bash
git fetch origin
git checkout {{BRANCH}} 2>/dev/null || git checkout -b {{BRANCH}} origin/{{BRANCH}}
```

If checkout fails, stop and report the failure. Stay in the project root for all subsequent commands.

## Fixed Point

Review only this slice's changes, not the whole branch.

1. List the branch commits: `git log --format='%H %s' origin/{{BASE_BRANCH}}..HEAD` (fall back to local `{{BASE_BRANCH}}` if the remote ref is unavailable).
2. Identify the commits whose messages reference `#{{SUB_ISSUE}}` exactly (not a longer issue number that merely starts with the same digits).
3. The fixed point is the parent of the earliest such commit. The diff under review is `git diff <fixed-point>...HEAD`, which also covers any commits stacked on top of the slice.
4. If no commit references `#{{SUB_ISSUE}}`, fall back to reviewing the full branch diff against the merge-base with `{{BASE_BRANCH}}`, and note the fallback in the output file.

Confirm the fixed point resolves with `git rev-parse` and the diff is non-empty before reviewing. An empty diff is a failure — report it.

## Review

Follow `{{SKILLS_DIR}}/code-review/SKILL.md`:

- **Spec axis** — the spec source is sub-issue `#{{SUB_ISSUE}}` (acceptance criteria, scope) plus the parent issue's PRD (implementation and testing decisions, seams). Report missing or partial requirements, scope creep, and requirements implemented wrong. Quote the spec line for each finding.
- **Standards axis** — documented repo standards (`CLAUDE.md`, `CONTEXT.md`, contributing docs) plus the skill's Fowler smell baseline. A documented repo standard overrides the baseline; every smell is a judgement call, never a hard violation; skip anything tooling already enforces.

Keep the two axes separate. Do not rerank findings across axes.

## Fix

Fix what the review found, staying inside this slice's scope:

- **Spec findings** — fix all confirmed ones. For a missing or wrong behavior, follow the TDD loop: write the failing test at the pre-agreed seam first, then the minimal fix.
- **Hard Standards violations** (a documented repo standard breached) — fix them.
- **Smell-baseline findings** — judgement calls: apply the fix when it is clearly beneficial and low-risk within this slice's diff (a rename, extracting an obvious duplication); record-but-skip when the fix would ripple beyond the slice or trade one judgement for another. Every skipped finding needs one line of reasoning in the output file.
- Do not fix code outside this slice's diff, implement other slices, or expand scope. If a finding implicates code this slice never touched, record it in the output file instead of fixing it.

If the review finds nothing, record that and complete normally — a zero-finding review is a valid outcome.

## Quality Checks

Run quality checks from CLAUDE.md after fixes. If CLAUDE.md defines exact commands, run those commands. If not, run the most relevant project tests for the files changed plus any formatter or lint command the project already uses.

Do not commit if tests or required checks fail — fix forward until green, or fail the step with a note.

## Git Commit and Push

If fixes were made:

1. Review the changed files with `git status --short` and relevant diffs.
2. Commit only the review fixes, referencing the sub-issue:

```bash
git commit -m "Review fixes for slice #{{SUB_ISSUE}}"
```

3. Push:

```bash
git push
```

If upstream tracking is missing, push with `git push -u origin {{BRANCH}}`.

If no fixes were needed, skip the commit — do not create an empty commit.

## Record

Write the review record to:

```text
{{WORKSPACE}}/{{STEP_ID}}.md
```

Structure:

```md
# Review Slice — #{{SUB_ISSUE}}

## Fixed point

<commit sha and how it was chosen, or the full-branch fallback note>

## Standards

<findings with file/hunk, each marked Fixed | Skipped (reason) | Not applicable>

## Spec

<findings with the spec line quoted, each marked Fixed | Skipped (reason)>

## Summary

<one line per axis: total findings, fixed, skipped — or "no findings">
```

Post the summary as a comment on the sub-issue for the audit trail:

```bash
gh issue comment {{SUB_ISSUE}} --repo {{REPO}} --body "<review summary>"
```

## Idempotency

Re-running this step reviews the current `HEAD` again using the same fixed point. Prior review-fix commits are part of the diff under review, not a reason to skip. Do not duplicate fixes that are already applied, and do not post a duplicate identical comment on the sub-issue — update the record file and only comment when the summary changed.

## Completion

Complete normally only after:

- The review ran over a non-empty slice diff along both axes.
- Every confirmed Spec finding and hard Standards violation is fixed, or the step failed with a note.
- Quality checks from CLAUDE.md pass on the final tree.
- Fixes (if any) are committed with a `#{{SUB_ISSUE}}` reference and pushed.
- `{{WORKSPACE}}/{{STEP_ID}}.md` records every finding with its outcome.
- The summary comment exists on sub-issue `#{{SUB_ISSUE}}`.
