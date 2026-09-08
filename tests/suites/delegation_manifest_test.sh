#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/delegation-manifest.sh"

# Hand-authored from #37 "Manifest" and "PR-review policy": five direct, flat,
# completed run-1 workers with no exposed settings are OBSERVED with no codes.
child() {
  jq -nc --arg id "$1" --arg task "$2" '{childId:$id,parentId:"parent-1",taskId:$task,run:1,assignmentDigest:null,started:true,completed:true,outcome:"completed",effective:{model:null,reasoningEffort:null},nested:false}'
}
five="$(jq -sc . <(child c-standards matt_standards) <(child c-spec matt_spec) <(child c-ponytail ponytail) <(child c-codex isolated_codex) <(child c-supe supe))"
request="$(jq -nc --argjson children "$five" '{issue:37,stepId:"multi-axis-pr-review",attemptId:"attempt-1",provider:"codex",policy:"pr-review-v1",
  requested:{parent:{model:"gpt-5.6-sol",reasoningEffort:"medium"},worker:{model:"gpt-5.6-luna",reasoningEffort:"max"}},
  providerFailed:false,evidence:{attemptId:"attempt-1",parentId:"parent-1",children:$children,modelHistory:{}}}')"
expected='{"schemaVersion":1,"issue":37,"stepId":"multi-axis-pr-review","attemptId":"attempt-1","provider":"codex","evidenceSource":"app-server","parentId":"parent-1","policy":"pr-review-v1","requested":{"parent":{"model":"gpt-5.6-sol","reasoningEffort":"medium"},"worker":{"model":"gpt-5.6-luna","reasoningEffort":"max"}},"expected":{"taskCount":5,"taskIds":["isolated_codex","matt_spec","matt_standards","ponytail","supe"]},"observed":{"startedCount":5,"completedCount":5,"selectedCount":5},"children":[{"childId":"c-codex","parentId":"parent-1","taskId":"isolated_codex","run":1,"assignmentDigest":null,"started":true,"completed":true,"outcome":"completed","effective":{"model":null,"reasoningEffort":null},"nested":false,"disposition":"selected"},{"childId":"c-spec","parentId":"parent-1","taskId":"matt_spec","run":1,"assignmentDigest":null,"started":true,"completed":true,"outcome":"completed","effective":{"model":null,"reasoningEffort":null},"nested":false,"disposition":"selected"},{"childId":"c-standards","parentId":"parent-1","taskId":"matt_standards","run":1,"assignmentDigest":null,"started":true,"completed":true,"outcome":"completed","effective":{"model":null,"reasoningEffort":null},"nested":false,"disposition":"selected"},{"childId":"c-ponytail","parentId":"parent-1","taskId":"ponytail","run":1,"assignmentDigest":null,"started":true,"completed":true,"outcome":"completed","effective":{"model":null,"reasoningEffort":null},"nested":false,"disposition":"selected"},{"childId":"c-supe","parentId":"parent-1","taskId":"supe","run":1,"assignmentDigest":null,"started":true,"completed":true,"outcome":"completed","effective":{"model":null,"reasoningEffort":null},"nested":false,"disposition":"selected"}],"evidenceLevel":"OBSERVED","mismatchCodes":[]}'
[[ "$(delegation_manifest_build <<< "$request")" == "$expected" ]]
# Children are compared only with requested.worker: Luna/max children under a
# Sol/medium parent are VERIFIED; children matching the parent settings fail.
with_effective() { jq -c --arg model "$1" --arg effort "$2" 'map(.effective = {model:$model,reasoningEffort:$effort})' <<< "$five"; }
verified="$(jq -c --argjson children "$(with_effective gpt-5.6-luna max)" '.evidence.children = $children' <<< "$request" | delegation_manifest_build)"
[[ "$(jq -c '[.evidenceLevel,.mismatchCodes,.observed]' <<< "$verified")" == '["VERIFIED",[],{"startedCount":5,"completedCount":5,"selectedCount":5}]' ]]
[[ "$(jq -c '.children[0].effective' <<< "$verified")" == '{"model":"gpt-5.6-luna","reasoningEffort":"max"}' ]]
[[ "$(jq -c --argjson children "$(with_effective gpt-5.6-sol medium)" '.evidence.children = $children' <<< "$request" | delegation_manifest_build | jq -c '[.evidenceLevel,.mismatchCodes]')" == '["UNVERIFIED",["EFFORT_MISMATCH","MODEL_MISMATCH"]]' ]]
# One missing effective field caps a valid run at OBSERVED without failing it.
partial="$(with_effective gpt-5.6-luna max | jq -c '.[2].effective.reasoningEffort = null')"
[[ "$(jq -c --argjson children "$partial" '.evidence.children = $children' <<< "$request" | delegation_manifest_build | jq -c '[.evidenceLevel,.mismatchCodes]')" == '["OBSERVED",[]]' ]]
# Every pr-review-v1 mismatch case yields its exact closed code; counts stay
# honest so status can later render N/M from the manifest alone.
verify() { jq -c --argjson children "$1" '.evidence.children = $children' <<< "$request" | delegation_manifest_build | jq -c '[.evidenceLevel,.mismatchCodes,.observed.startedCount,.observed.completedCount,.observed.selectedCount]'; }
[[ "$(verify "$(jq -c 'map(select(.taskId != "supe"))' <<< "$five")")" == '["UNVERIFIED",["TASK_MISSING"],4,4,4]' ]]
[[ "$(verify "$(jq -c '.[4] += {completed:false,outcome:"failed"}' <<< "$five")")" == '["UNVERIFIED",["CHILD_FAILED"],5,4,5]' ]]
[[ "$(verify "$(jq -c '.[4] += {completed:false,outcome:"stopped"}' <<< "$five")")" == '["UNVERIFIED",["CHILD_STOPPED"],5,4,5]' ]]
[[ "$(verify "$(jq -c '.[4] += {completed:false,outcome:"incomplete"}' <<< "$five")")" == '["UNVERIFIED",["CHILD_INCOMPLETE"],5,4,5]' ]]
[[ "$(verify "$(jq -c '.[4] += {started:false,completed:false,outcome:"incomplete"}' <<< "$five")")" == '["UNVERIFIED",["CHILD_MISSING"],4,4,5]' ]]
[[ "$(verify "$(jq -c '. + [.[4] | .childId = "c-supe-again"]' <<< "$five")")" == '["UNVERIFIED",["TASK_DUPLICATED"],6,6,6]' ]]
[[ "$(verify "$(jq -c '. + [.[4] | .childId = "c-helper" | .taskId = "helper"]' <<< "$five")")" == '["UNVERIFIED",["TASK_UNEXPECTED"],6,6,6]' ]]
# Retries are not allowed in PR review: a second run is an unexpected identity.
[[ "$(verify "$(jq -c '. + [.[4] | .childId = "c-supe-retry" | .run = 2]' <<< "$five")")" == '["UNVERIFIED",["TASK_UNEXPECTED"],6,6,6]' ]]
[[ "$(verify "$(jq -c '.[4].run = 2' <<< "$five")")" == '["UNVERIFIED",["TASK_MISSING","TASK_UNEXPECTED"],5,5,5]' ]]
# Nested descendants are listed for audit, flagged, and excluded from worker counts.
nested_child="$(child c-grandchild helper | jq -c '.parentId = "c-spec" | .nested = true')"
[[ "$(verify "$(jq -c --argjson n "$nested_child" '. + [$n]' <<< "$five")")" == '["UNVERIFIED",["NESTED_WORKER"],5,5,5]' ]]
[[ "$(verify "$(jq -c '.[4].parentId = "other-parent"' <<< "$five")")" == '["UNVERIFIED",["PARENT_MISMATCH"],5,5,5]' ]]
[[ "$(verify "$(jq -c '.[4].effective.model = "gpt-5.6-sol"' <<< "$five")")" == '["UNVERIFIED",["MODEL_MISMATCH"],5,5,5]' ]]
[[ "$(verify "$(jq -c '.[4].effective.reasoningEffort = "medium"' <<< "$five")")" == '["UNVERIFIED",["EFFORT_MISMATCH"],5,5,5]' ]]
# Stale-attempt evidence can never pass a newer attempt.
[[ "$(jq -c '.evidence.attemptId = "attempt-0"' <<< "$request" | delegation_manifest_build | jq -c '[.attemptId,.mismatchCodes]')" == '["attempt-1",["ATTEMPT_MISMATCH"]]' ]]
[[ "$(jq -c '.evidence.attemptId = null' <<< "$request" | delegation_manifest_build | jq -c '.mismatchCodes')" == '["ATTEMPT_MISSING"]' ]]
# Codes are unique and lexicographically sorted regardless of discovery order.
mixed="$(jq -c --argjson n "$nested_child" 'map(select(.taskId != "ponytail")) | .[3] += {completed:false,outcome:"failed"} | [$n] + .' <<< "$five")"
[[ "$(verify "$mixed")" == '["UNVERIFIED",["CHILD_FAILED","NESTED_WORKER","TASK_MISSING"],4,3,4]' ]]
# Claude family aliases accept only a canonical ID of that family; explicit IDs
# match exactly; every reported modelsUsed value is inspected, not just the
# resolved model. The actual canonical ID is recorded, never the alias.
claude_request="$(jq -c '.provider = "claude" | .requested = {parent:{model:"opus",reasoningEffort:"medium"},worker:{model:"sonnet",reasoningEffort:"high"}}' <<< "$request")"
claude_verify() { jq -c --argjson children "$1" --argjson history "${2:-{\}}" '.evidence.children = $children | .evidence.modelHistory = $history' <<< "$claude_request" | delegation_manifest_build | jq -c '[.evidenceSource,.evidenceLevel,.mismatchCodes]'; }
[[ "$(claude_verify "$(with_effective claude-sonnet-4-6 high)" '{}')" == '["hooks","VERIFIED",[]]' ]]
[[ "$(claude_verify "$(with_effective claude-sonnet-4-6 high)" '{"c-supe":["claude-sonnet-4-6","claude-sonnet-5"]}')" == '["hooks","VERIFIED",[]]' ]]
[[ "$(jq -c --argjson children "$(with_effective claude-sonnet-4-6 high)" '.evidence.children = $children' <<< "$claude_request" | delegation_manifest_build | jq -r '.children[0].effective.model')" == claude-sonnet-4-6 ]]
[[ "$(claude_verify "$(with_effective claude-opus-5 high)" '{}')" == '["hooks","UNVERIFIED",["MODEL_MISMATCH"]]' ]]
[[ "$(claude_verify "$(with_effective claude-sonnet-4-6 high)" '{"c-supe":["claude-sonnet-4-6","claude-opus-5"]}')" == '["hooks","UNVERIFIED",["MODEL_MISMATCH"]]' ]]
[[ "$(claude_verify "$(with_effective sonnet high)" '{}')" == '["hooks","UNVERIFIED",["MODEL_MISMATCH"]]' ]]
[[ "$(claude_verify "$(with_effective claude-sonnet-4-6 medium)" '{}')" == '["hooks","UNVERIFIED",["EFFORT_MISMATCH"]]' ]]
# Missing resolved model with a clean history is still OBSERVED, never VERIFIED.
[[ "$(claude_verify "$(with_effective claude-sonnet-4-6 high | jq -c '.[0].effective.model = null')" '{"c-codex":["claude-sonnet-4-6"]}')" == '["hooks","OBSERVED",[]]' ]]
explicit_request="$(jq -c '.requested.worker.model = "claude-sonnet-5"' <<< "$claude_request")"
[[ "$(jq -c --argjson children "$(with_effective claude-sonnet-4-6 high)" '.evidence.children = $children' <<< "$explicit_request" | delegation_manifest_build | jq -c '.mismatchCodes')" == '["MODEL_MISMATCH"]' ]]
[[ "$(jq -c --argjson children "$(with_effective claude-sonnet-5 high)" '.evidence.children = $children' <<< "$explicit_request" | delegation_manifest_build | jq -r '.evidenceLevel')" == VERIFIED ]]
# An unknown alias is not a family; it must match exactly.
[[ "$(jq -c --argjson children "$(with_effective claude-sonnet-5 high)" '.requested.worker.model = "sonnet5" | .evidence.children = $children' <<< "$claude_request" | delegation_manifest_build | jq -c '.mismatchCodes')" == '["MODEL_MISMATCH"]' ]]
# qa-v1 is valid metadata but not implemented here: it fails closed.
[[ "$(jq -c '.policy = "qa-v1"' <<< "$request" | delegation_manifest_build | jq -c '[.policy,.expected,.evidenceLevel,.mismatchCodes]')" == '["qa-v1",{"taskCount":0,"taskIds":[]},"UNVERIFIED",["POLICY_UNSUPPORTED"]]' ]]
# Provider failure writes a safe UNVERIFIED manifest with whatever partial
# records were bound; without any evidence the parent stays unknown.
partial_failure="$(jq -c --argjson children "$(jq -c '.[0:2]' <<< "$five")" '.providerFailed = true | .evidence.children = $children' <<< "$request" | delegation_manifest_build)"
[[ "$(jq -c '[.evidenceLevel,.mismatchCodes,.observed,(.children|length)]' <<< "$partial_failure")" == '["UNVERIFIED",["PROVIDER_FAILED","TASK_MISSING"],{"startedCount":2,"completedCount":2,"selectedCount":2},2]' ]]
no_evidence="$(jq -c '.providerFailed = true | .evidence = null' <<< "$request" | delegation_manifest_build)"
[[ "$(jq -c '[.parentId,.evidenceLevel,.mismatchCodes,.observed,.children,.expected.taskCount]' <<< "$no_evidence")" == '[null,"UNVERIFIED",["EVIDENCE_UNAVAILABLE","PROVIDER_FAILED"],{"startedCount":0,"completedCount":0,"selectedCount":0},[],5]' ]]
[[ "$(jq -c '.evidence = null' <<< "$request" | delegation_manifest_build | jq -c '.mismatchCodes')" == '["EVIDENCE_UNAVAILABLE"]' ]]
# Both providers produce one manifest shape; only provider and source differ.
codex_manifest="$(delegation_manifest_build <<< "$request")"
claude_manifest="$(jq -c --argjson children "$five" '.evidence.children = $children | .evidence.modelHistory = {"c-supe":["claude-sonnet-4-6"]}' <<< "$claude_request" | delegation_manifest_build)"
[[ "$(jq -c '[paths | map(if type == "number" then 0 else . end)] | unique' <<< "$codex_manifest")" == "$(jq -c '[paths | map(if type == "number" then 0 else . end)] | unique' <<< "$claude_manifest")" ]]
[[ "$(jq -c '[.provider,.evidenceSource]' <<< "$claude_manifest")" == '["claude","hooks"]' ]]
# Deterministic: identical evidence in any order yields identical bytes.
[[ "$(jq -c '.evidence.children |= reverse' <<< "$request" | delegation_manifest_build)" == "$codex_manifest" ]]
[[ "$(delegation_manifest_build <<< "$request")" == "$codex_manifest" ]]
# Malformed or over-rich requests are rejected without echoing any content.
for mutation in '.policy = "other"' '.provider = "deepseek"' '.requested.worker.model = null' '.transcript = "SECRET"' '.evidence.prompt = "SECRET"' '.evidence.children[0].response = "SECRET"' '.evidence.children[0].effective.raw = "SECRET"' '.evidence.modelHistory = {"c-supe":"SECRET"}' 'del(.providerFailed)' '.attemptId = ""'; do
  if output="$(jq -c "$mutation" <<< "$request" | delegation_manifest_build 2>&1)"; then echo "FAIL: accepted $mutation" >&2; exit 1; fi
  [[ -z "$output" ]] || { echo "FAIL: leaked output for $mutation" >&2; exit 1; }
