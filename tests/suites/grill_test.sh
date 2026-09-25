#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

export GIT_AUTHOR_NAME="Ralph Test" GIT_AUTHOR_EMAIL="ralph@example.com"
export GIT_COMMITTER_NAME="Ralph Test" GIT_COMMITTER_EMAIL="ralph@example.com"

UUID_GRILLING="11111111-1111-4111-8111-111111111111"
UUID_ANSWERING="22222222-2222-4222-8222-222222222222"
REQUIREMENT_TEXT=$'# Offline Export\n\nUsers need to export reports offline.'
REQUIREMENT_SHA256="04870b16254c43c51e6e243932fb6791ff6028191de64f8b8c12472d4ce9f1b9"

GRILL_TMP=""
GRILL_REPO=""
GRILL_RALPH=""
GRILL_SESSIONS=""
REQUIREMENT_FILE=""

# Builds a temporary target repository with a local bare remote and a Ralph
# install at <repo>/ralph-v2 (symlinked to this checkout), plus fake claude,
# uuidgen and gh on PATH.
setup_grill_repo() {
  GRILL_TMP="$(mktemp -d)"
  GRILL_REPO="$GRILL_TMP/repo"

  git init -q --bare -b main "$GRILL_TMP/remote.git"
  git init -q -b main "$GRILL_REPO"
  mkdir -p "$GRILL_REPO/ralph-v2"
  ln -s "$ROOT_DIR/ralph.sh" "$GRILL_REPO/ralph-v2/ralph.sh"
  ln -s "$ROOT_DIR/scripts" "$GRILL_REPO/ralph-v2/scripts"
  ln -s "$ROOT_DIR/prompts" "$GRILL_REPO/ralph-v2/prompts"
  ln -s "$ROOT_DIR/skills" "$GRILL_REPO/ralph-v2/skills"
  cp "$ROOT_DIR/ralph.config.json" "$GRILL_REPO/ralph-v2/ralph.config.json"
  printf '# Target project\n' > "$GRILL_REPO/README.md"
  git -C "$GRILL_REPO" add -A
  git -C "$GRILL_REPO" commit -q -m "Initial commit"
  git -C "$GRILL_REPO" remote add origin "$GRILL_TMP/remote.git"
  git -C "$GRILL_REPO" push -q -u origin main
  git -C "$GRILL_REPO" remote set-head origin main

  GRILL_RALPH="$GRILL_REPO/ralph-v2/ralph.sh"
  GRILL_SESSIONS="$GRILL_REPO/ralph-v2/grilling-sessions"
  REQUIREMENT_FILE="$GRILL_TMP/offline-export.md"
  printf '%s\n' "$REQUIREMENT_TEXT" > "$REQUIREMENT_FILE"

  install_fake_grill_claude "$GRILL_TMP/bin"
  install_fake_uuidgen "$GRILL_TMP/bin"
  install_fake_grill_gh "$GRILL_TMP/bin"
  export FAKE_CLAUDE_DIR="$GRILL_TMP/claude"
  export CLAUDE_CONFIG_DIR="$FAKE_CLAUDE_DIR/config"
  export FAKE_UUID_QUEUE="$GRILL_TMP/uuids"
  export FAKE_GH_LOG="$GRILL_TMP/gh.log"
  export FAKE_GH_ISSUE_JSON='{"title":"Add Dark Mode!","body":"Readers want a dark theme."}'
  unset FAKE_CLAUDE_HELP_OMIT
  printf '%s\n%s\n' "$UUID_GRILLING" "$UUID_ANSWERING" > "$FAKE_UUID_QUEUE"
  mkdir -p "$FAKE_CLAUDE_DIR/exchanges"
  : > "$FAKE_GH_LOG"
  queue_minimal_run
}

# Scripts the result text the fake claude returns for one exchange ID.
exchange_fixture() {
  printf '%s\n' "$2" > "$FAKE_CLAUDE_DIR/exchanges/$1.json"
}

# Scripts a shell side effect the fake claude runs in its working directory
# before answering one exchange ID.
exchange_effect() {
  printf '%s\n' "$2" > "$FAKE_CLAUDE_DIR/exchanges/$1.sh"
}

summary_fixture() {
  jq -n -c --arg id "$1" --arg summary "$2" \
    '{exchangeId: $id, decisionSummary: $summary, issueTitle: "Offline export", issueBody: "Export reports offline."}'
}

# The shortest run to the confirmation gate: an empty first Frontier, then the
# closing exchanges.
queue_minimal_run() {
  exchange_fixture ex-0003 '{"exchangeId":"ex-0003","round":1,"questions":[],"reopens":[]}'
  exchange_fixture ex-0004 "$(summary_fixture ex-0004 "- Nothing to decide.")"
  exchange_fixture ex-0005 '{"exchangeId":"ex-0005","faithful":true,"discrepancies":[]}'
  exchange_fixture ex-0006 "$(summary_fixture ex-0006 "- Nothing to decide.")"
}

# Two Frontier rounds (the second reopens a decision), an empty Frontier, and
# the closing exchanges. The first round edits CONTEXT.md inline.
queue_two_round_run() {
  exchange_effect ex-0003 'printf "# Context\n\n**Offline Export**: a report saved for offline reading.\n" > CONTEXT.md'
  exchange_fixture ex-0003 '{"exchangeId":"ex-0003","round":1,
    "questions":[
      {"id":"storage-backend","title":"Where are exports stored?","body":"Pick the storage backend.",
       "choices":[{"id":"sqlite","label":"SQLite","description":"Local file"},
                  {"id":"postgres","label":"Postgres","description":"Server database"}],
       "recommendation":{"choiceId":"sqlite","rationale":"No server exists yet."}},
      {"id":"export-format","title":"Which format?","body":"Pick the export format.",
       "choices":[{"id":"csv","label":"CSV","description":"Plain text"}],
       "recommendation":{"choiceId":"csv","rationale":"Spreadsheets open it."}}],
    "reopens":[]}'
  exchange_fixture ex-0004 '{"exchangeId":"ex-0004","answers":[
      {"questionId":"storage-backend","choiceId":"sqlite","rationale":"The app has no server.","evidence":["README.md"]},
      {"questionId":"export-format","choiceId":"csv","rationale":"Users open exports in spreadsheets.","evidence":["https://example.com/csv"]}]}'
  exchange_fixture ex-0005 '{"exchangeId":"ex-0005","round":2,
    "questions":[
      {"id":"sync-mode","title":"How do exports sync?","body":"Pick the sync mode.",
       "choices":[{"id":"manual","label":"Manual","description":"User triggers sync"}],
       "recommendation":{"choiceId":"manual","rationale":"Simplest."}}],
    "reopens":[{"questionId":"storage-backend","contradiction":"README says exports are shared across devices.","evidence":["README.md"]}]}'
  exchange_fixture ex-0006 '{"exchangeId":"ex-0006","answers":[
      {"questionId":"sync-mode","choiceId":"manual","rationale":"No background jobs exist.","evidence":["README.md"]},
      {"questionId":"storage-backend","choiceId":"postgres","rationale":"Shared exports need a server.","evidence":["README.md"]}]}'
  exchange_fixture ex-0007 '{"exchangeId":"ex-0007","round":3,"questions":[],"reopens":[]}'
  exchange_fixture ex-0008 "$(summary_fixture ex-0008 "- Draft summary: SQLite storage.")"
  exchange_fixture ex-0009 '{"exchangeId":"ex-0009","faithful":false,
    "discrepancies":[{"questionId":"storage-backend","problem":"Summary says SQLite.","fix":"Say Postgres."}]}'
  exchange_fixture ex-0010 "$(jq -n -c '{exchangeId: "ex-0010",
    decisionSummary: "- Storage: Postgres (reopened).\n- Format: CSV.\n- Sync: manual.",
    issueTitle: "Export reports offline with Postgres storage",
    issueBody: "Readers export CSV reports stored in Postgres."}')"
}

teardown_grill_repo() {
  rm -rf "${GRILL_TMP:?}"
}

# Runs ralph.sh grill from the target repository with fakes first on PATH.
grill() {
  (cd "$GRILL_REPO" && PATH="$GRILL_TMP/bin:$PATH" "$GRILL_RALPH" grill "$@")
}

claude_call_count() {
  find "$FAKE_CLAUDE_DIR/calls" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}

claude_argv() {
  cat "$FAKE_CLAUDE_DIR/calls/$1/argv.json"
}

