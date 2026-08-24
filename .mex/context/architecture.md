---
name: architecture
description: How Ralph v2 pipeline pieces connect and flow. Load when working on system design, integrations, prompt dispatch, or state behavior.
triggers:
  - "architecture"
  - "pipeline"
  - "state"
  - "prompt"
  - "agent"
  - "integration"
edges:
  - target: context/stack.md
    condition: when specific shell, jq, GitHub, Claude, Codex, Pi, DeepSeek, or council details are needed
  - target: context/decisions.md
    condition: when understanding why the pipeline, branch, review, or agent defaults exist
  - target: context/conventions.md
    condition: when editing scripts, prompts, tests, or docs in this architecture
  - target: patterns/run-and-monitor-pipeline.md
    condition: when executing or observing a live pipeline
last_updated: 2026-08-24
---

# Architecture

## System Overview

User starts with a GitHub issue -> `prompts/init.md` creates `workspaces/<issue>/state.json`, the local-resource ledger, and the always-run cleanup step -> `ralph.sh --issue N` validates state and context -> `prompt_render` combines a step prompt with state/workspace values -> `agent_run_step` dispatches to Claude, Codex, or DeepSeek through Pi -> the agent edits project files, GitHub issues, PR comments, or workspace artifacts -> `state_update_step` records completion, failure, HITL, metrics, PID, and notes -> preflight appends dynamic implementation/check/PR/QA/review steps -> post-merge `cleanup.sh` archives the workspace.

The pipeline is issue-driven and state-driven. `ralph.sh` does not infer missing branch contracts once running; `state.json` decides which step runs next and which agent owns it. Repo-wide provider defaults live in `ralph.config.json`; optional step fields override them for that issue.

## Key Components

- **`ralph.sh`** - CLI entrypoint and run loop; handles `run`, `status`, `logs`, `poll`, HITL resume, foreground/background dispatch, step limits, and shutdown reset.
- **`scripts/state.sh`** - state access and mutation layer; validates failed/stale steps, selects pending or blocked steps, defers `alwaysRun` cleanup behind normal work while prioritizing it after failure, rearms completed cleanup when normal work is retried, appends dynamic steps, and writes PID files.
- **`scripts/agent.sh`** - execution adapter for `claude`, `codex`, and `deepseek`; maps optional per-step model and `reasoningEffort` overrides to Claude, Codex, or Pi CLI flags, then wraps retries, logging, working directory handling, and metrics extraction.
- **`scripts/prompt.sh`** - renders prompt templates by replacing `{{ISSUE}}`, `{{REPO}}`, `{{WORKSPACE}}`, `{{BRANCH}}`, `{{BASE_BRANCH}}`, `{{STEP_ID}}`, `{{SUB_ISSUE}}`, `{{SKILLS_DIR}}`, `{{REVIEWERS}}`, and `{{AGENT}}`. Templates that request `{{NATIVE_DELEGATION_CONTRACT}}` receive the matching reusable Claude or Codex prompt fragment. Worker model and effort resolve from per-step `subagentModel` / `subagentReasoningEffort` overrides, then `ralph.config.json` provider defaults; rendering fails when the provider or required settings are missing.
- **`ralph.config.json`** - repo-wide defaults for provider-native delegation. Codex defaults to Luna/max and Claude defaults to Sonnet/high; individual state steps may override either value.
- **`prompts/`** - one markdown contract per step type; downstream agents initialize workspaces, plan, implement, check, create the PR, prepare/run local QA, consolidate five review passes across four skills, and clean local resources. QA and PR review leave flat worker orchestration to their main agent while the provider fragment pins supported worker settings. Preflight backfills missing cleanup artifacts for older initialized workspaces.
- **`skills/`** - bundled task guidance includes planning/TDD/domain skills plus `matt-pocock-code-review`, `ponytail-review`, `run-codex-review`, and `supe-review-code-changes`; grilling asks dependency-ordered question rounds; `quiz-grilling` can present those rounds through a disposable local web app and temporary tunnel; Wayfinder uses decision tickets and may fan out read-only research subagents while the parent owns all writes; `writing-for-agents`, `codebase-design`, `improve-codebase-architecture`, `prototype`, `wizard`, and `wait-what` are optional support outside the fixed pipeline. Prompt references stay inside the repository. Tracker operations live in `docs/agents/issue-tracker.md`, referenced from `AGENTS.md`.
- **`tests/`** - deterministic shell suite with shared fakes for external tools; validates behavior without real GitHub, Claude, Codex, Pi, or council calls.

## External Dependencies

- **GitHub CLI (`gh`)** - required by init and agent prompts to read/edit issues, create sub-issues, push branches, and create/update PRs.
- **Claude CLI (`claude`)** - used by `context_check` and by steps whose `agent` is `claude`; emits stream JSON logs consumed for metrics.
- **Codex CLI (`codex`)** - default generated step agent; `scripts/agent.sh` runs it from the project root with danger-full-access sandbox and JSON logging.
- **Pi CLI (`pi`)** - runs steps whose `agent` is `deepseek`; `scripts/agent.sh` selects the DeepSeek provider and consumes Pi's JSON event stream.
- **Council CLI (`council`)** - multi-agent review harness used by review prompts and `scripts/council-review.sh`.
- **Cloudflare Quick Tunnels or ngrok** - optionally expose a quiz-grilling session's loopback server to another device; the session records and cleans up the tunnel process.
- **Git** - branch creation, status checks, pushes, and project-root discovery underpin preflight and agent working directories.
- **`jq`** - required for all state manipulation, prompt rendering fields, status tables, and JSON validation.
- **mex (`npx mex-agent`)** - repository memory scaffold under `.mex/`; use `npx mex-agent check` and `npx mex-agent sync` unless mex is installed globally.

## What Does NOT Exist Here

- No deployed web service, database, daemon, or long-running server lives in this repo; `quiz-grilling` starts only a session-owned temporary local server.
- No package manager build step is needed for Ralph itself.
- No runtime persistence outside Git, GitHub, per-issue workspaces, logs, and `.mex/events`.
- No automatic recovery for failed work; Ralph runs pending `alwaysRun` cleanup and then a human or agent must reset the failed step intentionally.
- No safe default `baseBranch`; init writes it as `null` and preflight requires an explicit value.
