---
name: decisions
description: Key Ralph v2 architectural and workflow decisions with reasoning. Load when changing pipeline policy or understanding why behavior exists.
triggers:
  - "why do we"
  - "decision"
  - "baseBranch"
  - "review"
  - "agent"
  - "background"
  - "HITL"
edges:
  - target: context/architecture.md
    condition: when a decision relates to pipeline flow or component boundaries
  - target: context/stack.md
    condition: when a decision relates to shell, jq, gh, Claude, Codex, council, or mex
  - target: patterns/run-and-monitor-pipeline.md
    condition: when a decision affects live run behavior
  - target: patterns/initialize-issue-workspace.md
    condition: when a decision affects init or branch contracts
last_updated: 2026-07-09
---

# Decisions

## Decision Log

### Use mex for routed agent memory
**Date:** 2026-07-09
**Status:** Active
**Decision:** Store structured agent memory in `.mex/` while keeping root `AGENTS.md` as the tool-loaded anchor and `CLAUDE.md` as a symlink to it.
**Reasoning:** mex keeps long-lived project context, patterns, and drift checks out of one giant instruction file while remaining compatible with Codex and Claude.
**Alternatives considered:** Keep only root `AGENTS.md` with all instructions (rejected because it grows into a large prompt dump), or replace Ralph docs entirely with mex (rejected because README, CONTEXT, and prompt docs remain useful user-facing docs).
**Consequences:** Agents should read `.mex/ROUTER.md` at session start and use `npx mex-agent check` to detect scaffold drift.

### Require explicit `baseBranch` before preflight
**Date:** 2026-06-07
**Status:** Active
**Decision:** `init` writes `"baseBranch": null`, and humans or agents must set it explicitly before preflight creates a feature branch.
**Reasoning:** Grilling can create speculative `CONTEXT.md` or ADR changes that should live on a pushed `grill/*` planning branch instead of silently using `main`.
**Alternatives considered:** Default to `main` (rejected because it can drop planning context), or infer the current branch (rejected because it is fragile in automation).
**Consequences:** Preflight must fail if `baseBranch` is missing; setup and run guidance must mention the branch contract.

### Default generated steps to Codex
**Date:** 2026-06-07
**Status:** Active
**Decision:** Init creates generated non-review steps with `"agent": "codex"` by default, while allowing per-step edits before execution.
**Reasoning:** Codex is the default executor in this repository's current state schema, and explicit state keeps ownership auditable.
**Alternatives considered:** Runtime agent detection (rejected because it makes state less reproducible), or Claude-only defaults (rejected because Codex support is first-class here).
**Consequences:** `scripts/agent.sh` must keep Codex working-directory behavior correct, and tests must fake Codex paths.

### Keep Ralph state as the single source of truth
**Date:** 2026-05-02
**Status:** Active
**Decision:** Pipeline progress, branch fields, step order, statuses, metrics, HITL, reviewers, and agent assignment live in `workspaces/<issue>/state.json`.
**Reasoning:** A single state file makes recovery, retry, status, and test assertions deterministic.
**Alternatives considered:** Derive progress from logs or GitHub comments (rejected because both are incomplete and harder to mutate safely).
**Consequences:** All state edits must use `jq`, failed steps stop the pipeline, and manual recovery must validate JSON before rerun.

### Use foreground Ralph runs in Codex automation
**Date:** 2026-06-07
**Status:** Active
**Decision:** Codex automation should run long Ralph jobs in foreground and poll status/logs from another command instead of using `--background`.
**Reasoning:** The background nohup wrapper can be torn down when a tool session returns, leaving stale `in_progress` state and empty logs.
**Alternatives considered:** Always use `--background` (rejected due to stale wrapper risk), or always run in a user terminal (rejected because Codex often controls execution).
**Consequences:** Progress updates should poll `./ralph.sh status --issue N`; stale background runs require resetting step status, PID, and pid files.

### Write downstream planning output to GitHub issue bodies
**Date:** 2026-05-02
**Status:** Active
**Decision:** PRD content, slice outputs, and downstream-readable planning summaries belong in GitHub issue bodies, not comments.
**Reasoning:** `gh issue view` reads issue bodies by default, and downstream prompts rely on that content.
**Alternatives considered:** Put council output and PRD content in comments (rejected because downstream steps can miss it).
**Consequences:** Prompts must use `gh issue edit --body-file` when later steps need the content.