done
# Manifests live at workspaces/<issue>/delegation/<step-id>.manifest.json:
# private directory, 0600 file, atomic replacement, no temporary leftovers.
workspace="$(mktemp -d "${TMPDIR:-/tmp}/ralph-37-manifest.XXXXXX")"
trap 'rm -rf "$workspace"' EXIT
path="$(delegation_manifest_write "$workspace" <<< "$codex_manifest")"
[[ "$path" == "$workspace/delegation/multi-axis-pr-review.manifest.json" ]]
[[ "$(cat "$path")" == "$codex_manifest" ]]
node - "$workspace/delegation" "$path" <<'JS'
const fs=require('fs'),assert=require('assert');
assert.equal(fs.statSync(process.argv[2]).mode & 0o777,0o700);
assert.equal(fs.statSync(process.argv[3]).mode & 0o777,0o600);
JS
exec 3< "$path"
delegation_manifest_write "$workspace" <<< "$verified" >/dev/null
[[ "$(jq -r .evidenceLevel <&3)" == OBSERVED ]]
exec 3<&-
[[ "$(jq -r .evidenceLevel "$path")" == VERIFIED ]]
if delegation_manifest_write "$workspace" <<< '{"stepId":"../escape","prompt":"SECRET"}' 2>/dev/null; then echo 'FAIL: invalid manifest written' >&2; exit 1; fi
[[ "$(jq -r .evidenceLevel "$path")" == VERIFIED && ! -e "$workspace/escape.manifest.json" ]]
[[ "$(find "$workspace" -name '*.tmp-*' | wc -l | tr -d ' ')" == 0 ]]
if grep -rq SECRET "$workspace"; then echo 'FAIL: rejected content persisted' >&2; exit 1; fi
# The forbidden-field list never appears anywhere in a written manifest.
forbidden='["prompt","response","content","message","transcript","transcriptPath","transcript_path","rollout","path","cwd","command","auth","token","apiKey","events","raw","preview"]'
[[ "$(jq -c --argjson forbidden "$forbidden" '[paths | .[] | strings] | unique | map(select(. as $k | $forbidden | index($k) != null))' "$path")" == '[]' ]]
# OBSERVED and VERIFIED pass the v1 gate; UNVERIFIED does not.
delegation_manifest_passes <<< "$codex_manifest"
delegation_manifest_passes <<< "$verified"
if delegation_manifest_passes <<< "$no_evidence"; then echo 'FAIL: UNVERIFIED passed' >&2; exit 1; fi
if delegation_manifest_passes <<< '{"evidenceLevel":"VERIFIED"}'; then echo 'FAIL: malformed manifest passed' >&2; exit 1; fi
# Requested settings come from the step's saved State fields, never from
# child output; an incomplete snapshot is a configuration error.
step='{"id":"multi-axis-pr-review","agent":"codex","status":"in_progress","model":"gpt-5.6-sol","reasoningEffort":"medium","subagentModel":"gpt-5.6-luna","subagentReasoningEffort":"max","delegation":{"schemaVersion":1,"policy":"pr-review-v1"},"delegationAttempt":{"id":"attempt-1","startedAt":1787590000}}'
[[ "$(delegation_requested_settings <<< "$step")" == '{"parent":{"model":"gpt-5.6-sol","reasoningEffort":"medium"},"worker":{"model":"gpt-5.6-luna","reasoningEffort":"max"}}' ]]
for mutation in 'del(.subagentModel)' '.subagentReasoningEffort = ""' 'del(.model)' '.reasoningEffort = null'; do
  if jq "$mutation" <<< "$step" | delegation_requested_settings 2>/dev/null; then echo "FAIL: accepted $mutation" >&2; exit 1; fi
