# Create and Review Slices

Create or refresh implementation sub-issues for GitHub issue `{{ISSUE}}` in repo `{{REPO}}`.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Step: {{STEP_ID}}
Skills: {{SKILLS_DIR}}

Default agent: codex

## Goal

Read the PRD Artifact Issue as source-of-truth, draft vertical implementation slices, run council reviews according to `reviewRounds`, persist a local recovery copy, write the reviewed Slice Plan to the Slice Plan Artifact Issue, and create AFK-ready implementation sub-issues linked under the parent issue.

Do not write Slice Plan content to the parent issue body. The parent issue body is only the compact Parent Issue Index and must be refreshed through `artifact_refresh_parent_index`.

## Required Inputs

- Read the Parent Issue Index:
  `gh issue view {{ISSUE}} --repo {{REPO}}`
- Read `{{WORKSPACE}}/state.json`.
- Source Ralph helpers before artifact work:
  `source ./ralph-v2/scripts/state.sh`
  `source ./ralph-v2/scripts/artifacts.sh`
- Read project `CONTEXT.md`.
- Read project `CLAUDE.md`.
- Read any ADRs under `docs/adr/` if that directory exists.
- Read `{{SKILLS_DIR}}/to-issues/SKILL.md` if it exists. If not, still follow the slice rules below.
- Check existing sub-issues before creating anything so re-runs do not create duplicates.

## Artifact Startup

Start by ensuring artifact state exists:

```bash
state_ensure_artifacts "{{WORKSPACE}}/state.json"
```

Resolve the PRD Artifact Issue before drafting slices. `artifacts.prd` is the normal pointer:

1. Read `state_get_artifact "{{WORKSPACE}}/state.json" prd`.
2. If it points to a valid PRD Artifact Issue for parent `#{{ISSUE}}`, read that artifact body with `gh issue view <issue> --repo {{REPO}} --json body`.
3. If `artifacts.prd` is null, stale, deleted, or invalid on an artifact-aware rerun, recover or ensure the PRD Artifact Issue from local `prd.md` first.
4. If local `prd.md` is missing too, recover only from a valid upstream PRD source explicitly produced by the PRD step. If no required source exists, fail with a recovery message and mark the step failed.

The recovery message must name the missing source, for example: `Recovery failed: missing PRD Artifact Issue and local prd.md for parent #{{ISSUE}}.`

Ensure the Slice Plan Artifact Issue before implementation slice bodies are created, so every slice body can link to both artifacts. If `slices.md` does not exist yet, create a placeholder before calling `artifact_ensure`; replace it with final reviewed content before any downstream step treats it as source-of-truth.

```bash
if [[ ! -f "{{WORKSPACE}}/slices.md" ]]; then
  printf '# Slice Plan Placeholder\n\nFinal slice plan pending.\n' > "{{WORKSPACE}}/slices.md"
fi
slice_plan_issue="$(
  artifact_ensure \
    "{{WORKSPACE}}/state.json" \
    "{{REPO}}" \
    "{{ISSUE}}" \
    "slice-plan" \
    "{{STEP_ID}}" \
    "{{WORKSPACE}}/slices.md" \
    "[ralph artifact] #{{ISSUE}} Slice Plan"
)"
artifact_link_to_parent "{{REPO}}" "{{ISSUE}}" "$slice_plan_issue"
```

Placeholder Slice Plan artifacts are temporary allocation records only. On rerun, detect placeholder content such as `# Slice Plan Placeholder` or missing final sections, then update it to final content with `artifact_update_body` before creating or refreshing downstream links.

## Recovery Rules

Recovery order is strict:

1. A valid PRD Artifact Issue wins over local files. Read it before using local `prd.md`.
2. Use local `prd.md` only when no valid PRD Artifact Issue exists. Treat it as a recovery/audit source, not the durable source of truth.
3. If a PRD artifact must be recreated from `prd.md`, call `artifact_ensure`, then `artifact_write_body`, `artifact_update_body`, and `artifact_link_to_parent` before reading it.
4. A valid Slice Plan Artifact Issue wins over local `slices.md` only if it is not a placeholder and contains final slice-plan sections.
5. `slices.md` remains the workspace recovery/audit file and must be written with the final reviewed slice plan plus issue mapping.
6. If slice issue creation fails partway through, rerun must separately verify existing slices, create only missing slices, avoid duplicate links, and complete the Slice Plan artifact update with the complete mapping.
7. Missing required source content fails clearly instead of guessing from the compact Parent Issue Index. The diagnostic should include the phrase `missing required source content`.

## Slice Rules

Draft vertical slices following the `to-issues` skill rules:

