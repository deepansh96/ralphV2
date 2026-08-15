#!/usr/bin/env bash
set -euo pipefail

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
pid_file="$session_dir/tunnel.pid"
manifest="$session_dir/tunnel.json"

if [[ -f "$pid_file" ]]; then
  existing_pid="$(<"$pid_file")"
  if [[ "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" 2>/dev/null; then
    echo "Tunnel PID $existing_pid is already running for this session" >&2
    exit 1
  fi
  rm -f "$pid_file" "$manifest"
fi

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
printf '%s\n' "$tunnel_pid" > "$pid_file"

public_url=""
for _attempt in {1..60}; do
  if ! kill -0 "$tunnel_pid" 2>/dev/null; then
    echo "Tunnel process exited before publishing a URL. See $log_file" >&2
    rm -f "$pid_file"
    exit 1
  fi

  if [[ "$provider" == "cloudflare" ]]; then
    public_url="$(grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' "$log_file" 2>/dev/null | tail -1 || true)"
  else
    public_url="$(curl -fsS http://127.0.0.1:4040/api/tunnels 2>/dev/null \
      | jq -r --arg url "$local_url" '.tunnels[]? | select(.proto == "https" and .config.addr == $url) | .public_url' \
      | head -1 || true)"
  fi
  [[ -n "$public_url" ]] && break
  sleep 0.25
done

if [[ -z "$public_url" ]]; then
  kill "$tunnel_pid" 2>/dev/null || true
  rm -f "$pid_file"
  echo "Timed out waiting for a public tunnel URL. See $log_file" >&2
  exit 1
fi

jq -n --arg provider "$provider" --arg url "$public_url" --argjson pid "$tunnel_pid" \
  '{provider: $provider, url: $url, pid: $pid}' > "$manifest"
cat "$manifest"