done
# Collector envelopes from #40 and #42 map onto one neutral evidence shape.
claude_child='{"childId":"child-1","parentId":"parent-1","taskId":"matt_spec","run":1,"assignmentDigest":null,"started":true,"completed":true,"outcome":"completed","effective":{"model":"claude-sonnet-4-6","reasoningEffort":"high"},"nested":false}'
claude_envelope="$(jq -nc --argjson child "$claude_child" '{requested:{model:"claude-sonnet-5",reasoningEffort:"high"},children:[$child],events:[
  {event:"PreToolUse",tool_use_id:"tool-1",agent_id:null,subagent_type:"ralph-worker",model:null,taskId:"matt_spec",assignmentDigest:null,run:1},
  {event:"SubagentStart",agent_id:"child-1",agent_type:"ralph-worker"},
  {event:"SubagentStop",agent_id:"child-1",agent_type:"ralph-worker",status:null,effort:{level:"high"}},
  {event:"PostToolUse",tool_use_id:"tool-1",agentId:"child-1",status:"completed",resolvedModel:"claude-sonnet-4-6",modelsUsed:["claude-sonnet-4-6","claude-sonnet-5"]}]}')"
[[ "$(delegation_evidence_from_envelope claude attempt-3 parent-1 <<< "$claude_envelope")" == "$(jq -nc --argjson child "$claude_child" '{attemptId:"attempt-3",parentId:"parent-1",children:[$child],modelHistory:{"child-1":["claude-sonnet-4-6","claude-sonnet-5"]}}')" ]]
codex_child='{"childId":"child-1","parentId":"01a07eb4-da4f-70e2-b282-4079106da2e5","taskId":"matt_spec","run":1,"assignmentDigest":null,"started":true,"completed":true,"outcome":"completed","effective":{"model":"gpt-5.6-luna","reasoningEffort":"max"},"nested":false}'
codex_envelope="$(jq -nc --argjson child "$codex_child" '{parentId:"01a07eb4-da4f-70e2-b282-4079106da2e5",children:[$child],threads:[{id:"child-1",parentId:"01a07eb4-da4f-70e2-b282-4079106da2e5",direct:true,depth:1,spawnParent:"01a07eb4-da4f-70e2-b282-4079106da2e5",task:"matt_spec",model:"gpt-5.6-luna",reasoningEffort:"max",turns:[{status:"completed",startedAt:1,completedAt:2,failed:false}]}]}')"
codex_evidence="$(delegation_evidence_from_envelope codex attempt-1 01a07eb4-da4f-70e2-b282-4079106da2e5 <<< "$codex_envelope")"
[[ "$codex_evidence" == "$(jq -nc --argjson child "$codex_child" '{attemptId:"attempt-1",parentId:"01a07eb4-da4f-70e2-b282-4079106da2e5",children:[$child],modelHistory:{}}')" ]]
if delegation_evidence_from_envelope codex attempt-1 other-parent <<< "$codex_envelope" 2>/dev/null; then echo 'FAIL: unbound Codex envelope accepted' >&2; exit 1; fi
if delegation_evidence_from_envelope deepseek attempt-1 parent-1 <<< "$codex_envelope" 2>/dev/null; then echo 'FAIL: unsupported provider accepted' >&2; exit 1; fi
# The pieces compose into one request without any runner involvement.
composed="$(jq -nc --argjson requested "$(delegation_requested_settings <<< "$step")" --argjson evidence "$codex_evidence" '{issue:37,stepId:"multi-axis-pr-review",attemptId:"attempt-1",provider:"codex",policy:"pr-review-v1",requested:$requested,providerFailed:false,evidence:$evidence}' | delegation_manifest_build)"
[[ "$(jq -c '[.evidenceLevel,.mismatchCodes,.observed,.parentId]' <<< "$composed")" == '["UNVERIFIED",["TASK_MISSING"],{"startedCount":1,"completedCount":1,"selectedCount":1},"01a07eb4-da4f-70e2-b282-4079106da2e5"]' ]]
echo 'delegation_manifest_test.sh passed'
