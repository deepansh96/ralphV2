# PR Creation

Create or update the pull request for GitHub issue `{{ISSUE}}` in `{{REPO}}`.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Branch: {{BRANCH}}
Base branch: {{BASE_BRANCH}}
Step: {{STEP_ID}}

Default agent: codex
Mode: AFK, no HITL

## Goal

Push the feature branch and ensure exactly one open PR exists. This step does
not prepare QA, run QA, or review code.

## Inputs

- Read the parent issue, every `implement-slice` sub-issue in state, and
  `{{WORKSPACE}}/final-checks.md`.
- Work from the project root recorded in state.
- Fetch origin and check out `{{BRANCH}}`.

## Target Branch

If `{{BASE_BRANCH}}` does not start with `grill/`, use it as the PR target.

If it starts with `grill/`:

1. Resolve the repository default branch with
   `gh repo view {{REPO}} --json defaultBranchRef -q .defaultBranchRef.name`.
2. Merge `origin/{{BASE_BRANCH}}` into `{{BRANCH}}` with `git merge --no-edit`.
3. Abort and fail on conflicts.
4. Use the default branch as the PR target.

Push `{{BRANCH}}`, using `git push -u origin {{BRANCH}}` when needed.

## PR Body

The body contains only:

```md
## Summary

- ...

## Linked Issues

- Closes #{{ISSUE}}
- Closes #<sub-issue>
```

Do not include a review section or QA checklist.

Use `gh pr list` to find an open PR for the head branch and resolved target.
Update it with `gh pr edit`; otherwise create it with `gh pr create`. If an
older PR targets a `grill/*` branch, retarget it instead of creating another.

Write `{{WORKSPACE}}/pr-creation.md` with the PR number, URL, target branch,
whether it was created or updated, and linked issues. Fail on checkout, merge,
push, or PR errors.