claude_flag_value() {
  jq -r --arg flag "$2" '. as $a | [range(0; length) | select($a[.] == $flag) | $a[. + 1]] | first // ""' \
    "$FAKE_CLAUDE_DIR/calls/$1/argv.json"
}

session_count() {
  find "$GRILL_SESSIONS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}

file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

only_session_dir() {
  find "$GRILL_SESSIONS" -mindepth 1 -maxdepth 1 -type d | head -n 1
}

expect_start_failure() {
  local expected="$1"
  shift
  local output status

  set +e
  output="$(grill start "$@" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected grill start $* to fail"
  assert_contains "$output" "$expected"
  [[ "$(session_count)" == "0" ]] || fail "expected no Grilling Session Record for: $*"
  [[ "$(claude_call_count)" == "0" ]] || fail "expected no native session for: $*"
}

test_start_rejects_invalid_inputs() {
  setup_grill_repo

  expect_start_failure "exactly one of --issue or --requirement-file" \
    --issue 7 --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude
  expect_start_failure "exactly one of --issue or --requirement-file" \
    --grilling-agent claude --answering-agent claude
  expect_start_failure "--grilling-agent is required" \
    --requirement-file "$REQUIREMENT_FILE" --answering-agent claude
  expect_start_failure "--answering-agent is required" \
    --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude
  expect_start_failure "unsupported --answering-agent 'deepseek'" \
    --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent deepseek
  expect_start_failure "requirement file not found" \
    --requirement-file "$GRILL_TMP/missing.md" --grilling-agent claude --answering-agent claude

  teardown_grill_repo
}

test_start_creates_owner_only_record_with_frozen_config() {
  local output session_id session_dir record start_head

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  start_head="$(git -C "$GRILL_REPO" rev-parse HEAD)"

  output="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude \
    --answering-model sonnet --answering-effort high)"

  session_id="$(tail -n 1 <<<"$output")"
  [[ "$session_id" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$ ]] || fail "expected session ID as last line, got: $output"
  session_dir="$GRILL_SESSIONS/$session_id"
  [[ -d "$session_dir" ]] || fail "expected session dir $session_dir"
  [[ "$(file_mode "$GRILL_SESSIONS")" == "700" ]] || fail "expected grilling-sessions/ mode 700"
  [[ "$(file_mode "$session_dir")" == "700" ]] || fail "expected session dir mode 700"
  [[ "$(file_mode "$session_dir/session.json")" == "600" ]] || fail "expected session.json mode 600"
  [[ "$(file_mode "$session_dir/requirement.md")" == "600" ]] || fail "expected requirement.md mode 600"
  [[ "$(<"$session_dir/requirement.md")" == "$REQUIREMENT_TEXT" ]] || fail "expected requirement snapshot"

  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.id' <<<"$record")" == "$session_id" ]] || fail "expected record id"
  [[ "$(jq -r '.status' <<<"$record")" == "blocked" ]] || fail "expected status blocked"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected awaiting_confirmation"
  [[ "$(jq -r '.input.kind' <<<"$record")" == "requirement_file" ]] || fail "expected input kind"
  [[ "$(jq -r '.input.requirementSha256' <<<"$record")" == "$REQUIREMENT_SHA256" ]] || fail "expected requirement sha256"
  [[ "$(jq -r '.input.requirementPath' <<<"$record")" == "requirement.md" ]] || fail "expected requirement path"
  [[ "$(jq -r '.repo.root' <<<"$record")" == "$(cd "$GRILL_REPO" && pwd -P)" ]] || fail "expected repo root"
  [[ "$(jq -r '.repo.remote' <<<"$record")" == "origin" ]] || fail "expected remote"
  [[ "$(jq -r '.repo.startBranch' <<<"$record")" == "feature-work" ]] || fail "expected start branch"
  [[ "$(jq -r '.repo.branch' <<<"$record")" == "feature-work" ]] || fail "expected branch to stay off default"
  [[ "$(jq -r '.repo.startHead' <<<"$record")" == "$start_head" ]] || fail "expected start head"
  [[ "$(jq -r '.repo.defaultBranch' <<<"$record")" == "main" ]] || fail "expected default branch"
  [[ "$(jq -c '.agents.grilling | {provider, model, reasoningEffort}' <<<"$record")" \
    == '{"provider":"claude","model":"opus","reasoningEffort":"medium"}' ]] \
    || fail "expected grilling config from ralph.config.json defaults"
  [[ "$(jq -c '.agents.answering | {provider, model, reasoningEffort}' <<<"$record")" \
    == '{"provider":"claude","model":"sonnet","reasoningEffort":"high"}' ]] \
    || fail "expected answering config from flags"
  [[ "$(git -C "$GRILL_REPO" branch --show-current)" == "feature-work" ]] || fail "expected no branch switch"

  teardown_grill_repo
}

test_start_opens_two_distinct_native_claude_sessions() {
  local session_dir record grilling_prompt answering_prompt

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work

  grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude \
    --grilling-model opus --answering-model opus >/dev/null

  [[ "$(find "$CLAUDE_CONFIG_DIR/projects" -type f -name '*.jsonl' | wc -l | tr -d ' ')" == "2" ]] \
    || fail "expected exactly two native sessions"
  [[ "$(claude_flag_value 0001 --session-id)" == "$UUID_GRILLING" ]] || fail "expected grilling session first"
  [[ "$(claude_flag_value 0002 --session-id)" == "$UUID_ANSWERING" ]] || fail "expected answering session second"
  [[ "$(claude_flag_value 0001 --model)" == "opus" ]] || fail "expected grilling model"
  [[ "$(claude_flag_value 0002 --model)" == "opus" ]] || fail "expected answering model"

  grilling_prompt="$(claude_flag_value 0001 -p)"
  answering_prompt="$(claude_flag_value 0002 -p)"
  assert_contains "$grilling_prompt" "[ralph-exchange:ex-0001]"
  assert_contains "$grilling_prompt" "Grilling Agent"
  assert_contains "$grilling_prompt" "Users need to export reports offline."
  assert_contains "$answering_prompt" "[ralph-exchange:ex-0002]"
  assert_contains "$answering_prompt" "Answering Agent"
  assert_contains "$answering_prompt" "Users need to export reports offline."

  session_dir="$(only_session_dir)"
  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.agents.grilling.nativeSessionId' <<<"$record")" == "$UUID_GRILLING" ]] || fail "expected stored grilling native ID"
  [[ "$(jq -r '.agents.answering.nativeSessionId' <<<"$record")" == "$UUID_ANSWERING" ]] || fail "expected stored answering native ID"
  [[ "$(jq -c '[.exchanges[:2][] | {id, kind, role, status}]' <<<"$record")" \
    == '[{"id":"ex-0001","kind":"session_start","role":"grilling","status":"completed"},{"id":"ex-0002","kind":"session_start","role":"answering","status":"completed"}]' ]] \
    || fail "expected both start exchanges recorded"
  [[ "$(file_mode "$session_dir/logs/ex-0001-grilling.jsonl")" == "600" ]] || fail "expected grilling log mode 600"
  [[ "$(file_mode "$session_dir/logs/ex-0002-answering.jsonl")" == "600" ]] || fail "expected answering log mode 600"

  teardown_grill_repo
}

test_start_fails_when_native_ids_are_equal() {
  local output status record

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  printf '%s\n%s\n' "$UUID_GRILLING" "$UUID_GRILLING" > "$FAKE_UUID_QUEUE"

  set +e
  output="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected equal native IDs to fail start"
  assert_contains "$output" "native session IDs must differ"
  [[ "$(claude_call_count)" == "1" ]] || fail "expected answering session not to start with a duplicate ID"
  record="$(<"$(only_session_dir)/session.json")"
  [[ "$(jq -r '.status' <<<"$record")" == "failed" ]] || fail "expected failed record"

  teardown_grill_repo
}

test_adapter_argv_carries_role_access_policy() {
  local grilling_argv answering_argv settings

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work

  grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude >/dev/null

  grilling_argv="$(claude_argv 0001)"
  answering_argv="$(claude_argv 0002)"
  [[ "$grilling_argv" != *"--dangerously-skip-permissions"* ]] || fail "grilling argv must not skip permissions"
  [[ "$answering_argv" != *"--dangerously-skip-permissions"* ]] || fail "answering argv must not skip permissions"

  [[ "$(claude_flag_value 0001 --permission-mode)" == "acceptEdits" ]] || fail "expected grilling acceptEdits mode"
  [[ "$(<"$FAKE_CLAUDE_DIR/calls/0001/pwd")" == "$(cd "$GRILL_REPO" && pwd -P)" ]] || fail "expected grilling cwd at repo root"
  settings="$(claude_flag_value 0001 --settings)"
  [[ "$(jq -r '.sandbox.enabled' <<<"$settings")" == "true" ]] || fail "expected grilling sandbox"
  [[ "$(jq -r '.sandbox.allowUnsandboxedCommands' <<<"$settings")" == "false" ]] || fail "expected no grilling sandbox escape"
  jq -e '.permissions.deny | index("Bash(git push:*)")' <<<"$settings" >/dev/null || fail "expected grilling git push denied"
  jq -e '.permissions.deny | index("Bash(gh issue create:*)")' <<<"$settings" >/dev/null || fail "expected grilling gh writes denied"
  jq -e '.permissions.allow | index("WebFetch")' <<<"$settings" >/dev/null || fail "expected grilling web reads"
  jq -e '.permissions.allow | index("Bash(gh issue view:*)")' <<<"$settings" >/dev/null || fail "expected grilling gh reads"
  ! jq -e '.permissions.deny | index("Edit(//**)")' <<<"$settings" >/dev/null || fail "grilling must keep repo writes"

  [[ "$(claude_flag_value 0002 --permission-mode)" == "default" ]] || fail "expected answering default mode"
  assert_contains "$answering_argv" '"--disallowedTools"'
  jq -e 'index("Edit") and index("Write") and index("NotebookEdit")' <<<"$answering_argv" >/dev/null \
    || fail "expected answering write tools disallowed"
  settings="$(claude_flag_value 0002 --settings)"
  [[ "$(jq -r '.sandbox.enabled' <<<"$settings")" == "true" ]] || fail "expected answering sandbox"
  jq -e '.permissions.deny | index("Edit(//**)")' <<<"$settings" >/dev/null || fail "expected answering writes denied everywhere"
  jq -e '.permissions.deny | index("Bash(gh issue create:*)")' <<<"$settings" >/dev/null || fail "expected answering gh writes denied"
  jq -e '.permissions.allow | index("Bash(gh issue view:*)")' <<<"$settings" >/dev/null || fail "expected answering gh reads"

  teardown_grill_repo
}

test_capability_failure_refuses_before_native_sessions() {
  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  export FAKE_CLAUDE_HELP_OMIT="--settings"

  expect_start_failure "cannot express the required access policy" \
    --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude

  unset FAKE_CLAUDE_HELP_OMIT
  teardown_grill_repo
}

test_start_refuses_dirty_worktree() {
  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  printf 'uncommitted\n' > "$GRILL_REPO/notes.txt"

  expect_start_failure "working tree is dirty" \
    --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude

  teardown_grill_repo
}

test_start_ignores_ralph_session_storage_in_dirty_check() {
  local session_id

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  mkdir -p "$GRILL_SESSIONS/older-session" "$GRILL_REPO/ralph-v2/archive/grilling"
  printf 'old\n' > "$GRILL_SESSIONS/older-session/session.json"
  printf 'old\n' > "$GRILL_REPO/ralph-v2/archive/grilling/record.json"

  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude | tail -n 1)"

  [[ -f "$GRILL_SESSIONS/$session_id/session.json" ]] || fail "expected start despite Ralph session storage"

  teardown_grill_repo
}

