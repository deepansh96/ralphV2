#!/usr/bin/env bash
# Delegation completion gate for steps whose State carries `delegation`
# metadata. Ralph only observes: the provider's main agent still chooses,
# spawns, waits for, and replaces its workers. The runner sources this after
# agent.sh, prompt.sh, and state.sh; see docs/delegation-gate.md.
DELEGATION_GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DELEGATION_GATE_DIR/delegation-manifest.sh"
source "$DELEGATION_GATE_DIR/delegation-qa.sh"
source "$DELEGATION_GATE_DIR/claude-delegation.sh"
source "$DELEGATION_GATE_DIR/codex-delegation.sh"

# Runner inputs for the prepare callback, which runs in a subshell.
DELEGATION_GATE_TEMPLATE=""
DELEGATION_GATE_SKILLS=""
DELEGATION_GATE_HITL_FLAG=""
DELEGATION_GATE_HITL_ANSWERS=""
# The live invocation's private input directory, for interruption cleanup.
DELEGATION_GATE_INPUTS=""

# Step JSON on stdin. Any `delegation` key, even malformed, selects the gate so
# that bad metadata fails closed instead of silently running ungated.
delegation_gate_active() {
  jq -e 'has("delegation")' >/dev/null 2>&1
}

delegation_gate_cleanup_inputs() {
  local inputs="${1:-$DELEGATION_GATE_INPUTS}"
  if [[ -n "$inputs" && "$(basename "$inputs")" == ralph-delegation-* && -d "$inputs" ]]; then
    rm -rf "$inputs"
  fi
  DELEGATION_GATE_INPUTS=""
}

# delegation_prepare_invocation callback: rerender the prompt from fresh State,
# drop the previous plan, and create this invocation's Claude hook inputs.
delegation_gate_prepare() {
  local state="$1" step_id="$2" inputs="$3" step workspace prompt parent
  workspace="$(dirname "$state")"
  step="$(jq -ce --arg id "$step_id" 'first(.steps[] | select(.id == $id))' "$state")" || return 1
  prompt="$(prompt_render "$DELEGATION_GATE_TEMPLATE" "$state" "$workspace" "$step" "$DELEGATION_GATE_SKILLS")" || return 1
  if [[ -n "$DELEGATION_GATE_HITL_FLAG" ]]; then
    prompt="$(prompt_append_hitl_resume "$prompt" "$DELEGATION_GATE_HITL_FLAG" "$DELEGATION_GATE_HITL_ANSWERS")"
  fi
  printf '%s' "$prompt" > "$inputs/prompt" || return 1
  if [[ -e "$workspace/delegation/$step_id.plan.json" ]]; then
    rm -f "$workspace/delegation/$step_id.plan.json" || return 1
  fi
  if [[ "$(jq -r '.agent' <<< "$step")" == claude ]]; then
    parent="$(node -e 'console.log(require("node:crypto").randomUUID())')" || return 1
    printf '%s\n' "$parent" > "$inputs/parent" || return 1
    claude_delegation_prepare "$inputs" "$(jq -r '.delegationAttempt.id' <<< "$step")" "$parent" \
      "$(jq -r '.subagentModel' <<< "$step")" "$(jq -r '.subagentReasoningEffort' <<< "$step")" \
      > "$inputs/claude-inputs" || return 1
  fi
}

# One provider invocation into LOG. Claude gets the session-local worker, the
# temporary hooks, and a known session ID; Codex runs exactly as ungated.
delegation_gate_invoke() {
  local agent="$1" step="$2" inputs="$3" log="$4" project_root="$5" prompt model effort claude_inputs
  prompt="$(<"$inputs/prompt")"
  model="$(jq -r '.model' <<< "$step")"
  effort="$(jq -r '.reasoningEffort' <<< "$step")"
  case "$agent" in
    claude)
      claude_inputs="$(<"$inputs/claude-inputs")"
      CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 agent_claude_command "$prompt" "$model" "$effort" \
        --agents "$(claude_delegation_agents "$(jq -r '.subagentModel' <<< "$step")" "$(jq -r '.subagentReasoningEffort' <<< "$step")")" \
        --forward-subagent-text --settings "$claude_inputs/settings.json" --session-id "$(<"$inputs/parent")" \
        > "$log"
      ;;
    codex)
      agent_codex_command "$prompt" "$project_root" "$model" "$effort" "$inputs/last-message" > "$log"
      ;;
  esac
}

