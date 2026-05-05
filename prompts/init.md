# Ralph v2 Workspace Initialization

Initialize a Ralph v2 workspace for GitHub issue `{{ISSUE}}` in repo `{{REPO}}`.

## Required Inputs

- Issue: `{{ISSUE}}`
- Repo: `{{REPO}}`
- Workspace: `ralph-v2/workspaces/{{ISSUE}}` (`workspaces/{{ISSUE}}` relative to `ralph-v2/`)

## Hard Requirements

- Validate that the GitHub CLI is available before doing any other work:
  `command -v gh`
- Read the GitHub issue before creating state:
  `gh issue view {{ISSUE}} --repo {{REPO}}`
- Create `ralph-v2/workspaces/{{ISSUE}}/`.
- Write exactly one state file at `ralph-v2/workspaces/{{ISSUE}}/state.json`.
- Running init on an already-initialized workspace must not overwrite existing state. If `ralph-v2/workspaces/{{ISSUE}}/state.json` already exists, stop with a clear warning or error.
- Set both `"baseBranch": null` and `"branch": null`. Do not infer defaults.
- Capture `"projectRoot"` by running `git rev-parse --show-toplevel` from the project root (not from inside `ralph-v2/`). Store the absolute path.
- Hardcode the agent defaults shown below. Do not use runtime agent detection.
- After writing state, verify it with `jq` and confirm that `./ralph-v2/ralph.sh status --issue {{ISSUE}}` shows five pending steps.

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
    {
      "id": "review-decisions-1",
      "phase": "fixed",
      "type": "review-decisions",
      "status": "pending",
      "agent": "claude",
      "reviewers": ["codex", "gemini", "kimi", "deepseek", "claude-opus", "claude-sonnet"],
      "hitl": false,
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

## Implementation Steps

1. Run `command -v gh`. If it fails, stop and report that the GitHub CLI is required.
2. Run `gh issue view {{ISSUE}} --repo {{REPO}}`. If it fails, stop and report the issue lookup failure.
3. If `ralph-v2/workspaces/{{ISSUE}}/state.json` exists, stop. Do not silently overwrite it.
4. Create `ralph-v2/workspaces/{{ISSUE}}/`.
5. Write `state.json` using the schema above. Use a current UTC ISO-8601 timestamp for `createdAt`.
6. Validate the file with `jq`.
7. Run `./ralph-v2/ralph.sh status --issue {{ISSUE}}` and confirm it prints all five fixed steps with `pending` status.

Do not run any pipeline step. This prompt only initializes the workspace state.
