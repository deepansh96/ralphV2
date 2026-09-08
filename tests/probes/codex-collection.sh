#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/codex-delegation.sh"
source "$ROOT/scripts/prompt.sh"
[[ "${RALPH_CODEX_COLLECTION_PROBE:-}" == 1 && $# == 1 && -d "$1" ]] || {
  echo 'Opt in with RALPH_CODEX_COLLECTION_PROBE=1 and supply a registered scratch directory.' >&2
  exit 2
}
scratch="$(cd "$1" && pwd)"
model="${RALPH_CODEX_PROBE_MODEL:-gpt-5.6-sol}"
worker="${RALPH_CODEX_PROBE_WORKER:-gpt-5.6-luna}"
effort="${RALPH_CODEX_PROBE_WORKER_EFFORT:-max}"
step="$(jq -nc --arg model "$worker" --arg effort "$effort" '{subagentModel:$model,subagentReasoningEffort:$effort}')"
contract="$(prompt_native_delegation_contract "$ROOT/prompts/multi-axis-pr-review.md" codex "$step")"
prompt="$contract
This is an isolated collection compatibility probe. Call spawn_agent exactly once to create one direct worker with task_name matt_spec, then wait for it and finish. The worker message must begin with the packet below, unchanged. The worker must only return the requested number, use no tools, write no files, and spawn no agents. Do no other work and do not spawn any other agent.

RALPH-TASK: matt_spec
RALPH-RUN: 1
Return 7."
log="$scratch/ralph-37-codex-probe-exec.log"
trap 'rm -f "$log"' EXIT
printf 'Codex collection probe: %s\n' "$(codex --version)"
printf '%s' "$prompt" | (cd "$scratch" && codex -a never exec --model "$model" --skip-git-repo-check --sandbox read-only -C "$scratch" --json - > "$log")
parent="$(codex_delegation_parent_id "$log")"
result="$(codex_delegation_evidence "$parent")"
jq -e --arg parent "$parent" --arg worker "$worker" --arg effort "$effort" '
  .parentId == $parent and
  (.children | length == 1 and .[0].parentId == $parent and .[0].taskId == "matt_spec" and .[0].run == 1
    and .[0].assignmentDigest == null and .[0].started and .[0].completed and .[0].outcome == "completed" and (.[0].nested | not)
    and (.[0].effective.model == null or .[0].effective.model == $worker)
    and (.[0].effective.reasoningEffort == null or .[0].effective.reasoningEffort == $effort)) and
  all(.threads[]; (keys - ["id","parentId","direct","depth","spawnParent","task","model","reasoningEffort","turns"] | length) == 0
    and all(.turns[]; (keys - ["status","startedAt","completedAt","failed"] | length) == 0))
' <<< "$result" >/dev/null
printf 'Sanitized evidence: %s\n' "$(jq -c '{parentId, children}' <<< "$result")"
printf 'PASS: one direct spawn_agent worker; parentage, start, completion, task identity, and allowlisted evidence collected by a fresh App Server process. Effective settings: %s\n' "$(jq -c '.children[0].effective' <<< "$result")"
