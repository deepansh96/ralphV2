#!/usr/bin/env bash
STATUS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$STATUS_DIR/codex-delegation.sh"

_format_duration_seconds() {
  local total_seconds="$1"
  local hours minutes seconds

  if [[ "$total_seconds" -le 0 ]]; then
    printf '0s'
    return
  fi

  hours=$((total_seconds / 3600))
  minutes=$(( (total_seconds % 3600) / 60 ))
  seconds=$((total_seconds % 60))

  if [[ "$hours" -gt 0 ]]; then
    printf '%dh %dm' "$hours" "$minutes"
  elif [[ "$minutes" -gt 0 ]]; then
    printf '%dm %ds' "$minutes" "$seconds"
  else
    printf '%ds' "$seconds"
  fi
}

_format_duration_ms() {
  local ms="$1"
  local total_seconds

  total_seconds=$((ms / 1000))
  _format_duration_seconds "$total_seconds"
}

# Delegation output for gated steps (docs/delegation-gate.md, "Status"). Only fixed
# strings and manifest counts are printed: never prompts, arguments, opaque
# IDs, paths, commands, or raw events. Anything unbound prints nothing.
_status_delegation_token() {
  [[ "$1" =~ ^[a-zA-Z0-9_-]{1,200}$ ]]
}

# STEP JSON. One summary for a terminal step whose manifest is current.
_status_delegation_summary() {
  local workspace="$1" step="$2" step_id
  step_id="$(jq -r '.id' <<< "$step")"
  _status_delegation_token "$step_id" || return 0
  [[ -f "$workspace/delegation/$step_id.manifest.json" ]] || return 0
  jq -r --argjson step "$step" '
    def count: type == "number" and . >= 0 and . == floor;
    select(($step.delegationAttempt.id | type == "string")
      and .stepId == $step.id and .attemptId == $step.delegationAttempt.id
      and (.evidenceLevel | IN("OBSERVED","VERIFIED","UNVERIFIED"))
      and (.observed.selectedCount | count) and (.expected.taskCount | count))
    | "     Delegation: \(.evidenceLevel) \(.observed.selectedCount)/\(.expected.taskCount)"
  ' "$workspace/delegation/$step_id.manifest.json" 2>/dev/null || true
}

# Claude: this attempt's sanitized hook events. A child has started at
# SubagentStart and completed at its foreground Agent return with a stop.
_status_delegation_claude_activity() {
  local workspace="$1" attempt="$2" inputs claude
  inputs="$workspace/ralph-delegation-$attempt"
  [[ -f "$inputs/claude-inputs" ]] || return 0
  claude="$(<"$inputs/claude-inputs")"
  [[ -f "$claude/context.json" && -f "$claude/events.jsonl" ]] || return 0
  jq -e --arg attempt "$attempt" '.attempt == $attempt' "$claude/context.json" >/dev/null 2>&1 || return 0
  jq -rs '
    [.[] | select(.event == "SubagentStart" and .agent_type == "ralph-worker") | .agent_id] as $started
    | [.[] | select(.event == "SubagentStop") | .agent_id] as $stopped
    | .[]
    | if .event == "SubagentStart" and .agent_type == "ralph-worker" then "[delegation] child started"
      elif .event == "PostToolUse" and .status == "completed" and (.agentId | IN($started[])) and (.agentId | IN($stopped[]))
      then "[delegation] child completed"
      else empty end
  ' "$claude/events.jsonl" 2>/dev/null || true
}

# Codex: direct children of the current log's parent, read through a fresh App
# Server. A log older than the attempt belongs to an earlier invocation.
_status_delegation_codex_activity() {
  local log="$1" started_at="$2" parent children
  [[ -f "$log" && "$started_at" =~ ^[0-9]+$ ]] || return 0
  [[ "$(date -r "$log" +%s)" -ge "$started_at" ]] || return 0
  parent="$(codex_delegation_parent_id "$log")" || return 0
  children="$(RALPH_CODEX_COLLECT_TIMEOUT="${RALPH_CODEX_COLLECT_TIMEOUT:-10}" codex_delegation_collect "$parent" 2>/dev/null)" || return 0
  jq -r '
    [.[] | select(.nested | not)]
    | (.[] | select(.started) | "[delegation] child started"),
      (.[] | select(.completed) | "[delegation] child completed")
  ' <<< "$children"
}

