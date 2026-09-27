#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/claude-delegation.sh"
source "$ROOT/scripts/prompt.sh"
[[ "${RALPH_CLAUDE_COLLECTION_PROBE:-}" == 1 && $# == 1 ]] || {
  echo 'Opt in with RALPH_CLAUDE_COLLECTION_PROBE=1 and supply a registered workspace directory.' >&2
  exit 2
}
model="${RALPH_CLAUDE_PROBE_MODEL:-opus}"
worker="${RALPH_CLAUDE_PROBE_WORKER:-claude-sonnet-5}"
[[ "$worker" == claude-* ]] || { echo 'Probe requires an explicit canonical worker model ID.' >&2; exit 2; }
step="$(jq -nc --arg model "$worker" '{delegation:{schemaVersion:1},subagentModel:$model,subagentReasoningEffort:"high"}')"
contract="$(prompt_native_delegation_contract "$ROOT/prompts/multi-axis-pr-review.md" claude "$step")"
prompt="$contract
This is an isolated collection compatibility probe. Launch exactly two direct foreground Agent workers of type ralph-worker, one per packet below. Await both. Each worker must only return the requested number, use no tools, write no files, and spawn no children. Do no other work. Pass each packet unchanged at the beginning of its worker prompt.

RALPH-TASK: matt_spec
RALPH-RUN: 1
Return 7.

NEXT PACKET
RALPH-TASK: qa_group_1
RALPH-ASSIGNMENT: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
RALPH-RUN: 1
Return 11."
printf 'Claude collection probe: %s\n' "$(claude --version)"
result="$(claude_delegation_invoke "$1" "probe-$(date +%s)" "$prompt" "$model" medium "$worker" high \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' --tools 'Agent,TaskOutput')"
jq -e --arg model "$worker" '
  .requested == {model:$model,reasoningEffort:"high"} and
  (.children | length == 2 and all(.[]; .started and .completed and (.nested|not) and
    .run == 1 and .effective == {model:$model,reasoningEffort:"high"}) and
    ([.[].parentId]|unique|length) == 1 and
    .[0].taskId == "matt_spec" and .[0].assignmentDigest == null and
    .[1].taskId == "qa_group_1" and
    .[1].assignmentDigest == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") and
  all(.events[]; (keys - ["event","tool_use_id","agent_id","subagent_type","model","taskId","assignmentDigest","run","agentId","status","resolvedModel","modelsUsed","agent_type","effort"] | length) == 0)
' <<< "$result" >/dev/null
echo 'PASS: two direct Agent workers; parentage, lifecycle, distinct task markers, QA digest, canonical model and high effort correlated; allowlisted evidence only.'
