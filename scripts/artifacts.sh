#!/usr/bin/env bash

ARTIFACTS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=state.sh
source "$ARTIFACTS_SCRIPT_DIR/state.sh"

artifact_now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

artifact_validate_type() {
  state_validate_artifact_type "${1:-}"
}

artifact_byte_count() {
  wc -c < "$1" | tr -d '[:space:]'
}

artifact_provenance_block() {
  awk '
    /^---$/ { found = 1; exit }
    { print }
    END { if (!found) exit 2 }
  ' "$1"
}

artifact_validate_body() {
  local body_file="$1"
  local parent_issue="$2"
  local artifact_type="$3"
  local block_file

  artifact_validate_type "$artifact_type" || return 1
  if [[ ! -f "$body_file" ]]; then
    echo "Error: artifact body file not found: $body_file" >&2
    return 1
  fi

  block_file="$(mktemp)"
  if ! artifact_provenance_block "$body_file" > "$block_file"; then
    rm -f "$block_file"
    echo "Error: artifact body is missing provenance separator" >&2
    return 1
  fi

  if ! grep -Fxq "Ralph-Artifact: $artifact_type" "$block_file"; then
    rm -f "$block_file"
    echo "Error: artifact body has missing or wrong Ralph-Artifact marker" >&2
    return 1
  fi
  if ! grep -Fxq "Parent: #$parent_issue" "$block_file"; then
    rm -f "$block_file"
    echo "Error: artifact body has missing or wrong Parent marker" >&2
    return 1
  fi
  if ! grep -Eq '^Owning-Step: .+' "$block_file"; then
    rm -f "$block_file"
    echo "Error: artifact body is missing Owning-Step marker" >&2
    return 1
  fi
  if ! grep -Eq '^Last-Updated: .+' "$block_file"; then
    rm -f "$block_file"
    echo "Error: artifact body is missing Last-Updated marker" >&2
    return 1
  fi

  rm -f "$block_file"
}

artifact_write_body() {
  local parent_issue="$1"
  local artifact_type="$2"
  local owning_step="$3"
  local content_file="$4"
  local output_file="$5"

  artifact_validate_type "$artifact_type" || return 1
  if [[ -z "$owning_step" ]]; then
    echo "Error: owning step is required" >&2
    return 1
  fi
  if [[ ! -f "$content_file" ]]; then
    echo "Error: artifact content file not found: $content_file" >&2
    return 1
  fi

  {
    printf 'Ralph-Artifact: %s\n' "$artifact_type"
    printf 'Parent: #%s\n' "$parent_issue"
    printf 'Owning-Step: %s\n' "$owning_step"
    printf 'Last-Updated: %s\n' "$(artifact_now_utc)"
    printf 'WARNING: Managed by Ralph. Manual edits may be overwritten.\n'
    printf '%s\n' '---'
    cat "$content_file"
  } > "$output_file"
}

artifact_issue_number_from_output() {
  sed -nE 's#.*/issues/([0-9]+)/?$#\1#p; s#^([0-9]+)$#\1#p' | tail -n 1
}

artifact_issue_json() {
  local repo="$1"
  local issue="$2"

  gh issue view "$issue" --repo "$repo" --json number,state,createdAt,body,id
}

artifact_issue_matches() {
  local repo="$1"
  local issue="$2"
  local parent_issue="$3"
  local artifact_type="$4"
  local issue_json body_file

  if ! issue_json="$(artifact_issue_json "$repo" "$issue" 2>/dev/null)"; then
    return 1
  fi

  body_file="$(mktemp)"
  jq -r '.body // ""' <<<"$issue_json" > "$body_file"
  if artifact_validate_body "$body_file" "$parent_issue" "$artifact_type" >/dev/null 2>&1; then
    rm -f "$body_file"
    return 0
  fi

  rm -f "$body_file"
  return 1
}

artifact_issue_state() {
  local repo="$1"
  local issue="$2"

  artifact_issue_json "$repo" "$issue" | jq -r '.state // empty'
}

artifact_reopen_if_closed() {
  local repo="$1"
  local issue="$2"
  local state

  state="$(artifact_issue_state "$repo" "$issue" 2>/dev/null || true)"
  if [[ "${state,,}" == "closed" ]]; then
    gh issue reopen "$issue" --repo "$repo" >/dev/null
  fi
}

