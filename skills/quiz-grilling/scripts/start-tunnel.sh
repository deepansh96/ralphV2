#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
expected_marker="$(<"$script_dir/session-marker")"

usage() {
  echo "Usage: start-tunnel.sh --session <dir> --url <local-url> [--provider auto|cloudflare|ngrok]" >&2
  exit 2
}

session_dir=""
local_url=""
provider="auto"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session) session_dir="${2:-}"; shift 2 ;;
    --url) local_url="${2:-}"; shift 2 ;;
    --provider) provider="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$session_dir" && -n "$local_url" ]] || usage
[[ -f "$session_dir/.quiz-grilling-session" ]] || { echo "Not a quiz-grilling session: $session_dir" >&2; exit 1; }
[[ "$(<"$session_dir/.quiz-grilling-session")" == "$expected_marker" ]] || {
  echo "Not a quiz-grilling session: $session_dir" >&2
  exit 1
}
[[ "$local_url" == http://127.0.0.1:* || "$local_url" == http://localhost:* ]] || {
  echo "Tunnel target must be a loopback HTTP URL" >&2
  exit 1
}

if [[ "$provider" == "auto" ]]; then
  if command -v cloudflared >/dev/null 2>&1; then
    provider="cloudflare"
  elif command -v ngrok >/dev/null 2>&1; then
    provider="ngrok"
  else
    echo "Neither cloudflared nor ngrok is installed" >&2
    exit 3
  fi
fi

log_file="$session_dir/tunnel.log"
manifest="$session_dir/tunnel.json"

if [[ -f "$manifest" ]]; then
  existing_pid="$(jq -r '.pid // empty' "$manifest" 2>/dev/null || true)"
  if [[ "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" 2>/dev/null; then
    echo "Tunnel PID $existing_pid is already running for this session" >&2
    exit 1
  fi
  rm -f "$manifest"
fi

# Record the provider before anything can crash or be cleaned up, so
# cleanup-session.sh never has to guess which binary owns the tunnel.
jq -n --arg provider "$provider" '{provider: $provider}' > "$manifest"

case "$provider" in
  cloudflare)
    command -v cloudflared >/dev/null 2>&1 || { echo "cloudflared is not installed" >&2; exit 3; }
    nohup cloudflared tunnel --url "$local_url" --no-autoupdate >"$log_file" 2>&1 &
    ;;
  ngrok)
    command -v ngrok >/dev/null 2>&1 || { echo "ngrok is not installed" >&2; exit 3; }
    nohup ngrok http "$local_url" --log stdout --log-format json >"$log_file" 2>&1 &
    ;;
  *) usage ;;
esac

tunnel_pid=$!
jq -n --arg provider "$provider" --argjson pid "$tunnel_pid" \
  '{provider: $provider, pid: $pid}' > "$manifest"

# Stop the tunnel this run spawned. Keep the manifest until the process is
# confirmed dead so cleanup-session.sh always has a handle on a live tunnel.
stop_spawned_tunnel() {
  local attempt
  kill "$tunnel_pid" 2>/dev/null || true
  for ((attempt = 0; attempt < 20; attempt++)); do
    kill -0 "$tunnel_pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$tunnel_pid" 2>/dev/null; then
    kill -KILL "$tunnel_pid" 2>/dev/null || true
    sleep 0.2
  fi
  if kill -0 "$tunnel_pid" 2>/dev/null; then
    echo "Tunnel PID $tunnel_pid did not stop; its record is kept in $manifest" >&2
    return 1
  fi
  rm -f "$manifest"
}

public_url=""
for _attempt in {1..240}; do
  if ! kill -0 "$tunnel_pid" 2>/dev/null; then
    echo "Tunnel process exited before publishing a URL. See $log_file" >&2
    rm -f "$manifest"
    exit 1
  fi

  if [[ "$provider" == "cloudflare" ]]; then
    public_url="$(grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' "$log_file" 2>/dev/null | tail -1 || true)"
  else
    # Read the URL from this tunnel's own JSON log instead of the agent API,
    # which lives on a fixed port and may belong to another ngrok agent.
    public_url="$(jq -r 'select(.msg == "started tunnel") | .url // empty' "$log_file" 2>/dev/null | tail -1 || true)"
  fi
  [[ -n "$public_url" ]] && break
  sleep 0.25
done

if [[ -z "$public_url" ]]; then
  stop_spawned_tunnel || true
  echo "Timed out waiting for a public tunnel URL. See $log_file" >&2
  exit 1
fi

jq -n --arg provider "$provider" --arg url "$public_url" --argjson pid "$tunnel_pid" \
  '{provider: $provider, url: $url, pid: $pid}' > "$manifest"
cat "$manifest"
