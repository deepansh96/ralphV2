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
TEST_ISSUES=(42 9001 9002 9003 9004 9005 9006 9007 9008 9009 9010 9011 9012 9013 9014 9015 9016 9018 9019 9020 9021 9022 9023 9024 9025 9026 9027 9028 9029 9030 9031 9032 9033 9034 9035 9036 9037 9038 9039 9040 9041 9042 9043 9044 9045 9046 9047 9048 9049 9050 9051 9052 9053)
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

install_fake_post_implementation_claude() {
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
    result: "CONTEXT_CHECK: PASS",
    duration_ms: 100,
    usage: {input_tokens: 1, output_tokens: 1},
    total_cost_usd: 0.01
  }'
  exit 0
fi

workspace="$(awk '/^Workspace:/ { print $2; exit }' <<<"$prompt")"
step_id="$(awk '/^Step:/ { print $2; exit }' <<<"$prompt")"

printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
case "$step_id" in
  final-checks)
    [[ "$prompt" == *"git diff main...HEAD"* ]] || exit 201
    [[ "$prompt" == *"read-only"* ]] || exit 202
    cat > "$workspace/final-checks.md" <<'FINAL_CHECKS'
# Final Checks

- Quality checks: passed
- Acceptance criteria: satisfied
- Outcome: PASS
FINAL_CHECKS
    ;;
  pr-creation)
    [[ "$prompt" == *"Closes #9021"* ]] || exit 203
    [[ "$prompt" == *"Do not include a review section or QA checklist"* ]] || exit 204
    if [[ ! -f "$workspace/github-pr.md" ]]; then
      printf '1\n' > "$workspace/github-pr-create-count"
      printf 'created PR #77\n' > "$workspace/github-pr.md"
      action="created"
    else
      action="updated"
    fi
    cat > "$workspace/pr-body.md" <<'PR_BODY'
## Summary

- Added the post-implementation pipeline.

## Linked Issues

- Closes #9021
- Closes #9111
PR_BODY
    printf '# PR Creation\n\n- PR: #77\n- Action: %s\n' "$action" > "$workspace/pr-creation.md"
    ;;
  prepare-qa-checklist)
    [[ "$prompt" == *"ralph:qa-checklist"* ]] || exit 205
    if [[ ! -f "$workspace/qa-comment-count" ]]; then
      printf '1\n' > "$workspace/qa-comment-count"
    fi
    cat > "$workspace/github-qa-comment.md" <<'QA_COMMENT'
<!-- ralph:qa-checklist -->
## Local QA Checklist

- [ ] [PENDING] QA-01: Run locally
QA_COMMENT
    ;;
  runthrough-qa-checklist)
    [[ "$prompt" == *"Stub all external calls"* ]] || exit 206
    cat > "$workspace/github-qa-comment.md" <<'QA_COMMENT'
<!-- ralph:qa-checklist -->
## Local QA Checklist

- [x] [PASS] QA-01: Run locally

Summary: 1 passed.
QA_COMMENT
    ;;
  multi-axis-pr-review)
    [[ "$prompt" == *"two waves"* ]] || exit 207
    [[ "$prompt" == *"matt-pocock-code-review/SKILL.md"* ]] || exit 208
    [[ "$prompt" == *"ponytail-review/SKILL.md"* ]] || exit 209
    [[ "$prompt" == *"run-codex-review/SKILL.md"* ]] || exit 210
    [[ "$prompt" == *"supe-review-code-changes/SKILL.md"* ]] || exit 211
    if [[ ! -f "$workspace/multi-axis-comment-count" ]]; then
      printf '1\n' > "$workspace/multi-axis-comment-count"
    fi
    cat > "$workspace/github-multi-axis-comment.md" <<'REVIEW_COMMENT'
<!-- ralph:multi-axis-review -->
## Kept Findings

- None.

Verdict: pass.
REVIEW_COMMENT
    ;;
  cleanup-local-resources)
    [[ "$prompt" == *"after an earlier step fails"* ]] || exit 212
    printf '%s\n' '{"processes":[],"containers":[],"tempPaths":[],"sessions":[]}' > "$workspace/local-resources.json"
    cat > "$workspace/cleanup-local-resources.md" <<'CLEANUP'
# Cleanup Local Resources

- Removed recorded resources.
CLEANUP
    ;;
  *)
    echo "unexpected step: $step_id" >&2
    exit 213
    ;;
esac

jq -n -c --arg step "$step_id" '{
  type: "result",
  subtype: "success",
  result: ($step + " completed"),
  duration_ms: 100,
  usage: {input_tokens: 3, output_tokens: 2},
  total_cost_usd: 0.01
}'
FAKE_CLAUDE
  chmod +x "$fake_bin/claude"
}

install_fake_failure_then_cleanup_claude() {
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
  printf '%s\n' '{"type":"result","subtype":"success","result":"CONTEXT_CHECK: PASS","duration_ms":1,"usage":{"input_tokens":1,"output_tokens":1},"total_cost_usd":0}'
  exit 0
fi

workspace="$(awk '/^Workspace:/ { print $2; exit }' <<<"$prompt")"
step_id="$(awk '/^Step:/ { print $2; exit }' <<<"$prompt")"
if [[ "$step_id" == "create-and-review-prd" ]]; then
  exit 42
fi
[[ "$step_id" == "cleanup-local-resources" ]] || exit 43
printf 'cleanup ran\n' > "$workspace/cleanup-ran"
printf '%s\n' '{"type":"system","subtype":"init","session_id":"fake"}'
printf '%s\n' '{"type":"result","subtype":"success","result":"cleanup completed","duration_ms":1,"usage":{"input_tokens":1,"output_tokens":1},"total_cost_usd":0}'
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

run_test() {
  local name="$1"
  printf 'Running %s\n' "$name"
  "$name"
}
