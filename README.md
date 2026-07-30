# Ralph v2

Ralph v2 is a GitHub issue-driven pipeline for planning, implementing, checking,
opening a PR, running local QA, and reviewing one feature. It stores progress
in a per-issue `state.json` file and runs each step with the agent assigned in
that state.

## CLI

Run commands from the repository root:

```bash
./ralph-v2/ralph.sh --issue N
./ralph-v2/ralph.sh status --issue N
./ralph-v2/ralph.sh logs --issue N
./ralph-v2/ralph.sh logs --issue N --step <step-id>
./ralph-v2/cleanup.sh <issue-number>
```

- `ralph.sh --issue N` validates state and context, then runs pending steps until the pipeline finishes or blocks. After failure it skips normal work, runs pending always-run cleanup, and exits non-zero.
- `ralph.sh status --issue N` prints a step table with step ID, type, agent, status, duration, and cost.
- `ralph.sh logs --issue N` tails the active step log. Use `--step <step-id>` to read a specific step.
- `cleanup.sh <issue-number>` archives `workspaces/<issue-number>/` into `archive/<date>-<issue-number>/`.

## Monitoring

To monitor a running pipeline, poll with sleep intervals rather than continuously:

```bash
sleep 120 && ./ralph-v2/ralph.sh status --issue N 2>&1
```

## Tests

Run the full deterministic shell suite from the repository root:

```bash
./tests/run.sh
```

Run specific suites by name:

```bash
./tests/run.sh agent pipeline prompt_contracts
```

`tests/test_ralph_v2.sh` is a compatibility wrapper around `tests/run.sh`. The suite is split by behavior under `tests/suites/`, with shared fixtures and fake external tools in `tests/lib/`. See `tests/README.md` for the suite map.

## Workflow

1. Grill the feature into a GitHub issue using the project context and decision workflow (`skills/grill-with-docs/`). For an effort too big or foggy for one grilling session, chart a wayfinder map first (`skills/wayfinder/`): a map issue with child tickets resolved one per session, whose destination is the decision issue that enters the pipeline. If grilling produces speculative `CONTEXT.md` or ADR changes, keep them on a pushed `grill/*` planning branch instead of committing them directly to `main`.
2. Run the `init.md` prompt for that issue so an agent creates `ralph-v2/workspaces/<issue>/state.json`. By default, init skips review-decisions steps and PRD/slice council review rounds. Opt in with "with 1 review-decision round" or "with 1 review round on PRD".
3. Set `.baseBranch` explicitly in `state.json` before preflight reaches branch creation. Use the branch that already contains the grilling context: usually `main` for accepted docs, or the pushed `grill/*` planning branch for speculative feature docs.
4. Run `./ralph-v2/ralph.sh --issue N`.
5. If a step blocks, answer the questions in `workspaces/<issue>/hitl-<step-id>.md`, then run the same command again.
6. After the PR workflow completes, run `./ralph-v2/cleanup.sh <issue-number>`.

The fixed flow is:

```text
grill -> init -> run -> cleanup
```

When grilling docs are not ready for `main`, use a stacked branch flow:

```text
main
  -> grill/issue-123-short-slug      # CONTEXT.md / ADR / issue shaping commits
      -> feat/issue-123-short-slug   # Ralph implementation branch
```

In that flow, set `.baseBranch` to `grill/issue-123-short-slug`. At PR time,
the `pr-creation` step merges the planning branch into the feature branch (so
the PR carries the planning docs) and opens the implementation PR against the
repository default branch, not the planning branch. One merge lands docs and
implementation together; delete the planning branch afterwards.

During `run`, Ralph executes:

```text
review-decisions (0-2 rounds, default 0)
-> create-and-review-prd
-> create-and-review-slices
-> preflight
-> implement-slice...
-> final-checks
-> pr-creation
-> prepare-qa-checklist
-> runthrough-qa-checklist
-> multi-axis-pr-review
-> cleanup-local-resources
```

## State

Each issue has one workspace. Init creates both `state.json` and the empty
`local-resources.json` ledger, including the fixed always-run cleanup step:

```text
ralph-v2/workspaces/<issue-number>/
```

The workspace contains `state.json`, logs, human-input flag files, and review artifacts.

Top-level `state.json` fields:

