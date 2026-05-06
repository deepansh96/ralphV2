#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RALPH="$ROOT_DIR/ralph.sh"
CLEANUP_SCRIPT="$ROOT_DIR/cleanup.sh"
PROJECT_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
WORKSPACES_DIR="$ROOT_DIR/workspaces"
ARCHIVE_DIR="$ROOT_DIR/archive"
CONTEXT_FILE="$PROJECT_ROOT/CONTEXT.md"
INITIAL_CONTEXT_BACKUP="$(mktemp)"
INITIAL_CONTEXT_PRESENT="false"
TEST_ISSUES=(42 9001 9002 9003 9004 9005 9006 9007 9008 9009 9010 9011 9012 9013 9014 9015 9016 9018 9019 9020 9021 9022 9023 9024 9025 9026 9027 9028 9029 9030 9031 9032 9033 9034 9035 9036 9037 9038 9039 9040 9041 9042 9043 9044 9045)

if [[ -f "$CONTEXT_FILE" ]]; then
  cp "$CONTEXT_FILE" "$INITIAL_CONTEXT_BACKUP"
  INITIAL_CONTEXT_PRESENT="true"
fi

cleanup() {
  local issue

  if [[ "$INITIAL_CONTEXT_PRESENT" == "true" ]]; then
    cp "$INITIAL_CONTEXT_BACKUP" "$CONTEXT_FILE"
  else
    rm -f "$CONTEXT_FILE"
  fi
  rm -f "$INITIAL_CONTEXT_BACKUP"

  for issue in "${TEST_ISSUES[@]}"; do
    rm -rf "${WORKSPACES_DIR:?}/$issue"
    rm -rf "${ARCHIVE_DIR:?}/"*-"$issue"
  done
  rm -rf "${WORKSPACES_DIR:?}/fake-bin"
  rmdir "$ARCHIVE_DIR" 2>/dev/null || true
}

trap cleanup EXIT
cleanup

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"

  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"$'\n'"actual: $haystack"
}

backup_context_once() {
  mkdir -p "$WORKSPACES_DIR"
}

remove_context() {
  backup_context_once
  rm -f "$CONTEXT_FILE"
}

write_valid_context() {
  backup_context_once
  cat > "$CONTEXT_FILE" <<'CONTEXT'
# Ralph

Ralph is an autonomous coding agent orchestrator.

## Language

**Pipeline**:
An ordered set of steps Ralph runs for one GitHub issue.
_Avoid_: Loop

**Step**:
A resumable unit of pipeline work tracked in state.json.
_Avoid_: Iteration

## Relationships

- A **Pipeline** contains one or more **Steps**
- A **Step** belongs to exactly one **Pipeline**

## Example dialogue

> **Dev:** "Can I restart the **Pipeline** after a failed **Step**?"
> **Domain expert:** "Yes, reset the **Step** status and rerun Ralph."

## Flagged ambiguities

- "iteration" means the v1 loop; v2 uses **Step**.
CONTEXT
}

write_insufficient_context() {
  backup_context_once
  cat > "$CONTEXT_FILE" <<'CONTEXT'
# Ralph

Intentionally incomplete fixture.
CONTEXT
}

write_single_step_state() {
  local issue="$1"
  local step_id="$2"
  local status="$3"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    --arg id "$step_id" \
    --arg status "$status" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: $id,
          type: "stub",
          agent: "stub",
          status: $status,
          metrics: { duration: null },
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"
}

write_two_step_state() {
  local issue="$1"
  local first_status="$2"
  local second_status="$3"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    --arg first_status "$first_status" \
    --arg second_status "$second_status" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "first-step",
          type: "stub",
          agent: "stub",
          status: $first_status,
          metrics: { duration: "1s" },
          notes: ""
        },
        {
          id: "second-step",
          type: "stub",
          agent: "stub",
          status: $second_status,
          metrics: { duration: null },
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"
}

install_fake_claude() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
jq -n -c --arg prompt "$prompt" '{
  type: "result",
  subtype: "success",
  result: (
    if ($prompt | contains("CONTEXT_CHECK_REQUIRED")) then
      "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format."
    else
      "claude saw: " + $prompt
    end
  ),
  duration_ms: 1234,
  usage: {
    input_tokens: 11,
    output_tokens: 7
  },
  total_cost_usd: 0.02
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_context_check_claude() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
if [[ "$prompt" == *"Intentionally incomplete fixture"* ]]; then
  jq -n -c '{
    type: "result",
    subtype: "success",
    result: "CONTEXT_CHECK: FAIL\nMissing required sections: Language, Relationships, Example dialogue, Flagged ambiguities.",
    duration_ms: 100,
    usage: {
      input_tokens: 1,
      output_tokens: 1
    },
    total_cost_usd: 0.01
  }'
else
  jq -n -c '{
    type: "result",
    subtype: "success",
    result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
    duration_ms: 100,
    usage: {
      input_tokens: 1,
      output_tokens: 1
    },
    total_cost_usd: 0.01
  }'
fi
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_interrupt_once_claude() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

marker="$(dirname "$0")/interrupted-once"
prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "$prompt" == *"CONTEXT_CHECK_REQUIRED"* ]]; then
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
  jq -n -c '{
    type: "result",
    subtype: "success",
    result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
    duration_ms: 100,
    usage: {
      input_tokens: 1,
      output_tokens: 1
    },
    total_cost_usd: 0.01
  }'
  exit 0
fi

if [[ ! -f "$marker" ]]; then
  touch "$marker"
  kill -INT "$PPID"
  sleep 1
  exit 130
fi

printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
jq -n -c '{
  type: "result",
  subtype: "success",
  result: "completed after interrupt",
  duration_ms: 100,
  usage: {
    input_tokens: 1,
    output_tokens: 1
  },
  total_cost_usd: 0.01
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_sleeping_claude() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "$prompt" == *"CONTEXT_CHECK_REQUIRED"* ]]; then
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
  jq -n -c '{
    type: "result",
    subtype: "success",
    result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
    duration_ms: 100,
    usage: {
      input_tokens: 1,
      output_tokens: 1
    },
    total_cost_usd: 0.01
  }'
  exit 0
fi

sleep 2
printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
jq -n -c '{
  type: "result",
  subtype: "success",
  result: "completed after sleep",
  duration_ms: 2000,
  usage: {
    input_tokens: 1,
    output_tokens: 1
  },
  total_cost_usd: 0.01
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_hitl_claude() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "$prompt" == *"CONTEXT_CHECK_REQUIRED"* ]]; then
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
  jq -n -c '{
    type: "result",
    subtype: "success",
    result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
    duration_ms: 100,
    usage: {
      input_tokens: 1,
      output_tokens: 1
    },
    total_cost_usd: 0.01
  }'
  exit 0
fi

workspace="$(awk '/^Workspace / { print $2; exit }' <<<"$prompt")"
step_id="$(awk '/^Step / { print $2; exit }' <<<"$prompt")"
state_file="$workspace/state.json"
flag_file="$workspace/hitl-$step_id.md"

if [[ "$prompt" == *"This step was previously blocked for human input"* ]]; then
  [[ "$prompt" == *"Use the reviewed option"* ]] || exit 41
  [[ "$prompt" == *"Do not repeat any council or review phase"* ]] || exit 42
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
  jq -n -c --arg prompt "$prompt" '{
    type: "result",
    subtype: "success",
    result: ("resumed with: " + $prompt),
    duration_ms: 222,
    usage: {
      input_tokens: 3,
      output_tokens: 2
    },
    total_cost_usd: 0.03
  }'
  exit 0
fi

jq --arg id "$step_id" '
  .steps |= map(if .id == $id then .status = "blocked" else . end)
' "$state_file" > "$state_file.tmp"
mv "$state_file.tmp" "$state_file"

cat > "$flag_file" <<'FLAG'
## Questions

Which option should the review continue with?

## Answers
FLAG

printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
jq -n -c '{
  type: "result",
  subtype: "success",
  result: "blocked for human input",
  duration_ms: 111,
  usage: {
    input_tokens: 2,
    output_tokens: 1
  },
  total_cost_usd: 0.02
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_review_decisions_claude() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "$prompt" == *"CONTEXT_CHECK_REQUIRED"* ]]; then
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
  jq -n -c '{
    type: "result",
    subtype: "success",
    result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
    duration_ms: 100,
    usage: {
      input_tokens: 1,
      output_tokens: 1
    },
    total_cost_usd: 0.01
  }'
  exit 0
fi

workspace="$(awk '/^Workspace:/ { print $2; exit }' <<<"$prompt")"
step_id="$(awk '/^Step:/ { print $2; exit }' <<<"$prompt")"
state_file="$workspace/state.json"
flag_file="$workspace/hitl-$step_id.md"
findings_file="$workspace/review-decisions.md"

if [[ "$prompt" == *"This step was previously blocked for human input"* ]]; then
  [[ "$prompt" == *"complete WITHOUT re-running council review"* ]] || exit 51
  [[ "$prompt" == *"Use the architecture option"* ]] || exit 52
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
  jq -n -c --arg prompt "$prompt" '{
    type: "result",
    subtype: "success",
    result: ("completed without rerunning council: " + $prompt),
    duration_ms: 222,
    usage: {
      input_tokens: 3,
      output_tokens: 2
    },
    total_cost_usd: 0.03
  }'
  exit 0
fi

[[ "$prompt" == *"scripts/council-review.sh"* ]] || exit 61
[[ "$prompt" == *"Major feedback"* ]] || exit 62
[[ "$prompt" == *"nitpick"* ]] || exit 63
[[ "$prompt" == *"review-decisions.md"* ]] || exit 64

cat > "$findings_file" <<'FINDINGS'
# Review Decisions

## Major feedback

- Major issue: baseBranch must be explicit before preflight.

## Open questions

- Which architecture option should Ralph use?
FINDINGS

