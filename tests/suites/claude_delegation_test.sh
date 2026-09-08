#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/claude-delegation.sh"
raw='{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_use_id":"tool-1","tool_input":{"subagent_type":"ralph-worker","model":"sonnet","prompt":"RALPH-TASK: matt_spec\nRALPH-RUN: 1\nSECRET prompt"},"transcript_path":"SECRET","auth":"SECRET","command":"SECRET"}'
expected='{"event":"PreToolUse","tool_use_id":"tool-1","agent_id":null,"subagent_type":"ralph-worker","model":"sonnet","taskId":"matt_spec","assignmentDigest":null,"run":1}'
[[ "$(claude_delegation_sanitize <<< "$raw")" == "$expected" ]]
# Documented return and lifecycle shapes discard all free text.
for tool in Agent; do
  post="$(claude_delegation_sanitize <<JSON
{"hook_event_name":"PostToolUse","tool_name":"$tool","tool_use_id":"tool-1","tool_response":{"agentId":"child-1","status":"completed","resolvedModel":"claude-sonnet-4-6","modelsUsed":["claude-sonnet-4-6"],"content":"SECRET","auth":"SECRET"}}
JSON
)"
  [[ "$post" == '{"event":"PostToolUse","tool_use_id":"tool-1","agentId":"child-1","status":"completed","resolvedModel":"claude-sonnet-4-6","modelsUsed":["claude-sonnet-4-6"]}' ]]
done
[[ "$(claude_delegation_sanitize <<< '{"hook_event_name":"SubagentStop","agent_id":"child-1","agent_type":"ralph-worker","status":"completed","effort":{"level":"high"},"last_assistant_message":"SECRET","agent_transcript_path":"SECRET"}')" == '{"event":"SubagentStop","agent_id":"child-1","agent_type":"ralph-worker","status":"completed","effort":{"level":"high"}}' ]]
events='[
{"event":"PreToolUse","tool_use_id":"tool-1","agent_id":null,"subagent_type":"ralph-worker","model":"sonnet","taskId":"matt_spec","assignmentDigest":null,"run":1},
{"event":"SubagentStart","agent_id":"child-1","agent_type":"ralph-worker"},
{"event":"SubagentStop","agent_id":"child-1","agent_type":"ralph-worker","status":null,"effort":{"level":"high"}},
{"event":"PostToolUse","tool_use_id":"tool-1","agentId":"child-1","status":"completed","resolvedModel":"claude-sonnet-4-6","modelsUsed":["claude-sonnet-4-6"]}
]'
expected_child='[{"childId":"child-1","parentId":"parent-1","taskId":"matt_spec","run":1,"assignmentDigest":null,"started":true,"completed":true,"outcome":"completed","effective":{"model":"claude-sonnet-4-6","reasoningEffort":"high"},"nested":false}]'
[[ "$(claude_delegation_normalize parent-1 <<< "$events")" == "$expected_child" ]]
for mutation in 'map(select(.event != "SubagentStart"))' 'map(select(.event != "SubagentStop"))'; do
  result="$(jq "$mutation" <<< "$events" | claude_delegation_normalize parent-1)"
  jq -e '.[0].completed == false and .[0].outcome == "incomplete"' <<< "$result" >/dev/null
done
for outcome in failed stopped; do
  result="$(jq --arg outcome "$outcome" '.[3].status = $outcome' <<< "$events" | claude_delegation_normalize parent-1)"
  jq -e --arg outcome "$outcome" '.[0].completed == false and .[0].outcome == $outcome' <<< "$result" >/dev/null
done
result="$(jq '.[0].agent_id = "outer-child"' <<< "$events" | claude_delegation_normalize parent-1)"
jq -e '.[0].nested and .[0].parentId == "outer-child"' <<< "$result" >/dev/null
# Never silently omit uncorrelated records or choose one conflicting return.
for mutation in '. + [.[3] + {agentId:"other"}]' '. + [.[0]]' 'map(select(.event != "PreToolUse"))' '. + [{"event":"SubagentStart","agent_id":"orphan"}]' '.[0].taskId = null'; do
  if jq "$mutation" <<< "$events" | claude_delegation_normalize parent-1; then exit 1; fi
