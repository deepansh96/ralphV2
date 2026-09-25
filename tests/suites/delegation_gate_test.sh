#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

# End-to-end gate checks through `ralph.sh --issue N` with fake Claude, Codex
# (exec plus App Server), and gh binaries. Expected manifests are hand-authored
# from the #37 contract, never produced by the implementation under test.

GATE_BIN="$WORKSPACES_DIR/fake-bin"
QA_DIGEST="sha256:20c0036e0e890c2de1d1b4ee23aa561cb6f6436ab765f0e0c25d60b8f5c73fb7"
QA_HEX="${QA_DIGEST#sha256:}"
PR_TASKS='["matt_standards","matt_spec","ponytail","isolated_codex","supe"]'

install_gate_fakes() {
  local bin="$1"

  rm -rf "$bin"
  mkdir -p "$bin"
  printf '{}\n' > "$bin/threads.json"
  printf '{}\n' > "$bin/scenario.json"

  cat > "$bin/codex" <<FAKE
#!/usr/bin/env bash
set -euo pipefail
RALPH_ROOT="$ROOT_DIR"
FAKE
  cat >> "$bin/codex" <<'FAKE'
dir="$(cd "$(dirname "$0")" && pwd)"
mode=""
for arg in "$@"; do
  case "$arg" in exec|app-server) mode="$arg"; break ;; esac
done
if [[ "$mode" == app-server ]]; then
  exec node "$dir/app-server.cjs" "$dir/threads.json"
fi
[[ "$mode" == exec ]] || exit 99
prompt="$(cat)"
source "$dir/fake-common.sh"
fake_begin codex "$prompt"
parent="$(jq -r '.parent // "parent-unused"' <<< "$scenario")"
jq --arg parent "$parent" --argjson workers "$(jq -c '.workers // []' <<< "$scenario")" \
  '.[$parent] = $workers' "$dir/threads.json" > "$dir/threads.tmp"
mv "$dir/threads.tmp" "$dir/threads.json"
[[ "$parent" == parent-unused ]] || printf '{"type":"thread.started","thread_id":"%s"}\n' "$parent"
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":13,"output_tokens":8}}'
fake_finish
FAKE
  chmod +x "$bin/codex"

  cat > "$bin/claude" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"
prompt="" settings="" session="" agents="" forward=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    --settings) settings="$2"; shift 2 ;;
    --session-id) session="$2"; shift 2 ;;
    --agents) agents="$2"; shift 2 ;;
    --forward-subagent-text) forward=true; shift ;;
    *) shift ;;
  esac
