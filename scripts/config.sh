#!/usr/bin/env bash

ralph_config_validate() {
  local config_file="$1"

  if [[ ! -f "$config_file" ]]; then
    echo "Error: Ralph config not found: $config_file" >&2
    return 1
  fi
  if ! jq -e '.' "$config_file" >/dev/null 2>&1; then
    echo "Error: Ralph config is not valid JSON: $config_file" >&2
    return 1
  fi
}

ralph_config_native_delegation_defaults() {
  local config_file="$1"
  local agent="$2"

  ralph_config_validate "$config_file" || return 1

  if ! jq -e --arg agent "$agent" '.nativeDelegation[$agent] != null' \
    "$config_file" >/dev/null; then
    echo "Error: native delegation is not configured for agent '$agent'" >&2
    return 1
  fi

  if ! jq -e --arg agent "$agent" '
    def non_empty_string: type == "string" and length > 0;
    (.nativeDelegation[$agent].model | non_empty_string)
      and (.nativeDelegation[$agent].reasoningEffort | non_empty_string)
  ' "$config_file" >/dev/null; then
    echo "Error: native delegation defaults are incomplete for agent '$agent' in $config_file" >&2
    return 1
  fi

  jq -c --arg agent "$agent" '
    .nativeDelegation[$agent]
    | {model, reasoningEffort}
  ' "$config_file"
}

ralph_config_delegated_step_defaults() {
  local config_file="$1"
  local agent="$2"

  ralph_config_native_delegation_defaults "$config_file" "$agent" >/dev/null \
    || return 1

  if ! jq -e --arg agent "$agent" '
    def non_empty_string: type == "string" and length > 0;
    (.agentDefaults[$agent].model | non_empty_string)
      and (.agentDefaults[$agent].reasoningEffort | non_empty_string)
  ' "$config_file" >/dev/null; then
    echo "Error: main-agent defaults are incomplete for agent '$agent' in $config_file" >&2
    return 1
  fi

  jq -c --arg agent "$agent" '
    {
      agent: $agent,
      model: .agentDefaults[$agent].model,
      reasoningEffort: .agentDefaults[$agent].reasoningEffort,
      subagentModel: .nativeDelegation[$agent].model,
      subagentReasoningEffort: .nativeDelegation[$agent].reasoningEffort
    }
  ' "$config_file"
}
