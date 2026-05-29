#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"
source "$ROOT_DIR/scripts/artifacts.sh"

write_artifact_state() {
  local issue="$1"
  local state_file="$WORKSPACES_DIR/$issue/state.json"

  mkdir -p "$WORKSPACES_DIR/$issue/logs"
  jq -n \
    --argjson issue "$issue" \
    '{
      issue: $issue,
      repo: "deepansh96/ralphV2",
      baseBranch: "main",
      branch: "feat/artifact-helper",
      projectRoot: "/tmp/project",
      artifacts: {
        decisions: null,
        prd: null,
        slicePlan: null
      },
      pr: null,
      steps: []
    }' > "$state_file"
}

install_fake_artifact_gh() {
  local fake_bin="$1"
  local fixture_dir="$2"

  rm -rf "$fake_bin" "$fixture_dir"
  mkdir -p "$fake_bin" "$fixture_dir/issues"
  printf '100\n' > "$fixture_dir/next"
  : > "$fixture_dir/log"

  cat > "$fake_bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

fixture="${GH_FIXTURE_DIR:?}"
log_file="$fixture/log"

log() {
  printf '%s\n' "$*" >> "$log_file"
}

next_issue() {
  local next
  next="$(<"$fixture/next")"
  printf '%s\n' "$(( next + 1 ))" > "$fixture/next"
  printf '%s\n' "$next"
}

issue_file() {
  printf '%s/issues/%s.json\n' "$fixture" "$1"
}

json_escape_body() {
  jq -Rs . < "$1"
}

cmd="${1:-}"
shift || true

case "$cmd" in
  issue)
    sub="${1:-}"
    shift || true
    case "$sub" in
      create)
        repo=""
        title=""
        body_file=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --repo) repo="$2"; shift 2 ;;
            --title) title="$2"; shift 2 ;;
            --body-file) body_file="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        number="$(next_issue)"
        body_json="$(json_escape_body "$body_file")"
        jq -n \
          --argjson number "$number" \
          --arg title "$title" \
          --arg repo "$repo" \
          --arg body "$body_json" \
          --arg created_at "2026-05-30T00:00:${number}Z" \
          '{
            number: $number,
            title: $title,
            repo: $repo,
            state: "OPEN",
            createdAt: $created_at,
            body: ($body | fromjson),
            id: ("ISSUE_" + ($number | tostring)),
            url: ("https://github.com/" + $repo + "/issues/" + ($number | tostring)),
            labels: []
          }' > "$(issue_file "$number")"
        log "issue create $number $title"
        printf 'https://github.com/%s/issues/%s\n' "$repo" "$number"
        ;;
      view)
        number="$1"
        shift
        q=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --repo) shift 2 ;;
            --json) shift 2 ;;
            -q) q="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        file="$(issue_file "$number")"
        [[ -f "$file" ]] || exit 1
        if [[ "$q" == ".id" ]]; then
          jq -r '.id' "$file"
        else
          cat "$file"
        fi
        ;;
      list)
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --repo|--state|--search|--json|--limit) shift 2 ;;
            *) shift ;;
          esac
        done
        if compgen -G "$fixture/issues/*.json" >/dev/null; then
          jq -s '[.[] | {number, title, state, createdAt, body, url}]' "$fixture"/issues/*.json
        else
          printf '[]\n'
        fi
        ;;
      edit)
        number="$1"
        shift
        body_file=""
        add_label=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --repo) shift 2 ;;
            --body-file) body_file="$2"; shift 2 ;;
            --add-label) add_label="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        file="$(issue_file "$number")"
        [[ -f "$file" ]] || exit 1
        if [[ -n "$add_label" ]]; then
          log "issue edit-label $number $add_label"
          [[ "${GH_FAIL_LABELS:-}" != "1" ]] || exit 31
          tmp="$(mktemp)"
          jq --arg label "$add_label" '.labels += [$label]' "$file" > "$tmp"
          mv "$tmp" "$file"
          exit 0
        fi
        if [[ -n "$body_file" ]]; then
          tmp="$(mktemp)"
          body_json="$(json_escape_body "$body_file")"
          jq --arg body "$body_json" '.body = ($body | fromjson)' "$file" > "$tmp"
          mv "$tmp" "$file"
          log "issue edit-body $number"
        fi
        ;;
      comment)
        number="$1"
        shift
        body=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --repo) shift 2 ;;
            --body) body="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        file="$(issue_file "$number")"
        [[ -f "$file" ]] || exit 1
        log "issue comment $number $body"
        ;;
      close)
        number="$1"
        shift
        file="$(issue_file "$number")"
        [[ -f "$file" ]] || exit 1
        tmp="$(mktemp)"
        jq '.state = "CLOSED"' "$file" > "$tmp"
        mv "$tmp" "$file"
        log "issue close $number"
        ;;
      reopen)
        number="$1"
        shift
        file="$(issue_file "$number")"
        [[ -f "$file" ]] || exit 1
        tmp="$(mktemp)"
        jq '.state = "OPEN"' "$file" > "$tmp"
        mv "$tmp" "$file"
        log "issue reopen $number"
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  pr)
    sub="${1:-}"
    shift || true
    case "$sub" in
      list)
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --repo|--head|--json|--limit) shift 2 ;;
            *) shift ;;
          esac
        done
        if [[ -f "$fixture/prs.json" ]]; then
          cat "$fixture/prs.json"
        else
          printf '[]\n'
        fi
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  api)
    [[ "${GH_GRAPHQL_FAIL:-}" != "1" ]] || exit 42
    log "api graphql $*"
    printf '{"data":{"addSubIssue":{"issue":{"id":"ISSUE_PARENT"}}}}\n'
    ;;
  *)
    exit 2
    ;;
esac
FAKE_GH
  chmod +x "$fake_bin/gh"
}

artifact_fixture_paths() {
  local issue="$1"
  export GH_FIXTURE_DIR="$WORKSPACES_DIR/artifact-gh-$issue"
  export PATH="$WORKSPACES_DIR/fake-bin:$PATH"
}

issue_body() {
  local number="$1"

  jq -r '.body' "$GH_FIXTURE_DIR/issues/$number.json"
}

mark_issue_closed() {
  local number="$1"
  local tmp_file

  tmp_file="$(mktemp)"
  jq '.state = "CLOSED"' "$GH_FIXTURE_DIR/issues/$number.json" > "$tmp_file"
  mv "$tmp_file" "$GH_FIXTURE_DIR/issues/$number.json"
}

write_fixture_issue() {
  local number="$1"
  local title="$2"
  local body="$3"
  local state="${4:-OPEN}"

  jq -n \
    --argjson number "$number" \
    --arg title "$title" \
    --arg body "$body" \
    --arg state "$state" \
    '{
      number: $number,
      title: $title,
      repo: "deepansh96/ralphV2",
      state: $state,
      createdAt: "2026-05-30T00:00:00Z",
      body: $body,
      id: ("ISSUE_" + ($number | tostring)),
      url: ("https://github.com/deepansh96/ralphV2/issues/" + ($number | tostring)),
      labels: []
    }' > "$GH_FIXTURE_DIR/issues/$number.json"
}

write_fixture_prs() {
  local json="$1"

  printf '%s\n' "$json" > "$GH_FIXTURE_DIR/prs.json"
}

test_artifact_ensure_creates_marker_body_before_state_registration() {
  local issue state_file content_file artifact_number body

  issue="9051"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_artifact_state "$issue"
  install_fake_artifact_gh "$WORKSPACES_DIR/fake-bin" "$WORKSPACES_DIR/artifact-gh-$issue"
  artifact_fixture_paths "$issue"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  content_file="$WORKSPACES_DIR/$issue/decisions.md"
  printf 'Decision content\n' > "$content_file"

  artifact_number="$(artifact_ensure "$state_file" "deepansh96/ralphV2" "14" "decisions" "review-decisions-1" "$content_file")"

  [[ "$artifact_number" == "100" ]] || fail "expected first artifact issue 100, got $artifact_number"
  [[ "$(jq -r '.artifacts.decisions' "$state_file")" == "100" ]] || fail "expected state to register artifact after create"
  body="$(issue_body "$artifact_number")"
  assert_contains "$body" "Ralph-Artifact: decisions"
  assert_contains "$body" "Parent: #14"
  assert_contains "$body" "Owning-Step: review-decisions-1"
  assert_contains "$body" "Last-Updated:"
  assert_contains "$body" "WARNING: Managed by Ralph"
  assert_contains "$body" "---"
  assert_contains "$body" "Decision content"
}

test_artifact_ensure_reuses_state_reopens_closed_and_tolerates_label_failure() {
  local issue state_file content_file first second create_count

  issue="9052"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_artifact_state "$issue"
  install_fake_artifact_gh "$WORKSPACES_DIR/fake-bin" "$WORKSPACES_DIR/artifact-gh-$issue"
  artifact_fixture_paths "$issue"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  content_file="$WORKSPACES_DIR/$issue/prd.md"
  printf 'PRD content\n' > "$content_file"

  GH_FAIL_LABELS=1 first="$(artifact_ensure "$state_file" "deepansh96/ralphV2" "14" "prd" "create-and-review-prd" "$content_file")"
  mark_issue_closed "$first"
  GH_FAIL_LABELS=1 second="$(artifact_ensure "$state_file" "deepansh96/ralphV2" "14" "prd" "create-and-review-prd" "$content_file")"

  [[ "$second" == "$first" ]] || fail "expected closed registered artifact to be reused"
  assert_contains "$(<"$GH_FIXTURE_DIR/log")" "issue reopen $first"
  create_count="$(grep -c 'issue create' "$GH_FIXTURE_DIR/log")"
  [[ "$create_count" == "1" ]] || fail "expected no duplicate artifact create, got $create_count"
}

test_artifact_ensure_recovers_deleted_state_and_ignores_cross_parent_candidate() {
  local issue state_file content_file other_body artifact_number

  issue="9053"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_artifact_state "$issue"
  install_fake_artifact_gh "$WORKSPACES_DIR/fake-bin" "$WORKSPACES_DIR/artifact-gh-$issue"
  artifact_fixture_paths "$issue"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  content_file="$WORKSPACES_DIR/$issue/prd.md"
  other_body="$WORKSPACES_DIR/$issue/other-body.md"
  printf 'PRD content\n' > "$content_file"
  artifact_write_body "99" "prd" "create-and-review-prd" "$content_file" "$other_body"
  gh issue create --repo "deepansh96/ralphV2" --title "Wrong parent" --body-file "$other_body" >/dev/null
  state_set_artifact "$state_file" "prd" "999"

  artifact_number="$(artifact_ensure "$state_file" "deepansh96/ralphV2" "14" "prd" "create-and-review-prd" "$content_file")"

  [[ "$artifact_number" == "101" ]] || fail "expected deleted state to recover by creating 101, got $artifact_number"
  [[ "$(jq -r '.artifacts.prd' "$state_file")" == "101" ]] || fail "expected recovered artifact to replace stale state"
}

test_artifact_ensure_finds_parent_scoped_candidate_preferring_open_newest() {
  local issue state_file content_file body_file selected

  issue="9054"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_artifact_state "$issue"
  install_fake_artifact_gh "$WORKSPACES_DIR/fake-bin" "$WORKSPACES_DIR/artifact-gh-$issue"
  artifact_fixture_paths "$issue"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  content_file="$WORKSPACES_DIR/$issue/slices.md"
  body_file="$WORKSPACES_DIR/$issue/body.md"
  printf 'Slice plan\n' > "$content_file"

  artifact_write_body "14" "slicePlan" "create-and-review-slices" "$content_file" "$body_file"
  gh issue create --repo "deepansh96/ralphV2" --title "Closed slice plan" --body-file "$body_file" >/dev/null
  mark_issue_closed "100"
  gh issue create --repo "deepansh96/ralphV2" --title "Open older slice plan" --body-file "$body_file" >/dev/null
  gh issue create --repo "deepansh96/ralphV2" --title "Open newer slice plan" --body-file "$body_file" >/dev/null

  selected="$(artifact_ensure "$state_file" "deepansh96/ralphV2" "14" "slicePlan" "create-and-review-slices" "$content_file")"

  [[ "$selected" == "102" ]] || fail "expected newest open candidate 102, got $selected"
  [[ "$(jq -r '.artifacts.slicePlan' "$state_file")" == "102" ]] || fail "expected selected candidate in state"
}

test_artifact_update_body_rejects_wrong_markers_and_oversized_body() {
  local issue state_file content_file body_file bad_file output status

  issue="9055"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_artifact_state "$issue"
  install_fake_artifact_gh "$WORKSPACES_DIR/fake-bin" "$WORKSPACES_DIR/artifact-gh-$issue"
  artifact_fixture_paths "$issue"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  content_file="$WORKSPACES_DIR/$issue/content.md"
  body_file="$WORKSPACES_DIR/$issue/body.md"
  bad_file="$WORKSPACES_DIR/$issue/bad.md"
  printf 'Updated body\n' > "$content_file"
  artifact_write_body "14" "decisions" "review-decisions-1" "$content_file" "$body_file"
  gh issue create --repo "deepansh96/ralphV2" --title "Decisions" --body-file "$body_file" >/dev/null

  artifact_update_body "$state_file" "deepansh96/ralphV2" "14" "decisions" "100" "$body_file"
  [[ "$(jq -r '.artifacts.decisions' "$state_file")" == "100" ]] || fail "expected update to register artifact"

  sed 's/Parent: #14/Parent: #99/' "$body_file" > "$bad_file"
  set +e
  output="$(artifact_update_body "$state_file" "deepansh96/ralphV2" "14" "decisions" "100" "$bad_file" 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "expected wrong parent marker to fail"
  assert_contains "$output" "Parent marker"

  sed 's/Ralph-Artifact: decisions/Ralph-Artifact: prd/' "$body_file" > "$bad_file"
  set +e
  output="$(artifact_update_body "$state_file" "deepansh96/ralphV2" "14" "decisions" "100" "$bad_file" 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "expected wrong artifact type marker to fail"
  assert_contains "$output" "Ralph-Artifact marker"

  {
    printf 'Ralph-Artifact: decisions\nParent: #14\nOwning-Step: review-decisions-1\nLast-Updated: 2026-05-30T00:00:00Z\n---\n'
    head -c 60001 /dev/zero | tr '\0' x
  } > "$bad_file"
  set +e
  output="$(artifact_update_body "$state_file" "deepansh96/ralphV2" "14" "decisions" "100" "$bad_file" 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "expected oversized body to fail"
  assert_contains "$output" "exceeds 60000 bytes"
}

test_artifact_link_to_parent_warns_on_graphql_fallback_without_parent_write() {
  local issue content_file body_file output status

  issue="9056"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_artifact_state "$issue"
  install_fake_artifact_gh "$WORKSPACES_DIR/fake-bin" "$WORKSPACES_DIR/artifact-gh-$issue"
  artifact_fixture_paths "$issue"
  content_file="$WORKSPACES_DIR/$issue/content.md"
  body_file="$WORKSPACES_DIR/$issue/body.md"
  printf 'Parent\n' > "$content_file"
  artifact_write_body "14" "decisions" "review-decisions-1" "$content_file" "$body_file"
  gh issue create --repo "deepansh96/ralphV2" --title "Parent" --body-file "$body_file" >/dev/null
  gh issue create --repo "deepansh96/ralphV2" --title "Artifact" --body-file "$body_file" >/dev/null

  set +e
  output="$(GH_GRAPHQL_FAIL=1 artifact_link_to_parent "deepansh96/ralphV2" "100" "101" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected GraphQL fallback to return success"
  assert_contains "$output" "Warning"
  [[ "$(<"$GH_FIXTURE_DIR/log")" != *"issue edit-body 100"* ]] || fail "expected linking not to write parent body"
}

test_artifact_predicates_and_dispatch_placeholders() {
  local issue artifact_body slice_body false_body output

  issue="9057"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue"
  artifact_body="$WORKSPACES_DIR/$issue/artifact.md"
  slice_body="$WORKSPACES_DIR/$issue/slice.md"
  false_body="$WORKSPACES_DIR/$issue/false.md"

  printf 'Content\n' > "$WORKSPACES_DIR/$issue/content.md"
  artifact_write_body "14" "decisions" "review-decisions-1" "$WORKSPACES_DIR/$issue/content.md" "$artifact_body"
  {
    printf 'AFK: true\n'
    printf 'Parent: #14\n'
    printf '\nImplement this.\n'
  } > "$slice_body"
  {
    printf 'No markers here\n'
    printf '%s\n' '---'
    printf 'Ralph-Artifact: decisions\nParent: #14\n'
  } > "$false_body"

  artifact_is_artifact_issue "$artifact_body" "14" "decisions" || fail "expected artifact predicate to pass"
  ! artifact_is_artifact_issue "$false_body" || fail "expected markers after separator to be ignored"
  slice_is_eligible_implementation "$slice_body" "14" || fail "expected exact AFK/Parent slice to be eligible"
  ! slice_is_eligible_implementation "$artifact_body" "14" || fail "expected artifact issue not to be implementation eligible"

  output="$(cd "$ROOT_DIR/.." && bash "$ROOT_DIR/scripts/artifacts.sh" artifact_is_artifact_issue "$artifact_body" "14" "decisions")"
  [[ -z "$output" ]] || fail "expected predicate dispatch to be quiet"
}

test_slice_eligibility_requires_exact_markers_state_and_tracking() {
  local issue eligible_body wrong_parent_body loose_body artifact_body closed_body

  issue="9064"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  mkdir -p "$WORKSPACES_DIR/$issue"
  eligible_body="$WORKSPACES_DIR/$issue/eligible.md"
  wrong_parent_body="$WORKSPACES_DIR/$issue/wrong-parent.md"
  loose_body="$WORKSPACES_DIR/$issue/loose.md"
  artifact_body="$WORKSPACES_DIR/$issue/artifact.md"
  closed_body="$WORKSPACES_DIR/$issue/closed.md"

  printf 'AFK: true\nParent: #14\n\nBuild it.\n' > "$eligible_body"
  printf 'AFK: true\nParent: #99\n\nWrong run.\n' > "$wrong_parent_body"
  printf 'AFK:true\nParent: #14 \n\nLoose markers.\n' > "$loose_body"
  printf 'AFK: true\nParent: #14\n\nClosed but tracked.\n' > "$closed_body"
  {
    printf 'Ralph-Artifact: prd\n'
    printf 'Parent: #14\n'
    printf 'Owning-Step: create-and-review-prd\n'
    printf 'Last-Updated: now\n'
    printf '%s\n' '---'
    printf 'AFK: true\n'
  } > "$artifact_body"

  slice_is_eligible_implementation "$eligible_body" "14" "OPEN" "false" || fail "expected exact open slice to be eligible"
  ! slice_is_eligible_implementation "$wrong_parent_body" "14" "OPEN" "false" || fail "expected wrong parent to be ineligible"
  ! slice_is_eligible_implementation "$loose_body" "14" "OPEN" "false" || fail "expected non-exact markers to be ineligible"
  ! slice_is_eligible_implementation "$artifact_body" "14" "OPEN" "false" || fail "expected artifact marker to exclude issue"
  ! slice_is_eligible_implementation "$closed_body" "14" "CLOSED" "false" || fail "expected untracked closed slice to be ineligible"
  slice_is_eligible_implementation "$closed_body" "14" "CLOSED" "true" || fail "expected tracked closed slice to remain eligible"
}

test_preflight_slice_collection_excludes_artifacts_and_reports_malformed() {
  local issue state_file issues_json notes_file selected notes

  issue="9065"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_artifact_state "$issue"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  issues_json="$WORKSPACES_DIR/$issue/issues.json"
  notes_file="$WORKSPACES_DIR/$issue/notes.txt"

  jq '.steps += [
    {
      "id": "implement-slice-205",
      "phase": "dynamic",
      "type": "implement-slice",
      "status": "completed",
      "agent": "codex",
      "reviewers": [],
      "hitl": false,
      "sub_issue": 205,
      "metrics": null,
      "notes": ""
    }
  ]' "$state_file" > "$state_file.tmp"
  mv "$state_file.tmp" "$state_file"

  jq -n '[
    {"number":201,"title":"Eligible","state":"OPEN","body":"AFK: true\nParent: #14\n\nBuild."},
    {"number":202,"title":"Artifact","state":"OPEN","body":"Ralph-Artifact: prd\nParent: #14\nOwning-Step: create-and-review-prd\nLast-Updated: now\n---\nAFK: true\n"},
    {"number":203,"title":"Mixed malformed","state":"OPEN","body":"Ralph-Artifact: decisions\nAFK: true\nParent: #14\n---\nBad."},
    {"number":204,"title":"Wrong parent","state":"OPEN","body":"AFK: true\nParent: #99\n\nSkip."},
    {"number":205,"title":"Tracked closed","state":"CLOSED","body":"AFK: true\nParent: #14\n\nKeep."},
    {"number":206,"title":"Untracked closed","state":"CLOSED","body":"AFK: true\nParent: #14\n\nSkip."},
    {"number":207,"title":"Loose marker","state":"OPEN","body":"AFK: true\nParent:#14\n\nSkip."}
  ]' > "$issues_json"

  selected="$(artifact_collect_preflight_slices "$state_file" "14" "$issues_json" "$notes_file")"
  notes="$(<"$notes_file")"

  [[ "$selected" == $'201\n205' ]] || fail "expected only eligible open and tracked closed slices, got: $selected"
  assert_contains "$notes" "Skipped issue #202"
  assert_contains "$notes" "Skipped issue #203: malformed"
  assert_contains "$notes" "Skipped issue #204"
  assert_contains "$notes" "Skipped issue #206"
  assert_contains "$notes" "Skipped issue #207"
}

test_preflight_slice_collection_handles_zero_artifacts() {
  local issue state_file issues_json notes_file selected notes

  issue="9066"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_artifact_state "$issue"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  issues_json="$WORKSPACES_DIR/$issue/issues.json"
  notes_file="$WORKSPACES_DIR/$issue/notes.txt"

  jq -n '[
    {"number":301,"title":"Only slice","state":"OPEN","body":"AFK: true\nParent: #14\n\nBuild."}
  ]' > "$issues_json"

  selected="$(artifact_collect_preflight_slices "$state_file" "14" "$issues_json" "$notes_file")"
  notes="$(<"$notes_file")"

  [[ "$selected" == "301" ]] || fail "expected eligible slice without artifact issues, got: $selected"
  [[ -z "$notes" ]] || fail "expected no skip notes when only eligible slices exist, got: $notes"
}

test_artifact_refresh_parent_index_renders_compact_index_without_artifact_content() {
  local issue state_file content_file body_file output parent_body body_size

  issue="9058"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_artifact_state "$issue"
  install_fake_artifact_gh "$WORKSPACES_DIR/fake-bin" "$WORKSPACES_DIR/artifact-gh-$issue"
  artifact_fixture_paths "$issue"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  content_file="$WORKSPACES_DIR/$issue/content.md"
  body_file="$WORKSPACES_DIR/$issue/body.md"
  write_fixture_issue "14" "Split huge planning artifacts" "Original full feature request"
  printf 'Massive PRD content that must not be copied into the parent index\n' > "$content_file"

  artifact_write_body "14" "decisions" "review-decisions-1" "$content_file" "$body_file"
  gh issue create --repo "deepansh96/ralphV2" --title "Decisions" --body-file "$body_file" >/dev/null
  artifact_write_body "14" "prd" "create-and-review-prd" "$content_file" "$body_file"
  gh issue create --repo "deepansh96/ralphV2" --title "PRD" --body-file "$body_file" >/dev/null
  artifact_write_body "14" "slicePlan" "create-and-review-slices" "$content_file" "$body_file"
  gh issue create --repo "deepansh96/ralphV2" --title "Slice Plan" --body-file "$body_file" >/dev/null
  jq '.artifacts.decisions = 100 | .artifacts.prd = 101 | .artifacts.slicePlan = 102' "$state_file" > "$state_file.tmp"
  mv "$state_file.tmp" "$state_file"

  output="$(artifact_refresh_parent_index "$state_file" "deepansh96/ralphV2" "14")"
  parent_body="$(issue_body 14)"
  body_size="$(printf '%s' "$parent_body" | wc -c | tr -d '[:space:]')"

  assert_contains "$output" '"action":"refreshed"'
  assert_contains "$parent_body" "## Ralph Run Index"
  assert_contains "$parent_body" "## Summary"
  assert_contains "$parent_body" "Split huge planning artifacts"
  assert_contains "$parent_body" "## Routing"
  assert_contains "$parent_body" "- PR: TBD"
  assert_contains "$parent_body" "## Artifacts"
  assert_contains "$parent_body" "- Decisions: #100"
  assert_contains "$parent_body" "- PRD: #101"
  assert_contains "$parent_body" "- Slice Plan: #102"
  assert_contains "$parent_body" "## Implementation Slices"
  assert_contains "$parent_body" "## Notes"
  [[ "$parent_body" != *"Massive PRD content"* ]] || fail "expected parent index not to copy artifact content"
  [[ "$body_size" -lt 2048 ]] || fail "expected ordinary parent index under 2KB, got $body_size"
}

test_artifact_refresh_parent_index_uses_state_pr_before_branch_lookup() {
  local issue state_file output parent_body

  issue="9059"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_artifact_state "$issue"
  install_fake_artifact_gh "$WORKSPACES_DIR/fake-bin" "$WORKSPACES_DIR/artifact-gh-$issue"
  artifact_fixture_paths "$issue"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  write_fixture_issue "14" "PR routing" "Original"
  write_fixture_prs '[{"number":88,"url":"https://github.com/deepansh96/ralphV2/pull/88"}]'
  state_set_pr "$state_file" "77" "https://github.com/deepansh96/ralphV2/pull/77"

  output="$(artifact_refresh_parent_index "$state_file" "deepansh96/ralphV2" "14")"
  parent_body="$(issue_body 14)"

  assert_contains "$output" '"action":"refreshed"'
  assert_contains "$parent_body" "- PR: https://github.com/deepansh96/ralphV2/pull/77"
  [[ "$parent_body" != *"/pull/88"* ]] || fail "expected state PR URL to win over branch lookup"
}

test_artifact_refresh_parent_index_reads_slices_before_preflight_and_warnings() {
  local issue state_file parent_body

  issue="9060"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_artifact_state "$issue"
  install_fake_artifact_gh "$WORKSPACES_DIR/fake-bin" "$WORKSPACES_DIR/artifact-gh-$issue"
  artifact_fixture_paths "$issue"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  write_fixture_issue "14" "Before preflight" "Original"
  write_fixture_issue "200" "Eligible slice" $'AFK: true\nParent: #14\n\nBuild it.'
  write_fixture_issue "201" "Wrong parent" $'AFK: true\nParent: #99\n\nSkip it.'
  printf '%s\n' '- #200 - Eligible slice' '- #201 - Wrong parent' > "$WORKSPACES_DIR/$issue/slices.md"

  artifact_refresh_parent_index "$state_file" "deepansh96/ralphV2" "14" >/dev/null
  parent_body="$(issue_body 14)"

  assert_contains "$parent_body" "- #200 - Eligible slice (OPEN)"
  [[ "$parent_body" != *"#201 - Wrong parent (OPEN)"* ]] || fail "expected wrong-parent slice to be skipped"
  assert_contains "$parent_body" "Skipped issue #201"
}

test_artifact_refresh_parent_index_uses_dynamic_steps_after_preflight() {
  local issue state_file parent_body

  issue="9061"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_artifact_state "$issue"
  install_fake_artifact_gh "$WORKSPACES_DIR/fake-bin" "$WORKSPACES_DIR/artifact-gh-$issue"
  artifact_fixture_paths "$issue"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  write_fixture_issue "14" "After preflight" "Original"
  write_fixture_issue "300" "Tracked slice" $'AFK: true\nParent: #14\n\nBuild it.'
  write_fixture_issue "301" "Also tracked" $'AFK: true\nParent: #14\n\nBuild it.'
  write_fixture_issue "302" "Untracked discovery" $'AFK: true\nParent: #14\n\nShould not appear after preflight.'
  jq '.steps += [
    {
      "id": "implement-slice-300",
      "phase": "dynamic",
      "type": "implement-slice",
      "status": "pending",
      "agent": "codex",
      "reviewers": [],
      "hitl": false,
      "sub_issue": 300,
      "metrics": null,
      "notes": ""
    },
    {
      "id": "implement-slice-301",
      "phase": "dynamic",
      "type": "implement-slice",
      "status": "completed",
      "agent": "codex",
      "reviewers": [],
      "hitl": false,
      "sub_issue": 301,
      "metrics": null,
      "notes": ""
    }
  ]' "$state_file" > "$state_file.tmp"
  mv "$state_file.tmp" "$state_file"

  artifact_refresh_parent_index "$state_file" "deepansh96/ralphV2" "14" >/dev/null
  parent_body="$(issue_body 14)"

  assert_contains "$parent_body" "- #300 - Tracked slice (OPEN, step: pending)"
  assert_contains "$parent_body" "- #301 - Also tracked (OPEN, step: completed)"
  [[ "$parent_body" != *"#302 - Untracked discovery"* ]] || fail "expected dynamic steps to drive after-preflight rendering"
}

test_artifact_close_all_validates_comments_closes_and_skips_slices() {
  local issue state_file content_file body_file log

  issue="9062"
  rm -rf "${WORKSPACES_DIR:?}/$issue"
  write_artifact_state "$issue"
  install_fake_artifact_gh "$WORKSPACES_DIR/fake-bin" "$WORKSPACES_DIR/artifact-gh-$issue"
  artifact_fixture_paths "$issue"
  state_file="$WORKSPACES_DIR/$issue/state.json"
  content_file="$WORKSPACES_DIR/$issue/content.md"
  body_file="$WORKSPACES_DIR/$issue/body.md"
  printf 'Artifact content\n' > "$content_file"
  artifact_write_body "14" "decisions" "review-decisions-1" "$content_file" "$body_file"
  gh issue create --repo "deepansh96/ralphV2" --title "Decisions" --body-file "$body_file" >/dev/null
  artifact_write_body "14" "prd" "create-and-review-prd" "$content_file" "$body_file"
  gh issue create --repo "deepansh96/ralphV2" --title "PRD" --body-file "$body_file" >/dev/null
  mark_issue_closed "101"
  write_fixture_issue "200" "Implementation slice" $'AFK: true\nParent: #14\n\nDo work.'
  jq '.artifacts.decisions = 100 | .artifacts.prd = 101 | .steps += [{"id":"implement-slice-200","type":"implement-slice","sub_issue":200,"status":"completed"}]' "$state_file" > "$state_file.tmp"
  mv "$state_file.tmp" "$state_file"

  artifact_close_all "$state_file" "deepansh96/ralphV2" "14" "Archived by test." >/dev/null
  log="$(<"$GH_FIXTURE_DIR/log")"

  assert_contains "$log" "issue comment 100 Archived by test."
  assert_contains "$log" "issue close 100"
  assert_contains "$log" "issue comment 101 Archived by test."
  [[ "$log" != *"issue close 101"* ]] || fail "expected already-closed artifact not to be closed again"
  [[ "$log" != *"issue close 200"* ]] || fail "expected implementation slice not to be closed"
}

run_test test_artifact_ensure_creates_marker_body_before_state_registration
run_test test_artifact_ensure_reuses_state_reopens_closed_and_tolerates_label_failure
run_test test_artifact_ensure_recovers_deleted_state_and_ignores_cross_parent_candidate
run_test test_artifact_ensure_finds_parent_scoped_candidate_preferring_open_newest
run_test test_artifact_update_body_rejects_wrong_markers_and_oversized_body
run_test test_artifact_link_to_parent_warns_on_graphql_fallback_without_parent_write
run_test test_artifact_predicates_and_dispatch_placeholders
run_test test_slice_eligibility_requires_exact_markers_state_and_tracking
run_test test_preflight_slice_collection_excludes_artifacts_and_reports_malformed
run_test test_preflight_slice_collection_handles_zero_artifacts
run_test test_artifact_refresh_parent_index_renders_compact_index_without_artifact_content
run_test test_artifact_refresh_parent_index_uses_state_pr_before_branch_lookup
run_test test_artifact_refresh_parent_index_reads_slices_before_preflight_and_warnings
run_test test_artifact_refresh_parent_index_uses_dynamic_steps_after_preflight
run_test test_artifact_close_all_validates_comments_closes_and_skips_slices

echo "artifact_helper_test.sh passed"
