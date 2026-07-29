---
name: change-pipeline-behavior
description: How to add or change Ralph step, prompt, script, or pipeline behavior safely.
triggers:
  - "add step"
  - "change pipeline"
  - "prompt contract"
  - "preflight"
  - "implement-slice"
  - "cleanup-local-resources"
edges:
  - target: context/architecture.md
    condition: when mapping the new behavior into the run loop and state flow
  - target: context/conventions.md
    condition: when editing shell, prompts, state fields, or tests
  - target: context/decisions.md
    condition: when changing default agent, branch, review, or HITL policy
last_updated: 2026-07-30
---

# Change Pipeline Behavior

## Context

Load `context/architecture.md` and `context/conventions.md`. If the change touches branch contracts, review defaults, agent defaults, or HITL behavior, also load `context/decisions.md`.

## Steps

1. Find the behavior owner: `ralph.sh` for run-loop/CLI behavior, `scripts/*.sh` for helpers, `prompts/<step-type>.md` for agent contracts, or `tests/suites/*_test.sh` for expected behavior.
2. Grep callers before editing shared helpers: `rg "function_or_step_name|step-type"`.
3. Keep state schema changes explicit and mutate state with `jq`.
4. If adding a step type, add or update its prompt in `prompts/`, ensure `prompt_render` has every placeholder it uses, and add deterministic tests.
5. If changing agent execution, preserve the project-root `cd` for Codex and retry/metrics behavior for both agents.
6. Update README, `CONTEXT.md`, `.mex/context/*`, or pattern docs only when the user-facing workflow changes.

## Gotchas

- A prompt can look correct but fail at runtime if it references a placeholder not rendered by `scripts/prompt.sh`.
- Downstream steps read issue bodies with `gh issue view`; comments are not a substitute for PRD or slice content.
- `state.json` can become malformed through manual edits; always validate with `jq`.
- Tests must fake `claude`, `codex`, `gh`, and `council` rather than calling real services.

## Verify

- [ ] `bash -n` passes for changed shell files.
- [ ] `jq .` passes for changed JSON files or sample state.
- [ ] Focused suite passes, for example `./tests/run.sh prompt_contracts pipeline agent`.
- [ ] `./tests/run.sh` passes when the change affects shared flow.
- [ ] `npx mex-agent check --quiet` passes or remaining drift is reported.

## Debug

- For prompt failures, inspect rendered prompt inputs and placeholder names in `scripts/prompt.sh`.
- For state failures, inspect `workspaces/<issue>/state.json` and reproduce with a focused `tests/suites/state_test.sh` case.
- For agent failures, inspect the step log plus any `.attempt-N` retry logs.

## Update Scaffold

- [ ] Update `.mex/ROUTER.md` "Current Project State" if behavior changed.
- [ ] Update relevant `.mex/context/` files if architecture, stack, conventions, or decisions changed.
- [ ] Add or update a pattern if the new workflow can recur.
