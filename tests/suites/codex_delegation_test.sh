#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/tests/lib/test_helpers.sh"
source "$ROOT/scripts/codex-delegation.sh"
workspace="$(mktemp -d "${TMPDIR:-/tmp}/ralph-37-codex.XXXXXX")"
trap 'cleanup; rm -rf "$workspace"' EXIT

# The current attempt's parent is the supported thread.started record of its exec log.
printf '%s\n' '{"type":"thread.started","thread_id":"01a07eb4-da4f-70e2-b282-4079106da2e5"}' '{"type":"turn.started"}' '{"type":"item.completed","item":{"type":"agent_message","text":"SECRET"}}' > "$workspace/step.log"
[[ "$(codex_delegation_parent_id "$workspace/step.log")" == 01a07eb4-da4f-70e2-b282-4079106da2e5 ]]
# Missing, duplicated, malformed, or non-JSON records never yield a guessed parent.
printf '%s\n' '{"type":"turn.started"}' > "$workspace/none.log"
printf '%s\n' '{"type":"thread.started","thread_id":"a"}' '{"type":"thread.started","thread_id":"b"}' > "$workspace/two.log"
printf '%s\n' '{"type":"thread.started","thread_id":"../SECRET"}' > "$workspace/bad.log"
printf '%s\n' 'not json' '{"type":"thread.started","thread_id":"a"}' > "$workspace/broken.log"
for log in none two bad broken missing; do
  if codex_delegation_parent_id "$workspace/$log.log" 2>/dev/null; then echo "FAIL: $log accepted" >&2; exit 1; fi
