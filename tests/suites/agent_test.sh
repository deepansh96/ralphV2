#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

test_claude_agent_step_renders_prompt_logs_metrics_and_summary() {
  local issue output fake_bin log_file status_value duration_value input_tokens cost_value

  issue="9007"
  write_valid_context
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_claude "$fake_bin"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9007-fixture",
      steps: [
        {
          id: "claude-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          sub_issue: 77,
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue")"

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  duration_value="$(jq -r '.steps[0].metrics.duration_ms' "$WORKSPACES_DIR/$issue/state.json")"
  input_tokens="$(jq -r '.steps[0].metrics.input_tokens' "$WORKSPACES_DIR/$issue/state.json")"
  cost_value="$(jq -r '.steps[0].metrics.cost_usd' "$WORKSPACES_DIR/$issue/state.json")"
  log_file="$WORKSPACES_DIR/$issue/logs/claude-step.log"

  [[ "$status_value" == "completed" ]] || fail "expected claude step to complete, got $status_value"
  [[ "$duration_value" == "1234" ]] || fail "expected duration_ms metric, got $duration_value"
  [[ "$input_tokens" == "11" ]] || fail "expected input_tokens metric, got $input_tokens"
  [[ "$cost_value" == "0.02" ]] || fail "expected cost_usd metric, got $cost_value"
  [[ -f "$log_file" ]] || fail "expected claude step log file"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "claude saw: Issue 9007"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Repo deepansh96/ralph"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Workspace $WORKSPACES_DIR/$issue"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Branch feat/issue-9007-fixture"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Base main"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Step claude-step"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Sub 77"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Skills $ROOT_DIR/skills"
  assert_contains "$output" "Step ID"
  assert_contains "$output" "claude-step"
  assert_contains "$output" "completed"
  assert_contains "$output" "1234"
}

test_run_claude_retries_transient_error_and_preserves_attempt_logs() {
  local log_file metrics_file output

  log_file="$(mktemp)"
  metrics_file="$(mktemp)"
  rm -f "$log_file" "$log_file".attempt-* "$metrics_file"

  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    CLAUDE_CALLS=0
    claude() {
      CLAUDE_CALLS=$((CLAUDE_CALLS + 1))
      if [[ "$CLAUDE_CALLS" -eq 1 ]]; then
        printf '%s\n' 'Error: 529 overloaded'
        return 1
      fi

      printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
      jq -n -c '{
        type: "result",
        subtype: "success",
        result: "retried successfully",
        duration_ms: 2345,
        usage: {
          input_tokens: 12,
          output_tokens: 9
        },
        total_cost_usd: 0.03
      }'
    }

    RALPH_RETRY_DELAYS="0 0 0" run_claude "retry prompt" "$log_file" "$PROJECT_ROOT" > "$metrics_file"
    [[ "$CLAUDE_CALLS" -eq 2 ]] || fail "expected claude to be called twice, got $CLAUDE_CALLS"
  )

  [[ -f "$log_file.attempt-1" ]] || fail "expected first failed attempt log to be preserved"
  assert_contains "$(<"$log_file.attempt-1")" "529 overloaded"
  assert_contains "$(<"$log_file")" "retried successfully"
  output="$(<"$metrics_file")"
  assert_contains "$output" '"provider": "claude"'
  assert_contains "$output" '"duration_ms": 2345'

  rm -f "$log_file" "$log_file".attempt-* "$metrics_file"
}

test_run_codex_retries_transient_errors_and_preserves_attempt_logs() {
  local log_file metrics_file output count_file

  log_file="$(mktemp)"
  metrics_file="$(mktemp)"
  count_file="$(mktemp)"
  rm -f "$log_file" "$log_file".attempt-* "$metrics_file"
  printf '0\n' > "$count_file"

  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    codex() {
      local last_message_file calls

      last_message_file=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --output-last-message)
            last_message_file="$2"
            shift 2
            ;;
          *)
            shift
            ;;
        esac
      done
      cat >/dev/null

      calls="$(<"$count_file")"
      calls=$((calls + 1))
      printf '%s\n' "$calls" > "$count_file"
      case "$calls" in
        1)
          printf '%s\n' 'request failed: ETIMEDOUT'
          return 1
          ;;
        2)
          printf '%s\n' 'request failed: rate limit exceeded'
          return 1
          ;;
      esac

      if [[ -n "$last_message_file" ]]; then
        printf 'codex retried successfully\n' > "$last_message_file"
      fi
      printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":17,"output_tokens":19}}'
    }

    run_codex "retry prompt" "$log_file" "$PROJECT_ROOT" > "$metrics_file"
    [[ "$(<"$count_file")" -eq 3 ]] || fail "expected codex to be called three times, got $(<"$count_file")"
  )

  [[ -f "$log_file.attempt-1" ]] || fail "expected first failed codex attempt log"
  [[ -f "$log_file.attempt-2" ]] || fail "expected second failed codex attempt log"
  assert_contains "$(<"$log_file.attempt-1")" "ETIMEDOUT"
  assert_contains "$(<"$log_file.attempt-2")" "rate limit"
  assert_contains "$(<"$log_file")" "turn.completed"
  output="$(<"$metrics_file")"
  assert_contains "$output" '"provider": "codex"'
  assert_contains "$output" '"input_tokens": 17'
  assert_contains "$output" '"output_tokens": 19'

  rm -f "$log_file" "$log_file".attempt-* "$metrics_file" "$count_file"
}

