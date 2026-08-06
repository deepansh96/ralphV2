#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

test_skills_bundle_is_self_contained_and_readme_documents_workflow() {
  local required_files readme agents tests_readme global_skill_ref stale_refs broken_links link_records file target target_without_anchor resolved

  required_files=(
    "$ROOT_DIR/skills/to-spec/SKILL.md"
    "$ROOT_DIR/skills/to-tickets/SKILL.md"
    "$ROOT_DIR/skills/grill-with-docs/SKILL.md"
    "$ROOT_DIR/skills/grilling/SKILL.md"
    "$ROOT_DIR/skills/wayfinder/SKILL.md"
    "$ROOT_DIR/skills/research/SKILL.md"
    "$ROOT_DIR/skills/matt-pocock-code-review/SKILL.md"
    "$ROOT_DIR/skills/ponytail-review/SKILL.md"
    "$ROOT_DIR/skills/run-codex-review/SKILL.md"
    "$ROOT_DIR/skills/run-codex-review/scripts/review.mjs"
    "$ROOT_DIR/skills/supe-review-code-changes/SKILL.md"
    "$ROOT_DIR/skills/tdd/SKILL.md"
    "$ROOT_DIR/skills/tdd/tests.md"
    "$ROOT_DIR/skills/tdd/mocking.md"
    "$ROOT_DIR/skills/domain-modeling/SKILL.md"
    "$ROOT_DIR/skills/domain-modeling/DOMAIN-AWARENESS.md"
    "$ROOT_DIR/skills/domain-modeling/CONTEXT-FORMAT.md"
    "$ROOT_DIR/skills/domain-modeling/ADR-FORMAT.md"
    "$ROOT_DIR/skills/wizard/SKILL.md"
    "$ROOT_DIR/skills/wizard/template.sh"
    "$ROOT_DIR/skills/wizard/agents/openai.yaml"
    "$ROOT_DIR/skills/wizard/LICENSE"
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

  bash -n "$ROOT_DIR/skills/wizard/template.sh"

  readme="$ROOT_DIR/README.md"
  [[ -f "$readme" ]] || fail "expected ralph-v2 README"
  assert_contains "$(<"$readme")" "ralph.sh --issue N"
  assert_contains "$(<"$readme")" "ralph.sh status --issue N"
  assert_contains "$(<"$readme")" "ralph.sh logs --issue N"
  assert_contains "$(<"$readme")" "./tests/run.sh"
  assert_contains "$(<"$readme")" "tests/suites/"
  assert_contains "$(<"$readme")" "cleanup.sh <issue-number>"
  assert_contains "$(<"$readme")" "grill"
  assert_contains "$(<"$readme")" "grill/*"
  assert_contains "$(<"$readme")" "planning branch"
  assert_contains "$(<"$readme")" "baseBranch"
  assert_contains "$(<"$readme")" "init"
  assert_contains "$(<"$readme")" "run"
  assert_contains "$(<"$readme")" "cleanup"
  assert_contains "$(<"$readme")" "state.json"
  assert_contains "$(<"$readme")" "review-decisions"
  assert_contains "$(<"$readme")" "implement-slice"
  assert_contains "$(<"$readme")" "final-checks"
  assert_contains "$(<"$readme")" "pr-creation"
  assert_contains "$(<"$readme")" "prepare-qa-checklist"
  assert_contains "$(<"$readme")" "runthrough-qa-checklist"
  assert_contains "$(<"$readme")" "multi-axis-pr-review"
  assert_contains "$(<"$readme")" "cleanup-local-resources"
  assert_contains "$(<"$readme")" "wayfinder"
  assert_contains "$(<"$readme")" "wizard"
  assert_contains "$(<"$readme")" "docs/agents/issue-tracker.md"

  agents="$ROOT_DIR/AGENTS.md"
  assert_contains "$(<"$agents")" "skills/wizard/SKILL.md"

  tests_readme="$ROOT_DIR/tests/README.md"
  [[ -f "$tests_readme" ]] || fail "expected tests README"
  assert_contains "$(<"$tests_readme")" "./tests/run.sh"
  assert_contains "$(<"$tests_readme")" "Suite Map"
  assert_contains "$(<"$tests_readme")" "prompt_contracts_test.sh"
  assert_contains "$(<"$tests_readme")" "External tools"
}

test_isolated_codex_review_timeout_exits() {
  local fake_bin output_file pid status alive attempt

  fake_bin="$WORKSPACES_DIR/fake-bin"
  output_file="$fake_bin/review-output"
  rm -rf "$fake_bin"
  mkdir -p "$fake_bin"

  cat > "$fake_bin/codex" <<'FAKE'
#!/usr/bin/env bash
count=0
while IFS= read -r line; do
  count=$((count + 1))
  case "$count" in
    1) printf '{"id":1,"result":{}}\n' ;;
    3) printf '{"id":2,"result":{"thread":{"id":"thread-1"}}}\n' ;;
    4)
      printf '{"id":3,"result":{"turn":{"id":"turn-1"}}}\n'
      printf reached-review-start > "${CODEX_REVIEW_MARKER:?}"
      ;;
  esac
done
FAKE
  chmod +x "$fake_bin/codex"

  set +e
  CODEX_REVIEW_MARKER="$fake_bin/reached-review-start" \
    CODEX_BIN="$fake_bin/codex" \
    node "$ROOT_DIR/skills/run-codex-review/scripts/review.mjs" \
      --cwd "$ROOT_DIR" --custom smoke --timeout 1 \
      > "$output_file" 2>&1 &
  pid=$!
  set -e

  alive="true"
  for attempt in {1..60}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      alive="false"
      break
    fi
    sleep 0.05
  done

  if [[ "$alive" == "true" ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "expected timed-out isolated review process to exit"
  fi

  set +e
  wait "$pid"
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "expected timed-out isolated review to fail"
  [[ -f "$fake_bin/reached-review-start" ]] || fail "expected fake App Server to reach review/start"
  assert_contains "$(<"$output_file")" "Review timed out after 1 seconds"
}

run_test test_skills_bundle_is_self_contained_and_readme_documents_workflow
run_test test_isolated_codex_review_timeout_exits

echo "skill_docs_test.sh passed"
