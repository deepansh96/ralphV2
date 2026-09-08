#!/usr/bin/env bash
CLAUDE_DELEGATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLAUDE_DELEGATION_DIR/delegation.sh"

# Raw input is only in memory; diagnostics never echo rejected data.
claude_delegation_sanitize() {
  jq -ce -f "$CLAUDE_DELEGATION_DIR/claude-delegation-sanitize.jq" 2>/dev/null
}

# Safe event array on stdin, caller supplies the current invocation's parent ID.
# Nonzero means unbound/ambiguous evidence; never interpret it as zero workers.
claude_delegation_normalize() {
  local children
  children="$(jq -ce --arg parent "$1" -f "$CLAUDE_DELEGATION_DIR/claude-delegation-normalize.jq" 2>/dev/null)" || return 1
  delegation_sort_children <<< "$children"
}

# Explicit opt-in only. Caller registers WORKSPACE ownership first.
claude_delegation_prepare() {
  node "$CLAUDE_DELEGATION_DIR/claude-delegation-files.cjs" prepare "$@"
}
claude_delegation_cleanup() {
  node "$CLAUDE_DELEGATION_DIR/claude-delegation-files.cjs" cleanup "$1"
}

# One isolated CLI invocation, no retries or State transitions. #44 owns the
# production retry boundary. stdout contains only the safe collector envelope.
claude_delegation_invoke() (
  set -euo pipefail
  local workspace="$1" attempt="$2" prompt="$3" model="$4" effort="$5" parent inputs agents status=0
  local worker_model="$6" worker_effort="$7"
  shift 7
  parent="$(node -e 'console.log(require("node:crypto").randomUUID())')"
  inputs="$(claude_delegation_prepare "$workspace" "$attempt" "$parent" "$worker_model" "$worker_effort")"
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'claude_delegation_cleanup "$inputs"' EXIT
  agents="$(jq -nc --arg model "$worker_model" --arg effort "$worker_effort" '{"ralph-worker":{description:"Execute the assigned Ralph task packet and return to the parent.",prompt:"Perform only the assigned task. Never delegate or spawn children.",model:$model,effort:$effort,disallowedTools:["Agent","Workflow"]}}')"
  CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 claude -p "$prompt" --agents "$agents" --dangerously-skip-permissions --output-format stream-json --verbose \
    --forward-subagent-text --settings "$inputs/settings.json" --session-id "$parent" \
    --model "$model" --effort "$effort" --no-session-persistence "$@" \
    2>/dev/null | node "$CLAUDE_DELEGATION_DIR/claude-delegation-stream.cjs" "$inputs" || status=$?
  [[ "$status" == 0 ]] || return "$status"
  claude_delegation_evidence "$inputs" "$attempt" "$parent"
)

claude_delegation_collect() {
  local inputs="$1" attempt="$2" parent="$3"
  node "$CLAUDE_DELEGATION_DIR/claude-delegation-files.cjs" check "$inputs" || return 1
  [[ ! -e "$inputs/hook-error" ]] || return 1
  jq -e --arg attempt "$attempt" --arg parent "$parent" \
    '.attempt == $attempt and .parent == $parent' "$inputs/context.json" >/dev/null || return 1
  jq -se --slurpfile context "$inputs/context.json" 'all(.[]; .event != "PreToolUse" or .model == null or $context[0].requested.model == null or .model == $context[0].requested.model)' "$inputs/events.jsonl" >/dev/null || return 1
  jq -s . "$inputs/events.jsonl" | claude_delegation_normalize "$parent"
}

# Collector envelope retains the allowlisted provider facts needed by #41.
# The shared children schema is unchanged; this is not a manifest.
claude_delegation_evidence() {
  local inputs="$1" attempt="$2" parent="$3" children
  children="$(claude_delegation_collect "$inputs" "$attempt" "$parent")" || return 1
  jq -nc --argjson children "$children" --slurpfile context "$inputs/context.json" \
    --slurpfile events "$inputs/events.jsonl" \
    '{requested:$context[0].requested,children:$children,events:$events}'
}
