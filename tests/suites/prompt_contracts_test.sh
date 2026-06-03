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
  assert_contains "$prompt" '"reviewRounds": 1'
  assert_contains "$prompt" "Default is 1"
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
  assert_contains "$prompt" "to-prd"
  assert_contains "$prompt" "Decision Summary"
  assert_contains "$prompt" "Problem Statement"
  assert_contains "$prompt" "User Stories"
  assert_contains "$prompt" "Implementation Decisions"
  assert_contains "$prompt" "Testing Decisions"
  assert_contains "$prompt" "scripts/council-review.sh"
  assert_contains "$prompt" "Round 1"
  assert_contains "$prompt" "Round 2"
  assert_contains "$prompt" "**1 (default):** Run only Round 1"
  assert_contains "$prompt" 'If `reviewRounds` is missing, default to 1'
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
  assert_contains "$prompt" "to-issues"
  assert_contains "$prompt" "tracer bullets"
  assert_contains "$prompt" "horizontal"
  assert_contains "$prompt" "scripts/council-review.sh"
  assert_contains "$prompt" "Round 1"
  assert_contains "$prompt" "Round 2"
  assert_contains "$prompt" "**1 (default):** Run only Round 1"
  assert_contains "$prompt" 'If `reviewRounds` is missing, default to 1'
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
  assert_contains "$prompt" "implement-slice"
  assert_contains "$prompt" "final-review"
  assert_contains "$prompt" "pr-review"
  assert_contains "$prompt" "review-fixes"
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
  assert_contains "$prompt" "tdd/deep-modules.md"
  assert_contains "$prompt" "tdd/interface-design.md"
  assert_contains "$prompt" "tdd/refactoring.md"
  assert_contains "$prompt" "gh issue view {{ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "gh issue view {{SUB_ISSUE}} --repo {{REPO}}"
  assert_contains "$prompt" "Write one failing test first"
  assert_contains "$prompt" "Run quality checks from CLAUDE.md"
  assert_contains "$prompt" "git checkout {{BRANCH}}"
  assert_contains "$prompt" "git commit"
  assert_contains "$prompt" "#{{SUB_ISSUE}}"
  assert_contains "$prompt" "git push"
  assert_contains "$prompt" "gh issue close {{SUB_ISSUE}} --repo {{REPO}}"
}

test_final_review_prompt_defines_full_review_workflow_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/final-review.md"
  [[ -f "$prompt_file" ]] || fail "expected final-review prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "Issue: {{ISSUE}}"
  assert_contains "$prompt" "Repo: {{REPO}}"
  assert_contains "$prompt" "Workspace: {{WORKSPACE}}"
  assert_contains "$prompt" "Branch: {{BRANCH}}"
  assert_contains "$prompt" "Base branch: {{BASE_BRANCH}}"
  assert_contains "$prompt" "Step: {{STEP_ID}}"
  assert_contains "$prompt" "Skills: {{SKILLS_DIR}}"
  assert_contains "$prompt" "Default agent: codex"
  assert_contains "$prompt" "git diff --name-only {{BASE_BRANCH}}...HEAD"
  assert_contains "$prompt" "Progressively read changed files"
  assert_contains "$prompt" "Run quality checks from CLAUDE.md"
  assert_contains "$prompt" "Verify acceptance criteria from each sub-issue"
  assert_contains "$prompt" "side effects"
  assert_contains "$prompt" "missing pieces"
  assert_contains "$prompt" "scope creep"
  assert_contains "$prompt" "Update CONTEXT.md"
  assert_contains "$prompt" "Update CLAUDE.md"
  assert_contains "$prompt" "{{WORKSPACE}}/final-review.md"
}

