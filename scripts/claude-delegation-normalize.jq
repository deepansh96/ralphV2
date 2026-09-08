def require($ok): if $ok then . else error("unbound or ambiguous evidence") end;
. as $events |
require(all(.[]; if .event == "PreToolUse" or .event == "PostToolUse" or .event == "PostToolUseFailure" then (.tool_use_id | type == "string" and length > 0) else true end)) |
[.[] | select(.event == "PreToolUse")] as $pres |
require(all($pres[]; .subagent_type == "ralph-worker")) |
require(all($events[]; if .event == "SubagentStart" or .event == "SubagentStop" then .agent_type == "ralph-worker" else true end)) |
[.[] | select(.event == "PostToolUse")] as $posts |
require(($pres|map(.tool_use_id)|length) == ($pres|map(.tool_use_id)|unique|length)) |
require(all($events[]; . as $e |
  if .event == "PostToolUse" or .event == "PostToolUseFailure" then any($pres[]; .tool_use_id == $e.tool_use_id)
  elif .event == "SubagentStart" or .event == "SubagentStop" then any($posts[]; .agentId == $e.agent_id)
  else .event == "PreToolUse" end)) |
require(($posts|map(.agentId)|length) == ($posts|map(.agentId)|unique|length)) |
$pres | map(. as $pre |
  [$posts[] | select(.tool_use_id == $pre.tool_use_id)] as $returns |
  require($returns|length == 1) |
  $returns[0] as $post |
  [$events[] | select(.event == "SubagentStart" and .agent_id == $post.agentId)] as $starts |
  [$events[] | select(.event == "SubagentStop" and .agent_id == $post.agentId)] as $stops |
  require(($starts|length) <= 1 and ($stops|length) <= 1) |
  (any($events[]; .event == "PostToolUseFailure" and .tool_use_id == $pre.tool_use_id)
    or $post.status == "failed" or $stops[0].status == "failed") as $failed |
  ($post.status == "stopped" or $stops[0].status == "stopped") as $stopped |
  ($starts|length == 1) as $started |
  ($started and ($stops|length == 1) and $post.status == "completed"
    and ($stops[0].status == null or $stops[0].status == "completed")
    and ($failed|not) and ($stopped|not)) as $completed |
  {childId:$post.agentId,parentId:($pre.agent_id // $parent),taskId:$pre.taskId,run:$pre.run,
   assignmentDigest:$pre.assignmentDigest,started:$started,completed:$completed,
   outcome:(if $failed then "failed" elif $stopped then "stopped" elif $completed then "completed" else "incomplete" end),
   effective:{model:$post.resolvedModel,reasoningEffort:$stops[0].effort.level},
   nested:($pre.agent_id != null)})
