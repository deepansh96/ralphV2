#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

install_fake_cleanup_gh() {
  local fake_bin="$1"
  local fixture_dir="$2"

  rm -rf "$fake_bin" "$fixture_dir"
  mkdir -p "$fake_bin" "$fixture_dir/issues"
  : > "$fixture_dir/log"

  cat > "$fake_bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

fixture="${GH_FIXTURE_DIR:?}"
log_file="$fixture/log"

issue_file() {
  printf '%s/issues/%s.json\n' "$fixture" "$1"
}

log() {
  printf '%s\n' "$*" >> "$log_file"
}

[[ "${GH_FAIL_ALL:-}" != "1" ]] || exit 44

cmd="${1:-}"
shift || true

case "$cmd" in
  issue)
    sub="${1:-}"
    shift || true
    case "$sub" in
      view)
        number="$1"
        shift || true
        file="$(issue_file "$number")"
        [[ -f "$file" ]] || exit 1
        cat "$file"
        ;;
      comment)
        number="$1"
        shift || true
        body=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --repo) shift 2 ;;
            --body) body="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        log "comment $number $body"
        ;;
      close)
        number="$1"
        shift || true
        file="$(issue_file "$number")"
        [[ -f "$file" ]] || exit 1
        tmp="$(mktemp)"
        jq '.state = "CLOSED"' "$file" > "$tmp"
        mv "$tmp" "$file"
        log "close $number"
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  *)
    exit 2
    ;;
esac
FAKE_GH
  chmod +x "$fake_bin/gh"
}

write_cleanup_state() {
  local issue="$1"

  mkdir -p "$WORKSPACES_DIR/$issue"
  jq -n \
    --argjson issue "$issue" \
    '{
      issue: $issue,
      repo: "deepansh96/ralphV2",
      baseBranch: "main",
      branch: "feat/cleanup",
      projectRoot: "/tmp/project",
      artifacts: {
        decisions: 100,
        prd: 101,
        slicePlan: null
      },
      pr: null,
      steps: [
        {
          id: "implement-slice-200",
          type: "implement-slice",
          sub_issue: 200,
          status: "completed"
        }
      ]
    }' > "$WORKSPACES_DIR/$issue/state.json"
}

write_cleanup_issue() {
  local fixture_dir="$1"
  local number="$2"
  local body="$3"
  local state="${4:-OPEN}"

  jq -n \
    --argjson number "$number" \
    --arg body "$body" \
    --arg state "$state" \
    '{
      number: $number,
      title: ("Issue " + ($number | tostring)),
      state: $state,
      createdAt: "2026-05-30T00:00:00Z",
      body: $body,
      id: ("ISSUE_" + ($number | tostring))
    }' > "$fixture_dir/issues/$number.json"
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

test_cleanup_closes_registered_artifacts_before_archive_with_comment() {
  local issue date destination fake_bin fixture output log

  issue="9063"
  date="$(date +%Y-%m-%d)"
  destination="$ARCHIVE_DIR/$date-$issue"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  fixture="$WORKSPACES_DIR/artifact-gh-$issue"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$destination"
  write_cleanup_state "$issue"
  install_fake_cleanup_gh "$fake_bin" "$fixture"
  write_cleanup_issue "$fixture" "100" $'Ralph-Artifact: decisions\nParent: #9063\nOwning-Step: review-decisions-1\nLast-Updated: now\n---\nBody'
  write_cleanup_issue "$fixture" "101" $'Ralph-Artifact: prd\nParent: #9063\nOwning-Step: create-and-review-prd\nLast-Updated: now\n---\nBody'
  write_cleanup_issue "$fixture" "200" $'AFK: true\nParent: #9063\n\nImplementation'

  output="$(GH_FIXTURE_DIR="$fixture" PATH="$fake_bin:$PATH" "$CLEANUP_SCRIPT" "$issue")"
  log="$(<"$fixture/log")"

  [[ -f "$destination/state.json" ]] || fail "expected archived state"
  assert_contains "$output" "Archived workspace"
  assert_contains "$log" "comment 100 Archived by Ralph cleanup for parent #9063."
  assert_contains "$log" "close 100"
  assert_contains "$log" "comment 101 Archived by Ralph cleanup for parent #9063."
  assert_contains "$log" "close 101"
  [[ "$log" != *"close 200"* ]] || fail "expected cleanup not to close implementation slices"
}

test_cleanup_treats_already_closed_artifacts_as_success() {
  local issue date destination fake_bin fixture output log

  issue="9062"
  date="$(date +%Y-%m-%d)"
  destination="$ARCHIVE_DIR/$date-$issue"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  fixture="$WORKSPACES_DIR/artifact-gh-$issue"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$destination"
  write_cleanup_state "$issue"
  install_fake_cleanup_gh "$fake_bin" "$fixture"
  write_cleanup_issue "$fixture" "100" $'Ralph-Artifact: decisions\nParent: #9062\nOwning-Step: review-decisions-1\nLast-Updated: now\n---\nBody' "CLOSED"
  write_cleanup_issue "$fixture" "101" $'Ralph-Artifact: prd\nParent: #9062\nOwning-Step: create-and-review-prd\nLast-Updated: now\n---\nBody'

  output="$(GH_FIXTURE_DIR="$fixture" PATH="$fake_bin:$PATH" "$CLEANUP_SCRIPT" "$issue")"
  log="$(<"$fixture/log")"

  [[ -f "$destination/state.json" ]] || fail "expected archive despite already-closed artifact"
  assert_contains "$output" "Archived workspace"
  assert_contains "$log" "comment 100 Archived by Ralph cleanup for parent #9062."
  [[ "$log" != *"close 100"* ]] || fail "expected already-closed artifact not to be closed again"
  assert_contains "$log" "close 101"
}

test_cleanup_warns_but_archives_when_artifact_closure_fails() {
  local issue date destination fake_bin fixture output status

  issue="9061"
  date="$(date +%Y-%m-%d)"
  destination="$ARCHIVE_DIR/$date-$issue"
  fake_bin="$WORKSPACES_DIR/fake-bin"
  fixture="$WORKSPACES_DIR/artifact-gh-$issue"
  rm -rf "${WORKSPACES_DIR:?}/$issue" "$destination"
  write_cleanup_state "$issue"
  install_fake_cleanup_gh "$fake_bin" "$fixture"
  write_cleanup_issue "$fixture" "100" $'Ralph-Artifact: decisions\nParent: #9061\nOwning-Step: review-decisions-1\nLast-Updated: now\n---\nBody'

  set +e
  output="$(GH_FIXTURE_DIR="$fixture" GH_FAIL_ALL=1 PATH="$fake_bin:$PATH" "$CLEANUP_SCRIPT" "$issue" 2>&1)"
  status=$?
  set -e

  [[ "$status" -eq 0 ]] || fail "expected cleanup to succeed despite artifact closure failure"
  [[ -f "$destination/state.json" ]] || fail "expected archive despite artifact closure failure"
  assert_contains "$output" "Warning: artifact closure failed; continuing with local archive"
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

run_test test_cleanup_archives_workspace_by_issue_number
run_test test_cleanup_closes_registered_artifacts_before_archive_with_comment
run_test test_cleanup_treats_already_closed_artifacts_as_success
run_test test_cleanup_warns_but_archives_when_artifact_closure_fails
run_test test_cleanup_errors_when_workspace_is_missing
run_test test_cleanup_errors_when_archive_destination_exists
run_test test_cleanup_validates_issue_number
run_test test_cleanup_removes_empty_workspaces_directory

echo "cleanup_test.sh passed"