jq --arg id "$step_id" '
  .steps |= map(if .id == $id then .status = "blocked" else . end)
' "$state_file" > "$state_file.tmp"
mv "$state_file.tmp" "$state_file"

cat > "$flag_file" <<'FLAG'
## Questions

Which architecture option should Ralph use?

## Answers
FLAG

printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
jq -n -c '{
  type: "result",
  subtype: "success",
  result: "blocked after review-decisions council feedback",
  duration_ms: 111,
  usage: {
    input_tokens: 2,
    output_tokens: 1
  },
  total_cost_usd: 0.02
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_create_prd_claude() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "$prompt" == *"CONTEXT_CHECK_REQUIRED"* ]]; then
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
  jq -n -c '{
    type: "result",
    subtype: "success",
    result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
    duration_ms: 100,
    usage: {
      input_tokens: 1,
      output_tokens: 1
    },
    total_cost_usd: 0.01
  }'
  exit 0
fi

workspace="$(awk '/^Workspace:/ { print $2; exit }' <<<"$prompt")"
original_file="$workspace/original-issue.md"
issue_body_file="$workspace/github-issue-body.md"

[[ "$prompt" == *"gh issue view"* ]] || exit 71
[[ "$prompt" == *"--repo"* ]] || exit 70
[[ "$prompt" == *"CONTEXT.md"* ]] || exit 72
[[ "$prompt" == *"CLAUDE.md"* ]] || exit 73
[[ "$prompt" == *"docs/adr"* ]] || exit 74
[[ "$prompt" == *"Explore the codebase"* ]] || exit 75
[[ "$prompt" == *"to-prd"* ]] || exit 76
[[ "$prompt" == *"Round 1"* ]] || exit 77
[[ "$prompt" == *"Round 2"* ]] || exit 78
[[ "$prompt" == *"gh issue edit"* ]] || exit 79
[[ "$prompt" == *"Do not append a second PRD"* ]] || exit 80

if [[ ! -f "$original_file" ]]; then
  printf 'Original grilled issue body\n' > "$original_file"
fi

cat > "$issue_body_file" <<'PRD'
## Decision Summary

- Workflow: create-and-review-prd preserves original issue body and updates the issue with one PRD.

## Problem Statement

The pipeline needs a PRD before slice planning can begin.

## Solution

Create a reviewed PRD from the grilled issue decisions.

## User Stories

1. As a developer, I want the create-and-review-prd step to update the existing issue, so that the issue remains the source of truth.

## Implementation Decisions

- Prompt-driven workflow: The agent performs issue reading, review, preservation, and update.

## Testing Decisions

- Test through the Ralph pipeline and prompt contract.

## Out of Scope

- Slice creation and preflight.

## Further Notes

- Re-runs replace this body instead of appending another PRD.
PRD

printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
jq -n -c '{
  type: "result",
  subtype: "success",
  result: "create-and-review-prd preserved original and updated issue body",
  duration_ms: 333,
  usage: {
    input_tokens: 5,
    output_tokens: 4
  },
  total_cost_usd: 0.04
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_create_slices_claude() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "$prompt" == *"CONTEXT_CHECK_REQUIRED"* ]]; then
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
  jq -n -c '{
    type: "result",
    subtype: "success",
    result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
    duration_ms: 100,
    usage: {
      input_tokens: 1,
      output_tokens: 1
    },
    total_cost_usd: 0.01
  }'
  exit 0
fi

workspace="$(awk '/^Workspace:/ { print $2; exit }' <<<"$prompt")"
slices_file="$workspace/slices.md"
sub_issues_file="$workspace/github-sub-issues.md"

[[ "$prompt" == *"gh issue view"* ]] || exit 81
[[ "$prompt" == *"CONTEXT.md"* ]] || exit 82
[[ "$prompt" == *"CLAUDE.md"* ]] || exit 83
[[ "$prompt" == *"docs/adr"* ]] || exit 84
[[ "$prompt" == *"to-issues"* ]] || exit 85
[[ "$prompt" == *"tracer bullets"* ]] || exit 86
[[ "$prompt" == *"Round 1"* ]] || exit 87
[[ "$prompt" == *"Round 2"* ]] || exit 88
[[ "$prompt" == *"gh issue create"* ]] || exit 89
[[ "$prompt" == *"addSubIssue"* ]] || exit 90
[[ "$prompt" == *"AFK"* ]] || exit 91
[[ "$prompt" == *"duplicates"* ]] || exit 92

if [[ ! -f "$sub_issues_file" ]]; then
  cat > "$sub_issues_file" <<'ISSUES'
# Created Sub-Issues

- #9101 Slice: prompt contract (AFK: true, linked via addSubIssue)
- #9102 Slice: idempotent creation (AFK: true, linked via addSubIssue)
ISSUES
fi

cat > "$slices_file" <<'SLICES'
# Slices

## Created or reused sub-issues

- #9101 newly created and linked
- #9102 newly created and linked
SLICES

printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
jq -n -c '{
  type: "result",
  subtype: "success",
  result: "create-and-review-slices created AFK sub-issues and linked them under parent",
  duration_ms: 444,
  usage: {
    input_tokens: 6,
    output_tokens: 5
  },
  total_cost_usd: 0.05
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_failing_claude() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "$prompt" == *"CONTEXT_CHECK_REQUIRED"* ]]; then
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
  jq -n -c '{
    type: "result",
    subtype: "success",
    result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
    duration_ms: 100,
    usage: {
      input_tokens: 1,
      output_tokens: 1
    },
    total_cost_usd: 0.01
  }'
  exit 0
fi

echo "agent failed deliberately" >&2
exit 42
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_codex() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail

last_message_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message)
      last_message_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

prompt="$(cat)"
if [[ -n "$last_message_file" ]]; then
  printf 'codex saw: %s\n' "$prompt" > "$last_message_file"
fi

printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":13,"output_tokens":8}}'
FAKE_CODEX
  chmod +x "$fake_bin/codex"

  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
jq -n -c '{
  type: "result",
  subtype: "success",
  result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
  duration_ms: 100,
  usage: {
    input_tokens: 1,
    output_tokens: 1
  },
  total_cost_usd: 0.01
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_implement_slice_codex() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail

last_message_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message)
      last_message_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

prompt="$(cat)"
[[ "$prompt" == *"Issue: 9020"* ]] || exit 101
[[ "$prompt" == *"Repo: deepansh96/ralph"* ]] || exit 102
[[ "$prompt" == *"Workspace: "*"/workspaces/9020"* ]] || exit 103
[[ "$prompt" == *"Branch: feat/issue-9020-implementation-workflow"* ]] || exit 104
[[ "$prompt" == *"Base branch: main"* ]] || exit 105
[[ "$prompt" == *"Step: implement-slice-9111"* ]] || exit 106
[[ "$prompt" == *"Sub-issue: 9111"* ]] || exit 107
[[ "$prompt" == *"Skills: "*"/skills"* ]] || exit 108
[[ "$prompt" == *"CONTEXT.md"* ]] || exit 109
[[ "$prompt" == *"CLAUDE.md"* ]] || exit 110
[[ "$prompt" == *"docs/adr"* ]] || exit 111
[[ "$prompt" == *"tdd/SKILL.md"* ]] || exit 112
[[ "$prompt" == *"tdd/tests.md"* ]] || exit 113
[[ "$prompt" == *"tdd/mocking.md"* ]] || exit 114
[[ "$prompt" == *"tdd/deep-modules.md"* ]] || exit 115
[[ "$prompt" == *"tdd/interface-design.md"* ]] || exit 116
[[ "$prompt" == *"tdd/refactoring.md"* ]] || exit 117
[[ "$prompt" == *"gh issue view 9020 --repo deepansh96/ralph"* ]] || exit 118
[[ "$prompt" == *"gh issue view 9111 --repo deepansh96/ralph"* ]] || exit 119
[[ "$prompt" == *"Write one failing test first"* ]] || exit 120
[[ "$prompt" == *"Run quality checks from CLAUDE.md"* ]] || exit 121
[[ "$prompt" == *"git checkout feat/issue-9020-implementation-workflow"* ]] || exit 122
[[ "$prompt" == *"git commit"* ]] || exit 123
[[ "$prompt" == *"#9111"* ]] || exit 124
[[ "$prompt" == *"git push"* ]] || exit 125
[[ "$prompt" == *"gh issue close 9111 --repo deepansh96/ralph"* ]] || exit 126
[[ "$prompt" == *"agent: codex"* ]] || exit 127
[[ "$prompt" == *"AFK"* ]] || exit 128

if [[ -n "$last_message_file" ]]; then
  printf 'implemented, committed, pushed, and closed sub-issue\n' > "$last_message_file"
fi

printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":21,"output_tokens":34}}'
FAKE_CODEX
  chmod +x "$fake_bin/codex"

  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
jq -n -c '{
  type: "result",
  subtype: "success",
  result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
  duration_ms: 100,
  usage: {
    input_tokens: 1,
    output_tokens: 1
  },
  total_cost_usd: 0.01
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_final_and_pr_review_claude() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      prompt="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "$prompt" == *"CONTEXT_CHECK_REQUIRED"* ]]; then
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
  jq -n -c '{
    type: "result",
    subtype: "success",
    result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
    duration_ms: 100,
    usage: {
      input_tokens: 1,
      output_tokens: 1
    },
    total_cost_usd: 0.01
  }'
  exit 0
fi

workspace="$(awk '/^Workspace:/ { print $2; exit }' <<<"$prompt")"
step_id="$(awk '/^Step:/ { print $2; exit }' <<<"$prompt")"

printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
case "$step_id" in
  final-review)
    [[ "$prompt" == *"Issue: 9021"* ]] || exit 131
    [[ "$prompt" == *"Repo: deepansh96/ralph"* ]] || exit 132
    [[ "$prompt" == *"Branch: feat/issue-9021-final-pr-workflow"* ]] || exit 133
    [[ "$prompt" == *"Base branch: main"* ]] || exit 134
    [[ "$prompt" == *"git diff --name-only main...HEAD"* ]] || exit 135
    [[ "$prompt" == *"Progressively read changed files"* ]] || exit 136
    [[ "$prompt" == *"Run quality checks from CLAUDE.md"* ]] || exit 137
    [[ "$prompt" == *"Verify acceptance criteria from each sub-issue"* ]] || exit 138
    [[ "$prompt" == *"side effects"* ]] || exit 139
    [[ "$prompt" == *"scope creep"* ]] || exit 140
    [[ "$prompt" == *"Update CONTEXT.md"* ]] || exit 141
    [[ "$prompt" == *"Update CLAUDE.md"* ]] || exit 142
    cat > "$workspace/final-review.md" <<'FINAL_REVIEW'
# Final Review

## Changed files reviewed

- ralph-v2/prompts/final-review.md
- ralph-v2/prompts/pr-review.md

## Quality checks

- bash ralph-v2/tests/test_ralph_v2.sh passed

## Acceptance criteria verification

- #9111: satisfied

## Documentation updates

- No durable project documentation changes discovered.

## Findings

- No blockers.

## Outcome

Pass.
FINAL_REVIEW
    jq -n -c '{
      type: "result",
      subtype: "success",
      result: "final review verified changed files, checks, acceptance criteria, and docs",
      duration_ms: 555,
      usage: {
        input_tokens: 8,
        output_tokens: 7
      },
      total_cost_usd: 0.06
    }'
    ;;
  pr-review)
    [[ "$prompt" == *"gh pr list"* ]] || exit 151
    [[ "$prompt" == *"gh pr create"* ]] || exit 152
    [[ "$prompt" == *"--base main"* ]] || exit 153
    [[ "$prompt" == *"--head feat/issue-9021-final-pr-workflow"* ]] || exit 154
    [[ "$prompt" == *"summary of changes"* ]] || exit 155
    [[ "$prompt" == *"linked sub-issues"* ]] || exit 156
    [[ "$prompt" == *"human QA checklist"* ]] || exit 157
    [[ "$prompt" == *"code-review:code-review"* ]] || exit 158
    [[ "$prompt" == *"PR comments"* ]] || exit 159
    [[ "$prompt" == *"Do not create duplicate PRs"* ]] || exit 160
    cat > "$workspace/pr-body.md" <<'PR_BODY'
## Summary

- Added final-review and pr-review prompt workflows.

## Linked Issues

- Closes #9111
- Parent: #9021

## Final Review

- Pass.

## Human QA Checklist

- [ ] Run the Ralph v2 test suite.
PR_BODY
    if [[ ! -f "$workspace/github-pr.md" ]]; then
      printf '1\n' > "$workspace/github-pr-create-count"
      printf 'created PR #77\n' > "$workspace/github-pr.md"
      action="created"
    else
      action="updated"
    fi
    cat > "$workspace/pr-review.md" <<PR_REVIEW
# PR Review

- PR: #77 https://github.com/deepansh96/ralph/pull/77
- Action: $action
- Linked sub-issues: #9111
- code-review:code-review invoked and review comments posted.
PR_REVIEW
    jq -n -c --arg action "$action" '{
      type: "result",
      subtype: "success",
      result: ("pr-review " + $action + " PR and invoked code-review:code-review"),
      duration_ms: 666,
      usage: {
        input_tokens: 9,
        output_tokens: 8
      },
      total_cost_usd: 0.07
    }'
    ;;
  review-fixes)
    [[ "$prompt" == *"pr-review.md"* ]] || exit 161
    [[ "$prompt" == *"final-review.md"* ]] || exit 162
    [[ "$prompt" == *"gh api"* ]] || exit 163
    [[ "$prompt" == *"code-review:code-review"* ]] || exit 164
    [[ "$prompt" == *"Fix"* ]] || exit 165
    [[ "$prompt" == *"Dismiss"* ]] || exit 166
    [[ "$prompt" == *"gh pr comment"* ]] || exit 167
    cat > "$workspace/review-fixes-comment.md" <<'COMMENT'
## Review Fixes Assessment

### 1. Missing error handling in dashboard.sh

**Disposition:** Fixed

**Reasoning:** Valid — added set -e and error check.

## Summary

- Total findings: 1
- Fixed: 1
- Dismissed: 0
COMMENT
    cat > "$workspace/review-fixes.md" <<'REVIEW_FIXES'
# Review Fixes

## PR

- PR number: #77
- PR URL: https://github.com/deepansh96/ralph/pull/77

## Findings Evaluated

### 1. Missing error handling in dashboard.sh

**Finding:** dashboard.sh does not exit on error.

**Disposition:** Fixed

**Reasoning:** Valid concern — added set -e.

**Changes:** dashboard/dashboard.sh

## Summary

- Total findings: 1
- Fixed: 1
- Dismissed: 0
- Commit: abc1234
- Quality checks: passed
REVIEW_FIXES
    jq -n -c '{
      type: "result",
      subtype: "success",
      result: "review-fixes evaluated 1 finding, fixed 1, dismissed 0",
      duration_ms: 444,
      usage: {
        input_tokens: 10,
        output_tokens: 9
      },
      total_cost_usd: 0.05
    }'
    ;;
  *)
    echo "unexpected step: $step_id" >&2
    exit 170
    ;;
esac
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_council_success() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/council" <<'FAKE_COUNCIL'
#!/usr/bin/env bash
set -euo pipefail

calls_file="$(dirname "$0")/council-calls"
status_file="$(dirname "$0")/council-status-count"
command_name="${1:-}"
shift || true
printf '%s %s\n' "$command_name" "$*" >> "$calls_file"

case "$command_name" in
  ask)
    cat >/dev/null
    printf '%s\n' '{"runId":"run-123","members":["codex"],"dataDir":".council/run-123"}'
    ;;
  status)
    count=0
    [[ -f "$status_file" ]] && count="$(<"$status_file")"
    count=$((count + 1))
    printf '%s' "$count" > "$status_file"
    if [[ "$count" -lt 2 ]]; then
      printf '%s\n' '{"run_id":"run-123","running":true,"members":{"codex":{"status":"working","bytes":0,"elapsed_seconds":1}}}'
    else
      printf '%s\n' '{"run_id":"run-123","running":false,"members":{"codex":{"status":"done","exit_code":0,"bytes":10,"elapsed_seconds":2}}}'
    fi
    ;;
  read)
    printf '%s\n' '{"run_id":"run-123","members":{"codex":{"status":"done","exit_code":0,"output":"Major issue: baseBranch is still null before preflight."}}}'
    ;;
  cleanup)
    printf 'cleaned\n'
    ;;
  *)
    echo "unexpected council command: $command_name" >&2
    exit 90
    ;;
esac
FAKE_COUNCIL
  chmod +x "$fake_bin/council"
}

install_fake_council_failure() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/council" <<'FAKE_COUNCIL'
#!/usr/bin/env bash
set -euo pipefail

calls_file="$(dirname "$0")/council-calls"
command_name="${1:-}"
shift || true
printf '%s %s\n' "$command_name" "$*" >> "$calls_file"

case "$command_name" in
  ask)
    cat >/dev/null
    printf '%s\n' '{"runId":"run-456","members":["codex"],"dataDir":".council/run-456"}'
    ;;
  status)
    printf '%s\n' '{"run_id":"run-456","running":false,"members":{"codex":{"status":"failed","exit_code":42,"bytes":0,"elapsed_seconds":2}}}'
    ;;
  cleanup)
    printf 'cleaned\n'
    ;;
  *)
    echo "unexpected council command: $command_name" >&2
    exit 90
    ;;
esac
FAKE_COUNCIL
  chmod +x "$fake_bin/council"
}

install_fake_council_timeout() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/council" <<'FAKE_COUNCIL'
#!/usr/bin/env bash
set -euo pipefail

calls_file="$(dirname "$0")/council-calls"
command_name="${1:-}"
shift || true
printf '%s %s\n' "$command_name" "$*" >> "$calls_file"

case "$command_name" in
  ask)
    cat >/dev/null
    printf '%s\n' '{"runId":"run-789","members":["codex"],"dataDir":".council/run-789"}'
    ;;
  status)
    printf '%s\n' '{"run_id":"run-789","running":true,"members":{"codex":{"status":"working","bytes":0,"elapsed_seconds":2}}}'
    ;;
  cleanup)
    printf 'cleaned\n'
    ;;
  *)
    echo "unexpected council command: $command_name" >&2
    exit 90
    ;;
esac
FAKE_COUNCIL
  chmod +x "$fake_bin/council"
}

test_issue_must_be_positive_integer() {
  local output status

  set +e
  output="$("$RALPH" --issue nope 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected invalid issue to fail"
  assert_contains "$output" "--issue must be a positive integer"
}

test_cleanup_archives_workspace_by_issue_number() {
  local issue date destination output

  issue="42"
  date="$(date +%Y-%m-%d)"
  destination="$ARCHIVE_DIR/$date-$issue"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$destination"
  mkdir -p "$WORKSPACES_DIR/$issue"
  printf "state\n" > "$WORKSPACES_DIR/$issue/state.json"

  output="$("$CLEANUP_SCRIPT" "$issue")"

  [[ ! -d "$WORKSPACES_DIR/$issue" ]] || fail "expected workspace to be moved"
  [[ -f "$destination/state.json" ]] || fail "expected archived state.json"
  [[ "$(ls -1 "$WORKSPACES_DIR" | grep -x "$issue" || true)" == "" ]] || fail "workspace still listed"
  assert_contains "$output" "$WORKSPACES_DIR/$issue"
  assert_contains "$output" "$destination"
}

