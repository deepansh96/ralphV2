#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
session_dir="$(mktemp -d "${TMPDIR:-/tmp}/quiz-grilling.XXXXXX")"
chmod 700 "$session_dir"
cp "$script_dir/session-marker" "$session_dir/.quiz-grilling-session"
printf '%s\n' "$session_dir"