test_start_on_default_branch_creates_issue_planning_branch() {
  local session_id record

  setup_grill_repo

  session_id="$(grill start --issue 77 --grilling-agent claude --answering-agent claude | tail -n 1)"

  [[ "$(git -C "$GRILL_REPO" branch --show-current)" == "grill/issue-77-add-dark-mode" ]] \
    || fail "expected planning branch checkout"
  record="$(<"$GRILL_SESSIONS/$session_id/session.json")"
  [[ "$(jq -r '.repo.startBranch' <<<"$record")" == "main" ]] || fail "expected start branch main"
  [[ "$(jq -r '.repo.branch' <<<"$record")" == "grill/issue-77-add-dark-mode" ]] || fail "expected planning branch in record"
  [[ "$(jq -r '.input.kind' <<<"$record")" == "issue" ]] || fail "expected issue input kind"
  [[ "$(jq -r '.input.issue' <<<"$record")" == "77" ]] || fail "expected issue number"
  assert_contains "$(<"$GRILL_SESSIONS/$session_id/requirement.md")" "Readers want a dark theme."
  assert_contains "$(<"$FAKE_GH_LOG")" '["issue","view","77"'

  teardown_grill_repo
}

test_start_on_default_branch_creates_requirement_planning_branch() {
  setup_grill_repo

  grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude >/dev/null

  [[ "$(git -C "$GRILL_REPO" branch --show-current)" == "grill/offline-export" ]] \
    || fail "expected grill/<slug> planning branch"

  teardown_grill_repo
}

test_start_refuses_existing_planning_branch() {
  setup_grill_repo
  git -C "$GRILL_REPO" branch grill/offline-export

  expect_start_failure "branch 'grill/offline-export' already exists" \
    --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude
  [[ "$(git -C "$GRILL_REPO" branch --show-current)" == "main" ]] || fail "expected to stay on main"

  teardown_grill_repo
}

test_start_relays_frontier_rounds_to_the_confirmation_gate() {
  local status session_id session_dir record confirmation

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run

  set +e
  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude | tail -n 1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected start to exit 0 at the confirmation gate"
  session_dir="$GRILL_SESSIONS/$session_id"
  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.status' <<<"$record")" == "blocked" ]] || fail "expected status blocked"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected awaiting_confirmation"
  [[ "$(jq -r '.round' <<<"$record")" == "3" ]] || fail "expected three Frontier rounds"
  [[ "$(claude_call_count)" == "10" ]] || fail "expected ten exchanges"
  [[ "$(jq -c '[.exchanges[] | [.id, .kind, .role, .status]]' <<<"$record")" == "$(jq -n -c '[
      ["ex-0001","session_start","grilling","completed"],
      ["ex-0002","session_start","answering","completed"],
      ["ex-0003","frontier","grilling","completed"],
      ["ex-0004","answers","answering","completed"],
      ["ex-0005","frontier","grilling","completed"],
      ["ex-0006","answers","answering","completed"],
      ["ex-0007","frontier","grilling","completed"],
      ["ex-0008","summary_draft","grilling","completed"],
      ["ex-0009","summary_review","answering","completed"],
      ["ex-0010","summary_final","grilling","completed"]]')" ]] \
    || fail "expected sequential completed exchanges, got: $(jq -c '.exchanges' <<<"$record")"
  [[ "$(jq -r '.exchanges[4].logPath' <<<"$record")" == "logs/ex-0005-grilling.jsonl" ]] || fail "expected exchange log path"

  confirmation="$(<"$session_dir/confirmation.md")"
  [[ "$(file_mode "$session_dir/confirmation.md")" == "600" ]] || fail "expected confirmation.md mode 600"
  assert_contains "$confirmation" "- Storage: Postgres (reopened)."
  assert_contains "$confirmation" "Export reports offline with Postgres storage"
  assert_contains "$confirmation" "Readers export CSV reports stored in Postgres."
  assert_contains "$confirmation" "CONTEXT.md | 3 +++"
  assert_contains "$confirmation" "+**Offline Export**: a report saved for offline reading."
  assert_contains "$confirmation" "## Decision"
  assert_contains "$confirmation" "approve"
  assert_contains "$confirmation" "## Answers"
  [[ "$confirmation" != *"Draft summary: SQLite storage."* ]] || fail "expected the final summary, not the draft"

  teardown_grill_repo
}

test_every_exchange_after_start_resumes_the_stored_native_session() {
  local call flag expected argv

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run

  grill start --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude >/dev/null

  for call in 0003 0004 0005 0006 0007 0008 0009 0010; do
    case "$call" in
      0004|0006|0009) expected="$UUID_ANSWERING" ;;
      *) expected="$UUID_GRILLING" ;;
    esac
    argv="$(claude_argv "$call")"
    [[ "$(claude_flag_value "$call" --resume)" == "$expected" ]] || fail "expected call $call to resume $expected"
    [[ "$argv" != *'"--session-id"'* ]] || fail "expected call $call not to start a new session"
    assert_contains "$argv" '"--json-schema"'
    assert_contains "$(claude_flag_value "$call" -p)" "[ralph-exchange:ex-$call]"
  done
  for call in 0001 0002 0003 0004 0005 0006 0007 0008 0009 0010; do
    argv="$(claude_argv "$call")"
    for flag in --continue --last --fork-session -c; do
      ! jq -e --arg f "$flag" 'index($f)' <<<"$argv" >/dev/null || fail "call $call must not pass $flag"
    done
  done
  [[ "$(claude_flag_value 0005 --model)" == "opus" ]] || fail "expected the frozen model on resumed calls"
  [[ "$(claude_flag_value 0004 --permission-mode)" == "default" ]] || fail "expected answering policy on resumed calls"

  teardown_grill_repo
}

