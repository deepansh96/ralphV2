# PR Review

Create or update the pull request for GitHub issue `{{ISSUE}}` in repo `{{REPO}}`, then run automated code review.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Branch: {{BRANCH}}
Base branch: {{BASE_BRANCH}}
Step: {{STEP_ID}}
Skills: {{SKILLS_DIR}}

Default agent: claude
Mode: AFK, no HITL

## Failure Protocol

If any operation fails irrecoverably (checkout, push, PR creation, code review invocation), set this step's status to `failed` in `{{WORKSPACE}}/state.json` with a note explaining the failure, then stop.

## Goal

Create an idempotent PR from the feature branch to the base branch, write a comprehensive PR description with a summary of changes, linked sub-issues, and a human QA checklist, run a council review for independent multi-agent feedback, then invoke the `code-review:code-review` plugin skill. Synthesize both reviews into a single combined review comment on the PR.

## Required Inputs

- Read project `CONTEXT.md`.
- Read project `CLAUDE.md`.
- Read any ADRs under `docs/adr/` if that directory exists.
- Read the parent issue:
  `gh issue view {{ISSUE}} --repo {{REPO}}`
- Read the current workspace state:
  `{{WORKSPACE}}/state.json`
- Read the final review summary if it exists:
  `{{WORKSPACE}}/final-review.md`
- Identify implementation sub-issues from state steps where `type` is `implement-slice`, then read each sub-issue:
  `gh issue view <sub-issue-number> --repo {{REPO}}`

## Branch

Work on the feature branch recorded in state:

```bash
git checkout {{BRANCH}}
```

If checkout fails, stop and report the failure.

Ensure the branch is pushed before creating or updating the PR:

```bash
git push
```

If upstream tracking is missing, push with:

```bash
git push -u origin {{BRANCH}}
```

## PR Body

Write a PR body file in the workspace, for example:

```text
{{WORKSPACE}}/pr-body.md
```

The PR description must include:

- Summary of changes.
- Linked sub-issues.
- Human QA checklist.
- Final review outcome from `{{WORKSPACE}}/final-review.md`, if available.

Use this structure:

```md
## Summary

- ...

## Linked Issues

- Closes #<sub-issue>
- Parent: #{{ISSUE}}

## Final Review

- ...

## Human QA Checklist

- [ ] ...
```

## Idempotent PR Creation

Do not create duplicate PRs.

First check whether a PR already exists for the branch:

```bash
gh pr list --repo {{REPO}} --head {{BRANCH}} --base {{BASE_BRANCH}} --state open --json number,url
```

If an open PR exists, update its title and body instead of creating another PR:

```bash
gh pr edit <pr-number> --repo {{REPO}} --title "<title>" --body-file {{WORKSPACE}}/pr-body.md
```

If no open PR exists, create one:

```bash
gh pr create --repo {{REPO}} --base {{BASE_BRANCH}} --head {{BRANCH}} --title "<title>" --body-file {{WORKSPACE}}/pr-body.md
```

Capture the PR number and URL from either the existing PR or the newly created PR.

## Council Code Review

After the PR exists, run a council review for independent multi-agent feedback on the changes. The council agents are on the feature branch with all code available locally.

```bash
./ralph-v2/scripts/council-review.sh --only {{REVIEWERS}} "IMPORTANT: You are a reviewer. DO NOT modify any files, create branches, run tests, or make any changes to the codebase or config. Only read and analyze. Provide feedback as text output only.

You are reviewing PR #<pr-number> for GitHub issue {{ISSUE}} in repo {{REPO}}. You are on the feature branch with all code available locally. The PR merges {{BRANCH}} into {{BASE_BRANCH}}.

Review the full change from the perspective of a senior engineer. Focus on real issues that would block a merge — correctness bugs, architectural concerns, security issues, missing edge cases. Ignore style, nitpicks, and anything a linter would catch. For each issue found, state severity (critical/major/minor) and a concrete recommendation."
```

Before calling council, capture the working tree state with `git status --porcelain`. After council returns, run `git status --porcelain` again. If any files changed during the council run (new entries or different status compared to the before snapshot), revert only those files: `git checkout -- <file>` for modified tracked files, `rm <file>` for newly created untracked files.

Save the council output to `{{WORKSPACE}}/council-pr-review.md`.

## Automated Code Review

After the council review completes, invoke the `code-review:code-review` plugin skill on the PR.

The review must be posted as PR comments. If the skill requires a PR URL, pass the PR URL. If it requires repository, base, and head information, pass `{{REPO}}`, `{{BASE_BRANCH}}`, and `{{BRANCH}}`.

If the `code-review:code-review` plugin skill is unavailable or fails, stop and report the failure. Do not mark this step complete unless the automated review has been invoked successfully.

## Combined Review

After both reviews complete, synthesize the council findings and the `code-review:code-review` findings into a single combined review. Filter the council findings using the same rules as other review steps: keep critical and major issues, drop nitpicks and style-only comments. Post the combined review as a PR comment using `gh pr comment`.

## Output

After the PR is created or updated and the automated review is invoked, write a concise record to:

```text
{{WORKSPACE}}/pr-review.md
```

Include:

- PR number and URL.
- Whether the PR was created or updated.
- Linked sub-issues included in the body.
- Summary of council review findings (kept and dropped).
- Confirmation that `code-review:code-review` was invoked and review comments were posted.
- Confirmation that the combined review was posted as a PR comment.

## Completion

Complete normally only after:

- The feature branch has been pushed.
- An open PR exists from `{{BRANCH}}` to `{{BASE_BRANCH}}`.
- Re-running the step would update the existing PR instead of creating a duplicate.
- The PR description includes a summary of changes, linked sub-issues, and a human QA checklist.
- The council review has completed and findings are saved to `{{WORKSPACE}}/council-pr-review.md`.
- The `code-review:code-review` plugin skill has been invoked on the PR.
- The combined review (council + code-review) is posted as a PR comment.
