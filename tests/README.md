# Ralph v2 Test Suite

Run the full suite from the repository root:

```bash
./tests/run.sh
```

Run one or more suites by name:

```bash
./tests/run.sh prompt_contracts agent
```

`tests/test_ralph_v2.sh` remains as a compatibility wrapper for older commands.

## Suite Map

- `cli_test.sh`: CLI argument validation, status output, logs, and activity snippets.
- `cleanup_test.sh`: workspace archival and cleanup error handling.
- `context_test.sh`: `CONTEXT.md` gate behavior before pipeline execution.
- `agent_test.sh`: Claude, Codex, and DeepSeek/Pi dispatch, retries, metrics, logs, and working directory handling.
- `state_test.sh`: state transitions, dynamic step appends, metrics fields, and stale PID recovery.
- `delegation_test.sh`: shared delegation schemas, safe artifact writes, and fresh invocation preparation.
- `claude_delegation_test.sh`: opt-in Claude hook sanitization, lifecycle correlation, and the fake foreground Agent CLI seam.
- `codex_delegation_test.sh`: opt-in Codex App Server collection through a fake JSON-RPC server: exact read-only requests, pagination, lifecycle, nesting, task identity, and fail-closed evidence.
- `pipeline_test.sh`: run-loop behavior, HITL resume, failed-step handling, and simulated workflow steps.
- `background_poll_test.sh`: background wrapper and polling behavior.
- `council_test.sh`: council submit/status/read/cleanup wrapper behavior.
- `runner_test.sh`: suite selection and missing-suite errors for `tests/run.sh`.
- `prompt_render_test.sh`: prompt placeholder rendering and missing-template failures.
- `prompt_contracts_test.sh`: prompt and skill contracts that downstream agents must follow.
- `skill_docs_test.sh`: bundled skill/link integrity and workflow documentation.
- `parse_log_test.sh`: log summarization for Claude, Codex, and Pi JSONL output.

External tools such as `claude`, `codex`, `pi`, `gh`, and `council` are faked inside the suite. Tests must be deterministic, offline, and safe to run repeatedly.