test_answers_merge_into_decisions_and_reopens_route_the_contradiction() {
  local session_id record answering_prompt grilling_prompt

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run

  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude | tail -n 1)"

  record="$(<"$GRILL_SESSIONS/$session_id/session.json")"
  [[ "$(jq -c '.decisions' <<<"$record")" == "$(jq -n -c '{
      "storage-backend": {exchangeId: "ex-0006", decision: "postgres", reopenedBy: "ex-0005"},
      "export-format": {exchangeId: "ex-0004", decision: "csv", reopenedBy: null},
      "sync-mode": {exchangeId: "ex-0006", decision: "manual", reopenedBy: null}}')" ]] \
    || fail "expected merged decisions, got: $(jq -c '.decisions' <<<"$record")"

  answering_prompt="$(claude_flag_value 0004 -p)"
  assert_contains "$answering_prompt" "Where are exports stored?"
  assert_contains "$answering_prompt" "export-format"
  answering_prompt="$(claude_flag_value 0006 -p)"
  assert_contains "$answering_prompt" "sync-mode"
  assert_contains "$answering_prompt" "README says exports are shared across devices."
  grilling_prompt="$(claude_flag_value 0005 -p)"
  assert_contains "$grilling_prompt" "Users open exports in spreadsheets."
  grilling_prompt="$(claude_flag_value 0009 -p)"
  assert_contains "$grilling_prompt" "Draft summary: SQLite storage."
  grilling_prompt="$(claude_flag_value 0010 -p)"
  assert_contains "$grilling_prompt" "Say Postgres."

  teardown_grill_repo
}

# Asserts the session blocked as invalid_message on ex-0004 after exactly one
# re-emit request in the same Answering session.
assert_invalid_message_block_after_one_reemit() {
  local record prompt

  record="$(<"$(only_session_dir)/session.json")"
  [[ "$(jq -r '.status' <<<"$record")" == "blocked" ]] || fail "expected status blocked"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "invalid_message" ]] || fail "expected invalid_message"
  [[ "$(jq -c '.decisions' <<<"$record")" == "{}" ]] || fail "expected no decisions from an invalid message"
  [[ "$(claude_call_count)" == "5" ]] || fail "expected the original send plus exactly one re-emit request"
  [[ "$(claude_flag_value 0005 --resume)" == "$UUID_ANSWERING" ]] || fail "expected the re-emit in the same session"
  prompt="$(claude_flag_value 0005 -p)"
  assert_contains "$prompt" "[ralph-exchange:ex-0004]"
  assert_contains "$prompt" "re-emit"
  [[ "$(jq -c '[.exchanges[] | select(.id == "ex-0004") | .reemitRequested]' <<<"$record")" == "[true]" ]] \
    || fail "expected one ex-0004 exchange with reemitRequested"
  [[ -f "$(only_session_dir)/human-input-ex-0004.md" ]] || fail "expected a human-input file for the block"
}

test_partial_answer_set_is_invalid() {
  local status

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run
  exchange_fixture ex-0004 '{"exchangeId":"ex-0004","answers":[
      {"questionId":"storage-backend","choiceId":"sqlite","rationale":"The app has no server.","evidence":["README.md"]}]}'

  set +e
  grill start --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude >/dev/null 2>&1
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected a blocked session to exit 0"
  assert_invalid_message_block_after_one_reemit

  teardown_grill_repo
}

test_answer_without_evidence_is_invalid() {
  local status

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run
  exchange_fixture ex-0004 '{"exchangeId":"ex-0004","answers":[
      {"questionId":"storage-backend","choiceId":"sqlite","rationale":"The app has no server.","evidence":["README.md"]},
      {"questionId":"export-format","choiceId":"csv","rationale":"Spreadsheets.","evidence":[]}]}'

  set +e
  grill start --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude >/dev/null 2>&1
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected a blocked session to exit 0"
  assert_invalid_message_block_after_one_reemit

  teardown_grill_repo
}

test_invalid_message_followed_by_a_valid_reemit_continues() {
  local session_id record

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run
  cp "$FAKE_CLAUDE_DIR/exchanges/ex-0004.json" "$FAKE_CLAUDE_DIR/exchanges/ex-0004.2.json"
  exchange_fixture ex-0004 'Here are my answers: storage-backend is sqlite.'

  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude 2>/dev/null | tail -n 1)"

  record="$(<"$GRILL_SESSIONS/$session_id/session.json")"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected the session to reach the gate"
  [[ "$(claude_call_count)" == "11" ]] || fail "expected ten exchanges plus one re-emit request"
  [[ "$(claude_flag_value 0005 --resume)" == "$UUID_ANSWERING" ]] || fail "expected the re-emit in the same session"
  assert_contains "$(claude_flag_value 0005 -p)" "[ralph-exchange:ex-0004]"
  [[ "$(jq -c '[.exchanges[] | select(.id == "ex-0004") | [.status, .reemitRequested]]' <<<"$record")" \
    == '[["completed",true]]' ]] || fail "expected ex-0004 completed after one re-emit"
  [[ "$(jq -r '.exchanges | length' <<<"$record")" == "10" ]] || fail "expected the re-emit to reuse the exchange ID"
  [[ "$(jq -r '.decisions["storage-backend"].decision' <<<"$record")" == "postgres" ]] || fail "expected the run to continue"

  teardown_grill_repo
}

test_confirmation_flags_out_of_scope_changes_and_head_drift() {
  local session_id record start_head confirmation

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  start_head="$(git -C "$GRILL_REPO" rev-parse HEAD)"
  queue_two_round_run
  exchange_effect ex-0005 'mkdir -p docs/adr src
printf "# Use Postgres\n" > docs/adr/0001-use-postgres.md
printf "stray\n" > src/app.txt
printf "committed\n" > notes.txt
git add notes.txt && git commit -q -m "Sneaky commit"'

  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude | tail -n 1)"

  record="$(<"$GRILL_SESSIONS/$session_id/session.json")"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected awaiting_confirmation"
  confirmation="$(<"$GRILL_SESSIONS/$session_id/confirmation.md")"
  assert_contains "$confirmation" "Changed outside CONTEXT.md and docs/adr/: \`src/app.txt\`"
  [[ "$confirmation" != *"outside CONTEXT.md and docs/adr/: \`docs/adr"* ]] || fail "ADR files are in scope"
  [[ "$confirmation" != *"grilling-sessions"* ]] || fail "Ralph session storage must not be flagged"
  assert_contains "$confirmation" "HEAD changed since start: $start_head -> $(git -C "$GRILL_REPO" rev-parse HEAD)"
  assert_contains "$confirmation" "+# Use Postgres"

  teardown_grill_repo
}

test_confirmation_without_drift_has_no_flags() {
  local session_id confirmation

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run

  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude | tail -n 1)"

  confirmation="$(<"$GRILL_SESSIONS/$session_id/confirmation.md")"
  assert_contains "$confirmation" "- No flags."
  [[ "$confirmation" != *"Changed outside"* ]] || fail "expected no out-of-scope flag"
  [[ "$confirmation" != *"HEAD changed"* ]] || fail "expected no HEAD drift flag"

  teardown_grill_repo
}

test_provider_logs_are_owner_only_per_exchange_and_role() {
  local session_dir log

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run

  grill start --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude >/dev/null

  session_dir="$(only_session_dir)"
  for log in ex-0003-grilling ex-0004-answering ex-0005-grilling ex-0006-answering ex-0007-grilling \
    ex-0008-grilling ex-0009-answering ex-0010-grilling; do
    [[ -f "$session_dir/logs/$log.jsonl" ]] || fail "expected provider log $log"
    [[ "$(file_mode "$session_dir/logs/$log.jsonl")" == "600" ]] || fail "expected $log mode 600"
    assert_contains "$(<"$session_dir/logs/$log.jsonl")" '"type":"result"'
  done

  teardown_grill_repo
}

# Rewinds a gated record to the state right after both native sessions start.
rewind_to_after_start() {
  local session_dir="$1"
  local rewound

  rewound="$(jq '.status = "grilling" | .blockReason = null | .round = 0 | .decisions = {} | .exchanges |= .[:2]' \
    "$session_dir/session.json")"
  printf '%s\n' "$rewound" > "$session_dir/session.json"
  rm -f "$session_dir/confirmation.md"
}

