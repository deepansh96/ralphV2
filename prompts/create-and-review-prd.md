# Create and Review PRD

Create or refresh the PRD for GitHub issue `{{ISSUE}}` in repo `{{REPO}}`.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Step: {{STEP_ID}}
Skills: {{SKILLS_DIR}}

Default agent: codex

## Goal

Turn the Parent Issue Index plus the Decisions Artifact Issue into a complete PRD, run council reviews according to `reviewRounds`, persist a local recovery copy, and write the final PRD content to the PRD Artifact Issue.

Do not write PRD content to the parent issue body. The parent issue body is only the compact Parent Issue Index and must be refreshed through `artifact_refresh_parent_index`.

## Required Inputs

- Read the Parent Issue Index:
  `gh issue view {{ISSUE}} --repo {{REPO}}`
- Read `{{WORKSPACE}}/state.json`.
- Run Ralph helper commands in bash before artifact work. Do not source these helpers from zsh or another non-bash shell:
  `source ./ralph-v2/scripts/state.sh`
  `source ./ralph-v2/scripts/artifacts.sh`
- Read project `CONTEXT.md`.
- Read project `CLAUDE.md`.
- Read any ADRs under `docs/adr/` if that directory exists.
- Read `{{SKILLS_DIR}}/to-prd/SKILL.md` if it exists. If not, follow the `to-prd` structure embedded below.
- Explore the codebase for relevant modules, current patterns, test style, and risks before drafting.

## Artifact Startup

Start by ensuring artifact state exists:

```bash
state_ensure_artifacts "{{WORKSPACE}}/state.json"
```

Then resolve the Decisions Artifact Issue. Read it as the source of truth for decisions.

1. Read `state_get_artifact "{{WORKSPACE}}/state.json" decisions`.
2. If it points to a valid Decisions Artifact Issue for parent `#{{ISSUE}}`, read that artifact body with `gh issue view <issue> --repo {{REPO}} --json body`.
3. If it is missing or invalid, perform the zero-review / old-workspace recovery path below. Do not guess decisions from a compact parent index.

Resolve the PRD Artifact Issue before the first final update. If `prd.md` does not exist yet, create a minimal placeholder before calling `artifact_ensure`; replace it with the final PRD before `artifact_update_body`. Placeholder artifacts are not source-of-truth for downstream work.

```bash
if [[ ! -f "{{WORKSPACE}}/prd.md" ]]; then
  printf '# PRD Placeholder\n\nFinal PRD pending.\n' > "{{WORKSPACE}}/prd.md"
fi
prd_issue="$(
  artifact_ensure \
    "{{WORKSPACE}}/state.json" \
    "{{REPO}}" \
    "{{ISSUE}}" \
    "prd" \
    "{{STEP_ID}}" \
    "{{WORKSPACE}}/prd.md" \
    "[ralph artifact] #{{ISSUE}} PRD"
)"
artifact_link_to_parent "{{REPO}}" "{{ISSUE}}" "$prd_issue"
```

## Preserve Original Issue

Before any parent index refresh or artifact creation that could compact the parent issue, save the current parent issue body exactly once to:

```text
{{WORKSPACE}}/original-issue.md
```

If `original-issue.md` already exists, leave it unchanged. Re-runs must preserve the first captured original issue body, not overwrite it with a later Parent Issue Index.

## Zero-Review Decisions Migration

This step owns the zero-review mode where `review-decisions` steps were omitted, and also recovers old workspaces that reach PRD creation without `artifacts.decisions`.

If `artifacts.decisions` is missing or invalid:

1. Save `original-issue.md` first, as described above.
2. Create `{{WORKSPACE}}/decisions.md` from `original-issue.md`.
3. Include these stable sections:
   - `## Original Feature Request / Grilled Decisions`
   - `## Synthesized Decisions`
