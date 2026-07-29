# Preflight

Prepare the repository for implementation of GitHub issue `{{ISSUE}}` in repo `{{REPO}}`.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Step: {{STEP_ID}}
Base branch: {{BASE_BRANCH}}

Default agent: codex

## Goal

Validate that implementation can start from an explicit base branch; create and
push the feature branch; read the AFK implementation sub-issues from GitHub;
and append the dynamic implementation, checks, PR, QA, review, and cleanup
steps.

## Required Inputs

- Read the parent issue:
  `gh issue view {{ISSUE}} --repo {{REPO}}`
- Read `{{WORKSPACE}}/state.json`.
- Read the sub-issues linked under the parent issue on GitHub. Prefer GitHub's sub-issue relationship data when available; also inspect issue bodies that reference `Parent: #{{ISSUE}}` so re-runs can recover from partial linkage.
- Source the state manager before extending state:
  `source ./ralph-v2/scripts/state.sh`

## Hard Stops

On any hard stop failure, set this step's status to `failed` in `{{WORKSPACE}}/state.json` with a note explaining the failure, then stop. Ralph will detect the `failed` status and halt the pipeline.

1. Verify `baseBranch` in `state.json` is not `null` or empty. If it is missing, null, or empty, error with clear guidance to set `.baseBranch` explicitly in `{{WORKSPACE}}/state.json` before re-running preflight.
2. Run `git status --porcelain`. If the output is not empty, stop with clear guidance to commit or stash local changes before preflight. If the dirty files are grilling docs (`CONTEXT.md`, `docs/adr/`, or similar), tell the user to commit and push them to the branch that will be used as `.baseBranch`.
3. Verify the named base branch exists locally or can be fetched from the remote before creating the feature branch.
4. Verify the selected base branch contract:
   - If `baseBranch` starts with `grill/`, it must exist on the remote (`git ls-remote --exit-code --heads origin {{BASE_BRANCH}}`) before feature branch creation. Ralph will create `feat/issue-{{ISSUE}}-<slug>` from that planning branch; at PR time the pr-creation step merges the planning branch into the feature branch and targets the PR at the branch the planning branch was created from (the repository default branch).
   - If `baseBranch` is `main`, `master`, or the repository default branch, the user is asserting that any required grilling `CONTEXT.md` or ADR changes have already been committed and pushed or merged there.
   - For any other base branch, verify it is pushed or otherwise fetchable from `origin`; the PR will target that branch.

## Branch Creation

Create the feature branch from `baseBranch`.

- Derive the slug from the parent issue title.
- kebab-case the slug: lowercase, replace non-alphanumeric runs with single hyphens, trim leading and trailing hyphens.
- Truncate the slug to keep the branch name reasonably short.
- Branch name format must be:
  `feat/issue-{{ISSUE}}-<slug>`
- idempotent behavior:
  - If the branch already exists locally, check it out instead of creating a duplicate.
  - If the branch exists on the remote but not locally, check it out tracking the remote branch.
  - If the branch does not exist, create it from `baseBranch`.
- Push the branch to the remote immediately with upstream tracking:
  `git push -u origin <branch>`
- Update the top-level `branch` field in `{{WORKSPACE}}/state.json` to the feature branch name using an atomic temp-file write.

## Dynamic Steps

Read the implementation sub-issues created by the
`create-and-review-slices` step and append one implementation step per
sub-issue, followed by the terminal steps below.

Order the sub-issues before building steps: sort them topologically by their blocking edges (read from native issue dependencies and `Blocked by` body lines) so every blocker's steps come before any slice it blocks; break ties by ascending issue number. Do not rely on the order GitHub returns sub-issues — the body-reference fallback in particular can return arbitrary order, and a blocked slice ordered before its blocker would fail the implement-slice blocker check on a valid plan.

Each implementation step must use this shape:

```json
{
  "id": "implement-slice-<sub-issue-number>",
  "phase": "dynamic",
  "type": "implement-slice",
  "status": "pending",
  "agent": "codex",
  "reviewers": [],
  "hitl": false,
  "sub_issue": <sub-issue-number>,
  "metrics": null,
  "notes": ""
}
```

Append these steps after all implementation steps, in this exact order:

```json
{
  "id": "final-checks",
  "phase": "dynamic",
  "type": "final-checks",
  "status": "pending",
  "agent": "codex",
  "reviewers": [],
  "hitl": false,
  "metrics": null,
  "notes": ""
}
```

```json
{
  "id": "pr-creation",
  "phase": "dynamic",
  "type": "pr-creation",
  "status": "pending",
  "agent": "codex",
  "reviewers": [],
  "hitl": false,
  "metrics": null,
  "notes": ""
}
```

```json
{
  "id": "prepare-qa-checklist",
  "phase": "dynamic",
  "type": "prepare-qa-checklist",
  "status": "pending",
  "agent": "codex",
  "reviewers": [],
  "hitl": false,
  "metrics": null,
  "notes": ""
}
```

```json
{
  "id": "runthrough-qa-checklist",
  "phase": "dynamic",
  "type": "runthrough-qa-checklist",
  "status": "pending",
  "agent": "codex",
  "reviewers": [],
  "hitl": false,
  "metrics": null,
  "notes": ""
}
```

```json
{
  "id": "multi-axis-pr-review",
  "phase": "dynamic",
  "type": "multi-axis-pr-review",
  "status": "pending",
  "agent": "codex",
  "reviewers": [],
  "hitl": false,
  "metrics": null,
  "notes": ""
}
```

```json
{
  "id": "cleanup-local-resources",
  "phase": "dynamic",
  "type": "cleanup-local-resources",
  "status": "pending",
  "agent": "codex",
  "reviewers": [],
  "hitl": false,
  "alwaysRun": true,
  "metrics": null,
  "notes": ""
}
```

Use `state_add_steps "{{WORKSPACE}}/state.json" '<json-array>'` to extend the state file. `state_add_steps` prevents duplicate step IDs and writes atomically.

## Idempotency

Preflight must be safe to re-run.

- Do not create duplicate branches.
- Do not append duplicate dynamic steps.
- If all intended dynamic steps already exist, leave the step array unchanged.
- If some dynamic steps are missing, append only the missing steps in the correct order.
- Preserve existing completed, in-progress, blocked, failed, and pending statuses for steps already present.

Initialize `{{WORKSPACE}}/local-resources.json` to this valid JSON when it does
not exist. Do not overwrite an existing ledger:

```json
{"processes":[],"containers":[],"tempPaths":[],"sessions":[]}
```

## Verification

After updating state, run:

```bash
./ralph-v2/ralph.sh status --issue {{ISSUE}}
```

Confirm the status output shows the fixed pipeline plus all dynamic steps:

- N `implement-slice` steps with `agent` set to `codex` and the correct `sub_issue` value for each GitHub sub-issue
- no `review-slice` or `review-fixes` steps
- `final-checks`, `pr-creation`, `prepare-qa-checklist`,
  `runthrough-qa-checklist`, and `multi-axis-pr-review` with `agent` set to
  `codex`
- `cleanup-local-resources` last, with `agent` set to `codex` and
  `alwaysRun: true`

Complete normally only after the branch is pushed, the `branch` field is
updated, sub-issues are read from GitHub, the resource ledger exists, and
state contains the full dynamic pipeline.
