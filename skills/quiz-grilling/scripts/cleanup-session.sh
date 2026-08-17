#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
expected_marker="$(<"$script_dir/session-marker")"

session_dir="${1:-}"
[[ -n "$session_dir" ]] || { echo "Usage: cleanup-session.sh <session-dir>" >&2; exit 2; }
[[ -f "$session_dir/.quiz-grilling-session" ]] || { echo "Refusing to clean an unmarked directory: $session_dir" >&2; exit 1; }
[[ "$(<"$session_dir/.quiz-grilling-session")" == "$expected_marker" ]] || {
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
  local label="$1" record_file="$2" expected="$3" pid command_line attempt
  [[ -f "$record_file" ]] || return 0
  pid="$(jq -r '.pid // empty' "$record_file" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || { rm -f "$record_file"; return 0; }
  kill -0 "$pid" 2>/dev/null || { rm -f "$record_file"; return 0; }
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  # A command mismatch means the recorded process is gone and the OS reused
  # its PID: leave the stranger untouched, but drop the stale record so the
  # session directory can still be removed.
  [[ "$command_line" == *"$expected"* ]] || {
    echo "Recorded $label PID $pid now belongs to another process; leaving it untouched" >&2
    rm -f "$record_file"
    return 0
  }
  kill "$pid" 2>/dev/null || true
  for ((attempt = 0; attempt < 20; attempt++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$record_file"
}

tunnel_command="cloudflared"
if [[ -f "$session_dir/tunnel.json" ]]; then
  tunnel_provider="$(jq -r '.provider // empty' "$session_dir/tunnel.json" 2>/dev/null || true)"
  [[ "$tunnel_provider" == "ngrok" ]] && tunnel_command="ngrok"
fi

stop_recorded_process "tunnel" "$session_dir/tunnel.json" "$tunnel_command"
stop_recorded_process "quiz server" "$session_dir/server-ready.json" "serve-quiz.mjs"

rm -rf -- "$resolved_session"
printf 'Cleaned quiz-grilling session: %s\n' "$resolved_session"
