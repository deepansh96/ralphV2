#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

test_skills_bundle_is_self_contained_and_readme_documents_workflow() {
  local required_files readme tests_readme global_skill_ref stale_refs broken_links link_records file target target_without_anchor resolved

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
  assert_contains "$(<"$readme")" "grill/*"
  assert_contains "$(<"$readme")" "planning branch"
  assert_contains "$(<"$readme")" "baseBranch"
  assert_contains "$(<"$readme")" "init"
  assert_contains "$(<"$readme")" "run"
  assert_contains "$(<"$readme")" "cleanup"
  assert_contains "$(<"$readme")" "state.json"
  assert_contains "$(<"$readme")" "review-decisions"
  assert_contains "$(<"$readme")" "implement-slice"
  assert_contains "$(<"$readme")" "pr-review"
  assert_contains "$(<"$readme")" "review-fixes"

  tests_readme="$ROOT_DIR/tests/README.md"
  [[ -f "$tests_readme" ]] || fail "expected tests README"
  assert_contains "$(<"$tests_readme")" "./tests/run.sh"
  assert_contains "$(<"$tests_readme")" "Suite Map"
  assert_contains "$(<"$tests_readme")" "prompt_contracts_test.sh"
  assert_contains "$(<"$tests_readme")" "External tools"
}

run_test test_skills_bundle_is_self_contained_and_readme_documents_workflow

echo "skill_docs_test.sh passed"
