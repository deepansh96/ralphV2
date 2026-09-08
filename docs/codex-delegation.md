# Codex collection (opt-in)

`scripts/codex-delegation.sh` reads delegation evidence for one finished
`codex exec` parent through the supported App Server JSON-RPC surface. It does
not change State, write a manifest, verify QA/review policies, decide completion,
or activate production gating. `scripts/agent.sh` keeps its existing flags and
retries. Integration belongs to #44. Ralph remains an observer: the Codex main
agent still chooses, names, spawns, waits for, and replaces its own workers.

## Interfaces

Source the helper from the project root. Bash, jq 1.6+, Node.js 20+, and a
Codex CLI with `app-server` are required for collection; deterministic tests
need no Codex binary or credentials.

- `codex_delegation_parent_id LOG` prints the single `thread.started.thread_id`
  from the current `codex exec --json` log. Zero, several, or malformed records
  fail; log text is never echoed.
- `codex_delegation_threads PARENT` starts a fresh `codex app-server`
  (`CODEX_BIN` overrides the binary, as in the isolated review skill) and prints
  allowlisted facts `{parentId, threads}` for every direct child and descendant.
- `codex_delegation_normalize PARENT [PLAN]` turns those facts (stdin) into the
  sorted #39 child array. A nonzero exit means unavailable or ambiguous evidence,
  never zero workers.
- `codex_delegation_collect PARENT [PLAN]` runs both steps.
- `codex_delegation_evidence PARENT [PLAN]` returns the collector envelope
  `{parentId, children, threads}`. It is not a manifest; retain it for #41.

`PLAN` is an optional QA plan file validated with the shared `plan` schema.

## App Server contract

The collector initializes with `clientInfo` and `capabilities.experimentalApi:
true`, sends `initialized`, then issues only:

1. `thread/list` with `parentThreadId`, the five subagent `sourceKinds`
   (`subAgent`, `subAgentReview`, `subAgentCompact`, `subAgentThreadSpawn`,
   `subAgentOther`), `limit`, and the previous `nextCursor` until it is null.
2. The same pagination with `ancestorThreadId` for all descendants.
3. `thread/read` with `includeTurns: true` for every listed thread.

It never starts threads or turns, writes through the server, calls
`thread/items/list`, sets `useStateDbOnly`, reads rollout files, or answers
server-initiated requests with anything but an error. Server stderr is
discarded. The process exits after the reads and terminates the server.

Evidence is derived only from `Thread.id`, `Thread.parentThreadId`,
`Thread.source.subAgent.thread_spawn` (`depth`, `parent_thread_id`, and the final
`agent_path` segment), `turns[].status`, `startedAt`, `completedAt`, `error`,
and the thread-level `model` / `reasoningEffort` fields. Anything else,
including previews, names, paths, cwd, Git metadata, items, and error messages,
is dropped in memory before output.

## Normalization rules

- Direct children come from the `parentThreadId` listing and must report that
  parent both as `parentThreadId` and as their spawn record parent with depth 1.
  Every direct child must also appear in the descendant listing.
- Every other descendant must chain to the parent through listed threads; it is
  recorded with `nested: true` and its real `parentId`.
- Task identity is the final `agent_path` segment, which Codex derives from the
  `spawn_agent` `task_name`. Exact snake_case names such as `matt_spec` map
  directly with run 1. `qa_r<run>_<64 hex>` names yield the run, the digest
  `sha256:<hex>`, and the plan assignment `taskId` with that digest; without a
  matching assignment the provider name is kept verbatim so the verifier can
  report the mismatch. Missing or malformed names fail collection.
- A child `started` when it has at least one turn. It `completed` only when all
  turns are terminal, the final turn is `completed`, and no turn failed or
  carries an error. A failing turn yields `failed`; a final `interrupted` turn
  yields `stopped`; anything else, including unknown statuses, is `incomplete`.
- `effective.model` and `effective.reasoningEffort` are the thread-level values
  when present and null otherwise. They are persisted configuration, not per-turn
  telemetry, so #41 must still cap evidence at `OBSERVED` when they are null.
- Duplicate thread IDs, unfiltered listings, orphans, unreadable threads,
  malformed pages, pagination errors, a rejected initialize, or an unavailable
  server all fail closed.

## Checks and live probe

Run `./tests/run.sh codex_delegation` for deterministic coverage through a fake
Codex binary whose `app-server` mode serves hand-written pages and records every
request. It also runs in `./tests/run.sh`.

The live probe is excluded from the default suite. It needs an authenticated
Codex CLI with `spawn_agent` and `app-server` (tested on 0.153.4) and access to
the requested models. Register the scratch directory in the issue's
local-resource ledger first, then run:

```bash
RALPH_CODEX_COLLECTION_PROBE=1 \
  tests/probes/codex-collection.sh /absolute/registered/scratch-directory
```

Optional `RALPH_CODEX_PROBE_MODEL` (default `gpt-5.6-sol`),
`RALPH_CODEX_PROBE_WORKER` (default `gpt-5.6-luna`), and
`RALPH_CODEX_PROBE_WORKER_EFFORT` (default `max`) select the models. The probe
renders the existing Codex native contract, asks the parent to spawn exactly one
`matt_spec` worker with a review packet, reads the parent from the exec log,
collects with a fresh App Server process, and checks parentage, start,
completion, task identity, and the output allowlist. It removes its exec log.
Missing access or unsupported evidence fails the command; that is not a
compatibility pass.

On 2026-09-08 the probe passed on Codex CLI 0.153.4 with a `gpt-5.6-sol` parent:
one direct `matt_spec` worker completed, bound to the exec parent by both
`parentThreadId` and its spawn record, and the fresh App Server exposed
`gpt-5.6-luna` / `max` for that child. `thread/list` accepted the
`parentThreadId` and `ancestorThreadId` filters even though the generated
schema for this version omits them, so the collector additionally rejects any
listed thread that is not bound to the parent; an ignored filter can never
pass as evidence. This proves collection only; #48 owns the later full gated
QA smoke test.
