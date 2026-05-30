# Preflight

Prepare the repository for implementation of GitHub issue `{{ISSUE}}` in repo `{{REPO}}`.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Step: {{STEP_ID}}
Base branch: {{BASE_BRANCH}}

Default agent: codex

## Goal

Validate that implementation can start from an explicit base branch; create and push the feature branch; read the AFK implementation sub-issues from GitHub; and extend `{{WORKSPACE}}/state.json` with dynamic implementation, final review, PR review, and review-fixes steps.

## Required Inputs

- Read the parent issue:
  `gh issue view {{ISSUE}} --repo {{REPO}}`
- Read `{{WORKSPACE}}/state.json`.
- Read the sub-issues linked under the parent issue on GitHub. Prefer GitHub's sub-issue relationship data when available; also inspect issue bodies that reference `Parent: #{{ISSUE}}` so re-runs can recover from partial linkage.
- Run State and Artifact helper commands in bash before extending state or filtering issues. Do not source these helpers from zsh or another non-bash shell:
  `source ./ralph-v2/scripts/state.sh`
  `source ./ralph-v2/scripts/artifacts.sh`

## Hard Stops

On any hard stop failure, set this step's status to `failed` in `{{WORKSPACE}}/state.json` with a note explaining the failure, then stop. Ralph will detect the `failed` status and halt the pipeline.

1. Verify `baseBranch` in `state.json` is not `null` or empty. If it is missing, null, or empty, error with clear guidance to set `.baseBranch` explicitly in `{{WORKSPACE}}/state.json` before re-running preflight.
2. Run `git status --porcelain`. If the output is not empty, stop with clear guidance to commit or stash local changes before preflight. If the dirty files are grilling docs (`CONTEXT.md`, `docs/adr/`, or similar), tell the user to commit and push them to the branch that will be used as `.baseBranch`.
3. Verify the named base branch exists locally or can be fetched from the remote before creating the feature branch.
4. Verify the selected base branch contract:
   - If `baseBranch` starts with `grill/`, it must exist on the remote (`git ls-remote --exit-code --heads origin {{BASE_BRANCH}}`) before feature branch creation. Ralph will create `feat/issue-{{ISSUE}}-<slug>` from that planning branch and the PR will target that planning branch.
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

Read the implementation sub-issues created by the `create-and-review-slices` step and append one implementation step per eligible sub-issue, followed by final review, PR review, and review-fixes.

Use the shared Artifact Helper eligibility routines instead of hand-rolled `grep` filtering:

- Build a JSON file of linked or marker-discovered candidate issues with at least `number`, `state`, and `body`.
- Call `artifact_collect_preflight_slices "{{WORKSPACE}}/state.json" "{{ISSUE}}" <candidates-json-file> <skip-notes-file>` to produce the implementation slice issue numbers.
- `artifact_collect_preflight_slices` uses `slice_is_eligible_implementation <issue-body-file> "{{ISSUE}}" <issue-state> <already-tracked>` for the exact eligibility decision.
- An issue is eligible only when it has exact full-line `AFK: true`, exact full-line `Parent: #{{ISSUE}}`, no `Ralph-Artifact:` provenance marker, and an open issue state unless an existing State Step already tracks that issue.
- Issues with both `AFK: true` and `Ralph-Artifact:` are malformed Artifact Issue metadata. Exclude them, keep the skip note, and make sure the malformed note remains visible in logs and the next Parent Issue Index refresh.
- Issues with `AFK: true` but the wrong parent are excluded.
- Issues with non-exact marker formatting such as `AFK:true`, `Parent:#{{ISSUE}}`, trailing marker whitespace, or quoted/list-marker variants are excluded.
- Closed matching slice issues are included only when an existing State Step already tracks them.
- Filtering must succeed when zero Artifact Issues exist under the parent; do not require Artifact Issues to be present before preflight can proceed.
- Artifact Issues linked under the parent must never become `implement-slice` Steps, even if their body also contains `AFK: true` later in the content.

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

Append the final steps after all implementation steps:

```json
{
  "id": "final-review",
  "phase": "dynamic",
  "type": "final-review",
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
  "id": "pr-review",
  "phase": "dynamic",
  "type": "pr-review",
  "status": "pending",
  "agent": "codex",
  "reviewers": ["codex", "gemini", "kimi", "deepseek", "claude-opus", "claude-sonnet"],
  "hitl": false,
  "metrics": null,
  "notes": ""
}
```

```json
{
  "id": "review-fixes",
  "phase": "dynamic",
  "type": "review-fixes",
  "status": "pending",
  "agent": "codex",
  "reviewers": [],
  "hitl": false,
  "metrics": null,
  "notes": ""
}
```

Use `state_add_steps "{{WORKSPACE}}/state.json" '<json-array>'` to extend the state file. `state_add_steps` prevents duplicate step IDs and writes atomically.

After branch setup and dynamic Step setup are complete, call:

```bash
artifact_refresh_parent_index "{{WORKSPACE}}/state.json" "{{REPO}}" "{{ISSUE}}" <skip-notes-file>
```

This refresh records branch and implementation-slice routing in the compact Parent Issue Index. If the skip-notes file contains malformed or excluded issue notes, preserve those notes in the refresh path so the operator can see why candidate issues were skipped.

## Idempotency

Preflight must be safe to re-run.

- Do not create duplicate branches.
- Do not append duplicate dynamic steps.
- If all intended dynamic steps already exist, leave the step array unchanged.
- If some dynamic steps are missing, append only the missing steps in the correct order.
- Preserve existing completed, in-progress, blocked, failed, and pending statuses for steps already present.

## Verification

After updating state, run:

```bash
./ralph-v2/ralph.sh status --issue {{ISSUE}}
```

Confirm the status output shows the fixed pipeline plus all dynamic steps:

- N `implement-slice` steps with `agent` set to `codex` and the correct `sub_issue` value for each GitHub sub-issue
- `final-review` with `agent` set to `codex`
- `pr-review` with `agent` set to `codex`
- `review-fixes` with `agent` set to `codex`

Complete normally only after the branch is pushed, the `branch` field is updated, sub-issues are read from GitHub, and state contains the full dynamic pipeline.
