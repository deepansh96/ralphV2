## Native Delegation Contract — observed Claude Agent

Use native foreground Agent calls with `subagent_type: ralph-worker` for every
delegated task. The runner supplies this session-local definition with model
`{{SUBAGENT_MODEL}}` and effort `{{SUBAGENT_REASONING_EFFORT}}`. Do not override
its model, substitute another worker type, use Workflow, or delegate from workers.
If the configured Agent definition is unavailable, fail rather than substitute.

The parent owns task selection, grouping, launching, waiting, and any permitted
replacement. Follow the step's topology, dependency order, and concurrency limits.
Multiple foreground Agent calls may be issued together where the step allows it.
Await each dependency boundary. Return results to the parent; keep each worker
within its assigned scope. The parent must not take over work assigned to workers.

Begin each worker prompt with `RALPH-TASK: <task-id>` and `RALPH-RUN: <run>`.
QA packets also require `RALPH-ASSIGNMENT: sha256:<64 lowercase hex>` between
those lines. Preserve the exact assigned marker values. PR review uses run 1.
Ralph observes evidence; it does not schedule or launch workers.
