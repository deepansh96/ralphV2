# Ralph v2

Ralph v2 is a GitHub issue-driven pipeline for planning, implementing, reviewing, and opening a PR for one feature. It stores progress in a per-issue `state.json` file and runs each step with the agent assigned in that state.

## CLI

Run commands from the repository root:

```bash
./ralph-v2/ralph.sh --issue N
./ralph-v2/ralph.sh status --issue N
./ralph-v2/ralph.sh logs --issue N
./ralph-v2/ralph.sh logs --issue N --step <step-id>
./ralph-v2/cleanup.sh <issue-number>
```

- `ralph.sh --issue N` validates state and context, then runs pending steps until the pipeline finishes, fails, or blocks for human input.
- `ralph.sh status --issue N` prints a step table with step ID, type, agent, status, duration, and cost.
- `ralph.sh logs --issue N` tails the active step log. Use `--step <step-id>` to read a specific step.
- `cleanup.sh <issue-number>` archives `workspaces/<issue-number>/` into `archive/<date>-<issue-number>/`.

## Monitoring

To monitor a running pipeline, poll with sleep intervals rather than continuously:

```bash
sleep 120 && ./ralph-v2/ralph.sh status --issue N 2>&1
```

## Tests

Run the full deterministic shell suite from the repository root:

```bash
./tests/run.sh
```

Run specific suites by name:

```bash
./tests/run.sh agent pipeline prompt_contracts
```

`tests/test_ralph_v2.sh` is a compatibility wrapper around `tests/run.sh`. The suite is split by behavior under `tests/suites/`, with shared fixtures and fake external tools in `tests/lib/`. See `tests/README.md` for the suite map.

## Workflow

1. Grill the feature into a GitHub issue using the project context and decision workflow. If grilling produces speculative `CONTEXT.md` or ADR changes, keep them on a pushed `grill/*` planning branch instead of committing them directly to `main`.
2. Run the `init.md` prompt for that issue so an agent creates `ralph-v2/workspaces/<issue>/state.json`. By default, init skips review-decisions steps. Opt in with "with 1 review-decision round" or "with 2 review-decision rounds".
3. Set `.baseBranch` explicitly in `state.json` before preflight reaches branch creation. Use the branch that already contains the grilling context: usually `main` for accepted docs, or the pushed `grill/*` planning branch for speculative feature docs.
4. Run `./ralph-v2/ralph.sh --issue N`.
5. If a step blocks, answer the questions in `workspaces/<issue>/hitl-<step-id>.md`, then run the same command again.
6. After the PR workflow completes, run `./ralph-v2/cleanup.sh <issue-number>`.

The fixed flow is:

```text
grill -> init -> run -> cleanup
```

When grilling docs are not ready for `main`, use a stacked branch flow:

```text
main
  -> grill/issue-123-short-slug      # CONTEXT.md / ADR / issue shaping commits
      -> feat/issue-123-short-slug   # Ralph implementation branch
```

In that flow, set `.baseBranch` to `grill/issue-123-short-slug`. Ralph opens the implementation PR against the planning branch. After implementation is accepted, merge the feature branch into the planning branch, then open or merge the planning branch into `main` when the whole feature is ready.

During `run`, Ralph executes:

```text
review-decisions (0-2 rounds, default 0) -> create-and-review-prd -> create-and-review-slices -> preflight -> implement-slice... -> final-review -> pr-review -> review-fixes
```

## State

Each issue has one workspace:

```text
ralph-v2/workspaces/<issue-number>/
```

The workspace contains `state.json`, logs, human-input flag files, and review artifacts.

Top-level `state.json` fields:

```json
{
  "issue": 2,
  "repo": "owner/repo",
  "baseBranch": "main",
  "branch": "feat/issue-2-short-slug",
  "status": "initialized",
  "createdAt": "2026-05-02T00:00:00Z",
  "steps": []
}
```

Each step has this shape:

```json
{
  "id": "implement-slice-14",
  "phase": "fixed",
  "type": "implement-slice",
  "status": "pending",
  "agent": "codex",
  "reviewers": [],
  "hitl": false,
  "sub_issue": 14,
  "metrics": null,
  "notes": ""
}
```

Generated steps use `"agent": "codex"` by default. You can edit an individual step's `agent` in `state.json` before it runs if a different supported agent should own that step.

Step statuses are:

```text
pending -> in_progress -> completed
                       -> blocked
                       -> failed
```

Failed steps stop the pipeline until the user explicitly resets the step to `pending` or marks it `completed`.

## Step Types

- `review-decisions`: reviews issue decisions against `CONTEXT.md`, `CLAUDE.md`, and ADRs; may block for human input.
- `create-and-review-prd`: preserves the original issue body, drafts the PRD, runs council reviews (controlled by `reviewRounds`, default 2), and updates the parent issue.
- `create-and-review-slices`: drafts vertical AFK slices, runs council reviews (controlled by `reviewRounds`, default 2), creates GitHub sub-issues, and links them under the parent.
- `preflight`: checks the working tree and `baseBranch` contract, creates/pushes the feature branch, and appends dynamic steps.
- `implement-slice`: reads the assigned sub-issue, follows TDD, commits, pushes, and closes the sub-issue.
- `final-review`: reviews branch changes, runs quality checks, verifies acceptance criteria, and writes `final-review.md`.
- `pr-review`: creates or updates the PR and runs automated review using the step agent's review path (`code-review:code-review` for Claude, `codex review` for Codex).
- `review-fixes`: evaluates automated review findings, implements fixes for valid issues, dismisses false positives, and posts a summary comment on the PR.

## Bundled Skills

`ralph-v2/skills/` contains the skills used by the prompts:

- `to-prd/`
- `to-issues/`
- `tdd/`
- `domain/`
- `grill-with-docs/`

The bundle is self-contained. Skill references point at files inside `ralph-v2/skills/`, not at the user's global skill directory.
