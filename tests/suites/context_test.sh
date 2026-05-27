#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

test_run_hard_stops_when_context_missing() {
  local issue output status status_value

  issue="9013"
  remove_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "stub-step" "pending"

  set +e
  output="$("$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected missing CONTEXT.md to fail"
  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status_value" == "pending" ]] || fail "expected step to remain pending, got $status_value"
  assert_contains "$output" "CONTEXT.md not found"
  assert_contains "$output" "$CONTEXT_FILE"
}

test_run_hard_stops_when_context_is_insufficient() {
  local issue output status status_value fake_bin log_file

  issue="9014"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_insufficient_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_context_check_claude "$fake_bin"
  write_single_step_state "$issue" "stub-step" "pending"

  set +e
  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected insufficient CONTEXT.md to fail"
  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status_value" == "pending" ]] || fail "expected step to remain pending, got $status_value"
  log_file="$WORKSPACES_DIR/$issue/logs/check-context.log"
  [[ -f "$log_file" ]] || fail "expected context check log file"
  assert_contains "$output" "CONTEXT.md is insufficient"
  assert_contains "$output" "Missing required sections"
}

test_context_check_passes_when_jsonl_result_contains_pass() {
  local issue output status

  issue="9034"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "stub-step" "pending"

  source "$ROOT_DIR/scripts/prompt.sh"
  source "$ROOT_DIR/scripts/context.sh"

  run_claude() {
    local prompt="$1"
    local log_file="$2"

    printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}' > "$log_file"
    jq -n -c '{
      type: "result",
      subtype: "success",
      result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
      duration_ms: 100,
      usage: {
        input_tokens: 1,
        output_tokens: 1
      },
      total_cost_usd: 0.01
    }' >> "$log_file"
  }

  set +e
  output="$(context_check "$ROOT_DIR" "$WORKSPACES_DIR/$issue/state.json" "$WORKSPACES_DIR/$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected JSONL CONTEXT_CHECK PASS to return 0; output: $output"
}

test_context_check_fails_when_jsonl_result_contains_fail() {
  local issue output status

  issue="9035"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "stub-step" "pending"

  source "$ROOT_DIR/scripts/prompt.sh"
  source "$ROOT_DIR/scripts/context.sh"

  run_claude() {
    local prompt="$1"
    local log_file="$2"

    jq -n -c '{
      type: "assistant",
      message: "CONTEXT_CHECK: PASS from a non-result stream event"
    }' > "$log_file"
    jq -n -c '{
      type: "result",
      subtype: "success",
      result: "CONTEXT_CHECK: FAIL\nMissing required sections.",
      duration_ms: 100,
      usage: {
        input_tokens: 1,
        output_tokens: 1
      },
      total_cost_usd: 0.01
    }' >> "$log_file"
  }

  set +e
  output="$(context_check "$ROOT_DIR" "$WORKSPACES_DIR/$issue/state.json" "$WORKSPACES_DIR/$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected JSONL CONTEXT_CHECK FAIL result to return 1; status: $status output: $output"
  assert_contains "$output" "CONTEXT.md is insufficient"
  assert_contains "$output" "Missing required sections"
}

test_context_check_falls_back_to_plain_text_pass() {
  local issue output status

  issue="9036"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "stub-step" "pending"

  source "$ROOT_DIR/scripts/prompt.sh"
  source "$ROOT_DIR/scripts/context.sh"

  run_claude() {
    local prompt="$1"
    local log_file="$2"

    cat > "$log_file" <<'LOG'
CONTEXT_CHECK: PASS
CONTEXT.md follows the required format.
LOG
  }

  set +e
  output="$(context_check "$ROOT_DIR" "$WORKSPACES_DIR/$issue/state.json" "$WORKSPACES_DIR/$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected plain-text CONTEXT_CHECK PASS fallback to return 0; output: $output"
}

run_test test_run_hard_stops_when_context_missing
run_test test_run_hard_stops_when_context_is_insufficient
run_test test_context_check_passes_when_jsonl_result_contains_pass
run_test test_context_check_fails_when_jsonl_result_contains_fail
run_test test_context_check_falls_back_to_plain_text_pass

echo "context_test.sh passed"
