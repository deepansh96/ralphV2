#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

test_run_rejects_failed_steps() {
  local issue output status

  issue="9002"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "stub-step" "failed"

  set +e
  output="$("$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected failed step pre-check to fail"
  assert_contains "$output" "failed steps"
  assert_contains "$output" "set status to pending or completed"
}

test_state_add_steps_appends_dynamic_steps_and_rejects_duplicates() {
  local issue state_file duplicate_output status ids agents sub_issues output

  issue="9019"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  state_file="$WORKSPACES_DIR/$issue/state.json"

  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9019-fixture",
      steps: [
        {
          id: "preflight",
          phase: "fixed",
          type: "preflight",
          agent: "claude",
          reviewers: [],
          hitl: false,
          status: "completed",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"

  source "$ROOT_DIR/scripts/state.sh"

  state_add_steps "$state_file" '[
    {
      "id": "implement-slice-9101",
      "phase": "dynamic",
      "type": "implement-slice",
      "agent": "codex",
      "reviewers": [],
      "hitl": false,
      "status": "pending",
      "sub_issue": 9101,
      "metrics": null,
      "notes": ""
    },
    {
      "id": "implement-slice-9102",
      "phase": "dynamic",
      "type": "implement-slice",
      "agent": "codex",
      "reviewers": [],
      "hitl": false,
      "status": "pending",
      "sub_issue": 9102,
      "metrics": null,
      "notes": ""
    },
    {
      "id": "final-review",
      "phase": "dynamic",
      "type": "final-review",
      "agent": "claude",
      "reviewers": [],
      "hitl": false,
      "status": "pending",
      "metrics": null,
      "notes": ""
    },
    {
      "id": "pr-review",
      "phase": "dynamic",
      "type": "pr-review",
      "agent": "claude",
      "reviewers": ["codex", "gemini", "kimi", "deepseek"],
      "hitl": false,
      "status": "pending",
      "metrics": null,
      "notes": ""
    },
    {
      "id": "review-fixes",
      "phase": "dynamic",
      "type": "review-fixes",
      "agent": "claude",
      "reviewers": [],
      "hitl": false,
      "status": "pending",
      "metrics": null,
      "notes": ""
    }
  ]'

  ids="$(jq -r '.steps[].id' "$state_file" | tr '\n' ' ')"
  agents="$(jq -r '.steps[] | select(.phase == "dynamic") | "\(.type):\(.agent)"' "$state_file" | tr '\n' ' ')"
  sub_issues="$(jq -r '.steps[] | select(.type == "implement-slice") | .sub_issue' "$state_file" | tr '\n' ' ')"

  assert_contains "$ids" "preflight implement-slice-9101 implement-slice-9102 final-review pr-review review-fixes"
  assert_contains "$agents" "implement-slice:codex"
  assert_contains "$agents" "final-review:claude"
  assert_contains "$agents" "pr-review:claude"
  assert_contains "$agents" "review-fixes:claude"
  assert_contains "$sub_issues" "9101 9102"

  output="$("$RALPH" status --issue "$issue")"
  assert_contains "$output" "implement-slice-9101"
  assert_contains "$output" "implement-slice-9102"
  assert_contains "$output" "final-review"
  assert_contains "$output" "pr-review"
  assert_contains "$output" "review-fixes"

  set +e
  duplicate_output="$(state_add_steps "$state_file" '[{"id":"implement-slice-9101","phase":"dynamic","type":"implement-slice","agent":"codex","status":"pending"}]' 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected duplicate dynamic step id to fail"
  assert_contains "$duplicate_output" "duplicate step id"
  [[ "$(jq '.steps | length' "$state_file")" == "6" ]] || fail "expected duplicate failure not to append steps"
}

test_state_add_steps_rejects_malformed_step_payloads() {
  local issue state_file output status

  issue="9049"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  jq -n '{issue: 9049, steps: []}' > "$state_file"

  source "$ROOT_DIR/scripts/state.sh"

  set +e
  output="$(state_add_steps "$state_file" '{"id":"not-an-array"}' 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected non-array state_add_steps payload to fail"
  assert_contains "$output" "new steps must be a JSON array"
  [[ "$(jq '.steps | length' "$state_file")" == "0" ]] || fail "expected malformed payload not to append steps"

  set +e
  output="$(state_add_steps "$state_file" '[{"id":"","type":"bad"}]' 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected empty step id payload to fail"
  assert_contains "$output" "new steps must be a JSON array"
  [[ "$(jq '.steps | length' "$state_file")" == "0" ]] || fail "expected empty-id payload not to append steps"
}

test_state_update_step_sets_started_at_on_in_progress() {
  local issue state_file started_at

  issue="9026"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "timing-step" "pending"
  state_file="$WORKSPACES_DIR/$issue/state.json"

  source "$ROOT_DIR/scripts/state.sh"

  state_update_step "$state_file" "timing-step" "in_progress"

  started_at="$(jq -r '.steps[0].started_at // empty' "$state_file")"
  [[ -n "$started_at" ]] || fail "expected started_at to be set when status is in_progress"
  [[ "$started_at" =~ ^[0-9]+$ ]] || fail "expected started_at to be epoch seconds, got: $started_at"

  local now_epoch
  now_epoch="$(date +%s)"
  local diff=$(( now_epoch - started_at ))
  [[ "$diff" -ge 0 && "$diff" -lt 5 ]] || fail "expected started_at to be close to now, diff=$diff"
}

test_state_update_step_clears_started_at_on_pending() {
  local issue state_file started_at

  issue="9027"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "reset-step" "pending"
  state_file="$WORKSPACES_DIR/$issue/state.json"

  source "$ROOT_DIR/scripts/state.sh"

  state_update_step "$state_file" "reset-step" "in_progress"
  started_at="$(jq -r '.steps[0].started_at // empty' "$state_file")"
  [[ -n "$started_at" ]] || fail "expected started_at to be set after in_progress"

  state_update_step "$state_file" "reset-step" "pending"
  started_at="$(jq '.steps[0].started_at' "$state_file")"
  [[ "$started_at" == "null" ]] || fail "expected started_at to be null after reset to pending, got: $started_at"
}

test_state_update_step_tracks_and_clears_pid() {
  local issue state_file pid_file pid_value state_pid

  issue="9034"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "pid-step" "pending"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  pid_file="$WORKSPACES_DIR/$issue/pids/pid-step.pid"
  pid_value="12345"

  source "$ROOT_DIR/scripts/state.sh"

  state_update_step "$state_file" "pid-step" "in_progress" "null" "null" "$pid_value"

  state_pid="$(jq -r '.steps[0].pid' "$state_file")"
  [[ "$state_pid" == "$pid_value" ]] || fail "expected state pid $pid_value, got $state_pid"
  [[ -f "$pid_file" ]] || fail "expected pid file to be created"
  [[ "$(<"$pid_file")" == "$pid_value" ]] || fail "expected pid file to contain $pid_value"

  state_update_step "$state_file" "pid-step" "completed"

  state_pid="$(jq -r '.steps[0].pid' "$state_file")"
  [[ "$state_pid" == "null" ]] || fail "expected pid to clear on completed, got $state_pid"
  [[ ! -f "$pid_file" ]] || fail "expected pid file to be removed on completed"

  state_update_step "$state_file" "pid-step" "in_progress" "null" "null" "$pid_value"
  state_update_step "$state_file" "pid-step" "pending"
  state_pid="$(jq -r '.steps[0].pid' "$state_file")"
  [[ "$state_pid" == "null" ]] || fail "expected pid to clear on pending, got $state_pid"
  [[ ! -f "$pid_file" ]] || fail "expected pid file to be removed on pending"

  state_update_step "$state_file" "pid-step" "in_progress" "null" "null" "$pid_value"
  state_update_step "$state_file" "pid-step" "failed"
  state_pid="$(jq -r '.steps[0].pid' "$state_file")"
  [[ "$state_pid" == "null" ]] || fail "expected pid to clear on failed, got $state_pid"
  [[ ! -f "$pid_file" ]] || fail "expected pid file to be removed on failed"
}

test_run_pipeline_records_current_shell_pid_while_step_runs() {
  local issue fake_bin state_file pid_file ralph_pid state_pid file_pid final_status

  issue="9039"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_sleeping_claude "$fake_bin"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  pid_file="$WORKSPACES_DIR/$issue/pids/sleeping-step.pid"

  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9039-fixture",
      steps: [
        {
          id: "sleeping-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null &
  ralph_pid="$!"

  for _ in {1..100}; do
    [[ -f "$pid_file" ]] && break
    kill -0 "$ralph_pid" 2>/dev/null || break
    sleep 0.05
  done

  [[ -f "$pid_file" ]] || fail "expected pid file while ralph step is running"
  state_pid="$(jq -r '.steps[0].pid' "$state_file")"
  file_pid="$(<"$pid_file")"
  [[ "$state_pid" == "$ralph_pid" ]] || fail "expected state pid $ralph_pid, got $state_pid"
  [[ "$file_pid" == "$ralph_pid" ]] || fail "expected pid file $ralph_pid, got $file_pid"

  wait "$ralph_pid"
  final_status="$(jq -r '.steps[0].status' "$state_file")"
  [[ "$final_status" == "completed" ]] || fail "expected sleeping step to complete, got $final_status"
  [[ "$(jq -r '.steps[0].pid' "$state_file")" == "null" ]] || fail "expected pid to clear after completion"
  [[ ! -f "$pid_file" ]] || fail "expected pid file to be removed after completion"
}

test_state_validate_resets_stale_in_progress_step_without_pid_file() {
  local issue state_file now_epoch started_at output status status_value started_value

  issue="9035"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  now_epoch="$(date +%s)"
  started_at=$(( now_epoch - 10 ))

  jq -n \
    --arg issue "$issue" \
    --argjson started_at "$started_at" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "stale-step",
          type: "stub",
          agent: "stub",
          status: "in_progress",
          started_at: $started_at,
          pid: null,
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"

  source "$ROOT_DIR/scripts/state.sh"

  set +e
  output="$(RALPH_STALE_THRESHOLD=1 state_validate "$state_file" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected stale reset validation to succeed, got $status: $output"
  status_value="$(jq -r '.steps[0].status' "$state_file")"
  started_value="$(jq '.steps[0].started_at' "$state_file")"
  [[ "$status_value" == "pending" ]] || fail "expected stale step to reset to pending, got $status_value"
  [[ "$started_value" == "null" ]] || fail "expected stale step started_at to clear, got $started_value"
  assert_contains "$output" "Warning"
  assert_contains "$output" "stale-step"
}

test_state_validate_keeps_stale_in_progress_step_with_live_pid() {
  local issue state_file now_epoch started_at pid output status status_value

  issue="9036"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs" "$WORKSPACES_DIR/$issue/pids"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  now_epoch="$(date +%s)"
  started_at=$(( now_epoch - 10 ))
  sleep 60 &
  pid="$!"

  jq -n \
    --arg issue "$issue" \
    --argjson started_at "$started_at" \
    --argjson pid "$pid" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "live-step",
          type: "stub",
          agent: "stub",
          status: "in_progress",
          started_at: $started_at,
          pid: $pid,
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"
  printf '%s\n' "$pid" > "$WORKSPACES_DIR/$issue/pids/live-step.pid"

  source "$ROOT_DIR/scripts/state.sh"

  set +e
  output="$(RALPH_STALE_THRESHOLD=1 state_validate "$state_file" 2>&1)"
  status=$?
  set -e
  kill "$pid" 2>/dev/null || true

  [[ "$status" -eq 0 ]] || fail "expected live PID validation to succeed, got $status: $output"
  status_value="$(jq -r '.steps[0].status' "$state_file")"
  [[ "$status_value" == "in_progress" ]] || fail "expected live PID step to remain in_progress, got $status_value"
  [[ "$output" != *"Warning"* ]] || fail "expected no stale warning for live PID, got: $output"
}

test_state_validate_resets_stale_in_progress_step_with_dead_pid_file() {
  local issue state_file now_epoch started_at dead_pid output status status_value

  issue="9038"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs" "$WORKSPACES_DIR/$issue/pids"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  now_epoch="$(date +%s)"
  started_at=$(( now_epoch - 10 ))
  dead_pid="999999"

  jq -n \
    --arg issue "$issue" \
    --argjson started_at "$started_at" \
    --argjson dead_pid "$dead_pid" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "dead-step",
          type: "stub",
          agent: "stub",
          status: "in_progress",
          started_at: $started_at,
          pid: $dead_pid,
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"
  printf '%s\n' "$dead_pid" > "$WORKSPACES_DIR/$issue/pids/dead-step.pid"

  source "$ROOT_DIR/scripts/state.sh"

  set +e
  output="$(RALPH_STALE_THRESHOLD=1 state_validate "$state_file" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected dead PID stale validation to succeed, got $status: $output"
  status_value="$(jq -r '.steps[0].status' "$state_file")"
  [[ "$status_value" == "pending" ]] || fail "expected dead PID step to reset to pending, got $status_value"
  [[ ! -f "$WORKSPACES_DIR/$issue/pids/dead-step.pid" ]] || fail "expected dead PID file to be removed"
  assert_contains "$output" "Warning"
  assert_contains "$output" "dead-step"
}

run_test test_run_rejects_failed_steps
run_test test_state_add_steps_appends_dynamic_steps_and_rejects_duplicates
run_test test_state_add_steps_rejects_malformed_step_payloads
run_test test_state_update_step_sets_started_at_on_in_progress
run_test test_state_update_step_clears_started_at_on_pending
run_test test_state_update_step_tracks_and_clears_pid
run_test test_run_pipeline_records_current_shell_pid_while_step_runs
run_test test_state_validate_resets_stale_in_progress_step_without_pid_file
run_test test_state_validate_keeps_stale_in_progress_step_with_live_pid
run_test test_state_validate_resets_stale_in_progress_step_with_dead_pid_file

echo "state_test.sh passed"
