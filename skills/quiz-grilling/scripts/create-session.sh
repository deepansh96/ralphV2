#!/usr/bin/env bash
set -euo pipefail

session_dir="$(mktemp -d "${TMPDIR:-/tmp}/quiz-grilling.XXXXXX")"
chmod 700 "$session_dir"
printf '%s\n' 'quiz-grilling-v1' > "$session_dir/.quiz-grilling-session"
printf '%s\n' "$session_dir"