test_resume_continues_a_grilling_session_to_the_gate() {
  local session_id session_dir record

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude | tail -n 1)"
  session_dir="$GRILL_SESSIONS/$session_id"
  rewind_to_after_start "$session_dir"
  rm -rf "$FAKE_CLAUDE_DIR/calls"

  grill resume --id "$session_id" >/dev/null

  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected resume to reach the gate"
  [[ "$(claude_call_count)" == "4" ]] || fail "expected four resumed exchanges"
  [[ "$(claude_flag_value 0001 --resume)" == "$UUID_GRILLING" ]] || fail "expected resume of the grilling session"
  assert_contains "$(claude_flag_value 0001 -p)" "[ralph-exchange:ex-0003]"
  [[ -f "$session_dir/confirmation.md" ]] || fail "expected confirmation.md after resume"

  teardown_grill_repo
}

test_resume_rejects_configuration_flags() {
  local session_id flag output status before

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude | tail -n 1)"
  rewind_to_after_start "$GRILL_SESSIONS/$session_id"
  before="$(claude_call_count)"

  for flag in --grilling-agent --answering-agent --grilling-model --grilling-effort \
    --answering-model --answering-effort; do
    set +e
    output="$(grill resume --id "$session_id" "$flag" claude 2>&1)"
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail "expected resume $flag to fail"
    assert_contains "$output" "configuration is frozen"
  done
  [[ "$(claude_call_count)" == "$before" ]] || fail "expected no Agent contact on rejected resume"

  teardown_grill_repo
}

# Writes a hand-built Grilling Session Record with the given status into a
# session directory, with a provider log beside it.
write_fixture_session() {
  local session_dir="$1"
  local session_id="$2"
  local status="$3"

  mkdir -p "$session_dir/logs"
  jq -n --arg id "$session_id" --arg status "$status" '{
    id: $id, status: $status, blockReason: null, round: 2,
    agents: {grilling: {provider: "claude", model: "opus", reasoningEffort: "medium", nativeSessionId: "g"},
             answering: {provider: "claude", model: "sonnet", reasoningEffort: "high", nativeSessionId: "a"}},
    decisions: {}, exchanges: []}' > "$session_dir/session.json"
  printf '%s\n' "$REQUIREMENT_TEXT" > "$session_dir/requirement.md"
  printf '{"type":"result","result":"done"}\n' > "$session_dir/logs/ex-0001-grilling.jsonl"
}

expect_grill_failure() {
  local expected="$1"
  shift
  local output status

  set +e
  output="$(grill "$@" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected grill $* to fail"
  assert_contains "$output" "$expected"
}

NEEDS_HUMAN_EX_0004='{"exchangeId":"ex-0004","needsHuman":{"questionIds":["storage-backend"],"reason":"Nothing says whether exports are shared across devices."}}'

test_needs_human_blocks_with_a_human_input_file() {
  local status session_id session_dir record input output

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run
  exchange_fixture ex-0004 "$NEEDS_HUMAN_EX_0004"

  set +e
  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude 2>/dev/null | tail -n 1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected start to exit 0 on a needsHuman block"
  session_dir="$GRILL_SESSIONS/$session_id"
  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.status' <<<"$record")" == "blocked" ]] || fail "expected status blocked"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "needs_human" ]] || fail "expected needs_human"
  [[ "$(jq -r '.agents.grilling.nativeSessionId' <<<"$record")" == "$UUID_GRILLING" ]] || fail "expected grilling native ID kept"
  [[ "$(jq -r '.agents.answering.nativeSessionId' <<<"$record")" == "$UUID_ANSWERING" ]] || fail "expected answering native ID kept"
  [[ "$(jq -c '.decisions' <<<"$record")" == "{}" ]] || fail "expected no decisions from a needsHuman reply"
  [[ "$(claude_call_count)" == "4" ]] || fail "expected no exchange after needsHuman"

  input="$session_dir/human-input-ex-0004.md"
  [[ -f "$input" ]] || fail "expected human-input file $input"
  [[ "$(file_mode "$input")" == "600" ]] || fail "expected human-input file mode 600"
  assert_contains "$(<"$input")" "storage-backend"
  assert_contains "$(<"$input")" "Where are exports stored?"
  assert_contains "$(<"$input")" "Nothing says whether exports are shared across devices."
  assert_contains "$(<"$input")" "## Answers"

  output="$(grill status --id "$session_id")"
  assert_contains "$output" "State: blocked"
  assert_contains "$output" "Block reason: needs_human"

  teardown_grill_repo
}

# Starts a session that blocks on needsHuman at ex-0004 and prints its ID.
start_needs_human_session() {
  queue_two_round_run
  exchange_fixture ex-0004 "$NEEDS_HUMAN_EX_0004"
  grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude 2>/dev/null | tail -n 1
}

test_resume_with_empty_answers_prints_the_input_file_without_agent_calls() {
  local session_id session_dir output status

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(start_needs_human_session)"
  session_dir="$(cd "$GRILL_SESSIONS/$session_id" && pwd -P)"
  rm -rf "$FAKE_CLAUDE_DIR/calls"

  set +e
  output="$(grill resume --id "$session_id" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected resume with empty answers to exit 0, got $status: $output"
  assert_contains "$output" "$session_dir/human-input-ex-0004.md"
  [[ "$(claude_call_count)" == "0" ]] || fail "expected no Agent calls with empty answers"
  [[ "$(jq -r '.blockReason' "$session_dir/session.json")" == "needs_human" ]] || fail "expected the block to stay"

  teardown_grill_repo
}

# Scripts the closing exchanges from the given first exchange number: an
# empty Frontier, then the summary draft, review and final.
queue_closing_from() {
  local n="$1"

  exchange_fixture "ex-$(printf '%04d' "$n")" \
    "{\"exchangeId\":\"ex-$(printf '%04d' "$n")\",\"round\":$2,\"questions\":[],\"reopens\":[]}"
  exchange_fixture "ex-$(printf '%04d' $((n + 1)))" "$(summary_fixture "ex-$(printf '%04d' $((n + 1)))" "- Storage: Postgres.")"
  exchange_fixture "ex-$(printf '%04d' $((n + 2)))" \
    "{\"exchangeId\":\"ex-$(printf '%04d' $((n + 2)))\",\"faithful\":true,\"discrepancies\":[]}"
  exchange_fixture "ex-$(printf '%04d' $((n + 3)))" "$(summary_fixture "ex-$(printf '%04d' $((n + 3)))" "- Storage: Postgres.")"
}

test_resume_routes_human_input_to_answering_then_grilling() {
  local session_id session_dir record prompt

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(start_needs_human_session)"
  session_dir="$GRILL_SESSIONS/$session_id"
  printf 'Exports are shared across devices, so use Postgres.\n' >> "$session_dir/human-input-ex-0004.md"
  exchange_fixture ex-0005 '{"exchangeId":"ex-0005","answers":[
      {"questionId":"storage-backend","choiceId":"postgres","rationale":"The human says exports are shared.","evidence":["human-input-ex-0004.md"]},
      {"questionId":"export-format","choiceId":"csv","rationale":"Users open exports in spreadsheets.","evidence":["README.md"]}]}'
  queue_closing_from 6 2
  rm -rf "$FAKE_CLAUDE_DIR/calls"

  grill resume --id "$session_id" >/dev/null 2>&1

  [[ "$(claude_flag_value 0001 --resume)" == "$UUID_ANSWERING" ]] || fail "expected human input sent to the Answering session first"
  prompt="$(claude_flag_value 0001 -p)"
  assert_contains "$prompt" "[ralph-exchange:ex-0005]"
  assert_contains "$prompt" "Exports are shared across devices, so use Postgres."
  assert_contains "$prompt" "Where are exports stored?"
  [[ "$(claude_flag_value 0002 --resume)" == "$UUID_GRILLING" ]] || fail "expected the updated decision relayed to the Grilling session second"
  prompt="$(claude_flag_value 0002 -p)"
  assert_contains "$prompt" "[ralph-exchange:ex-0006]"
  assert_contains "$prompt" "The human says exports are shared."
  [[ "$(claude_call_count)" == "5" ]] || fail "expected human input, relay and three closing exchanges"

  record="$(<"$session_dir/session.json")"
  [[ "$(jq -c '[.exchanges[4:6][] | [.id, .kind, .role, .status]]' <<<"$record")" \
    == '[["ex-0005","human_input","answering","completed"],["ex-0006","correction_relay","grilling","completed"]]' ]] \
    || fail "expected human_input then correction_relay exchanges, got: $(jq -c '.exchanges' <<<"$record")"
  [[ "$(jq -c '.decisions["storage-backend"]' <<<"$record")" \
    == '{"exchangeId":"ex-0005","decision":"postgres","reopenedBy":null}' ]] || fail "expected the human-informed decision"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected grilling to continue to the gate"

  teardown_grill_repo
}

