# QA checklist format, plan, and `qa-v1` verification (not yet wired)

`scripts/delegation-qa.sh` parses the marked QA checklist comment, computes the
canonical digests, writes the immutable QA assignment plan, and refetches the
checklist for verification. `scripts/delegation-manifest.sh` verifies `qa-v1`
from those facts plus collector evidence. Source them from the project root.
Bash, jq 1.6+, Node.js 20+, and an authenticated `gh` (for the real comment
fetch) are required. Run `./tests/run.sh delegation_qa prompt_contracts` for
the focused deterministic suite; it uses a fake `gh` and needs no credentials.
`./tests/run.sh` includes it.

Nothing calls the verifier in production yet: runner completion is unchanged
until #44. The QA parent still chooses the groups, spawns, and waits for its
workers. Ralph only snapshots what the parent planned and later checks what the
provider reports. This slice accepts one successful direct run-1 worker per
assignment; replacement runs and `superseded` dispositions arrive in #46 before
activation.

## Checklist comment format

`prepare-qa-checklist` writes, and `runthrough-qa-checklist` updates, one PR
comment in this exact format:

```md
<!-- ralph:qa-checklist -->
## Local QA Checklist

- [ ] [PENDING] QA-01: <behavior>
  - Setup: ...
  - Action: ...
  - Expected: ...
  - Isolation: ...
```

Parser rules (`delegation_qa_checklist_items`):

1. CRLF is normalized to LF. The marker appears exactly once and is the first
   nonblank line; the next nonblank line is exactly `## Local QA Checklist`.
2. The checklist ends at `<!-- ralph:qa-summary -->` or the end of the comment.
   Everything after the summary marker is ignored.
3. An item line is `- [ ] ` or `- [x] `, then one of `[PENDING]`, `[PASS]`,
   `[FAIL]`, `[BLOCKED]`, then `QA-` plus two or more digits, `: `, and the
   behavior text.
4. Instruction lines start with `  - Setup: `, `  - Action: `,
   `  - Expected: `, or `  - Isolation: `. Progress lines start with
   `  - Result: ` or `  - Evidence: `. A line indented by four or more spaces
   continues the preceding instruction or progress line. Blank lines are
   ignored. Any other line rejects the comment.
5. An item's text is its behavior plus its instruction lines, verbatim, joined
   with LF and outer whitespace trimmed. Checkbox state, status tag, progress
   lines, and the summary are excluded.
6. Zero items, a duplicate ID, or an empty text rejects the comment (exit 2).

So progress edits (checkbox, tag, Result/Evidence, summary) keep the same
items; changing an ID or instruction, or adding or removing an item, does not.

## Canonical digests

- Checklist digest: SHA-256 of compact UTF-8 JSON of the items sorted by `id`,
  each exactly `{"id":…,"text":…}` in that key order
  (`delegation_qa_checklist_digest`).
- Assignment digest: SHA-256 of compact JSON of exactly
  `{"taskId":…,"checklistItemIds":[…sorted]}` (`delegation_qa_assignment_digest`).

Both print `sha256:<64 lowercase hex>`. Vectors in `tests/suites/delegation_qa_test.sh`
were produced independently with `shasum -a 256`.

## Plan

Before its first spawn the QA parent runs:

```bash
source ./ralph-v2/scripts/delegation-qa.sh
delegation_qa_plan_write <workspace>/state.json runthrough-qa-checklist <owner/repo> <comment-id> <<< '<assignments JSON>'
```

Assignments are `[{taskId, checklistItemIds}]`. The helper refetches the exact
comment, requires every snapshot ID in exactly one assignment, and atomically
writes `<workspace>/delegation/runthrough-qa-checklist.plan.json` (0600) in the
#37 shape: `schemaVersion`, `stepId`, `attemptId` (State's
`delegationAttempt.id`, or `ungated` for a legacy step, which no gate accepts),
`checklist {commentId, updatedAt, digest, items}`, and sorted `assignments`
with their digests. It prints the plan so the parent can copy each digest.

Each worker packet begins with:

```text
RALPH-TASK: <taskId>
RALPH-ASSIGNMENT: <assignmentDigest>
RALPH-RUN: 1
```

Codex workers use `spawn_agent.task_name` `qa_r1_<assignment-digest-hex>`. The
Codex collector maps that digest back to the plan's task ID; Claude hooks parse
the three packet lines.

## Verification

After the provider run the runner calls
`delegation_qa_verification PLAN_FILE REPO`, which prints the request's `qa`
field `{plan, checklist}`: the plan file's value (`null` when absent,
`"invalid"` when unparsable) and the refetch of the plan's exact `commentId`
as `{commentId, status: ok|unavailable|invalid, items}`. A `qa-v1` request must
carry this field; other policies must not. `updatedAt` is audit metadata and is
never compared.

| Code | Meaning |
| --- | --- |
| `PLAN_MISSING` | No plan file. |
| `PLAN_INVALID` | Unparsable, unknown fields, wrong schema version or step, malformed or duplicate IDs, bad checklist digest, or an assigned ID not in the snapshot. No task identity is judged. |
| `ATTEMPT_MISMATCH` | The plan belongs to another attempt. |
| `ASSIGNMENT_DIGEST_MISMATCH` | A plan digest is not canonical, or a direct child's digest/task pair is not one plan assignment. |
| `ASSIGNMENT_MISSING` / `ASSIGNMENT_DUPLICATED` | A snapshot ID is unassigned / assigned twice. |
| `CHECKLIST_UNAVAILABLE` | The comment is deleted, unreadable, or not the planned ID. |
| `CHECKLIST_INVALID` | The refetched comment is malformed, unmarked, or has duplicate IDs. |
| `CHECKLIST_CHANGED` | Instruction digest or ID set differs from the snapshot. |
| `TASK_MISSING` / `TASK_DUPLICATED` | An assignment has no / more than one direct run-1 worker. |
| `TASK_UNEXPECTED` | A run other than 1. Replacements are rejected until #46. |

Lifecycle, nesting, parent, attempt, and model/effort codes apply exactly as in
`docs/delegation-manifest.md`. `expected` lists the plan's task IDs; `observed`
counts direct children; every child is `selected`.
