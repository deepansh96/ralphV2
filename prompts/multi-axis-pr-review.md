# Multi-Axis PR Review

Run four independent reviews of the PR created from `{{BRANCH}}`.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Branch: {{BRANCH}}
Base branch: {{BASE_BRANCH}}
Step: {{STEP_ID}}
Skills: {{SKILLS_DIR}}

Default agent: codex
Mode: AFK, no HITL

## Prepare

Read the whole PR, actual base and head revisions, complete diff, parent issue,
linked sub-issues, local QA comment, and repository instructions. Confirm the
diff is non-empty.

## Four Reviews

Run the four read-only review agents in two waves so the parent and all
subagents stay within the four-agent concurrency limit. Each review agent
receives the PR scope, requirements sources, base/head revisions, and one
skill to load.

Wave 1:

1. Run `{{SKILLS_DIR}}/matt-pocock-code-review/SKILL.md` alone. It spawns its
   own Standards and Spec subagents.

Wait for wave 1 to finish, then run wave 2 in parallel:

1. `{{SKILLS_DIR}}/ponytail-review/SKILL.md`
2. `{{SKILLS_DIR}}/run-codex-review/SKILL.md`
3. `{{SKILLS_DIR}}/supe-review-code-changes/SKILL.md`

For the isolated Codex review, use:

```bash
node "{{SKILLS_DIR}}/run-codex-review/scripts/review.mjs" \
  --cwd "$(jq -r '.projectRoot' {{WORKSPACE}}/state.json)" \
  --base "<actual-pr-base>"
```

Subagents must not edit files, branches, state, or GitHub. They return findings
only to the parent. All four top-level reviews must finish successfully.

## Consolidate

For every finding:

1. Verify it against the actual diff, surrounding code, requirements, and QA
   result.
2. Vote `KEEP` for a real actionable point or `DISCARD` for a false positive,
   duplicate, style nit, or unsupported speculation.
3. Give one concise reason.
4. Deduplicate kept findings without losing their source axes.

Post the kept findings, discarded-count summary, and a concise final verdict
as one PR comment containing `<!-- ralph:multi-axis-review -->`. On rerun,
edit the existing marked comment instead of posting another. Do not apply
fixes. Delete temporary comment-body files.

Fail if any review does not return or the PR comment cannot be created or
updated.
