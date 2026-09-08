#!/usr/bin/env bash
DELEGATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Validate exactly one JSON value from stdin. Never echo rejected provider data.
delegation_validate() {
  jq -e -s --arg schema "$1" -f "$DELEGATION_DIR/delegation-schema.jq" >/dev/null 2>&1
}

# Normalization is explicit; validators do not silently repair malformed artifacts.
delegation_sort_codes() {
  local value
  value="$(cat)"
  delegation_validate codes <<< "$value" || return 1
  jq -c 'unique' <<< "$value"
}

# Caller registers workspace ownership before using this helper. NAME is a
# basename, never a provider path. Node supplies fsync, unavailable in Bash/jq.
delegation_write_json() {
  local workspace="$1" name="$2" schema="$3" value
  value="$(cat)"
  delegation_validate "$schema" <<< "$value" || return 1
  printf '%s\n' "$value" | node "$DELEGATION_DIR/delegation-files.cjs" "$workspace" "$name"
}

# Dormant until gate activation. Call once per provider invocation, including
# internal CLI retries and manual/HITL resumes, BEFORE rendering any input.
# PREPARE is a shell callback: PREPARE STATE STEP FRESH_INPUT_DIRECTORY.
# It renders from current State and creates the invocation's plan/hook/log inputs.
# stdout returns only the new directory; absent metadata is a byte-preserving
# no-op (the caller retains its legacy path). Callback stdout goes to stderr.
# The final attempt remains in State, even when preparation/provider work fails.
delegation_prepare_invocation() {
  local state="$1" step="$2" prepare="$3" record attempt updated workspace inputs
  record="$(jq -ce --arg id "$step" '[.steps[] | select(.id == $id)] | if length == 1 then .[0] else error("step") end' "$state" 2>/dev/null)" || return 1
  if ! jq -e 'has("delegation")' <<< "$record" >/dev/null; then
    return 0
  fi
  jq '.delegation' <<< "$record" | delegation_validate metadata || return 1
  attempt="$(node -e 'console.log(JSON.stringify({id:require("node:crypto").randomUUID(),startedAt:Math.floor(Date.now()/1000)}))')" || return 1
  updated="$(jq --arg id "$step" --argjson attempt "$attempt" '
    .steps |= map(if .id == $id then .status = "in_progress" | .delegationAttempt = $attempt else . end)
  ' "$state")" || return 1
  workspace="$(dirname "$state")"
  delegation_write_json "$workspace" "$(basename "$state")" state <<< "$updated" || return 1
  inputs="$workspace/ralph-delegation-$(jq -r .id <<< "$attempt")"
  (umask 077; mkdir "$inputs") || return 1
  (umask 077; "$prepare" "$state" "$step" "$inputs") >&2 || return 1
  printf '%s\n' "$inputs"
}

delegation_sort_children() {
  local value
  value="$(cat)"
  delegation_validate children <<< "$value" || return 1
  jq -c 'sort_by(.taskId,.run,.childId)' <<< "$value"
}
