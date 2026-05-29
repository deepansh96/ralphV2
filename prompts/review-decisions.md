# Review Decisions

Review the decisions in GitHub issue `{{ISSUE}}` for repo `{{REPO}}`.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Step: {{STEP_ID}}
Skills: {{SKILLS_DIR}}

Default agent: codex

## Required Inputs

- Read the issue with `gh issue view {{ISSUE}} --repo {{REPO}}`.
- Read project `CONTEXT.md`.
- Read project `CLAUDE.md`.
- Read any ADRs under `docs/adr/` if that directory exists.
- Source the artifact helper from the project root:
  ```bash
  source ./ralph-v2/scripts/artifacts.sh
  ```
- Use `{{WORKSPACE}}/state.json` as the State file for artifact registry reads/writes.

## Artifact Storage Contract

Decision review output is stored in the Decisions Artifact Issue, not in the parent issue body.

Before any call that can refresh the Parent Issue Index, preserve the current parent body once:

```bash
if [[ ! -f "{{WORKSPACE}}/original-issue.md" ]]; then
  gh issue view {{ISSUE}} --repo {{REPO}} --json body -q .body > "{{WORKSPACE}}/original-issue.md"
fi
```

Maintain `{{WORKSPACE}}/decisions.md` as a workspace recovery/audit file. Its content is the source file used to update the Decisions Artifact. The artifact content must contain these stable sections:

```md
# Decisions Artifact

## Original Feature Request / Grilled Decisions

<contents of original-issue.md>

## {{STEP_ID}}

<this round's verified findings, recommendations, dropped feedback, and Council Attribution>

## HITL Answers

<human answers, only when this step resumes from HITL>
```

On rerun, replace the existing `## {{STEP_ID}}` section in `decisions.md` instead of appending a duplicate. Preserve other round sections such as `## review-decisions-1` and `## review-decisions-2`. Preserve each round's `## Council Attribution` inside that round section; never compact council attribution away.

Use the artifact helper to create/reuse, link, update, and refresh:

```bash
artifact_issue="$(
  artifact_ensure \
    "{{WORKSPACE}}/state.json" \
    "{{REPO}}" \
    "{{ISSUE}}" \
    "decisions" \
    "{{STEP_ID}}" \
    "{{WORKSPACE}}/decisions.md" \
    "[ralph artifact] #{{ISSUE}} Decisions"
)"
artifact_link_to_parent "{{REPO}}" "{{ISSUE}}" "$artifact_issue"
artifact_write_body "{{ISSUE}}" "decisions" "{{STEP_ID}}" "{{WORKSPACE}}/decisions.md" "{{WORKSPACE}}/decisions-artifact-body.md"
artifact_update_body "{{WORKSPACE}}/state.json" "{{REPO}}" "{{ISSUE}}" "decisions" "$artifact_issue" "{{WORKSPACE}}/decisions-artifact-body.md"
artifact_refresh_parent_index "{{WORKSPACE}}/state.json" "{{REPO}}" "{{ISSUE}}"
```

`artifact_ensure` must be called before `artifact_link_to_parent`. On rerun it must reuse the existing Decisions Artifact Issue from State or marker recovery; do not create a second Decisions Artifact Issue.

Do not append decision findings to the parent issue body. The parent issue body must be refreshed only as the compact Parent Issue Index via `artifact_refresh_parent_index`.

## HITL Resume

If this prompt includes a `## HITL Resume` section, use the human answers in that section and complete WITHOUT re-running council review.

On HITL resume:

1. Read `{{WORKSPACE}}/{{STEP_ID}}.md`.
2. Read `{{WORKSPACE}}/decisions.md` if it exists; otherwise reconstruct it from `{{WORKSPACE}}/original-issue.md` and `{{WORKSPACE}}/{{STEP_ID}}.md`.
3. Add or replace a stable `## HITL Answers` section in `{{WORKSPACE}}/decisions.md` using the human answers from the `## HITL Resume` section.
4. Call `artifact_ensure`, `artifact_link_to_parent`, `artifact_write_body`, `artifact_update_body`, and `artifact_refresh_parent_index` as described in "Artifact Storage Contract".
5. Do not call `scripts/council-review.sh`.
6. Do not repeat any council or review phase.
7. Do not delete the HITL flag file — it serves as an audit trail.
8. Finish normally so Ralph can mark the step completed.

## Council Review

Call the standalone wrapper:

```bash
./ralph-v2/scripts/council-review.sh --only {{REVIEWERS}} "IMPORTANT: You are a reviewer. DO NOT modify any files, create branches, run tests, or make any changes to the codebase or config. Only read and analyze. Provide feedback as text output only.

Review the decisions in GitHub issue {{ISSUE}} (repo {{REPO}}). Evaluate each decision against:
1. DESIGN GAPS — Are any decisions missing that a developer would need before implementation? Are scope boundaries explicit?
2. ARCHITECTURE RISKS — Could any decision lead to performance, scaling, security, or maintainability problems?
3. CODEBASE CONFLICTS — Do any decisions contradict patterns in CONTEXT.md, CLAUDE.md, or existing ADRs?
4. IMPLEMENTATION CLARITY — Is each decision specific enough to implement without guessing? Are acceptance criteria testable?
5. DEPENDENCY & SEQUENCING — Are there implicit ordering constraints or external dependencies that are not called out?
6. TESTABILITY — Can the proposed approach be verified with automated tests? Are edge cases addressed?
For each issue found, state the severity (critical / major / minor), the specific decision it applies to, and a concrete recommendation."
```

