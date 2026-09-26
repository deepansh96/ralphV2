#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

# `ralph status` delegation output through the CLI seam. Manifests, hook events,
# App Server pages, and expected lines are hand-written from the #37 contract.
# Every fixture carries SECRET-marked prompts, IDs, paths, and commands that
# must never reach the output.

FORBIDDEN=(SECRET toolu_ attempt- parent- child- /tmp "RALPH-TASK" "{" "}" matt_ qa_ "rm -rf" "[cmd]" "[tool]" "[text]")

assert_no_leaks() {
  local output="$1" needle
  for needle in "${FORBIDDEN[@]}"; do
    [[ "$output" != *"$needle"* ]] || fail "status leaked '$needle': $output"
  done
}

# Lines after the "Current activity" header, which carries only step, agent, elapsed.
activity_of() {
  sed -n '/^--- Current activity/,$p' <<< "$1" | tail -n +2
}

# A hand-written manifest in the #41 shape with rich opaque values.
write_manifest() {
  local workspace="$1" step="$2" attempt="$3" level="$4" selected="$5" expected="$6"
  mkdir -p "$workspace/delegation"
  jq -n --arg step "$step" --arg attempt "$attempt" --arg level "$level" \
    --argjson selected "$selected" --argjson expected "$expected" '{
      schemaVersion: 1, issue: 9067, stepId: $step, attemptId: $attempt,
      provider: "codex", evidenceSource: "app-server", parentId: "parent-SECRET-thread",
      policy: "pr-review-v1",
      requested: {parent: {model: "gpt-5.6-sol", reasoningEffort: "medium"}, worker: {model: "gpt-5.6-luna", reasoningEffort: "max"}},
      expected: {taskCount: $expected, taskIds: ["isolated_codex","matt_spec","matt_standards","ponytail","supe"][:$expected]},
      observed: {startedCount: $selected, completedCount: $selected, selectedCount: $selected},
      children: [range($selected) | {childId: "child-SECRET-\(.)", parentId: "parent-SECRET-thread", taskId: "matt_spec",
        run: 1, assignmentDigest: null, started: true, completed: true, outcome: "completed", startedAt: 1, endedAt: 2,
        effective: {model: "gpt-5.6-luna", reasoningEffort: "max"}, nested: false, disposition: "selected"}],
      evidenceLevel: $level, mismatchCodes: (if $selected < $expected then ["CHILD_MISSING","TASK_MISSING"] else [] end)
    }' > "$workspace/delegation/$step.manifest.json"
  chmod 600 "$workspace/delegation/$step.manifest.json"
}

gated_step() {
  jq -nc --arg id "$1" --arg type "$2" --arg agent "$3" --arg status "$4" --arg attempt "$5" --arg policy "$6" \
    '{id:$id,type:$type,agent:$agent,status:$status,metrics:{duration:"4m 2s"},notes:"",
      model:"gpt-5.6-sol",reasoningEffort:"medium",subagentModel:"gpt-5.6-luna",subagentReasoningEffort:"max",
      delegation:{schemaVersion:1,policy:$policy},delegationAttempt:{id:$attempt,startedAt:1787590000}}'
}