4. In `## Synthesized Decisions`, clearly state: `This Decisions Artifact was synthesized from the original feature request because review-decision rounds were omitted.`
5. Call `artifact_ensure` for type `decisions`, then `artifact_link_to_parent`.
6. Wrap the final decisions content with `artifact_write_body`, update it with `artifact_update_body`, and keep `decisions.md` as the workspace recovery/audit file.
7. Continue by reading the Decisions Artifact Issue you just created.

After this step completes successfully, `artifacts.decisions` must not be null.

## Recovery Rules

Recovery order is strict:

1. A valid PRD Artifact Issue wins over local files. If `artifacts.prd` points to a valid PRD Artifact Issue for parent `#{{ISSUE}}`, read that body before using local `prd.md`.
2. Use local `prd.md` only when no valid PRD Artifact Issue exists. Treat it as a recovery/audit source, not the durable source of truth.
3. If no valid Decisions Artifact Issue exists and `original-issue.md` cannot be recovered from the current parent body, fail with a clear recovery message and mark the step failed.
4. If no valid PRD Artifact Issue exists and local `prd.md` is also missing, create a placeholder only so `artifact_ensure` can allocate the issue number; do not treat the placeholder as final content.

The error message for missing required source must say which source is missing, for example: `Recovery failed: missing Decisions Artifact Issue and original-issue.md for parent #{{ISSUE}}.`

## AFK Planning

Sketch the modules and test plan yourself. Do not ask the user to confirm modules or test coverage during this step. Use the project vocabulary from `CONTEXT.md`, and flag ADR conflicts inside the PRD if any exist.

## PRD Structure

Draft the PRD following the `to-prd` skill template. Persist the final PRD body to:

```text
{{WORKSPACE}}/prd.md
```

The final PRD Artifact Issue content must contain these sections, in this order:

```md
## Decision Summary

## Problem Statement

## Solution

## User Stories

## Implementation Decisions

## Testing Decisions

## Out of Scope

## Further Notes

## PRD Review Round 1

(Omit if reviewRounds is 0.)

## PRD Review Round 2

(Omit if reviewRounds is less than 2.)
```

Requirements:

- `Decision Summary` is a concise, scannable list of concrete decisions from the Decisions Artifact Issue, Parent Issue Index, and discovered context.
- `User Stories` is a numbered list using: `As a <actor>, I want a <feature>, so that <benefit>`.
- `Implementation Decisions` covers modules, interfaces, architecture, schemas, API contracts, and important interactions, but avoids fragile file-path or code-snippet details.
- `Testing Decisions` explains behavior-focused tests, target modules, and relevant prior test style in the codebase.
- `Out of Scope` explicitly separates future work from this PRD.
- Each executed PRD council round gets a stable section named exactly `## PRD Review Round 1` or `## PRD Review Round 2`.
- Each round section must preserve its own `### Council Attribution` subsection with `Reviewed by:` and `Failed:` lines.
- On rerun, replace the existing `## PRD Review Round N` section for that round instead of appending a duplicate. Preserve other round sections unless rerunning that round.

## Council Review

Before starting, read the `reviewRounds` field for this step (`{{STEP_ID}}`) from `{{WORKSPACE}}/state.json`. This controls how many council review rounds to run:

- **2 (default):** Run both Round 1 and Round 2 below.
- **1:** Run only Round 1. Skip Round 2 entirely.
- **0:** Skip council review entirely. Proceed directly to artifact update.

If `reviewRounds` is missing, default to 2.

Round 1 (skip if `reviewRounds` is 0):

```bash
./ralph-v2/scripts/council-review.sh --only {{REVIEWERS}} "IMPORTANT: You are a reviewer. DO NOT modify any files, create branches, run tests, or make any changes to the codebase or config. Only read and analyze. Provide feedback as text output only.

Review the draft PRD for GitHub issue {{ISSUE}} in repo {{REPO}}. Focus on:
1. MISSING REQUIREMENTS - Are any decisions or modules missing?
2. UNCLEAR DECISIONS - Are decisions specific enough to implement without guessing?
3. ARCHITECTURE RISKS - Module boundary cleanliness, coupling between modules, scaling or security concerns.
4. EDGE CASES - Race conditions, error paths, or boundary conditions not addressed.
5. INTERFACE DESIGN - Are public interfaces well-defined? Would you restructure any module boundaries?
6. TESTING GAPS - Is the test plan sufficient? Are edge cases covered?
7. CONFLICTS - Contradictions with CONTEXT.md, CLAUDE.md, or existing ADRs.
For each issue found, state severity (critical/major/minor) and a concrete recommendation."
```

