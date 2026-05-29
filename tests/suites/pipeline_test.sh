#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

test_run_completes_pending_agent_step() {
  local issue status_value log_file fake_bin

  issue="9003"
  write_valid_context
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_claude "$fake_bin"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9003-fixture",
      steps: [
        {
          id: "claude-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status_value" == "completed" ]] || fail "expected agent step to be completed, got $status_value"

  log_file="$WORKSPACES_DIR/$issue/logs/claude-step.log"
  [[ -f "$log_file" ]] || fail "expected agent step log file"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "claude saw"
}

test_sigint_resets_running_step_to_pending_and_rerun_picks_it_up() {
  local issue output fake_bin status first_status second_status metrics_files

  issue="9009"
  write_valid_context
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_interrupt_once_claude "$fake_bin"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9009-fixture",
      steps: [
        {
          id: "interruptible-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  set +e
  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected SIGINT handler to exit cleanly, got $status: $output"
  first_status="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$first_status" == "pending" ]] || fail "expected interrupted step to reset to pending, got $first_status"
  metrics_files="$(find "$WORKSPACES_DIR/$issue" -maxdepth 1 -name 'metrics.interruptible-step.*' -print)"
  [[ -z "$metrics_files" ]] || fail "expected SIGINT to clean metrics temp file, found $metrics_files"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null
  second_status="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$second_status" == "completed" ]] || fail "expected rerun to complete same step, got $second_status"
}

test_sigterm_resets_running_step_to_pending_and_cleans_metrics_file() {
  local issue fake_bin output_file ralph_pid status metrics_files

  issue="9034"
  write_valid_context
  fake_bin="$WORKSPACES_DIR/fake-bin"
  output_file="$WORKSPACES_DIR/$issue/ralph.out"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_sleeping_claude "$fake_bin"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9034-fixture",
      steps: [
        {
          id: "term-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" > "$output_file" 2>&1 &
  ralph_pid=$!

  for _ in {1..50}; do
    status="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
    metrics_files="$(find "$WORKSPACES_DIR/$issue" -maxdepth 1 -name 'metrics.term-step.*' -print)"
    if [[ "$status" == "in_progress" && -n "$metrics_files" ]]; then
      break
    fi
    sleep 0.1
  done

  status="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status" == "in_progress" ]] || fail "expected TERM test step to be in_progress before signal, got $status"
  [[ -n "$metrics_files" ]] || fail "expected TERM test metrics temp file before signal"

  kill -TERM "$ralph_pid"
  wait "$ralph_pid" || true

  status="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status" == "pending" ]] || fail "expected SIGTERM to reset step to pending, got $status"
  metrics_files="$(find "$WORKSPACES_DIR/$issue" -maxdepth 1 -name 'metrics.term-step.*' -print)"
  [[ -z "$metrics_files" ]] || fail "expected SIGTERM to clean metrics temp file, found $metrics_files"
}

test_sighup_resets_running_step_to_pending_and_cleans_metrics_file() {
  local issue fake_bin output_file ralph_pid status metrics_files

  issue="9035"
  write_valid_context
  fake_bin="$WORKSPACES_DIR/fake-bin"
  output_file="$WORKSPACES_DIR/$issue/ralph.out"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_sleeping_claude "$fake_bin"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9035-fixture",
      steps: [
        {
          id: "hup-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" > "$output_file" 2>&1 &
  ralph_pid=$!

  for _ in {1..50}; do
    status="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
    metrics_files="$(find "$WORKSPACES_DIR/$issue" -maxdepth 1 -name 'metrics.hup-step.*' -print)"
    if [[ "$status" == "in_progress" && -n "$metrics_files" ]]; then
      break
    fi
    sleep 0.1
  done

  status="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status" == "in_progress" ]] || fail "expected HUP test step to be in_progress before signal, got $status"
  [[ -n "$metrics_files" ]] || fail "expected HUP test metrics temp file before signal"

  kill -HUP "$ralph_pid"
  wait "$ralph_pid" || true

  status="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status" == "pending" ]] || fail "expected SIGHUP to reset step to pending, got $status"
  metrics_files="$(find "$WORKSPACES_DIR/$issue" -maxdepth 1 -name 'metrics.hup-step.*' -print)"
  [[ -z "$metrics_files" ]] || fail "expected SIGHUP to clean metrics temp file, found $metrics_files"
}

