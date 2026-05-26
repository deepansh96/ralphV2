# PR Review

Create or update the pull request for GitHub issue `{{ISSUE}}` in repo `{{REPO}}`, then run automated code review.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Branch: {{BRANCH}}
Base branch: {{BASE_BRANCH}}
Step: {{STEP_ID}}
Skills: {{SKILLS_DIR}}
Step agent: {{AGENT}}

Default agent: claude
Mode: AFK, no HITL

## Failure Protocol

If any operation fails irrecoverably (checkout, push, PR creation, code review invocation), set this step's status to `failed` in `{{WORKSPACE}}/state.json` with a note explaining the failure, then stop.

## Goal

Create an idempotent PR from the feature branch to the base branch, write a comprehensive PR description with a summary of changes, linked sub-issues, and a human QA checklist, run a council review for independent multi-agent feedback, then run the automated code review path for this step's assigned agent. Synthesize both reviews into a single combined review comment on the PR.

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

The council output includes an `=== COUNCIL ATTRIBUTION ===` block at the end listing which agents succeeded (`Reviewed by:`) and which failed (`Failed:`). Preserve this attribution for inclusion in the combined review PR comment.

Save the council output to `{{WORKSPACE}}/council-pr-review.md`.

## Automated Code Review

After the council review completes, read this step's assigned agent from `{{WORKSPACE}}/state.json` for step `{{STEP_ID}}`. It should match `Step agent: {{AGENT}}`.

Use exactly one automated review path:

- If the step agent is `claude`, invoke the `code-review:code-review` plugin skill on the PR. The review must be posted as PR comments. If the skill requires a PR URL, pass the PR URL. If it requires repository, base, and head information, pass `{{REPO}}`, `{{BASE_BRANCH}}`, and `{{BRANCH}}`. If the `code-review:code-review` plugin skill is unavailable or fails, stop and report the failure.
- If the step agent is `codex`, run Codex's local review command from the project root and save its output:

```bash
git fetch origin {{BASE_BRANCH}}
codex -a never --sandbox danger-full-access review --base origin/{{BASE_BRANCH}} > {{WORKSPACE}}/codex-pr-review.md
```

If `origin/{{BASE_BRANCH}}` is not available after fetch but local `{{BASE_BRANCH}}` exists, retry once with:

```bash
codex -a never --sandbox danger-full-access review --base {{BASE_BRANCH}} > {{WORKSPACE}}/codex-pr-review.md
```

If `codex review` is unavailable or exits non-zero, stop and report the failure.
- If the step agent is neither `claude` nor `codex`, stop and report that automated PR review is unsupported for that agent.

Do not mark this step complete unless the selected automated review path has completed successfully.

## Combined Review

Before synthesizing, verify each council finding against the actual code. For each point: read the relevant files and diffs the council references. State whether the point is valid, partially valid, or invalid, citing what you found. If invalid, drop it with evidence. Do not accept or reject council feedback based on reasoning alone.

After verification, synthesize the verified council findings and the selected automated review findings into a single combined review. For the Claude path, use the `code-review:code-review` findings from PR comments. For the Codex path, use `{{WORKSPACE}}/codex-pr-review.md`. Filter the council findings using the same rules as other review steps: keep critical and major issues, drop nitpicks, style-only comments, and points invalidated by codebase verification. Include the automated review source (`code-review:code-review` or `codex review`) and a council attribution line at the end of the comment (e.g., `Reviewed by: codex, gemini, kimi · Failed: deepseek` or `Reviewed by: codex, gemini, kimi, deepseek` if none failed). Post the combined review as a PR comment using `gh pr comment`.

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
- Automated review source used (`code-review:code-review` or `codex review`).
- Confirmation that the selected automated review completed successfully.
- Confirmation that the combined review was posted as a PR comment.

## Completion

Complete normally only after:

- The feature branch has been pushed.
- An open PR exists from `{{BRANCH}}` to `{{BASE_BRANCH}}`.
- Re-running the step would update the existing PR instead of creating a duplicate.
- The PR description includes a summary of changes, linked sub-issues, and a human QA checklist.
- The council review has completed and findings are saved to `{{WORKSPACE}}/council-pr-review.md`.
- The selected automated review path for the step agent has completed successfully.
- The combined review (council + automated review) is posted as a PR comment.
