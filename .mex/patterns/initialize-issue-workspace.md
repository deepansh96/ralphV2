---
name: initialize-issue-workspace
description: How to initialize Ralph state for a GitHub issue without breaking the branch contract.
triggers:
  - "init"
  - "initialize"
  - "state.json"
  - "baseBranch"
  - "workspace"
edges:
  - target: context/setup.md
    condition: when checking prerequisites or first-time setup commands
  - target: context/decisions.md
    condition: when reasoning about baseBranch or review-round defaults
  - target: context/conventions.md
    condition: when editing or validating state JSON
last_updated: 2026-07-30
---

# Initialize Issue Workspace

## Context

Load `context/setup.md`, `context/decisions.md`, and `context/conventions.md`. Read `prompts/init.md` before making or reviewing an init change.

## Steps

1. Confirm prerequisites: `command -v gh`, `gh auth status`, and a clean `git status --porcelain`.
2. Read the issue with `gh issue view N --repo owner/repo`.
3. Run or follow `prompts/init.md` for the issue and repo.
4. Create exactly one `workspaces/N/state.json` plus its empty
   `local-resources.json` ledger; do not overwrite an existing initialized
   workspace.
5. Keep `"baseBranch": null` and `"branch": null` during init unless the user separately tells you to set `baseBranch` after init.
6. Set review-decision steps and PRD/slice `reviewRounds` only when explicitly requested.
7. Validate both JSON files with `jq`.
8. Confirm `./ralph.sh status --issue N` shows all steps pending.

## Gotchas

- A dirty tree before init usually means grilling docs need to be committed first.
- `baseBranch` is required before preflight but intentionally not inferred during init.
- Review-decision rounds and PRD/slice review rounds are separate knobs.
- Generated steps default to `codex`; do not use runtime agent detection.
- Init includes pending `cleanup-local-resources`; the scheduler defers it
  behind normal work.

## Verify

- [ ] `git status --porcelain` was checked before creating state.
- [ ] Existing `workspaces/N/state.json` was not overwritten.
- [ ] `jq . workspaces/N/state.json` passes.
- [ ] `jq . workspaces/N/local-resources.json` passes.
- [ ] `baseBranch` is `null` immediately after init unless explicitly set afterward.
- [ ] `./ralph.sh status --issue N` works and shows pending steps.

## Debug

- If `gh issue view` fails, check repo owner/name and authentication.
- If status fails, validate JSON and verify required fields: `issue`, `repo`, `baseBranch`, `branch`, `projectRoot`, `status`, `createdAt`, and `steps`.
- If preflight later fails, check `baseBranch` and clean-tree status first.

## Update Scaffold

- [ ] Update `.mex/context/decisions.md` if init defaults or branch policy changed.
- [ ] Update `.mex/context/setup.md` if prerequisites or commands changed.