test_codex_step_passes_model_flag_when_set() {
  local log_file metrics_file args_file

  log_file="$(mktemp)"
  metrics_file="$(mktemp)"
  args_file="$(mktemp)"
  rm -f "$log_file" "$log_file".attempt-*

  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    codex() {
      printf '%s\n' "$*" > "$args_file"
      cat >/dev/null
      printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":3}}'
    }

    agent_run_step '{"agent":"codex","model":"gpt-5-codex"}' "model prompt" "$log_file" "$PROJECT_ROOT" > "$metrics_file"
  )

  assert_contains "$(<"$args_file")" "--model gpt-5-codex"
  assert_contains "$(<"$metrics_file")" '"provider": "codex"'

  rm -f "$log_file" "$log_file".attempt-* "$metrics_file" "$args_file"
}

test_codex_step_omits_model_flag_when_unset() {
  local log_file metrics_file args_file

  log_file="$(mktemp)"
  metrics_file="$(mktemp)"
  args_file="$(mktemp)"
  rm -f "$log_file" "$log_file".attempt-*

  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    codex() {
      printf '%s\n' "$*" > "$args_file"
      cat >/dev/null
      printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":3}}'
    }

    agent_run_step '{"agent":"codex"}' "no model prompt" "$log_file" "$PROJECT_ROOT" > "$metrics_file"
  )

  [[ "$(<"$args_file")" != *"--model"* ]] || fail "expected no --model flag when step has no model, got: $(<"$args_file")"

  rm -f "$log_file" "$log_file".attempt-* "$metrics_file" "$args_file"
}

test_run_claude_fails_clean_json_error_without_retrying() {
  local log_file metrics_file status

  log_file="$(mktemp)"
  metrics_file="$(mktemp)"
  rm -f "$log_file" "$log_file".attempt-* "$metrics_file"

  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    CLAUDE_CALLS=0
    claude() {
      CLAUDE_CALLS=$((CLAUDE_CALLS + 1))
      jq -n -c '{
        type: "error",
        error: {
          type: "authentication_error",
          message: "invalid api key"
        }
      }'
      return 2
    }

    set +e
    run_claude "auth prompt" "$log_file" "$PROJECT_ROOT" > "$metrics_file"
    status=$?
    set -e

    [[ "$status" -eq 2 ]] || fail "expected clean JSON auth error status 2, got $status"
    [[ "$CLAUDE_CALLS" -eq 1 ]] || fail "expected claude to be called once, got $CLAUDE_CALLS"
  )

  [[ ! -f "$log_file.attempt-1" ]] || fail "expected non-retryable claude error not to preserve retry attempt"
  assert_contains "$(<"$log_file")" "authentication_error"

  rm -f "$log_file" "$log_file".attempt-* "$metrics_file"
}

test_run_claude_retries_empty_crash_log() {
  local log_file metrics_file

  log_file="$(mktemp)"
  metrics_file="$(mktemp)"
  rm -f "$log_file" "$log_file".attempt-* "$metrics_file"

  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    CLAUDE_CALLS=0
    claude() {
      CLAUDE_CALLS=$((CLAUDE_CALLS + 1))
      if [[ "$CLAUDE_CALLS" -eq 1 ]]; then
        return 1
      fi

      jq -n -c '{
        type: "result",
        subtype: "success",
        result: "retried after empty crash log",
        duration_ms: 3456,
        usage: {
          input_tokens: 3,
          output_tokens: 4
        },
        total_cost_usd: 0.04
      }'
    }

    run_claude "empty crash prompt" "$log_file" "$PROJECT_ROOT" > "$metrics_file"
    [[ "$CLAUDE_CALLS" -eq 2 ]] || fail "expected claude to retry empty crash log, got $CLAUDE_CALLS calls"
  )

  [[ -f "$log_file.attempt-1" ]] || fail "expected empty failed attempt log to be preserved"
  [[ ! -s "$log_file.attempt-1" ]] || fail "expected first attempt log to be empty"
  assert_contains "$(<"$log_file")" "retried after empty crash log"

  rm -f "$log_file" "$log_file".attempt-* "$metrics_file"
}

