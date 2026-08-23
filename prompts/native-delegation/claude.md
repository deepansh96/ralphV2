## Native Delegation Contract — Claude Code

This prompt explicitly opts in to Claude Code's native dynamic Workflow tool.
Use that tool for the top-level review fan-out because its `agent()` function
can set both the worker model and effort. The plain Agent tool cannot set effort
per invocation.

Implement the two waves in Required Delegation below inside one workflow: await
wave 1, then start wave 2. In wave 1, use `Promise.all` to run two independent
workflow `agent()` calls: one for the Matt skill's Standards axis and one for
its Spec axis. Instruct each worker to load the Matt skill and complete only its
assigned axis. Preserve both results separately.

After both wave 1 results return, use a second `Promise.all` for the three wave
2 skill reviews. On all five workflow `agent()` calls, explicitly set:

- model: `sonnet`
- effort: `high`

Delegate all review exploration and axis-specific analysis. The parent only
plans, launches the workflow, waits for its complete result, and verifies the
returned findings during Consolidate. Do not save a durable workflow.

If the Workflow tool is unavailable or any worker cannot apply the requested
configuration, fail the step. Do not silently use a different worker
configuration.