test_cleanup_errors_when_workspace_is_missing() {
  local issue output status

  issue="9022"
  rm -rf "${WORKSPACES_DIR:?}/$issue"

  set +e
  output="$("$CLEANUP_SCRIPT" "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected missing workspace cleanup to fail"
  assert_contains "$output" "workspace not found"
  assert_contains "$output" "$WORKSPACES_DIR/$issue"
}

test_cleanup_errors_when_archive_destination_exists() {
  local issue date destination output status

  issue="9023"
  date="$(date +%Y-%m-%d)"
  destination="$ARCHIVE_DIR/$date-$issue"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$destination"
  mkdir -p "$WORKSPACES_DIR/$issue" "$destination"

  set +e
  output="$("$CLEANUP_SCRIPT" "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected existing archive cleanup to fail"
  [[ -d "$WORKSPACES_DIR/$issue" ]] || fail "expected workspace to remain when archive exists"
  assert_contains "$output" "archive destination already exists"
  assert_contains "$output" "$destination"
}

test_cleanup_validates_issue_number() {
  local output status

  set +e
  output="$("$CLEANUP_SCRIPT" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected missing cleanup issue to fail"
  assert_contains "$output" "issue number is required"

  set +e
  output="$("$CLEANUP_SCRIPT" "0" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected invalid cleanup issue to fail"
  assert_contains "$output" "issue number must be a positive integer"
}

test_cleanup_removes_empty_workspaces_directory() {
  local issue date destination output test_workspaces

  issue="9024"
  date="$(date +%Y-%m-%d)"
  destination="$ARCHIVE_DIR/$date-$issue"
  test_workspaces="$(mktemp -d "${WORKSPACES_DIR}.isolated.XXXXXX")"
  rm -rf "$destination"
  mkdir -p "$test_workspaces/$issue"
  printf "state\n" > "$test_workspaces/$issue/state.json"

  output="$(RALPH_V2_WORKSPACES_DIR="$test_workspaces" "$CLEANUP_SCRIPT" "$issue")"

  [[ -d "$destination" ]] || fail "expected archived workspace"
  [[ ! -d "$test_workspaces" ]] || fail "expected empty workspaces directory to be removed"
  assert_contains "$output" "$test_workspaces/$issue"
  assert_contains "$output" "$destination"
}

test_run_requires_existing_state() {
  local issue output status

  issue="9001"
  rm -rf "${WORKSPACES_DIR:?}/$issue"

  set +e
  output="$("$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected missing state to fail"
  assert_contains "$output" "state.json not found"
  assert_contains "$output" "run init.md first"
}

test_run_rejects_failed_steps() {
  local issue output status

  issue="9002"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "stub-step" "failed"

  set +e
  output="$("$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected failed step pre-check to fail"
  assert_contains "$output" "failed steps"
  assert_contains "$output" "set status to pending or completed"
}

test_run_hard_stops_when_context_missing() {
  local issue output status status_value

  issue="9013"
  remove_context
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "stub-step" "pending"

  set +e
  output="$("$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected missing CONTEXT.md to fail"
  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status_value" == "pending" ]] || fail "expected step to remain pending, got $status_value"
  assert_contains "$output" "CONTEXT.md not found"
  assert_contains "$output" "$CONTEXT_FILE"
}

test_run_hard_stops_when_context_is_insufficient() {
  local issue output status status_value fake_bin log_file

  issue="9014"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_insufficient_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_context_check_claude "$fake_bin"
  write_single_step_state "$issue" "stub-step" "pending"

  set +e
  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected insufficient CONTEXT.md to fail"
  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status_value" == "pending" ]] || fail "expected step to remain pending, got $status_value"
  log_file="$WORKSPACES_DIR/$issue/logs/check-context.log"
  [[ -f "$log_file" ]] || fail "expected context check log file"
  assert_contains "$output" "CONTEXT.md is insufficient"
  assert_contains "$output" "Missing required sections"
}

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

test_status_prints_step_table() {
  local issue output

  issue="9004"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "stub-step" "in_progress"

  output="$("$RALPH" status --issue "$issue")"

  assert_contains "$output" "#"
  assert_contains "$output" "Step ID"
  assert_contains "$output" "Type"
  assert_contains "$output" "Agent"
  assert_contains "$output" "Status"
  assert_contains "$output" "Duration"
  assert_contains "$output" "stub-step"
  assert_contains "$output" "stub"
  assert_contains "$output" "in_progress"
}

test_logs_tails_active_step_log() {
  local issue output

  issue="9005"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_two_step_state "$issue" "completed" "in_progress"
  printf "active log line\n" > "$WORKSPACES_DIR/$issue/logs/second-step.log"
  printf "old log line\n" > "$WORKSPACES_DIR/$issue/logs/first-step.log"

  output="$("$RALPH" logs --issue "$issue")"

  assert_contains "$output" "active log line"
  [[ "$output" != *"old log line"* ]] || fail "expected active logs to exclude inactive step log"
}

test_logs_tails_specific_step_log() {
  local issue output

  issue="9006"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_two_step_state "$issue" "completed" "in_progress"
  printf "specific completed log\n" > "$WORKSPACES_DIR/$issue/logs/first-step.log"
  printf "active log\n" > "$WORKSPACES_DIR/$issue/logs/second-step.log"

  output="$("$RALPH" logs --issue "$issue" --step first-step)"

  assert_contains "$output" "specific completed log"
  [[ "$output" != *"active log"* ]] || fail "expected --step logs to exclude active step log"
}