test_blocked_step_stops_then_resumes_with_human_answers() {
  local issue output fake_bin flag_file status_value log_file

  issue="9010"
  write_valid_context
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_hitl_claude "$fake_bin"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9010-fixture",
      steps: [
        {
          id: "review-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue")"
  flag_file="$WORKSPACES_DIR/$issue/hitl-review-step.md"
  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"

  [[ "$status_value" == "blocked" ]] || fail "expected step to remain blocked, got $status_value"
  [[ -f "$flag_file" ]] || fail "expected HITL flag file"
  assert_contains "$output" "blocked for human input"
  assert_contains "$output" "$flag_file"

  printf "\nUse the reviewed option\n" >> "$flag_file"
  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  log_file="$WORKSPACES_DIR/$issue/logs/review-step.log"
  [[ "$status_value" == "completed" ]] || fail "expected answered HITL step to complete, got $status_value"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "resumed with"
}

test_failed_agent_invocation_marks_step_failed_and_exits_one() {
  local issue output fake_bin status status_value

  issue="9011"
  write_valid_context
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_failing_claude "$fake_bin"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9011-fixture",
      steps: [
        {
          id: "failing-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  set +e
  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected failed agent to make ralph exit 1, got $status: $output"
  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status_value" == "failed" ]] || fail "expected failed agent step to be marked failed, got $status_value"
}

test_review_decisions_runs_after_context_check_and_blocks_then_resumes() {
  local issue fake_bin output flag_file findings_file status_value log_file status artifact_file parent_index_file decisions_file create_count round_count hitl_count

  issue="9015"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_review_decisions_claude "$fake_bin"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: null,
      branch: null,
      status: "initialized",
      steps: [
        {
          id: "review-decisions",
          phase: "fixed",
          type: "review-decisions",
          agent: "claude",
          reviewers: ["codex", "gemini", "kimi", "deepseek"],
          hitl: true,
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  set +e
  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e
  [[ "$status" -eq 0 ]] || fail "expected review-decisions first run to block cleanly, got $status: $output"
  flag_file="$WORKSPACES_DIR/$issue/hitl-review-decisions.md"
  findings_file="$WORKSPACES_DIR/$issue/review-decisions.md"
  decisions_file="$WORKSPACES_DIR/$issue/decisions.md"
  artifact_file="$WORKSPACES_DIR/$issue/github-decisions-artifact.md"
  parent_index_file="$WORKSPACES_DIR/$issue/github-parent-index.md"
  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"

  [[ "$status_value" == "blocked" ]] || fail "expected review-decisions to block, got $status_value"
  [[ -f "$WORKSPACES_DIR/$issue/logs/check-context.log" ]] || fail "expected context check log file"
  [[ -f "$findings_file" ]] || fail "expected review-decisions findings file"
  [[ -f "$WORKSPACES_DIR/$issue/original-issue.md" ]] || fail "expected original issue body to be preserved before parent index refresh"
  [[ -f "$decisions_file" ]] || fail "expected decisions.md recovery/audit file"
  [[ -f "$artifact_file" ]] || fail "expected Decisions Artifact fixture to be written"
  [[ -f "$parent_index_file" ]] || fail "expected compact parent index fixture"
  [[ -f "$flag_file" ]] || fail "expected HITL flag file"
  assert_contains "$output" "blocked for human input"
  assert_contains "$(<"$findings_file")" "Major issue"
  assert_contains "$(<"$artifact_file")" "Ralph-Artifact: decisions"
  assert_contains "$(<"$artifact_file")" "## Original Feature Request / Grilled Decisions"
  assert_contains "$(<"$artifact_file")" "Original grilled issue body"
  assert_contains "$(<"$artifact_file")" "## review-decisions-1"
  assert_contains "$(<"$artifact_file")" "## Council Attribution"
  assert_contains "$(<"$artifact_file")" "Reviewed by: codex, gemini"
  assert_contains "$(<"$parent_index_file")" "## Ralph Run Index"
  assert_contains "$(<"$parent_index_file")" "- Decisions: #9100"
  [[ "$(<"$parent_index_file")" != *"Major issue"* ]] || fail "expected parent index not to contain decision findings"
  [[ "$(<"$findings_file")" != *"nitpick"* ]] || fail "expected findings to filter nitpicks"

  jq '.steps[0].status = "pending"' "$WORKSPACES_DIR/$issue/state.json" > "$WORKSPACES_DIR/$issue/state.json.tmp"
  mv "$WORKSPACES_DIR/$issue/state.json.tmp" "$WORKSPACES_DIR/$issue/state.json"
  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  round_count="$(grep -c '^## review-decisions-1$' "$artifact_file")"
  create_count="$(grep -c '^Ralph-Artifact: decisions$' "$artifact_file")"
  [[ "$round_count" == "1" ]] || fail "expected rerun to replace review-decisions-1 section, got $round_count"
  [[ "$create_count" == "1" ]] || fail "expected rerun to reuse one Decisions Artifact, got $create_count marker sections"

  printf "\nUse the architecture option\n" >> "$flag_file"
  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  log_file="$WORKSPACES_DIR/$issue/logs/review-decisions.log"
  [[ "$status_value" == "completed" ]] || fail "expected review-decisions to complete after answers, got $status_value"
  assert_contains "$(<"$artifact_file")" "## HITL Answers"
  assert_contains "$(<"$artifact_file")" "Use the architecture option"
  hitl_count="$(grep -c '^## HITL Answers$' "$artifact_file")"
  [[ "$hitl_count" == "1" ]] || fail "expected one HITL Answers section, got $hitl_count"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "completed without rerunning council"
}

test_create_prd_pipeline_writes_prd_artifact_and_compact_parent_index() {
  local issue fake_bin original_file prd_file prd_artifact_file parent_index_file status_value log_file decision_count problem_count

  issue="9016"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_create_prd_claude "$fake_bin"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: null,
      branch: null,
      status: "initialized",
      artifacts: {
        decisions: 9100,
        prd: null,
        slicePlan: null
      },
      steps: [
        {
          id: "review-decisions",
          phase: "fixed",
          type: "review-decisions",
          agent: "claude",
          reviewers: ["codex", "gemini", "kimi", "deepseek"],
          hitl: true,
          status: "completed",
          metrics: {},
          notes: ""
        },
        {
          id: "create-and-review-prd",
          phase: "fixed",
          type: "create-and-review-prd",
          agent: "claude",
          reviewers: ["codex", "gemini", "kimi", "deepseek"],
          hitl: false,
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  original_file="$WORKSPACES_DIR/$issue/original-issue.md"
  prd_file="$WORKSPACES_DIR/$issue/prd.md"
  prd_artifact_file="$WORKSPACES_DIR/$issue/github-prd-artifact.md"
  parent_index_file="$WORKSPACES_DIR/$issue/github-parent-index.md"
  log_file="$WORKSPACES_DIR/$issue/logs/create-and-review-prd.log"
  status_value="$(jq -r '.steps[1].status' "$WORKSPACES_DIR/$issue/state.json")"

  [[ "$status_value" == "completed" ]] || fail "expected create-and-review-prd to complete, got $status_value"
  [[ -f "$original_file" ]] || fail "expected original issue body to be preserved"
  [[ -f "$prd_file" ]] || fail "expected prd.md recovery/audit file"
  [[ -f "$prd_artifact_file" ]] || fail "expected PRD Artifact fixture to be updated"
  [[ -f "$parent_index_file" ]] || fail "expected compact parent index fixture"
  assert_contains "$(<"$original_file")" "Original grilled issue body"
  assert_contains "$(<"$prd_file")" "## Decision Summary"
  assert_contains "$(<"$prd_artifact_file")" "Ralph-Artifact: prd"
  assert_contains "$(<"$prd_artifact_file")" "## Problem Statement"
  assert_contains "$(<"$prd_artifact_file")" "## PRD Review Round 1"
  assert_contains "$(<"$prd_artifact_file")" "Reviewed by: codex, gemini"
  assert_contains "$(<"$parent_index_file")" "## Ralph Run Index"
  assert_contains "$(<"$parent_index_file")" "- PRD: #9101"
  [[ "$(<"$parent_index_file")" != *"## Problem Statement"* ]] || fail "expected parent index not to contain full PRD content"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "updated PRD Artifact Issue"
  [[ "$(jq -r '.artifacts.prd' "$WORKSPACES_DIR/$issue/state.json")" == "9101" ]] || fail "expected state artifacts.prd to be set"

  jq '.steps[1].status = "pending"' "$WORKSPACES_DIR/$issue/state.json" > "$WORKSPACES_DIR/$issue/state.json.tmp"
  mv "$WORKSPACES_DIR/$issue/state.json.tmp" "$WORKSPACES_DIR/$issue/state.json"
  printf 'Original grilled issue body\nHuman note that must stay preserved\n' > "$original_file"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  assert_contains "$(<"$original_file")" "Human note that must stay preserved"
  decision_count="$(grep -c '^## Decision Summary$' "$prd_artifact_file")"
  problem_count="$(grep -c '^## Problem Statement$' "$prd_artifact_file")"
  [[ "$decision_count" == "1" ]] || fail "expected one Decision Summary after rerun, got $decision_count"
  [[ "$problem_count" == "1" ]] || fail "expected one Problem Statement after rerun, got $problem_count"
}

test_create_prd_pipeline_zero_review_synthesizes_decisions_artifact() {
  local issue fake_bin decisions_file decision_artifact_file prd_artifact_file parent_index_file status_value

  issue="9067"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_create_prd_claude "$fake_bin"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: null,
      branch: null,
      status: "initialized",
      artifacts: {
        decisions: null,
        prd: null,
        slicePlan: null
      },
      steps: [
        {
          id: "create-and-review-prd",
          phase: "fixed",
          type: "create-and-review-prd",
          agent: "claude",
          reviewers: ["codex", "gemini"],
          hitl: false,
          reviewRounds: 0,
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  decisions_file="$WORKSPACES_DIR/$issue/decisions.md"
  decision_artifact_file="$WORKSPACES_DIR/$issue/github-decisions-artifact.md"
  prd_artifact_file="$WORKSPACES_DIR/$issue/github-prd-artifact.md"
  parent_index_file="$WORKSPACES_DIR/$issue/github-parent-index.md"
  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"

  [[ "$status_value" == "completed" ]] || fail "expected create-and-review-prd to complete, got $status_value"
  [[ -f "$WORKSPACES_DIR/$issue/original-issue.md" ]] || fail "expected original issue body to be preserved in zero-review mode"
  [[ -f "$decisions_file" ]] || fail "expected decisions.md to be persisted in zero-review mode"
  [[ -f "$decision_artifact_file" ]] || fail "expected synthesized Decisions Artifact fixture"
  [[ -f "$prd_artifact_file" ]] || fail "expected PRD Artifact fixture"
  [[ -f "$parent_index_file" ]] || fail "expected compact parent index fixture"
  assert_contains "$(<"$decision_artifact_file")" "Ralph-Artifact: decisions"
  assert_contains "$(<"$decision_artifact_file")" "synthesized from the original feature request"
  assert_contains "$(<"$parent_index_file")" "## Ralph Run Index"
  [[ "$(<"$parent_index_file")" != *"synthesized from the original feature request"* ]] || fail "expected parent index not to contain synthesized decision content"
  [[ "$(jq -r '.artifacts.decisions' "$WORKSPACES_DIR/$issue/state.json")" == "9100" ]] || fail "expected state artifacts.decisions to be set"
  [[ "$(jq -r '.artifacts.prd' "$WORKSPACES_DIR/$issue/state.json")" == "9101" ]] || fail "expected state artifacts.prd to be set"
}

test_create_slices_pipeline_writes_slice_plan_artifact_and_creates_linked_afk_sub_issues_idempotently() {
  local issue fake_bin slices_file sub_issues_file slice_plan_artifact_file parent_index_file status_value log_file issue_count round_count

  issue="9018"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_create_slices_claude "$fake_bin"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: null,
      branch: null,
      status: "initialized",
      artifacts: {
        decisions: 9100,
        prd: 9101,
        slicePlan: null
      },
      steps: [
        {
          id: "review-decisions",
          phase: "fixed",
          type: "review-decisions",
          agent: "claude",
          reviewers: ["codex", "gemini", "kimi", "deepseek"],
          hitl: true,
          status: "completed",
          metrics: {},
          notes: ""
        },
        {
          id: "create-and-review-prd",
          phase: "fixed",
          type: "create-and-review-prd",
          agent: "claude",
          reviewers: ["codex", "gemini", "kimi", "deepseek"],
          hitl: false,
          status: "completed",
          metrics: {},
          notes: ""
        },
        {
          id: "create-and-review-slices",
          phase: "fixed",
          type: "create-and-review-slices",
          agent: "claude",
          reviewers: ["codex", "gemini", "kimi", "deepseek"],
          hitl: false,
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  slices_file="$WORKSPACES_DIR/$issue/slices.md"
  sub_issues_file="$WORKSPACES_DIR/$issue/github-sub-issues.md"
  slice_plan_artifact_file="$WORKSPACES_DIR/$issue/github-slice-plan-artifact.md"
  parent_index_file="$WORKSPACES_DIR/$issue/github-parent-index.md"
  log_file="$WORKSPACES_DIR/$issue/logs/create-and-review-slices.log"
  status_value="$(jq -r '.steps[2].status' "$WORKSPACES_DIR/$issue/state.json")"

  [[ "$status_value" == "completed" ]] || fail "expected create-and-review-slices to complete, got $status_value"
  [[ -f "$slices_file" ]] || fail "expected final slices file"
  [[ -f "$slice_plan_artifact_file" ]] || fail "expected Slice Plan Artifact fixture"
  [[ -f "$parent_index_file" ]] || fail "expected compact parent index fixture"
  [[ -f "$sub_issues_file" ]] || fail "expected sub-issue fixture file"
  assert_contains "$(<"$slice_plan_artifact_file")" "Ralph-Artifact: slicePlan"
  assert_contains "$(<"$slice_plan_artifact_file")" "Reviewed Slice Plan"
  assert_contains "$(<"$slice_plan_artifact_file")" "## Slice Plan Review Round 1"
  assert_contains "$(<"$slice_plan_artifact_file")" "Reviewed by: codex, gemini"
  assert_contains "$(<"$slice_plan_artifact_file")" "#9102"
  assert_contains "$(<"$slice_plan_artifact_file")" "#9103"
  assert_contains "$(<"$sub_issues_file")" "PRD: #9101"
  assert_contains "$(<"$sub_issues_file")" "Slice Plan: #9104"
  assert_contains "$(<"$sub_issues_file")" "AFK: true"
  assert_contains "$(<"$sub_issues_file")" "Parent: #9018"
  assert_contains "$(<"$sub_issues_file")" "addSubIssue"
  [[ "$(<"$sub_issues_file")" != *"Ralph-Artifact:"* ]] || fail "expected AFK implementation slice bodies not to contain artifact markers"
  assert_contains "$(<"$parent_index_file")" "## Ralph Run Index"
  assert_contains "$(<"$parent_index_file")" "- Slice Plan: #9104"
  [[ "$(<"$parent_index_file")" != *"Reviewed Slice Plan"* ]] || fail "expected parent index not to contain full slice plan content"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "create-and-review-slices created AFK sub-issues"
  [[ "$(jq -r '.artifacts.slicePlan' "$WORKSPACES_DIR/$issue/state.json")" == "9104" ]] || fail "expected state artifacts.slicePlan to be set"

  jq '.steps[2].status = "pending"' "$WORKSPACES_DIR/$issue/state.json" > "$WORKSPACES_DIR/$issue/state.json.tmp"
  mv "$WORKSPACES_DIR/$issue/state.json.tmp" "$WORKSPACES_DIR/$issue/state.json"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  issue_count="$(grep -c '^-' "$sub_issues_file")"
  [[ "$issue_count" == "2" ]] || fail "expected rerun not to create duplicate sub-issues, got $issue_count entries"
  round_count="$(grep -c '^## Slice Plan Review Round 1$' "$slice_plan_artifact_file")"
  [[ "$round_count" == "1" ]] || fail "expected rerun to replace slice review round sections, got $round_count"
}

test_implement_slice_pipeline_runs_codex_with_sub_issue_context() {
  local issue fake_bin status_value log_file input_tokens output_tokens output

  issue="9020"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_implement_slice_codex "$fake_bin"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    --arg project_root "$PROJECT_ROOT" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9020-implementation-workflow",
      projectRoot: $project_root,
      status: "initialized",
      steps: [
        {
          id: "implement-slice-9111",
          phase: "dynamic",
          type: "implement-slice",
          agent: "codex",
          reviewers: [],
          hitl: false,
          status: "pending",
          sub_issue: 9111,
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue")"

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  input_tokens="$(jq -r '.steps[0].metrics.input_tokens' "$WORKSPACES_DIR/$issue/state.json")"
  output_tokens="$(jq -r '.steps[0].metrics.output_tokens' "$WORKSPACES_DIR/$issue/state.json")"
  log_file="$WORKSPACES_DIR/$issue/logs/implement-slice-9111.log"

  [[ "$status_value" == "completed" ]] || fail "expected implement-slice to complete, got $status_value"
  [[ "$input_tokens" == "21" ]] || fail "expected implement-slice input_tokens metric, got $input_tokens"
  [[ "$output_tokens" == "34" ]] || fail "expected implement-slice output_tokens metric, got $output_tokens"
  [[ -f "$log_file" ]] || fail "expected implement-slice log file"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "turn.completed"
  assert_contains "$output" "implement-slice-9111"
  assert_contains "$output" "codex"
}

test_final_and_pr_review_pipeline_completes_with_idempotent_pr() {
  local issue fake_bin output final_file pr_body_file pr_review_file create_count final_status pr_status pr_status_after_rerun

  issue="9021"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_final_and_pr_review_claude "$fake_bin"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9021-final-pr-workflow",
      status: "initialized",
      steps: [
        {
          id: "implement-slice-9111",
          phase: "dynamic",
          type: "implement-slice",
          agent: "codex",
          reviewers: [],
          hitl: false,
          status: "completed",
          sub_issue: 9111,
          metrics: {},
          notes: ""
        },
        {
          id: "final-review",
          phase: "dynamic",
          type: "final-review",
          agent: "claude",
          reviewers: [],
          hitl: false,
          status: "pending",
          metrics: {},
          notes: ""
        },
        {
          id: "pr-review",
          phase: "dynamic",
          type: "pr-review",
          agent: "claude",
          reviewers: ["codex", "gemini", "kimi", "deepseek"],
          hitl: false,
          status: "pending",
          metrics: {},
          notes: ""
        },
        {
          id: "review-fixes",
          phase: "dynamic",
          type: "review-fixes",
          agent: "claude",
          reviewers: [],
          hitl: false,
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue")"

  final_file="$WORKSPACES_DIR/$issue/final-review.md"
  pr_body_file="$WORKSPACES_DIR/$issue/pr-body.md"
  pr_review_file="$WORKSPACES_DIR/$issue/pr-review.md"
  review_fixes_file="$WORKSPACES_DIR/$issue/review-fixes.md"
  review_fixes_comment="$WORKSPACES_DIR/$issue/review-fixes-comment.md"
  final_status="$(jq -r '.steps[] | select(.id == "final-review") | .status' "$WORKSPACES_DIR/$issue/state.json")"
  pr_status="$(jq -r '.steps[] | select(.id == "pr-review") | .status' "$WORKSPACES_DIR/$issue/state.json")"
  rf_status="$(jq -r '.steps[] | select(.id == "review-fixes") | .status' "$WORKSPACES_DIR/$issue/state.json")"

  [[ "$final_status" == "completed" ]] || fail "expected final-review to complete, got $final_status"
  [[ "$pr_status" == "completed" ]] || fail "expected pr-review to complete, got $pr_status"
  [[ "$rf_status" == "completed" ]] || fail "expected review-fixes to complete, got $rf_status"
  [[ -f "$final_file" ]] || fail "expected final-review.md to exist"
  [[ -f "$pr_body_file" ]] || fail "expected PR body file"
  [[ -f "$pr_review_file" ]] || fail "expected PR review record"
  [[ -f "$review_fixes_file" ]] || fail "expected review-fixes.md to exist"
  [[ -f "$review_fixes_comment" ]] || fail "expected review-fixes-comment.md to exist"
  assert_contains "$(<"$final_file")" "Acceptance criteria verification"
  assert_contains "$(<"$pr_body_file")" "## Summary"
  assert_contains "$(<"$pr_body_file")" "Closes #9021"
  assert_contains "$(<"$pr_body_file")" "Closes #9111"
  assert_contains "$(<"$pr_body_file")" "Human QA Checklist"
  assert_contains "$(<"$pr_review_file")" "code-review:code-review invoked"
  assert_contains "$(<"$review_fixes_file")" "Findings Evaluated"
  assert_contains "$(<"$review_fixes_file")" "Fixed"
  assert_contains "$(<"$review_fixes_comment")" "Review Fixes Assessment"
  assert_contains "$output" "final-review"
  assert_contains "$output" "pr-review"
  assert_contains "$output" "review-fixes"

  jq '(.steps[] | select(.id == "pr-review") | .status) = "pending"
    | (.steps[] | select(.id == "review-fixes") | .status) = "pending"' "$WORKSPACES_DIR/$issue/state.json" > "$WORKSPACES_DIR/$issue/state.json.tmp"
  mv "$WORKSPACES_DIR/$issue/state.json.tmp" "$WORKSPACES_DIR/$issue/state.json"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  pr_status_after_rerun="$(jq -r '.steps[] | select(.id == "pr-review") | .status' "$WORKSPACES_DIR/$issue/state.json")"
  create_count="$(<"$WORKSPACES_DIR/$issue/github-pr-create-count")"
  [[ "$pr_status_after_rerun" == "completed" ]] || fail "expected pr-review rerun to complete, got $pr_status_after_rerun"
  [[ "$create_count" == "1" ]] || fail "expected rerun not to create duplicate PRs, got create count $create_count"
  assert_contains "$(<"$pr_review_file")" "Action: updated"
}

test_pr_review_pipeline_uses_codex_review_path_when_step_agent_is_codex() {
  local issue fake_bin output status_value input_tokens output_tokens pr_review_file codex_review_file log_file

  issue="9050"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_codex_pr_review "$fake_bin"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    --arg project_root "$PROJECT_ROOT" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9050-codex-pr-review",
      projectRoot: $project_root,
      status: "initialized",
      steps: [
        {
          id: "pr-review",
          phase: "dynamic",
          type: "pr-review",
          agent: "codex",
          reviewers: ["codex", "gemini"],
          hitl: false,
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue")"

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  input_tokens="$(jq -r '.steps[0].metrics.input_tokens' "$WORKSPACES_DIR/$issue/state.json")"
  output_tokens="$(jq -r '.steps[0].metrics.output_tokens' "$WORKSPACES_DIR/$issue/state.json")"
  pr_review_file="$WORKSPACES_DIR/$issue/pr-review.md"
  codex_review_file="$WORKSPACES_DIR/$issue/codex-pr-review.md"
  log_file="$WORKSPACES_DIR/$issue/logs/pr-review.log"

  [[ "$status_value" == "completed" ]] || fail "expected codex pr-review step to complete, got $status_value"
  [[ "$input_tokens" == "31" ]] || fail "expected codex pr-review input_tokens metric, got $input_tokens"
  [[ "$output_tokens" == "29" ]] || fail "expected codex pr-review output_tokens metric, got $output_tokens"
  [[ -f "$pr_review_file" ]] || fail "expected pr-review.md to exist"
  [[ -f "$codex_review_file" ]] || fail "expected codex-pr-review.md to exist"
  [[ -f "$log_file" ]] || fail "expected pr-review log to exist"
  assert_contains "$(<"$pr_review_file")" "Automated review source: codex review"
  assert_contains "$(<"$codex_review_file")" "No findings"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "turn.completed"
  assert_contains "$output" "pr-review"
  assert_contains "$output" "codex"
}

run_test test_run_completes_pending_agent_step
run_test test_sigint_resets_running_step_to_pending_and_rerun_picks_it_up
run_test test_sigterm_resets_running_step_to_pending_and_cleans_metrics_file
run_test test_sighup_resets_running_step_to_pending_and_cleans_metrics_file
run_test test_blocked_step_stops_then_resumes_with_human_answers
run_test test_failed_agent_invocation_marks_step_failed_and_exits_one
run_test test_review_decisions_runs_after_context_check_and_blocks_then_resumes
run_test test_create_prd_pipeline_writes_prd_artifact_and_compact_parent_index
run_test test_create_prd_pipeline_zero_review_synthesizes_decisions_artifact
run_test test_create_slices_pipeline_writes_slice_plan_artifact_and_creates_linked_afk_sub_issues_idempotently
run_test test_implement_slice_pipeline_runs_codex_with_sub_issue_context
run_test test_final_and_pr_review_pipeline_completes_with_idempotent_pr
run_test test_pr_review_pipeline_uses_codex_review_path_when_step_agent_is_codex

echo "pipeline_test.sh passed"
