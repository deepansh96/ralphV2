#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

test_init_prompt_defines_complete_workspace_initialization_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/init.md"
  [[ -f "$prompt_file" ]] || fail "expected init prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "gh issue view {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "command -v gh"
  assert_contains "$prompt" "workspaces/{{ISSUE}}"
  assert_contains "$prompt" "must not overwrite"
  assert_contains "$prompt" '"baseBranch": null'
  assert_contains "$prompt" '"branch": null'
  assert_contains "$prompt" '"status": "initialized"'
  assert_contains "$prompt" '"phase": "fixed"'
  assert_contains "$prompt" '"metrics": null'
  assert_contains "$prompt" '"reviewers": []'
  assert_contains "$prompt" "review-decisions"
  assert_contains "$prompt" "create-and-review-prd"
  assert_contains "$prompt" "create-and-review-slices"
  assert_contains "$prompt" "preflight"
  assert_contains "$prompt" "ralph.sh status --issue {{ISSUE}}"
  assert_contains "$prompt" '"projectRoot"'
  assert_contains "$prompt" "git rev-parse --show-toplevel"
  assert_contains "$prompt" "git status --porcelain"
  assert_contains "$prompt" "working tree"
  assert_contains "$prompt" "grill/*"
  assert_contains "$prompt" "planning branch"
  assert_contains "$prompt" 'default **0**'
  assert_contains "$prompt" "Include review-decisions steps only when the user explicitly opts in"
  assert_contains "$prompt" "If the user opts in without a count, use 1 review-decisions round"
  assert_contains "$prompt" '"reviewRounds": 0'
  assert_contains "$prompt" "Default is 0"
  [[ "$prompt" != *"reviewFixes"* ]] || fail "expected init to omit removed reviewFixes option"
}

