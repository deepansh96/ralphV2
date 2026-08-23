## Native Delegation Contract — Codex

Use Codex's native subagent tooling for every delegated review. On every
`spawn_agent` call, explicitly set every top-level and nested review subagent
to:

- model: `gpt-5.6-luna`
- `reasoning_effort`: `max`

Use `fork_turns: "none"` and include the complete review packet in the task
message so the worker configuration does not inherit from the parent. Do not
omit any of these values. Pass this same requirement to any subagent that must
spawn nested reviewers.

For wave 1, spawn exactly one Matt review coordinator with these settings. It
must load the Matt skill, then spawn its Standards and Spec reviewers in
parallel with the same Luna/max/no-history settings and return both results.
For wave 2, spawn the three skill reviewers concurrently with these settings.

Delegate all review exploration and axis-specific analysis. The parent only
plans, coordinates, waits for the delegated results, and verifies them during
Consolidate.

If the native subagent tool cannot apply the requested model and reasoning
effort, fail the step. Do not silently use a different worker configuration.