done
source "$dir/fake-common.sh"
fake_begin claude "$prompt"
hook() {
  local command
  command="$(jq -r --arg event "$1" '.hooks[$event][0].hooks[0].command' "$settings")"
  jq -c --arg event "$1" --arg session "$session" '. + {hook_event_name: $event, session_id: $session}' <<< "$2" | bash -c "$command"
}
if [[ -n "$settings" ]]; then
  while IFS= read -r worker; do
    task="$(jq -r .task <<< "$worker")"
    run="$(jq -r '.run // 1' <<< "$worker")"
    tool="tool-$task-$run"
    child="child-$task-$run"
    packet="$(jq -r '"RALPH-TASK: \(.task)\n" + (if .digest then "RALPH-ASSIGNMENT: \(.digest)\n" else "" end) + "RALPH-RUN: \(.run // 1)\nSECRET packet"' <<< "$worker")"
    hook PreToolUse "$(jq -nc --arg tool "$tool" --arg packet "$packet" '{tool_name:"Agent",tool_use_id:$tool,tool_input:{subagent_type:"ralph-worker",prompt:$packet}}')"
    if jq -e '.badHook' <<< "$worker" >/dev/null; then
      hook PreToolUse '{"tool_name":"Agent","agent_id":"bad/id"}' || true
    fi
    hook SubagentStart "$(jq -nc --arg child "$child" '{agent_id:$child,agent_type:"ralph-worker"}')"
    hook SubagentStop "$(jq -c --arg child "$child" '{agent_id:$child,agent_type:"ralph-worker",last_assistant_message:"SECRET"} + (if .effort then {effort:{level:.effort}} else {} end)' <<< "$worker")"
    hook PostToolUse "$(jq -c --arg tool "$tool" --arg child "$child" '{tool_name:"Agent",tool_use_id:$tool,tool_response:{agentId:$child,status:(.outcome // "completed"),resolvedModel:.model,modelsUsed:[.model],content:"SECRET"}}' <<< "$worker")"
  done < <(jq -c '.workers // [] | .[]' <<< "$scenario")
fi
printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
printf '%s\n' '{"type":"result","subtype":"success","result":"done","duration_ms":5,"usage":{"input_tokens":3,"output_tokens":2},"total_cost_usd":0.01}'
fake_finish
FAKE
  chmod +x "$bin/claude"

  # Shared by both fakes: pick this invocation's scenario, record what the
  # provider observed at launch, run the QA parent's real plan helper, block.
  cat > "$bin/fake-common.sh" <<FAKE
RALPH_ROOT="$ROOT_DIR"
FAKE
  cat >> "$bin/fake-common.sh" <<'FAKE'
fake_begin() {
  local provider="$1" prompt="$2" n attempt manifest
  step="$(awk '/^Step:/ { print $2; exit }' <<< "$prompt")"
  workspace="$(awk '/^Workspace:/ { print $2; exit }' <<< "$prompt")"
  repo="$(awk '/^Repo:/ { print $2; exit }' <<< "$prompt")"
  printf '%s\n' "$step" >> "$dir/calls"
  n="$(grep -cx -- "$step" "$dir/calls")"
  scenario="$(jq -c --arg step "$step" --argjson n "$n" '(.[$step] // [])[$n - 1] // {}' "$dir/scenario.json")"
  attempt="$(jq -c --arg step "$step" 'first(.steps[] | select(.id == $step)) | .delegationAttempt // null' "$workspace/state.json")"
  manifest="$(jq -r '.attemptId' "$workspace/delegation/$step.manifest.json" 2>/dev/null || true)"
  jq -nc --arg provider "$provider" --arg step "$step" --argjson n "$n" --argjson attempt "$attempt" \
    --arg manifest "$manifest" --arg settings "${settings:-}" --arg session "${session:-}" \
    --arg agents "${agents:-}" --arg forward "${forward:-false}" --arg background "${CLAUDE_CODE_DISABLE_BACKGROUND_TASKS:-}" \
    --arg prompt "$prompt" \
    '{provider:$provider,step:$step,n:$n,attempt:$attempt,manifestAttempt:$manifest,settings:$settings,
      session:$session,agents:$agents,forward:($forward == "true"),background:$background,
      agentContract:($prompt | contains("subagent_type: ralph-worker")),
      hitlResume:($prompt | contains("## HITL Resume"))}' >> "$dir/observed.jsonl"
  if jq -e '.qa' <<< "$scenario" >/dev/null; then
    # shellcheck source=/dev/null
    source "$RALPH_ROOT/scripts/delegation-qa.sh"
    delegation_qa_plan_write "$workspace/state.json" "$step" "$repo" 123 \
      <<< '[{"taskId":"qa_group_1","checklistItemIds":["QA-01","QA-02"]}]' >/dev/null
  fi
  if jq -e '.blocked' <<< "$scenario" >/dev/null; then
    jq --arg step "$step" '.steps |= map(if .id == $step then .status = "blocked" else . end)' \
      "$workspace/state.json" > "$workspace/state.fake"
    mv "$workspace/state.fake" "$workspace/state.json"
  fi
}
fake_finish() {
  local status
  if jq -e '.interrupt' <<< "$scenario" >/dev/null; then
    kill -INT "$PPID"
  fi
  status="$(jq -r '.exit // 0' <<< "$scenario")"
  [[ "$status" == 0 ]] && return 0
  if jq -e '.retryable' <<< "$scenario" >/dev/null; then
    echo 'overloaded'
  fi
  exit "$status"
}
FAKE

  cat > "$bin/app-server.cjs" <<'FAKE'
const fs = require('node:fs');
const readline = require('node:readline');
const parents = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const turns = {
  completed: [{ id: 't', status: 'completed', startedAt: 1, completedAt: 2, error: null }],
  failed: [{ id: 't', status: 'failed', startedAt: 1, completedAt: 2, error: { message: 'SECRET' } }],
  incomplete: [{ id: 't', status: 'inProgress', startedAt: 1, completedAt: null, error: null }],
};
const threads = {};
for (const [parent, workers] of Object.entries(parents)) {
  for (const w of workers) {
    const id = `${parent}-${w.task}-r${w.run || 1}`;
    threads[id] = { parent, thread: { id, parentThreadId: parent, preview: 'SECRET',
      source: { subAgent: { thread_spawn: { parent_thread_id: parent, depth: 1, agent_path: `/root/${w.name || w.task}` } } },
      model: w.model ?? null, reasoningEffort: w.effort ?? null, turns: turns[w.outcome || 'completed'] } };
  }
}
const reply = (id, body) => process.stdout.write(JSON.stringify({ id, ...body }) + '\n');
readline.createInterface({ input: process.stdin }).on('line', line => {
  const m = JSON.parse(line);
  if (m.id === undefined) return;
  if (m.method === 'initialize') return reply(m.id, { result: {} });
  if (m.method === 'thread/list') {
    const parent = m.params.parentThreadId ?? m.params.ancestorThreadId;
    const data = Object.values(threads).filter(t => t.parent === parent).map(t => ({ ...t.thread, turns: [] }));
    return reply(m.id, { result: { data, nextCursor: null } });
  }
  if (m.method === 'thread/read') {
    const t = threads[m.params.threadId];
    return t ? reply(m.id, { result: { thread: t.thread } }) : reply(m.id, { error: { code: -32602, message: 'missing' } });
  }
  reply(m.id, { error: { code: -32601, message: 'unsupported' } });
});
FAKE

  jq -n --rawfile body /dev/stdin '{id:123,updated_at:"2026-09-25T10:00:00Z",body:$body}' > "$bin/comment.json" <<'MD'
<!-- ralph:qa-checklist -->
## Local QA Checklist

- [ ] [PENDING] QA-01: First check instruction
- [ ] [PENDING] QA-02: Second check instruction
MD
  cat > "$bin/pi" <<'FAKE'
