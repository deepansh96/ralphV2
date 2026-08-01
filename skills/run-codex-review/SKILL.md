---
name: run-codex-review
description: Run a second, isolated Codex reviewer through a fresh App Server process and its review/start API. Invoke explicitly with $run-codex-review when you want an independent review of uncommitted changes, a branch diff, one commit, or custom review instructions.
---

# Run Codex Review

Use the bundled launcher instead of recreating the App Server protocol.

## Workflow

1. Inspect the repository and choose exactly one target:
   - Working tree: `--uncommitted`
   - Current branch against a base: `--base <branch>`
   - One commit: `--commit <sha>`
   - Free-form review task: `--custom <instructions>`
2. Run:

Use the `scripts/review.mjs` beside this `SKILL.md`; resolve it from the skill
path supplied by the caller rather than from a global skills directory:

```sh
node "<skills-dir>/run-codex-review/scripts/review.mjs" \
  --cwd /absolute/path/to/repo \
  --base main
```

3. Check each reported finding against the code before presenting it.
4. Report actionable findings first, ordered by severity and with file/line references. Say clearly when the reviewer found no issues.

## Rules

- Do not assemble or paste the Git diff; `review/start` reads it from `cwd`.
- Let the child inherit `CODEX_HOME`, authentication, and Codex configuration.
- Do not edit files as part of this skill. Review only.
- Do not use detached delivery. The fresh App Server process is already isolated.
- Do not leave the child process running after the review completes or fails.