test_run_claude_retries_truncated_crash_log() {
  local log_file metrics_file

  log_file="$(mktemp)"
  metrics_file="$(mktemp)"
  rm -f "$log_file" "$log_file".attempt-* "$metrics_file"

  (
    source "$ROOT_DIR/scripts/metrics.sh"
    source "$ROOT_DIR/scripts/agent.sh"

    CLAUDE_CALLS=0
    claude() {
      CLAUDE_CALLS=$((CLAUDE_CALLS + 1))
      if [[ "$CLAUDE_CALLS" -eq 1 ]]; then
        printf '%s\n' '{"type":"result"'
        return 1
      fi

      jq -n -c '{
        type: "result",
        subtype: "success",
        result: "retried after truncated crash log",
        duration_ms: 4567,
        usage: {
          input_tokens: 5,
          output_tokens: 6
        },
        total_cost_usd: 0.05
      }'
    }

    run_claude "truncated crash prompt" "$log_file" "$PROJECT_ROOT" > "$metrics_file"
    [[ "$CLAUDE_CALLS" -eq 2 ]] || fail "expected claude to retry truncated crash log, got $CLAUDE_CALLS calls"
  )

  [[ -f "$log_file.attempt-1" ]] || fail "expected truncated failed attempt log to be preserved"
  assert_contains "$(<"$log_file.attempt-1")" '{"type":"result"'
  assert_contains "$(<"$log_file")" "retried after truncated crash log"

  rm -f "$log_file" "$log_file".attempt-* "$metrics_file"
}

test_codex_agent_step_logs_jsonl_and_records_metrics() {
  local issue output fake_bin log_file status_value input_tokens output_tokens cost_value

  issue="9008"
  write_valid_context
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_codex "$fake_bin"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    --arg project_root "$PROJECT_ROOT" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9008-fixture",
      projectRoot: $project_root,
      steps: [
        {
          id: "codex-step",
          type: "test-fixture",
          agent: "codex",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue")"

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  input_tokens="$(jq -r '.steps[0].metrics.input_tokens' "$WORKSPACES_DIR/$issue/state.json")"
  output_tokens="$(jq -r '.steps[0].metrics.output_tokens' "$WORKSPACES_DIR/$issue/state.json")"
  cost_value="$(jq -r '.steps[0].metrics.cost_usd' "$WORKSPACES_DIR/$issue/state.json")"
  log_file="$WORKSPACES_DIR/$issue/logs/codex-step.log"

  [[ "$status_value" == "completed" ]] || fail "expected codex step to complete, got $status_value"
  [[ "$input_tokens" == "13" ]] || fail "expected codex input_tokens metric, got $input_tokens"
  [[ "$output_tokens" == "8" ]] || fail "expected codex output_tokens metric, got $output_tokens"
  [[ "$cost_value" == "null" ]] || fail "expected codex cost_usd to be null, got $cost_value"
  [[ -f "$log_file" ]] || fail "expected codex step log file"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "turn.completed"
  assert_contains "$output" "codex-step"
  assert_contains "$output" "codex"
}

test_codex_step_uses_project_root_from_state_json() {
  local issue fake_bin status_value log_file cwd_file

  issue="9025"
  write_valid_context
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"

  mkdir -p "$fake_bin"
  cwd_file="$fake_bin/codex-cwd"
  cat > "$fake_bin/codex" <<FAKE_CODEX
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$(pwd)" > "$cwd_file"
while [[ \$# -gt 0 ]]; do shift; done
cat >/dev/null
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
FAKE_CODEX
  chmod +x "$fake_bin/codex"

  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
jq -n -c '{
  type: "result",
  subtype: "success",
  result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
  duration_ms: 100,
  usage: { input_tokens: 1, output_tokens: 1 },
  total_cost_usd: 0.01
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    --arg project_root "$PROJECT_ROOT" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9025-fixture",
      projectRoot: $project_root,
      steps: [
        {
          id: "codex-step",
          type: "test-fixture",
          agent: "codex",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status_value" == "completed" ]] || fail "expected codex step to complete, got $status_value"
  [[ -f "$cwd_file" ]] || fail "expected codex cwd file to exist"

  local actual_cwd
  actual_cwd="$(<"$cwd_file")"
  [[ "$actual_cwd" == "$PROJECT_ROOT" ]] || fail "expected codex to run in $PROJECT_ROOT, got $actual_cwd"
}

test_unsupported_agent_marks_step_failed() {
  local issue fake_bin output status status_value

  issue="9048"
  write_valid_context
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_claude "$fake_bin"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    --arg project_root "$PROJECT_ROOT" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9048-unsupported-agent",
      projectRoot: $project_root,
      steps: [
        {
          id: "unsupported-step",
          type: "test-fixture",
          agent: "gemini",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  set +e
  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected unsupported agent run to exit 1, got $status: $output"
  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status_value" == "failed" ]] || fail "expected unsupported agent step to be marked failed, got $status_value"
}

run_test test_claude_agent_step_renders_prompt_logs_metrics_and_summary
run_test test_run_claude_retries_transient_error_and_preserves_attempt_logs
run_test test_run_codex_retries_transient_errors_and_preserves_attempt_logs
run_test test_codex_step_passes_model_flag_when_set
run_test test_codex_step_omits_model_flag_when_unset
run_test test_run_claude_fails_clean_json_error_without_retrying
run_test test_run_claude_retries_empty_crash_log
run_test test_run_claude_retries_truncated_crash_log
run_test test_codex_agent_step_logs_jsonl_and_records_metrics
run_test test_codex_step_uses_project_root_from_state_json
run_test test_unsupported_agent_marks_step_failed

echo "agent_test.sh passed"