# Collect this invocation's evidence, build and write its manifest, and pass
# only at OBSERVED or VERIFIED. Unbound or unavailable evidence is null, which
# the verifier reports as UNVERIFIED. PROVIDER_STATUS nonzero adds
# PROVIDER_FAILED. A write failure fails without claiming a manifest exists.
delegation_gate_verify() {
  local state="$1" step_id="$2" attempt="$3" inputs="$4" log="$5" provider_status="$6"
  local step workspace agent policy plan_file parent="" envelope="" evidence=null request manifest level
  workspace="$(dirname "$state")"
  step="$(jq -ce --arg id "$step_id" 'first(.steps[] | select(.id == $id))' "$state")" || return 1
  agent="$(jq -r '.agent' <<< "$step")"
  policy="$(jq -r '.delegation.policy' <<< "$step")"
  plan_file="$workspace/delegation/$step_id.plan.json"
  case "$agent" in
    claude)
      parent="$(<"$inputs/parent")"
      envelope="$(claude_delegation_evidence "$(<"$inputs/claude-inputs")" "$attempt" "$parent" 2>/dev/null)" || envelope=""
      ;;
    codex)
      if parent="$(codex_delegation_parent_id "$log")"; then
        if [[ "$policy" == qa-v1 && -f "$plan_file" ]] && delegation_validate plan < "$plan_file"; then
          envelope="$(codex_delegation_evidence "$parent" "$plan_file" 2>/dev/null)" || envelope=""
        else
          envelope="$(codex_delegation_evidence "$parent" 2>/dev/null)" || envelope=""
        fi
      fi
      ;;
  esac
  if [[ -n "$envelope" ]]; then
    evidence="$(delegation_evidence_from_envelope "$agent" "$attempt" "$parent" <<< "$envelope")" || evidence=null
  fi
  request="$(jq -nc --argjson issue "$(jq '.issue' "$state")" --arg step "$step_id" --arg attempt "$attempt" \
    --arg agent "$agent" --arg policy "$policy" --argjson requested "$(delegation_requested_settings <<< "$step")" \
    --argjson failed "$([[ "$provider_status" -eq 0 ]] && echo false || echo true)" --argjson evidence "$evidence" \
    '{issue:$issue,stepId:$step,attemptId:$attempt,provider:$agent,policy:$policy,requested:$requested,
      providerFailed:$failed,evidence:$evidence}')" || return 1
  if [[ "$policy" == qa-v1 ]]; then
    request="$(jq -c --argjson qa "$(delegation_qa_verification "$plan_file" "$(jq -r '.repo' "$state")")" '. + {qa:$qa}' <<< "$request")" || return 1
  fi
  if ! manifest="$(delegation_manifest_build <<< "$request")"; then
    echo "Delegation gate: step '$step_id' verification request was rejected" >&2
    return 1
  fi
  if ! delegation_manifest_write "$workspace" <<< "$manifest" >/dev/null 2>&1; then
    echo "Delegation gate: step '$step_id' MANIFEST_WRITE_FAILED" >&2
    return 1
  fi
  delegation_manifest_passes <<< "$manifest" && return 0
  level="$(jq -r '"\(.evidenceLevel) \(.mismatchCodes | join(","))"' <<< "$manifest")"
  echo "Delegation gate: step '$step_id' is $level" >&2
  return 1
}

# Run one gated step with the existing retry limit and backoff. Every provider
# invocation, including an internal retry, gets a fresh State attempt, prompt,
# plan slot, hooks, and log. stdout carries metrics JSON when the step may
# proceed: verified, or blocked for HITL (no manifest until a terminal result).
delegation_gate_run_step() {
  local state="$1" step_id="$2" log="$3" project_root="$4"
  local step agent attempt inputs status verified max_attempts=3 attempt_no=1 start_ms duration_ms
  step="$(jq -ce --arg id "$step_id" 'first(.steps[] | select(.id == $id))' "$state")" || return 1
  agent="$(jq -r '.agent // empty' <<< "$step")"
  # Fail closed before launch: unsupported provider, malformed metadata or
  # policy, and missing parent/worker settings are configuration errors.
  case "$agent" in
    claude|codex) ;;
    *) echo "Error: delegation gate does not support agent '$agent'" >&2; return 1 ;;
  esac
  if ! jq -c '.delegation' <<< "$step" | delegation_validate metadata; then
    echo "Error: step '$step_id' has unsupported delegation metadata" >&2
    return 1
  fi
  if ! delegation_requested_settings <<< "$step" >/dev/null \
    || ! agent_validate_reasoning_effort "$agent" "$(jq -r '.reasoningEffort' <<< "$step")" \
    || ! agent_validate_reasoning_effort "$agent" "$(jq -r '.subagentReasoningEffort' <<< "$step")"; then
    echo "Error: step '$step_id' needs model, reasoningEffort, subagentModel, and subagentReasoningEffort" >&2
    return 1
  fi
  if [[ -z "$project_root" ]]; then
    project_root="$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel)"
  fi

  start_ms="$(current_time_ms)"
  while true; do
    if ! inputs="$(delegation_prepare_invocation "$state" "$step_id" delegation_gate_prepare)" || [[ -z "$inputs" ]]; then
      attempt="$(jq -r --arg id "$step_id" 'first(.steps[] | select(.id == $id)) | .delegationAttempt.id // empty' "$state")"
      [[ -z "$attempt" ]] || delegation_gate_cleanup_inputs "$(dirname "$state")/ralph-delegation-$attempt"
      echo "Error: could not prepare delegated invocation for step '$step_id'" >&2
      return 1
    fi
    DELEGATION_GATE_INPUTS="$inputs"
    attempt="$(jq -r --arg id "$step_id" 'first(.steps[] | select(.id == $id)) | .delegationAttempt.id' "$state")"
    status=0
    delegation_gate_invoke "$agent" "$step" "$inputs" "$log" "$project_root" || status=$?

    if [[ "$status" -eq 0 && "$(state_get_step_status "$state" "$step_id")" == blocked ]]; then
      delegation_gate_cleanup_inputs "$inputs"
      break
    fi
    verified=0
    delegation_gate_verify "$state" "$step_id" "$attempt" "$inputs" "$log" "$status" || verified=$?
    delegation_gate_cleanup_inputs "$inputs"
    if [[ "$status" -eq 0 ]]; then
      [[ "$verified" -eq 0 ]] || return 1
      break
    fi
    if [[ "$attempt_no" -ge "$max_attempts" ]] || ! agent_log_is_retryable_failure "$log"; then
      return "$status"
    fi
    mv "$log" "$log.attempt-$attempt_no"
    agent_sleep_before_retry "$attempt_no"
    attempt_no=$((attempt_no + 1))
  done

  duration_ms=$(( $(current_time_ms) - start_ms ))
  "metrics_from_${agent}_log" "$log" "$duration_ms"
}
