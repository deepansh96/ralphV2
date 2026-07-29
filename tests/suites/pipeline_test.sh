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
  local issue fake_bin output flag_file findings_file status_value log_file status

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
  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"

  [[ "$status_value" == "blocked" ]] || fail "expected review-decisions to block, got $status_value"
  [[ -f "$WORKSPACES_DIR/$issue/logs/check-context.log" ]] || fail "expected context check log file"
  [[ -f "$findings_file" ]] || fail "expected review-decisions findings file"
  [[ -f "$flag_file" ]] || fail "expected HITL flag file"
  assert_contains "$output" "blocked for human input"
  assert_contains "$(<"$findings_file")" "Major issue"
  [[ "$(<"$findings_file")" != *"nitpick"* ]] || fail "expected findings to filter nitpicks"

  printf "\nUse the architecture option\n" >> "$flag_file"
  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  log_file="$WORKSPACES_DIR/$issue/logs/review-decisions.log"
  [[ "$status_value" == "completed" ]] || fail "expected review-decisions to complete after answers, got $status_value"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "completed without rerunning council"
}

test_create_prd_pipeline_preserves_original_and_updates_single_prd_body() {
  local issue fake_bin original_file issue_body_file status_value log_file decision_count problem_count

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
  issue_body_file="$WORKSPACES_DIR/$issue/github-issue-body.md"
  log_file="$WORKSPACES_DIR/$issue/logs/create-and-review-prd.log"
  status_value="$(jq -r '.steps[1].status' "$WORKSPACES_DIR/$issue/state.json")"

  [[ "$status_value" == "completed" ]] || fail "expected create-and-review-prd to complete, got $status_value"
  [[ -f "$original_file" ]] || fail "expected original issue body to be preserved"
  [[ -f "$issue_body_file" ]] || fail "expected issue body fixture to be updated"
  assert_contains "$(<"$original_file")" "Original grilled issue body"
  assert_contains "$(<"$issue_body_file")" "## Decision Summary"
  assert_contains "$(<"$issue_body_file")" "## Problem Statement"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "create-and-review-prd preserved original"

  jq '.steps[1].status = "pending"' "$WORKSPACES_DIR/$issue/state.json" > "$WORKSPACES_DIR/$issue/state.json.tmp"
  mv "$WORKSPACES_DIR/$issue/state.json.tmp" "$WORKSPACES_DIR/$issue/state.json"
  printf 'Original grilled issue body\nHuman note that must stay preserved\n' > "$original_file"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  assert_contains "$(<"$original_file")" "Human note that must stay preserved"
  decision_count="$(grep -c '^## Decision Summary$' "$issue_body_file")"
  problem_count="$(grep -c '^## Problem Statement$' "$issue_body_file")"
  [[ "$decision_count" == "1" ]] || fail "expected one Decision Summary after rerun, got $decision_count"
  [[ "$problem_count" == "1" ]] || fail "expected one Problem Statement after rerun, got $problem_count"
}

