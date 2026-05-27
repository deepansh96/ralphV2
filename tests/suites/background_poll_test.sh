#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

test_background_run_exits_immediately_writes_wrapper_pid_and_completes() {
  local issue fake_bin state_file wrapper_pid_file output status elapsed status_value wrapper_pid wrapper_log start_epoch

  issue="9040"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_sleeping_claude "$fake_bin"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  wrapper_pid_file="$WORKSPACES_DIR/$issue/step-runner.pid"
  wrapper_log="$WORKSPACES_DIR/$issue/logs/wrapper.log"

  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9040-fixture",
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

  start_epoch="$(date +%s)"
  set +e
  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" --background 2>&1)"
  status=$?
  set -e
  elapsed=$(( $(date +%s) - start_epoch ))

  [[ "$status" -eq 0 ]] || fail "expected background run to exit 0, got $status: $output"
  [[ "$elapsed" -lt 2 ]] || fail "expected background run to exit within 2s, took ${elapsed}s"
  [[ -f "$wrapper_pid_file" ]] || fail "expected wrapper PID file"
  wrapper_pid="$(<"$wrapper_pid_file")"
  [[ "$wrapper_pid" =~ ^[0-9]+$ ]] || fail "expected numeric wrapper PID, got $wrapper_pid"
  assert_contains "$output" "$wrapper_pid"
  kill -0 "$wrapper_pid" 2>/dev/null || fail "expected wrapper process $wrapper_pid to be alive immediately after launch"

  for _ in {1..100}; do
    status_value="$(jq -r '.steps[0].status' "$state_file")"
    [[ "$status_value" == "completed" ]] && break
    sleep 0.05
  done

  status_value="$(jq -r '.steps[0].status' "$state_file")"
  [[ "$status_value" == "completed" ]] || fail "expected background wrapper to complete step, got $status_value"
  [[ -f "$wrapper_log" ]] || fail "expected wrapper log file"
}

test_poll_blocks_until_step_completes_then_exits_zero() {
  local issue state_file output status now_epoch wrapper_pid updater_pid

  issue="9041"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs" "$WORKSPACES_DIR/$issue/pids"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  now_epoch="$(date +%s)"
  sleep 60 &
  wrapper_pid="$!"

  jq -n \
    --arg issue "$issue" \
    --argjson started_at "$now_epoch" \
    --argjson pid "$wrapper_pid" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "poll-step",
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
  printf '%s\n' "$wrapper_pid" > "$WORKSPACES_DIR/$issue/step-runner.pid"
  printf '%s\n' "$wrapper_pid" > "$WORKSPACES_DIR/$issue/pids/poll-step.pid"

  (
    sleep 0.2
    jq '.steps[0].status = "completed" | .steps[0].pid = null' "$state_file" > "$state_file.tmp"
    mv "$state_file.tmp" "$state_file"
  ) &
  updater_pid="$!"

  set +e
  output="$(RALPH_POLL_INTERVAL=0.05 "$RALPH" poll --issue "$issue" 2>&1)"
  status=$?
  set -e

  wait "$updater_pid"
  kill "$wrapper_pid" 2>/dev/null || true

  [[ "$status" -eq 0 ]] || fail "expected poll to exit 0 after completion, got $status: $output"
  assert_contains "$output" "poll-step"
  assert_contains "$output" "alive"
  assert_contains "$output" "Pipeline complete"
}

test_poll_exits_one_when_step_fails() {
  local issue state_file output status

  issue="9042"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  state_file="$WORKSPACES_DIR/$issue/state.json"

  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "failed-step",
          type: "stub",
          agent: "stub",
          status: "failed",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"

  set +e
  output="$(RALPH_POLL_INTERVAL=0.05 "$RALPH" poll --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected poll to exit 1 for failed step, got $status: $output"
  assert_contains "$output" "Step failed-step failed"
}

test_poll_exits_zero_when_step_is_blocked_for_hitl() {
  local issue state_file flag_file output status

  issue="9043"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  flag_file="$WORKSPACES_DIR/$issue/hitl-blocked-step.md"

  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "blocked-step",
          type: "stub",
          agent: "stub",
          status: "blocked",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"
  printf '## Questions\n\nNeed input.\n' > "$flag_file"

  set +e
  output="$(RALPH_POLL_INTERVAL=0.05 "$RALPH" poll --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected poll to exit 0 for blocked step, got $status: $output"
  assert_contains "$output" "blocked for human input"
  assert_contains "$output" "$flag_file"
}

test_poll_detects_dead_wrapper_pid_and_exits_one() {
  local issue state_file output status now_epoch started_at dead_pid status_value

  issue="9044"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs" "$WORKSPACES_DIR/$issue/pids"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  now_epoch="$(date +%s)"
  started_at=$(( now_epoch - 10 ))
  dead_pid="999999"

  jq -n \
    --arg issue "$issue" \
    --argjson started_at "$started_at" \
    --argjson pid "$dead_pid" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "dead-wrapper-step",
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
  printf '%s\n' "$dead_pid" > "$WORKSPACES_DIR/$issue/step-runner.pid"
  printf '%s\n' "$dead_pid" > "$WORKSPACES_DIR/$issue/pids/dead-wrapper-step.pid"

  set +e
  output="$(RALPH_STALE_THRESHOLD=1 RALPH_POLL_INTERVAL=0.05 "$RALPH" poll --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected poll to exit 1 for dead wrapper PID, got $status: $output"
  assert_contains "$output" "Wrapper PID $dead_pid is dead"
  status_value="$(jq -r '.steps[0].status' "$state_file")"
  [[ "$status_value" == "pending" ]] || fail "expected stale detection to reset step to pending, got $status_value"
}

test_background_run_respects_steps_limit() {
  local issue fake_bin state_file output status first_status second_status

  issue="9045"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_claude "$fake_bin"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  state_file="$WORKSPACES_DIR/$issue/state.json"

  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9045-fixture",
      steps: [
        {
          id: "first-background-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          metrics: {},
          notes: ""
        },
        {
          id: "second-background-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"

  set +e
  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" --background --steps 1 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected background --steps run to launch, got $status: $output"
  for _ in {1..100}; do
    first_status="$(jq -r '.steps[0].status' "$state_file")"
    [[ "$first_status" == "completed" ]] && break
    sleep 0.05
  done

  first_status="$(jq -r '.steps[0].status' "$state_file")"
  second_status="$(jq -r '.steps[1].status' "$state_file")"
  [[ "$first_status" == "completed" ]] || fail "expected first background step completed, got $first_status"
  [[ "$second_status" == "pending" ]] || fail "expected second background step pending after --steps 1, got $second_status"
  assert_contains "$(<"$WORKSPACES_DIR/$issue/logs/wrapper.log")" "Step limit reached (1/1)"
}

run_test test_background_run_exits_immediately_writes_wrapper_pid_and_completes
run_test test_poll_blocks_until_step_completes_then_exits_zero
run_test test_poll_exits_one_when_step_fails
run_test test_poll_exits_zero_when_step_is_blocked_for_hitl
run_test test_poll_detects_dead_wrapper_pid_and_exits_one
run_test test_background_run_respects_steps_limit

echo "background_poll_test.sh passed"
