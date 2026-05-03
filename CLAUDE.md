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

### 2. Init

Create the workspace and state file for the issue.

```
Read ralph-v2/prompts/init.md and execute it for issue N in repo owner/repo
```

Output: `ralph-v2/workspaces/<issue>/state.json` with four fixed steps (review-decisions, create-and-review-prd, create-and-review-slices, preflight) all pending.

**After init, set `.baseBranch` in state.json** to the branch you want the feature branch created from. This is required — preflight will fail without it.

### 3. Run

Execute the pipeline. This is the autonomous loop.

```bash
./ralph-v2/ralph.sh --issue N
```

Ralph runs steps sequentially: review-decisions → create-and-review-prd → create-and-review-slices → preflight → implement-slice(s) → final-review → pr-review → review-fixes.

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

## Key rules

- All commands run from the **project root**, not from inside `ralph-v2/`.
- `state.json` is the single source of truth. Agents read it, update it, and ralph.sh dispatches based on it.
- Review steps use a `reviewers` array (e.g. `["codex", "gemini", "kimi", "deepseek"]`). Edit it per-step to add/remove council agents.
- Non-review steps have `"reviewers": []`.
- Implementation steps run on `codex`. Review and planning steps run on `claude`.
- `CONTEXT.md`, `CLAUDE.md`, and `docs/adr/` are read from the project root — not from inside `ralph-v2/`.
