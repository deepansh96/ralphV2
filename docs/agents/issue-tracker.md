# Issue tracker: GitHub

Issues, PRDs, and wayfinder maps for this repo live as GitHub issues. Use the `gh` CLI for all operations.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body "..."`. Use a heredoc or `--body-file` for multi-line bodies.
- **Read an issue**: `gh issue view <number> --comments` for human-readable output. To filter comments with `jq` or inspect labels, request JSON instead: `gh issue view <number> --json body,comments,labels` (plain `--comments` emits formatted text that `jq` cannot parse and omits labels).
- **List issues**: `gh issue list --state open --json number,title,body,labels,assignees` with appropriate `--label` and `--state` filters.
- **Comment on an issue**: `gh issue comment <number> --body "..."`
- **Apply / remove labels**: `gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **Close**: `gh issue close <number> --comment "..."`

Infer the repo from `git remote -v` — `gh` does this automatically when run inside a clone.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --comments`.

## Sub-issues

Link a child issue under a parent with the GraphQL `addSubIssue` mutation:

```bash
gh api graphql -f query='
  mutation {
    addSubIssue(input: {issueId: "<parent-node-id>", subIssueId: "<child-node-id>"}) {
      issue { id }
    }
  }'
```

Node IDs come from `gh issue view <number> --json id -q .id`.

## Blocking edges

Use GitHub's **native issue dependencies** — the canonical, UI-visible representation:

```bash
gh api --method POST repos/<owner>/<repo>/issues/<blocked-number>/dependencies/blocked_by -F issue_id=<blocker-db-id>
```

`<blocker-db-id>` is the blocker's numeric **database id** (`gh api repos/<owner>/<repo>/issues/<n> --jq .id`), *not* the `#number` or the GraphQL `node_id`. GitHub reports `issue_dependencies_summary.blocked_by` (open blockers only — the live gate):

```bash
gh api repos/<owner>/<repo>/issues/<n> --jq '.issue_dependencies_summary.blocked_by'
```

Where dependencies aren't available, fall back to a `Blocked by: #<n>, #<n>` line at the top of the issue body. A ticket is unblocked when every blocker is closed.

## Wayfinding operations

Used by the `wayfinder` skill. The **map** is a single issue with **child** issues as tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Destination / Notes / Decisions-so-far / Not-yet-specified / Out-of-scope body. `gh issue create --label wayfinder:map`.
- **Decision ticket**: an issue linked to the map as a GitHub sub-issue (see above). Where sub-issues aren't enabled, add it to a task list in the map body and put `Part of #<map>` at the top of its body. Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Once claimed, the ticket is assigned to the driving dev.
- **Blocking**: native issue dependencies (see above), with the body-line fallback.
- **Frontier query**: list the map's open children (`gh issue list --state open`, scoped to the map's sub-issues / task list), drop any with an open blocker (`issue_dependencies_summary.blocked_by > 0`, or an open issue in the `Blocked by` line) or an assignee; first in map order wins.
- **Claim**: `gh issue edit <n> --add-assignee @me` — the session's first write.
- **Research fan-out**: claim each unblocked research ticket before spawning one read-only research subagent per ticket. Subagents return findings only; the parent session serializes file, branch, comment, close, and map writes.
- **Resolve**: `gh issue comment <n> --body "<answer>"`, then `gh issue close <n>`, then append a context pointer to the map's Decisions-so-far. Point prototype and research tickets to their `prototype/<name>` or `research/<name>` branch; otherwise link the relevant gist or asset.
- **Labels**: create once per repo if missing: `wayfinder:map`, `wayfinder:research`, `wayfinder:prototype`, `wayfinder:grilling`, `wayfinder:task` (`gh label create <name>`).
