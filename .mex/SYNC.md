# Sync - Realign This Scaffold

Use mex drift checks when the codebase or workflow changes.

## Quick Check

```bash
npx mex-agent check
npx mex-agent check --quiet
npx mex-agent sync --dry-run
```

If mex is installed globally, the same commands work as `mex check`, `mex check --quiet`, and `mex sync --dry-run`.

## Manual Resync

1. Read `.mex/ROUTER.md`.
2. Load the context files relevant to the drift.
3. Compare scaffold claims to the actual repo files.
4. Update only stale sections; do not rewrite unrelated context.
5. Preserve YAML frontmatter fields and edge targets.
6. In `.mex/context/decisions.md`, never delete old decisions; mark superseded decisions and add new ones above them.
7. Update `last_updated` in every scaffold file changed.
8. Run `npx mex-agent check --quiet`.

Report changed files, any superseded decisions, and anything that could not be verified.
