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
    slice-plan) printf 'Issue #%s Slice Plan Artifact\n' "$parent_issue" ;;
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
  local issue_json current_body_file

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
  if ! issue_json="$(artifact_issue_json "$repo" "$artifact_issue" 2>/dev/null)"; then
    echo "Error: could not read artifact issue #$artifact_issue before update" >&2
    return 1
  fi
  current_body_file="$(mktemp)"
  jq -r '.body // ""' <<<"$issue_json" > "$current_body_file"
  if ! artifact_validate_body "$current_body_file" "$parent_issue" "$artifact_type" >/dev/null 2>&1; then
    rm -f "$current_body_file"
    echo "Error: issue #$artifact_issue is not a valid $artifact_type artifact for parent #$parent_issue" >&2
    return 1
  fi
  rm -f "$current_body_file"

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
  local artifact_type="${3:-decisions|prd|slice-plan}"

  [[ -f "$body_file" ]] || return 1
  if [[ "$parent_issue" =~ ^[0-9]+$ && "$artifact_type" != *"|"* ]]; then
    artifact_validate_body "$body_file" "$parent_issue" "$artifact_type" >/dev/null 2>&1
    return $?
  fi

  awk '/^---$/ { exit } { print }' "$body_file" |
    grep -Eq '^Ralph-Artifact: (decisions|prd|slice-plan)$' &&
    awk '/^---$/ { exit } { print }' "$body_file" |
    grep -Eq '^Parent: #[0-9]+$'
}

artifact_has_provenance_marker() {
  local body_file="$1"

  [[ -f "$body_file" ]] || return 1
  awk '/^---$/ { exit } { print }' "$body_file" |
    grep -Eq '^Ralph-Artifact:'
}

slice_bool_true() {
  case "${1,,}" in
    1|true|yes|y) return 0 ;;
    *) return 1 ;;
  esac
}

