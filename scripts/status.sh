#!/usr/bin/env bash

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
        (.value.pid // "-")
      ]
    | @tsv
  ' "$state_file" | while IFS=$'\t' read -r number id type agent status duration started_at pid; do
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
      parse_log "$log_file" "$ip_agent" 10
    fi
  fi
}