#!/usr/bin/env bash
printf 'pi\n' >> "$(cd "$(dirname "$0")" && pwd)/calls"
exit 0
FAKE
  chmod +x "$bin/pi"

  cat > "$bin/gh" <<'FAKE'
#!/usr/bin/env bash
dir="$(cd "$(dirname "$0")" && pwd)"
[[ "$1" == api && "$2" == repos/deepansh96/ralph/issues/comments/123 ]] || exit 1
cat "$dir/comment.json"
FAKE
  chmod +x "$bin/gh"
}

# State: a completed preflight, the given steps, and always-run cleanup.
# STEPS is a JSON array of partial step objects merged over the agent defaults.
write_gate_state() {
  local issue="$1" agent="$2" steps="$3"

  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n --argjson issue "$issue" --arg agent "$agent" --argjson steps "$steps" --arg root "$ROOT_DIR" '
    ({claude: {model:"opus",reasoningEffort:"medium",subagentModel:"claude-sonnet-5",subagentReasoningEffort:"high"},
      codex: {model:"gpt-5.6-sol",reasoningEffort:"medium",subagentModel:"gpt-5.6-luna",subagentReasoningEffort:"max"}}[$agent]
      // {model:"deepseek-v4-flash",reasoningEffort:"high",subagentModel:"deepseek-v4-flash",subagentReasoningEffort:"high"}) as $settings
    | {issue:$issue, repo:"deepansh96/ralph", projectRoot:$root, baseBranch:"main", branch:"feat/issue-\($issue)-fixture",
       steps: ([{id:"preflight",type:"preflight",agent:"codex",status:"completed",metrics:{},notes:""}]
         + ($steps | map({phase:"dynamic",type:.id,status:"pending",agent:$agent,reviewers:[],hitl:false,metrics:null,notes:""} + $settings + .))
         + [{id:"cleanup-local-resources",phase:"fixed",type:"cleanup-local-resources",status:"pending",agent:"codex",
             reviewers:[],hitl:false,alwaysRun:true,metrics:null,notes:""}])}
  ' > "$WORKSPACES_DIR/$issue/state.json"
}

pr_workers() {
  jq -nc --argjson tasks "$PR_TASKS" --arg model "${1:-}" --arg effort "${2:-}" \
    '$tasks | map({task:., outcome:"completed"} + (if $model == "" then {} else {model:$model,effort:$effort} end))'
}

# Hand-authored manifest child from the #37 child record plus disposition.
expected_child() {
  jq -nc --arg id "$1" --arg parent "$2" --arg task "$3" --argjson digest "$4" --argjson effective "$5" \
    '{childId:$id,parentId:$parent,taskId:$task,run:1,assignmentDigest:$digest,started:true,completed:true,
      outcome:"completed",effective:$effective,nested:false,disposition:"selected"}'
}

state_step() {
  jq -c --arg id "$2" 'first(.steps[] | select(.id == $id))' "$WORKSPACES_DIR/$1/state.json"
}

manifest_file() {
  printf '%s/%s/delegation/%s.manifest.json\n' "$WORKSPACES_DIR" "$1" "$2"
}

run_ralph() {
  local issue="$1"
  set +e
  RUN_OUTPUT="$(PATH="$GATE_BIN:$PATH" "$RALPH" --issue "$issue" 2>&1)"
  RUN_STATUS=$?
  set -e
}

assert_no_attempt_inputs() {
  [[ -z "$(find "$WORKSPACES_DIR/$1" -name 'ralph-delegation-*' -print -quit)" ]] \
    || fail "expected per-invocation delegation inputs to be removed"
}

assert_file_mode_600() {
  node -e 'process.exit((require("fs").statSync(process.argv[1]).mode & 0o777) === 0o600 ? 0 : 1)' "$1" \
    || fail "expected mode 0600: $1"
}