done
# Sanitized App Server facts normalize into the shared #39 child record.
parent=01a07eb4-da4f-70e2-b282-4079106da2e5
facts='{"parentId":"01a07eb4-da4f-70e2-b282-4079106da2e5","threads":[
{"id":"child-1","parentId":"01a07eb4-da4f-70e2-b282-4079106da2e5","direct":true,"depth":1,"spawnParent":"01a07eb4-da4f-70e2-b282-4079106da2e5","task":"matt_spec","model":"gpt-5.6-luna","reasoningEffort":"max",
 "turns":[{"status":"completed","startedAt":1786897497,"completedAt":1786897863,"failed":false}]}
]}'
expected_child='[{"childId":"child-1","parentId":"01a07eb4-da4f-70e2-b282-4079106da2e5","taskId":"matt_spec","run":1,"assignmentDigest":null,"started":true,"completed":true,"outcome":"completed","effective":{"model":"gpt-5.6-luna","reasoningEffort":"max"},"nested":false}]'
[[ "$(codex_delegation_normalize "$parent" <<< "$facts")" == "$expected_child" ]]
# Lifecycle comes only from turns[].status and error: a child is complete when it has a turn,
# all turns are terminal, the final turn completed, and none failed.
outcome_of() { jq -c --argjson turns "$1" '.threads[0].turns = $turns' <<< "$facts" | codex_delegation_normalize "$parent" | jq -c '.[0] | [.started,.completed,.outcome]'; }
[[ "$(outcome_of '[]')" == '[false,false,"incomplete"]' ]]
[[ "$(outcome_of '[{"status":"inProgress","startedAt":1,"completedAt":null,"failed":false}]')" == '[true,false,"incomplete"]' ]]
[[ "$(outcome_of '[{"status":"completed","startedAt":1,"completedAt":2,"failed":false},{"status":"inProgress","startedAt":3,"completedAt":null,"failed":false}]')" == '[true,false,"incomplete"]' ]]
[[ "$(outcome_of '[{"status":"failed","startedAt":1,"completedAt":2,"failed":true}]')" == '[true,false,"failed"]' ]]
[[ "$(outcome_of '[{"status":"failed","startedAt":1,"completedAt":2,"failed":true},{"status":"completed","startedAt":3,"completedAt":4,"failed":false}]')" == '[true,false,"failed"]' ]]
[[ "$(outcome_of '[{"status":"completed","startedAt":1,"completedAt":2,"failed":true}]')" == '[true,false,"failed"]' ]]
[[ "$(outcome_of '[{"status":"interrupted","startedAt":1,"completedAt":null,"failed":false}]')" == '[true,false,"stopped"]' ]]
[[ "$(outcome_of '[{"status":"completed","startedAt":null,"completedAt":2,"failed":false},{"status":"interrupted","startedAt":3,"completedAt":null,"failed":false},{"status":"completed","startedAt":4,"completedAt":5,"failed":false}]')" == '[true,true,"completed"]' ]]
[[ "$(outcome_of '[{"status":"unknown-provider-status","startedAt":1,"completedAt":2,"failed":false}]')" == '[true,false,"incomplete"]' ]]
# Effective settings stay null when App Server does not expose them.
[[ "$(jq -c 'del(.threads[0].model, .threads[0].reasoningEffort)' <<< "$facts" | codex_delegation_normalize "$parent" | jq -c '.[0].effective')" == '{"model":null,"reasoningEffort":null}' ]]
# Descendants below a direct child are nested workers with their real parent.
nested="$(jq -c '.threads += [{"id":"grandchild","parentId":"child-1","direct":false,"depth":2,"spawnParent":"child-1","task":"helper","model":null,"reasoningEffort":null,"turns":[{"status":"completed","startedAt":1,"completedAt":2,"failed":false}]}]' <<< "$facts")"
[[ "$(codex_delegation_normalize "$parent" <<< "$nested" | jq -c 'map([.childId,.parentId,.taskId,.nested])')" == '[["grandchild","child-1","helper",true],["child-1","01a07eb4-da4f-70e2-b282-4079106da2e5","matt_spec",false]]' ]]
# Task identity: exact PR-review names map directly; QA names bind through the plan digest.
digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf '%s\n' '{"schemaVersion":1,"stepId":"runthrough-qa-checklist","attemptId":"attempt-1","checklist":{"commentId":"123","updatedAt":"2026-08-25T10:00:00Z","digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","items":[{"id":"QA-01","text":"First check instruction"}]},"assignments":[{"taskId":"qa_group_1","checklistItemIds":["QA-01"],"assignmentDigest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}' > "$workspace/plan.json"
qa="$(jq -c '.threads[0].task = "qa_r2_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' <<< "$facts")"
[[ "$(codex_delegation_normalize "$parent" "$workspace/plan.json" <<< "$qa" | jq -c '.[0] | [.taskId,.run,.assignmentDigest]')" == '["qa_group_1",2,"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]' ]]
# Without a matching assignment the provider name is kept verbatim for the verifier; nothing is guessed.
[[ "$(codex_delegation_normalize "$parent" <<< "$qa" | jq -c '.[0] | [.taskId,.run,.assignmentDigest]')" == '["qa_r2_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",2,"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]' ]]
[[ "$(jq -c '.threads[0].task = "verify_codex_iv_large"' <<< "$facts" | codex_delegation_normalize "$parent" | jq -r '.[0].taskId')" == verify_codex_iv_large ]]
if codex_delegation_normalize "$parent" "$workspace/step.log" <<< "$qa" 2>/dev/null; then echo 'FAIL: invalid plan accepted' >&2; exit 1; fi
# Fail closed: wrong attempt parent, unfiltered or misbound direct children, orphans, duplicates,
# unidentifiable tasks, and malformed turns are unavailable evidence, never zero workers.
for mutation in '.parentId = "other-parent"' '.threads[0].parentId = "other-parent"' '.threads[0].spawnParent = "other-parent"' '.threads[0].depth = 2' \
  '.threads += [{"id":"orphan","parentId":"unknown","direct":false,"depth":2,"spawnParent":"unknown","task":"helper","model":null,"reasoningEffort":null,"turns":[]}]' \
  '.threads += [.threads[0]]' '.threads[0].task = null' '.threads[0].task = "Bad-Name"' '.threads[0].turns = null' '.threads[0].id = null'; do
  if jq "$mutation" <<< "$facts" | codex_delegation_normalize "$parent" >/dev/null 2>&1; then echo "FAIL: accepted $mutation" >&2; exit 1; fi
done
if codex_delegation_normalize other-parent <<< "$facts" >/dev/null 2>&1; then echo 'FAIL: parent mismatch accepted' >&2; exit 1; fi
# CLI seam: a fresh fake App Server serves hand-written pages; only supported reads are issued.
fake_bin="$workspace/bin"
fixture="$workspace/fixture.json"
thread() { jq -nc --arg id "$1" --arg parent "$2" --argjson depth "$3" --arg task "$4" --argjson turns "$5" '{id:$id,parentThreadId:$parent,source:{subAgent:{thread_spawn:{parent_thread_id:$parent,depth:$depth,agent_path:("/root/" + $task),agent_nickname:"Volta",agent_role:null}}},model:"gpt-5.6-luna",reasoningEffort:"max",preview:"SECRET prompt",cwd:"/SECRET/cwd",path:"/SECRET/rollout.jsonl",name:"SECRET",gitInfo:{sha:"SECRET"},turns:$turns,status:{type:"notLoaded"},sessionId:"SECRET"}'; }
done_turn='[{"id":"turn-1","status":"completed","startedAt":1786897497,"completedAt":1786897863,"error":null,"items":[{"type":"agentMessage","text":"SECRET"}]}]'
jq -n --arg parent "$parent" \
  --argjson a "$(thread matt_standards "$parent" 1 matt_standards "$done_turn")" \
  --argjson b "$(thread matt_spec "$parent" 1 matt_spec "$done_turn")" \
  --argjson c "$(thread ponytail "$parent" 1 ponytail '[{"id":"turn-2","status":"failed","startedAt":1,"completedAt":2,"error":{"message":"SECRET failure"},"items":[]}]')" \
  --argjson d "$(thread helper matt_spec 2 helper '[]')" \
  '{parent:$parent, direct:[{ids:["matt_standards","matt_spec"],nextCursor:"cursor-1"},{ids:["ponytail"],nextCursor:null}],
    descendants:[{ids:["matt_standards","matt_spec","ponytail"],nextCursor:"cursor-2"},{ids:["helper"],nextCursor:null}],
    threads:{matt_standards:$a,matt_spec:$b,ponytail:$c,helper:$d}}' > "$fixture"