test_create_slices_pipeline_creates_linked_afk_sub_issues_idempotently() {
  local issue fake_bin slices_file sub_issues_file status_value log_file issue_count

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
  log_file="$WORKSPACES_DIR/$issue/logs/create-and-review-slices.log"
  status_value="$(jq -r '.steps[2].status' "$WORKSPACES_DIR/$issue/state.json")"

  [[ "$status_value" == "completed" ]] || fail "expected create-and-review-slices to complete, got $status_value"
  [[ -f "$slices_file" ]] || fail "expected final slices file"
  [[ -f "$sub_issues_file" ]] || fail "expected sub-issue fixture file"
  assert_contains "$(<"$sub_issues_file")" "AFK: true"
  assert_contains "$(<"$sub_issues_file")" "addSubIssue"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "create-and-review-slices created AFK sub-issues"

  jq '.steps[2].status = "pending"' "$WORKSPACES_DIR/$issue/state.json" > "$WORKSPACES_DIR/$issue/state.json.tmp"
  mv "$WORKSPACES_DIR/$issue/state.json.tmp" "$WORKSPACES_DIR/$issue/state.json"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  issue_count="$(grep -c '^-' "$sub_issues_file")"
  [[ "$issue_count" == "2" ]] || fail "expected rerun not to create duplicate sub-issues, got $issue_count entries"
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

test_post_implementation_pipeline_completes_with_idempotent_pr_comments() {
  local issue fake_bin output pr_status cleanup_status create_count qa_count review_count

  issue="9021"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_post_implementation_claude "$fake_bin"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  printf '%s\n' '{"processes":[],"containers":[],"tempPaths":[],"sessions":[]}' > "$WORKSPACES_DIR/$issue/local-resources.json"
  jq -n \
    --arg issue "$issue" \
    --arg project_root "$PROJECT_ROOT" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9021-post-implementation",
      projectRoot: $project_root,
      status: "initialized",
      steps: [
        {id: "implement-slice-9111", phase: "dynamic", type: "implement-slice", agent: "codex", status: "completed", sub_issue: 9111},
        {id: "final-checks", phase: "dynamic", type: "final-checks", agent: "claude", status: "pending"},
        {id: "pr-creation", phase: "dynamic", type: "pr-creation", agent: "claude", status: "pending"},
        {id: "prepare-qa-checklist", phase: "dynamic", type: "prepare-qa-checklist", agent: "claude", status: "pending"},
        {id: "runthrough-qa-checklist", phase: "dynamic", type: "runthrough-qa-checklist", agent: "claude", status: "pending"},
        {id: "multi-axis-pr-review", phase: "dynamic", type: "multi-axis-pr-review", agent: "claude", status: "pending"},
        {id: "cleanup-local-resources", phase: "dynamic", type: "cleanup-local-resources", agent: "claude", alwaysRun: true, status: "pending"}
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue")"

  pr_status="$(jq -r '.steps[] | select(.id == "pr-creation") | .status' "$WORKSPACES_DIR/$issue/state.json")"
  cleanup_status="$(jq -r '.steps[] | select(.id == "cleanup-local-resources") | .status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$pr_status" == "completed" ]] || fail "expected pr-creation to complete"
  [[ "$cleanup_status" == "completed" ]] || fail "expected cleanup to complete"
  [[ -f "$WORKSPACES_DIR/$issue/final-checks.md" ]] || fail "expected final-checks artifact"
  [[ -f "$WORKSPACES_DIR/$issue/pr-creation.md" ]] || fail "expected pr-creation artifact"
  [[ -f "$WORKSPACES_DIR/$issue/cleanup-local-resources.md" ]] || fail "expected cleanup artifact"
  assert_contains "$(<"$WORKSPACES_DIR/$issue/pr-body.md")" "Closes #9021"
  [[ "$(<"$WORKSPACES_DIR/$issue/pr-body.md")" != *"QA Checklist"* ]] || fail "expected PR body without QA"
  assert_contains "$(<"$WORKSPACES_DIR/$issue/github-qa-comment.md")" "[PASS]"
  assert_contains "$(<"$WORKSPACES_DIR/$issue/github-multi-axis-comment.md")" "ralph:multi-axis-review"
  assert_contains "$output" "cleanup-local-resources"

  jq '(.steps[] | select(.id == "pr-creation" or .id == "prepare-qa-checklist" or .id == "multi-axis-pr-review" or .id == "cleanup-local-resources") | .status) = "pending"' \
    "$WORKSPACES_DIR/$issue/state.json" > "$WORKSPACES_DIR/$issue/state.json.tmp"
  mv "$WORKSPACES_DIR/$issue/state.json.tmp" "$WORKSPACES_DIR/$issue/state.json"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  create_count="$(<"$WORKSPACES_DIR/$issue/github-pr-create-count")"
  qa_count="$(<"$WORKSPACES_DIR/$issue/qa-comment-count")"
  review_count="$(<"$WORKSPACES_DIR/$issue/multi-axis-comment-count")"
  [[ "$create_count" == "1" ]] || fail "expected one PR creation"
  [[ "$qa_count" == "1" ]] || fail "expected one QA comment"
  [[ "$review_count" == "1" ]] || fail "expected one multi-axis comment"
  assert_contains "$(<"$WORKSPACES_DIR/$issue/pr-creation.md")" "updated"
}

test_cleanup_runs_after_an_earlier_step_fails() {
  local issue fake_bin status final_status skipped_status cleanup_status

  issue="9052"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_failure_then_cleanup_claude "$fake_bin"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg project_root "$PROJECT_ROOT" \
    '{
      issue: 9052,
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9052-cleanup",
      projectRoot: $project_root,
      steps: [
        {id: "final-checks", type: "final-checks", agent: "claude", status: "pending"},
        {id: "pr-creation", type: "pr-creation", agent: "claude", status: "pending"},
        {id: "cleanup-local-resources", type: "cleanup-local-resources", agent: "claude", status: "pending", alwaysRun: true}
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  set +e
  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null
  status=$?
  set -e

  final_status="$(jq -r '.steps[] | select(.id == "final-checks") | .status' "$WORKSPACES_DIR/$issue/state.json")"
  skipped_status="$(jq -r '.steps[] | select(.id == "pr-creation") | .status' "$WORKSPACES_DIR/$issue/state.json")"
  cleanup_status="$(jq -r '.steps[] | select(.id == "cleanup-local-resources") | .status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status" -ne 0 ]] || fail "expected pipeline to preserve the original failure"
  [[ "$final_status" == "failed" ]] || fail "expected final-checks to fail"
  [[ "$skipped_status" == "pending" ]] || fail "expected normal later steps to remain pending"
  [[ "$cleanup_status" == "completed" ]] || fail "expected cleanup to run after failure"
  [[ -f "$WORKSPACES_DIR/$issue/cleanup-ran" ]] || fail "expected cleanup agent to run"
}

run_test test_run_completes_pending_agent_step
run_test test_sigint_resets_running_step_to_pending_and_rerun_picks_it_up
run_test test_sigterm_resets_running_step_to_pending_and_cleans_metrics_file
run_test test_sighup_resets_running_step_to_pending_and_cleans_metrics_file
run_test test_blocked_step_stops_then_resumes_with_human_answers
run_test test_failed_agent_invocation_marks_step_failed_and_exits_one
run_test test_review_decisions_runs_after_context_check_and_blocks_then_resumes
run_test test_create_prd_pipeline_preserves_original_and_updates_single_prd_body
run_test test_create_slices_pipeline_creates_linked_afk_sub_issues_idempotently
run_test test_implement_slice_pipeline_runs_codex_with_sub_issue_context
run_test test_post_implementation_pipeline_completes_with_idempotent_pr_comments
run_test test_cleanup_runs_after_an_earlier_step_fails

echo "pipeline_test.sh passed"