test_codex_fixture_passes_pr_review_and_qa_and_completes() {
  local issue=9056 attempt manifest expected children

  write_valid_context
  install_gate_fakes "$GATE_BIN"
  write_gate_state "$issue" codex '[
    {"id":"runthrough-qa-checklist","delegation":{"schemaVersion":1,"policy":"qa-v1"}},
    {"id":"multi-axis-pr-review","delegation":{"schemaVersion":1,"policy":"pr-review-v1"}}]'
  jq -n --argjson pr "$(pr_workers)" --arg name "qa_r1_$QA_HEX" '{
    "runthrough-qa-checklist": [{parent:"parent-q",qa:true,workers:[{task:"qa_group_1",name:$name,outcome:"completed",model:"gpt-5.6-luna",effort:"max"}]}],
    "multi-axis-pr-review": [{parent:"parent-r",workers:$pr}]}' > "$GATE_BIN/scenario.json"

  run_ralph "$issue"
  [[ "$RUN_STATUS" -eq 0 ]] || fail "expected gated Codex run to pass: $RUN_OUTPUT"
  [[ "$(jq -r '[.steps[].status] | join(",")' "$WORKSPACES_DIR/$issue/state.json")" == "completed,completed,completed,completed" ]] \
    || fail "expected all steps completed: $(jq -c '[.steps[].status]' "$WORKSPACES_DIR/$issue/state.json")"

  # QA: one planned assignment, provider-exposed worker settings -> VERIFIED.
  attempt="$(state_step "$issue" runthrough-qa-checklist | jq -r '.delegationAttempt.id')"
  [[ -n "$attempt" && "$attempt" != null ]] || fail "expected QA attempt in State"
  manifest="$(manifest_file "$issue" runthrough-qa-checklist)"
  assert_file_mode_600 "$manifest"
  children="[$(expected_child parent-q-qa_group_1-r1 parent-q qa_group_1 "\"$QA_DIGEST\"" '{"model":"gpt-5.6-luna","reasoningEffort":"max"}')]"
  expected="$(jq -nc --arg attempt "$attempt" --argjson children "$children" '{schemaVersion:1,issue:9056,stepId:"runthrough-qa-checklist",attemptId:$attempt,
    provider:"codex",evidenceSource:"app-server",parentId:"parent-q",policy:"qa-v1",
    requested:{parent:{model:"gpt-5.6-sol",reasoningEffort:"medium"},worker:{model:"gpt-5.6-luna",reasoningEffort:"max"}},
    expected:{taskCount:1,taskIds:["qa_group_1"]},observed:{startedCount:1,completedCount:1,selectedCount:1},
    children:$children,evidenceLevel:"VERIFIED",mismatchCodes:[]}')"
  [[ "$(<"$manifest")" == "$expected" ]] || fail "unexpected QA manifest: $(<"$manifest")"

  # PR review: five flat workers without exposed settings -> OBSERVED passes.
  attempt="$(state_step "$issue" multi-axis-pr-review | jq -r '.delegationAttempt.id')"
  manifest="$(manifest_file "$issue" multi-axis-pr-review)"
  children="$(for task in isolated_codex matt_spec matt_standards ponytail supe; do
    expected_child "parent-r-$task-r1" parent-r "$task" null '{"model":null,"reasoningEffort":null}'; done | jq -sc .)"
  expected="$(jq -nc --arg attempt "$attempt" --argjson children "$children" '{schemaVersion:1,issue:9056,stepId:"multi-axis-pr-review",attemptId:$attempt,
    provider:"codex",evidenceSource:"app-server",parentId:"parent-r",policy:"pr-review-v1",
    requested:{parent:{model:"gpt-5.6-sol",reasoningEffort:"medium"},worker:{model:"gpt-5.6-luna",reasoningEffort:"max"}},
    expected:{taskCount:5,taskIds:["isolated_codex","matt_spec","matt_standards","ponytail","supe"]},
    observed:{startedCount:5,completedCount:5,selectedCount:5},children:$children,evidenceLevel:"OBSERVED",mismatchCodes:[]}')"
  [[ "$(<"$manifest")" == "$expected" ]] || fail "unexpected PR manifest: $(<"$manifest")"
  if grep -q SECRET "$manifest"; then fail "manifest leaked provider text"; fi

  # The attempt is stamped before launch and is what the provider saw.
  [[ "$(jq -r 'select(.step == "multi-axis-pr-review") | .attempt.id' "$GATE_BIN/observed.jsonl")" == "$attempt" ]] \
    || fail "expected provider to launch under the stamped attempt"
  assert_no_attempt_inputs "$issue"
}

