## Native Delegation Contract — Claude Code

This prompt explicitly opts in to Claude Code's native dynamic Workflow tool.
Use that tool for every task that the step prompt marks as delegated because its
`agent()` function can set both the worker model and effort. The plain Agent tool
cannot set effort per invocation.

Build one session-scoped workflow that preserves the delegation topology,
dependency order, and concurrency boundaries defined by the step prompt. Use
`Promise.all` only for work that the step explicitly allows to run concurrently,
and await each dependency boundary before starting dependent work.

On every workflow `agent()` call, explicitly set:

- model: `{{SUBAGENT_MODEL}}`
- effort: `{{SUBAGENT_REASONING_EFFORT}}`

Include the complete task packet in each call, give the worker only its assigned
scope, and require it to return its result to the parent. The parent plans,
launches, waits, and verifies. It performs responsibilities that the step assigns
to the parent, but it must not take over exploration, execution, implementation,
or checks that the step assigns to workers. Do not save a durable workflow.

If the Workflow tool is unavailable or any worker cannot apply the requested
configuration, fail the step. Do not silently use a different worker
configuration.
