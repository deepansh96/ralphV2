# Ralph v2

Ralph v2 is a GitHub issue-driven pipeline that grills, plans, implements,
checks, opens a PR, runs local QA, reviews, and cleans local resources for one
feature.

## Start Here

Read `.mex/ROUTER.md` before doing task work. Load only the context and patterns it routes you to.

## Non-Negotiables

- Run Ralph commands from the project root, not from inside `ralph-v2/`.
- Never pipe `ralph.sh --issue N` through `head`, `tail`, or similar commands.
- Treat `workspaces/<issue>/state.json` as the single source of truth.
- Set `.baseBranch` explicitly before preflight.
- Preserve `CLAUDE.md -> AGENTS.md`.

## Planning sessions

Read these before starting, in order. Also read the target project's `CONTEXT.md` and `docs/adr/` if they exist (see `skills/domain-modeling/DOMAIN-AWARENESS.md`).

**Grilling session** (default entry, one-session features):

1. `skills/grill-with-docs/SKILL.md` — the session contract (branch safety, wrap-up issue)
2. `skills/grilling/SKILL.md` — the interview loop (facts from code, decisions from the human, confirmation gate)
3. `skills/domain-modeling/SKILL.md` — glossary and ADR discipline
4. `skills/domain-modeling/CONTEXT-FORMAT.md` and `ADR-FORMAT.md` — only when writing those files

**Wayfinder session** (efforts too big for one grilling session):

1. `skills/wayfinder/SKILL.md` — the map, ticket types, chart/work modes
2. `docs/agents/issue-tracker.md` — the "Wayfinding operations" section (map, tickets, blocking, frontier, claim)
3. `skills/grilling/SKILL.md` and `skills/domain-modeling/SKILL.md` — for naming the destination and grilling tickets
4. `skills/research/SKILL.md` — only when resolving a research ticket

**Pipeline steps** need no manual reading list: each `prompts/<step-type>.md` names the skill files its agent must read.

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
