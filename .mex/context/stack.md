---
name: stack
description: Technology stack, tool choices, and version constraints for Ralph v2. Load when working with shell, jq, GitHub, Claude, Codex, council, or mex.
triggers:
  - "library"
  - "dependency"
  - "tool"
  - "shell"
  - "jq"
  - "gh"
  - "codex"
  - "claude"
  - "council"
edges:
  - target: context/decisions.md
    condition: when the reasoning behind a tool or dependency choice is needed
  - target: context/conventions.md
    condition: when using these tools in scripts, prompts, or tests
  - target: context/setup.md
    condition: when installing or validating local command availability
  - target: patterns/change-pipeline-behavior.md
    condition: when a stack choice affects a new or changed pipeline step
last_updated: 2026-07-09
---

# Stack

## Core Technologies

- **Bash** - primary implementation language for CLI, pipeline, state helpers, logs, metrics, and tests.
- **Markdown** - prompt templates, skills, project context, ADR conventions, and mex scaffold files are plain markdown.
- **JSON** - `workspaces/<issue>/state.json`, metrics payloads, and agent/council logs use JSON or JSONL.
- **GitHub Issues and PRs** - the product surface Ralph automates; issues drive PRD, slices, implementation, and review.
- **Git** - branch contracts, clean-tree validation, project-root discovery, and push flows.

## Key Libraries

- **`jq`** - mandatory JSON mutation and validation tool; do not replace with fragile sed/awk JSON edits.
- **`gh`** - GitHub API access; prompts rely on issue body edits, issue views, sub-issue creation, and PR operations.
- **`claude` CLI** - used for context completeness checks and optional Claude-owned steps.
- **`codex` CLI** - default step executor for generated state; run from project root in `scripts/agent.sh`.
- **`council` CLI** - fan-out review runner for decision, PRD, slice, and review-fix workflows.
- **Shell test fakes** - tests fake `claude`, `codex`, `gh`, and `council`; never make deterministic tests depend on real services.

## What We Deliberately Do NOT Use

- No Node, Python, or compiled app runtime for the core pipeline; keep shell changes shell-native unless a real need appears.
- No real external services in tests; use fake commands under `tests/lib/`.
- No background mode from Codex automation; foreground Ralph plus separate status polling is safer.
- No implicit branch defaults; `.baseBranch` must be set explicitly before preflight.
- No global skill dependency; bundled skills live under `skills/`.

## Version Constraints

- `jq`, `git`, and `gh` must be available on PATH for normal operation.
- `claude`, `codex`, and `council` must be available only for steps or prompts that invoke them.
- mex requires Node.js 20+ when using `npx mex-agent`.
