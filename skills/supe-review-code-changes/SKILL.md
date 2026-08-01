---
name: supe-review-code-changes
description: Perform a read-only review of a pull request, branch, commit range, or working-tree diff against its requirements and the repository's documented standards. Use only when explicitly invoked to find actionable correctness, security, compatibility, and test-coverage problems before merge.
---

# Supe Review Code Changes

Review the change, not the author's explanation of it. Keep the checkout read-only and report only findings the author can act on.

## 1. Fix The Review Scope

Identify and record:

- the repository and worktree
- the base and head revisions
- the exact diff command
- the PR description, linked issue, plan, or other requirements

For a PR, use its actual base and head SHAs. For a branch, compare from the merge base with the target branch. If the target cannot be inferred safely, ask for it. Stop if the revisions do not resolve or the diff is empty.

Do not change files, the index, `HEAD`, branches, PR comments, or review threads.

## 2. Build Relevant Context

Read:

- the complete diff and commit list
- the closest `AGENTS.md` files and relevant repository guidance
- the requirements source
- surrounding implementations, callers, types, tests, and configuration needed to understand each changed path

Use repository tools and existing patterns as the source of truth. Do not judge a hunk in isolation when its behavior depends on code outside the diff.

## 3. Review For Real Defects

Check whether the change:

- implements every requirement without unrelated scope
- introduces incorrect behavior, regressions, races, data loss, or security problems
- mishandles failures, trust boundaries, edge cases, or compatibility
- violates a documented repository rule not already enforced by tooling
- lacks a test that would realistically catch an introduced defect

Trace important data and control flow end to end. Verify suspected findings against the code before reporting them. Do not report speculative concerns, generic advice, praise, or style preferences.

## 4. Calibrate Findings

Assign the lowest severity that accurately reflects impact:

- `P0`: immediate, broad, catastrophic failure
- `P1`: serious defect that should block merge
- `P2`: real defect that should be fixed
- `P3`: small but concrete defect

Every finding must:

- identify the smallest useful changed-line range
- state the failure condition
- explain the observable impact
- give a clear fix direction when it is not obvious

Do not inflate severity. Combine findings with the same root cause.

## 5. Report

Lead with findings ordered by severity, then file order. Use:

```text
[P1] Short imperative title
path/to/file.ts:42

Explain the concrete failure, when it occurs, and why it matters. State the fix direction if needed.
```

End with `Verdict: block merge` when any `P0` or `P1` finding exists; otherwise use `Verdict: no blocking findings`. If there are no findings, say so directly and mention only meaningful remaining test gaps or uncertainty.