install_fake_codex_app_server "$fake_bin" "$fixture"
children="$(PATH="$fake_bin:$PATH" codex_delegation_collect "$parent")"
expected_children='[{"childId":"helper","parentId":"matt_spec","taskId":"helper","run":1,"assignmentDigest":null,"started":false,"completed":false,"outcome":"incomplete","effective":{"model":"gpt-5.6-luna","reasoningEffort":"max"},"nested":true},{"childId":"matt_spec","parentId":"01a07eb4-da4f-70e2-b282-4079106da2e5","taskId":"matt_spec","run":1,"assignmentDigest":null,"started":true,"completed":true,"outcome":"completed","effective":{"model":"gpt-5.6-luna","reasoningEffort":"max"},"nested":false},{"childId":"matt_standards","parentId":"01a07eb4-da4f-70e2-b282-4079106da2e5","taskId":"matt_standards","run":1,"assignmentDigest":null,"started":true,"completed":true,"outcome":"completed","effective":{"model":"gpt-5.6-luna","reasoningEffort":"max"},"nested":false},{"childId":"ponytail","parentId":"01a07eb4-da4f-70e2-b282-4079106da2e5","taskId":"ponytail","run":1,"assignmentDigest":null,"started":true,"completed":false,"outcome":"failed","effective":{"model":"gpt-5.6-luna","reasoningEffort":"max"},"nested":false}]'
[[ "$children" == "$expected_children" ]]
requests="$fake_bin/app-server-requests.jsonl"
[[ "$(jq -r '.method' "$requests" | head -1)" == initialize ]]
[[ "$(jq -c 'select(.method == "initialize") | .params' "$requests")" == '{"clientInfo":{"name":"ralph-codex-delegation","version":"1"},"capabilities":{"experimentalApi":true}}' ]]
[[ "$(jq -r '.method' "$requests" | sort -u | tr '\n' ' ')" == 'initialize initialized thread/list thread/read ' ]]
kinds='["subAgent","subAgentReview","subAgentCompact","subAgentThreadSpawn","subAgentOther"]'
[[ "$(jq -c 'select(.method == "thread/list") | .params' "$requests" | tr '\n' ' ')" == "{\"parentThreadId\":\"$parent\",\"sourceKinds\":$kinds,\"limit\":100} {\"parentThreadId\":\"$parent\",\"sourceKinds\":$kinds,\"limit\":100,\"cursor\":\"cursor-1\"} {\"ancestorThreadId\":\"$parent\",\"sourceKinds\":$kinds,\"limit\":100} {\"ancestorThreadId\":\"$parent\",\"sourceKinds\":$kinds,\"limit\":100,\"cursor\":\"cursor-2\"} " ]]
[[ "$(jq -c 'select(.method == "thread/read") | .params' "$requests" | sort | tr '\n' ' ')" == '{"threadId":"helper","includeTurns":true} {"threadId":"matt_spec","includeTurns":true} {"threadId":"matt_standards","includeTurns":true} {"threadId":"ponytail","includeTurns":true} ' ]]
if grep -q 'useStateDbOnly\|thread/items/list\|thread/start\|turn/start\|review/start' "$requests"; then echo 'FAIL: unsupported App Server usage' >&2; exit 1; fi
# Strict sanitization: the collector envelope keeps only allowlisted thread facts.
evidence="$(PATH="$fake_bin:$PATH" codex_delegation_evidence "$parent")"
if grep -q SECRET <<< "$evidence"; then echo 'FAIL: provider text leaked' >&2; exit 1; fi
jq -e --arg parent "$parent" --argjson children "$expected_children" '.parentId == $parent and .children == $children and (.threads | length == 4) and all(.threads[]; (keys - ["id","parentId","direct","depth","spawnParent","task","model","reasoningEffort","turns"] | length) == 0 and all(.turns[]; (keys - ["status","startedAt","completedAt","failed"] | length) == 0))' <<< "$evidence" >/dev/null
# A fresh App Server process resolves the parent recorded by an earlier exec invocation.
rm -f "$requests"
PATH="$fake_bin:$PATH" codex exec --json --output-last-message "$workspace/last.txt" - <<< 'prompt' > "$workspace/exec.log"
[[ "$(codex_delegation_parent_id "$workspace/exec.log")" == "$parent" ]]
[[ "$(PATH="$fake_bin:$PATH" codex_delegation_collect "$(codex_delegation_parent_id "$workspace/exec.log")" | jq -c 'map(.childId)')" == '["helper","matt_spec","matt_standards","ponytail"]' ]]
# The binary override seam is honored, and rollout files are never a source.
mkdir -p "$workspace/codex-home/sessions/2026/09/08"
printf '{"type":"session_meta","payload":{"id":"canary","parent":"%s"}}\n' "$parent" > "$workspace/codex-home/sessions/2026/09/08/rollout-canary.jsonl"
mkdir "$workspace/decoy"
printf '#!/usr/bin/env bash\nexit 99\n' > "$workspace/decoy/codex"
chmod +x "$workspace/decoy/codex"
[[ "$(CODEX_HOME="$workspace/codex-home" PATH="$workspace/decoy:$PATH" CODEX_BIN="$fake_bin/codex" codex_delegation_collect "$parent" | jq -c 'map(.childId)')" == '["helper","matt_spec","matt_standards","ponytail"]' ]]
# Unavailable server, rejected initialize, malformed pages, pagination failures, unreadable
# threads, and inconsistent listings are unavailable evidence, never zero or guessed workers.
if CODEX_BIN="$workspace/does-not-exist" codex_delegation_collect "$parent" >/dev/null 2>&1; then echo 'FAIL: missing binary accepted' >&2; exit 1; fi
if CODEX_BIN="$workspace/decoy/codex" codex_delegation_collect "$parent" >/dev/null 2>&1; then echo 'FAIL: exiting server accepted' >&2; exit 1; fi
for mutation in '.initialize = {error:{code:-32600,message:"rejected"}}' '.direct[1] = {malformed:true}' '.direct[1] = {error:{code:-32603,message:"boom"}}' '.descendants[1] = {error:{code:-32603,message:"boom"}}' '.reads = {ponytail:{error:{code:-32602,message:"unreadable"}}}' '.descendants = [{ids:["matt_standards"],nextCursor:null}]' 'del(.threads.helper)' '.threads.helper.parentThreadId = "unlisted"'; do
  jq "$mutation" "$fixture" > "$workspace/broken-fixture.json"
  install_fake_codex_app_server "$workspace/broken-bin" "$workspace/broken-fixture.json"
  if PATH="$workspace/broken-bin:$PATH" codex_delegation_collect "$parent" >/dev/null 2>&1; then echo "FAIL: accepted $mutation" >&2; exit 1; fi