test_terminal_steps_show_one_manifest_only_summary() {
  local issue=9067 workspace output expected
  workspace="$WORKSPACES_DIR/$issue"
  rm -rf "$workspace"
  mkdir -p "$workspace/logs"
  jq -n --argjson issue "$issue" \
    --argjson review "$(gated_step multi-axis-pr-review multi-axis-pr-review codex completed attempt-SECRET-review pr-review-v1)" \
    --argjson qa "$(gated_step runthrough-qa-checklist runthrough-qa-checklist claude failed attempt-SECRET-qa qa-v1)" \
    --argjson verified "$(gated_step verified-review multi-axis-pr-review claude completed attempt-SECRET-verified pr-review-v1)" \
    --argjson stale "$(gated_step stale-review multi-axis-pr-review codex completed attempt-SECRET-new pr-review-v1)" \
    --argjson missing "$(gated_step missing-review multi-axis-pr-review codex completed attempt-SECRET-missing pr-review-v1)" \
    '{issue:$issue,steps:[
      {id:"legacy-step",type:"implement-slice",agent:"codex",status:"completed",metrics:{duration:"1m 5s"},notes:""},
      $review,$qa,$verified,$stale,$missing,
      {id:"cleanup-local-resources",type:"cleanup-local-resources",agent:"codex",status:"pending",alwaysRun:true,metrics:{},notes:""}]}' \
    > "$workspace/state.json"
  write_manifest "$workspace" multi-axis-pr-review attempt-SECRET-review OBSERVED 5 5
  # A missing child keeps the denominator from expected.taskCount.
  write_manifest "$workspace" runthrough-qa-checklist attempt-SECRET-qa UNVERIFIED 1 2
  write_manifest "$workspace" verified-review attempt-SECRET-verified VERIFIED 5 5
  # A manifest from an earlier attempt is never current for this State attempt.
  write_manifest "$workspace" stale-review attempt-SECRET-old OBSERVED 5 5
  # A legacy step never shows delegation output, even beside a manifest file.
  write_manifest "$workspace" legacy-step attempt-SECRET-legacy OBSERVED 5 5

  # Trailing column padding is pre-existing table formatting; compare without it.
  output="$("$RALPH" status --issue "$issue" | sed 's/ *$//')"

  expected="$(cat <<'EXPECTED'
#    Step ID                  Type               Agent      Status       Duration   Process
1    legacy-step              implement-slice    codex      completed    1m 5s      -
2    multi-axis-pr-review     multi-axis-pr-review codex      completed    4m 2s      -
     Delegation: OBSERVED 5/5
3    runthrough-qa-checklist  runthrough-qa-checklist claude     failed       -          -
     Delegation: UNVERIFIED 1/2
4    verified-review          multi-axis-pr-review claude     completed    4m 2s      -
     Delegation: VERIFIED 5/5
5    stale-review             multi-axis-pr-review codex      completed    4m 2s      -
6    missing-review           multi-axis-pr-review codex      completed    4m 2s      -
7    cleanup-local-resources  cleanup-local-resources codex      pending      -          -
EXPECTED
)"
  [[ "$output" == "$expected" ]] || fail "unexpected status output:
$output"
  assert_no_leaks "$output"
}

test_summary_ignores_mutable_qa_plan() {
  local issue=9068 workspace output
  workspace="$WORKSPACES_DIR/$issue"
  rm -rf "$workspace"
  mkdir -p "$workspace/logs"
  jq -n --argjson issue "$issue" \
    --argjson qa "$(gated_step runthrough-qa-checklist runthrough-qa-checklist codex completed attempt-SECRET-qa qa-v1)" \
    '{issue:$issue,steps:[$qa]}' > "$workspace/state.json"
  write_manifest "$workspace" runthrough-qa-checklist attempt-SECRET-qa OBSERVED 2 2
  # The plan may later be rewritten; status counts come only from the manifest.
  printf '{"assignments":[{"taskId":"qa_SECRET_1"},{"taskId":"qa_SECRET_2"},{"taskId":"qa_SECRET_3"}]}\n' \
    > "$workspace/delegation/runthrough-qa-checklist.plan.json"

  output="$("$RALPH" status --issue "$issue")"

  [[ "$(grep -c 'Delegation:' <<< "$output")" == 1 ]] || fail "expected one summary: $output"
  assert_contains "$output" "     Delegation: OBSERVED 2/2"
  assert_no_leaks "$output"
}