done
result="$(jq '. + [{"event":"PostToolUseFailure","tool_use_id":"tool-1","status":"failed"}]' <<< "$events" | claude_delegation_normalize parent-1)"
jq -e '.[0].outcome == "failed" and (.[0].completed|not)' <<< "$result" >/dev/null
workspace="$(mktemp -d "${TMPDIR:-/tmp}/ralph-37-claude.XXXXXX")"
trap 'rm -rf "$workspace"' EXIT
inputs="$(claude_delegation_prepare "$workspace" attempt-1 parent-1)"
settings="$inputs/settings.json"
[[ -f "$settings" && -f "$inputs/events.jsonl" ]]
node - "$settings" "$inputs/events.jsonl" <<'JS'
const fs=require('fs'),assert=require('assert');
for(const p of process.argv.slice(2)) assert.equal(fs.statSync(p).mode&0o777,0o600);
JS
command="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$settings")"
jq '. + {session_id:"parent-1"}' <<< "$raw" | bash -c "$command"
[[ "$(jq -r .event "$inputs/events.jsonl")" == PreToolUse ]]
[[ "$(jq -r .model "$inputs/events.jsonl")" == sonnet ]]
if rg SECRET "$inputs"; then exit 1; fi
# Wrong session cannot contribute to this attempt.
jq '. + {session_id:"old-parent"}' <<< "$raw" | bash -c "$command" || true
[[ "$(wc -l < "$inputs/events.jsonl" | tr -d ' ')" == 1 ]]
printf 'existing settings\n' > "$workspace/settings.json"
claude_delegation_cleanup "$inputs"
[[ ! -e "$inputs" && "$(cat "$workspace/settings.json")" == 'existing settings' ]]
# CLI seam: real hooks, fake external provider, no raw stdout persisted.
mkdir "$workspace/bin"
cat > "$workspace/bin/claude" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
settings="" parent="" forward=false agents=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agents) agents="$2"; shift 2;;
    --settings) settings="$2"; shift 2;;
    --session-id) parent="$2"; shift 2;;
    --forward-subagent-text) forward=true; shift;;
    *) shift;;
  esac
done
[[ "$forward" == true && -f "$settings" ]]
[[ "${CLAUDE_CODE_DISABLE_BACKGROUND_TASKS:-}" == 1 ]]
jq -e '.["ralph-worker"] | .model == "claude-sonnet-5" and .effort == "high" and (.disallowedTools | index("Agent")) and (.disallowedTools | index("Workflow"))' <<< "$agents" >/dev/null
for event in PreToolUse SubagentStart SubagentStop PostToolUse; do
  cmd="$(jq -r --arg event "$event" '.hooks[$event][0].hooks[0].command' "$settings")"
  case "$event" in
    PreToolUse) raw='{"tool_name":"Agent","tool_use_id":"tool-1","tool_input":{"subagent_type":"ralph-worker","prompt":"RALPH-TASK: matt_spec\nRALPH-RUN: 1\nSECRET"}}';;
    SubagentStart) raw='{"agent_id":"child-1","agent_type":"ralph-worker"}';;
    SubagentStop) raw='{"agent_id":"child-1","agent_type":"ralph-worker","last_assistant_message":"SECRET"}';;
    PostToolUse) raw='{"tool_name":"Agent","tool_use_id":"tool-1","tool_response":{"agentId":"child-1","status":"completed","content":"SECRET"}}';;
  esac
  jq --arg event "$event" --arg parent "$parent" '. + {hook_event_name:$event,session_id:$parent}' <<< "$raw" | bash -c "$cmd"
done
printf '{"type":"assistant","parent_tool_use_id":"tool-1","message":{"content":"SECRET"}}\n'
FAKE
chmod +x "$workspace/bin/claude"
result="$(PATH="$workspace/bin:$PATH" claude_delegation_invoke "$workspace" attempt-2 'probe prompt' sonnet high claude-sonnet-5 high)"
jq -e '.requested.model == "claude-sonnet-5" and (.children | length == 1 and .[0].completed and .[0].taskId == "matt_spec")' <<< "$result" >/dev/null
[[ -z "$(find "$workspace" -name events.jsonl)" ]]
# A malformed invoking ID must never be downgraded to a root spawn.
if jq '.agent_id = "invalid/id"' <<< "$raw" | claude_delegation_sanitize >/dev/null; then
  echo 'FAIL: malformed nested parent accepted as root' >&2
  exit 1
