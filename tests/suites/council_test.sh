#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

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

run_test test_council_review_submits_polls_reads_cleans_up_and_prints_review
run_test test_council_review_handles_member_failure_and_cleans_up
run_test test_council_review_handles_timeout_and_cleans_up

echo "council_test.sh passed"
