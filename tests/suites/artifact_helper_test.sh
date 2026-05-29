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
          jq -s '[.[] | {number, state, createdAt}]' "$fixture"/issues/*.json
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

  output="$(cd "$ROOT_DIR/.." && bash "$ROOT_DIR/scripts/artifacts.sh" artifact_refresh_parent_index)"
  assert_contains "$output" '"action":"artifact_refresh_parent_index"'
  output="$(cd "$ROOT_DIR" && bash scripts/artifacts.sh artifact_close_all)"
  assert_contains "$output" '"action":"artifact_close_all"'
}

run_test test_artifact_ensure_creates_marker_body_before_state_registration
run_test test_artifact_ensure_reuses_state_reopens_closed_and_tolerates_label_failure
run_test test_artifact_ensure_recovers_deleted_state_and_ignores_cross_parent_candidate
run_test test_artifact_ensure_finds_parent_scoped_candidate_preferring_open_newest
run_test test_artifact_update_body_rejects_wrong_markers_and_oversized_body
run_test test_artifact_link_to_parent_warns_on_graphql_fallback_without_parent_write
run_test test_artifact_predicates_and_dispatch_placeholders

echo "artifact_helper_test.sh passed"