done
# A parent with no children is an empty, well-formed collection.
jq '.direct = [{ids:[],nextCursor:null}] | .descendants = [{ids:[],nextCursor:null}]' "$fixture" > "$workspace/empty-fixture.json"
install_fake_codex_app_server "$workspace/empty-bin" "$workspace/empty-fixture.json"
[[ "$(PATH="$workspace/empty-bin:$PATH" codex_delegation_collect "$parent")" == '[]' ]]
[[ "$(PATH="$workspace/empty-bin:$PATH" codex_delegation_evidence "$parent" | jq -c '[.children,.threads]')" == '[[],[]]' ]]
# QA worker names bind through the plan on the CLI seam too.
jq --arg parent "$parent" '.threads.qa = (.threads.matt_spec | .id = "qa" | .source.subAgent.thread_spawn.agent_path = "/root/qa_r1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") | .direct = [{ids:["qa"],nextCursor:null}] | .descendants = [{ids:["qa"],nextCursor:null}]' "$fixture" > "$workspace/qa-fixture.json"
install_fake_codex_app_server "$workspace/qa-bin" "$workspace/qa-fixture.json"
[[ "$(PATH="$workspace/qa-bin:$PATH" codex_delegation_collect "$parent" "$workspace/plan.json" | jq -c '.[0] | [.taskId,.run,.assignmentDigest,.completed]')" == '["qa_group_1",1,"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",true]' ]]
echo 'Codex collection behavior and isolation checks passed'
