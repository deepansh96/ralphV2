# Implement Slice

Implement GitHub sub-issue `{{SUB_ISSUE}}` for parent issue `{{ISSUE}}` in repo `{{REPO}}`.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Branch: {{BRANCH}}
Base branch: {{BASE_BRANCH}}
Step: {{STEP_ID}}
Sub-issue: {{SUB_ISSUE}}
Skills: {{SKILLS_DIR}}

Default agent: codex
Mode: AFK, no HITL

## Failure Protocol

If any operation fails irrecoverably (checkout, tests, quality checks), set this step's status to `failed` in `{{WORKSPACE}}/state.json` with a note explaining the failure, then stop.

## Goal

Read the project context, compact Parent Issue Index, PRD Artifact Issue, Slice Plan Artifact Issue, and assigned sub-issue; implement only the assigned sub-issue via TDD on the feature branch; run project quality checks; commit, push, and close the sub-issue after the implementation is verified.

## Required Inputs

- Read project `CONTEXT.md`.
- Read project `CLAUDE.md`.
- Read any ADRs under `docs/adr/` if that directory exists.
- Read the TDD skill workflow files from Ralph's bundled skills directory:
  - `{{SKILLS_DIR}}/tdd/SKILL.md`
  - `{{SKILLS_DIR}}/tdd/tests.md`
  - `{{SKILLS_DIR}}/tdd/mocking.md`
  - `{{SKILLS_DIR}}/tdd/deep-modules.md`
  - `{{SKILLS_DIR}}/tdd/interface-design.md`
  - `{{SKILLS_DIR}}/tdd/refactoring.md`
- Read the parent issue for overall context:
  `gh issue view {{ISSUE}} --repo {{REPO}}`
- Read the assigned sub-issue for this slice's exact requirements:
  `gh issue view {{SUB_ISSUE}} --repo {{REPO}}`
- Read the current workspace state:
  `{{WORKSPACE}}/state.json`
- From the project root, run this State helper snippet in bash and read artifact issue numbers. Do not source these helpers from zsh or another non-bash shell:

```bash
source ./ralph-v2/scripts/state.sh
state_ensure_artifacts {{WORKSPACE}}/state.json
prd_artifact_issue="$(state_get_artifact {{WORKSPACE}}/state.json prd)"
slice_plan_artifact_issue="$(state_get_artifact {{WORKSPACE}}/state.json slice-plan)"
```

- Read the PRD Artifact Issue for broader planning context:
  `gh issue view <prd-artifact-issue> --repo {{REPO}}`
- Read the Slice Plan Artifact Issue for broader planning context:
  `gh issue view <slice-plan-artifact-issue> --repo {{REPO}}`
- The parent issue is now a compact Parent Issue Index. Use it for routing and links, but do not rely on the parent issue body for full PRD or Slice Plan content.
- If `prd_artifact_issue` or `slice_plan_artifact_issue` is empty, malformed, or unavailable, fail this step with a recovery note instead of guessing from partial parent content.

## Blocker Verification

Before starting implementation, check whether sub-issue `#{{SUB_ISSUE}}` lists any blocked-by issues. If it does, verify each blocker is closed:

```bash
gh issue view <blocker-number> --repo {{REPO}} --json state -q '.state'
```

If any blocker is still open, set this step's status to `failed` with a note listing the open blockers, then stop.

## Scope Rules

- Implement only sub-issue `#{{SUB_ISSUE}}`.
- Use the PRD Artifact Issue and Slice Plan Artifact Issue only as broader planning context.
- Stay within the acceptance criteria listed in the assigned sub-issue.
- Do not implement other parent issue slices, blocked-by issues, referenced future work, or cleanup outside this slice.
- Preserve unrelated user changes in the working tree.

## Branch

**CRITICAL**: This repo uses git submodules. You MUST run ALL git commands from the project root at `{{WORKSPACE}}/../../..` (which is the same as the `projectRoot` in state.json). Do NOT run git commands from inside the workspace directory — it is inside a submodule with a different remote.

First, change to the project root:
```bash
cd $(jq -r '.projectRoot' {{WORKSPACE}}/state.json)
```

Then checkout the feature branch:
```bash
git fetch origin
git checkout {{BRANCH}} 2>/dev/null || git checkout -b {{BRANCH}} origin/{{BRANCH}}
```

If the branch is already checked out, continue. If checkout fails, stop and report the failure.

**Stay in the project root for all subsequent commands** — do not cd back to the workspace.

## TDD Workflow

Follow the TDD skill workflow strictly.

1. Identify the public interface and behavior required by sub-issue `#{{SUB_ISSUE}}`.
2. Write one failing test first for the next observable behavior.
3. Run the focused test and confirm it fails for the expected reason.
4. Implement the smallest change needed to pass that test.
5. Run the focused test and confirm it passes.
6. Repeat one behavior at a time until the sub-issue acceptance criteria are satisfied.
7. Refactor only after tests are green, keeping tests focused on public behavior instead of implementation details.

Use integration-style tests through public interfaces where practical. Mock only external boundaries.

## Quality Checks

Run quality checks from CLAUDE.md before commit. If CLAUDE.md defines exact commands, run those commands. If no exact command is available, run the most relevant project tests for the files changed plus any formatter or lint command already used by the project.

Do not commit if tests or required checks fail.

## Git Commit

After tests and quality checks pass:

1. Review the changed files with `git status --short` and relevant diffs.
2. Commit only the changes for sub-issue `#{{SUB_ISSUE}}`.
3. Use a descriptive commit message that references the sub-issue, for example:

```bash
git commit -m "Implement slice #{{SUB_ISSUE}}"
```

## Push

Push the feature branch after the commit succeeds:

```bash
git push
```

If upstream tracking is missing, push with:

```bash
git push -u origin {{BRANCH}}
```

## Close Sub-Issue

Close the assigned sub-issue only after the implementation commit is pushed successfully:

```bash
gh issue close {{SUB_ISSUE}} --repo {{REPO}} --comment "Implemented in {{BRANCH}}."
```

Do not close the parent issue.

## Post-Implementation Audit

After pushing and before closing the sub-issue, run a self-review:

1. **Acceptance criteria audit** — read the diff against `{{BASE_BRANCH}}` and check each acceptance criterion from the sub-issue. Every criterion must be addressed.
2. **Scope creep check** — flag any changes that implement work belonging to other issues or beyond the stated acceptance criteria. Revert scope creep before closing.
3. **File scope check** — verify that changed files fall within the module or file scope stated in the sub-issue. Flag unexpected file changes.

If the audit finds unmet acceptance criteria, fix them before closing. If scope creep or file scope violations are found, revert the offending changes and re-run quality checks.

## Completion

Complete normally only after:

- The sub-issue acceptance criteria are implemented.
- Tests were written first and pass.
- Quality checks from CLAUDE.md pass.
- The post-implementation audit passes with no unmet criteria, scope creep, or file scope violations.
- Changes are committed with a `#{{SUB_ISSUE}}` reference.
- The feature branch is pushed.
- Sub-issue `#{{SUB_ISSUE}}` is closed on GitHub.
