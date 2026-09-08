# Claude collection (opt-in)

`scripts/claude-delegation.sh` observes one Claude invocation. It does not change
State, write a manifest, verify QA/review policies, or activate production gating.
`scripts/agent.sh` retains its existing flags and retries. Integration belongs to
#44; that caller must prepare fresh inputs for every internal retry and collect
partial evidence before cleanup on provider failure.

## Interfaces

Source the helper from the project root:

- `claude_delegation_prepare WORKSPACE ATTEMPT PARENT [WORKER_MODEL WORKER_EFFORT]`
  creates a fresh private directory and returns its path. Register ownership of
  the workspace before calling. Each invocation gets distinct settings and events.
- `claude_delegation_collect INPUTS ATTEMPT PARENT` returns the sorted #39 child
  array. A nonzero exit means unavailable or ambiguous evidence, never zero work.
- `claude_delegation_evidence INPUTS ATTEMPT PARENT` returns a collector envelope
  with `children`, `requested` worker settings, and sanitized `events`. This is
  not a manifest. Retain this envelope for the future verifier: `modelsUsed`,
  resolved model and explicit requested overrides must not be discarded.
- `claude_delegation_cleanup INPUTS` removes only that invocation's known files.
- `claude_delegation_invoke WORKSPACE ATTEMPT PROMPT PARENT_MODEL PARENT_EFFORT
  WORKER_MODEL WORKER_EFFORT [CLI_OPTIONS...]` is the isolated probe adapter. It
  returns the envelope on success and cleans inputs on success, failure, INT and
  TERM. Production integration can use prepare/collect/cleanup separately.

The adapter passes `--forward-subagent-text`, temporary `--settings`, an explicit
parent session ID, and a session-local `--agents` definition named `ralph-worker`.
Worker model and effort are parameters; the definition disables Agent/Workflow
nesting. Only this invocation sets `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`.
The Claude parent still chooses and launches its own workers. No persistent
project/user settings or agent definitions are edited.

The prompt renderer selects `native-delegation/claude-agent.md` only when the
step has delegation metadata. The isolated probe explicitly selects this variant
without writing metadata into State. Ungated rendering retains Workflow.

## Evidence and limits

Hook input is parsed only in memory and bound to the configured parent session.
Files use 0600 inside a fresh 0700 directory; event appends are flushed with fsync.
The sanitizer stores event kind and only these event-specific fields:

| Event | Fields |
| --- | --- |
| PreToolUse | tool_use_id, agent_id, subagent_type, model, taskId, assignmentDigest, run |
| PostToolUse | tool_use_id, agentId, status, resolvedModel, modelsUsed |
| PostToolUseFailure | tool_use_id, status |
| SubagentStart | agent_id, agent_type |
| SubagentStop | agent_id, agent_type, status, effort.level |

Workflow hooks become a fixed `UnsupportedWorkflow` event, with no input fields.
Rejected hook input leaves a fixed `HOOK_FAILED` marker, never raw diagnostics.
Forwarded output retains only a validated parent tool-use ID as an activity fact;
it is not lifecycle proof. Prompts, responses, final messages, transcript paths,
commands, authentication fields and raw events never enter collector files.
Provider-owned internal storage is outside this collector's control.

Pre/Post records join by tool-use ID, then start/stop by returned child ID.
Completion requires all three lifecycle facts and a completed foreground return.
Missing starts/stops remain incomplete; ambiguous or unbound records fail closed.
An invoking `agent_id` means nesting; malformed or null invoking IDs are rejected.
Conflicting worker types and explicit requested model overrides fail collection.
Effective settings stay null when absent. Alias and model-history policy checks
belong to #41. Only the supplied attempt and parent are read; sibling old hooks
and retry logs cannot supply evidence.

## Checks and live probe

Run `./tests/run.sh claude_delegation` for deterministic normalizer and fake CLI
coverage. It also runs in `./tests/run.sh`. Fixtures use hand-written literals
based on the Claude 2.1.263 foreground Agent research shapes, including an omitted
per-call model, null stop status, and separate resolved model/model-history facts.

The live probe is excluded from the default suite. It needs Bash, jq, Node.js,
Claude Code with foreground Agent definitions/hooks (tested on 2.1.263), and an
authenticated profile that can access the requested models. Register its process
and scratch directory in the issue's local-resource ledger first, then run:

```bash
RALPH_CLAUDE_COLLECTION_PROBE=1 \
  tests/probes/claude-collection.sh /absolute/registered/scratch-directory
```

Set `CLAUDE_CONFIG_DIR` externally when selecting a different authenticated
profile. Optional `RALPH_CLAUDE_PROBE_MODEL` defaults to `opus`;
`RALPH_CLAUDE_PROBE_WORKER` defaults to the explicit ID `claude-sonnet-5`.
The probe requests high worker effort, disables MCP access, and gives the parent
only Agent/TaskOutput. It requests two distinct arithmetic packets, including a
synthetic QA assignment digest, and checks direct parentage, starts, completion,
markers, canonical model, high effort, and the output allowlist. Missing access
or unsupported evidence fails the command; it is not a compatibility pass.

On 2026-09-08 the independently rerun probe passed on Claude Code 2.1.263: two
direct workers completed using `claude-sonnet-5`/high, with the review marker and
QA digest separately bound. Temporary collector inputs were removed. This proves
collection only; #47 owns the later full gated QA smoke test.
