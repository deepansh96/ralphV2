#!/usr/bin/env bash
set -euo pipefail

session_dir="${1:-}"
[[ -n "$session_dir" ]] || { echo "Usage: cleanup-session.sh <session-dir>" >&2; exit 2; }
[[ -f "$session_dir/.quiz-grilling-session" ]] || { echo "Refusing to clean an unmarked directory: $session_dir" >&2; exit 1; }
[[ "$(<"$session_dir/.quiz-grilling-session")" == "quiz-grilling-v1" ]] || {
  echo "Refusing to clean a session with an unknown marker: $session_dir" >&2
  exit 1
}

resolved_session="$(cd "$session_dir" && pwd -P)"
case "$resolved_session" in
  /|"$HOME"|/Users|/home|/tmp|/private/tmp)
    echo "Refusing unsafe cleanup target: $resolved_session" >&2
    exit 1
    ;;
esac

stop_recorded_process() {
  local label="$1" pid_file="$2" expected="$3" pid command_line attempt
  [[ -f "$pid_file" ]] || return 0
  pid="$(<"$pid_file")"
  [[ "$pid" =~ ^[0-9]+$ ]] || { echo "Invalid $label PID: $pid" >&2; return 1; }
  kill -0 "$pid" 2>/dev/null || { rm -f "$pid_file"; return 0; }
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$command_line" == *"$expected"* ]] || {
    echo "Refusing to stop PID $pid: it is not the recorded $label process" >&2
    return 1
  }
  kill "$pid" 2>/dev/null || true
  for ((attempt = 0; attempt < 20; attempt++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file"
}

tunnel_command="cloudflared"
if [[ -f "$session_dir/tunnel.json" ]]; then
  tunnel_provider="$(jq -r '.provider // empty' "$session_dir/tunnel.json" 2>/dev/null || true)"
  [[ "$tunnel_provider" == "ngrok" ]] && tunnel_command="ngrok"
fi

cleanup_failed="false"
stop_recorded_process "tunnel" "$session_dir/tunnel.pid" "$tunnel_command" || cleanup_failed="true"
stop_recorded_process "quiz server" "$session_dir/server.pid" "serve-quiz.mjs" || cleanup_failed="true"
[[ "$cleanup_failed" == "false" ]] || {
  echo "Cleanup left the marked session in place for manual recovery: $resolved_session" >&2
  exit 1
}

rm -rf -- "$resolved_session"
printf 'Cleaned quiz-grilling session: %s\n' "$resolved_session"
