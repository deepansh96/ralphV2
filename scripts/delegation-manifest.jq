# Input: one validated verification request. Output: the v1 manifest.
# Ralph only observes: it never spawns, groups, or retries workers here.
def families: ["sonnet","opus","haiku","fable"];
# Family aliases accept only a canonical Claude ID of the same family; explicit
# IDs (and unknown short names) require an exact match.
def model_ok($requested; $reported):
  if (families | index($requested)) != null then
    ($reported | split("-")) as $parts
    | $parts[0] == "claude" and (($parts[1:] | index($requested)) != null)
  else $reported == $requested end;
# $digests: null for pr-review-v1; for qa-v1 the recomputed plan and refetched
# checklist digests (delegation_manifest_qa_digests).

. as $r |
($r.policy == "qa-v1") as $qa |
# A QA plan is usable only when schema-valid, self-consistent, and covering no
# foreign IDs; otherwise PLAN_INVALID and no task identity is judged.
(if $qa and $digests.planValid then $r.qa.plan else null end) as $candidate |
(if $candidate == null then null
 else [$candidate.checklist.items[].id] as $ids
   | if $digests.checklist != $candidate.checklist.digest
       or any($candidate.assignments[].checklistItemIds[]; . as $id | $ids | index($id) == null)
     then null else $candidate end end) as $plan |
(if $r.policy == "pr-review-v1" then ["isolated_codex","matt_spec","matt_standards","ponytail","supe"]
 elif $plan != null then [$plan.assignments[].taskId] else [] end) as $tasks |
($r.evidence.children // []) as $children |
[$children[] | select(.nested | not)] as $direct |
$r.evidence.parentId as $parent |
$r.requested.worker as $worker |
[
  (if $r.providerFailed then "PROVIDER_FAILED" else empty end),
  (if $r.evidence == null then "EVIDENCE_UNAVAILABLE" else empty end),
  (if $r.policy | IN("pr-review-v1","qa-v1") | not then "POLICY_UNSUPPORTED" else empty end),
  (if $qa then
     if $r.qa.plan == null then "PLAN_MISSING"
     elif $plan == null then "PLAN_INVALID"
     else
       [$plan.checklist.items[].id] as $ids |
       [$plan.assignments[].checklistItemIds[]] as $assigned |
       (if $plan.attemptId != $r.attemptId then "ATTEMPT_MISMATCH" else empty end),
       ($plan.assignments[] | select($digests.assignments[.taskId] != .assignmentDigest) | "ASSIGNMENT_DIGEST_MISMATCH"),
       ($ids[] | . as $id | select($assigned | index($id) == null) | "ASSIGNMENT_MISSING"),
       (if ($assigned | length) != ($assigned | unique | length) then "ASSIGNMENT_DUPLICATED" else empty end),
       # The refetched exact comment must keep the same instructions and IDs;
       # updatedAt is audit metadata and never compared.
       ($r.qa.checklist as $c |
        if $c == null or $c.status == "unavailable" or $c.commentId != $plan.checklist.commentId then "CHECKLIST_UNAVAILABLE"
        elif $c.status == "invalid" then "CHECKLIST_INVALID"
        elif $digests.refetched != $plan.checklist.digest or ([$c.items[].id] | sort) != $ids then "CHECKLIST_CHANGED"
        else empty end)
     end
   else empty end),
  (if $r.evidence != null then
     if $r.evidence.attemptId == null then "ATTEMPT_MISSING"
     elif $r.evidence.attemptId != $r.attemptId then "ATTEMPT_MISMATCH"
     else empty end
   else empty end),
  ($children[] | select(.nested) | "NESTED_WORKER"),
  ($direct[] | select(.parentId != $parent) | "PARENT_MISMATCH"),
  ($direct[] |
    if .outcome == "failed" then "CHILD_FAILED"
    elif .outcome == "stopped" then "CHILD_STOPPED"
    elif .completed then empty
    elif .started then "CHILD_INCOMPLETE"
    else "CHILD_MISSING" end),
  ($direct[] | select(.effective.model != null and (model_ok($worker.model; .effective.model) | not)) | "MODEL_MISMATCH"),
  ($direct[] | . as $c | select(any(($r.evidence.modelHistory[$c.childId] // [])[]; model_ok($worker.model; .) | not)) | "MODEL_MISMATCH"),
  ($direct[] | select(.effective.reasoningEffort != null and .effective.reasoningEffort != $worker.reasoningEffort) | "EFFORT_MISMATCH"),
  # Task identity is judged only under a supported policy with bound evidence:
  # each expected (taskId, run 1) pair appears exactly once.
  # qa-v1 identity: every direct child proves one immutable plan assignment
  # (digest and task ID). This slice allows exactly one run-1 worker per
  # assignment; replacement runs and supersession arrive in #46.
  (if $plan != null and $r.evidence != null then
     ($plan.assignments[] | . as $a
       | [$direct[] | select(.assignmentDigest == $a.assignmentDigest and .taskId == $a.taskId and .run == 1)] | length
       | if . == 0 then "TASK_MISSING" elif . > 1 then "TASK_DUPLICATED" else empty end),
     ($direct[] | . as $c | [$plan.assignments[] | select(.assignmentDigest == $c.assignmentDigest)] as $m
       | if ($m | length) != 1 or $m[0].taskId != $c.taskId then "ASSIGNMENT_DIGEST_MISMATCH"
         elif $c.run != 1 then "TASK_UNEXPECTED" else empty end)
   else empty end),
  (if $r.policy == "pr-review-v1" and $r.evidence != null then
     ($tasks[] | . as $task | [$direct[] | select(.taskId == $task and .run == 1)] | length
       | if . == 0 then "TASK_MISSING" elif . > 1 then "TASK_DUPLICATED" else empty end),
     ($direct[] | . as $c | select($c.run != 1 or (($tasks | index($c.taskId)) == null)) | "TASK_UNEXPECTED")
   else empty end)
] | sort | unique | . as $codes |
{
  schemaVersion: 1,
  issue: $r.issue,
  stepId: $r.stepId,
  attemptId: $r.attemptId,
  provider: $r.provider,
  evidenceSource: (if $r.provider == "codex" then "app-server" else "hooks" end),
  parentId: $parent,
  policy: $r.policy,
  requested: {parent: {model: $r.requested.parent.model, reasoningEffort: $r.requested.parent.reasoningEffort},
              worker: {model: $worker.model, reasoningEffort: $worker.reasoningEffort}},
  expected: {taskCount: ($tasks | length), taskIds: ($tasks | sort)},
  observed: {startedCount: ([$direct[] | select(.started)] | length),
             completedCount: ([$direct[] | select(.completed)] | length),
             selectedCount: ($direct | length)},
  children: ($children | sort_by(.taskId, .run, .childId) | map({
    childId, parentId, taskId, run, assignmentDigest, started, completed, outcome,
    effective: {model: .effective.model, reasoningEffort: .effective.reasoningEffort},
    nested, disposition: "selected"})),
  evidenceLevel: (if ($codes | length) > 0 then "UNVERIFIED"
    elif all($direct[]; .effective.model != null and .effective.reasoningEffort != null) then "VERIFIED"
    else "OBSERVED" end),
  mismatchCodes: $codes
}