fi
# Workflow evidence cannot masquerade as the supported Agent path.
if jq '.[0].event = "UnsupportedWorkflow"' <<< "$events" | claude_delegation_normalize parent-1 >/dev/null; then
  echo 'FAIL: Workflow accepted as Agent' >&2; exit 1
fi
# A different worker definition must not satisfy this collector.
if jq '.[0].subagent_type = "other-worker"' <<< "$events" | claude_delegation_normalize parent-1 >/dev/null; then
  echo 'FAIL: conflicting worker type accepted' >&2; exit 1
fi
# The collector retains settings and model history outside the shared child shape.
inputs="$(claude_delegation_prepare "$workspace" attempt-3 parent-1 claude-sonnet-5 high)"
jq -c '.[] | if .event == "PreToolUse" then .model = null else . end' <<< "$events" > "$inputs/events.jsonl"
evidence="$(claude_delegation_evidence "$inputs" attempt-3 parent-1)"
jq -e '.requested == {model:"claude-sonnet-5",reasoningEffort:"high"} and .children[0].completed and .events[3].modelsUsed == ["claude-sonnet-4-6"]' <<< "$evidence" >/dev/null
claude_delegation_cleanup "$inputs"
# A failed sanitizer cannot disappear from an otherwise complete collection.
inputs="$(claude_delegation_prepare "$workspace" attempt-4 parent-1 claude-sonnet-5 high)"
jq -c '.[] | if .event == "PreToolUse" then .model = null else . end' <<< "$events" > "$inputs/events.jsonl"
command="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$inputs/settings.json")"
printf '%s\n' '{"session_id":"parent-1","hook_event_name":"PreToolUse","tool_name":"Agent","agent_id":"bad/id"}' | bash -c "$command" || true
if claude_delegation_collect "$inputs" attempt-4 parent-1 >/dev/null; then
  echo 'FAIL: rejected hook disappeared' >&2; exit 1
fi
claude_delegation_cleanup "$inputs"
source "$ROOT/scripts/prompt.sh"
legacy="$(prompt_native_delegation_contract "$ROOT/prompts/multi-axis-pr-review.md" claude '{}')"
gated="$(prompt_native_delegation_contract "$ROOT/prompts/multi-axis-pr-review.md" claude '{"delegation":{"schemaVersion":1},"subagentModel":"claude-sonnet-5","subagentReasoningEffort":"high"}')"
[[ "$legacy" == *'dynamic Workflow'* ]]
[[ "$gated" == *'subagent_type: ralph-worker'* && "$gated" == *'claude-sonnet-5'* ]]
# Present-but-null invoking identity is ambiguous, not a root call.
if jq '.agent_id = null' <<< "$raw" | claude_delegation_sanitize >/dev/null; then
  echo 'FAIL: null invoking identity became root' >&2; exit 1
fi
inputs="$(claude_delegation_prepare "$workspace" attempt-5 parent-1 claude-sonnet-5 high)"
jq -c '.[] | if .event == "PreToolUse" then .model = "opus" else . end' <<< "$events" > "$inputs/events.jsonl"
if claude_delegation_collect "$inputs" attempt-5 parent-1 >/dev/null; then
  echo 'FAIL: explicit model override accepted' >&2; exit 1
fi
claude_delegation_cleanup "$inputs"
inputs="$(claude_delegation_prepare "$workspace" attempt-6 parent-1)"
jq -c '.[]' <<< "$events" > "$inputs/events.jsonl"
chmod 644 "$inputs/events.jsonl"
if claude_delegation_collect "$inputs" attempt-6 parent-1 >/dev/null; then
  echo 'FAIL: insecure events file accepted' >&2; exit 1
