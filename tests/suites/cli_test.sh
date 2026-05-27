#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

test_issue_must_be_positive_integer() {
  local output status

  set +e
  output="$("$RALPH" --issue nope 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected invalid issue to fail"
  assert_contains "$output" "--issue must be a positive integer"
}

test_run_requires_existing_state() {
  local issue output status

  issue="9001"
  rm -rf "${WORKSPACES_DIR:?}/$issue"

  set +e
  output="$("$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected missing state to fail"
  assert_contains "$output" "state.json not found"
  assert_contains "$output" "run init.md first"
}

test_status_prints_step_table() {
  local issue output

  issue="9004"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "stub-step" "in_progress"

  output="$("$RALPH" status --issue "$issue")"

  assert_contains "$output" "#"
  assert_contains "$output" "Step ID"
  assert_contains "$output" "Type"
  assert_contains "$output" "Agent"
  assert_contains "$output" "Status"
  assert_contains "$output" "Duration"
  assert_contains "$output" "stub-step"
  assert_contains "$output" "stub"
  assert_contains "$output" "in_progress"
}

test_logs_tails_active_step_log() {
  local issue output

  issue="9005"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_two_step_state "$issue" "completed" "in_progress"
  printf "active log line\n" > "$WORKSPACES_DIR/$issue/logs/second-step.log"
  printf "old log line\n" > "$WORKSPACES_DIR/$issue/logs/first-step.log"

  output="$("$RALPH" logs --issue "$issue")"

  assert_contains "$output" "active log line"
  [[ "$output" != *"old log line"* ]] || fail "expected active logs to exclude inactive step log"
}

test_logs_tails_specific_step_log() {
  local issue output

  issue="9006"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_two_step_state "$issue" "completed" "in_progress"
  printf "specific completed log\n" > "$WORKSPACES_DIR/$issue/logs/first-step.log"
  printf "active log\n" > "$WORKSPACES_DIR/$issue/logs/second-step.log"

  output="$("$RALPH" logs --issue "$issue" --step first-step)"

  assert_contains "$output" "specific completed log"
  [[ "$output" != *"active log"* ]] || fail "expected --step logs to exclude active step log"
}

test_status_shows_elapsed_time_for_in_progress_step() {
  local issue state_file output now_epoch started_at

  issue="9028"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  state_file="$WORKSPACES_DIR/$issue/state.json"

  now_epoch="$(date +%s)"
  started_at=$(( now_epoch - 125 ))

  jq -n \
    --arg issue "$issue" \
    --argjson started_at "$started_at" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "completed-step",
          type: "stub",
          agent: "stub",
          status: "completed",
          metrics: { duration_ms: 65000 },
          notes: ""
        },
        {
          id: "running-step",
          type: "stub",
          agent: "stub",
          status: "in_progress",
          started_at: $started_at,
          metrics: {},
          notes: ""
        },
        {
          id: "waiting-step",
          type: "stub",
          agent: "stub",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"

  output="$("$RALPH" status --issue "$issue")"

  assert_contains "$output" "1m 5s"
  assert_contains "$output" "2m"
  assert_contains "$output" "running-step"
  assert_contains "$output" "completed-step"

  local pending_line
  pending_line="$(echo "$output" | grep "waiting-step")"
  assert_contains "$pending_line" "-"
}

test_status_shows_pid_liveness_for_in_progress_steps() {
  local issue state_file output now_epoch live_pid dead_pid

  issue="9037"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  now_epoch="$(date +%s)"
  sleep 60 &
  live_pid="$!"
  dead_pid="999999"

  jq -n \
    --arg issue "$issue" \
    --argjson started_at "$now_epoch" \
    --argjson live_pid "$live_pid" \
    --argjson dead_pid "$dead_pid" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "live-running-step",
          type: "stub",
          agent: "stub",
          status: "in_progress",
          started_at: $started_at,
          pid: $live_pid,
          metrics: {},
          notes: ""
        },
        {
          id: "dead-running-step",
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

  output="$("$RALPH" status --issue "$issue")"
  kill "$live_pid" 2>/dev/null || true

  assert_contains "$output" "live-running-step"
  assert_contains "$output" "alive (PID $live_pid)"
  assert_contains "$output" "dead-running-step"
  assert_contains "$output" "not found (stale)"
}

test_status_shows_activity_snippet_for_in_progress_step() {
  local issue state_file workspace log_file output

  issue="9033"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  workspace="$WORKSPACES_DIR/$issue"
  mkdir -p "$workspace/logs"
  state_file="$workspace/state.json"

  local now_epoch started_at
  now_epoch="$(date +%s)"
  started_at=$(( now_epoch - 222 ))

  jq -n \
    --arg issue "$issue" \
    --argjson started_at "$started_at" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "implement-slice-42",
          type: "implement-slice",
          agent: "codex",
          status: "in_progress",
          started_at: $started_at,
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"

  log_file="$workspace/logs/implement-slice-42.log"
  cat > "$log_file" <<'JSONL'
{"type":"item.completed","item":{"type":"command_execution","command":"npm test"}}
{"type":"item.completed","item":{"type":"agent_message","text":"All tests pass. I will commit the changes now."}}
JSONL

  source "$ROOT_DIR/scripts/parse-log.sh"
  source "$ROOT_DIR/scripts/status.sh"
  output="$(status_print "$state_file" "$workspace")"

  assert_contains "$output" "Current activity"
  assert_contains "$output" "implement-slice-42"
  assert_contains "$output" "codex"
  assert_contains "$output" "3m"
  assert_contains "$output" "[cmd] npm test"
  assert_contains "$output" "[text] All tests pass"
}

test_status_shows_dash_for_in_progress_without_started_at() {
  local issue state_file output

  issue="9028"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  state_file="$WORKSPACES_DIR/$issue/state.json"

  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "old-running-step",
          type: "stub",
          agent: "stub",
          status: "in_progress",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"

  output="$("$RALPH" status --issue "$issue")"

  assert_contains "$output" "old-running-step"
  assert_contains "$output" "in_progress"

  local step_line
  step_line="$(echo "$output" | grep "^[0-9].*old-running-step")"
  local duration_field
  duration_field="$(echo "$step_line" | awk '{print $6}')"
  [[ "$duration_field" == "-" ]] || fail "expected dash for in_progress step without started_at, got: $duration_field"
}

run_test test_issue_must_be_positive_integer
run_test test_run_requires_existing_state
run_test test_status_prints_step_table
run_test test_logs_tails_active_step_log
run_test test_logs_tails_specific_step_log
run_test test_status_shows_elapsed_time_for_in_progress_step
run_test test_status_shows_pid_liveness_for_in_progress_steps
run_test test_status_shows_activity_snippet_for_in_progress_step
run_test test_status_shows_dash_for_in_progress_without_started_at

echo "cli_test.sh passed"
