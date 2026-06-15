# QA Slice

Run local QA for GitHub sub-issue `{{SUB_ISSUE}}` under parent issue `{{ISSUE}}` in repo `{{REPO}}`.

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

If local setup, required credentials, test data, API checks, browser checks, or acceptance criteria fail irrecoverably, set this step's status to `failed` in `{{WORKSPACE}}/state.json` with a note explaining the blocker or regression, comment the failure summary on the QA sub-issue, and stop. Do not close the QA sub-issue on failure.

## Goal

Read the project context, parent issue, assigned QA sub-issue, and relevant code paths; design smart local QA from the code and the issue criteria; back up the local database before testing; run the local QA checks; restore the local database from that backup before completion; save API logs, browser screenshots, traces, and command output under a temporary QA artifact directory; comment the result on the QA sub-issue; close the QA sub-issue only when every acceptance criterion passes.

## Required Inputs

- Read project `CONTEXT.md`.
- Read project `CLAUDE.md`.
- Read any ADRs under `docs/adr/` if that directory exists.
- If `graphify-out/GRAPH_REPORT.md` exists, read it before selecting files to inspect.
- Read the parent issue for overall context:
  `gh issue view {{ISSUE}} --repo {{REPO}}`
- Read the assigned QA sub-issue for this slice's exact requirements:
  `gh issue view {{SUB_ISSUE}} --repo {{REPO}}`
- Read the current workspace state:
  `{{WORKSPACE}}/state.json`

## Smart QA Requirement

Do not run the checklist mechanically. Before testing:

1. Read the code and existing tests that implement or exercise the assigned QA slice.
2. Identify the public API/UI surface, validation rules, authorization boundary, persistence side effects, and shared components in the blast radius.
3. Add code-informed QA checks where the issue checklist is incomplete. Prefer high-signal checks that can catch real regressions over broad busywork.
4. Write the resulting checklist to `$QA_ROOT/logs/checklist.md`, separating:
   - issue acceptance criteria
   - code-informed checks added by the QA agent
   - explicit out-of-scope areas

The QA result comment must include a short "Smart QA additions" section listing what was added after reading the code and why.

## Blocker Verification

Before starting QA, check whether sub-issue `#{{SUB_ISSUE}}` lists any blocked-by issues. If it does, verify each blocker is closed:

```bash
gh issue view <blocker-number> --repo {{REPO}} --json state -q '.state'
```

If any blocker is still open, set this step's status to `failed` with a note listing the open blockers, comment on the QA sub-issue, and stop.

## Branch And Local App

This repo uses git submodules. Run all git commands from the project root recorded in `{{WORKSPACE}}/state.json`.

```bash
cd $(jq -r '.projectRoot' {{WORKSPACE}}/state.json)
git fetch origin
git checkout {{BRANCH}} 2>/dev/null || git checkout -b {{BRANCH}} origin/{{BRANCH}}
```

If checkout fails, stop and report the failure.

Create a temporary artifact root for this slice:

```bash
export QA_ROOT="/tmp/ads-pr{{ISSUE}}-qa-slice-{{SUB_ISSUE}}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$QA_ROOT"/{api,screenshots,playwright,traces,logs}
```

## Local Database Backup And Restore

Before running any API, browser, or automated QA that can mutate local data, create a local database backup and record the backup path:

```bash
cd $(jq -r '.projectRoot' {{WORKSPACE}}/state.json)
set -a
[ -f server/.env ] && . server/.env
set +a
: "${DATABASE_URL:?DATABASE_URL is required for local DB backup}"
export QA_DB_BACKUP="$QA_ROOT/local-db-before-qa.dump"
pg_dump --format=custom --no-owner --no-acl --file "$QA_DB_BACKUP" "$DATABASE_URL"
```

Guardrail: this QA step is only allowed to back up and restore a local/dev/test database. If `DATABASE_URL` does not clearly point to local infrastructure (for example `localhost`, `127.0.0.1`, a local Docker host, or an explicitly named dev/test database), stop and fail the step with a blocker. Do not run `pg_dump`, `pg_restore`, destructive cleanup, or tests against production-like database URLs.

Before completing the step, restore the local database from the backup even if the QA checks pass. Stop any local server process started by this step before restore so active connections do not block the restore.

```bash
pg_restore --clean --if-exists --no-owner --no-acl --dbname "$DATABASE_URL" "$QA_DB_BACKUP"
```

If restore fails, do not close the QA sub-issue. Set the Ralph step to `failed`, comment the failure and backup path on the QA issue, and stop.

Use local URLs unless the QA sub-issue states otherwise:

- API: `http://localhost:8811`
- Client: `http://localhost:8812`

If local services are not already running, start them according to `CLAUDE.md` or `./start-local.sh`. Do not leave required foreground sessions running unattended at completion.

## QA Scope Rules

- Run only the checks listed in the QA sub-issue and directly required setup/cleanup.
- Do not modify product code.
- Do not commit product changes.
- Temporary QA helper scripts are allowed only under `$QA_ROOT`.
- Screenshots must be saved under `$QA_ROOT/screenshots`.
- API request/response logs must be saved under `$QA_ROOT/api`.
- Playwright output, traces, videos, and failure screenshots must be saved under `$QA_ROOT/playwright` or `$QA_ROOT/traces`.
- Avoid future-dated Check-in records. Use today or earlier only.
- Clean up created local test records when practical during QA, but still restore the local database from `$QA_DB_BACKUP` before completion.

## Local Authentication

Prefer existing local debug-login and Playwright storage setup:

```bash
cd client
E2E_BASE_URL=http://localhost:8812 npx playwright test --project=chromium --list
```

For browser checks, use `client/e2e/storage/admin.json` and `client/e2e/storage/sales.json` when available, or run Playwright global setup against local debug login. For API checks, extract `accessToken` from the relevant storage state or direct-login response. If credentials or debug login are unavailable, fail the step with a clear blocker and leave the QA sub-issue open.

## Execution

1. Read relevant code and tests, then translate the QA sub-issue acceptance criteria plus code-informed checks into `$QA_ROOT/logs/checklist.md`.
2. Back up the local database to `$QA_DB_BACKUP`.
3. Run the required API, browser, automated, and smart QA checks.
4. Capture screenshots for each requested browser state.
5. Save command output and API responses into `$QA_ROOT`.
6. Check browser console errors when browser QA is in scope.
7. Restore the local database from `$QA_DB_BACKUP`.
8. Verify every acceptance criterion and smart QA addition.

## GitHub Comment

After QA, comment on the sub-issue with:

```md
## QA Result

Status: PASS / FAIL

Artifact root: `<QA_ROOT>`

### Commands run
- ...

### Screenshots
- `<path>`

### API evidence
- `<path>`

### Findings
- None / ...

### Smart QA additions
- ...

### Database backup/restore
- Backup: `<path>`
- Restore: success / failure

### Acceptance criteria
- [x] ...
- [ ] ...
```

## Completion

Complete normally only after:

- All acceptance criteria in the QA sub-issue pass.
- Required screenshots and logs are saved under `$QA_ROOT`.
- The local database was restored successfully from `$QA_DB_BACKUP` after testing.
- A QA result comment is posted on the QA sub-issue.
- The QA sub-issue is closed with a comment such as:

```bash
gh issue close {{SUB_ISSUE}} --repo {{REPO}} --comment "Local QA passed. Artifacts: $QA_ROOT"
```

Do not close the parent issue.
