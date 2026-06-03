# Ralph v2

Ralph v2 is a GitHub issue-driven pipeline that takes a feature from idea to PR autonomously. Clone it as `ralph-v2/` inside any project root.

## Prerequisites

- `gh` CLI authenticated
- `CONTEXT.md` at the project root (ralph creates one during grilling if missing)
- `CLAUDE.md` at the project root (the target project's, not this file)

## Workflow

The full lifecycle is: **grill → init → run → cleanup**.

### 1. Grill

Stress-test the feature idea against the project's domain model before writing any code.

```
Read ralph-v2/skills/grill-with-docs/SKILL.md and run a grilling session for this feature: <describe feature>
```

Output: a well-defined GitHub issue with clear scope, decisions, and acceptance criteria. The grilling session also creates or updates `CONTEXT.md` and any ADRs.

If those documentation changes are speculative or feature-specific, keep them on a pushed planning branch such as `grill/issue-N-short-slug` instead of committing them directly to the default branch. Later, set Ralph's `.baseBranch` to that planning branch so the implementation branch stacks on top of the grilled context.

### 2. Init

Create the workspace and state file for the issue.

```
Read ralph-v2/prompts/init.md and execute it for issue N in repo owner/repo
```

By default, init creates no review-decisions steps and sets `reviewRounds: 1` on the PRD and slices steps. To opt into review-decisions steps or change PRD/slice review rounds:

```
Read ralph-v2/prompts/init.md and execute it for issue N in repo owner/repo with 1 review-decision round
Read ralph-v2/prompts/init.md and execute it for issue N in repo owner/repo with 2 review-decision rounds
Read ralph-v2/prompts/init.md and execute it for issue N in repo owner/repo with 1 review round on PRD and 0 on slices
```

Output: `ralph-v2/workspaces/<issue>/state.json` with fixed steps (3–5 depending on review rounds) all pending.

**After init, set `.baseBranch` in state.json** to the branch you want the feature branch created from. This is required — preflight will fail without it. Use the branch that already contains the relevant grilled context: the default branch if the docs were merged there, or the pushed `grill/*` planning branch if the docs are still feature-specific.

### 3. Run

Execute the pipeline. This is the autonomous loop.

```bash
./ralph-v2/ralph.sh --issue N
```

Ralph runs steps sequentially: review-decisions (0–2 rounds, default 0) → create-and-review-prd → create-and-review-slices → preflight → implement-slice(s) → final-review → pr-review → review-fixes.

- Preflight creates the feature branch and appends dynamic steps (one per sub-issue slice, plus final-review, pr-review, review-fixes).
- If a step blocks for human input, ralph stops and prints the flag file path. Answer the questions there, then re-run the same command.
- If a step fails, ralph stops. Fix the issue, reset the step status to `pending` in state.json, and re-run.
- Use `--steps N` to limit how many steps run before stopping.

### 4. Cleanup

Archive the workspace after the PR is merged.

```bash
./ralph-v2/cleanup.sh <issue-number>
```

## Useful commands

```bash
./ralph-v2/ralph.sh status --issue N          # step table with status, agent, duration, cost
./ralph-v2/ralph.sh logs --issue N             # tail active step log
./ralph-v2/ralph.sh logs --issue N --step X    # read a specific step's log
```

To monitor a running pipeline, poll with sleep intervals rather than continuously:

```bash
sleep 120 && ./ralph-v2/ralph.sh status --issue N 2>&1
```

## Tests

Run Ralph's deterministic shell tests from the `ralph-v2/` repository root:

```bash
./tests/run.sh
```

Run a focused suite by name:

```bash
./tests/run.sh agent pipeline prompt_contracts
```

`tests/test_ralph_v2.sh` remains as a compatibility wrapper. New tests should live under `tests/suites/`, use shared helpers from `tests/lib/test_helpers.sh`, and fake external tools such as `claude`, `codex`, `gh`, and `council` instead of calling real services.

## Key rules

- All commands run from the **project root**, not from inside `ralph-v2/`.
- **Never pipe ralph commands through `head`, `tail`, or similar** — ralph spawns long-running subprocesses that produce output slowly. Piping causes buffering deadlocks.
- In Codex automation, run long Ralph jobs in the foreground with `./ralph-v2/ralph.sh --issue N` and poll status or logs from another command.
- Avoid `./ralph-v2/ralph.sh --issue N --background` in Codex `exec_command` sessions. The nohup wrapper can be torn down when the tool session returns, leaving a stale `in_progress` step with empty logs. Use background mode only from a persistent shell, tmux session, or equivalent terminal that will stay alive.
- If a stale background run occurs, reset the affected step in `state.json` from `in_progress` to `pending`, clear its stale `pid` and `startedAt` fields, remove its pid file, then rerun Ralph in foreground.
- `state.json` is the single source of truth. Agents read it, update it, and ralph.sh dispatches based on it.
- Review steps use a `reviewers` array (e.g. `["codex", "gemini", "kimi", "deepseek", "claude-opus", "claude-sonnet"]`). Edit it per-step to add/remove council agents.
- `create-and-review-prd` and `create-and-review-slices` have a `reviewRounds` field (0, 1, or 2, default 1) controlling how many council rounds run inside the step. Edit it per-step in state.json.
- Non-review steps have `"reviewers": []`.
- Generated steps run on `codex` by default. Individual steps can still be edited in `state.json` to use another supported agent when needed.
- `CONTEXT.md`, `CLAUDE.md`, and `docs/adr/` are read from the project root — not from inside `ralph-v2/`.
