#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/delegation.sh"
valid='{"schemaVersion":1,"policy":"pr-review-v1"}'
delegation_validate metadata <<< "$valid"
delegation_validate metadata <<< '{"schemaVersion":1,"policy":"qa-v1"}'
for invalid in 'null' '{}' '{"schemaVersion":2,"policy":"qa-v1"}' '{"schemaVersion":1,"policy":"other"}' '{"schemaVersion":1,"policy":"qa-v1","prompt":"secret"}'; do
  if delegation_validate metadata <<< "$invalid"; then exit 1; fi
done
child='{"childId":"child-1","parentId":"parent-1","taskId":"matt_spec","run":1,"assignmentDigest":null,"started":true,"completed":true,"outcome":"completed","effective":{"model":null,"reasoningEffort":null},"nested":false}'
delegation_validate child <<< "$child"
for mutation in '. + {prompt:"secret"}' '.effective += {response:"secret"}' '.run = 0' '.outcome = "success"' '.started = "true"' '.assignmentDigest = "bad"'; do
  if jq "$mutation" <<< "$child" | delegation_validate child; then exit 1; fi
done
[[ "$(delegation_sort_codes <<< '["TASK_MISSING","CHILD_FAILED","TASK_MISSING"]')" == '["CHILD_FAILED","TASK_MISSING"]' ]]
if delegation_sort_codes <<< '["UNKNOWN"]'; then exit 1; fi
manifest='{"schemaVersion":1,"issue":37,"stepId":"review","attemptId":"attempt-1","provider":"codex","evidenceSource":"app-server","parentId":"parent-1","policy":"pr-review-v1","requested":{"parent":{"model":"sol","reasoningEffort":"medium"},"worker":{"model":"luna","reasoningEffort":"max"}},"expected":{"taskCount":1,"taskIds":["matt_spec"]},"observed":{"startedCount":1,"completedCount":1,"selectedCount":1},"children":[],"evidenceLevel":"OBSERVED","mismatchCodes":[]}'
manifest="$(jq --argjson child "$child" '.children = [$child + {disposition:"selected"}]' <<< "$manifest")"
delegation_validate manifest <<< "$manifest"
for mutation in '.requested = .requested.parent' '.requested.worker.prompt = "secret"' '.children[0].response = "secret"' '.mismatchCodes = ["TASK_MISSING","CHILD_FAILED"]' '.evidenceLevel = "OK"' '.transcript = "/secret"'; do
  if jq "$mutation" <<< "$manifest" | delegation_validate manifest; then exit 1; fi
done
plan='{"schemaVersion":1,"stepId":"runthrough-qa-checklist","attemptId":"attempt-1","checklist":{"commentId":"123","updatedAt":"2026-08-25T10:00:00Z","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","items":[{"id":"QA-01","text":"First check instruction"}]},"assignments":[{"taskId":"qa_group_1","checklistItemIds":["QA-01"],"assignmentDigest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}'
delegation_validate plan <<< "$plan"
for mutation in '.checklist.items = ["QA-01"]' '.checklist.items[0].response = "secret"' '.assignments[0].packet = "secret"' '.checklist.items += .checklist.items' '.assignments[0].checklistItemIds = ["QA-02","QA-01"]' '.checklist.items[0].id = "bad"'; do
  if jq "$mutation" <<< "$plan" | delegation_validate plan; then exit 1; fi