- Use tracer bullets: each slice should deliver one end-to-end behavior that can be implemented and verified independently.
- Do not create horizontal slices by technical layer, file type, component category, or infrastructure-only work.
- Each slice must include a clear user-facing or operator-visible behavior, acceptance criteria, and focused test guidance.
- Keep slices small enough for one AFK implementation step, but complete enough that the resulting code is useful.
- Mark every generated sub-issue as AFK with exact full-line `AFK: true`.
- Include exact full-line `Parent: #{{ISSUE}}`.
- Include compact artifact context links near the top: `PRD: #<issue>` and `Slice Plan: #<issue>`.
- Implementation slice bodies must never include `Ralph-Artifact:`.
- Keep future work or blocked-by references out of the generated sub-issues unless the PRD explicitly requires them for this issue.
- When referencing dependencies between slices, always use the GitHub issue number, for example `Blocked by #25`, never the slice ordinal. The implement-slice step checks blockers by running `gh issue view <number>`.

Each implementation slice issue body must remain self-contained:

```md
AFK: true
Parent: #{{ISSUE}}
PRD: #<prd-issue>
Slice Plan: #<slice-plan-issue>

## What to build

## Acceptance criteria

## Testing guidance

## Out of scope
```

## Slice Plan Structure

Write the final reviewed Slice Plan to `{{WORKSPACE}}/slices.md`. The Slice Plan Artifact Issue content must contain these sections:

```md
## Reviewed Slice Plan

## Slice Plan Review Round 1

(Omit if reviewRounds is 0.)

## Slice Plan Review Round 2

(Omit if reviewRounds is less than 2.)

## Created/Reused Slice Issue Mapping
```

Requirements:

- `## Reviewed Slice Plan` contains the final slice list, dependencies, AFK status, acceptance criteria summary, and testing guidance.
- Each executed review round gets a stable section named exactly `## Slice Plan Review Round 1` or `## Slice Plan Review Round 2`.
- Each round section must preserve its own `### Council Attribution` subsection with `Reviewed by:` and `Failed:` lines.
- On rerun, replace the existing `## Slice Plan Review Round N` section for that round instead of appending a duplicate. Preserve other round sections unless rerunning that round.
- `## Created/Reused Slice Issue Mapping` contains the created/reused slice issue mapping and whether each issue was newly created, reused, newly linked, or skipped with a reason.

## Council Review

Before starting, read the `reviewRounds` field for this step (`{{STEP_ID}}`) from `{{WORKSPACE}}/state.json`. This controls how many council review rounds to run:

- **2 (default):** Run both Round 1 and Round 2 below.
- **1:** Run only Round 1. Skip Round 2 entirely.
- **0:** Skip council review entirely. Proceed directly to artifact update and sub-issue creation.

If `reviewRounds` is missing, default to 2.

Round 1 (skip if `reviewRounds` is 0):

```bash
./ralph-v2/scripts/council-review.sh --only {{REVIEWERS}} "IMPORTANT: You are a reviewer. DO NOT modify any files, create branches, run tests, or make any changes to the codebase or config. Only read and analyze. Provide feedback as text output only.

Review the draft vertical slices for GitHub issue {{ISSUE}} in repo {{REPO}}. Focus on:
1. HORIZONTAL SLICING - Are any slices horizontal (single layer) rather than vertical (end-to-end demoable)?
2. MISSING WORK - Is there work that no slice covers?
3. DEPENDENCY PROBLEMS - Wrong dependency relationships or implicit ordering constraints.
4. AGENT COMPLETABILITY - Could anything block an agent from completing a slice independently in AFK mode?
5. MERGE CONFLICT RISK - Do multiple slices touch the same files? Are write boundaries between parallel slices clear?
6. TEST GAPS - Missing acceptance criteria or test guidance.
7. CONFLICTS - Contradictions with CONTEXT.md, CLAUDE.md, or existing ADRs.
For each issue found, state severity (critical/major/minor) and a concrete recommendation."
```

Before calling council, capture the working tree state with `git status --porcelain`. After council returns, run `git status --porcelain` again. If any files changed during the council run, revert only those files: `git checkout -- <file>` for modified tracked files, `rm <file>` for newly created untracked files.

The council output includes an `=== COUNCIL ATTRIBUTION ===` block at the end listing which agents succeeded (`Reviewed by:`) and which failed (`Failed:`). Track attribution from each round and include it inside that round's stable section.

Before incorporating feedback, verify each council point against the codebase. For each point: read the relevant files, modules, or docs the council references. State whether the point is valid, partially valid, or invalid, citing what you found. If valid, determine the concrete slice change needed. If invalid, drop it with evidence. Do not accept or reject council feedback based on reasoning alone.