test_initialized_workspace_status_shows_default_three_pending_fixed_steps() {
  local issue output pending_count

  issue="9012"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: null,
      branch: null,
      status: "initialized",
      createdAt: "2026-05-02T00:00:00Z",
      steps: [
        {
          id: "create-and-review-prd",
          phase: "fixed",
          type: "create-and-review-prd",
          status: "pending",
          agent: "codex",
          reviewers: ["codex", "gemini", "kimi", "deepseek"],
          reviewRounds: 0,
          hitl: false,
          metrics: null,
          notes: ""
        },
        {
          id: "create-and-review-slices",
          phase: "fixed",
          type: "create-and-review-slices",
          status: "pending",
          agent: "codex",
          reviewers: ["codex", "gemini", "kimi", "deepseek"],
          reviewRounds: 0,
          hitl: false,
          metrics: null,
          notes: ""
        },
        {
          id: "preflight",
          phase: "fixed",
          type: "preflight",
          status: "pending",
          agent: "codex",
          reviewers: [],
          hitl: false,
          metrics: null,
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  output="$("$RALPH" status --issue "$issue")"
  pending_count="$(grep -c "pending" <<<"$output")"

  [[ "$pending_count" == "3" ]] || fail "expected 3 pending steps in status output, got $pending_count: $output"
  assert_contains "$output" "create-and-review-prd"
  assert_contains "$output" "create-and-review-slices"
  assert_contains "$output" "preflight"
}

test_review_decisions_prompt_defines_council_filtering_and_hitl_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/review-decisions.md"
  [[ -f "$prompt_file" ]] || fail "expected review-decisions prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "gh issue view {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "Default agent: codex"
  assert_contains "$prompt" "CONTEXT.md"
  assert_contains "$prompt" "CLAUDE.md"
  assert_contains "$prompt" "docs/adr"
  assert_contains "$prompt" "scripts/council-review.sh"
  assert_contains "$prompt" "Major feedback"
  assert_contains "$prompt" "nitpick"
  assert_contains "$prompt" "{{STEP_ID}}.md"
  assert_contains "$prompt" "hitl-{{STEP_ID}}.md"
  assert_contains "$prompt" "complete WITHOUT re-running council review"
}

test_create_prd_prompt_defines_full_prd_workflow_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/create-and-review-prd.md"
  [[ -f "$prompt_file" ]] || fail "expected create-and-review-prd prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "gh issue view {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "Default agent: codex"
  assert_contains "$prompt" "original-issue.md"
  assert_contains "$prompt" "CONTEXT.md"
  assert_contains "$prompt" "CLAUDE.md"
  assert_contains "$prompt" "docs/adr"
  assert_contains "$prompt" "Explore the codebase"
  assert_contains "$prompt" "to-spec"
  assert_contains "$prompt" "seams"
  assert_contains "$prompt" "SEAMS"
  assert_contains "$prompt" "Decision Summary"
  assert_contains "$prompt" "Problem Statement"
  assert_contains "$prompt" "User Stories"
  assert_contains "$prompt" "Implementation Decisions"
  assert_contains "$prompt" "Testing Decisions"
  assert_contains "$prompt" "scripts/council-review.sh"
  assert_contains "$prompt" "Round 1"
  assert_contains "$prompt" "Round 2"
  assert_contains "$prompt" "**0 (default):** Skip council review entirely"
  assert_contains "$prompt" 'If `reviewRounds` is missing, default to 0'
  assert_contains "$prompt" "incorporate"
  assert_contains "$prompt" "Compact"
  assert_contains "$prompt" "gh issue edit {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "idempotent"
}

test_create_slices_prompt_defines_full_slice_creation_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/create-and-review-slices.md"
  [[ -f "$prompt_file" ]] || fail "expected create-and-review-slices prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "gh issue view {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "Default agent: codex"
  assert_contains "$prompt" "CONTEXT.md"
  assert_contains "$prompt" "CLAUDE.md"
  assert_contains "$prompt" "docs/adr"
  assert_contains "$prompt" "to-tickets"
  assert_contains "$prompt" "tracer bullets"
  assert_contains "$prompt" "horizontal"
  assert_contains "$prompt" "Blocked by"
  assert_contains "$prompt" "dependency order"
  assert_contains "$prompt" "dependencies/blocked_by"
  assert_contains "$prompt" "--method DELETE"
  assert_contains "$prompt" "delete edges no longer declared"
  assert_contains "$prompt" "expand"
  assert_contains "$prompt" "prefactor"
  assert_contains "$prompt" "scripts/council-review.sh"
  assert_contains "$prompt" "Round 1"
  assert_contains "$prompt" "Round 2"
  assert_contains "$prompt" "**0 (default):** Skip council review entirely"
  assert_contains "$prompt" 'If `reviewRounds` is missing, default to 0'
  assert_contains "$prompt" "gh issue create"
  assert_contains "$prompt" "addSubIssue"
  assert_contains "$prompt" "AFK"
  assert_contains "$prompt" "existing sub-issues"
  assert_contains "$prompt" "duplicates"
}

test_preflight_prompt_defines_full_preflight_workflow_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/preflight.md"
  [[ -f "$prompt_file" ]] || fail "expected preflight prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "baseBranch"
  assert_contains "$prompt" "Default agent: codex"
  assert_contains "$prompt" "clear guidance"
  assert_contains "$prompt" "feat/issue-{{ISSUE}}-<slug>"
  assert_contains "$prompt" "kebab"
  assert_contains "$prompt" "git push"
  assert_contains "$prompt" "git status --porcelain"
  assert_contains "$prompt" "git ls-remote --exit-code --heads origin {{BASE_BRANCH}}"
  assert_contains "$prompt" "grill/"
  assert_contains "$prompt" "planning branch"
  assert_contains "$prompt" "branch"
  assert_contains "$prompt" "gh issue view {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "sub-issues"
  assert_contains "$prompt" "state_add_steps"
  assert_contains "$prompt" "topologically"
  assert_contains "$prompt" "implement-slice"
  assert_contains "$prompt" "final-checks"
  assert_contains "$prompt" "pr-creation"
  assert_contains "$prompt" "prepare-qa-checklist"
  assert_contains "$prompt" "runthrough-qa-checklist"
  assert_contains "$prompt" "multi-axis-pr-review"
  assert_contains "$prompt" "cleanup-local-resources"
  assert_contains "$prompt" '"alwaysRun": true'
  assert_contains "$prompt" "local-resources.json"
  [[ "$prompt" != *'"type": "review-slice"'* ]] || fail "expected preflight to omit review-slice"
  [[ "$prompt" != *'"type": "review-fixes"'* ]] || fail "expected preflight to omit review-fixes"
  assert_contains "$prompt" "codex"
  assert_contains "$prompt" "sub_issue"
  assert_contains "$prompt" "idempotent"
}

test_implement_slice_prompt_defines_full_implementation_workflow_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/implement-slice.md"
  [[ -f "$prompt_file" ]] || fail "expected implement-slice prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "Issue: {{ISSUE}}"
  assert_contains "$prompt" "Repo: {{REPO}}"
  assert_contains "$prompt" "Workspace: {{WORKSPACE}}"
  assert_contains "$prompt" "Branch: {{BRANCH}}"
  assert_contains "$prompt" "Base branch: {{BASE_BRANCH}}"
  assert_contains "$prompt" "Step: {{STEP_ID}}"
  assert_contains "$prompt" "Sub-issue: {{SUB_ISSUE}}"
  assert_contains "$prompt" "Skills: {{SKILLS_DIR}}"
  assert_contains "$prompt" "Default agent: codex"
  assert_contains "$prompt" "AFK"
  assert_contains "$prompt" "CONTEXT.md"
  assert_contains "$prompt" "CLAUDE.md"
  assert_contains "$prompt" "docs/adr"
  assert_contains "$prompt" "tdd/SKILL.md"
  assert_contains "$prompt" "tdd/tests.md"
  assert_contains "$prompt" "tdd/mocking.md"
  assert_contains "$prompt" "issue_dependencies_summary.blocked_by"
  assert_contains "$prompt" "seams"
  assert_contains "$prompt" "tautological"
  assert_contains "$prompt" "gh issue view {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "gh issue view {{SUB_ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "Write one failing test first"
  assert_contains "$prompt" "Run quality checks from CLAUDE.md"
  assert_contains "$prompt" "git checkout {{BRANCH}}"
  assert_contains "$prompt" "git commit"
  assert_contains "$prompt" "#{{SUB_ISSUE}}"
  assert_contains "$prompt" "git push"
  assert_contains "$prompt" "gh issue close {{SUB_ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "local-resources.json"
}

test_final_checks_prompt_defines_read_only_check_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/final-checks.md"
  [[ -f "$prompt_file" ]] || fail "expected final-checks prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "git diff {{BASE_BRANCH}}...HEAD"
  assert_contains "$prompt" 'quality commands in `CLAUDE.md`'
  assert_contains "$prompt" "acceptance criterion"
  assert_contains "$prompt" "cross-slice integration"
  assert_contains "$prompt" "read-only"
  assert_contains "$prompt" "{{WORKSPACE}}/final-checks.md"
  assert_contains "$prompt" "local-resources.json"
}

test_pr_creation_prompt_defines_idempotent_pr_only_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/pr-creation.md"
  [[ -f "$prompt_file" ]] || fail "expected pr-creation prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "git push -u origin {{BRANCH}}"
  assert_contains "$prompt" "gh pr list"
  assert_contains "$prompt" "gh pr edit"
  assert_contains "$prompt" "gh pr create"
  assert_contains "$prompt" "defaultBranchRef"
  assert_contains "$prompt" "git merge --no-edit"
  assert_contains "$prompt" "Closes #{{ISSUE}}"
  assert_contains "$prompt" "Closes #<sub-issue>"
  assert_contains "$prompt" "Do not include a review section or QA checklist"
  assert_contains "$prompt" "{{WORKSPACE}}/pr-creation.md"
}