# A gated in-progress Claude step with this attempt's sanitized hook events.
write_claude_live() {
  local workspace="$1" state_attempt="$2" context_attempt="$3" inputs claude
  inputs="$workspace/ralph-delegation-$context_attempt"
  claude="$inputs/ralph-37-claude-SECRET"
  mkdir -p "$claude"
  printf '%s\n' "$claude" > "$inputs/claude-inputs"
  printf 'parent-SECRET-session\n' > "$inputs/parent"
  jq -nc --arg attempt "$context_attempt" \
    '{attempt:$attempt,parent:"parent-SECRET-session",requested:{model:"sonnet",reasoningEffort:"high"}}' > "$claude/context.json"
  cat > "$claude/events.jsonl" <<'EVENTS'
{"event":"PreToolUse","tool_use_id":"toolu_SECRET_1","agent_id":null,"subagent_type":"ralph-worker","model":null,"taskId":"matt_spec","assignmentDigest":null,"run":1}
{"event":"PreToolUse","tool_use_id":"toolu_SECRET_2","agent_id":null,"subagent_type":"ralph-worker","model":null,"taskId":"ponytail","assignmentDigest":null,"run":1}
{"event":"SubagentStart","agent_id":"child-SECRET-1","agent_type":"ralph-worker"}
{"event":"SubagentStart","agent_id":"child-SECRET-2","agent_type":"ralph-worker"}
{"event":"SubagentStop","agent_id":"child-SECRET-1","agent_type":"ralph-worker","status":null,"effort":{"level":"high"}}
{"event":"PostToolUse","tool_use_id":"toolu_SECRET_1","agentId":"child-SECRET-1","status":"completed","resolvedModel":"claude-sonnet-5","modelsUsed":["claude-sonnet-5"]}
EVENTS
  jq -n --argjson issue "$(basename "$workspace")" --arg attempt "$state_attempt" --argjson started "$(date +%s)" --argjson pid "$$" '
    {issue:$issue,steps:[{id:"multi-axis-pr-review",type:"multi-axis-pr-review",agent:"claude",status:"in_progress",
      started_at:$started,pid:$pid,metrics:{},notes:"",model:"sonnet",reasoningEffort:"high",subagentModel:"sonnet",subagentReasoningEffort:"high",
      delegation:{schemaVersion:1,policy:"pr-review-v1"},delegationAttempt:{id:$attempt,startedAt:$started}}]}' > "$workspace/state.json"
  mkdir -p "$workspace/pids"
  printf '%s\n' "$$" > "$workspace/pids/multi-axis-pr-review.pid"
  # The parent's own stream holds prompts, tool arguments, and commands.
  cat > "$workspace/logs/multi-axis-pr-review.log" <<'LOG'
{"type":"assistant","message":{"content":[{"type":"text","text":"SECRET plan text"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"prompt":"RALPH-TASK: matt_spec SECRET prompt","subagent_type":"ralph-worker"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"rm -rf /tmp/SECRET"}}]}}
LOG
}

test_in_progress_claude_shows_safe_live_activity() {
  local issue=9069 workspace output
  workspace="$WORKSPACES_DIR/$issue"
  rm -rf "$workspace"
  mkdir -p "$workspace/logs"
  write_claude_live "$workspace" attempt-SECRET-live attempt-SECRET-live

  output="$("$RALPH" status --issue "$issue")"

  assert_contains "$output" "--- Current activity (multi-axis-pr-review · claude · "
  [[ "$(activity_of "$output")" == "$(printf '%s\n' '[delegation] child started' '[delegation] child started' '[delegation] child completed')" ]] \
    || fail "unexpected Claude activity: $output"
  [[ "$output" != *"Delegation:"* ]] || fail "in-progress step must not show a summary: $output"
  assert_no_leaks "$output"
}