fi
chmod 600 "$inputs/events.jsonl"
claude_delegation_cleanup "$inputs"
# Event order and archived sibling files are not correlation evidence.
[[ "$(jq 'reverse' <<< "$events" | claude_delegation_normalize parent-1)" == "$expected_child" ]]
inputs="$(claude_delegation_prepare "$workspace" attempt-7 parent-1)"
printf 'not current JSON\n' > "$workspace/old-hooks.jsonl"
printf 'not current JSON\n' > "$inputs/events.jsonl.attempt-1"
jq -c '.[]' <<< "$events" > "$inputs/events.jsonl"
[[ "$(claude_delegation_collect "$inputs" attempt-7 parent-1)" == "$expected_child" ]]
if claude_delegation_collect "$inputs" attempt-6 parent-1 >/dev/null; then exit 1; fi
if claude_delegation_collect "$inputs" attempt-7 old-parent >/dev/null; then exit 1; fi
rm "$inputs/events.jsonl.attempt-1"
claude_delegation_cleanup "$inputs"
# Real Workflow probe shape: lifecycle IDs exist but the tool response is unbound.
if printf '%s\n' '[{"event":"SubagentStart","agent_id":"workflow-child","agent_type":"general-purpose"},{"event":"SubagentStop","agent_id":"workflow-child","agent_type":"general-purpose","effort":{"level":"high"}}]' | claude_delegation_normalize parent-1 >/dev/null; then exit 1; fi
# An absent return or a failed call without a child ID cannot be guessed complete.
for mutation in 'map(select(.event != "PostToolUse"))' 'map(select(.event != "PostToolUse")) + [{event:"PostToolUseFailure",tool_use_id:"tool-1",status:"failed"}]'; do
  if jq "$mutation" <<< "$events" | claude_delegation_normalize parent-1 >/dev/null; then exit 1; fi
done
# Provider errors clean the attempt and do not return successful evidence.
printf '#!/usr/bin/env bash\nexit 17\n' > "$workspace/bin/claude"
if PATH="$workspace/bin:$PATH" claude_delegation_invoke "$workspace" attempt-failed prompt opus medium claude-sonnet-5 high; then exit 1; fi
[[ -z "$(find "$workspace" -name events.jsonl)" ]]
[[ "$(claude_delegation_sanitize <<< '{"hook_event_name":"PostToolUse","tool_name":"Workflow","tool_response":{"content":"SECRET"}}')" == '{"event":"UnsupportedWorkflow"}' ]]
# Invalid exposed settings cannot be silently erased as missing evidence.
if claude_delegation_sanitize <<< '{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_use_id":"tool-1","tool_response":{"agentId":"child-1","modelsUsed":["claude-sonnet-5","invalid/model"]}}' >/dev/null; then
  echo 'FAIL: malformed model history was dropped' >&2; exit 1
fi
if jq 'map(if .event == "PreToolUse" or .event == "PostToolUse" then .tool_use_id = null else . end)' <<< "$events" | claude_delegation_normalize parent-1 >/dev/null; then
  echo 'FAIL: missing tool-use IDs correlated' >&2; exit 1
fi
stop="$(claude_delegation_sanitize <<< '{"hook_event_name":"SubagentStop","agent_id":"child-1","agent_type":"ralph-worker","status":"unknown-provider-status"}')"
result="$(jq --argjson stop "$stop" '.[2] = $stop' <<< "$events" | claude_delegation_normalize parent-1)"
jq -e '.[0].completed == false' <<< "$result" >/dev/null
if jq '.tool_input.model = "invalid/model"' <<< "$raw" | claude_delegation_sanitize >/dev/null; then
  echo 'FAIL: malformed explicit model erased' >&2; exit 1
fi

qa='{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_use_id":"qa-tool","tool_input":{"subagent_type":"ralph-worker","prompt":"RALPH-TASK: qa_group_1\nRALPH-ASSIGNMENT: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nRALPH-RUN: 2\nSECRET packet"}}'
qa_clean="$(claude_delegation_sanitize <<< "$qa")"
jq -e '.taskId == "qa_group_1" and .run == 2 and .model == null and .assignmentDigest == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' <<< "$qa_clean" >/dev/null
echo 'Claude collection behavior and isolation checks passed'