Incorporate verified Round 1 feedback into the slice list. Keep major feedback that changes slice boundaries, sequencing, correctness, or testing. Drop nitpicks, style-only comments, and points invalidated by codebase verification. Write or replace only the `## Slice Plan Review Round 1` section for the round output and attribution.

Round 2 (skip if `reviewRounds` is less than 2):

```bash
./ralph-v2/scripts/council-review.sh --only {{REVIEWERS}} "IMPORTANT: You are a reviewer. DO NOT modify any files, create branches, run tests, or make any changes to the codebase or config. Only read and analyze. Provide feedback as text output only.

Review the revised vertical slices for GitHub issue {{ISSUE}} in repo {{REPO}}. Focus on remaining blockers, duplicate or overlapping slices, missing AFK criteria, unresolved dependencies, merge conflict risk between parallel slices, and contradictions introduced while incorporating Round 1 feedback."
```

Use the same working-tree protection and verification process. Incorporate verified Round 2 feedback into the final slice list and write or replace only the `## Slice Plan Review Round 2` section. Do not run additional review rounds.

## GitHub Sub-Issue Creation

Create or reuse one GitHub issue per final implementation slice using:

```bash
gh issue create --repo {{REPO}} --title "<slice title>" --body-file <slice-body-file>
```

Before creating a slice, inspect existing sub-issues linked to parent `#{{ISSUE}}` and repo issues that reference `Parent: #{{ISSUE}}`. Reuse only issues that are implementation slices: exact `AFK: true`, exact `Parent: #{{ISSUE}}`, and no `Ralph-Artifact:` marker. Artifact Issues and malformed mixed-marker issues are not implementation slices.

After each issue is created or reused, link it to the parent with GitHub GraphQL `addSubIssue`.

Required GraphQL flow:

1. Resolve the parent issue node ID with `gh api graphql`.
2. Resolve or capture each created or reused sub-issue node ID.
3. Call the `addSubIssue` mutation for each missing parent/sub-issue relationship.

The mutation must use the parent issue ID and sub-issue ID; do not rely only on markdown references.

## Partial Creation Recovery

This step is idempotent and must recover from partway failures:

- Before creating sub-issues, build an intended-slice key from each final slice title or stable slug.
- For each intended slice, verify whether an existing eligible AFK implementation issue already satisfies that slice.
- Create only missing slices.
- Do not create a duplicate if an intended slice already exists but was not linked; only run `addSubIssue`.
- Avoid duplicate links by checking existing parent/sub-issue relationships where GitHub exposes them; otherwise treat `addSubIssue` failure for an already-linked issue as non-fatal only when the issue body markers are valid.
- Update `{{WORKSPACE}}/slices.md` and the Slice Plan Artifact Issue mapping after all slices exist, so the final mapping contains the complete final set.

## Artifact Update

After the final slice plan and all slice issues are reconciled, write the final Slice Plan body to `{{WORKSPACE}}/slices.md`, then create a provenance-wrapped body and update the Slice Plan Artifact Issue:

```bash
artifact_write_body "{{ISSUE}}" "slice-plan" "{{STEP_ID}}" "{{WORKSPACE}}/slices.md" "{{WORKSPACE}}/slice-plan-artifact-body.md"
artifact_update_body "{{WORKSPACE}}/state.json" "{{REPO}}" "{{ISSUE}}" "slice-plan" "$slice_plan_issue" "{{WORKSPACE}}/slice-plan-artifact-body.md"
artifact_refresh_parent_index "{{WORKSPACE}}/state.json" "{{REPO}}" "{{ISSUE}}"
```

`artifact_update_body` must be the GitHub write path for final Slice Plan content. Do not edit the parent issue with a final slice plan body file.

## Idempotency

This step is idempotent:

- Re-running reads the PRD Artifact Issue as source-of-truth.
- Re-running updates the same Slice Plan Artifact Issue rather than creating duplicates.
- Placeholder Slice Plan artifacts are replaced with final content before downstream use.
- Slice Plan council review rounds are stable sections in the Slice Plan Artifact Issue, replaced on rerun rather than duplicated, with council attribution per round preserved.
- Final Slice Plan artifact body contains the reviewed slice plan, council attribution, and created/reused slice issue mapping.
- Re-running after a partway slice creation failure reuses existing slices, creates only missing slices, avoids duplicate links, and updates the Slice Plan artifact mapping to the complete final set.
- `slices.md` remains a workspace recovery/audit file.

Complete normally only after the Slice Plan Artifact Issue is updated, all final AFK implementation sub-issues exist and are linked under the parent issue, and the Parent Issue Index refresh succeeds.