test_in_progress_claude_ignores_stale_attempt_events() {
  local issue=9070 workspace output
  workspace="$WORKSPACES_DIR/$issue"
  rm -rf "$workspace"
  mkdir -p "$workspace/logs"
  # Hook inputs left by an earlier attempt are never read for the current one.
  write_claude_live "$workspace" attempt-SECRET-current attempt-SECRET-old

  output="$("$RALPH" status --issue "$issue")"

  assert_contains "$output" "--- Current activity (multi-axis-pr-review · claude · "
  [[ -z "$(activity_of "$output")" ]] || fail "stale attempt produced activity: $output"
  assert_no_leaks "$output"

  # A current-attempt directory whose hook context names another attempt is also unbound.
  mv "$workspace/ralph-delegation-attempt-SECRET-old" "$workspace/ralph-delegation-attempt-SECRET-current"
  output="$("$RALPH" status --issue "$issue")"
  [[ -z "$(activity_of "$output")" ]] || fail "unbound hook context produced activity: $output"
}

write_codex_live() {
  local workspace="$1" fake_bin="$2" started="$3" fixture
  fixture="$fake_bin/fixture.json"
  mkdir -p "$fake_bin"
  thread() { jq -nc --arg id "$1" --arg parent "$2" --argjson depth "$3" --arg task "$4" --argjson turns "$5" '{id:$id,parentThreadId:$parent,source:{subAgent:{thread_spawn:{parent_thread_id:$parent,depth:$depth,agent_path:("/root/" + $task),agent_nickname:"SECRET",agent_role:null}}},model:"gpt-5.6-luna",reasoningEffort:"max",preview:"SECRET prompt",cwd:"/tmp/SECRET",path:"/tmp/SECRET/rollout.jsonl",turns:$turns}'; }
  jq -n \
    --argjson a "$(thread child-SECRET-a parent-SECRET-thread 1 matt_spec '[{"id":"t1","status":"completed","startedAt":1,"completedAt":2,"error":null,"items":[]}]')" \
    --argjson b "$(thread child-SECRET-b parent-SECRET-thread 1 ponytail '[{"id":"t2","status":"inProgress","startedAt":3,"completedAt":null,"error":null,"items":[]}]')" \
    --argjson c "$(thread child-SECRET-c parent-SECRET-thread 1 supe '[]')" \
    --argjson d "$(thread child-SECRET-d child-SECRET-a 2 helper '[{"id":"t3","status":"completed","startedAt":1,"completedAt":2,"error":null,"items":[]}]')" \
    '{parent:"parent-SECRET-thread",
      direct:[{ids:["child-SECRET-a","child-SECRET-b","child-SECRET-c"],nextCursor:null}],
      descendants:[{ids:["child-SECRET-a","child-SECRET-b","child-SECRET-c","child-SECRET-d"],nextCursor:null}],
      threads:{"child-SECRET-a":$a,"child-SECRET-b":$b,"child-SECRET-c":$c,"child-SECRET-d":$d}}' > "$fixture"
  install_fake_codex_app_server "$fake_bin" "$fixture"
  jq -n --argjson issue "$(basename "$workspace")" --argjson started "$started" --argjson pid "$$" '
    {issue:$issue,steps:[{id:"runthrough-qa-checklist",type:"runthrough-qa-checklist",agent:"codex",status:"in_progress",
      started_at:$started,pid:$pid,metrics:{},notes:"",model:"gpt-5.6-sol",reasoningEffort:"medium",subagentModel:"gpt-5.6-luna",subagentReasoningEffort:"max",
      delegation:{schemaVersion:1,policy:"qa-v1"},delegationAttempt:{id:"attempt-SECRET-codex",startedAt:$started}}]}' > "$workspace/state.json"
  mkdir -p "$workspace/pids"
  printf '%s\n' "$$" > "$workspace/pids/runthrough-qa-checklist.pid"
  cat > "$workspace/logs/runthrough-qa-checklist.log" <<'LOG'
{"type":"thread.started","thread_id":"parent-SECRET-thread"}
{"type":"item.completed","item":{"type":"command_execution","command":"rm -rf /tmp/SECRET"}}
{"type":"item.completed","item":{"type":"agent_message","text":"SECRET agent message"}}
LOG
}

