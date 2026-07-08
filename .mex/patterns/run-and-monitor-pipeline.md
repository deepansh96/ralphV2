---
name: run-and-monitor-pipeline
description: How to start, limit, monitor, and report progress on Ralph pipeline runs.
triggers:
  - "run ralph"
  - "monitor"
  - "status"
  - "logs"
  - "poll"
  - "progress"
edges:
  - target: context/setup.md
    condition: when checking commands or prerequisites
  - target: context/architecture.md
    condition: when understanding run-loop behavior or step state
  - target: patterns/recover-failed-or-stale-step.md
    condition: when a step fails, blocks, or becomes stale
last_updated: 2026-07-09
---

# Run And Monitor Pipeline

## Context

Load `context/setup.md` and `context/architecture.md`. Confirm the issue workspace exists and `baseBranch` is set before preflight.

## Steps

1. Confirm state is valid: `jq . workspaces/N/state.json`.
2. Check current table: `./ralph.sh status --issue N`.
3. Run foreground in Codex automation: `./ralph.sh --issue N`.
4. Use `--steps N` only when intentionally limiting progress.
5. For progress updates, leave the foreground run alive and poll from another command: `./ralph.sh status --issue N`.
6. Summarize active step, elapsed time, process alive/dead, and latest meaningful activity. Do not paste raw logs unless asked.
7. If the step blocks or fails, report immediately and follow `recover-failed-or-stale-step.md`.

## Gotchas

- Do not pipe `./ralph.sh --issue N` through `head`, `tail`, or similar commands.
- Avoid `--background` inside Codex tool sessions; the wrapper can die and leave stale state.
- `logs --issue N` follows the active step; use `--step step-id` for a specific log.
- Context completeness check runs before the first completed step and requires `CONTEXT.md`.

## Verify

- [ ] `state.json` validates with `jq`.
- [ ] `baseBranch` is non-null before preflight runs.
- [ ] Foreground run was not piped.
- [ ] Progress update includes active step, elapsed time, process status, and summarized activity.
- [ ] Failed or blocked state was handled with the recovery pattern.

## Debug

- If no active step appears, check pending count and failed/blocked steps.
- If process is dead while state says `in_progress`, follow stale step recovery.
- If logs are empty, check wrapper/session behavior and PID files before rerunning.

## Update Scaffold

- [ ] Update `.mex/ROUTER.md` if run behavior or current known issues changed.
- [ ] Update this pattern if a new monitoring failure mode appears.