artifact_apply_labels() {
  local repo="$1"
  local issue="$2"

  gh issue edit "$issue" --repo "$repo" --add-label "Ralph-Artifact" >/dev/null 2>&1 || true
  gh issue edit "$issue" --repo "$repo" --add-label "ralph-artifact" >/dev/null 2>&1 || true
}

artifact_find_candidate() {
  local repo="$1"
  local parent_issue="$2"
  local artifact_type="$3"
  local list_json number

  artifact_validate_type "$artifact_type" || return 1

  list_json="$(
    gh issue list \
      --repo "$repo" \
      --state all \
      --search "Ralph-Artifact Parent: #$parent_issue" \
      --json number,state,createdAt \
      --limit 100 2>/dev/null || printf '[]'
  )"

  while IFS= read -r number; do
    [[ -n "$number" ]] || continue
    if artifact_issue_matches "$repo" "$number" "$parent_issue" "$artifact_type"; then
      printf '%s\n' "$number"
      return 0
    fi
  done < <(
    jq -r '
      def rank:
        if ((.state // "" | ascii_downcase) == "open") then 0 else 1 end;
      [ .[] | {number, state, createdAt, rank: rank} ]
      | sort_by(.rank, (.createdAt // ""))
      | group_by(.rank)
      | map(sort_by(.createdAt // "") | reverse)
      | add // []
      | .[].number
    ' <<<"$list_json"
  )

  return 1
}

artifact_default_title() {
  local parent_issue="$1"
  local artifact_type="$2"

  case "$artifact_type" in
    decisions) printf 'Issue #%s Decisions Artifact\n' "$parent_issue" ;;
    prd) printf 'Issue #%s PRD Artifact\n' "$parent_issue" ;;
    slicePlan) printf 'Issue #%s Slice Plan Artifact\n' "$parent_issue" ;;
  esac
}

artifact_ensure() {
  local state_file="$1"
  local repo="$2"
  local parent_issue="$3"
  local artifact_type="$4"
  local owning_step="$5"
  local content_file="$6"
  local title="${7:-}"
  local current_issue candidate body_file create_output issue_number

  artifact_validate_type "$artifact_type" || return 1
  state_ensure_artifacts "$state_file" || return 1

  current_issue="$(state_get_artifact "$state_file" "$artifact_type")"
  if [[ -n "$current_issue" ]] && artifact_issue_matches "$repo" "$current_issue" "$parent_issue" "$artifact_type"; then
    artifact_reopen_if_closed "$repo" "$current_issue"
    artifact_apply_labels "$repo" "$current_issue"
    printf '%s\n' "$current_issue"
    return 0
  fi

  if candidate="$(artifact_find_candidate "$repo" "$parent_issue" "$artifact_type")"; then
    artifact_reopen_if_closed "$repo" "$candidate"
    artifact_apply_labels "$repo" "$candidate"
    state_set_artifact "$state_file" "$artifact_type" "$candidate"
    printf '%s\n' "$candidate"
    return 0
  fi

  body_file="$(mktemp)"
  artifact_write_body "$parent_issue" "$artifact_type" "$owning_step" "$content_file" "$body_file"
  if [[ "$(artifact_byte_count "$body_file")" -gt 60000 ]]; then
    rm -f "$body_file"
    echo "Error: artifact body exceeds 60000 bytes" >&2
    return 1
  fi
  artifact_validate_body "$body_file" "$parent_issue" "$artifact_type" || {
    rm -f "$body_file"
    return 1
  }

  if [[ -z "$title" ]]; then
    title="$(artifact_default_title "$parent_issue" "$artifact_type")"
  fi

  create_output="$(gh issue create --repo "$repo" --title "$title" --body-file "$body_file")"
  issue_number="$(printf '%s\n' "$create_output" | artifact_issue_number_from_output)"
  if [[ ! "$issue_number" =~ ^[1-9][0-9]*$ ]]; then
    rm -f "$body_file"
    echo "Error: could not parse created artifact issue number" >&2
    return 1
  fi

  artifact_apply_labels "$repo" "$issue_number"
  state_set_artifact "$state_file" "$artifact_type" "$issue_number"
  rm -f "$body_file"
  printf '%s\n' "$issue_number"
}

artifact_update_body() {
  local state_file="$1"
  local repo="$2"
  local parent_issue="$3"
  local artifact_type="$4"
  local artifact_issue="$5"
  local body_file="$6"

  artifact_validate_type "$artifact_type" || return 1
  if [[ ! "$artifact_issue" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: artifact issue must be a positive integer" >&2
    return 1
  fi
  if [[ ! -f "$body_file" ]]; then
    echo "Error: artifact body file not found: $body_file" >&2
    return 1
  fi
  if [[ "$(artifact_byte_count "$body_file")" -gt 60000 ]]; then
    echo "Error: artifact body exceeds 60000 bytes" >&2
    return 1
  fi

  artifact_validate_body "$body_file" "$parent_issue" "$artifact_type" || return 1
  gh issue edit "$artifact_issue" --repo "$repo" --body-file "$body_file" >/dev/null
  state_set_artifact "$state_file" "$artifact_type" "$artifact_issue"
}

artifact_link_to_parent() {
  local repo="$1"
  local parent_issue="$2"
  local artifact_issue="$3"
  local parent_id artifact_id

  if ! parent_id="$(gh issue view "$parent_issue" --repo "$repo" --json id -q .id 2>/dev/null)"; then
    echo "Warning: could not resolve parent issue ID for artifact linking" >&2
    return 0
  fi
  if ! artifact_id="$(gh issue view "$artifact_issue" --repo "$repo" --json id -q .id 2>/dev/null)"; then
    echo "Warning: could not resolve artifact issue ID for artifact linking" >&2
    return 0
  fi

  if ! gh api graphql \
    -f query='mutation($issueId:ID!,$subIssueId:ID!){addSubIssue(input:{issueId:$issueId,subIssueId:$subIssueId}){issue{id}}}' \
    -f issueId="$parent_id" \
    -f subIssueId="$artifact_id" >/dev/null 2>&1; then
    echo "Warning: GitHub sub-issue linking is unavailable; continuing with markdown/state recovery" >&2
  fi
}

artifact_is_artifact_issue() {
  local body_file="$1"
  local parent_issue="${2:-[0-9][0-9]*}"
  local artifact_type="${3:-decisions|prd|slicePlan}"

  [[ -f "$body_file" ]] || return 1
  if [[ "$parent_issue" =~ ^[0-9]+$ && "$artifact_type" != *"|"* ]]; then
    artifact_validate_body "$body_file" "$parent_issue" "$artifact_type" >/dev/null 2>&1
    return $?
  fi

  awk '/^---$/ { exit } { print }' "$body_file" |
    grep -Eq '^Ralph-Artifact: (decisions|prd|slicePlan)$' &&
    awk '/^---$/ { exit } { print }' "$body_file" |
    grep -Eq '^Parent: #[0-9]+$'
}

slice_is_eligible_implementation() {
  local body_file="$1"
  local parent_issue="$2"

  [[ -f "$body_file" ]] || return 1
  ! artifact_is_artifact_issue "$body_file" || return 1
  grep -Fxq 'AFK: true' "$body_file" || return 1
  grep -Fxq "Parent: #$parent_issue" "$body_file" || return 1
}

artifact_refresh_parent_index() {
  printf '{"action":"artifact_refresh_parent_index","status":"not_implemented"}\n'
}

artifact_close_all() {
  printf '{"action":"artifact_close_all","status":"not_implemented"}\n'
}

artifact_usage() {
  cat >&2 <<'USAGE'
Usage:
  artifacts.sh <function-name> [args...]

Functions:
  artifact_ensure
  artifact_update_body
  artifact_link_to_parent
  artifact_refresh_parent_index
  artifact_close_all
  artifact_is_artifact_issue
  slice_is_eligible_implementation
USAGE
}

artifact_main() {
  local fn="${1:-}"
  [[ -n "$fn" ]] || {
    artifact_usage
    return 2
  }
  shift || true

  case "$fn" in
    artifact_ensure|artifact_update_body|artifact_link_to_parent|artifact_refresh_parent_index|artifact_close_all|artifact_is_artifact_issue|slice_is_eligible_implementation)
      "$fn" "$@"
      ;;
    *)
      echo "Error: unknown artifact helper function: $fn" >&2
      artifact_usage
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  artifact_main "$@"
fi