test_identical_frontier_without_reopens_blocks_as_no_progress() {
  local status session_id session_dir record

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run
  jq -c '.exchangeId = "ex-0005" | .round = 2' "$FAKE_CLAUDE_DIR/exchanges/ex-0003.json" > "$GRILL_TMP/repeat.json"
  exchange_fixture ex-0005 "$(<"$GRILL_TMP/repeat.json")"

  set +e
  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude 2>/dev/null | tail -n 1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected start to exit 0 on a no_progress block"
  session_dir="$GRILL_SESSIONS/$session_id"
  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.status' <<<"$record")" == "blocked" ]] || fail "expected status blocked"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "no_progress" ]] || fail "expected no_progress, got $(jq -r '.blockReason' <<<"$record")"
  [[ "$(claude_call_count)" == "5" ]] || fail "expected no exchange after the repeated Frontier"
  assert_contains "$(<"$session_dir/human-input-ex-0005.md")" "storage-backend"
  assert_contains "$(<"$session_dir/human-input-ex-0005.md")" "## Answers"

  teardown_grill_repo
}

# Writes a decision line into confirmation.md's ## Decision section.
write_confirmation_decision() {
  awk -v decision="$2" '/^## Answers/ { print decision; print "" } { print }' "$1" > "$1.new"
  mv "$1.new" "$1"
}

test_correct_at_the_gate_routes_answering_then_grilling_back_to_the_gate() {
  local session_id session_dir record output prompt confirmation

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude 2>/dev/null | tail -n 1)"
  session_dir="$(cd "$GRILL_SESSIONS/$session_id" && pwd -P)"
  write_confirmation_decision "$session_dir/confirmation.md" correct
  rm -rf "$FAKE_CLAUDE_DIR/calls"

  output="$(grill resume --id "$session_id" 2>&1)"
  assert_contains "$output" "$session_dir/confirmation.md"
  [[ "$(claude_call_count)" == "0" ]] || fail "expected no Agent calls for a correction without text"

  printf 'Exports must also be available as JSON.\n' >> "$session_dir/confirmation.md"
  exchange_fixture ex-0007 '{"exchangeId":"ex-0007","answers":[
      {"questionId":"export-format","choiceId":"json","rationale":"The human asked for JSON exports.","evidence":["confirmation.md"]}]}'
  queue_closing_from 8 2

  grill resume --id "$session_id" >/dev/null 2>&1

  [[ "$(claude_flag_value 0001 --resume)" == "$UUID_ANSWERING" ]] || fail "expected the correction sent to the Answering session first"
  prompt="$(claude_flag_value 0001 -p)"
  assert_contains "$prompt" "[ralph-exchange:ex-0007]"
  assert_contains "$prompt" "Exports must also be available as JSON."
  [[ "$(claude_flag_value 0002 --resume)" == "$UUID_GRILLING" ]] || fail "expected the updated decision relayed to the Grilling session second"
  prompt="$(claude_flag_value 0002 -p)"
  assert_contains "$prompt" "[ralph-exchange:ex-0008]"
  assert_contains "$prompt" "The human asked for JSON exports."
  [[ "$(claude_call_count)" == "5" ]] || fail "expected correction, relay and a new closing pass"

  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.status' <<<"$record")" == "blocked" ]] || fail "expected status blocked"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected the confirmation gate again"
  [[ "$(jq -c '[.exchanges[6:][] | [.id, .kind, .role]]' <<<"$record")" == "$(jq -n -c '[
      ["ex-0007","human_input","answering"],
      ["ex-0008","correction_relay","grilling"],
      ["ex-0009","summary_draft","grilling"],
      ["ex-0010","summary_review","answering"],
      ["ex-0011","summary_final","grilling"]]')" ]] \
    || fail "expected correction exchanges then a new closing pass, got: $(jq -c '.exchanges' <<<"$record")"
  [[ "$(jq -r '.decisions["export-format"].decision' <<<"$record")" == "json" ]] || fail "expected the corrected decision"
  confirmation="$(<"$session_dir/confirmation.md")"
  assert_contains "$confirmation" "- Storage: Postgres."
  [[ "$confirmation" != *"Exports must also be available as JSON."* ]] || fail "expected a fresh confirmation file"

  teardown_grill_repo
}

test_gate_text_without_a_correct_decision_contacts_no_agent() {
  local session_id session_dir output

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude 2>/dev/null | tail -n 1)"
  session_dir="$(cd "$GRILL_SESSIONS/$session_id" && pwd -P)"
  printf 'Exports must also be available as JSON.\n' >> "$session_dir/confirmation.md"
  rm -rf "$FAKE_CLAUDE_DIR/calls"

  output="$(grill resume --id "$session_id" 2>&1)"

  assert_contains "$output" "## Decision"
  assert_contains "$output" "$session_dir/confirmation.md"
  [[ "$(claude_call_count)" == "0" ]] || fail "expected no Agent calls without a decision"
  [[ "$(jq -r '.blockReason' "$session_dir/session.json")" == "awaiting_confirmation" ]] || fail "expected the gate to stay"

  teardown_grill_repo
}

test_status_logs_and_cleanup_require_a_known_id() {
  local subcommand

  setup_grill_repo

  for subcommand in status logs cleanup; do
    expect_grill_failure "Usage:" "$subcommand"
    expect_grill_failure "no Grilling Session Record for 20260101-000000-abcd" "$subcommand" --id 20260101-000000-abcd
  done

  teardown_grill_repo
}

