# Multi-Axis PR Review

Run four independent reviews of the PR created from `{{BRANCH}}`.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Branch: {{BRANCH}}
Base branch: {{BASE_BRANCH}}
Step: {{STEP_ID}}
Skills: {{SKILLS_DIR}}

Agent: {{AGENT}}
Mode: AFK, no HITL

{{NATIVE_DELEGATION_CONTRACT}}

## Prepare

Read the whole PR, actual base and head revisions, complete diff, parent issue,
linked sub-issues, local QA comment, and repository instructions. Confirm the
diff is non-empty. Before launching reviews, verify `git rev-parse HEAD` equals
the actual PR head revision. Fail instead of reviewing a different local head.

## Required Delegation

The parent is the review orchestrator, not one of the four reviewers. It owns
Prepare and Consolidate. The parent must not run any of the four review skills
or perform their axis-specific review analysis in the parent thread.

Prepare one shared review packet containing the PR scope, requirements sources,
base/head revisions, complete diff, local QA result, and repository
instructions. Give that packet to every top-level review subagent.

Spawn four read-only top-level review subagents in two waves so the parent and
all active subagents stay within the four-agent concurrency limit.

Wave 1:

1. Spawn exactly one subagent for
   `{{SKILLS_DIR}}/matt-pocock-code-review/SKILL.md`.
2. Instruct it to load that skill and complete its contract, including its own
   Standards and Spec subagents. Require both nested results in its response.

Wait for wave 1 to finish and confirm both nested results returned, then run
wave 2 in parallel:

1. Spawn exactly three subagents concurrently, one for each skill:
   - `{{SKILLS_DIR}}/ponytail-review/SKILL.md`
   - `{{SKILLS_DIR}}/run-codex-review/SKILL.md`
   - `{{SKILLS_DIR}}/supe-review-code-changes/SKILL.md`
2. Instruct each subagent to load only its assigned skill.
3. Require each to return findings only to the parent.
4. Wait for all three to finish.

For the isolated Codex review, its assigned subagent must use:

```bash
node "{{SKILLS_DIR}}/run-codex-review/scripts/review.mjs" \
  --cwd "$(jq -r '.projectRoot' {{WORKSPACE}}/state.json)" \
  --base "<actual-pr-base>"
```

All review subagents must remain read-only: they must not edit files, branches,
state, or GitHub. If any top-level review fails, returns no usable result, or
the Matt review omits either nested result, fail this step. The parent must not
replace missing delegated work with its own review. Do not begin Consolidate
until all four top-level reviews and the Matt review's two nested results have
returned successfully.

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