```json
{
  "issue": 2,
  "repo": "owner/repo",
  "baseBranch": "main",
  "branch": "feat/issue-2-short-slug",
  "status": "initialized",
  "createdAt": "2026-05-02T00:00:00Z",
  "steps": []
}
```

Each step has this shape:

```json
{
  "id": "implement-slice-14",
  "phase": "fixed",
  "type": "implement-slice",
  "status": "pending",
  "agent": "codex",
  "model": "<provider-model>",
  "reasoningEffort": "high",
  "reviewers": [],
  "hitl": false,
  "sub_issue": 14,
  "metrics": null,
  "notes": ""
}
```

Generated steps use `"agent": "codex"` by default. Before a step runs, you can
edit its optional `model` and `reasoningEffort` fields in `state.json`:

- Codex: `low`, `medium`, `high`, `xhigh`, `max`, or `ultra`
- Claude: `low`, `medium`, `high`, `xhigh`, or `max`

Effort availability still depends on the selected model and account. Omit
either field to use that CLI's configured default.

Step statuses are:

```text
pending -> in_progress -> completed
                       -> blocked
                       -> failed
```

After a failed step, Ralph skips remaining normal steps, runs pending steps
marked `"alwaysRun": true`, then exits non-zero. The failed step must still be
reset to `pending` or marked `completed` before normal work can resume. When
normal work is retried, completed always-run cleanup is automatically rearmed.

## Step Types

- `review-decisions`: reviews issue decisions against `CONTEXT.md`, `CLAUDE.md`, and ADRs; may block for human input.
- `create-and-review-prd`: preserves the original issue body, drafts the PRD following the `to-spec` skill (including the testing seams), runs council reviews (controlled by `reviewRounds`, default 0), and updates the parent issue.
- `create-and-review-slices`: drafts vertical AFK slices following the `to-tickets` skill with explicit blocking edges (native GitHub issue dependencies plus `Blocked by` body lines), runs council reviews (controlled by `reviewRounds`, default 0), creates GitHub sub-issues, and links them under the parent.
- `preflight`: backfills missing cleanup artifacts for older initialized workspaces, checks the working tree and `baseBranch` contract, creates/pushes the feature branch, and appends the dynamic implementation and post-implementation steps.
- `implement-slice`: reads the assigned sub-issue, verifies blockers are closed, follows TDD at the PRD's pre-agreed seams, commits, pushes, and closes the sub-issue.
- `final-checks`: reads the complete branch diff, runs project checks, verifies every slice's acceptance criteria, and writes `final-checks.md` without changing product code.
- `pr-creation`: pushes the feature branch and idempotently creates or updates a PR with a summary and issue-closing links.
- `prepare-qa-checklist`: posts or updates one PR comment containing local-only manual QA items.
- `runthrough-qa-checklist`: executes that checklist with local services, stubs, local databases, and browser tooling; updates the same PR comment with results.
- `multi-axis-pr-review`: runs four skill-driven reviews in two bounded waves, verifies and votes on their findings, and posts one consolidated PR comment.
- `cleanup-local-resources`: always runs after success or failure and removes pipeline-owned processes, containers, sessions, temporary files, and worktree leftovers.

## Bundled Skills

`ralph-v2/skills/` contains the skills used by the prompts:

- `to-spec/` — turn grilled decisions into a spec/PRD (with testing seams)
- `to-tickets/` — break a spec into tracer-bullet slices with blocking edges
- `tdd/` — the red → green loop, seams, and test anti-patterns
- `matt-pocock-code-review/` — two-axis Standards and Spec review
- `ponytail-review/` — over-engineering and deletion-focused review
- `run-codex-review/` — isolated Codex App Server review
- `supe-review-code-changes/` — correctness, security, compatibility, and test review
- `domain-modeling/` — glossary and ADR discipline, plus domain awareness for consumers
- `grilling/` — the core interview loop (facts from the code, decisions from the human)
- `grill-with-docs/` — grilling plus inline `CONTEXT.md`/ADR updates; the default entry point
- `wayfinder/` — map an effort too big for one session as tracker tickets; hands its destination issue to `init`
- `research/` — investigate a question against primary sources, leave a cited note

Tracker operations (sub-issues, native blocking edges, wayfinding operations) live in `docs/agents/issue-tracker.md`, referenced from the `Issue tracker` section of `AGENTS.md`.

The bundle is self-contained. Skill references point at files inside `ralph-v2/skills/`, not at the user's global skill directory.