test_claude_agent_step_renders_prompt_logs_metrics_and_summary() {
  local issue output fake_bin log_file status_value duration_value input_tokens cost_value

  issue="9007"
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
      branch: "feat/issue-9007-fixture",
      steps: [
        {
          id: "claude-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          sub_issue: 77,
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue")"

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  duration_value="$(jq -r '.steps[0].metrics.duration_ms' "$WORKSPACES_DIR/$issue/state.json")"
  input_tokens="$(jq -r '.steps[0].metrics.input_tokens' "$WORKSPACES_DIR/$issue/state.json")"
  cost_value="$(jq -r '.steps[0].metrics.cost_usd' "$WORKSPACES_DIR/$issue/state.json")"
  log_file="$WORKSPACES_DIR/$issue/logs/claude-step.log"

  [[ "$status_value" == "completed" ]] || fail "expected claude step to complete, got $status_value"
  [[ "$duration_value" == "1234" ]] || fail "expected duration_ms metric, got $duration_value"
  [[ "$input_tokens" == "11" ]] || fail "expected input_tokens metric, got $input_tokens"
  [[ "$cost_value" == "0.02" ]] || fail "expected cost_usd metric, got $cost_value"
  [[ -f "$log_file" ]] || fail "expected claude step log file"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "claude saw: Issue 9007"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Repo deepansh96/ralph"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Workspace $WORKSPACES_DIR/$issue"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Branch feat/issue-9007-fixture"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Base main"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Step claude-step"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Sub 77"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "Skills $ROOT_DIR/skills"
  assert_contains "$output" "Step ID"
  assert_contains "$output" "claude-step"
  assert_contains "$output" "completed"
  assert_contains "$output" "1234"
}

test_codex_agent_step_logs_jsonl_and_records_metrics() {
  local issue output fake_bin log_file status_value input_tokens output_tokens cost_value

  issue="9008"
  write_valid_context
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_codex "$fake_bin"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9008-fixture",
      steps: [
        {
          id: "codex-step",
          type: "test-fixture",
          agent: "codex",
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
  cost_value="$(jq -r '.steps[0].metrics.cost_usd' "$WORKSPACES_DIR/$issue/state.json")"
  log_file="$WORKSPACES_DIR/$issue/logs/codex-step.log"

  [[ "$status_value" == "completed" ]] || fail "expected codex step to complete, got $status_value"
  [[ "$input_tokens" == "13" ]] || fail "expected codex input_tokens metric, got $input_tokens"
  [[ "$output_tokens" == "8" ]] || fail "expected codex output_tokens metric, got $output_tokens"
  [[ "$cost_value" == "null" ]] || fail "expected codex cost_usd to be null, got $cost_value"
  [[ -f "$log_file" ]] || fail "expected codex step log file"
  assert_contains "$(tr '\n' ' ' < "$log_file")" "turn.completed"
  assert_contains "$output" "codex-step"
  assert_contains "$output" "codex"
}

test_sigint_resets_running_step_to_pending_and_rerun_picks_it_up() {
  local issue output fake_bin status first_status second_status

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

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null
  second_status="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$second_status" == "completed" ]] || fail "expected rerun to complete same step, got $second_status"
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
}

test_initialized_workspace_status_shows_four_pending_fixed_steps() {
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
          id: "review-decisions",
          phase: "fixed",
          type: "review-decisions",
          status: "pending",
          agent: "claude",
          reviewers: ["codex", "gemini", "kimi", "deepseek"],
          hitl: true,
          metrics: null,
          notes: ""
        },
        {
          id: "create-and-review-prd",
          phase: "fixed",
          type: "create-and-review-prd",
          status: "pending",
          agent: "claude",
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
          agent: "claude",
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
          agent: "claude",
          reviewers: [],
          hitl: false,
          metrics: null,
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  output="$("$RALPH" status --issue "$issue")"
  pending_count="$(grep -c "pending" <<<"$output")"

  [[ "$pending_count" == "4" ]] || fail "expected 4 pending steps in status output, got $pending_count: $output"
  assert_contains "$output" "review-decisions"
  assert_contains "$output" "create-and-review-prd"
  assert_contains "$output" "create-and-review-slices"
  assert_contains "$output" "preflight"
}

test_council_review_submits_polls_reads_cleans_up_and_prints_review() {
  local fake_bin output calls

  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "$fake_bin"
  install_fake_council_success "$fake_bin"

  output="$(printf 'Review these decisions' | PATH="$fake_bin:$PATH" RALPH_COUNCIL_POLL_INTERVAL=0 "$ROOT_DIR/scripts/council-review.sh")"
  calls="$(<"$fake_bin/council-calls")"

  assert_contains "$output" "Major issue: baseBranch is still null"
  assert_contains "$calls" "ask"
  assert_contains "$calls" "status"
  assert_contains "$calls" "read"
  assert_contains "$calls" "cleanup"
}

test_council_review_handles_member_failure_and_cleans_up() {
  local fake_bin output calls status

  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "$fake_bin"
  install_fake_council_failure "$fake_bin"

  set +e
  output="$(PATH="$fake_bin:$PATH" RALPH_COUNCIL_POLL_INTERVAL=0 "$ROOT_DIR/scripts/council-review.sh" "Review these decisions" 2>&1)"
  status=$?
  set -e
  calls="$(<"$fake_bin/council-calls")"

  [[ "$status" -ne 0 ]] || fail "expected failed council member to fail"
  assert_contains "$output" "all council members failed"
  assert_contains "$calls" "cleanup"
}

test_council_review_handles_timeout_and_cleans_up() {
  local fake_bin output calls status

  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "$fake_bin"
  install_fake_council_timeout "$fake_bin"

  set +e
  output="$(PATH="$fake_bin:$PATH" RALPH_COUNCIL_TIMEOUT_SECONDS=0 RALPH_COUNCIL_POLL_INTERVAL=0 "$ROOT_DIR/scripts/council-review.sh" "Review these decisions" 2>&1)"
  status=$?
  set -e
  calls="$(<"$fake_bin/council-calls")"

  [[ "$status" -ne 0 ]] || fail "expected council timeout to fail"
  assert_contains "$output" "timed out"
  assert_contains "$calls" "cleanup"
}

test_review_decisions_prompt_defines_council_filtering_and_hitl_contract() {
  local prompt_file prompt

  prompt_file="$ROOT_DIR/prompts/review-decisions.md"
  [[ -f "$prompt_file" ]] || fail "expected review-decisions prompt template at $prompt_file"

  prompt="$(<"$prompt_file")"

  assert_contains "$prompt" "gh issue view {{ISSUE}} --repo {{REPO}}"
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
  assert_contains "$prompt" "CONTEXT.md"
  assert_contains "$prompt" "CLAUDE.md"
  assert_contains "$prompt" "docs/adr"
  assert_contains "$prompt" "to-issues"
  assert_contains "$prompt" "tracer bullets"
  assert_contains "$prompt" "horizontal"
  assert_contains "$prompt" "scripts/council-review.sh"
  assert_contains "$prompt" "Round 1"
  assert_contains "$prompt" "Round 2"
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
  assert_contains "$prompt" "clear guidance"
  assert_contains "$prompt" "feat/issue-{{ISSUE}}-<slug>"
  assert_contains "$prompt" "kebab"
  assert_contains "$prompt" "git push"
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
  assert_contains "$prompt" "agent: codex"
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
  assert_contains "$prompt" "agent: claude"
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
  assert_contains "$prompt" "agent: claude"
  assert_contains "$prompt" "gh pr list"
  assert_contains "$prompt" "gh pr create"
  assert_contains "$prompt" "--base {{BASE_BRANCH}}"
  assert_contains "$prompt" "--head {{BRANCH}}"
  assert_contains "$prompt" "summary of changes"
  assert_contains "$prompt" "linked sub-issues"
  assert_contains "$prompt" "human QA checklist"
  assert_contains "$prompt" "code-review:code-review"
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
  assert_contains "$prompt" "agent: claude"
  assert_contains "$prompt" "pr-review.md"
  assert_contains "$prompt" "final-review.md"
  assert_contains "$prompt" "gh api"
  assert_contains "$prompt" "issues/<pr-number>/comments"
  assert_contains "$prompt" "pulls/<pr-number>/comments"
  assert_contains "$prompt" "code-review:code-review"
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

test_skills_bundle_is_self_contained_and_readme_documents_workflow() {
  local required_files readme global_skill_ref stale_refs broken_links link_records file target target_without_anchor resolved

  required_files=(
    "$ROOT_DIR/skills/to-prd/SKILL.md"
    "$ROOT_DIR/skills/to-issues/SKILL.md"
    "$ROOT_DIR/skills/grill-with-docs/SKILL.md"
    "$ROOT_DIR/skills/tdd/SKILL.md"
    "$ROOT_DIR/skills/tdd/tests.md"
    "$ROOT_DIR/skills/tdd/mocking.md"
    "$ROOT_DIR/skills/tdd/deep-modules.md"
    "$ROOT_DIR/skills/tdd/interface-design.md"
    "$ROOT_DIR/skills/tdd/refactoring.md"
    "$ROOT_DIR/skills/domain/DOMAIN-AWARENESS.md"
    "$ROOT_DIR/skills/domain/CONTEXT-FORMAT.md"
    "$ROOT_DIR/skills/domain/ADR-FORMAT.md"
  )

  for file in "${required_files[@]}"; do
    [[ -f "$file" ]] || fail "expected bundled skill file: $file"
  done

  global_skill_ref="~/.claude/""skills"
  stale_refs="$(grep -R "$global_skill_ref" "$ROOT_DIR/skills" 2>/dev/null || true)"
  [[ -z "$stale_refs" ]] || fail "expected no global skill directory references in bundled skills: $stale_refs"

  link_records="$(perl -ne 'if (/^```/) { $in_fence = !$in_fence; next } next if $in_fence; while (/\[[^\]]+\]\(([^)]+)\)/g) { print "$ARGV:$1\n" }' "${required_files[@]}")"
  broken_links=""
  while IFS= read -r link_record; do
    [[ -n "$link_record" ]] || continue
    file="${link_record%%:*}"
    target="${link_record#*:}"
    case "$target" in
      http://*|https://*|mailto:*|\#*|/*)
        continue
        ;;
    esac

    target_without_anchor="${target%%#*}"
    [[ -n "$target_without_anchor" ]] || continue
    resolved="$(cd "$(dirname "$file")" && cd "$(dirname "$target_without_anchor")" 2>/dev/null && pwd)/$(basename "$target_without_anchor")"
    [[ -e "$resolved" ]] || broken_links+="$file -> $target"$'\n'
  done <<< "$link_records"
  [[ -z "$broken_links" ]] || fail "expected all bundled skill relative links to resolve:"$'\n'"$broken_links"

  readme="$ROOT_DIR/README.md"
  [[ -f "$readme" ]] || fail "expected ralph-v2 README"
  assert_contains "$(<"$readme")" "ralph.sh --issue N"
  assert_contains "$(<"$readme")" "ralph.sh status --issue N"
  assert_contains "$(<"$readme")" "ralph.sh logs --issue N"
  assert_contains "$(<"$readme")" "cleanup.sh <issue-number>"
  assert_contains "$(<"$readme")" "grill"
  assert_contains "$(<"$readme")" "init"
  assert_contains "$(<"$readme")" "run"
  assert_contains "$(<"$readme")" "cleanup"
  assert_contains "$(<"$readme")" "state.json"
  assert_contains "$(<"$readme")" "review-decisions"
  assert_contains "$(<"$readme")" "implement-slice"
  assert_contains "$(<"$readme")" "pr-review"
  assert_contains "$(<"$readme")" "review-fixes"
}

test_state_add_steps_appends_dynamic_steps_and_rejects_duplicates() {
  local issue state_file duplicate_output status ids agents sub_issues output

  issue="9019"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  state_file="$WORKSPACES_DIR/$issue/state.json"

  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9019-fixture",
      steps: [
        {
          id: "preflight",
          phase: "fixed",
          type: "preflight",
          agent: "claude",
          reviewers: [],
          hitl: false,
          status: "completed",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"

  source "$ROOT_DIR/scripts/state.sh"

  state_add_steps "$state_file" '[
    {
      "id": "implement-slice-9101",
      "phase": "dynamic",
      "type": "implement-slice",
      "agent": "codex",
      "reviewers": [],
      "hitl": false,
      "status": "pending",
      "sub_issue": 9101,
      "metrics": null,
      "notes": ""
    },
    {
      "id": "implement-slice-9102",
      "phase": "dynamic",
      "type": "implement-slice",
      "agent": "codex",
      "reviewers": [],
      "hitl": false,
      "status": "pending",
      "sub_issue": 9102,
      "metrics": null,
      "notes": ""
    },
    {
      "id": "final-review",
      "phase": "dynamic",
      "type": "final-review",
      "agent": "claude",
      "reviewers": [],
      "hitl": false,
      "status": "pending",
      "metrics": null,
      "notes": ""
    },
    {
      "id": "pr-review",
      "phase": "dynamic",
      "type": "pr-review",
      "agent": "claude",
      "reviewers": ["codex", "gemini", "kimi", "deepseek"],
      "hitl": false,
      "status": "pending",
      "metrics": null,
      "notes": ""
    },
    {
      "id": "review-fixes",
      "phase": "dynamic",
      "type": "review-fixes",
      "agent": "claude",
      "reviewers": [],
      "hitl": false,
      "status": "pending",
      "metrics": null,
      "notes": ""
    }
  ]'

  ids="$(jq -r '.steps[].id' "$state_file" | tr '\n' ' ')"
  agents="$(jq -r '.steps[] | select(.phase == "dynamic") | "\(.type):\(.agent)"' "$state_file" | tr '\n' ' ')"
  sub_issues="$(jq -r '.steps[] | select(.type == "implement-slice") | .sub_issue' "$state_file" | tr '\n' ' ')"

  assert_contains "$ids" "preflight implement-slice-9101 implement-slice-9102 final-review pr-review review-fixes"
  assert_contains "$agents" "implement-slice:codex"
  assert_contains "$agents" "final-review:claude"
  assert_contains "$agents" "pr-review:claude"
  assert_contains "$agents" "review-fixes:claude"
  assert_contains "$sub_issues" "9101 9102"

  output="$("$RALPH" status --issue "$issue")"
  assert_contains "$output" "implement-slice-9101"
  assert_contains "$output" "implement-slice-9102"
  assert_contains "$output" "final-review"
  assert_contains "$output" "pr-review"
  assert_contains "$output" "review-fixes"

  set +e
  duplicate_output="$(state_add_steps "$state_file" '[{"id":"implement-slice-9101","phase":"dynamic","type":"implement-slice","agent":"codex","status":"pending"}]' 2>&1)"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected duplicate dynamic step id to fail"
  assert_contains "$duplicate_output" "duplicate step id"
  [[ "$(jq '.steps | length' "$state_file")" == "6" ]] || fail "expected duplicate failure not to append steps"
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
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9020-implementation-workflow",
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

test_codex_step_uses_project_root_from_state_json() {
  local issue fake_bin status_value log_file cwd_file

  issue="9025"
  write_valid_context
  fake_bin="$WORKSPACES_DIR/fake-bin"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"

  mkdir -p "$fake_bin"
  cwd_file="$fake_bin/codex-cwd"
  cat > "$fake_bin/codex" <<FAKE_CODEX
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$(pwd)" > "$cwd_file"
while [[ \$# -gt 0 ]]; do shift; done
cat >/dev/null
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
FAKE_CODEX
  chmod +x "$fake_bin/codex"

  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
jq -n -c '{
  type: "result",
  subtype: "success",
  result: "CONTEXT_CHECK: PASS\nCONTEXT.md follows the required format.",
  duration_ms: 100,
  usage: { input_tokens: 1, output_tokens: 1 },
  total_cost_usd: 0.01
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --arg issue "$issue" \
    --arg project_root "$PROJECT_ROOT" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9025-fixture",
      projectRoot: $project_root,
      steps: [
        {
          id: "codex-step",
          type: "test-fixture",
          agent: "codex",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null

  status_value="$(jq -r '.steps[0].status' "$WORKSPACES_DIR/$issue/state.json")"
  [[ "$status_value" == "completed" ]] || fail "expected codex step to complete, got $status_value"
  [[ -f "$cwd_file" ]] || fail "expected codex cwd file to exist"

  local actual_cwd
  actual_cwd="$(<"$cwd_file")"
  [[ "$actual_cwd" == "$PROJECT_ROOT" ]] || fail "expected codex to run in $PROJECT_ROOT, got $actual_cwd"
}

test_state_update_step_sets_started_at_on_in_progress() {
  local issue state_file started_at

  issue="9026"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "timing-step" "pending"
  state_file="$WORKSPACES_DIR/$issue/state.json"

  source "$ROOT_DIR/scripts/state.sh"

  state_update_step "$state_file" "timing-step" "in_progress"

  started_at="$(jq -r '.steps[0].started_at // empty' "$state_file")"
  [[ -n "$started_at" ]] || fail "expected started_at to be set when status is in_progress"
  [[ "$started_at" =~ ^[0-9]+$ ]] || fail "expected started_at to be epoch seconds, got: $started_at"

  local now_epoch
  now_epoch="$(date +%s)"
  local diff=$(( now_epoch - started_at ))
  [[ "$diff" -ge 0 && "$diff" -lt 5 ]] || fail "expected started_at to be close to now, diff=$diff"
}

test_state_update_step_clears_started_at_on_pending() {
  local issue state_file started_at

  issue="9027"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "reset-step" "pending"
  state_file="$WORKSPACES_DIR/$issue/state.json"

  source "$ROOT_DIR/scripts/state.sh"

  state_update_step "$state_file" "reset-step" "in_progress"
  started_at="$(jq -r '.steps[0].started_at // empty' "$state_file")"
  [[ -n "$started_at" ]] || fail "expected started_at to be set after in_progress"

  state_update_step "$state_file" "reset-step" "pending"
  started_at="$(jq '.steps[0].started_at' "$state_file")"
  [[ "$started_at" == "null" ]] || fail "expected started_at to be null after reset to pending, got: $started_at"
}

test_state_update_step_tracks_and_clears_pid() {
  local issue state_file pid_file pid_value state_pid

  issue="9034"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_single_step_state "$issue" "pid-step" "pending"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  pid_file="$WORKSPACES_DIR/$issue/pids/pid-step.pid"
  pid_value="12345"

  source "$ROOT_DIR/scripts/state.sh"

  state_update_step "$state_file" "pid-step" "in_progress" "null" "null" "$pid_value"

  state_pid="$(jq -r '.steps[0].pid' "$state_file")"
  [[ "$state_pid" == "$pid_value" ]] || fail "expected state pid $pid_value, got $state_pid"
  [[ -f "$pid_file" ]] || fail "expected pid file to be created"
  [[ "$(<"$pid_file")" == "$pid_value" ]] || fail "expected pid file to contain $pid_value"

  state_update_step "$state_file" "pid-step" "completed"

  state_pid="$(jq -r '.steps[0].pid' "$state_file")"
  [[ "$state_pid" == "null" ]] || fail "expected pid to clear on completed, got $state_pid"
  [[ ! -f "$pid_file" ]] || fail "expected pid file to be removed on completed"

  state_update_step "$state_file" "pid-step" "in_progress" "null" "null" "$pid_value"
  state_update_step "$state_file" "pid-step" "pending"
  state_pid="$(jq -r '.steps[0].pid' "$state_file")"
  [[ "$state_pid" == "null" ]] || fail "expected pid to clear on pending, got $state_pid"
  [[ ! -f "$pid_file" ]] || fail "expected pid file to be removed on pending"

  state_update_step "$state_file" "pid-step" "in_progress" "null" "null" "$pid_value"
  state_update_step "$state_file" "pid-step" "failed"
  state_pid="$(jq -r '.steps[0].pid' "$state_file")"
  [[ "$state_pid" == "null" ]] || fail "expected pid to clear on failed, got $state_pid"
  [[ ! -f "$pid_file" ]] || fail "expected pid file to be removed on failed"
}

test_run_pipeline_records_current_shell_pid_while_step_runs() {
  local issue fake_bin state_file pid_file ralph_pid state_pid file_pid final_status

  issue="9039"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_sleeping_claude "$fake_bin"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  pid_file="$WORKSPACES_DIR/$issue/pids/sleeping-step.pid"

  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9039-fixture",
      steps: [
        {
          id: "sleeping-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"

  PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" >/dev/null &
  ralph_pid="$!"

  for _ in {1..100}; do
    [[ -f "$pid_file" ]] && break
    kill -0 "$ralph_pid" 2>/dev/null || break
    sleep 0.05
  done

  [[ -f "$pid_file" ]] || fail "expected pid file while ralph step is running"
  state_pid="$(jq -r '.steps[0].pid' "$state_file")"
  file_pid="$(<"$pid_file")"
  [[ "$state_pid" == "$ralph_pid" ]] || fail "expected state pid $ralph_pid, got $state_pid"
  [[ "$file_pid" == "$ralph_pid" ]] || fail "expected pid file $ralph_pid, got $file_pid"

  wait "$ralph_pid"
  final_status="$(jq -r '.steps[0].status' "$state_file")"
  [[ "$final_status" == "completed" ]] || fail "expected sleeping step to complete, got $final_status"
  [[ "$(jq -r '.steps[0].pid' "$state_file")" == "null" ]] || fail "expected pid to clear after completion"
  [[ ! -f "$pid_file" ]] || fail "expected pid file to be removed after completion"
}

test_background_run_exits_immediately_writes_wrapper_pid_and_completes() {
  local issue fake_bin state_file wrapper_pid_file output status elapsed status_value wrapper_pid wrapper_log start_epoch

  issue="9040"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_sleeping_claude "$fake_bin"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  wrapper_pid_file="$WORKSPACES_DIR/$issue/step-runner.pid"
  wrapper_log="$WORKSPACES_DIR/$issue/logs/wrapper.log"

  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9040-fixture",
      steps: [
        {
          id: "sleeping-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"

  start_epoch="$(date +%s)"
  set +e
  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" --background 2>&1)"
  status=$?
  set -e
  elapsed=$(( $(date +%s) - start_epoch ))

  [[ "$status" -eq 0 ]] || fail "expected background run to exit 0, got $status: $output"
  [[ "$elapsed" -lt 2 ]] || fail "expected background run to exit within 2s, took ${elapsed}s"
  [[ -f "$wrapper_pid_file" ]] || fail "expected wrapper PID file"
  wrapper_pid="$(<"$wrapper_pid_file")"
  [[ "$wrapper_pid" =~ ^[0-9]+$ ]] || fail "expected numeric wrapper PID, got $wrapper_pid"
  assert_contains "$output" "$wrapper_pid"
  kill -0 "$wrapper_pid" 2>/dev/null || fail "expected wrapper process $wrapper_pid to be alive immediately after launch"

  for _ in {1..100}; do
    status_value="$(jq -r '.steps[0].status' "$state_file")"
    [[ "$status_value" == "completed" ]] && break
    sleep 0.05
  done

  status_value="$(jq -r '.steps[0].status' "$state_file")"
  [[ "$status_value" == "completed" ]] || fail "expected background wrapper to complete step, got $status_value"
  [[ -f "$wrapper_log" ]] || fail "expected wrapper log file"
}

test_poll_blocks_until_step_completes_then_exits_zero() {
  local issue state_file output status now_epoch wrapper_pid updater_pid

  issue="9041"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs" "$WORKSPACES_DIR/$issue/pids"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  now_epoch="$(date +%s)"
  sleep 60 &
  wrapper_pid="$!"

  jq -n \
    --arg issue "$issue" \
    --argjson started_at "$now_epoch" \
    --argjson pid "$wrapper_pid" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "poll-step",
          type: "stub",
          agent: "stub",
          status: "in_progress",
          started_at: $started_at,
          pid: $pid,
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"
  printf '%s\n' "$wrapper_pid" > "$WORKSPACES_DIR/$issue/step-runner.pid"
  printf '%s\n' "$wrapper_pid" > "$WORKSPACES_DIR/$issue/pids/poll-step.pid"

  (
    sleep 0.2
    jq '.steps[0].status = "completed" | .steps[0].pid = null' "$state_file" > "$state_file.tmp"
    mv "$state_file.tmp" "$state_file"
  ) &
  updater_pid="$!"

  set +e
  output="$(RALPH_POLL_INTERVAL=0.05 "$RALPH" poll --issue "$issue" 2>&1)"
  status=$?
  set -e

  wait "$updater_pid"
  kill "$wrapper_pid" 2>/dev/null || true

  [[ "$status" -eq 0 ]] || fail "expected poll to exit 0 after completion, got $status: $output"
  assert_contains "$output" "poll-step"
  assert_contains "$output" "alive"
  assert_contains "$output" "Pipeline complete"
}

test_poll_exits_one_when_step_fails() {
  local issue state_file output status

  issue="9042"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  state_file="$WORKSPACES_DIR/$issue/state.json"

  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "failed-step",
          type: "stub",
          agent: "stub",
          status: "failed",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"

  set +e
  output="$(RALPH_POLL_INTERVAL=0.05 "$RALPH" poll --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected poll to exit 1 for failed step, got $status: $output"
  assert_contains "$output" "Step failed-step failed"
}

test_poll_exits_zero_when_step_is_blocked_for_hitl() {
  local issue state_file flag_file output status

  issue="9043"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  flag_file="$WORKSPACES_DIR/$issue/hitl-blocked-step.md"

  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "blocked-step",
          type: "stub",
          agent: "stub",
          status: "blocked",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"
  printf '## Questions\n\nNeed input.\n' > "$flag_file"

  set +e
  output="$(RALPH_POLL_INTERVAL=0.05 "$RALPH" poll --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected poll to exit 0 for blocked step, got $status: $output"
  assert_contains "$output" "blocked for human input"
  assert_contains "$output" "$flag_file"
}

test_poll_detects_dead_wrapper_pid_and_exits_one() {
  local issue state_file output status now_epoch started_at dead_pid status_value

  issue="9044"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs" "$WORKSPACES_DIR/$issue/pids"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  now_epoch="$(date +%s)"
  started_at=$(( now_epoch - 10 ))
  dead_pid="999999"

  jq -n \
    --arg issue "$issue" \
    --argjson started_at "$started_at" \
    --argjson pid "$dead_pid" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "dead-wrapper-step",
          type: "stub",
          agent: "stub",
          status: "in_progress",
          started_at: $started_at,
          pid: $pid,
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"
  printf '%s\n' "$dead_pid" > "$WORKSPACES_DIR/$issue/step-runner.pid"
  printf '%s\n' "$dead_pid" > "$WORKSPACES_DIR/$issue/pids/dead-wrapper-step.pid"

  set +e
  output="$(RALPH_STALE_THRESHOLD=1 RALPH_POLL_INTERVAL=0.05 "$RALPH" poll --issue "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 1 ]] || fail "expected poll to exit 1 for dead wrapper PID, got $status: $output"
  assert_contains "$output" "Wrapper PID $dead_pid is dead"
  status_value="$(jq -r '.steps[0].status' "$state_file")"
  [[ "$status_value" == "pending" ]] || fail "expected stale detection to reset step to pending, got $status_value"
}

test_background_run_respects_steps_limit() {
  local issue fake_bin state_file output status first_status second_status

  issue="9045"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  write_valid_context
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$fake_bin"
  install_fake_claude "$fake_bin"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  state_file="$WORKSPACES_DIR/$issue/state.json"

  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      repo: "deepansh96/ralph",
      baseBranch: "main",
      branch: "feat/issue-9045-fixture",
      steps: [
        {
          id: "first-background-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          metrics: {},
          notes: ""
        },
        {
          id: "second-background-step",
          type: "test-fixture",
          agent: "claude",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"

  set +e
  output="$(PATH="$fake_bin:$PATH" "$RALPH" --issue "$issue" --background --steps 1 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected background --steps run to launch, got $status: $output"
  for _ in {1..100}; do
    first_status="$(jq -r '.steps[0].status' "$state_file")"
    [[ "$first_status" == "completed" ]] && break
    sleep 0.05
  done

  first_status="$(jq -r '.steps[0].status' "$state_file")"
  second_status="$(jq -r '.steps[1].status' "$state_file")"
  [[ "$first_status" == "completed" ]] || fail "expected first background step completed, got $first_status"
  [[ "$second_status" == "pending" ]] || fail "expected second background step pending after --steps 1, got $second_status"
  assert_contains "$(<"$WORKSPACES_DIR/$issue/logs/wrapper.log")" "Step limit reached (1/1)"
}

test_state_validate_resets_stale_in_progress_step_without_pid_file() {
  local issue state_file now_epoch started_at output status status_value started_value

  issue="9035"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  now_epoch="$(date +%s)"
  started_at=$(( now_epoch - 10 ))

  jq -n \
    --arg issue "$issue" \
    --argjson started_at "$started_at" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "stale-step",
          type: "stub",
          agent: "stub",
          status: "in_progress",
          started_at: $started_at,
          pid: null,
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"

  source "$ROOT_DIR/scripts/state.sh"

  set +e
  output="$(RALPH_STALE_THRESHOLD=1 state_validate "$state_file" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected stale reset validation to succeed, got $status: $output"
  status_value="$(jq -r '.steps[0].status' "$state_file")"
  started_value="$(jq '.steps[0].started_at' "$state_file")"
  [[ "$status_value" == "pending" ]] || fail "expected stale step to reset to pending, got $status_value"
  [[ "$started_value" == "null" ]] || fail "expected stale step started_at to clear, got $started_value"
  assert_contains "$output" "Warning"
  assert_contains "$output" "stale-step"
}

test_state_validate_keeps_stale_in_progress_step_with_live_pid() {
  local issue state_file now_epoch started_at pid output status status_value

  issue="9036"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs" "$WORKSPACES_DIR/$issue/pids"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  now_epoch="$(date +%s)"
  started_at=$(( now_epoch - 10 ))
  sleep 60 &
  pid="$!"

  jq -n \
    --arg issue "$issue" \
    --argjson started_at "$started_at" \
    --argjson pid "$pid" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "live-step",
          type: "stub",
          agent: "stub",
          status: "in_progress",
          started_at: $started_at,
          pid: $pid,
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"
  printf '%s\n' "$pid" > "$WORKSPACES_DIR/$issue/pids/live-step.pid"

  source "$ROOT_DIR/scripts/state.sh"

  set +e
  output="$(RALPH_STALE_THRESHOLD=1 state_validate "$state_file" 2>&1)"
  status=$?
  set -e
  kill "$pid" 2>/dev/null || true

  [[ "$status" -eq 0 ]] || fail "expected live PID validation to succeed, got $status: $output"
  status_value="$(jq -r '.steps[0].status' "$state_file")"
  [[ "$status_value" == "in_progress" ]] || fail "expected live PID step to remain in_progress, got $status_value"
  [[ "$output" != *"Warning"* ]] || fail "expected no stale warning for live PID, got: $output"
}

test_state_validate_resets_stale_in_progress_step_with_dead_pid_file() {
  local issue state_file now_epoch started_at dead_pid output status status_value

  issue="9038"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs" "$WORKSPACES_DIR/$issue/pids"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  now_epoch="$(date +%s)"
  started_at=$(( now_epoch - 10 ))
  dead_pid="999999"

  jq -n \
    --arg issue "$issue" \
    --argjson started_at "$started_at" \
    --argjson dead_pid "$dead_pid" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "dead-step",
          type: "stub",
          agent: "stub",
          status: "in_progress",
          started_at: $started_at,
          pid: $dead_pid,
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"
  printf '%s\n' "$dead_pid" > "$WORKSPACES_DIR/$issue/pids/dead-step.pid"

  source "$ROOT_DIR/scripts/state.sh"

  set +e
  output="$(RALPH_STALE_THRESHOLD=1 state_validate "$state_file" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected dead PID stale validation to succeed, got $status: $output"
  status_value="$(jq -r '.steps[0].status' "$state_file")"
  [[ "$status_value" == "pending" ]] || fail "expected dead PID step to reset to pending, got $status_value"
  [[ ! -f "$WORKSPACES_DIR/$issue/pids/dead-step.pid" ]] || fail "expected dead PID file to be removed"
  assert_contains "$output" "Warning"
  assert_contains "$output" "dead-step"
}

test_status_shows_elapsed_time_for_in_progress_step() {
  local issue state_file output now_epoch started_at

  issue="9028"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  state_file="$WORKSPACES_DIR/$issue/state.json"

  now_epoch="$(date +%s)"
  started_at=$(( now_epoch - 125 ))

  jq -n \
    --arg issue "$issue" \
    --argjson started_at "$started_at" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "completed-step",
          type: "stub",
          agent: "stub",
          status: "completed",
          metrics: { duration_ms: 65000 },
          notes: ""
        },
        {
          id: "running-step",
          type: "stub",
          agent: "stub",
          status: "in_progress",
          started_at: $started_at,
          metrics: {},
          notes: ""
        },
        {
          id: "waiting-step",
          type: "stub",
          agent: "stub",
          status: "pending",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"

  output="$("$RALPH" status --issue "$issue")"

  assert_contains "$output" "1m 5s"
  assert_contains "$output" "2m"
  assert_contains "$output" "running-step"
  assert_contains "$output" "completed-step"

  local pending_line
  pending_line="$(echo "$output" | grep "waiting-step")"
  assert_contains "$pending_line" "-"
}

test_status_shows_pid_liveness_for_in_progress_steps() {
  local issue state_file output now_epoch live_pid dead_pid

  issue="9037"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  now_epoch="$(date +%s)"
  sleep 60 &
  live_pid="$!"
  dead_pid="999999"

  jq -n \
    --arg issue "$issue" \
    --argjson started_at "$now_epoch" \
    --argjson live_pid "$live_pid" \
    --argjson dead_pid "$dead_pid" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "live-running-step",
          type: "stub",
          agent: "stub",
          status: "in_progress",
          started_at: $started_at,
          pid: $live_pid,
          metrics: {},
          notes: ""
        },
        {
          id: "dead-running-step",
          type: "stub",
          agent: "stub",
          status: "in_progress",
          started_at: $started_at,
          pid: $dead_pid,
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"

  output="$("$RALPH" status --issue "$issue")"
  kill "$live_pid" 2>/dev/null || true

  assert_contains "$output" "live-running-step"
  assert_contains "$output" "alive (PID $live_pid)"
  assert_contains "$output" "dead-running-step"
  assert_contains "$output" "not found (stale)"
}

test_parse_log_claude_extracts_text_and_tool_use() {
  local log_file output

  log_file="$(mktemp)"
  cat > "$log_file" <<'JSONL'
{"type":"system","subtype":"init","session_id":"fake"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Reading the file now to understand the structure."}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/foo.sh"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"The file looks correct. I will make the changes."}]}}
{"type":"result","subtype":"success","result":"done"}
JSONL

  source "$ROOT_DIR/scripts/parse-log.sh"
  output="$(parse_log "$log_file" "claude" 10)"
  rm -f "$log_file"

  assert_contains "$output" "[text] Reading the file now"
  assert_contains "$output" "[tool] Read: file_path=/tmp/foo.sh"
  assert_contains "$output" "[text] The file looks correct"
  [[ "$output" != *"system"* ]] || fail "expected system events to be filtered out"
  [[ "$output" != *"result"* ]] || fail "expected result events to be filtered out"
}

test_parse_log_codex_extracts_messages_and_commands() {
  local log_file output

  log_file="$(mktemp)"
  cat > "$log_file" <<'JSONL'
{"type":"turn.started"}
{"type":"item.started","item":{"type":"command_execution"}}
{"type":"item.completed","item":{"type":"command_execution","command":"npm test"}}
{"type":"item.completed","item":{"type":"agent_message","text":"All tests pass. Committing now."}}
{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}
JSONL

  source "$ROOT_DIR/scripts/parse-log.sh"
  output="$(parse_log "$log_file" "codex" 10)"
  rm -f "$log_file"

  assert_contains "$output" "[cmd] npm test"
  assert_contains "$output" "[text] All tests pass. Committing now."
  [[ "$output" != *"turn.started"* ]] || fail "expected turn.started to be filtered out"
  [[ "$output" != *"turn.completed"* ]] || fail "expected turn.completed to be filtered out"
  [[ "$output" != *"item.started"* ]] || fail "expected item.started to be filtered out"
}

test_parse_log_empty_file_shows_starting() {
  local log_file output

  log_file="$(mktemp)"
  : > "$log_file"

  source "$ROOT_DIR/scripts/parse-log.sh"
  output="$(parse_log "$log_file" "claude" 10)"
  rm -f "$log_file"

  assert_contains "$output" "Starting..."

  output="$(parse_log "/nonexistent/file/does/not/exist" "claude" 10)"
  assert_contains "$output" "Starting..."
}

test_parse_log_partial_write_skips_truncated_lines() {
  local log_file output

  log_file="$(mktemp)"
  cat > "$log_file" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"text","text":"Valid line before truncation."}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Trun
JSONL

  source "$ROOT_DIR/scripts/parse-log.sh"
  output="$(parse_log "$log_file" "claude" 10)"
  rm -f "$log_file"

  assert_contains "$output" "[text] Valid line before truncation."
  [[ "$output" != *"Trun"* ]] || fail "expected truncated line to be skipped"
}

test_status_shows_activity_snippet_for_in_progress_step() {
  local issue state_file workspace log_file output

  issue="9033"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  workspace="$WORKSPACES_DIR/$issue"
  mkdir -p "$workspace/logs"
  state_file="$workspace/state.json"

  local now_epoch started_at
  now_epoch="$(date +%s)"
  started_at=$(( now_epoch - 222 ))

  jq -n \
    --arg issue "$issue" \
    --argjson started_at "$started_at" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "implement-slice-42",
          type: "implement-slice",
          agent: "codex",
          status: "in_progress",
          started_at: $started_at,
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"

  log_file="$workspace/logs/implement-slice-42.log"
  cat > "$log_file" <<'JSONL'
{"type":"item.completed","item":{"type":"command_execution","command":"npm test"}}
{"type":"item.completed","item":{"type":"agent_message","text":"All tests pass. I will commit the changes now."}}
JSONL

  source "$ROOT_DIR/scripts/parse-log.sh"
  source "$ROOT_DIR/scripts/status.sh"
  output="$(status_print "$state_file" "$workspace")"

  assert_contains "$output" "Current activity"
  assert_contains "$output" "implement-slice-42"
  assert_contains "$output" "codex"
  assert_contains "$output" "3m"
  assert_contains "$output" "[cmd] npm test"
  assert_contains "$output" "[text] All tests pass"
}

test_status_shows_dash_for_in_progress_without_started_at() {
  local issue state_file output

  issue="9028"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  state_file="$WORKSPACES_DIR/$issue/state.json"

  jq -n \
    --arg issue "$issue" \
    '{
      issue: ($issue | tonumber),
      steps: [
        {
          id: "old-running-step",
          type: "stub",
          agent: "stub",
          status: "in_progress",
          metrics: {},
          notes: ""
        }
      ]
    }' > "$state_file"

  output="$("$RALPH" status --issue "$issue")"

  assert_contains "$output" "old-running-step"
  assert_contains "$output" "in_progress"

  local step_line
  step_line="$(echo "$output" | grep "^[0-9].*old-running-step")"
  local duration_field
  duration_field="$(echo "$step_line" | awk '{print $6}')"
  [[ "$duration_field" == "-" ]] || fail "expected dash for in_progress step without started_at, got: $duration_field"
}

test_issue_must_be_positive_integer
test_cleanup_archives_workspace_by_issue_number
test_cleanup_errors_when_workspace_is_missing
test_cleanup_errors_when_archive_destination_exists
test_cleanup_validates_issue_number
test_cleanup_removes_empty_workspaces_directory
test_run_requires_existing_state
test_run_rejects_failed_steps
test_run_hard_stops_when_context_missing
test_run_hard_stops_when_context_is_insufficient
test_run_completes_pending_agent_step
test_status_prints_step_table
test_logs_tails_active_step_log
test_logs_tails_specific_step_log
test_claude_agent_step_renders_prompt_logs_metrics_and_summary
test_codex_agent_step_logs_jsonl_and_records_metrics
test_sigint_resets_running_step_to_pending_and_rerun_picks_it_up
test_blocked_step_stops_then_resumes_with_human_answers
test_failed_agent_invocation_marks_step_failed_and_exits_one
test_init_prompt_defines_complete_workspace_initialization_contract
test_initialized_workspace_status_shows_four_pending_fixed_steps
test_council_review_submits_polls_reads_cleans_up_and_prints_review
test_council_review_handles_member_failure_and_cleans_up
test_council_review_handles_timeout_and_cleans_up
test_review_decisions_prompt_defines_council_filtering_and_hitl_contract
test_create_prd_prompt_defines_full_prd_workflow_contract
test_create_slices_prompt_defines_full_slice_creation_contract
test_preflight_prompt_defines_full_preflight_workflow_contract
test_implement_slice_prompt_defines_full_implementation_workflow_contract
test_final_review_prompt_defines_full_review_workflow_contract
test_pr_review_prompt_defines_full_pr_workflow_contract
test_review_fixes_prompt_defines_full_review_fixes_workflow_contract
test_skills_bundle_is_self_contained_and_readme_documents_workflow
test_state_add_steps_appends_dynamic_steps_and_rejects_duplicates
test_review_decisions_runs_after_context_check_and_blocks_then_resumes
test_create_prd_pipeline_preserves_original_and_updates_single_prd_body
test_create_slices_pipeline_creates_linked_afk_sub_issues_idempotently
test_implement_slice_pipeline_runs_codex_with_sub_issue_context
test_final_and_pr_review_pipeline_completes_with_idempotent_pr
test_codex_step_uses_project_root_from_state_json
test_state_update_step_sets_started_at_on_in_progress
test_state_update_step_clears_started_at_on_pending
test_state_update_step_tracks_and_clears_pid
test_run_pipeline_records_current_shell_pid_while_step_runs
test_background_run_exits_immediately_writes_wrapper_pid_and_completes
test_poll_blocks_until_step_completes_then_exits_zero
test_poll_exits_one_when_step_fails
test_poll_exits_zero_when_step_is_blocked_for_hitl
test_poll_detects_dead_wrapper_pid_and_exits_one
test_background_run_respects_steps_limit
test_state_validate_resets_stale_in_progress_step_without_pid_file
test_state_validate_keeps_stale_in_progress_step_with_live_pid
test_state_validate_resets_stale_in_progress_step_with_dead_pid_file
test_status_shows_elapsed_time_for_in_progress_step
test_status_shows_pid_liveness_for_in_progress_steps
test_parse_log_claude_extracts_text_and_tool_use
test_parse_log_codex_extracts_messages_and_commands
test_parse_log_empty_file_shows_starting
test_parse_log_partial_write_skips_truncated_lines
test_status_shows_activity_snippet_for_in_progress_step
test_status_shows_dash_for_in_progress_without_started_at

echo "All ralph-v2 tests passed"