test_claude_fixture_passes_pr_review_and_qa_with_session_local_worker() {
  local issue=9057 attempt session manifest expected children observed

  write_valid_context
  install_gate_fakes "$GATE_BIN"
  write_gate_state "$issue" claude '[
    {"id":"runthrough-qa-checklist","delegation":{"schemaVersion":1,"policy":"qa-v1"}},
    {"id":"multi-axis-pr-review","delegation":{"schemaVersion":1,"policy":"pr-review-v1"}}]'
  jq -n --argjson pr "$(pr_workers claude-sonnet-5 high)" --arg digest "$QA_DIGEST" '{
    "runthrough-qa-checklist": [{qa:true,workers:[{task:"qa_group_1",digest:$digest,outcome:"completed",model:"claude-sonnet-5"}]}],
    "multi-axis-pr-review": [{workers:$pr}]}' > "$GATE_BIN/scenario.json"

  run_ralph "$issue"
  [[ "$RUN_STATUS" -eq 0 ]] || fail "expected gated Claude run to pass: $RUN_OUTPUT"
  [[ "$(jq -r '[.steps[].status] | join(",")' "$WORKSPACES_DIR/$issue/state.json")" == "completed,completed,completed,completed" ]] \
    || fail "expected all steps completed"

  # The parent got the session-local worker, temporary hooks, forwarded
  # worker text, a fresh session, foreground-only Agent, and Agent instructions.
  observed="$(jq -c 'select(.step == "multi-axis-pr-review")' "$GATE_BIN/observed.jsonl")"
  jq -e '.forward and .background == "1" and .agentContract and (.settings | endswith("/settings.json")) and (.session | length > 0)
    and (.agents | fromjson | .["ralph-worker"] | .model == "claude-sonnet-5" and .effort == "high" and .disallowedTools == ["Agent","Workflow"])' \
    <<< "$observed" >/dev/null || fail "unexpected gated Claude invocation: $observed"
  session="$(jq -r '.session' <<< "$observed")"

  # PR review: canonical model and effort exposed for every worker -> VERIFIED.
  attempt="$(state_step "$issue" multi-axis-pr-review | jq -r '.delegationAttempt.id')"
  manifest="$(manifest_file "$issue" multi-axis-pr-review)"
  children="$(for task in isolated_codex matt_spec matt_standards ponytail supe; do
    expected_child "child-$task-1" "$session" "$task" null '{"model":"claude-sonnet-5","reasoningEffort":"high"}'; done | jq -sc .)"
  expected="$(jq -nc --arg attempt "$attempt" --arg session "$session" --argjson children "$children" '{schemaVersion:1,issue:9057,stepId:"multi-axis-pr-review",attemptId:$attempt,
    provider:"claude",evidenceSource:"hooks",parentId:$session,policy:"pr-review-v1",
    requested:{parent:{model:"opus",reasoningEffort:"medium"},worker:{model:"claude-sonnet-5",reasoningEffort:"high"}},
    expected:{taskCount:5,taskIds:["isolated_codex","matt_spec","matt_standards","ponytail","supe"]},
    observed:{startedCount:5,completedCount:5,selectedCount:5},children:$children,evidenceLevel:"VERIFIED",mismatchCodes:[]}')"
  [[ "$(<"$manifest")" == "$expected" ]] || fail "unexpected Claude PR manifest: $(<"$manifest")"

  # QA: effort not exposed by SubagentStop -> OBSERVED, which still passes.
  manifest="$(manifest_file "$issue" runthrough-qa-checklist)"
  [[ "$(jq -c '[.evidenceLevel,.mismatchCodes,.expected,.observed,(.children | map([.taskId,.assignmentDigest,.effective.reasoningEffort]))]' "$manifest")" \
    == "[\"OBSERVED\",[],{\"taskCount\":1,\"taskIds\":[\"qa_group_1\"]},{\"startedCount\":1,\"completedCount\":1,\"selectedCount\":1},[[\"qa_group_1\",\"$QA_DIGEST\",null]]]" ]] \
    || fail "unexpected Claude QA manifest: $(<"$manifest")"
  if grep -rq SECRET "$WORKSPACES_DIR/$issue/delegation"; then fail "delegation artifacts leaked provider text"; fi
  assert_no_attempt_inputs "$issue"
}

assert_cleanup_ran() {
  grep -qx cleanup-local-resources "$GATE_BIN/calls" || fail "expected always-run cleanup to run"
  [[ "$(state_step "$1" cleanup-local-resources | jq -r .status)" == completed ]] || fail "expected cleanup completed"
}

test_verifier_failure_writes_unverified_manifest_and_fails_step() {
  local issue=9058 attempt manifest children expected

  write_valid_context
  install_gate_fakes "$GATE_BIN"
  write_gate_state "$issue" codex '[{"id":"multi-axis-pr-review","delegation":{"schemaVersion":1,"policy":"pr-review-v1"}}]'
  jq -n --argjson pr "$(pr_workers | jq -c 'map(select(.task != "supe"))')" \
    '{"multi-axis-pr-review": [{parent:"parent-v",workers:$pr}]}' > "$GATE_BIN/scenario.json"

  run_ralph "$issue"
  [[ "$RUN_STATUS" -eq 1 ]] || fail "expected verifier failure to exit 1, got $RUN_STATUS: $RUN_OUTPUT"
  [[ "$(state_step "$issue" multi-axis-pr-review | jq -r .status)" == failed ]] || fail "expected gated step failed"
  assert_contains "$RUN_OUTPUT" "UNVERIFIED TASK_MISSING"
  attempt="$(state_step "$issue" multi-axis-pr-review | jq -r '.delegationAttempt.id')"
  manifest="$(manifest_file "$issue" multi-axis-pr-review)"
  children="$(for task in isolated_codex matt_spec matt_standards ponytail; do
    expected_child "parent-v-$task-r1" parent-v "$task" null '{"model":null,"reasoningEffort":null}'; done | jq -sc .)"
  expected="$(jq -nc --arg attempt "$attempt" --argjson children "$children" '{schemaVersion:1,issue:9058,stepId:"multi-axis-pr-review",attemptId:$attempt,
    provider:"codex",evidenceSource:"app-server",parentId:"parent-v",policy:"pr-review-v1",
    requested:{parent:{model:"gpt-5.6-sol",reasoningEffort:"medium"},worker:{model:"gpt-5.6-luna",reasoningEffort:"max"}},
    expected:{taskCount:5,taskIds:["isolated_codex","matt_spec","matt_standards","ponytail","supe"]},
    observed:{startedCount:4,completedCount:4,selectedCount:4},children:$children,evidenceLevel:"UNVERIFIED",mismatchCodes:["TASK_MISSING"]}')"
  [[ "$(<"$manifest")" == "$expected" ]] || fail "unexpected UNVERIFIED manifest: $(<"$manifest")"
  assert_file_mode_600 "$manifest"
  assert_cleanup_ran "$issue"
  assert_no_attempt_inputs "$issue"
}

