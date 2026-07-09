---
name: to-tickets
description: Break a plan, spec, or PRD into tracer-bullet GitHub issues, each declaring its blocking edges as native GitHub issue dependencies. Use when user wants to convert a plan into issues, create implementation tickets, or break down work into issues.
---

# To Tickets

Break a plan, spec, or conversation into a set of **tickets** — tracer-bullet vertical slices, each declaring the tickets that **block** it. Published as GitHub issues in dependency order, with blocking edges wired as native GitHub issue dependencies.

## Process

### 1. Gather context

Work from whatever is already in the conversation context. If the user passes a GitHub issue number or URL as an argument, fetch it with `gh issue view <number>` (with comments).

### 2. Explore the codebase (optional)

If you have not already explored the codebase, do so to understand the current state of the code. Before exploring, follow [../domain-modeling/DOMAIN-AWARENESS.md](../domain-modeling/DOMAIN-AWARENESS.md). Issue titles and descriptions should use the project's `CONTEXT.md` vocabulary, and respect ADRs in the area you're touching.

Look for opportunities to prefactor the code to make the implementation easier. "Make the change easy, then make the easy change." Any prefactoring becomes its own ticket, done first.

### 3. Draft vertical slices

Break the work into **tracer bullet** tickets.

<vertical-slice-rules>

- Each slice cuts a narrow but COMPLETE path through every layer (schema, API, UI, tests) — vertical, NOT a horizontal slice of one layer
- A completed slice is demoable or verifiable on its own
- Each slice is sized to fit in a single fresh context window
- Any prefactoring should be done first

</vertical-slice-rules>

Give each ticket its **blocking edges** — the other tickets that must complete before it can start. A ticket with no blockers can start immediately.

**Wide refactors are the exception to vertical slicing.** A **wide refactor** is one mechanical change — rename a column, retype a shared symbol — whose **blast radius** fans across the whole codebase, so a single edit breaks thousands of call sites at once and no vertical slice can land green. Don't force it into a tracer bullet; sequence it as **expand–contract**. First expand: add the new form beside the old so nothing breaks. Then migrate the call sites over in batches sized by blast radius (per package, per directory), each batch its own ticket blocked by the expand, keeping CI green batch to batch because the old form still exists. Finally contract: delete the old form once no caller remains, in a ticket blocked by every migrate batch.

### 4. Quiz the user

Present the proposed breakdown as a numbered list. For each ticket, show:

- **Title**: short descriptive name
- **Blocked by**: which other tickets (if any) must complete first
- **What it delivers**: the end-to-end behaviour this ticket makes work

Ask the user:

- Does the granularity feel right? (too coarse / too fine)
- Are the blocking edges correct — does each ticket only depend on tickets that genuinely gate it?
- Should any tickets be merged or split further?

Iterate until the user approves the breakdown.

Running AFK (inside the Ralph pipeline), skip the quiz — council review takes its place.

### 5. Create the GitHub issues

For each approved ticket, create a GitHub issue using `gh issue create`. Use the issue body template below.

Create issues in dependency order (blockers first) so blocking edges can reference real issue numbers.

**If a parent issue exists**, add each created issue as a sub-issue of the parent using the GraphQL API:

```bash
gh api graphql -f query='
  mutation {
    addSubIssue(input: {issueId: "<parent-node-id>", subIssueId: "<child-node-id>"}) {
      issue { id }
    }
  }'
```

To get the node ID of an issue, use:

```bash
gh issue view <number> --json id -q .id
```

**Wire each blocking edge as a native GitHub issue dependency** — it renders visually in GitHub's UI, so anyone can see which tickets are takeable without reading bodies:

```bash
gh api --method POST repos/<owner>/<repo>/issues/<blocked-number>/dependencies/blocked_by -F issue_id=<blocker-database-id>
```

The `issue_id` is the blocker's numeric **database id** (`gh api repos/<owner>/<repo>/issues/<blocker-number> --jq .id`), NOT the `#number` or the GraphQL `node_id`. Keep the `Blocked by #<number>` line in the issue body as well — it is the human-readable fallback and what agents check first.

<issue-template>
## What to build

The end-to-end behaviour this ticket makes work, from the user's perspective — not layer-by-layer implementation.

## Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

## Blocked by

- Blocked by #<issue-number> (if any)

Or "None - can start immediately" if no blockers.

</issue-template>

Avoid specific file paths or code snippets in ticket bodies — they go stale fast. Exception: if a prototype produced a snippet that encodes a decision more precisely than prose can (state machine, reducer, schema, type shape), inline it and note briefly that it came from a prototype. Trim to the decision-rich parts.

Do NOT close or modify any parent issue.

Work the **frontier** — any ticket whose blockers are all closed — one ticket at a time, clearing context between tickets.