done
workspace="$(mktemp -d "${TMPDIR:-/tmp}/ralph-37-delegation.XXXXXX")"
trap 'rm -rf "$workspace"' EXIT
# Invalid replacements leave the last complete artifact intact; valid writes
# replace an inode, so readers holding the old file still see complete JSON.
delegation_write_json "$workspace" manifest.json manifest <<< "$manifest"
node - "$workspace/manifest.json" <<'JS'
const fs=require('fs'),assert=require('assert');
assert.equal(fs.statSync(process.argv[2]).mode & 0o777,0o600);
JS
exec 3< "$workspace/manifest.json"
jq '.evidenceLevel = "VERIFIED"' <<< "$manifest" | delegation_write_json "$workspace" manifest.json manifest
[[ "$(jq -r .evidenceLevel <&3)" == OBSERVED ]]
exec 3<&-
[[ "$(jq -r .evidenceLevel "$workspace/manifest.json")" == VERIFIED ]]
if delegation_write_json "$workspace" manifest.json manifest <<< '{}'; then exit 1; fi
[[ "$(jq -r .evidenceLevel "$workspace/manifest.json")" == VERIFIED ]]
if delegation_write_json "$workspace" ../escape.json manifest <<< "$manifest"; then exit 1; fi
ln -s "$workspace/manifest.json" "$workspace/link.json"
if delegation_write_json "$workspace" link.json manifest <<< "$manifest"; then exit 1; fi
[[ "$(find "$workspace" -name '*.tmp-*' | wc -l | tr -d ' ')" == 0 ]]
cat > "$workspace/state.json" <<'JSON'
{"issue":37,"unrelated":"preserved","steps":[{"id":"review","status":"pending","delegation":{"schemaVersion":1,"policy":"pr-review-v1"}},{"id":"legacy","status":"pending"}]}
JSON
prepare_fixture() {
  local state="$1" step="$2" inputs="$3"
  jq -e --arg id "$step" '.steps[] | select(.id == $id) | .status == "in_progress"' "$state" >/dev/null
  jq -r --arg id "$step" '.steps[] | select(.id == $id) | .delegationAttempt.id' "$state" > "$inputs/prompt"
  [[ ! -e "$inputs/evidence.json" ]]
}
first="$(delegation_prepare_invocation "$workspace/state.json" review prepare_fixture)"
printf 'old evidence' > "$first/evidence.json"
first_id="$(cat "$first/prompt")"
# The same entry point is called on CLI retry and on manual/HITL resume.
for status in in_progress pending blocked; do
  value="$(jq --arg status "$status" '.steps[0].status = $status' "$workspace/state.json")"
  printf '%s\n' "$value" > "$workspace/state.json"
  current="$(delegation_prepare_invocation "$workspace/state.json" review prepare_fixture)"
  [[ "$current" != "$first" && "$(cat "$current/prompt")" != "$first_id" ]]
  [[ ! -e "$current/evidence.json" ]]
  jq -e --arg id "$(cat "$current/prompt")" '.unrelated == "preserved" and .steps[0].delegationAttempt.id == $id and (.steps[0].delegationAttempt.startedAt | type == "number" and floor == . and . > 1787590000)' "$workspace/state.json" >/dev/null
done
before="$(cat "$workspace/state.json")"
[[ -z "$(delegation_prepare_invocation "$workspace/state.json" legacy prepare_fixture)" ]]
[[ "$(cat "$workspace/state.json")" == "$before" ]]
# Malformed metadata must not stamp or render anything.
value="$(jq '.steps[0].delegation.policy = "unknown"' "$workspace/state.json")"
printf '%s\n' "$value" > "$workspace/state.json"
if delegation_prepare_invocation "$workspace/state.json" review prepare_fixture; then exit 1; fi
[[ "$(cat "$workspace/state.json")" == "$value" ]]
# Both adapters share a stable ordering without discarding duplicate evidence.
children="$(jq -n --argjson child "$child" '[$child + {childId:"z",taskId:"supe"}, $child + {childId:"b"}, $child + {childId:"a"}]')"
[[ "$(delegation_sort_children <<< "$children" | jq -c '[.[].childId]')" == '["a","b","z"]' ]]
if delegation_sort_children <<< '[{"prompt":"secret"}]'; then exit 1; fi
# Reject malformed attempt fields and multiple JSON documents.
for invalid in '{}' '{"id":"x","startedAt":-1}' '{"id":"x","startedAt":1.5}' '{"id":"x","startedAt":"1"}' '{"id":"x","startedAt":1,"path":"secret"}'; do
  if delegation_validate attempt <<< "$invalid"; then exit 1; fi
done
if printf '%s\n%s\n' "$valid" "$valid" | delegation_validate metadata; then exit 1; fi
if delegation_validate metadata </dev/null; then exit 1; fi
# Preparation failure keeps the final attempt for audit but supplies no usable
# invocation directory to the caller. A subsequent invocation must start fresh.
value="$(jq '.steps[0].delegation.policy = "pr-review-v1"' "$workspace/state.json")"
printf '%s\n' "$value" > "$workspace/state.json"
fail_prepare() { return 17; }
if output="$(delegation_prepare_invocation "$workspace/state.json" review fail_prepare)"; then exit 1; fi
[[ -z "$output" ]]
failed_id="$(jq -r '.steps[0].delegationAttempt.id' "$workspace/state.json")"
[[ "$failed_id" != "$(cat "$current/prompt")" ]]
current="$(delegation_prepare_invocation "$workspace/state.json" review prepare_fixture)"
[[ "$(cat "$current/prompt")" != "$failed_id" ]]
# Completion through the existing State API preserves the final attempt.
source "$ROOT/scripts/state.sh"
state_update_step "$workspace/state.json" review completed
[[ "$(jq -r '.steps[0].delegationAttempt.id' "$workspace/state.json")" == "$(cat "$current/prompt")" ]]
node - "$current" <<'JS'
const fs=require('fs'),assert=require('assert');
assert.equal(fs.statSync(process.argv[2]).mode & 0o777,0o700);
assert.equal(fs.statSync(process.argv[2]+'/prompt').mode & 0o777,0o600);
JS
echo 'delegation_test.sh passed'
