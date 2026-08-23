# Multi-Axis PR Review

Run five independent review passes across four skills for the PR created from
`{{BRANCH}}`.

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

The parent is the review orchestrator, not one of the five review workers. It
owns Prepare and Consolidate. The parent must not run any review pass or perform
axis-specific review analysis in the parent thread.

Prepare one shared review packet containing the PR scope, requirements sources,
base/head revisions, complete diff, local QA result, and repository
instructions. Give that packet to every top-level review subagent.

Using the exact provider-native mechanism in the injected contract above, spawn
exactly five top-level subagents in two flat batches. Every worker is a direct
child of the parent; no worker may spawn another worker.

Batch 1 — spawn these two workers concurrently:

1. Matt Standards: load
   `{{SKILLS_DIR}}/matt-pocock-code-review/SKILL.md` and run only its Standards
   axis.
2. Matt Spec: load
   `{{SKILLS_DIR}}/matt-pocock-code-review/SKILL.md` and run only its Spec axis.

Wait for both Matt results, then start batch 2 with these three workers
concurrently:

1. Ponytail: load `{{SKILLS_DIR}}/ponytail-review/SKILL.md`.
2. Isolated Codex: load `{{SKILLS_DIR}}/run-codex-review/SKILL.md`.
3. Supe: load `{{SKILLS_DIR}}/supe-review-code-changes/SKILL.md`.

Give each worker only its assigned pass. Require each to return findings only
to the parent, and wait for all five results.

For the isolated Codex review, its assigned subagent must use:

```bash
node "{{SKILLS_DIR}}/run-codex-review/scripts/review.mjs" \
  --cwd "$(jq -r '.projectRoot' {{WORKSPACE}}/state.json)" \
  --base "<actual-pr-base>"
```

All review workers must remain read-only: they must not edit files, branches,
state, or GitHub. If any of the five top-level review results fails or is
unusable, fail this step. The Matt Spec worker may explicitly report that no
spec is available. The parent must not replace missing delegated work with its
own review. Do not begin Consolidate until the Standards, Spec, Ponytail,
isolated Codex, and Supe results have all returned successfully.

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
