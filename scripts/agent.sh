#!/usr/bin/env bash

current_time_ms() {
  printf '%s000\n' "$(date +%s)"
}

agent_retry_delays() {
  printf '%s\n' "${RALPH_RETRY_DELAYS:-30 60 120}"
}

agent_log_is_retryable_failure() {
  local log_file="$1"

  [[ -s "$log_file" ]] || return 0

  if grep -Eiq 'overloaded|529|rate limit|ETIMEDOUT|ECONNRESET' "$log_file"; then
    return 0
  fi

  if ! jq -s '.' "$log_file" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

agent_sleep_before_retry() {
  local attempt="$1"
  local delays delay

  read -r -a delays <<<"$(agent_retry_delays)"
  delay="${delays[$((attempt - 1))]:-0}"
  [[ "$delay" -gt 0 ]] || return 0
  sleep "$delay"
}

agent_run_with_retry() {
  local log_file="$1"
  local command_fn="$2"
  local attempt max_attempts status errexit_enabled

  max_attempts=3
  attempt=1

  while true; do
    errexit_enabled="false"
    if [[ $- == *e* ]]; then
      errexit_enabled="true"
      set +e
    fi
    "$command_fn" > "$log_file"
    status=$?
    if [[ "$errexit_enabled" == "true" ]]; then
      set -e
    fi

    if [[ "$status" -eq 0 ]]; then
      return 0
    fi

    if [[ "$attempt" -ge "$max_attempts" ]] || ! agent_log_is_retryable_failure "$log_file"; then
      return "$status"
    fi

    mv "$log_file" "$log_file.attempt-$attempt"
    agent_sleep_before_retry "$attempt"
    attempt=$((attempt + 1))
  done
}

run_claude() {
  local prompt="$1"
  local log_file="$2"
  local project_root="${3:-}"  # accepted for forward-compatibility, currently unused
  local model="${4:-}"
  local start_ms end_ms duration_ms status

  run_claude_command() {
    claude -p "$prompt" --dangerously-skip-permissions --output-format stream-json --verbose \
      ${model:+--model "$model"}
  }

  start_ms="$(current_time_ms)"
  agent_run_with_retry "$log_file" run_claude_command
  status=$?
  end_ms="$(current_time_ms)"
  duration_ms=$((end_ms - start_ms))

  [[ "$status" -eq 0 ]] || return "$status"

  metrics_from_claude_log "$log_file" "$duration_ms"
}

run_codex() {
  local prompt="$1"
  local log_file="$2"
  local project_root="${3:-}"
  local last_message_file start_ms end_ms duration_ms status

  if [[ -z "$project_root" ]]; then
    project_root="$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel)"
  fi
  last_message_file="$(mktemp)"
  run_codex_command() {
    printf '%s' "$prompt" | (cd "$project_root" && codex -a never exec \
      --skip-git-repo-check \
      --sandbox danger-full-access \
      -C "$project_root" \
      --json \
      --output-last-message "$last_message_file" \
      -)
  }

  start_ms="$(current_time_ms)"
  agent_run_with_retry "$log_file" run_codex_command
  status=$?
  end_ms="$(current_time_ms)"
  duration_ms=$((end_ms - start_ms))
  rm -f "$last_message_file"

  [[ "$status" -eq 0 ]] || return "$status"

  metrics_from_codex_log "$log_file" "$duration_ms"
}

agent_run_step() {
  local step_json="$1"
  local prompt="$2"
  local log_file="$3"
  local project_root="${4:-}"
  local agent model

  agent="$(jq -r '.agent // empty' <<<"$step_json")"
  model="$(jq -r '.model // empty' <<<"$step_json")"
  case "$agent" in
    claude)
      run_claude "$prompt" "$log_file" "$project_root" "$model"
      ;;
    codex)
      run_codex "$prompt" "$log_file" "$project_root"
      ;;
    *)
      echo "Error: unsupported agent '$agent'" >&2
      return 1
      ;;
  esac
}
