## Native Delegation Contract — Codex

Use Codex's native subagent tooling for every task that the step prompt marks
as delegated. On every `spawn_agent` call for that work, explicitly set:

- model: `{{SUBAGENT_MODEL}}`
- `reasoning_effort`: `{{SUBAGENT_REASONING_EFFORT}}`

Use `fork_turns: "none"` and include the complete task packet in the message so
the worker does not depend on the parent conversation. Do not omit any of these
values.

Preserve the delegation topology, dependency order, and concurrency boundaries
defined by the step prompt. Give each worker only its assigned scope and require
it to return its result to the parent.

The parent plans, coordinates, waits, and verifies. It performs responsibilities
that the step assigns to the parent, but it must not take over exploration,
execution, implementation, or checks that the step assigns to workers.

If the native subagent tool cannot apply the requested model and reasoning
effort, fail the step. Do not silently use a different worker configuration.
