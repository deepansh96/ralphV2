---
name: recover-failed-or-stale-step
description: How to recover Ralph steps that failed, blocked, or became stale in progress.
triggers:
  - "failed step"
  - "stale"
  - "in_progress"
  - "blocked"
  - "HITL"
  - "pid"
  - "retry"
edges:
  - target: context/architecture.md
    condition: when understanding state, PID, log, and HITL flow
  - target: context/conventions.md
    condition: when editing state safely
  - target: patterns/run-and-monitor-pipeline.md
    condition: when rerunning or monitoring after recovery
last_updated: 2026-07-09
---

# Recover Failed Or Stale Step

## Context

Load `context/architecture.md` and `context/conventions.md`. Identify the issue workspace before editing anything.

## Steps

1. Check current state: `./ralph.sh status --issue N`.
2. Inspect the step log: `./ralph.sh logs --issue N --step step-id`.
3. For `blocked`, open `workspaces/N/hitl-step-id.md`, answer under `## Answers`, and rerun Ralph.
4. For `failed`, fix the root cause first, then reset only that step to `pending`.
5. For stale `in_progress`, check `workspaces/N/pids/step-id.pid` and whether the PID is alive.
6. If the runner and child agent are dead, reset the step to `pending`, clear stale PID and `started_at`, remove the stale pid file, and rerun.
7. Validate state with `jq . workspaces/N/state.json`.

## Gotchas

- Killing `ralph.sh` alone can leave a Claude or Codex subprocess running.
- Only `ralph.sh` updates `state.json`; orphaned agents may finish work but not advance state.
- Failed steps intentionally stop reruns until the user or agent resets them.
- Do not reset unrelated steps just to make the table look clean.

## Verify

- [ ] The root cause is fixed or the HITL answers are present.
- [ ] `jq . workspaces/N/state.json` passes.
- [ ] Only the intended step status changed.
- [ ] Stale pid files were removed when resetting stale `in_progress`.
- [ ] `./ralph.sh status --issue N` shows a coherent next step.

## Debug

- If a step flips back to failed, read the newest step log and retry attempt logs.
- If a blocked step does not resume, ensure answers are below a `## Answers` heading.
- If status reports a stale process, confirm whether the PID belongs to the current workspace before killing it.

## Update Scaffold

- [ ] Add any new recovery gotcha to this pattern.
- [ ] Update `.mex/context/setup.md` if a new common issue emerged.
