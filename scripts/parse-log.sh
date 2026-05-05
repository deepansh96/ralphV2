#!/usr/bin/env bash

parse_log() {
  local log_file="$1"
  local agent="$2"
  local lines="${3:-10}"

  if [[ ! -s "$log_file" ]]; then
    printf 'Starting...\n'
    return
  fi

  local jq_filter

  case "$agent" in
    claude)
      jq_filter='
        select(.type == "assistant")
        | .message.content[]?
        | if .type == "text" then
            "[text] " + (.text[:120] | gsub("\n"; " "))
          elif .type == "tool_use" then
            "[tool] " + .name + ": " + (
              (.input | to_entries | first | (.key + "=" + (.value | tostring)[:80])) // ""
            )
          else
            empty
          end
      '
      ;;
    codex)
      jq_filter='
        select(.type == "item.completed")
        | .item
        | if .type == "agent_message" then
            "[text] " + (.text[:120] | gsub("\n"; " "))
          elif .type == "command_execution" then
            "[cmd] " + (.command[:120] | gsub("\n"; " "))
          else
            empty
          end
      '
      ;;
    *)
      printf 'Unknown agent: %s\n' "$agent"
      return
      ;;
  esac

  tail -20 "$log_file" \
    | jq -R 'try fromjson' \
    | jq -r "$jq_filter" \
    | tail -"$lines"
}