test_status_shows_state_agents_and_next_action_without_raw_content() {
  local session_id session_dir output log line

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work

  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude \
    --answering-model sonnet --answering-effort high 2>/dev/null | tail -n 1)"
  session_dir="$(cd "$GRILL_SESSIONS/$session_id" && pwd -P)"

  output="$(grill status --id "$session_id")"
  assert_contains "$output" "State: blocked"
  assert_contains "$output" "Block reason: awaiting_confirmation"
  assert_contains "$output" "Round: 1"
  assert_contains "$output" "Grilling Agent: claude (model opus, effort medium)"
  assert_contains "$output" "Answering Agent: claude (model sonnet, effort high)"
  assert_contains "$output" "Next action: edit $session_dir/confirmation.md, then run: ralph.sh grill resume --id $session_id"

  for log in "$session_dir"/logs/*.jsonl; do
    while IFS= read -r line; do
      [[ -z "$line" || "$output" != *"$line"* ]] || fail "expected status to exclude raw log line: $line"
    done < "$log"
  done
  [[ "$output" != *"Users need to export reports offline."* ]] || fail "expected status to exclude the requirement"
  [[ "$output" != *"Offline Export"* ]] || fail "expected status to exclude the requirement title"

  jq '.status = "blocked" | .blockReason = "needs_human"' "$session_dir/session.json" > "$GRILL_TMP/needs-human.json"
  cp "$GRILL_TMP/needs-human.json" "$session_dir/session.json"
  output="$(grill status --id "$session_id")"
  assert_contains "$output" "Block reason: needs_human"
  assert_contains "$output" "Next action: write your input under ## Answers in the human-input file in $session_dir, then run: ralph.sh grill resume --id $session_id"

  teardown_grill_repo
}

test_logs_summarize_activity_per_role_and_exchange() {
  local session_id session_dir output

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work

  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude \
    2>/dev/null | tail -n 1)"
  session_dir="$GRILL_SESSIONS/$session_id"
  cat > "$session_dir/logs/ex-0003-grilling.jsonl" <<'LOG'
{"type":"assistant","message":{"content":[{"type":"text","text":"Reading CONTEXT.md before the first Frontier."},{"type":"tool_use","name":"Read","input":{"file_path":"CONTEXT.md"}}]}}
LOG
  cat > "$session_dir/logs/ex-0005-answering.jsonl" <<'LOG'
{"type":"assistant","message":{"content":[{"type":"text","text":"Checked the draft against the decisions."}]}}
LOG

  output="$(grill logs --id "$session_id")"
  assert_contains "$output" "ex-0003 frontier (grilling Agent, claude)"
  assert_contains "$output" "[text] Reading CONTEXT.md before the first Frontier."
  assert_contains "$output" "[tool] Read: file_path=CONTEXT.md"
  assert_contains "$output" "ex-0005 summary_review (answering Agent, claude)"
  assert_contains "$output" "[text] Checked the draft against the decisions."
  [[ "$output" != *'"type":"assistant"'* ]] || fail "expected logs to exclude raw provider events"

  teardown_grill_repo
}

test_cleanup_deletes_terminal_sessions_and_refuses_active_ones() {
  local archive_dir status session_id n=0

  setup_grill_repo
  archive_dir="$GRILL_REPO/ralph-v2/archive/grilling"

  write_fixture_session "$GRILL_SESSIONS/20260924-100000-0001" 20260924-100000-0001 failed
  write_fixture_session "$GRILL_SESSIONS/20260924-100000-0002" 20260924-100000-0002 context_lost
  write_fixture_session "$archive_dir/2026-09-24-20260924-100000-0003" 20260924-100000-0003 completed
  write_fixture_session "$archive_dir/2026-09-24-20260924-100000-0004" 20260924-100000-0004 rejected

  grill cleanup --id 20260924-100000-0001 >/dev/null
  [[ ! -e "$GRILL_SESSIONS/20260924-100000-0001" ]] || fail "expected failed session deleted"
  grill cleanup --id 20260924-100000-0002 >/dev/null
  [[ ! -e "$GRILL_SESSIONS/20260924-100000-0002" ]] || fail "expected context_lost session deleted"
  grill cleanup --id 20260924-100000-0003 >/dev/null
  [[ ! -e "$archive_dir/2026-09-24-20260924-100000-0003" ]] || fail "expected archived completed session deleted"
  grill cleanup --id 20260924-100000-0004 >/dev/null
  [[ ! -e "$archive_dir/2026-09-24-20260924-100000-0004" ]] || fail "expected archived rejected session deleted"

  for status in starting grilling blocked applying; do
    n=$((n + 1))
    session_id="20260924-110000-000$n"
    write_fixture_session "$GRILL_SESSIONS/$session_id" "$session_id" "$status"
    expect_grill_failure "session $session_id is $status" cleanup --id "$session_id"
    [[ -f "$GRILL_SESSIONS/$session_id/session.json" ]] || fail "expected $status session record intact"
    [[ -f "$GRILL_SESSIONS/$session_id/logs/ex-0001-grilling.jsonl" ]] || fail "expected $status session logs intact"
  done

  teardown_grill_repo
}

test_grilling_sessions_are_gitignored() {
  grep -qx 'grilling-sessions/' "$ROOT_DIR/.gitignore" || fail "expected grilling-sessions/ in .gitignore"
}

# Starts a claude/claude session to the gate and rewinds it to right after
# both native sessions started, with no Agent calls recorded. Prints its ID.
start_then_rewind() {
  local session_id

  session_id="$(grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude | tail -n 1)"
  rewind_to_after_start "$GRILL_SESSIONS/$session_id"
  rm -rf "$FAKE_CLAUDE_DIR/calls"
  printf '%s\n' "$session_id"
}

# Runs grill in its own process group, as a terminal job would, so the fake
# claude can interrupt the whole group like Ctrl-C. Prints the exit status.
grill_as_job() {
  local pid status=0

  set -m
  grill "$@" > "$GRILL_TMP/job.out" 2>&1 &
  pid=$!
  set +m
  wait "$pid" || status=$?
  printf '%s\n' "$status"
}

exchange_status() {
  jq -r --arg id "$2" '[.exchanges[] | select(.id == $id) | .status] | join(",")' "$1/session.json"
}

test_resume_fails_on_a_live_lock_and_reclaims_a_dead_one() {
  local session_id session_dir holder output status

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(start_then_rewind)"
  session_dir="$GRILL_SESSIONS/$session_id"
  [[ ! -e "$session_dir/lock" ]] || fail "expected start to release its lock"

  sleep 30 &
  holder=$!
  mkdir "$session_dir/lock"
  printf '%s\n' "$holder" > "$session_dir/lock/pid"

  set +e
  output="$(grill resume --id "$session_id" 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "expected resume to fail on a live lock"
  assert_contains "$output" "is locked by another coordinator (PID $holder)"
  [[ "$(claude_call_count)" == "0" ]] || fail "expected no Agent calls while locked"
  [[ "$(<"$session_dir/lock/pid")" == "$holder" ]] || fail "expected the live lock untouched"

  kill "$holder"
  wait "$holder" 2>/dev/null || true
  grill resume --id "$session_id" >/dev/null

  [[ "$(jq -r '.blockReason' "$session_dir/session.json")" == "awaiting_confirmation" ]] \
    || fail "expected resume to proceed after reclaiming a dead lock"
  [[ ! -e "$session_dir/lock" ]] || fail "expected resume to release the reclaimed lock"

  teardown_grill_repo
}

test_sessions_with_different_ids_hold_their_locks_at_once() {
  local first second holder

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  printf '%s\n' "$UUID_GRILLING" "$UUID_ANSWERING" \
    33333333-3333-4333-8333-333333333333 44444444-4444-4444-8444-444444444444 > "$FAKE_UUID_QUEUE"
  first="$(start_then_rewind)"
  second="$(start_then_rewind)"
  [[ "$first" != "$second" ]] || fail "expected two sessions"

  sleep 30 &
  holder=$!
  mkdir "$GRILL_SESSIONS/$first/lock"
  printf '%s\n' "$holder" > "$GRILL_SESSIONS/$first/lock/pid"
  exchange_effect ex-0003 "[[ -d '$GRILL_SESSIONS/$first/lock' && -d '$GRILL_SESSIONS/$second/lock' ]] && touch '$GRILL_TMP/both-locked'"

  grill resume --id "$second" >/dev/null

  [[ -f "$GRILL_TMP/both-locked" ]] || fail "expected both sessions locked during the second resume"
  [[ "$(jq -r '.blockReason' "$GRILL_SESSIONS/$second/session.json")" == "awaiting_confirmation" ]] \
    || fail "expected the second session to reach the gate"
  [[ "$(<"$GRILL_SESSIONS/$first/lock/pid")" == "$holder" ]] || fail "expected the first session lock untouched"
  kill "$holder"
  wait "$holder" 2>/dev/null || true

  teardown_grill_repo
}

test_kill_mid_exchange_leaves_it_in_flight_and_resume_reemits_when_received() {
  local status session_dir record prompt

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run
  printf 'received\n' > "$FAKE_CLAUDE_DIR/exchanges/ex-0004.kill"

  status="$(grill_as_job start --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude)"

  [[ "$status" -ne 0 ]] || fail "expected the killed coordinator to exit non-zero"
  session_dir="$(only_session_dir)"
  [[ "$(jq -r '.status' "$session_dir/session.json")" == "grilling" ]] || fail "expected the record to stay grilling"
  [[ "$(exchange_status "$session_dir" ex-0004)" =~ ^(intent|sent)$ ]] || fail "expected ex-0004 left in flight"
  [[ "$(jq -c '.decisions' "$session_dir/session.json")" == "{}" ]] || fail "expected no decisions before recovery"
  [[ ! -e "$session_dir/lock" ]] || fail "expected the killed coordinator to release its lock"
  rm -rf "$FAKE_CLAUDE_DIR/calls"

  grill resume --id "$(basename "$session_dir")" >/dev/null

  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected resume to reach the gate"
  [[ "$(jq -c '[.exchanges[].id]' <<<"$record")" \
    == '["ex-0001","ex-0002","ex-0003","ex-0004","ex-0005","ex-0006","ex-0007","ex-0008","ex-0009","ex-0010"]' ]] \
    || fail "expected no duplicated exchange, got $(jq -c '[.exchanges[].id]' <<<"$record")"
  [[ "$(jq -c '.decisions | map_values(.exchangeId)' <<<"$record")" \
    == '{"storage-backend":"ex-0006","export-format":"ex-0004","sync-mode":"ex-0006"}' ]] \
    || fail "expected each decision once, got $(jq -c '.decisions' <<<"$record")"
  [[ "$(claude_call_count)" == "7" ]] || fail "expected one call per remaining exchange"
  [[ "$(claude_flag_value 0001 --resume)" == "$UUID_ANSWERING" ]] || fail "expected the answering session resumed"
  prompt="$(claude_flag_value 0001 -p)"
  assert_contains "$prompt" "[ralph-exchange:ex-0004]"
  assert_contains "$prompt" "Re-emit your reply to exchange ex-0004"
  [[ "$prompt" != *"Where are exports stored?"* ]] || fail "expected a re-emit request, not the original round"

  teardown_grill_repo
}

test_resume_after_a_kill_resends_an_exchange_the_session_never_received() {
  local status session_dir record prompt

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  queue_two_round_run
  printf 'lost\n' > "$FAKE_CLAUDE_DIR/exchanges/ex-0004.kill"

  status="$(grill_as_job start --requirement-file "$REQUIREMENT_FILE" --grilling-agent claude --answering-agent claude)"

  [[ "$status" -ne 0 ]] || fail "expected the killed coordinator to exit non-zero"
  session_dir="$(only_session_dir)"
  [[ "$(exchange_status "$session_dir" ex-0004)" =~ ^(intent|sent)$ ]] || fail "expected ex-0004 left in flight"
  rm -rf "$FAKE_CLAUDE_DIR/calls"

  grill resume --id "$(basename "$session_dir")" >/dev/null

  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected resume to reach the gate"
  [[ "$(jq -c '[.exchanges[].id]' <<<"$record")" \
    == '["ex-0001","ex-0002","ex-0003","ex-0004","ex-0005","ex-0006","ex-0007","ex-0008","ex-0009","ex-0010"]' ]] \
    || fail "expected no duplicated exchange"
  [[ "$(jq -c '.decisions | map_values(.exchangeId)' <<<"$record")" \
    == '{"storage-backend":"ex-0006","export-format":"ex-0004","sync-mode":"ex-0006"}' ]] \
    || fail "expected each decision once"
  [[ "$(claude_call_count)" == "7" ]] || fail "expected one call per remaining exchange"
  [[ "$(claude_flag_value 0001 --resume)" == "$UUID_ANSWERING" ]] || fail "expected the answering session resumed"
  prompt="$(claude_flag_value 0001 -p)"
  assert_contains "$prompt" "[ralph-exchange:ex-0004]"
  assert_contains "$prompt" "Where are exports stored?"
  [[ "$prompt" != *"Re-emit your reply"* ]] || fail "expected the original round, not a re-emit"

  teardown_grill_repo
}

test_transient_failure_is_retried_within_the_same_exchange_and_session() {
  local session_dir record

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  touch "$FAKE_CLAUDE_DIR/exchanges/ex-0003.transient"

  RALPH_RETRY_DELAYS=0 grill start --requirement-file "$REQUIREMENT_FILE" \
    --grilling-agent claude --answering-agent claude >/dev/null

  session_dir="$(only_session_dir)"
  record="$(<"$session_dir/session.json")"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "awaiting_confirmation" ]] || fail "expected the retry to reach the gate"
  [[ "$(jq -c '[.exchanges[].id]' <<<"$record")" \
    == '["ex-0001","ex-0002","ex-0003","ex-0004","ex-0005","ex-0006"]' ]] || fail "expected no new exchange for the retry"
  [[ "$(claude_call_count)" == "7" ]] || fail "expected one extra call for the retry"
  [[ "$(claude_flag_value 0003 --resume)" == "$UUID_GRILLING" ]] || fail "expected the failed call to resume the grilling session"
  [[ "$(claude_flag_value 0004 --resume)" == "$UUID_GRILLING" ]] || fail "expected the retry to resume the grilling session"
  assert_contains "$(claude_flag_value 0003 -p)" "[ralph-exchange:ex-0003]"
  assert_contains "$(claude_flag_value 0004 -p)" "[ralph-exchange:ex-0003]"
  [[ -z "$(claude_flag_value 0004 --session-id)" ]] || fail "expected no new native session on retry"
  assert_contains "$(<"$session_dir/logs/ex-0003-grilling.jsonl.attempt-1")" "529"

  teardown_grill_repo
}

test_session_not_found_on_resume_is_context_lost() {
  local session_id session_dir output status call

  setup_grill_repo
  git -C "$GRILL_REPO" checkout -q -b feature-work
  session_id="$(start_then_rewind)"
  session_dir="$GRILL_SESSIONS/$session_id"
  mkdir -p "$FAKE_CLAUDE_DIR/lost"
  touch "$FAKE_CLAUDE_DIR/lost/$UUID_GRILLING"

  set +e
  output="$(RALPH_RETRY_DELAYS=0 grill resume --id "$session_id" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected a lost native session to fail resume"
  assert_contains "$output" "context_lost"
  [[ "$(jq -r '.status' "$session_dir/session.json")" == "context_lost" ]] || fail "expected context_lost record"
  [[ "$(claude_call_count)" == "1" ]] || fail "expected no retry or replacement after not found"
  for call in "$FAKE_CLAUDE_DIR"/calls/*; do
    [[ -z "$(claude_flag_value "$(basename "$call")" --session-id)" ]] || fail "expected no replacement session start"
  done
  assert_contains "$(<"$session_dir/logs/ex-0003-grilling.jsonl")" "No conversation found"
  [[ -f "$session_dir/logs/ex-0001-grilling.jsonl" ]] || fail "expected earlier logs retained"
  [[ ! -e "$session_dir/lock" ]] || fail "expected the lock released"
  expect_grill_failure "start a new session" resume --id "$session_id"

  teardown_grill_repo
}

test_resume_on_a_terminal_record_fails() {
  local status session_id n=0

  setup_grill_repo

  for status in completed rejected context_lost failed; do
    n=$((n + 1))
    session_id="20260925-120000-000$n"
    write_fixture_session "$GRILL_SESSIONS/$session_id" "$session_id" "$status"
    expect_grill_failure "start a new session" resume --id "$session_id"
    [[ "$(jq -r '.status' "$GRILL_SESSIONS/$session_id/session.json")" == "$status" ]] || fail "expected $status record untouched"
  done
  [[ "$(claude_call_count)" == "0" ]] || fail "expected no Agent calls for terminal records"

  teardown_grill_repo
}

run_test test_start_rejects_invalid_inputs
run_test test_start_creates_owner_only_record_with_frozen_config
run_test test_start_opens_two_distinct_native_claude_sessions
run_test test_start_fails_when_native_ids_are_equal
run_test test_adapter_argv_carries_role_access_policy
run_test test_capability_failure_refuses_before_native_sessions
run_test test_start_refuses_dirty_worktree
run_test test_start_ignores_ralph_session_storage_in_dirty_check
run_test test_start_on_default_branch_creates_issue_planning_branch
run_test test_start_on_default_branch_creates_requirement_planning_branch
run_test test_start_refuses_existing_planning_branch
run_test test_grilling_sessions_are_gitignored
run_test test_start_relays_frontier_rounds_to_the_confirmation_gate
run_test test_every_exchange_after_start_resumes_the_stored_native_session
run_test test_answers_merge_into_decisions_and_reopens_route_the_contradiction
run_test test_partial_answer_set_is_invalid
run_test test_answer_without_evidence_is_invalid
run_test test_invalid_message_followed_by_a_valid_reemit_continues
run_test test_confirmation_flags_out_of_scope_changes_and_head_drift
run_test test_confirmation_without_drift_has_no_flags
run_test test_provider_logs_are_owner_only_per_exchange_and_role
run_test test_resume_continues_a_grilling_session_to_the_gate
run_test test_resume_rejects_configuration_flags
run_test test_needs_human_blocks_with_a_human_input_file
run_test test_resume_with_empty_answers_prints_the_input_file_without_agent_calls
run_test test_resume_routes_human_input_to_answering_then_grilling
run_test test_identical_frontier_without_reopens_blocks_as_no_progress
run_test test_correct_at_the_gate_routes_answering_then_grilling_back_to_the_gate
run_test test_gate_text_without_a_correct_decision_contacts_no_agent
run_test test_status_logs_and_cleanup_require_a_known_id
run_test test_status_shows_state_agents_and_next_action_without_raw_content
run_test test_logs_summarize_activity_per_role_and_exchange
run_test test_cleanup_deletes_terminal_sessions_and_refuses_active_ones

run_test test_resume_fails_on_a_live_lock_and_reclaims_a_dead_one
run_test test_sessions_with_different_ids_hold_their_locks_at_once
run_test test_kill_mid_exchange_leaves_it_in_flight_and_resume_reemits_when_received
run_test test_resume_after_a_kill_resends_an_exchange_the_session_never_received
run_test test_transient_failure_is_retried_within_the_same_exchange_and_session
run_test test_session_not_found_on_resume_is_context_lost
run_test test_resume_on_a_terminal_record_fails

echo "grill_test.sh passed"
