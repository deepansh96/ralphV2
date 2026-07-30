# Cleanup Local Resources

Clean local resources left by this Ralph pipeline.

Issue: {{ISSUE}}
Repo: {{REPO}}
Workspace: {{WORKSPACE}}
Branch: {{BRANCH}}
Step: {{STEP_ID}}

Default agent: codex
Mode: AFK, no HITL, always run

This step runs after success and after an earlier step fails.

1. Read `{{WORKSPACE}}/local-resources.json` when present.
2. Stop recorded local processes and services.
3. Stop and remove recorded Docker containers.
4. Close recorded browser or computer-use sessions.
5. Remove recorded temporary files and directories.
6. Inspect the project worktree for uncommitted debug edits, rough files, logs,
   generated databases, coverage output, or other pipeline leftovers.
7. Remove or restore only leftovers clearly created by this pipeline. Never use
   `git reset --hard`, never alter commits, and never delete an unknown change.
8. Check for resources named with the `ralph-{{ISSUE}}-` prefix that were
   missed by the ledger and clean them.
9. After all known entries are handled successfully, replace the ledger with:
   `{"processes":[],"containers":[],"tempPaths":[],"sessions":[]}`.
   Keep any entry whose resource could not be cleaned.

Do not invoke the post-merge `cleanup.sh`; it archives the workspace and is a
separate operation.

Write `{{WORKSPACE}}/cleanup-local-resources.md` listing what was cleaned and
anything left untouched because ownership was unclear. Fail only when a known
pipeline-owned resource could not be cleaned.
