# Input: sanitized App Server facts {parentId, threads:[...]} for one parent.
# $parent binds the facts to the current attempt; $plan is null or a valid QA plan.
# Every rule fails closed: unbound, inconsistent, or unidentifiable threads are
# never downgraded to zero workers or guessed complete.
def require($ok): if $ok then . else error("unbound or ambiguous evidence") end;
def terminal: IN("completed","interrupted","failed");
def task_id: type == "string" and test("^[a-z][a-z0-9_]{0,100}$");
require(.parentId == $parent) |
.threads as $threads |
($threads | map(.id)) as $ids |
require(($ids | length) == ($ids | unique | length)) |
require(all($threads[]; (.id | type == "string") and (.turns | type == "array"))) |
# Direct children must be bound to this parent by both the list filter and the spawn record.
require(all($threads[]; .direct | not) or all($threads[] | select(.direct);
  .parentId == $parent and (.depth == null or .depth == 1) and (.spawnParent == null or .spawnParent == $parent))) |
# Every descendant must chain to the parent through listed threads only.
def chain($id; $seen): if $id == $parent then true
  elif ($seen | index($id)) != null then false
  else ([$threads[] | select(.id == $id)] | if length == 1 then chain(.[0].parentId; $seen + [$id]) else false end) end;
require(all($threads[]; chain(.id; []))) |
$threads | map(. as $t |
  ($t.task) as $task |
  require($task | type == "string") |
  ($task | capture("^qa_r(?<run>[1-9][0-9]{0,8})_(?<hex>[0-9a-f]{64})$")? // null) as $qa |
  (if $qa != null then
     ("sha256:" + $qa.hex) as $digest |
     ([($plan.assignments // [])[] | select(.assignmentDigest == $digest)] | if length == 1 then .[0].taskId else $task end) as $taskId |
     {taskId:$taskId, run:($qa.run | tonumber), assignmentDigest:$digest}
   else
     require($task | task_id) |
     {taskId:$task, run:1, assignmentDigest:null}
   end) as $identity |
  ($t.turns) as $turns |
  ($turns | length > 0) as $started |
  (any($turns[]; .status == "failed" or .failed == true)) as $failed |
  ($started and all($turns[]; .status | terminal) and ($turns | last | .status == "completed") and ($failed | not)) as $completed |
  ($started and ($failed | not) and all($turns[]; .status | terminal) and ($turns | last | .status == "interrupted")) as $stopped |
  {childId:$t.id, parentId:$t.parentId, taskId:$identity.taskId, run:$identity.run,
   assignmentDigest:$identity.assignmentDigest, started:$started, completed:$completed,
   outcome:(if $failed then "failed" elif $completed then "completed" elif $stopped then "stopped" else "incomplete" end),
   effective:{model:($t.model // null), reasoningEffort:($t.reasoningEffort // null)},
   nested:($t.direct | not)})
