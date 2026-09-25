# Delegation completion gate

`scripts/delegation-gate.sh` connects the collectors and verifiers to the
runner. A step whose State has a `delegation` key cannot become `completed`
until its provider evidence passes the named policy at `OBSERVED` or
`VERIFIED`. Ralph only observes and gates. The provider's main agent still
chooses, groups, spawns, waits for, and replaces its workers. Ralph never
launches, schedules, or retries a worker.

Run `./tests/run.sh delegation_gate` for the end-to-end checks. The suite drives
`ralph.sh --issue N` with fake Claude, Codex (exec and App Server), and `gh`
binaries. `./tests/run.sh` includes it. Prerequisites are Bash, jq 1.6+, and
Node.js 20+. The deterministic suite needs no provider credentials. The early
collection probes passed on Claude Code 2.1.263 and Codex CLI 0.153.4 (see the
collector guides). Fake fixtures are not compatibility proof: the full gated
path is compatibility-verified only by the real smoke tests in #47 (Claude) and
#48 (Codex).

## Activation

Preflight writes `{"schemaVersion":1,"policy":"qa-v1"}` on new
`runthrough-qa-checklist` steps and `{"schemaVersion":1,"policy":"pr-review-v1"}`
on new `multi-axis-pr-review` steps. On every rerun,
`state_backfill_delegation_metadata STATE STEP POLICY` (`scripts/state.sh`)
fills that metadata only on an existing `pending` step with no `delegation`
key. It never changes an explicit value, even a malformed one, and never
touches completed, running, blocked, or failed steps. Completed steps are never
rechecked.

Steps without a `delegation` key take the unchanged legacy path. They get no
attempt field, no hooks, no session-local worker, and no manifest. Claude keeps
the Workflow contract for them. Always-run cleanup is unchanged; it runs after a
gated failure exactly as after any other failure.

## Runner order

For a gated step, `ralph.sh` calls `delegation_gate_run_step` in place of
`agent_run_step`:

1. **Fail closed before launch.** An agent other than `claude`/`codex`,
   metadata that is not the exact v1 shape (unknown policy or version, extra
   fields, `null`), or a missing or invalid `model`, `reasoningEffort`,
   `subagentModel`, or `subagentReasoningEffort` fails the step. No provider
   runs and no manifest is written.
2. **Stamp and prepare.** `delegation_prepare_invocation` saves a fresh
   `delegationAttempt` in State and creates a private
   `workspaces/<issue>/ralph-delegation-<attempt>/` directory. The callback
   rerenders the prompt from that State, adding HITL answers on a resume, and
   deletes the previous QA plan. For Claude, it creates new hook settings and a
   new parent session ID.
3. **Run the provider once.** Codex runs the normal `codex exec --json`
   command. Claude runs the normal CLI with these additions:
   - a session-local `--agents` `ralph-worker` definition using the step's
     worker model and effort, with Agent and Workflow disallowed;
   - `--forward-subagent-text`, the temporary `--settings` hooks, and
     `--session-id`;
   - `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`, set only for this invocation.

   The log goes to `logs/<step>.log`.
4. **Blocked/HITL.** If the provider exits 0 after marking the step `blocked`,
   the gate removes the invocation inputs and returns. It writes no manifest.
   A resume is a new invocation with a fresh attempt, session, hooks, and plan.
5. **Collect, write, verify.** On any other terminal result, the gate collects
   evidence bound to this attempt:
   - Claude: the hook events for this session.
   - Codex: the single `thread.started` parent in this log, read through a
     fresh App Server, plus the plan when it is schema-valid.

   Unavailable or unbound evidence becomes `null`. The gate builds the
   verification request, which carries the QA refetch facts for `qa-v1`, and
   atomically writes `workspaces/<issue>/delegation/<step>.manifest.json`
   (0600). A nonzero provider exit sets `PROVIDER_FAILED` and keeps any safe
   partial children.
6. **Complete or fail.** The step completes only at `OBSERVED` or `VERIFIED`.
   Any other level uses the existing `failed` status. stderr prints one safe
   line, such as `Delegation gate: step 'multi-axis-pr-review' is UNVERIFIED
   TASK_MISSING`. If the manifest cannot be written, the gate prints
   `MANIFEST_WRITE_FAILED` and the step fails. No manifest is claimed.

The invocation directory is removed after every result: success, failure,
block, internal retry, or interruption. `handle_shutdown` removes the live
directory before resetting the step to `pending`.

## Retries

The existing retry limit (3 invocations) and backoff (`RALPH_RETRY_DELAYS`)
still apply, and so does the retryable-log rule. Before a retry, the gate writes
the failed invocation's `UNVERIFIED`/`PROVIDER_FAILED` manifest, cleans its
inputs, and archives its log as `<step>.log.attempt-N`. It then returns to step
2, so the retry gets a new attempt, prompt, plan slot, hooks, session, and log.
Only the final invocation's manifest decides completion. A first parent that
spawned every worker and then failed cannot supply proof for the second parent.

A manifest is current only when its `attemptId` equals State's
`delegationAttempt.id`. While a retry runs, the file on disk still belongs to
the earlier attempt, so it can never look current. The final write atomically
replaces it. The final attempt stays in State after completion or failure.

## Related guides

- `docs/delegation-contracts.md`: schemas, attempts, and private writes.
- `docs/claude-delegation.md` and `docs/codex-delegation.md`: the collectors.
- `docs/delegation-manifest.md`: the manifest, evidence levels, and `pr-review-v1`.
- `docs/qa-delegation.md`: the QA plan, checklist refetch, and `qa-v1`.
