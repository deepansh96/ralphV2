## Native Delegation Contract — Claude Code

Use Claude Code's native Agent tool for every delegated review. Explicitly set
every top-level and nested review subagent to:

- model: `sonnet`
- effort: `high`

Do not omit either value or inherit the parent agent's model or effort. Pass
this same requirement to any subagent that must spawn nested reviewers.
Delegate all review exploration and axis-specific analysis. The parent only
plans, coordinates, waits for the delegated results, and verifies them during
Consolidate.

If the native Agent tool cannot apply the requested model and effort, fail the
step. Do not silently use a different worker configuration.