test_provider_failure_writes_provider_failed_manifest_before_failing() {
  local issue=9059 manifest

  write_valid_context
  install_gate_fakes "$GATE_BIN"
  write_gate_state "$issue" codex '[{"id":"multi-axis-pr-review","delegation":{"schemaVersion":1,"policy":"pr-review-v1"}}]'
  jq -n --argjson pr "$(pr_workers | jq -c '.[0:2]')" \
    '{"multi-axis-pr-review": [{parent:"parent-f",exit:3,workers:$pr}]}' > "$GATE_BIN/scenario.json"

  run_ralph "$issue"
  [[ "$RUN_STATUS" -eq 1 ]] || fail "expected provider failure to exit 1: $RUN_OUTPUT"
  [[ "$(state_step "$issue" multi-axis-pr-review | jq -r .status)" == failed ]] || fail "expected gated step failed"
  [[ "$(grep -cx multi-axis-pr-review "$GATE_BIN/calls")" == 1 ]] || fail "expected a non-retryable failure to run once"
  manifest="$(manifest_file "$issue" multi-axis-pr-review)"
  # Safe partial evidence from the failed parent is kept for audit.
  [[ "$(jq -c '[.parentId,.evidenceLevel,.mismatchCodes,.observed,(.children | map(.taskId))]' "$manifest")" \
    == '["parent-f","UNVERIFIED",["PROVIDER_FAILED","TASK_MISSING"],{"startedCount":2,"completedCount":2,"selectedCount":2},["matt_spec","matt_standards"]]' ]] \
    || fail "unexpected provider-failure manifest: $(<"$manifest")"
  assert_cleanup_ran "$issue"
  assert_no_attempt_inputs "$issue"
}

test_retry_stamps_fresh_attempt_and_only_final_parent_counts() {
  local issue=9060 first second manifest

  write_valid_context
  install_gate_fakes "$GATE_BIN"
  write_gate_state "$issue" codex '[{"id":"multi-axis-pr-review","delegation":{"schemaVersion":1,"policy":"pr-review-v1"}}]'
  # The first parent spawns all five workers, then fails retryably; the
  # retried parent spawns none. The first parent's workers are not proof.
  jq -n --argjson pr "$(pr_workers gpt-5.6-luna max)" '{"multi-axis-pr-review": [
    {parent:"parent-a",exit:1,retryable:true,workers:$pr}, {parent:"parent-b",workers:[]}]}' > "$GATE_BIN/scenario.json"

  run_ralph "$issue"
  [[ "$RUN_STATUS" -eq 1 ]] || fail "expected retried parent without workers to fail: $RUN_OUTPUT"
  first="$(jq -c 'select(.step == "multi-axis-pr-review" and .n == 1)' "$GATE_BIN/observed.jsonl")"
  second="$(jq -c 'select(.step == "multi-axis-pr-review" and .n == 2)' "$GATE_BIN/observed.jsonl")"
  [[ -n "$second" ]] || fail "expected an internal retry"
  [[ "$(jq -r .attempt.id <<< "$first")" != "$(jq -r .attempt.id <<< "$second")" ]] || fail "expected a fresh attempt per invocation"
  # While the retry ran, the only manifest on disk belonged to the failed
  # invocation, so it could not look current against State.
  [[ "$(jq -r .manifestAttempt <<< "$second")" == "$(jq -r .attempt.id <<< "$first")" ]] \
    || fail "expected the failed invocation's UNVERIFIED manifest during the retry"
  manifest="$(manifest_file "$issue" multi-axis-pr-review)"
  [[ "$(jq -r .attemptId "$manifest")" == "$(state_step "$issue" multi-axis-pr-review | jq -r .delegationAttempt.id)" ]] \
    || fail "expected State to keep the final attempt"
  [[ "$(jq -r .attemptId "$manifest")" == "$(jq -r .attempt.id <<< "$second")" ]] || fail "expected the manifest replaced by the final attempt"
  [[ "$(jq -c '[.parentId,.mismatchCodes,.children]' "$manifest")" == '["parent-b",["TASK_MISSING"],[]]' ]] \
    || fail "expected only the final parent's evidence: $(<"$manifest")"
  [[ -f "$WORKSPACES_DIR/$issue/logs/multi-axis-pr-review.log.attempt-1" ]] || fail "expected the failed log archived"
  assert_no_attempt_inputs "$issue"

  # Same failure, but the retried parent supplies its own passing proof.
  issue=9061
  install_gate_fakes "$GATE_BIN"
  write_gate_state "$issue" codex '[{"id":"multi-axis-pr-review","delegation":{"schemaVersion":1,"policy":"pr-review-v1"}}]'
  jq -n --argjson pr "$(pr_workers gpt-5.6-luna max)" '{"multi-axis-pr-review": [
    {parent:"parent-a",exit:1,retryable:true,workers:$pr}, {parent:"parent-b",workers:$pr}]}' > "$GATE_BIN/scenario.json"
  run_ralph "$issue"
  [[ "$RUN_STATUS" -eq 0 ]] || fail "expected retried parent with its own workers to pass: $RUN_OUTPUT"
  manifest="$(manifest_file "$issue" multi-axis-pr-review)"
  [[ "$(jq -c '[.parentId,.evidenceLevel,(.children | map(.parentId) | unique)]' "$manifest")" == '["parent-b","VERIFIED",["parent-b"]]' ]] \
    || fail "expected VERIFIED evidence from the final parent only: $(<"$manifest")"
  [[ "$(state_step "$issue" multi-axis-pr-review | jq -r .status)" == completed ]] || fail "expected completion"
}