test_prepare_qa_checklist_prompt_defines_local_comment_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/prepare-qa-checklist.md"
  [[ -f "$prompt_file" ]] || fail "expected prepare-qa-checklist prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "whole PR"
  assert_contains "$prompt" "never test a deployed environment"
  assert_contains "$prompt" "stub or local fake"
  assert_contains "$prompt" "remote database"
  assert_contains "$prompt" "local browser"
  assert_contains "$prompt" "<!-- ralph:qa-checklist -->"
  assert_contains "$prompt" "[PENDING]"
  assert_contains "$prompt" "edit it instead of adding another comment"
  assert_contains "$prompt" "Save no checklist"
}

test_runthrough_qa_checklist_prompt_defines_execution_and_progress_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/runthrough-qa-checklist.md"
  [[ -f "$prompt_file" ]] || fail "expected runthrough-qa-checklist prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "<!-- ralph:qa-checklist -->"
  assert_contains "$prompt" "todo"
  assert_contains "$prompt" "free local ports"
  assert_contains "$prompt" "Stub all external calls"
  assert_contains "$prompt" "local databases"
  assert_contains "$prompt" "[PASS]"
  assert_contains "$prompt" "[FAIL]"
  assert_contains "$prompt" "[BLOCKED]"
  assert_contains "$prompt" "local-resources.json"
  assert_contains "$prompt" "do not fail this step"
}

