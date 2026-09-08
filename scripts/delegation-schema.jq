def exact($fields): type == "object" and (keys == ($fields | sort));
def text: type == "string" and length > 0;
def integer: type == "number" and floor == . and . >= 0;
def positive: integer and . > 0;
def nullable_text: . == null or text;
def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
def policy: . == "pr-review-v1" or . == "qa-v1";
def metadata: exact(["schemaVersion","policy"]) and .schemaVersion == 1 and (.policy | policy);
def settings: exact(["model","reasoningEffort"]) and (.model | nullable_text) and (.reasoningEffort | nullable_text);
def child:
  exact(["childId","parentId","taskId","run","assignmentDigest","started","completed","outcome","effective","nested"])
  and ([.childId,.parentId,.taskId] | all(.[]; text))
  and (.run | positive) and (.assignmentDigest | . == null or digest)
  and ([.started,.completed,.nested] | all(.[]; type == "boolean"))
  and (.outcome | IN("completed","failed","stopped","incomplete")) and (.effective | settings);
def codes: ["ASSIGNMENT_DIGEST_MISMATCH","ASSIGNMENT_DUPLICATED","ASSIGNMENT_MISSING","ATTEMPT_MISMATCH","ATTEMPT_MISSING","CHECKLIST_CHANGED","CHECKLIST_INVALID","CHECKLIST_UNAVAILABLE","CHILD_FAILED","CHILD_INCOMPLETE","CHILD_MISSING","CHILD_STOPPED","EFFORT_MISMATCH","EVIDENCE_UNAVAILABLE","MANIFEST_WRITE_FAILED","MODEL_MISMATCH","NESTED_WORKER","PARENT_MISMATCH","PLAN_INVALID","PLAN_MISSING","POLICY_UNSUPPORTED","PROVIDER_FAILED","TASK_DUPLICATED","TASK_MISSING","TASK_UNEXPECTED"];
def code_array: type == "array" and all(.[]; . as $code | codes | index($code) != null);
def sorted_strings: type == "array" and all(.[]; text) and . == (sort | unique);
def manifest_child: . as $record | del(.disposition) | child
  and ($record.disposition | IN("selected","superseded"));
def manifest:
  exact(["schemaVersion","issue","stepId","attemptId","provider","evidenceSource","parentId","policy","requested","expected","observed","children","evidenceLevel","mismatchCodes"])
  and .schemaVersion == 1 and (.issue | positive)
  and ([.stepId,.attemptId,.parentId] | all(.[]; text)) and (.policy | policy)
  and ((.provider == "codex" and .evidenceSource == "app-server") or (.provider == "claude" and .evidenceSource == "hooks"))
  and (.requested | exact(["parent","worker"]) and (.parent | settings) and (.worker | settings)
    and ([.parent.model,.parent.reasoningEffort,.worker.model,.worker.reasoningEffort] | all(.[]; text)))
  and (.expected | exact(["taskCount","taskIds"]) and (.taskCount | integer) and (.taskIds | sorted_strings) and .taskCount == (.taskIds | length))
  and (.observed | exact(["startedCount","completedCount","selectedCount"]) and all(.[]; integer))
  and (.children | type == "array" and all(.[]; manifest_child)
    and . == sort_by(.taskId,.run,.childId))
  and (.evidenceLevel | IN("OBSERVED","VERIFIED","UNVERIFIED"))
  and (.mismatchCodes | code_array and . == (sort | unique));
def qa_id: type == "string" and test("^QA-[0-9]{2,}$");
def plan:
  exact(["schemaVersion","stepId","attemptId","checklist","assignments"])
  and .schemaVersion == 1 and .stepId == "runthrough-qa-checklist" and (.attemptId | text)
  and (.checklist | exact(["commentId","updatedAt","digest","items"])
    and (.commentId | type == "string" and test("^[0-9]+$"))
    and (.updatedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.digest | digest)
    and (.items | type == "array" and length > 0
      and all(.[]; exact(["id","text"]) and (.id | qa_id) and (.text | text and (contains("\r") | not) and . == gsub("^\\s+|\\s+$";"")))
      and ([.[].id] | . == (sort | unique))))
  and (.assignments | type == "array" and length > 0
    and all(.[]; exact(["taskId","checklistItemIds","assignmentDigest"])
      and (.taskId | text) and (.assignmentDigest | digest)
      and (.checklistItemIds | sorted_strings and length > 0 and all(.[]; qa_id)))
    and ([.[].taskId] | . == (sort | unique)));
def attempt: exact(["id","startedAt"]) and (.id | text) and (.startedAt | integer);
# Validate only the new fields; legacy State has an intentionally open schema.
def state_contract:
  type == "object" and (.steps | type == "array")
  and all(.steps[];
    if has("delegation") then (.delegation | metadata)
      and (if has("delegationAttempt") then (.delegationAttempt | attempt) else true end)
    else (has("delegationAttempt") | not) end);
if length != 1 then false else .[0] |
if $schema == "metadata" then metadata
elif $schema == "child" then child
elif $schema == "children" then type == "array" and all(.[]; child)
elif $schema == "codes" then code_array
elif $schema == "manifest" then manifest
elif $schema == "plan" then plan
elif $schema == "attempt" then attempt
elif $schema == "state" then state_contract
else false end end