Before calling council, capture the working tree state with `git status --porcelain`. After council returns, run `git status --porcelain` again. If any files changed during the council run, revert only those files: `git checkout -- <file>` for modified tracked files, `rm <file>` for newly created untracked files.

The council output includes an `=== COUNCIL ATTRIBUTION ===` block at the end listing which agents succeeded (`Reviewed by:`) and which failed (`Failed:`). Track attribution from each round and include it inside that round's stable section.

Before incorporating feedback, verify each council point against the codebase. For each point: read the relevant files, modules, or docs the council references. State whether the point is valid, partially valid, or invalid, citing what you found. If valid, determine the concrete PRD change needed. If invalid, drop it with evidence. Do not accept or reject council feedback based on reasoning alone.

Incorporate verified Round 1 feedback into the PRD. Keep major feedback that changes scope, architecture, correctness, sequencing, or testing. Drop nitpicks, style-only comments, and points invalidated by codebase verification. Write or replace only the `## PRD Review Round 1` section for the round output and attribution.

Round 2 (skip if `reviewRounds` is less than 2):

```bash
./ralph-v2/scripts/council-review.sh --only {{REVIEWERS}} "IMPORTANT: You are a reviewer. DO NOT modify any files, create branches, run tests, or make any changes to the codebase or config. Only read and analyze. Provide feedback as text output only.

Review the revised PRD for GitHub issue {{ISSUE}} in repo {{REPO}}. Focus on remaining blockers, unresolved ambiguities, acceptance-risk gaps, interface design quality, and contradictions introduced while incorporating Round 1 feedback. Would you restructure anything that remains?"
```

Use the same working-tree protection and verification process. Incorporate verified Round 2 feedback into the final PRD and write or replace only the `## PRD Review Round 2` section. In every round, incorporate only feedback that remains valid after codebase verification. Do not run additional review rounds.

## Compacting

Compact the PRD Artifact Issue body before update if it approaches GitHub's issue body limit. Preserve all PRD sections, implementation-critical decisions, acceptance criteria, and all `### Council Attribution` subsections. Prefer concise bullets over removing important requirements.

## Artifact Update

Write the reviewed PRD body to `{{WORKSPACE}}/prd.md`, then create a provenance-wrapped body and update the PRD Artifact Issue:

```bash
artifact_write_body "{{ISSUE}}" "prd" "{{STEP_ID}}" "{{WORKSPACE}}/prd.md" "{{WORKSPACE}}/prd-artifact-body.md"
artifact_update_body "{{WORKSPACE}}/state.json" "{{REPO}}" "{{ISSUE}}" "prd" "$prd_issue" "{{WORKSPACE}}/prd-artifact-body.md"
artifact_refresh_parent_index "{{WORKSPACE}}/state.json" "{{REPO}}" "{{ISSUE}}"
```

`artifact_update_body` must be the GitHub write path for final PRD content. Do not edit the parent issue with a final PRD body file for PRD content.

## Idempotency

This step is idempotent:

- If a valid PRD Artifact Issue already exists, reuse it and replace its PRD content with the refreshed final PRD.
- If `{{WORKSPACE}}/original-issue.md` already exists, do not overwrite it.
- Re-running the step updates the PRD Artifact Issue rather than duplicating PRD sections.
- The final PRD Artifact Issue should contain one `## Decision Summary`, one `## Problem Statement`, and one complete PRD.
- PRD review council rounds are stable sections in the PRD Artifact Issue, replaced on rerun rather than duplicated, with council attribution per round preserved.

Complete normally after the PRD Artifact Issue update and Parent Issue Index refresh succeed so Ralph can mark the step completed.