test_multi_axis_pr_review_prompt_defines_four_skill_vote_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/multi-axis-pr-review.md"
  [[ -f "$prompt_file" ]] || fail "expected multi-axis-pr-review prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "exactly four parallel"
  assert_contains "$prompt" "matt-pocock-code-review/SKILL.md"
  assert_contains "$prompt" "ponytail-review/SKILL.md"
  assert_contains "$prompt" "run-codex-review/SKILL.md"
  assert_contains "$prompt" "supe-review-code-changes/SKILL.md"
  assert_contains "$prompt" "run-codex-review/scripts/review.mjs"
  assert_contains "$prompt" "KEEP"
  assert_contains "$prompt" "DISCARD"
  assert_contains "$prompt" "Deduplicate"
  assert_contains "$prompt" "<!-- ralph:multi-axis-review -->"
  assert_contains "$prompt" "Do not apply"
}

test_cleanup_local_resources_prompt_defines_owned_always_run_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/cleanup-local-resources.md"
  [[ -f "$prompt_file" ]] || fail "expected cleanup-local-resources prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "after an earlier step fails"
  assert_contains "$prompt" "local-resources.json"
  assert_contains "$prompt" "Docker containers"
  assert_contains "$prompt" "browser or computer-use sessions"
  assert_contains "$prompt" "project worktree"
  assert_contains "$prompt" "Never use"
  assert_contains "$prompt" "ralph-{{ISSUE}}-"
  assert_contains "$prompt" 'Do not invoke the post-merge `cleanup.sh`'
  assert_contains "$prompt" "cleanup-local-resources.md"
}

test_removed_review_prompts_are_absent() {
  local name

  for name in review-slice final-review pr-review review-fixes; do
    [[ ! -e "$ROOT_DIR/prompts/$name.md" ]] || fail "expected removed prompt to be absent: $name"
  done
}

test_grill_with_docs_skill_defines_planning_branch_contract() {
  local skill_file skill

  skill_file="$ROOT_DIR/skills/grill-with-docs/SKILL.md"
  [[ -f "$skill_file" ]] || fail "expected grill-with-docs skill at $skill_file"

  skill="$(<"$skill_file")"

  assert_contains "$skill" "git status --short --branch"
  assert_contains "$skill" "git branch --show-current"
  assert_contains "$skill" "refs/remotes/origin/HEAD"
  assert_contains "$skill" "working tree is already dirty"
  assert_contains "$skill" "planning branch"
  assert_contains "$skill" "grill/issue-<issue-number>-<slug>"
  assert_contains "$skill" "git checkout -b grill/issue-<issue-number>-<slug>"
  assert_contains "$skill" "git push -u origin grill/issue-<issue-number>-<slug>"
  assert_contains "$skill" "baseBranch"
  assert_contains "$skill" 'do not run `init` yet'
  assert_contains "$skill" "Facts vs. decisions"
  assert_contains "$skill" "Confirmation gate"
  assert_contains "$skill" "wayfinder"
}

run_test test_init_prompt_defines_complete_workspace_initialization_contract
run_test test_initialized_workspace_status_shows_default_three_pending_fixed_steps
run_test test_review_decisions_prompt_defines_council_filtering_and_hitl_contract
run_test test_create_prd_prompt_defines_full_prd_workflow_contract
run_test test_create_slices_prompt_defines_full_slice_creation_contract
run_test test_preflight_prompt_defines_full_preflight_workflow_contract
run_test test_implement_slice_prompt_defines_full_implementation_workflow_contract
run_test test_final_checks_prompt_defines_read_only_check_contract
run_test test_pr_creation_prompt_defines_idempotent_pr_only_contract
run_test test_prepare_qa_checklist_prompt_defines_local_comment_contract
run_test test_runthrough_qa_checklist_prompt_defines_execution_and_progress_contract
run_test test_multi_axis_pr_review_prompt_defines_four_skill_vote_contract
run_test test_cleanup_local_resources_prompt_defines_owned_always_run_contract
run_test test_removed_review_prompts_are_absent
run_test test_grill_with_docs_skill_defines_planning_branch_contract

echo "prompt_contracts_test.sh passed"