test_in_progress_codex_shows_safe_live_activity() {
  local issue=9071 workspace fake_bin output
  workspace="$WORKSPACES_DIR/$issue"
  fake_bin="$workspace/fake-bin"
  rm -rf "$workspace"
  mkdir -p "$workspace/logs"
  write_codex_live "$workspace" "$fake_bin" "$(( $(date +%s) - 5 ))"

  output="$(PATH="$fake_bin:$PATH" "$RALPH" status --issue "$issue")"

  assert_contains "$output" "--- Current activity (runthrough-qa-checklist · codex · "
  # Direct children only: two have started, one has completed; nested work is not a child.
  [[ "$(activity_of "$output")" == "$(printf '%s\n' '[delegation] child started' '[delegation] child started' '[delegation] child completed')" ]] \
    || fail "unexpected Codex activity: $output"
  assert_no_leaks "$output"
}

test_in_progress_codex_without_current_facts_shows_nothing() {
  local issue=9072 workspace fake_bin output
  workspace="$WORKSPACES_DIR/$issue"
  fake_bin="$workspace/fake-bin"
  rm -rf "$workspace"
  mkdir -p "$workspace/logs"
  # The log predates this attempt, so its parent belongs to an earlier invocation.
  write_codex_live "$workspace" "$fake_bin" "$(( $(date +%s) + 3600 ))"
  jq '.steps[0].started_at = (now | floor)' "$workspace/state.json" > "$workspace/state.tmp" && mv "$workspace/state.tmp" "$workspace/state.json"

  output="$(PATH="$fake_bin:$PATH" "$RALPH" status --issue "$issue")"
  [[ -z "$(activity_of "$output")" ]] || fail "stale Codex log produced activity: $output"
  assert_no_leaks "$output"

  # An unavailable App Server is best-effort silence, not a status failure.
  write_codex_live "$workspace" "$fake_bin" "$(( $(date +%s) - 5 ))"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fake_bin/codex"
  output="$(PATH="$fake_bin:$PATH" "$RALPH" status --issue "$issue")"
  [[ -z "$(activity_of "$output")" ]] || fail "unavailable App Server produced activity: $output"
  assert_no_leaks "$output"
}

test_legacy_in_progress_activity_is_unchanged() {
  local issue=9073 workspace output
  workspace="$WORKSPACES_DIR/$issue"
  rm -rf "$workspace"
  mkdir -p "$workspace/logs" "$workspace/pids"
  jq -n --argjson issue "$issue" --argjson started "$(date +%s)" --argjson pid "$$" \
    '{issue:$issue,steps:[{id:"implement-slice-42",type:"implement-slice",agent:"codex",status:"in_progress",started_at:$started,pid:$pid,metrics:{},notes:""}]}' \
    > "$workspace/state.json"
  printf '%s\n' "$$" > "$workspace/pids/implement-slice-42.pid"
  printf '%s\n' '{"type":"item.completed","item":{"type":"command_execution","command":"npm test"}}' > "$workspace/logs/implement-slice-42.log"

  output="$("$RALPH" status --issue "$issue")"

  [[ "$(activity_of "$output")" == "[cmd] npm test" ]] || fail "legacy activity changed: $output"
  [[ "$output" != *"[delegation]"* && "$output" != *"Delegation:"* ]] || fail "legacy step showed delegation: $output"
}

run_test test_terminal_steps_show_one_manifest_only_summary
run_test test_summary_ignores_mutable_qa_plan
run_test test_in_progress_claude_shows_safe_live_activity
run_test test_in_progress_claude_ignores_stale_attempt_events
run_test test_in_progress_codex_shows_safe_live_activity
run_test test_in_progress_codex_without_current_facts_shows_nothing
run_test test_legacy_in_progress_activity_is_unchanged

echo "status_delegation_test.sh passed"