Before calling council, capture the working tree state with `git status --porcelain`. After council returns, run `git status --porcelain` again. If any files changed during the council run (new entries or different status compared to the before snapshot), revert only those files: `git checkout -- <file>` for modified tracked files, `rm <file>` for newly created untracked files.

The council output includes an `=== COUNCIL ATTRIBUTION ===` block at the end listing which agents succeeded (`Reviewed by:`) and which failed (`Failed:`). Preserve this attribution in `{{WORKSPACE}}/{{STEP_ID}}.md` and inside the matching `## {{STEP_ID}}` section of the Decisions Artifact.

## Codebase Verification

For each point raised by the council, verify it against the codebase before accepting or rejecting it:

1. **Read the relevant files** — if the council claims a conflict, missing edge case, or architectural risk, open the actual code, config, `CONTEXT.md`, `CLAUDE.md`, or ADRs it references.
2. **Verdict** — state whether the point is **valid**, **partially valid**, or **invalid**, citing what you found in the codebase as evidence.
3. **Concrete change** — if valid, specify exactly what should change: which decision in the issue should be updated, what wording should be added or removed, or what constraint should be documented. If invalid, explain why with evidence from the code.

Do not accept or reject council feedback based on reasoning alone. Every verdict must reference something you actually read in the codebase or project docs.

## Filtering

Keep:

- Critical or major feedback that could change scope, architecture, sequencing, correctness, or operator workflow.
- Questions that require human judgment and cannot be resolved from the codebase alone.
- Conflicts with `CONTEXT.md`, `CLAUDE.md`, or ADRs.

Drop:

- Minor or nitpick-level feedback
- Wording preferences that do not change behavior
- Style-only comments
- Speculative future work outside this issue

## Output File

Write findings to `{{WORKSPACE}}/{{STEP_ID}}.md`. For every point (kept or dropped), include the council's original point, your analysis, and your recommendation.

Structure:

```md
# Review Decisions — {{STEP_ID}}

## Major feedback

### 1. <short title>

**Council:** <what the council said>

**Verified against:** <file(s) or doc(s) you read to check this>

**Verdict:** Valid | Partially valid | Invalid

**Analysis:** <what you found in the codebase — why this matters or why the council is wrong>

**Recommended change:** <exact change to the issue decisions, or why no change is needed>

### 2. ...

## Open questions

### 1. <short title>

**Council:** <what the council raised>

**Verified against:** <file(s) or doc(s) you checked>

**Analysis:** <why this can't be resolved from the codebase alone>

**Recommendation:** <what the human should decide and what the tradeoffs are>

### 2. ...

## Council Attribution

Reviewed by: <comma-separated list of agents that succeeded>
Failed: <comma-separated list of agents that failed, or "none">

## Dropped feedback

### 1. <short title>

**Council:** <what the council said>

**Why dropped:** <why this is a nitpick, style-only, or out of scope>

### 2. ...
```

## Update the Decisions Artifact

After writing the output file, write the review findings to the Decisions Artifact Issue. Downstream steps read artifact issues for full planning context and use the parent only as a compact index.

1. Ensure `{{WORKSPACE}}/original-issue.md` exists, preserving the parent issue body before the first Parent Issue Index refresh:
   ```bash
   if [[ ! -f "{{WORKSPACE}}/original-issue.md" ]]; then
     gh issue view {{ISSUE}} --repo {{REPO}} --json body -q .body > "{{WORKSPACE}}/original-issue.md"
   fi
   ```
2. Merge `{{WORKSPACE}}/{{STEP_ID}}.md` into `{{WORKSPACE}}/decisions.md` under `## {{STEP_ID}}`, replacing that section when it already exists.
3. Keep `## Original Feature Request / Grilled Decisions` seeded from `{{WORKSPACE}}/original-issue.md`.
4. Create or reuse the Decisions Artifact Issue:
   ```bash
   artifact_issue="$(artifact_ensure "{{WORKSPACE}}/state.json" "{{REPO}}" "{{ISSUE}}" "decisions" "{{STEP_ID}}" "{{WORKSPACE}}/decisions.md" "[ralph artifact] #{{ISSUE}} Decisions")"
   artifact_link_to_parent "{{REPO}}" "{{ISSUE}}" "$artifact_issue"
   artifact_write_body "{{ISSUE}}" "decisions" "{{STEP_ID}}" "{{WORKSPACE}}/decisions.md" "{{WORKSPACE}}/decisions-artifact-body.md"
   artifact_update_body "{{WORKSPACE}}/state.json" "{{REPO}}" "{{ISSUE}}" "decisions" "$artifact_issue" "{{WORKSPACE}}/decisions-artifact-body.md"
   artifact_refresh_parent_index "{{WORKSPACE}}/state.json" "{{REPO}}" "{{ISSUE}}"
   ```
5. Treat any artifact helper create/reuse/update failure as a hard stop and set this Step to `failed`.

## Blocking Protocol

Read the `hitl` field for step `{{STEP_ID}}` from `{{WORKSPACE}}/state.json`. Only apply the blocking protocol below if `hitl` is `true`. If `hitl` is `false`, complete normally regardless of open questions.

If `hitl` is `true` and there are open questions requiring human judgment:

1. Set this step status to `blocked` in `{{WORKSPACE}}/state.json`.
2. Create `{{WORKSPACE}}/hitl-{{STEP_ID}}.md`.
3. Include the questions and an `## Answers` section in the flag file.
4. Stop after writing the flag file.

If there are no open questions, complete normally so Ralph marks the step completed.
