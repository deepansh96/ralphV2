def token: if type == "string" and test("^[a-zA-Z0-9_-]{1,200}$") then . else null end;
def marker($name; $pattern):
  [split("\n")[] | select(startswith($name + ":")) | ltrimstr($name + ":") | sub("^ +";"") | select(test($pattern))]
  | if length == 1 then .[0] else null end;
def status: if IN("completed","failed","stopped","incomplete","async_launched") then . elif . == null then null else "incomplete" end;
if .tool_name == "Workflow" and (.hook_event_name | IN("PreToolUse","PostToolUse","PostToolUseFailure")) then
{event:"UnsupportedWorkflow"}
elif .hook_event_name == "PreToolUse" then
select(.tool_name == "Agent" or .tool_name == "Workflow") |
select(.hook_event_name == "PreToolUse") |
if has("agent_id") and (.agent_id|token) == null
then error("invalid invoking agent") else . end |
if (.tool_input | has("model")) and (.tool_input.model|token) == null
then error("invalid explicit model") else . end |
(.tool_input.prompt // "") as $prompt |
{event:.hook_event_name,tool_use_id:(.tool_use_id|token),agent_id:(.agent_id|token),
 subagent_type:(.tool_input.subagent_type|token),model:(.tool_input.model|token),
 taskId:($prompt|marker("RALPH-TASK";"^[a-z][a-z0-9_]{0,100}$")),
 assignmentDigest:($prompt|marker("RALPH-ASSIGNMENT";"^sha256:[0-9a-f]{64}$")),
 run:($prompt|marker("RALPH-RUN";"^[1-9][0-9]{0,8}$")|if . then tonumber else null end)}

elif .hook_event_name == "PostToolUse" then
select(.tool_name == "Agent" or .tool_name == "Workflow") |
{event:.hook_event_name,tool_use_id:(.tool_use_id|token),agentId:(.tool_response.agentId|token),
 status:(.tool_response.status|status),resolvedModel:(.tool_response.resolvedModel|token),
 modelsUsed:((.tool_response.modelsUsed // []) | if type == "array" and all(.[]; token != null) then unique else error("invalid model history") end)}
elif .hook_event_name == "PostToolUseFailure" then
select(.tool_name == "Agent" or .tool_name == "Workflow") |
{event:.hook_event_name,tool_use_id:(.tool_use_id|token),status:"failed"}
elif .hook_event_name == "SubagentStart" then
{event:.hook_event_name,agent_id:(.agent_id|token),agent_type:(.agent_type|token)}
elif .hook_event_name == "SubagentStop" then
{event:.hook_event_name,agent_id:(.agent_id|token),agent_type:(.agent_type|token),
 status:(.status|status),effort:{level:(.effort.level|if IN("low","medium","high","xhigh","max") then . else null end)}}
else empty end
