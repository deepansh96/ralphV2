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
# Only failed or stopped outcomes prove a run ended; incomplete may still run.
def ended: .outcome == "failed" or .outcome == "stopped";
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
# qa-v1 replacement chains: direct children of this parent session that prove
# one plan assignment (digest and task ID), grouped by assignment. A lower run
# that neither completed nor reported completion is superseded by the highest.
(if $plan == null then [] else
   [$direct[] | select(.parentId == $parent) | . as $c
     | select(any($plan.assignments[]; .assignmentDigest == $c.assignmentDigest and .taskId == $c.taskId))]
   | group_by(.assignmentDigest) end) as $chains |
[$chains[] | (map(.run) | max) as $top
  | .[] | select(.run < $top and (.completed | not) and .outcome != "completed")] as $superseded |
[$direct[] | . as $c | select(any($superseded[]; . == $c) | not)] as $selected |
$r.requested.worker as $worker |
[
  (if $r.providerFailed then "PROVIDER_FAILED" else empty end),
  (if $r.evidence == null then "EVIDENCE_UNAVAILABLE" else empty end),
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
  ($selected[] |
    if .outcome == "failed" then "CHILD_FAILED"
    elif .outcome == "stopped" then "CHILD_STOPPED"
    elif .completed then empty
    elif .started then "CHILD_INCOMPLETE"
    else "CHILD_MISSING" end),
  ($direct[] | select(.effective.model != null and (model_ok($worker.model; .effective.model) | not)) | "MODEL_MISMATCH"),
  ($direct[] | . as $c | select(any(($r.evidence.modelHistory[$c.childId] // [])[]; model_ok($worker.model; .) | not)) | "MODEL_MISMATCH"),
  ($direct[] | select(.effective.reasoningEffort != null and .effective.reasoningEffort != $worker.reasoningEffort) | "EFFORT_MISMATCH"),
  # Task identity is judged only under a supported policy with bound evidence.
  # qa-v1: every direct child proves one immutable plan assignment (digest and
  # task ID). Each assignment's chain has runs exactly 1..N, each once; only
  # runs that ended failed or stopped may be replaced (a completed lower run is
  # a duplicate execution, an incomplete one a possibly concurrent duplicate),
  # and only when the lower run's endedAt is at or before every later run's
  # startedAt. Missing marks cannot prove sequence, so they fail closed.
  # Nesting, parentage, and settings are still judged on every run, so
  # supersession hides none of them.
  (if $plan != null and $r.evidence != null then
     ($plan.assignments[] | . as $a
       | [$chains[] | select(.[0].assignmentDigest == $a.assignmentDigest)[]] as $runs
       | [$runs[].run] as $numbers
       | if $runs == [] then "TASK_MISSING"
         else
           (if ($numbers | length) != ($numbers | unique | length)
               or any($runs[]; .run < ($numbers | max) and (.completed or (ended | not)))
               or any($runs[]; . as $lower | .run < ($numbers | max)
                    and ($lower.endedAt == null
                      or any($runs[]; .run > $lower.run and (.startedAt == null or .startedAt < $lower.endedAt))))
            then "TASK_DUPLICATED" else empty end),
           (if ($numbers | unique) != [range(1; ($numbers | max) + 1)] then "TASK_UNEXPECTED" else empty end)
         end),
     ($direct[] | . as $c | [$plan.assignments[] | select(.assignmentDigest == $c.assignmentDigest)] as $m
       | if ($m | length) != 1 or $m[0].taskId != $c.taskId then "ASSIGNMENT_DIGEST_MISMATCH" else empty end)
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
  # Counts describe the selected logical assignments, not superseded runs.
  observed: {startedCount: ([$selected[] | select(.started)] | length),
             completedCount: ([$selected[] | select(.completed)] | length),
             selectedCount: ($selected | length)},
  children: ($children | sort_by(.taskId, .run, .childId) | map(. as $c | {
    childId, parentId, taskId, run, assignmentDigest, started, completed, outcome, startedAt, endedAt,
    effective: {model: .effective.model, reasoningEffort: .effective.reasoningEffort},
    nested, disposition: (if any($superseded[]; . == $c) then "superseded" else "selected" end)})),
  evidenceLevel: (if ($codes | length) > 0 then "UNVERIFIED"
    elif all($selected[]; .effective.model != null and .effective.reasoningEffort != null) then "VERIFIED"
    else "OBSERVED" end),
  mismatchCodes: $codes
}