test_hitl_block_defers_manifest_and_resume_uses_fresh_attempt() {
  local issue=9062 first second manifest flag

  write_valid_context
  install_gate_fakes "$GATE_BIN"
  write_gate_state "$issue" claude '[{"id":"multi-axis-pr-review","delegation":{"schemaVersion":1,"policy":"pr-review-v1"}}]'
  jq -n --argjson pr "$(pr_workers claude-sonnet-5 high)" '{"multi-axis-pr-review": [
    {blocked:true,workers:($pr | .[0:2])}, {workers:$pr}]}' > "$GATE_BIN/scenario.json"

  run_ralph "$issue"
  [[ "$RUN_STATUS" -eq 0 ]] || fail "expected a blocked run to exit 0: $RUN_OUTPUT"
  assert_contains "$RUN_OUTPUT" "is blocked for human input"
  [[ "$(state_step "$issue" multi-axis-pr-review | jq -r .status)" == blocked ]] || fail "expected blocked step"
  [[ ! -e "$(manifest_file "$issue" multi-axis-pr-review)" ]] || fail "blocked run must not finalize a manifest"
  assert_no_attempt_inputs "$issue"

  flag="$WORKSPACES_DIR/$issue/hitl-multi-axis-pr-review.md"
  printf '# Questions\n\n## Answers\nProceed.\n' > "$flag"
  run_ralph "$issue"
  [[ "$RUN_STATUS" -eq 0 ]] || fail "expected resumed run to pass: $RUN_OUTPUT"
  first="$(jq -c 'select(.step == "multi-axis-pr-review" and .n == 1)' "$GATE_BIN/observed.jsonl")"
  second="$(jq -c 'select(.step == "multi-axis-pr-review" and .n == 2)' "$GATE_BIN/observed.jsonl")"
  jq -e '.hitlResume' <<< "$second" >/dev/null || fail "expected resume answers in the rerendered prompt"
  [[ "$(jq -r .attempt.id <<< "$first")" != "$(jq -r .attempt.id <<< "$second")" ]] || fail "expected a fresh attempt on resume"
  [[ "$(jq -r .session <<< "$first")" != "$(jq -r .session <<< "$second")" ]] || fail "expected a fresh parent session on resume"
  [[ "$(jq -r .settings <<< "$first")" != "$(jq -r .settings <<< "$second")" ]] || fail "expected fresh hook inputs on resume"
  manifest="$(manifest_file "$issue" multi-axis-pr-review)"
  [[ "$(jq -c --arg a "$(jq -r .attempt.id <<< "$second")" --arg p "$(jq -r .session <<< "$second")" \
    '[.attemptId == $a, .parentId == $p, .evidenceLevel, .observed.completedCount]' "$manifest")" == '[true,true,"VERIFIED",5]' ]] \
    || fail "expected resumed evidence only: $(<"$manifest")"
  [[ "$(state_step "$issue" multi-axis-pr-review | jq -r .status)" == completed ]] || fail "expected completion after resume"
}

test_configuration_errors_fail_closed_before_launch() {
  local issue=9063 agent override

  write_valid_context
  while IFS=$'\t' read -r agent override; do
    install_gate_fakes "$GATE_BIN"
    write_gate_state "$issue" "$agent" "$(jq -nc --argjson override "$override" '[{id:"multi-axis-pr-review"} + $override]')"
    run_ralph "$issue"
    [[ "$RUN_STATUS" -eq 1 ]] || fail "expected fail-closed exit for $agent $override: $RUN_OUTPUT"
    [[ "$(state_step "$issue" multi-axis-pr-review | jq -r .status)" == failed ]] || fail "expected failed step for $override"
    if grep -qx -e multi-axis-pr-review -e pi "$GATE_BIN/calls"; then fail "provider launched despite $agent $override"; fi
    [[ ! -e "$WORKSPACES_DIR/$issue/delegation" ]] || fail "no manifest may be claimed for $override"
    assert_cleanup_ran "$issue"
    assert_no_attempt_inputs "$issue"
  done <<'CASES'
codex	{"delegation":{"schemaVersion":1,"policy":"deploy-v1"}}
codex	{"delegation":{"schemaVersion":2,"policy":"pr-review-v1"}}
codex	{"delegation":null}
codex	{"delegation":{"schemaVersion":1,"policy":"pr-review-v1","extra":true}}
deepseek	{"delegation":{"schemaVersion":1,"policy":"pr-review-v1"}}
codex	{"delegation":{"schemaVersion":1,"policy":"pr-review-v1"},"subagentModel":null}
claude	{"delegation":{"schemaVersion":1,"policy":"qa-v1"},"subagentReasoningEffort":""}
CASES
}

