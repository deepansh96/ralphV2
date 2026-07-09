#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RALPH="$ROOT_DIR/ralph.sh"
CLEANUP_SCRIPT="$ROOT_DIR/cleanup.sh"
PROJECT_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
WORKSPACES_DIR="$ROOT_DIR/workspaces"
ARCHIVE_DIR="$ROOT_DIR/archive"
CONTEXT_FILE="$PROJECT_ROOT/CONTEXT.md"
INITIAL_CONTEXT_BACKUP="$(mktemp)"
INITIAL_CONTEXT_PRESENT="false"
TEST_ISSUES=(42 9001 9002 9003 9004 9005 9006 9007 9008 9009 9010 9011 9012 9013 9014 9015 9016 9018 9019 9020 9021 9022 9023 9024 9025 9026 9027 9028 9029 9030 9031 9032 9033 9034 9035 9036 9037 9038 9039 9040 9041 9042 9043 9044 9045 9046 9047 9048 9049 9050)
export RALPH_RETRY_DELAYS="${RALPH_RETRY_DELAYS:-0 0 0}"

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
[[ "$prompt" == *"to-spec"* ]] || exit 76
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
[[ "$prompt" == *"to-tickets"* ]] || exit 85
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
[[ "$prompt" == *"issue_dependencies_summary.blocked_by"* ]] || exit 115
[[ "$prompt" == *"seams"* ]] || exit 116
[[ "$prompt" == *"tautological"* ]] || exit 117
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
    [[ "$prompt" == *"Step agent: claude"* ]] || exit 150
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
    [[ "$prompt" == *"review --base"* ]] || exit 161
    cat > "$workspace/pr-body.md" <<'PR_BODY'
## Summary

- Added final-review and pr-review prompt workflows.

## Linked Issues

- Closes #9021
- Closes #9111

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

install_fake_codex_pr_review() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail

while [[ $# -gt 0 ]]; do
  shift
done

prompt="$(cat)"
[[ "$prompt" == *"Step agent: codex"* ]] || exit 181
[[ "$prompt" == *"codex-pr-review.md"* ]] || exit 182
[[ "$prompt" == *"codex review"* ]] || exit 183
[[ "$prompt" == *"review --base origin/main"* ]] || exit 184
[[ "$prompt" == *"gh pr comment"* ]] || exit 185

workspace="$(awk '/^Workspace:/ { print $2; exit }' <<<"$prompt")"
cat > "$workspace/codex-pr-review.md" <<'CODEX_REVIEW'
No findings.
CODEX_REVIEW

cat > "$workspace/pr-review.md" <<'PR_REVIEW'
# PR Review

- PR: #88 https://github.com/deepansh96/ralph/pull/88
- Automated review source: codex review
- Codex review output: no findings
PR_REVIEW

printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":31,"output_tokens":29}}'
FAKE_CODEX
  chmod +x "$fake_bin/codex"

  cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

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
}


run_test() {
  local name="$1"
  printf 'Running %s\n' "$name"
  "$name"
}
