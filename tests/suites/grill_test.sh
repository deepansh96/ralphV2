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
  export FAKE_UUID_QUEUE="$GRILL_TMP/uuids"
  export FAKE_GH_LOG="$GRILL_TMP/gh.log"
  export FAKE_GH_ISSUE_JSON='{"title":"Add Dark Mode!","body":"Readers want a dark theme."}'
  unset FAKE_CLAUDE_HELP_OMIT
  printf '%s\n%s\n' "$UUID_GRILLING" "$UUID_ANSWERING" > "$FAKE_UUID_QUEUE"
  mkdir -p "$FAKE_CLAUDE_DIR"
  : > "$FAKE_GH_LOG"
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
  [[ "$(jq -r '.status' <<<"$record")" == "grilling" ]] || fail "expected status grilling"
  [[ "$(jq -r '.blockReason' <<<"$record")" == "null" ]] || fail "expected null blockReason"
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

  [[ "$(claude_call_count)" == "2" ]] || fail "expected exactly two native sessions"
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
  [[ "$(jq -c '[.exchanges[] | {id, role, status}]' <<<"$record")" \
    == '[{"id":"ex-0001","role":"grilling","status":"completed"},{"id":"ex-0002","role":"answering","status":"completed"}]' ]] \
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

test_grilling_sessions_are_gitignored() {
  grep -qx 'grilling-sessions/' "$ROOT_DIR/.gitignore" || fail "expected grilling-sessions/ in .gitignore"
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

echo "grill_test.sh passed"
