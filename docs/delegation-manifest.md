# Delegation manifest and PR-review verification (not yet wired)

`scripts/delegation-manifest.sh` turns bound collector evidence into the v1
manifest and verifies the `pr-review-v1` policy. Source it from the project
root; it loads `scripts/delegation.sh`. Bash, jq 1.6+, and Node.js 20+ are
required. Run `./tests/run.sh delegation_manifest prompt_contracts` for the
focused deterministic suite; `./tests/run.sh` includes it. No provider
credentials are needed.

Nothing calls these helpers in production yet. `ralph.sh`, `scripts/agent.sh`,
and `scripts/state.sh` complete steps exactly as before. #44 connects the
verifier to the runner; #43 and #46 add `qa-v1`, which this verifier reports as
`POLICY_UNSUPPORTED` today. Ralph remains an observer and gate: the provider's
main agent still chooses, names, spawns, waits for, and replaces its workers.
Ralph never launches, groups, schedules, or retries them.

## Interfaces

- `delegation_requested_settings` reads one step JSON on stdin and prints
  `{parent:{model,reasoningEffort},worker:{model,reasoningEffort}}` from the
  saved `model`, `reasoningEffort`, `subagentModel`, and
  `subagentReasoningEffort` fields. Any missing value is a configuration error
  (nonzero). Worker settings are never inferred from child output.
- `delegation_evidence_from_envelope PROVIDER ATTEMPT PARENT` reads a
  `claude_delegation_evidence` or `codex_delegation_evidence` envelope on stdin
  and prints the neutral evidence object `{attemptId, parentId, children,
  modelHistory}`. `ATTEMPT` and `PARENT` are the values the caller collected
  under. Claude `modelHistory` maps each returned child ID to its reported
  `modelsUsed`; Codex has none because its thread-level model is already the
  child's effective model. A Codex envelope bound to another parent fails.
- `delegation_manifest_build` reads one verification request on stdin (schema
  `request`) and prints the manifest. A malformed request exits nonzero and
  echoes nothing. Policy failures are never exit codes: they become mismatch
  codes inside an `UNVERIFIED` manifest.
- `delegation_manifest_write WORKSPACE` reads a manifest on stdin and writes
  `WORKSPACE/delegation/<stepId>.manifest.json`, printing the path. The
  directory is created with mode 0700; the file is written through the shared
  same-directory temporary file, chmod 0600, fsync, close, and atomic rename.
  An invalid manifest leaves the previous file intact. Register workspace
  ownership before calling.
- `delegation_manifest_passes` reads a manifest on stdin and exits zero only
  for `OBSERVED` or `VERIFIED`.

The request shape is:

```json
{
  "issue": 37,
  "stepId": "multi-axis-pr-review",
  "attemptId": "<current State delegationAttempt.id>",
  "provider": "codex",
  "policy": "pr-review-v1",
  "requested": { "parent": { "model": "gpt-5.6-sol", "reasoningEffort": "medium" },
                 "worker": { "model": "gpt-5.6-luna", "reasoningEffort": "max" } },
  "providerFailed": false,
  "evidence": { "attemptId": "<collected attempt>", "parentId": "<opaque id>",
                "children": [], "modelHistory": {} }
}
```

`evidence` is `null` when the collector failed or returned unbound evidence.
`providerFailed: true` records a provider exit failure; the runner may still
pass whatever partial children were bound.

## Manifest rules

The manifest follows #37 exactly: fixed key order, `evidenceSource`
`app-server` for Codex and `hooks` for Claude, `expected` task IDs sorted,
children sorted by `taskId`, `run`, then `childId`, and unique lexicographically
sorted `mismatchCodes`. Every child carries the full normalized record plus
`disposition`; `pr-review-v1` has no supersession, so every record is
`selected`. `parentId` is `null` only when no evidence bound a parent, such as a
provider that failed before reporting its thread.

`observed` counts cover direct children only (`nested: false`):
`selectedCount` is their number, `startedCount` those that started, and
`completedCount` those that completed. Nested descendants are listed for audit
and flagged but never counted as workers, so status can later render `N/M`
from `completedCount` and `expected.taskCount` alone.

Identical evidence produces identical bytes regardless of input order. Only
allowlisted fields are copied; a request carrying prompts, responses, paths,
raw events, or any other unknown field is rejected, and the manifest schema
rejects unknown keys at every level.

## Evidence levels

- `UNVERIFIED`: at least one mismatch code. The future gate fails the step.
- `OBSERVED`: no mismatch codes, but at least one direct child lacks an
  effective model or effort. This passes the v1 gate.
- `VERIFIED`: no mismatch codes and every direct child reports an effective
  model and effort that match `requested.worker`.

Missing effective settings never fail a run and are never invented.

## Settings comparison

Child settings are compared only with `requested.worker`; the parent settings
are recorded for audit and never compared. A Sol/medium parent with Luna/max
children is `VERIFIED`; children that report Sol/medium fail with
`MODEL_MISMATCH` and `EFFORT_MISMATCH`.

An explicit requested model ID requires an exact match. A supported family
alias (`sonnet`, `opus`, `haiku`, `fable`) accepts only a provider-reported
canonical Claude ID of that family, such as `claude-sonnet-4-6` for `sonnet`;
a bare alias reported back, a cross-family ID, or a different explicit ID is
`MODEL_MISMATCH`. Unknown short names are not aliases and must match exactly.
The child's effective model records the actual canonical ID, never the alias.
Every `modelHistory` entry is checked as well as the effective model, so a
mid-run model change cannot hide behind the final resolved model. Effort must
equal the requested worker effort exactly.

## `pr-review-v1`

Expected identities are the five `(taskId, run 1)` pairs for `isolated_codex`,
`matt_spec`, `matt_standards`, `ponytail`, and `supe`. Codes:

| Code | Meaning |
| --- | --- |
| `TASK_MISSING` | An expected identity has no direct child. |
| `TASK_DUPLICATED` | An expected identity has more than one direct child. |
| `TASK_UNEXPECTED` | A direct child has an unexpected task ID or a run other than 1 (retries are not allowed). |
| `CHILD_MISSING` | A direct child never started. |
| `CHILD_INCOMPLETE` | A direct child started but did not finish. |
| `CHILD_FAILED` / `CHILD_STOPPED` | A direct child failed or was interrupted. |
| `NESTED_WORKER` | A descendant below a direct child exists. |
| `PARENT_MISMATCH` | A direct child is bound to another parent. |
| `MODEL_MISMATCH` / `EFFORT_MISMATCH` | Reported settings differ from `requested.worker`. |
| `ATTEMPT_MISSING` / `ATTEMPT_MISMATCH` | Evidence is not bound to the current State attempt. |
| `EVIDENCE_UNAVAILABLE` | The request carried no evidence. |
| `PROVIDER_FAILED` | The provider invocation failed; the manifest is always `UNVERIFIED`. |
| `POLICY_UNSUPPORTED` | The policy has no verifier yet (`qa-v1`). |

Task identity is judged only when the policy is supported and evidence exists;
lifecycle, nesting, parent, and settings checks apply to every listed record.
`MANIFEST_WRITE_FAILED` is reserved for the runner when `delegation_manifest_write`
fails. The remaining vocabulary belongs to `qa-v1`.

## Prompt contract

`prompts/multi-axis-pr-review.md` now requires the five exact task IDs as the
provider task name (Codex `task_name`) and the first two packet lines
`RALPH-TASK: <task-id>` and `RALPH-RUN: 1`, with no retries, duplicates, or
extra workers. The provider fragments under `prompts/native-delegation/` stay
policy-free; `prompt_contracts_test.sh` checks both.
