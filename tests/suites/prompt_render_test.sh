#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

test_prompt_render_replaces_all_supported_placeholders() {
  local issue workspace state_file template_file prompt

  issue="9046"
  workspace="$WORKSPACES_DIR/$issue"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$workspace"
  state_file="$workspace/state.json"
  template_file="$workspace/template.md"

  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      branch: "feat/issue-9046-render",
      baseBranch: "grill/issue-9046-render"
    }' > "$state_file"

  cat > "$template_file" <<'TEMPLATE'
Issue={{ISSUE}}
Repo={{REPO}}
Workspace={{WORKSPACE}}
Branch={{BRANCH}}
Base={{BASE_BRANCH}}
Step={{STEP_ID}}
Sub={{SUB_ISSUE}}
Skills={{SKILLS_DIR}}
Reviewers={{REVIEWERS}}
Agent={{AGENT}}
TEMPLATE

  source "$ROOT_DIR/scripts/prompt.sh"
  prompt="$(
    prompt_render \
      "$template_file" \
      "$state_file" \
      "$workspace" \
      '{"id":"render-step","sub_issue":1234,"reviewers":["codex","gemini"],"agent":"codex"}' \
      "$ROOT_DIR/skills"
  )"

  assert_contains "$prompt" "Issue=9046"
  assert_contains "$prompt" "Repo=deepansh96/ralph"
  assert_contains "$prompt" "Workspace=$workspace"
  assert_contains "$prompt" "Branch=feat/issue-9046-render"
  assert_contains "$prompt" "Base=grill/issue-9046-render"
  assert_contains "$prompt" "Step=render-step"
  assert_contains "$prompt" "Sub=1234"
  assert_contains "$prompt" "Skills=$ROOT_DIR/skills"
  assert_contains "$prompt" "Reviewers=codex,gemini"
  assert_contains "$prompt" "Agent=codex"
}

test_prompt_render_fails_when_template_is_missing() {
  local issue workspace state_file output status

  issue="9047"
  workspace="$WORKSPACES_DIR/$issue"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$workspace"
  state_file="$workspace/state.json"
  jq -n '{issue: 9047}' > "$state_file"

  source "$ROOT_DIR/scripts/prompt.sh"

  set +e
  output="$(prompt_render "$workspace/missing.md" "$state_file" "$workspace" '{"id":"missing"}' "$ROOT_DIR/skills" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected missing template render to fail with 1, got $status"
  assert_contains "$output" "prompt template not found"
  assert_contains "$output" "$workspace/missing.md"
}

test_prompt_render_injects_codex_native_delegation_contract() {
  local issue workspace state_file prompt

  issue="9048"
  workspace="$WORKSPACES_DIR/$issue"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$workspace"
  state_file="$workspace/state.json"
  jq -n '{issue: 9048}' > "$state_file"

  source "$ROOT_DIR/scripts/prompt.sh"
  prompt="$(
    prompt_render \
      "$ROOT_DIR/prompts/multi-axis-pr-review.md" \
      "$state_file" \
      "$workspace" \
      '{"id":"multi-axis-pr-review","agent":"codex"}' \
      "$ROOT_DIR/skills"
  )"

  assert_contains "$prompt" "Native Delegation Contract — Codex"
  assert_contains "$prompt" 'model: `gpt-5.6-luna`'
  assert_contains "$prompt" '`reasoning_effort`: `max`'
  assert_contains "$prompt" 'fork_turns: "none"'
  assert_contains "$prompt" "omit any of these values"
  assert_contains "$prompt" "spawn exactly one Matt review coordinator"
  assert_contains "$prompt" "Standards and Spec reviewers in"
  [[ "$prompt" != *'{{NATIVE_DELEGATION_CONTRACT}}'* ]] || fail "expected delegation placeholder to be rendered"
  [[ "$prompt" != *"Claude Code's native Agent tool"* ]] || fail "expected only the Codex delegation contract"
}

test_prompt_render_injects_claude_native_delegation_contract() {
  local issue workspace state_file prompt

  issue="9049"
  workspace="$WORKSPACES_DIR/$issue"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$workspace"
  state_file="$workspace/state.json"
  jq -n '{issue: 9049}' > "$state_file"

  source "$ROOT_DIR/scripts/prompt.sh"
  prompt="$(
    prompt_render \
      "$ROOT_DIR/prompts/multi-axis-pr-review.md" \
      "$state_file" \
      "$workspace" \
      '{"id":"multi-axis-pr-review","agent":"claude"}' \
      "$ROOT_DIR/skills"
  )"

  assert_contains "$prompt" "Native Delegation Contract — Claude Code"
  assert_contains "$prompt" "native dynamic Workflow tool"
  assert_contains "$prompt" 'workflow `agent()` call'
  assert_contains "$prompt" 'model: `sonnet`'
  assert_contains "$prompt" 'effort: `high`'
  assert_contains "$prompt" '`Promise.all`'
  assert_contains "$prompt" "plain Agent tool cannot set effort"
  assert_contains "$prompt" 'all five workflow `agent()` calls'
  assert_contains "$prompt" "Matt skill's Standards axis"
  assert_contains "$prompt" "its Spec axis"
  [[ "$prompt" != *"gpt-5.6-luna"* ]] || fail "expected only the Claude delegation contract"
}

test_prompt_render_rejects_unconfigured_native_delegation_agent() {
  local issue workspace state_file output status

  issue="9050"
  workspace="$WORKSPACES_DIR/$issue"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$workspace"
  state_file="$workspace/state.json"
  jq -n '{issue: 9050}' > "$state_file"

  source "$ROOT_DIR/scripts/prompt.sh"
  set +e
  output="$(
    prompt_render \
      "$ROOT_DIR/prompts/multi-axis-pr-review.md" \
      "$state_file" \
      "$workspace" \
      '{"id":"multi-axis-pr-review","agent":"deepseek"}' \
      "$ROOT_DIR/skills" 2>&1
  )"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected unconfigured delegation agent to fail with 1, got $status"
  assert_contains "$output" "native delegation is not configured for agent 'deepseek'"
}

run_test test_prompt_render_replaces_all_supported_placeholders
run_test test_prompt_render_fails_when_template_is_missing
run_test test_prompt_render_injects_codex_native_delegation_contract
run_test test_prompt_render_injects_claude_native_delegation_contract
run_test test_prompt_render_rejects_unconfigured_native_delegation_agent

echo "prompt_render_test.sh passed"