# STEP JSON. Best-effort live activity for an in-progress gated step.
_status_delegation_activity() {
  local workspace="$1" step="$2" log="$3" attempt
  attempt="$(jq -r '.delegationAttempt.id // empty' <<< "$step")"
  _status_delegation_token "$attempt" || return 0
  case "$(jq -r '.agent' <<< "$step")" in
    claude) _status_delegation_claude_activity "$workspace" "$attempt" ;;
    codex) _status_delegation_codex_activity "$log" "$(jq -r '.delegationAttempt.startedAt' <<< "$step")" ;;
  esac
}

status_print() {
  local state_file="$1"
  local workspace="${2:-}"
  local now_epoch

  now_epoch="$(date +%s)"

  printf "%-4s %-24s %-18s %-10s %-12s %-10s %-18s\n" "#" "Step ID" "Type" "Agent" "Status" "Duration" "Process"
  jq -r '
    .steps
    | to_entries[]
    | [
        (.key + 1),
        .value.id,
        (.value.type // "-"),
        (.value.agent // "-"),
        .value.status,
        (.value.metrics.duration // .value.metrics.duration_ms // "-"),
        (.value.started_at // "-"),
        (.value.pid // "-"),
        (.value | has("delegation"))
      ]
    | @tsv
  ' "$state_file" | while IFS=$'\t' read -r number id type agent status duration started_at pid gated; do
    local display_duration="-"
    local process_status="-"

    if [[ "$status" == "in_progress" ]]; then
      if [[ "$started_at" != "-" && "$started_at" != "null" && -n "$started_at" ]]; then
        local elapsed=$(( now_epoch - started_at ))
        display_duration="$(_format_duration_seconds "$elapsed")"
      fi
      if [[ "$pid" != "-" && "$pid" != "null" && -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        process_status="alive (PID $pid)"
      else
        process_status="not found (stale)"
      fi
    elif [[ "$status" == "completed" ]]; then
      if [[ "$duration" != "-" && "$duration" != "null" && -n "$duration" ]]; then
        if [[ "$duration" =~ ^[0-9]+$ ]]; then
          display_duration="$(_format_duration_ms "$duration")"
        else
          display_duration="$duration"
        fi
      fi
    fi

    printf "%-4s %-24s %-18s %-10s %-12s %-10s %-18s\n" "$number" "$id" "$type" "$agent" "$status" "$display_duration" "$process_status"
    if [[ "$gated" == true && -n "$workspace" && ( "$status" == completed || "$status" == failed ) ]]; then
      _status_delegation_summary "$workspace" "$(jq -c --argjson i "$((number - 1))" '.steps[$i]' "$state_file")"
    fi
  done

  if [[ -n "$workspace" ]]; then
    local ip_step ip_id ip_agent ip_started_at elapsed_str log_file snippet
    ip_step="$(jq -r '.steps[] | select(.status == "in_progress") | @json' "$state_file" 2>/dev/null | head -1)"
    if [[ -n "$ip_step" ]]; then
      ip_id="$(jq -r '.id' <<<"$ip_step")"
      ip_agent="$(jq -r '.agent // "-"' <<<"$ip_step")"
      ip_started_at="$(jq -r '.started_at // "-"' <<<"$ip_step")"

      if [[ "$ip_started_at" != "-" && "$ip_started_at" != "null" && -n "$ip_started_at" ]]; then
        elapsed_str="$(_format_duration_seconds $(( now_epoch - ip_started_at )))"
      else
        elapsed_str="-"
      fi

      log_file="$workspace/logs/$ip_id.log"
      printf '\n--- Current activity (%s · %s · %s) ---\n' "$ip_id" "$ip_agent" "$elapsed_str"
      if jq -e 'has("delegation")' <<< "$ip_step" >/dev/null; then
        _status_delegation_activity "$workspace" "$ip_step" "$log_file"
      else
        parse_log "$log_file" "$ip_agent" 10
      fi
    fi
  fi
}