test_artifact_errors_fail_closed() {
  local issue=9064 manifest

  # A rejected hook record makes Claude evidence unavailable, never zero work.
  write_valid_context
  install_gate_fakes "$GATE_BIN"
  write_gate_state "$issue" claude '[{"id":"multi-axis-pr-review","delegation":{"schemaVersion":1,"policy":"pr-review-v1"}}]'
  jq -n --argjson pr "$(pr_workers claude-sonnet-5 high | jq -c '.[0].badHook = true')" \
    '{"multi-axis-pr-review": [{workers:$pr}]}' > "$GATE_BIN/scenario.json"
  run_ralph "$issue"
  [[ "$RUN_STATUS" -eq 1 ]] || fail "expected unavailable evidence to fail: $RUN_OUTPUT"
  manifest="$(manifest_file "$issue" multi-axis-pr-review)"
  [[ "$(jq -c '[.evidenceLevel,.mismatchCodes,.children]' "$manifest")" == '["UNVERIFIED",["EVIDENCE_UNAVAILABLE"],[]]' ]] \
    || fail "unexpected unavailable-evidence manifest: $(<"$manifest")"
  [[ "$(state_step "$issue" multi-axis-pr-review | jq -r .status)" == failed ]] || fail "expected failed step"
  assert_no_attempt_inputs "$issue"

  # Unwritable manifest storage fails the step without pretending a manifest exists.
  issue=9065
  install_gate_fakes "$GATE_BIN"
  write_gate_state "$issue" codex '[{"id":"multi-axis-pr-review","delegation":{"schemaVersion":1,"policy":"pr-review-v1"}}]'
  printf 'not a directory\n' > "$WORKSPACES_DIR/$issue/delegation"
  jq -n --argjson pr "$(pr_workers gpt-5.6-luna max)" '{"multi-axis-pr-review": [{parent:"parent-w",workers:$pr}]}' > "$GATE_BIN/scenario.json"
  run_ralph "$issue"
  [[ "$RUN_STATUS" -eq 1 ]] || fail "expected manifest write failure to fail: $RUN_OUTPUT"
  assert_contains "$RUN_OUTPUT" "MANIFEST_WRITE_FAILED"
  [[ "$(state_step "$issue" multi-axis-pr-review | jq -r .status)" == failed ]] || fail "expected failed step"
  [[ "$(<"$WORKSPACES_DIR/$issue/delegation")" == "not a directory" ]] || fail "expected no manifest to be claimed"
  assert_cleanup_ran "$issue"
}

test_interrupt_resets_step_and_removes_attempt_inputs() {
  local issue=9066

  write_valid_context
  install_gate_fakes "$GATE_BIN"
  write_gate_state "$issue" claude '[{"id":"multi-axis-pr-review","delegation":{"schemaVersion":1,"policy":"pr-review-v1"}}]'
  jq -n '{"multi-axis-pr-review": [{interrupt:true,workers:[]}]}' > "$GATE_BIN/scenario.json"
  run_ralph "$issue"
  [[ "$RUN_STATUS" -eq 0 ]] || fail "expected interrupt handler to exit cleanly: $RUN_OUTPUT"
  [[ "$(state_step "$issue" multi-axis-pr-review | jq -r .status)" == pending ]] || fail "expected interrupted step pending"
  [[ ! -e "$(manifest_file "$issue" multi-axis-pr-review)" ]] || fail "interrupted run must not finalize a manifest"
  assert_no_attempt_inputs "$issue"
}

test_steps_without_metadata_keep_legacy_behavior() {
  local issue=9056 observed before after

  write_valid_context
  install_gate_fakes "$GATE_BIN"
  write_gate_state "$issue" claude '[
    {"id":"old-review","type":"multi-axis-pr-review","status":"completed","delegation":{"schemaVersion":1,"policy":"pr-review-v1"}},
    {"id":"multi-axis-pr-review"}]'
  before="$(state_step "$issue" old-review)"
  run_ralph "$issue"
  [[ "$RUN_STATUS" -eq 0 ]] || fail "expected legacy run to pass: $RUN_OUTPUT"
  observed="$(jq -c 'select(.step == "multi-axis-pr-review")' "$GATE_BIN/observed.jsonl")"
  jq -e '.settings == "" and .session == "" and .agents == "" and (.forward | not) and .background == "" and (.agentContract | not) and .attempt == null' \
    <<< "$observed" >/dev/null || fail "legacy step received gated inputs: $observed"
  state_step "$issue" multi-axis-pr-review | jq -e '.status == "completed" and (has("delegationAttempt") | not)' >/dev/null \
    || fail "expected legacy completion without an attempt"
  # A completed step is never rechecked, even when it carries metadata.
  after="$(state_step "$issue" old-review)"
  [[ "$before" == "$after" ]] || fail "completed step changed: $after"
  [[ ! -e "$WORKSPACES_DIR/$issue/delegation" ]] || fail "legacy steps must not write manifests"
  assert_cleanup_ran "$issue"
}

run_test test_codex_fixture_passes_pr_review_and_qa_and_completes
run_test test_claude_fixture_passes_pr_review_and_qa_with_session_local_worker
run_test test_verifier_failure_writes_unverified_manifest_and_fails_step
run_test test_provider_failure_writes_provider_failed_manifest_before_failing
run_test test_retry_stamps_fresh_attempt_and_only_final_parent_counts
run_test test_hitl_block_defers_manifest_and_resume_uses_fresh_attempt
run_test test_configuration_errors_fail_closed_before_launch
run_test test_artifact_errors_fail_closed
run_test test_interrupt_resets_step_and_removes_attempt_inputs
run_test test_steps_without_metadata_keep_legacy_behavior
