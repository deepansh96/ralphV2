#!/usr/bin/env bash
DELEGATION_QA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DELEGATION_QA_DIR/delegation.sh"

# Marked comment body on stdin; canonical sorted [{id,text}] instruction items
# on stdout. Exit 2 means a malformed, duplicated, or unmarked checklist.
delegation_qa_checklist_items() {
  node "$DELEGATION_QA_DIR/delegation-qa.cjs" items
}

# [{id,text}] on stdin; sha256:<hex> of the compact items sorted by id.
delegation_qa_checklist_digest() {
  node "$DELEGATION_QA_DIR/delegation-qa.cjs" checklist-digest
}

# {taskId,checklistItemIds} on stdin; sha256:<hex> of the canonical assignment.
delegation_qa_assignment_digest() {
  node "$DELEGATION_QA_DIR/delegation-qa.cjs" assignment-digest
}

# Refetch one exact marked comment. stdout {commentId,updatedAt,items}.
# Exit 1: deleted, unreadable, or not that comment. Exit 2: malformed checklist.
delegation_qa_checklist_fetch() {
  local repo="$1" id="$2" comment body items
  [[ "$id" =~ ^[0-9]+$ ]] || return 1
  comment="$(gh api "repos/$repo/issues/comments/$id" 2>/dev/null)" || return 1
  jq -e --arg id "$id" '(.id | tostring) == $id and (.body | type == "string")
    and (.updated_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' <<< "$comment" >/dev/null 2>&1 || return 1
  body="$(jq -r '.body' <<< "$comment")"
  items="$(delegation_qa_checklist_items <<< "$body" 2>/dev/null)" || return $?
  jq -c --argjson items "$items" '{commentId: (.id | tostring), updatedAt: .updated_at, items: $items}' <<< "$comment"
}

# Parent-side snapshot before the first spawn. Assignments [{taskId,
# checklistItemIds}] on stdin. Writes WORKSPACE/delegation/STEP.plan.json (0600,
# atomic) next to STATE and prints the plan. The attempt comes from State; an
# ungated legacy step has none and records "ungated", which no gate accepts.
delegation_qa_plan_write() {
  local state="$1" step="$2" repo="$3" id="$4" assignments snapshot attempt plan workspace
  assignments="$(cat)"
  snapshot="$(delegation_qa_checklist_fetch "$repo" "$id")" || return 1
  attempt="$(jq -r --arg step "$step" '[.steps[] | select(.id == $step)] | if length == 1 then (.[0].delegationAttempt.id // "ungated") else error("step") end' "$state" 2>/dev/null)" || return 1
  plan="$(jq -nc --arg step "$step" --arg attempt "$attempt" --argjson snapshot "$snapshot" --argjson assignments "$assignments" \
    '{stepId: $step, attemptId: $attempt, snapshot: $snapshot, assignments: $assignments}' 2>/dev/null \
    | node "$DELEGATION_QA_DIR/delegation-qa.cjs" plan 2>/dev/null)" || return 1
  delegation_validate plan <<< "$plan" || return 1
  workspace="$(dirname "$state")"
  (umask 077; mkdir -p "$workspace/delegation") || return 1
  delegation_write_json "$workspace/delegation" "$step.plan.json" plan <<< "$plan" 2>/dev/null || return 1
  printf '%s\n' "$plan"
}

# Runner-side refetch after the provider run. stdout is the verification
# request's `qa` field: {plan, checklist}. plan is the file's JSON value, null
# when absent, or "invalid" when unparsable. checklist is null without a plan
# commentId, else {commentId, status: ok|unavailable|invalid, items}.
delegation_qa_verification() {
  local plan_file="$1" repo="$2" plan=null id snapshot status checklist=null
  if [[ -e "$plan_file" ]]; then
    plan="$(jq -cse 'if length == 1 then .[0] else error("one value") end' "$plan_file" 2>/dev/null)" || plan='"invalid"'
  fi
  id="$(jq -r 'if type == "object" and (.checklist | type == "object") and (.checklist.commentId | type == "string") then .checklist.commentId else empty end' <<< "$plan")"
  if [[ -n "$id" ]]; then
    snapshot="$(delegation_qa_checklist_fetch "$repo" "$id")" && status=0 || status=$?
    case "$status" in
      0) checklist="$(jq -c '{commentId, status: "ok", items}' <<< "$snapshot")" ;;
      2) checklist="$(jq -nc --arg id "$id" '{commentId: $id, status: "invalid", items: null}')" ;;
      *) checklist="$(jq -nc --arg id "$id" '{commentId: $id, status: "unavailable", items: null}')" ;;
    esac
  fi
  jq -nc --argjson plan "$plan" --argjson checklist "$checklist" '{plan: $plan, checklist: $checklist}'
}
