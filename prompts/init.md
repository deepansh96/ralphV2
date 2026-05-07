# Ralph v2 Workspace Initialization

Initialize a Ralph v2 workspace for GitHub issue `{{ISSUE}}` in repo `{{REPO}}`.

## Required Inputs

- Issue: `{{ISSUE}}`
- Repo: `{{REPO}}`
- Workspace: `ralph-v2/workspaces/{{ISSUE}}` (`workspaces/{{ISSUE}}` relative to `ralph-v2/`)

## Review-Decisions Rounds

The number of review-decisions steps is configurable: **0, 1, or 2** (default **2**).

- **2 rounds (default):** `review-decisions-1` with `hitl: false`, then `review-decisions-2` with `hitl: true`. Two-pass review: first council feedback, then human checkpoint.
- **1 round:** `review-decisions-1` with `hitl: true`. Council feedback + human checkpoint in a single pass.
- **0 rounds:** No review-decisions steps. Pipeline starts at `create-and-review-prd`.

If the user does not mention review rounds, use the default of 2. If the user requests a specific count (e.g. "with 1 review round", "with 0 review rounds", "skip review decisions"), use that count.

## Hard Requirements

- Validate that the GitHub CLI is available before doing any other work:
  `command -v gh`
- Read the GitHub issue before creating state:
  `gh issue view {{ISSUE}} --repo {{REPO}}`
- Verify the working tree is clean before creating state:
  `git status --porcelain`
  If output is not empty, error that the working tree is dirty and the user must commit or stash changes (e.g. from a grilling session) before initializing.
- Create `ralph-v2/workspaces/{{ISSUE}}/`.
- Write exactly one state file at `ralph-v2/workspaces/{{ISSUE}}/state.json`.
- Running init on an already-initialized workspace must not overwrite existing state. If `ralph-v2/workspaces/{{ISSUE}}/state.json` already exists, stop with a clear warning or error.
- Set both `"baseBranch": null` and `"branch": null`. Do not infer defaults.
- Capture `"projectRoot"` by running `git rev-parse --show-toplevel` from the project root (not from inside `ralph-v2/`). Store the absolute path.
- Hardcode the agent defaults shown below. Do not use runtime agent detection.
- After writing state, verify it with `jq` and confirm that `./ralph-v2/ralph.sh status --issue {{ISSUE}}` shows all steps with pending status.

## State Schema

Write `ralph-v2/workspaces/{{ISSUE}}/state.json` with this shape:

```json
{
  "issue": {{ISSUE}},
  "repo": "{{REPO}}",
  "baseBranch": null,
  "branch": null,
  "projectRoot": "<absolute path from git rev-parse --show-toplevel>",
  "status": "initialized",
  "createdAt": "<ISO-8601 UTC timestamp>",
  "steps": [
    // --- review-decisions steps (include based on requested round count) ---
    // If 2 rounds (default): include both steps below
    // If 1 round: include only review-decisions-1 with hitl: true
    // If 0 rounds: omit both steps entirely
    {
      "id": "review-decisions-1",
      "phase": "fixed",
      "type": "review-decisions",
      "status": "pending",
      "agent": "claude",
      "reviewers": ["codex", "gemini", "kimi", "deepseek", "claude-opus", "claude-sonnet"],
      "hitl": false,  // set to true when this is the only round (1 round)
      "metrics": null,
      "notes": ""
    },
    {
      "id": "review-decisions-2",
      "phase": "fixed",
      "type": "review-decisions",
      "status": "pending",
      "agent": "claude",
      "reviewers": ["codex", "gemini", "kimi", "deepseek", "claude-opus", "claude-sonnet"],
      "hitl": true,
      "metrics": null,
      "notes": ""
    },
    // --- end review-decisions steps ---
    {
      "id": "create-and-review-prd",
      "phase": "fixed",
      "type": "create-and-review-prd",
      "status": "pending",
      "agent": "claude",
      "reviewers": ["codex", "gemini", "kimi", "deepseek", "claude-opus", "claude-sonnet"],
      "hitl": false,
      "metrics": null,
      "notes": ""
    },
    {
      "id": "create-and-review-slices",
      "phase": "fixed",
      "type": "create-and-review-slices",
      "status": "pending",
      "agent": "claude",
      "reviewers": ["codex", "gemini", "kimi", "deepseek", "claude-opus", "claude-sonnet"],
      "hitl": false,
      "metrics": null,
      "notes": ""
    },
    {
      "id": "preflight",
      "phase": "fixed",
      "type": "preflight",
      "status": "pending",
      "agent": "claude",
      "reviewers": [],
      "hitl": false,
      "metrics": null,
      "notes": ""
    }
  ]
}
```

**Review-decisions round rules:**
- **2 rounds (default):** Include both `review-decisions-1` (`hitl: false`) and `review-decisions-2` (`hitl: true`). Total fixed steps: 5.
- **1 round:** Include only `review-decisions-1` with `hitl: true`. Total fixed steps: 4.
- **0 rounds:** Omit both review-decisions steps. Steps start at `create-and-review-prd`. Total fixed steps: 3.

The actual `state.json` output must be valid JSON (no comments). The comments above are for your reference only.

## Implementation Steps

1. Run `command -v gh`. If it fails, stop and report that the GitHub CLI is required.
2. Run `gh issue view {{ISSUE}} --repo {{REPO}}`. If it fails, stop and report the issue lookup failure.
3. Run `git status --porcelain`. If the output is not empty, stop and report that the working tree must be clean before initializing.
4. If `ralph-v2/workspaces/{{ISSUE}}/state.json` exists, stop. Do not silently overwrite it.
5. Create `ralph-v2/workspaces/{{ISSUE}}/`.
6. Write `state.json` using the schema above. Use a current UTC ISO-8601 timestamp for `createdAt`.
7. Validate the file with `jq`.
8. Run `./ralph-v2/ralph.sh status --issue {{ISSUE}}` and confirm all steps show `pending` status.

Do not run any pipeline step. This prompt only initializes the workspace state.
