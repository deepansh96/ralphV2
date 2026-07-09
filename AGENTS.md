# Ralph v2

Ralph v2 is a GitHub issue-driven pipeline that grills, plans, implements, reviews, and opens a PR for one feature.

## Start Here

Read `.mex/ROUTER.md` before doing task work. Load only the context and patterns it routes you to.

## Non-Negotiables

- Run Ralph commands from the project root, not from inside `ralph-v2/`.
- Never pipe `ralph.sh --issue N` through `head`, `tail`, or similar commands.
- Treat `workspaces/<issue>/state.json` as the single source of truth.
- Set `.baseBranch` explicitly before preflight.
- Preserve `CLAUDE.md -> AGENTS.md`.

## Issue tracker

GitHub, via the `gh` CLI. Tracker operations — sub-issues, native blocking edges, wayfinding operations — live in `docs/agents/issue-tracker.md`. Skills resolve the tracker through this pointer; do not hardcode tracker commands elsewhere.

## Commands

- Test: `./tests/run.sh`
- Focused tests: `./tests/run.sh agent pipeline prompt_contracts`
- Run pipeline: `./ralph.sh --issue N`
- Status: `./ralph.sh status --issue N`
- Logs: `./ralph.sh logs --issue N --step step-id`
- Cleanup: `./cleanup.sh N`
- mex drift: `npx mex-agent check --quiet`