slice_is_tracked_in_state() {
  local state_file="$1"
  local issue="$2"

  [[ -f "$state_file" ]] || return 1
  jq -e --argjson issue "$issue" '
    any(.steps[]?; .type == "implement-slice" and (.sub_issue // null) == $issue)
  ' "$state_file" >/dev/null
}

slice_eligibility_note() {
  local body_file="$1"
  local parent_issue="$2"
  local issue_state="${3:-OPEN}"
  local already_tracked="${4:-false}"
  local state_lower

  if [[ ! -f "$body_file" ]]; then
    printf 'missing issue body\n'
    return 0
  fi

  if artifact_has_provenance_marker "$body_file"; then
    if grep -Fxq 'AFK: true' "$body_file"; then
      printf 'malformed: issue has both AFK: true and Ralph-Artifact: markers\n'
    else
      printf 'artifact issue, not an implementation slice\n'
    fi
    return 0
  fi

  if ! grep -Fxq 'AFK: true' "$body_file"; then
    printf 'missing exact AFK: true marker\n'
    return 0
  fi
  if ! grep -Fxq "Parent: #$parent_issue" "$body_file"; then
    printf 'missing exact Parent: #%s marker\n' "$parent_issue"
    return 0
  fi

  state_lower="${issue_state,,}"
  if [[ -n "$state_lower" && "$state_lower" != "open" ]] && ! slice_bool_true "$already_tracked"; then
    printf 'issue is %s and no existing State Step tracks it\n' "$issue_state"
    return 0
  fi
}

slice_is_eligible_implementation() {
  local body_file="$1"
  local parent_issue="$2"
  local issue_state="${3:-OPEN}"
  local already_tracked="${4:-false}"
  local note

  [[ -f "$body_file" ]] || return 1
  note="$(slice_eligibility_note "$body_file" "$parent_issue" "$issue_state" "$already_tracked")"
  [[ -z "$note" ]]
}

artifact_collect_preflight_slices() {
  local state_file="$1"
  local parent_issue="$2"
  local issues_json_file="$3"
  local notes_file="$4"
  local issue_json number state body_file already_tracked note
  local seen_file

  [[ -f "$issues_json_file" ]] || {
    echo "Error: issues JSON file not found: $issues_json_file" >&2
    return 1
  }
  : > "$notes_file"
  seen_file="$(mktemp)"

  while IFS= read -r issue_json; do
    [[ -n "$issue_json" ]] || continue
    number="$(jq -r '.number // empty' <<<"$issue_json")"
    [[ "$number" =~ ^[1-9][0-9]*$ ]] || continue
    if grep -Fxq "$number" "$seen_file"; then
      continue
    fi
    printf '%s\n' "$number" >> "$seen_file"
    state="$(jq -r '.state // "OPEN"' <<<"$issue_json")"
    body_file="$(mktemp)"
    jq -r '.body // ""' <<<"$issue_json" > "$body_file"

    already_tracked="false"
    if slice_is_tracked_in_state "$state_file" "$number"; then
      already_tracked="true"
    fi

    if slice_is_eligible_implementation "$body_file" "$parent_issue" "$state" "$already_tracked"; then
      printf '%s\n' "$number"
    else
      note="$(slice_eligibility_note "$body_file" "$parent_issue" "$state" "$already_tracked")"
      printf 'Skipped issue #%s: %s\n' "$number" "$note" >> "$notes_file"
    fi
    rm -f "$body_file"
  done < <(jq -c '.[]?' "$issues_json_file")

  rm -f "$seen_file"
}

artifact_issue_summary() {
  local repo="$1"
  local issue="$2"
  local step_status="${3:-}"
  local issue_json title state suffix

  if ! issue_json="$(gh issue view "$issue" --repo "$repo" --json number,title,state,url 2>/dev/null)"; then
    printf '%s\t%s\n' "" "Skipped issue #$issue: could not read issue details"
    return 0
  fi

  title="$(jq -r '.title // ""' <<<"$issue_json" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  state="$(jq -r '.state // "UNKNOWN"' <<<"$issue_json")"
  suffix="$state"
  if [[ -n "$step_status" ]]; then
    suffix="$suffix, step: $step_status"
  fi

  printf -- '- #%s - %s (%s)\t\n' "$issue" "$title" "$suffix"
}

artifact_candidate_slice_summary() {
  local repo="$1"
  local parent_issue="$2"
  local issue="$3"
  local step_status="${4:-}"
  local issue_json body_file state already_tracked note

  if ! issue_json="$(gh issue view "$issue" --repo "$repo" --json number,title,state,body,url 2>/dev/null)"; then
    printf '%s\t%s\n' "" "Skipped issue #$issue: could not read issue details"
    return 0
  fi

  body_file="$(mktemp)"
  jq -r '.body // ""' <<<"$issue_json" > "$body_file"
  state="$(jq -r '.state // "OPEN"' <<<"$issue_json")"
  already_tracked="false"
  if [[ -n "$step_status" ]]; then
    already_tracked="true"
  fi
  if slice_is_eligible_implementation "$body_file" "$parent_issue" "$state" "$already_tracked"; then
    rm -f "$body_file"
    artifact_issue_summary "$repo" "$issue" "$step_status"
    return 0
  fi

  note="$(slice_eligibility_note "$body_file" "$parent_issue" "$state" "$already_tracked")"
  rm -f "$body_file"
  printf '%s\t%s\n' "" "Skipped issue #$issue: $note"
}

artifact_slice_numbers_from_file() {
  local slices_file="$1"

  [[ -f "$slices_file" ]] || return 0
  grep -Eo '#[1-9][0-9]*' "$slices_file" | tr -d '#' | sort -n -u
}

artifact_collect_slice_lines() {
  local state_file="$1"
  local repo="$2"
  local parent_issue="$3"
  local workspace slice_file dynamic_count issue status issue_json body_file state
  local slice_lines_file="$4"
  local notes_file="$5"

  workspace="$(dirname "$state_file")"
  slice_file="$workspace/slices.md"
  : > "$slice_lines_file"
  : > "$notes_file"

  dynamic_count="$(jq '[.steps[]? | select(.type == "implement-slice" and (.sub_issue // empty))] | length' "$state_file")"
  if [[ "$dynamic_count" -gt 0 ]]; then
    while IFS=$'\t' read -r issue status; do
      [[ -n "$issue" ]] || continue
      artifact_issue_summary "$repo" "$issue" "$status"
    done < <(
      jq -r '.steps[]? | select(.type == "implement-slice" and (.sub_issue // empty)) | [(.sub_issue | tostring), (.status // "unknown")] | @tsv' "$state_file"
    ) | while IFS=$'\t' read -r line note; do
      if [[ -n "$line" ]]; then
        printf '%s\n' "$line" >> "$slice_lines_file"
      fi
      if [[ -n "$note" ]]; then
        printf '%s\n' "$note" >> "$notes_file"
      fi
    done
    return 0
  fi

  if [[ -f "$slice_file" ]]; then
    while IFS= read -r issue; do
      [[ -n "$issue" ]] || continue
      artifact_candidate_slice_summary "$repo" "$parent_issue" "$issue"
    done < <(artifact_slice_numbers_from_file "$slice_file") | while IFS=$'\t' read -r line note; do
      if [[ -n "$line" ]]; then
        printf '%s\n' "$line" >> "$slice_lines_file"
      fi
      if [[ -n "$note" ]]; then
        printf '%s\n' "$note" >> "$notes_file"
      fi
    done
    return 0
  fi

  if issue_json="$(gh issue list --repo "$repo" --state open --search "AFK: true Parent: #$parent_issue" --json number,title,state,body,url --limit 100 2>/dev/null)"; then
    while IFS=$'\t' read -r issue; do
      [[ -n "$issue" ]] || continue
      body_file="$(mktemp)"
      jq -r --argjson number "$issue" '.[] | select(.number == $number) | .body // ""' <<<"$issue_json" > "$body_file"
      state="$(jq -r --argjson number "$issue" '.[] | select(.number == $number) | .state // "OPEN"' <<<"$issue_json")"
      if slice_is_eligible_implementation "$body_file" "$parent_issue" "$state" "false"; then
        jq -r --argjson number "$issue" '.[] | select(.number == $number) | "- #\(.number) - \(.title // "") (\(.state // "UNKNOWN"))"' <<<"$issue_json" >> "$slice_lines_file"
      else
        printf 'Skipped issue #%s: %s\n' "$issue" "$(slice_eligibility_note "$body_file" "$parent_issue" "$state" "false")" >> "$notes_file"
      fi
      rm -f "$body_file"
    done < <(jq -r '.[].number' <<<"$issue_json")
  fi
}

artifact_pr_line() {
  local state_file="$1"
  local repo="$2"
  local pr_url branch pr_json

  pr_url="$(jq -r '.pr.url // empty' "$state_file")"
  if [[ -n "$pr_url" ]]; then
    printf '%s\n' "$pr_url"
    return 0
  fi

  branch="$(jq -r '.branch // empty' "$state_file")"
  if [[ -n "$branch" ]]; then
    pr_json="$(gh pr list --repo "$repo" --head "$branch" --json number,url --limit 1 2>/dev/null || printf '[]')"
    pr_url="$(jq -r '.[0].url // empty' <<<"$pr_json")"
    if [[ -n "$pr_url" ]]; then
      printf '%s\n' "$pr_url"
      return 0
    fi
  fi

  printf 'TBD\n'
}

artifact_render_artifact_line() {
  local state_file="$1"
  local artifact_type="$2"
  local label="$3"
  local issue

  issue="$(state_get_artifact "$state_file" "$artifact_type")"
  if [[ -n "$issue" ]]; then
    printf -- '- %s: #%s\n' "$label" "$issue"
  else
    printf -- '- %s: TBD\n' "$label"
  fi
}

artifact_refresh_parent_index() {
  local state_file="$1"
  local repo="$2"
  local parent_issue="$3"
  local extra_notes_file="${4:-}"
  local parent_json title status base_branch branch pr_value body_file slice_lines_file notes_file bytes

  state_ensure_artifacts "$state_file" || return 1
  if ! parent_json="$(gh issue view "$parent_issue" --repo "$repo" --json number,title,state,url 2>/dev/null)"; then
    echo "Error: could not read parent issue #$parent_issue" >&2
    return 1
  fi

  title="$(jq -r '.title // ("Issue #'"$parent_issue"'")' <<<"$parent_json" | tr '\n' ' ')"
  status="$(jq -r '.status // (first(.steps[]? | select(.status == "pending") | .id) // "unknown")' "$state_file")"
  base_branch="$(jq -r '.baseBranch // "unset"' "$state_file")"
  branch="$(jq -r '.branch // "unset"' "$state_file")"
  pr_value="$(artifact_pr_line "$state_file" "$repo")"
  body_file="$(mktemp)"
  slice_lines_file="$(mktemp)"
  notes_file="$(mktemp)"

  artifact_collect_slice_lines "$state_file" "$repo" "$parent_issue" "$slice_lines_file" "$notes_file"
  if [[ -n "$extra_notes_file" && -f "$extra_notes_file" ]]; then
    while IFS= read -r note; do
      [[ -n "$note" ]] || continue
      printf '%s\n' "$note" >> "$notes_file"
    done < "$extra_notes_file"
  fi

  {
    printf '## Ralph Run Index\n\n'
    printf 'This issue is the compact index for a Ralph pipeline run. Durable planning content lives in linked Artifact Issues.\n\n'
    printf '## Summary\n\n'
    printf '%s\n\n' "$title"
    printf '## Routing\n\n'
    printf -- '- Status: %s\n' "$status"
    printf -- '- Base branch: `%s`\n' "$base_branch"
    printf -- '- Feature branch: `%s`\n' "$branch"
    printf -- '- PR: %s\n\n' "$pr_value"
    printf '## Artifacts\n\n'
    artifact_render_artifact_line "$state_file" "decisions" "Decisions"
    artifact_render_artifact_line "$state_file" "prd" "PRD"
    artifact_render_artifact_line "$state_file" "slice-plan" "Slice Plan"
    printf '\n## Implementation Slices\n\n'
    if [[ -s "$slice_lines_file" ]]; then
      cat "$slice_lines_file"
    else
      printf -- '- TBD\n'
    fi
    printf '\n## Notes\n\n'
    printf -- '- Artifact issues are planning storage and are not implementation slices.\n'
    printf -- '- Only AFK implementation slice issues become `implement-slice` steps.\n'
    if [[ -s "$notes_file" ]]; then
      while IFS= read -r note; do
        if [[ -n "$note" ]]; then
          printf -- '- %s\n' "$note"
        fi
      done < "$notes_file"
    fi
  } > "$body_file"

  gh issue edit "$parent_issue" --repo "$repo" --body-file "$body_file" >/dev/null
  bytes="$(artifact_byte_count "$body_file")"
  rm -f "$body_file" "$slice_lines_file" "$notes_file"
  printf '{"action":"refreshed","issue":%s,"bytes":%s}\n' "$parent_issue" "$bytes"
}

artifact_close_all() {
  local state_file="$1"
  local repo="$2"
  local parent_issue="$3"
  local comment="${4:-Archived by Ralph cleanup.}"
  local artifact_type issue issue_json body_file state closed_count skipped_count

  state_ensure_artifacts "$state_file" || return 1
  closed_count=0
  skipped_count=0

  for artifact_type in decisions prd slice-plan; do
    issue="$(state_get_artifact "$state_file" "$artifact_type")"
    if [[ -z "$issue" ]]; then
      continue
    fi
    if [[ ! "$issue" =~ ^[1-9][0-9]*$ ]]; then
      echo "Warning: skipping invalid registered artifact issue for $artifact_type: $issue" >&2
      skipped_count=$((skipped_count + 1))
      continue
    fi
    if ! issue_json="$(artifact_issue_json "$repo" "$issue" 2>/dev/null)"; then
      echo "Error: could not read registered artifact issue #$issue" >&2
      return 1
    fi

    body_file="$(mktemp)"
    jq -r '.body // ""' <<<"$issue_json" > "$body_file"
    if ! artifact_validate_body "$body_file" "$parent_issue" "$artifact_type" >/dev/null 2>&1; then
      rm -f "$body_file"
      echo "Error: registered issue #$issue is not a valid $artifact_type artifact for parent #$parent_issue" >&2
      return 1
    fi
    rm -f "$body_file"

    gh issue comment "$issue" --repo "$repo" --body "$comment" >/dev/null
    state="$(jq -r '.state // ""' <<<"$issue_json")"
    if [[ "${state,,}" == "closed" ]]; then
      skipped_count=$((skipped_count + 1))
      continue
    fi
    gh issue close "$issue" --repo "$repo" >/dev/null
    closed_count=$((closed_count + 1))
  done

  printf '{"action":"closed-artifacts","closed":%s,"skipped":%s}\n' "$closed_count" "$skipped_count"
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
  slice_eligibility_note
  artifact_collect_preflight_slices
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
    artifact_ensure|artifact_update_body|artifact_link_to_parent|artifact_refresh_parent_index|artifact_close_all|artifact_is_artifact_issue|slice_is_eligible_implementation|slice_eligibility_note|artifact_collect_preflight_slices)
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
