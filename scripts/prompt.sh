#!/usr/bin/env bash

prompt_native_delegation_contract() {
  local template_file="$1"
  local agent="$2"
  local step_json="$3"
  local contract_file config_file ralph_root contract
  local subagent_model subagent_reasoning_effort

  contract_file="$(dirname "$template_file")/native-delegation/$agent.md"
  if [[ ! -f "$contract_file" ]]; then
    echo "Error: native delegation is not configured for agent '$agent'" >&2
    return 1
  fi

  ralph_root="$(cd "$(dirname "$template_file")/.." && pwd)"
  config_file="$ralph_root/ralph.config.json"
  if [[ ! -f "$config_file" ]]; then
    echo "Error: Ralph config not found: $config_file" >&2
    return 1
  fi
  if ! jq -e '.' "$config_file" >/dev/null 2>&1; then
    echo "Error: Ralph config is not valid JSON: $config_file" >&2
    return 1
  fi

  subagent_model="$(jq -r '.subagentModel // empty' <<<"$step_json")"
  if [[ -z "$subagent_model" ]]; then
    subagent_model="$(jq -r --arg agent "$agent" '.nativeDelegation[$agent].model // empty' "$config_file")"
  fi

  subagent_reasoning_effort="$(jq -r '.subagentReasoningEffort // empty' <<<"$step_json")"
  if [[ -z "$subagent_reasoning_effort" ]]; then
    subagent_reasoning_effort="$(
      jq -r --arg agent "$agent" \
        '.nativeDelegation[$agent].reasoningEffort // empty' \
        "$config_file"
    )"
  fi

  if [[ -z "$subagent_model" || -z "$subagent_reasoning_effort" ]]; then
    echo "Error: native delegation defaults are incomplete for agent '$agent' in $config_file" >&2
    return 1
  fi

  contract="$(<"$contract_file")"
  contract="${contract//\{\{SUBAGENT_MODEL\}\}/$subagent_model}"
  contract="${contract//\{\{SUBAGENT_REASONING_EFFORT\}\}/$subagent_reasoning_effort}"

  printf '%s\n' "$contract"
}

prompt_render() {
  local template_file="$1"
  local state_file="$2"
  local workspace="$3"
  local step_json="$4"
  local skills_dir="$5"
  local prompt

  if [[ ! -f "$template_file" ]]; then
    echo "Error: prompt template not found: $template_file" >&2
    return 1
  fi

  prompt="$(<"$template_file")"

  local issue repo branch base_branch step_id sub_issue reviewers agent
  local native_delegation_contract
  issue="$(jq -r '.issue // ""' "$state_file")"
  repo="$(jq -r '.repo // ""' "$state_file")"
  branch="$(jq -r '.branch // ""' "$state_file")"
  base_branch="$(jq -r '.baseBranch // ""' "$state_file")"
  step_id="$(jq -r '.id // ""' <<<"$step_json")"
  sub_issue="$(jq -r '.sub_issue // .subIssue // ""' <<<"$step_json")"
  reviewers="$(jq -r '(.reviewers // []) | join(",")' <<<"$step_json")"
  agent="$(jq -r '.agent // ""' <<<"$step_json")"

  prompt="${prompt//\{\{ISSUE\}\}/$issue}"
  prompt="${prompt//\{\{REPO\}\}/$repo}"
  prompt="${prompt//\{\{WORKSPACE\}\}/$workspace}"
  prompt="${prompt//\{\{BRANCH\}\}/$branch}"
  prompt="${prompt//\{\{BASE_BRANCH\}\}/$base_branch}"
  prompt="${prompt//\{\{STEP_ID\}\}/$step_id}"
  prompt="${prompt//\{\{SUB_ISSUE\}\}/$sub_issue}"
  prompt="${prompt//\{\{SKILLS_DIR\}\}/$skills_dir}"
  prompt="${prompt//\{\{REVIEWERS\}\}/$reviewers}"
  prompt="${prompt//\{\{AGENT\}\}/$agent}"

  if [[ "$prompt" == *'{{NATIVE_DELEGATION_CONTRACT}}'* ]]; then
    if ! native_delegation_contract="$(prompt_native_delegation_contract "$template_file" "$agent" "$step_json")"; then
      return 1
    fi
    prompt="${prompt//\{\{NATIVE_DELEGATION_CONTRACT\}\}/$native_delegation_contract}"
  fi

  printf '%s\n' "$prompt"
}
