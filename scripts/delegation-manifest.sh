#!/usr/bin/env bash
DELEGATION_MANIFEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DELEGATION_MANIFEST_DIR/delegation.sh"

# Verification request on stdin (schema `request` in delegation-schema.jq);
# the v1 manifest on stdout. Nonzero means the request itself is malformed;
# rejected input is never echoed. Policy failures are reported inside the
# manifest as mismatch codes with evidenceLevel UNVERIFIED, not as exit codes.
delegation_manifest_build() {
  local request manifest
  request="$(cat)"
  delegation_validate request <<< "$request" || return 1
  manifest="$(jq -ce -f "$DELEGATION_MANIFEST_DIR/delegation-manifest.jq" <<< "$request" 2>/dev/null)" || return 1
  delegation_validate manifest <<< "$manifest" || return 1
  printf '%s\n' "$manifest"
}

# Manifest on stdin; writes WORKSPACE/delegation/<stepId>.manifest.json through
# the shared private atomic writer and prints the path. The caller registers
# workspace ownership first. An invalid manifest leaves any prior file intact.
delegation_manifest_write() {
  local workspace="$1" manifest step
  manifest="$(cat)"
  delegation_validate manifest <<< "$manifest" || return 1
  step="$(jq -r '.stepId' <<< "$manifest")"
  [[ "$step" != */* && "$step" != .* ]] || return 1
  (umask 077; mkdir -p "$workspace/delegation") || return 1
  delegation_write_json "$workspace/delegation" "$step.manifest.json" manifest <<< "$manifest" || return 1
  printf '%s\n' "$workspace/delegation/$step.manifest.json"
}

# Manifest on stdin. The v1 gate passes at OBSERVED or VERIFIED only.
delegation_manifest_passes() {
  local manifest
  manifest="$(cat)"
  delegation_validate manifest <<< "$manifest" || return 1
  jq -e '.evidenceLevel == "OBSERVED" or .evidenceLevel == "VERIFIED"' <<< "$manifest" >/dev/null
}

# Step JSON on stdin; the manifest's requested parent and worker settings.
# All four saved fields must be present: worker settings are never inferred
# from child output, and children are never compared with the parent.
delegation_requested_settings() {
  jq -ce '
    {parent: {model: .model, reasoningEffort: .reasoningEffort},
     worker: {model: .subagentModel, reasoningEffort: .subagentReasoningEffort}}
    | if all(.parent[], .worker[]; type == "string" and length > 0) then . else error("incomplete settings") end
  ' 2>/dev/null
}

# Collector envelope on stdin (claude_delegation_evidence or
# codex_delegation_evidence output); the neutral evidence object for a request.
# ATTEMPT and PARENT are the values the caller collected under, so a stale
# directory or another parent's threads cannot pass as current evidence.
delegation_evidence_from_envelope() {
  local provider="$1" attempt="$2" parent="$3" evidence
  case "$provider" in
    claude)
      evidence="$(jq -ce --arg attempt "$attempt" --arg parent "$parent" '
        {attemptId: $attempt, parentId: $parent, children: .children,
         modelHistory: ([.events[] | select(.event == "PostToolUse" and .agentId != null)
           | {key: .agentId, value: (.modelsUsed // [])}] | from_entries)}
      ' 2>/dev/null)" || return 1 ;;
    codex)
      evidence="$(jq -ce --arg attempt "$attempt" --arg parent "$parent" '
        if .parentId != $parent then error("unbound parent") else . end
        | {attemptId: $attempt, parentId: $parent, children: .children, modelHistory: {}}
      ' 2>/dev/null)" || return 1 ;;
    *) return 1 ;;
  esac
  delegation_validate evidence <<< "$evidence" || return 1
  printf '%s\n' "$evidence"
}