test_pr_review_prompt_defines_full_pr_workflow_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/pr-review.md"
  [[ -f "$prompt_file" ]] || fail "expected pr-review prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "Issue: {{ISSUE}}"
  assert_contains "$prompt" "Repo: {{REPO}}"
  assert_contains "$prompt" "Workspace: {{WORKSPACE}}"
  assert_contains "$prompt" "Branch: {{BRANCH}}"
  assert_contains "$prompt" "Base branch: {{BASE_BRANCH}}"
  assert_contains "$prompt" "Step: {{STEP_ID}}"
  assert_contains "$prompt" "Skills: {{SKILLS_DIR}}"
  assert_contains "$prompt" "Step agent: {{AGENT}}"
  assert_contains "$prompt" "Default agent: codex"
  assert_contains "$prompt" "gh pr list"
  assert_contains "$prompt" "gh pr create"
  assert_contains "$prompt" "--base {{BASE_BRANCH}}"
  assert_contains "$prompt" "--head {{BRANCH}}"
  assert_contains "$prompt" "summary of changes"
  assert_contains "$prompt" "linked sub-issues"
  assert_contains "$prompt" 'Closes #{{ISSUE}}'
  assert_contains "$prompt" "Closes #<sub-issue>"
  assert_contains "$prompt" "human QA checklist"
  assert_contains "$prompt" "code-review:code-review"
  assert_contains "$prompt" "review --base"
  assert_contains "$prompt" "codex-pr-review.md"
  assert_contains "$prompt" "PR comments"
  assert_contains "$prompt" "idempotent"
  assert_contains "$prompt" "Do not create duplicate PRs"
}

test_review_fixes_prompt_defines_full_review_fixes_workflow_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/review-fixes.md"
  [[ -f "$prompt_file" ]] || fail "expected review-fixes prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "Issue: {{ISSUE}}"
  assert_contains "$prompt" "Repo: {{REPO}}"
  assert_contains "$prompt" "Workspace: {{WORKSPACE}}"
  assert_contains "$prompt" "Branch: {{BRANCH}}"
  assert_contains "$prompt" "Base branch: {{BASE_BRANCH}}"
  assert_contains "$prompt" "Step: {{STEP_ID}}"
  assert_contains "$prompt" "Skills: {{SKILLS_DIR}}"
  assert_contains "$prompt" "Default agent: codex"
  assert_contains "$prompt" "pr-review.md"
  assert_contains "$prompt" "final-review.md"
  assert_contains "$prompt" "gh api"
  assert_contains "$prompt" "issues/<pr-number>/comments"
  assert_contains "$prompt" "pulls/<pr-number>/comments"
  assert_contains "$prompt" "code-review:code-review"
  assert_contains "$prompt" "codex review"
  assert_contains "$prompt" "Fix"
  assert_contains "$prompt" "Dismiss"
  assert_contains "$prompt" "Run quality checks from CLAUDE.md"
  assert_contains "$prompt" "git commit"
  assert_contains "$prompt" "git push"
  assert_contains "$prompt" "gh pr comment"
  assert_contains "$prompt" "review-fixes-comment.md"
  assert_contains "$prompt" "review-fixes.md"
  assert_contains "$prompt" "zero"
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
}

run_test test_init_prompt_defines_complete_workspace_initialization_contract
run_test test_initialized_workspace_status_shows_default_three_pending_fixed_steps
run_test test_review_decisions_prompt_defines_council_filtering_and_hitl_contract
run_test test_create_prd_prompt_defines_full_prd_workflow_contract
run_test test_create_slices_prompt_defines_full_slice_creation_contract
run_test test_preflight_prompt_defines_full_preflight_workflow_contract
run_test test_implement_slice_prompt_defines_full_implementation_workflow_contract
run_test test_final_review_prompt_defines_full_review_workflow_contract
run_test test_pr_review_prompt_defines_full_pr_workflow_contract
run_test test_review_fixes_prompt_defines_full_review_fixes_workflow_contract
run_test test_grill_with_docs_skill_defines_planning_branch_contract

echo "prompt_contracts_test.sh passed"
