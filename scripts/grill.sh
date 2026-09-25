#!/usr/bin/env bash

# Grill coordinator: the `ralph.sh grill` command family. It is the only
# component that writes the Grilling Session Record, runs Git writes, or calls
# gh writes. Agents are reached only through the session adapters.

GRILL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ralph-v2/scripts/grill-record.sh
source "$GRILL_SCRIPT_DIR/grill-record.sh"
# shellcheck source=ralph-v2/scripts/grill-adapters.sh
source "$GRILL_SCRIPT_DIR/grill-adapters.sh"

grill_usage() {
  cat >&2 <<'USAGE'
Usage:
  ralph.sh grill start (--issue N | --requirement-file PATH)
                       --grilling-agent codex|claude --answering-agent codex|claude
                       [--grilling-model M] [--grilling-effort E]
                       [--answering-model M] [--answering-effort E]
  ralph.sh grill resume --id SESSION_ID
  ralph.sh grill status --id SESSION_ID
  ralph.sh grill logs --id SESSION_ID
  ralph.sh grill cleanup --id SESSION_ID
USAGE
}

grill_die() {
  echo "Error: $*" >&2
  return 1
}

grill_main() {
  local subcommand="${1:-}"

  case "$subcommand" in
    start)
      shift
      grill_start "$@"
      ;;
    resume)
      shift
      grill_resume "$@"
      ;;
    status|logs|cleanup)
      shift
      "grill_$subcommand" "$@"
      ;;
    -h|--help|"")
      grill_usage
      [[ -n "$subcommand" ]]
      ;;
    *)
      grill_usage
      grill_die "unknown grill subcommand: $subcommand"
      ;;
  esac
}

grill_slugify() {
  tr '[:upper:]' '[:lower:]' <<<"$1" \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-50 \
    | sed -E 's/-+$//'
}

grill_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Prints the frozen agent config for a role: flags win, then agentDefaults.
grill_resolve_agent_config() {
  local role="$1"
  local provider="$2"
  local model="$3"
  local effort="$4"
  local config_file="$SCRIPT_DIR/ralph.config.json"

  ralph_config_validate "$config_file" || return 1
  [[ -n "$model" ]] || model="$(jq -r --arg p "$provider" '.agentDefaults[$p].model // empty' "$config_file")"
  [[ -n "$effort" ]] || effort="$(jq -r --arg p "$provider" '.agentDefaults[$p].reasoningEffort // empty' "$config_file")"
  [[ -n "$model" && -n "$effort" ]] \
    || grill_die "no model/effort for the $role agent: pass --$role-model/--$role-effort or set agentDefaults.$provider in $config_file" \
    || return 1
  agent_validate_reasoning_effort "$provider" "$effort" || return 1

  jq -n -c --arg provider "$provider" --arg model "$model" --arg effort "$effort" \
    '{provider: $provider, model: $model, reasoningEffort: $effort, nativeSessionId: null}'
}

# Prints the Ralph directory relative to the target repository, with a
# trailing slash (empty when Ralph is the repository root).
grill_ralph_rel() {
  local repo_root="$1"
  local ralph_dir ralph_rel

  ralph_dir="$(cd "$SCRIPT_DIR" && pwd -P)"
  ralph_rel="${ralph_dir#"$repo_root"}"
  ralph_rel="${ralph_rel#/}"
  printf '%s\n' "${ralph_rel:+$ralph_rel/}"
}

grill_default_branch() {
  local repo_root="$1"
  local remote="$2"
  local ref

  if ref="$(git -C "$repo_root" symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null)"; then
    printf '%s\n' "${ref#"$remote"/}"
    return 0
  fi
  git -C "$repo_root" config init.defaultBranch 2>/dev/null || printf 'main\n'
}

# Prints the prompt for a role's native session start.
grill_render_start_prompt() {
  local role="$1"
  local exchange_id="$2"
  local repo_root="$3"
  local requirement_file="$4"
  local prompts_dir="$SCRIPT_DIR/prompts/grill"
  local role_prompt fragment

  role_prompt="$(<"$prompts_dir/$role-agent.md")"
  fragment="$(<"$prompts_dir/session-start.md")"
  role_prompt="$role_prompt"$'\n\n'"$fragment"
  role_prompt="${role_prompt//\{\{SKILLS_DIR\}\}/$SCRIPT_DIR/skills}"
  role_prompt="${role_prompt//\{\{REPO_ROOT\}\}/$repo_root}"
  role_prompt="${role_prompt//\{\{EXCHANGE_ID\}\}/$exchange_id}"
  role_prompt="${role_prompt//\{\{REQUIREMENT\}\}/$(<"$requirement_file")}"
  printf '%s\n' "$role_prompt"
}

grill_fail_record() {
  local record_file="$1"
  local reason="$2"

  grill_record_update "$record_file" '.status = "failed" | .failureReason = $reason' --arg reason "$reason" || true
  grill_die "$reason"
}

# Starts one role's native session as a recorded exchange and stores its ID.
grill_start_role_session() {
  local record_file="$1"
  local role="$2"
  local exchange_id="$3"
  local native_id="$4"
  local session_dir config prompt log_rel native

  session_dir="$(dirname "$record_file")"
  log_rel="logs/$exchange_id-$role.jsonl"
  config="$(jq -c --arg role "$role" --arg id "$native_id" \
    '.agents[$role] + {repoRoot: .repo.root, nativeSessionId: (if $id == "" then null else $id end)}' "$record_file")"
  prompt="$(grill_render_start_prompt "$role" "$exchange_id" "$(jq -r '.repo.root' "$record_file")" "$session_dir/requirement.md")"

  grill_record_update "$record_file" \
    '.exchanges += [{id: $id, kind: "session_start", role: $role, status: "intent", reemitRequested: false, logPath: $log}]' \
    --arg id "$exchange_id" --arg role "$role" --arg log "$log_rel" || return 1

  # Raw provider logs are owner-only; the adapter truncates this file.
  grill_record_write_file "$session_dir/$log_rel" < /dev/null || return 1
  if ! native="$(adapter_start "$role" "$config" "$prompt" "$session_dir/$log_rel")"; then
    grill_fail_record "$record_file" "the $role native session did not start; see $session_dir/$log_rel"
    return 1
  fi

  grill_record_update "$record_file" \
    '.agents[$role].nativeSessionId = $native
     | .exchanges |= map(if .id == $id then .status = "completed" else . end)' \
    --arg role "$role" --arg native "$native" --arg id "$exchange_id"
}

grill_start() {
  local issue="" requirement_file=""
  local grilling_agent="" answering_agent=""
  local grilling_model="" grilling_effort="" answering_model="" answering_effort=""
  local grilling_config answering_config provider role
  local repo_root ralph_dir ralph_rel dirty remote="origin"
  local start_branch start_head default_branch branch slug title issue_json
  local sessions_dir session_id session_dir record_file input_json now
  local grilling_native answering_native

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --issue|--requirement-file|--grilling-agent|--answering-agent|--grilling-model|--grilling-effort|--answering-model|--answering-effort)
        [[ $# -ge 2 && -n "$2" ]] || { grill_usage; grill_die "$1 requires a value"; return 1; }
        case "$1" in
          --issue) issue="$2" ;;
          --requirement-file) requirement_file="$2" ;;
          --grilling-agent) grilling_agent="$2" ;;
          --answering-agent) answering_agent="$2" ;;
          --grilling-model) grilling_model="$2" ;;
          --grilling-effort) grilling_effort="$2" ;;
          --answering-model) answering_model="$2" ;;
          --answering-effort) answering_effort="$2" ;;
        esac
        shift 2
        ;;
      -h|--help)
        grill_usage
        return 0
        ;;
      *)
        grill_usage
        grill_die "unknown argument: $1"
        return 1
        ;;
    esac
  done

  # Input validation: nothing is created before these checks pass.
  if [[ -n "$issue" && -n "$requirement_file" ]] || [[ -z "$issue" && -z "$requirement_file" ]]; then
    grill_die "pass exactly one of --issue or --requirement-file"
    return 1
  fi
  if [[ -n "$issue" ]] && ! [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
    grill_die "--issue must be a positive integer"
    return 1
  fi
  if [[ -n "$requirement_file" && ! -f "$requirement_file" ]]; then
    grill_die "requirement file not found: $requirement_file"
    return 1
  fi
  [[ -n "$grilling_agent" ]] || { grill_die "--grilling-agent is required (codex|claude)"; return 1; }
  [[ -n "$answering_agent" ]] || { grill_die "--answering-agent is required (codex|claude)"; return 1; }
  for role in grilling answering; do
    provider="$grilling_agent"
    [[ "$role" == "grilling" ]] || provider="$answering_agent"
    case "$provider" in
      codex|claude) ;;
      *) grill_die "unsupported --$role-agent '$provider' (expected codex or claude)"; return 1 ;;
    esac
  done
  grilling_config="$(grill_resolve_agent_config grilling "$grilling_agent" "$grilling_model" "$grilling_effort")" || return 1
  answering_config="$(grill_resolve_agent_config answering "$answering_agent" "$answering_model" "$answering_effort")" || return 1

  # Refuse before any native session exists if a provider cannot express the
  # required access policy.
  adapter_capabilities "$grilling_agent" || return 1
  if [[ "$answering_agent" != "$grilling_agent" ]]; then
    adapter_capabilities "$answering_agent" || return 1
  fi

  # Target repository: the Git toplevel above the Ralph directory.
  ralph_dir="$(cd "$SCRIPT_DIR" && pwd -P)"
  if ! repo_root="$(git -C "$ralph_dir/.." rev-parse --show-toplevel 2>/dev/null)"; then
    grill_die "no Git repository found above the Ralph directory ($ralph_dir)"
    return 1
  fi
  repo_root="$(cd "$repo_root" && pwd -P)"
  ralph_rel="$(grill_ralph_rel "$repo_root")"

  # Branch safety.
  dirty="$(git -C "$repo_root" status --porcelain --untracked-files=all -- . \
    ":(exclude)${ralph_rel}grilling-sessions" ":(exclude)${ralph_rel}archive")"
  if [[ -n "$dirty" ]]; then
    grill_die "working tree is dirty; commit or stash these changes before grilling:"$'\n'"$dirty"
    return 1
  fi
  start_branch="$(git -C "$repo_root" branch --show-current)"
  [[ -n "$start_branch" ]] || { grill_die "HEAD is detached; check out a branch before grilling"; return 1; }
  start_head="$(git -C "$repo_root" rev-parse HEAD)"
  default_branch="$(grill_default_branch "$repo_root" "$remote")"

  # Requirement snapshot source and slug.
  if [[ -n "$issue" ]]; then
    if ! issue_json="$(cd "$repo_root" && gh issue view "$issue" --json title,body)"; then
      grill_die "could not read issue #$issue with gh"
      return 1
    fi
    title="$(jq -r '.title // ""' <<<"$issue_json")"
    slug="$(grill_slugify "$title")"
    input_json="$(jq -n -c --argjson issue "$issue" '{kind: "issue", issue: $issue}')"
  else
    title="$(sed -n -E 's/^#[[:space:]]+//p' "$requirement_file" | head -n 1)"
    [[ -n "$title" ]] || title="$(basename "${requirement_file%.*}")"
    slug="$(grill_slugify "$title")"
    input_json="$(jq -n -c --arg path "$requirement_file" '{kind: "requirement_file", sourcePath: $path}')"
  fi

  branch="$start_branch"
  if [[ "$start_branch" == "$default_branch" ]]; then
    [[ -n "$slug" ]] || { grill_die "could not derive a planning branch slug from '$title'"; return 1; }
    if [[ -n "$issue" ]]; then
      branch="grill/issue-$issue-$slug"
    else
      branch="grill/$slug"
    fi
    if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch" \
      || git -C "$repo_root" show-ref --verify --quiet "refs/remotes/$remote/$branch"; then
      grill_die "planning branch '$branch' already exists; delete it or start from that branch"
      return 1
    fi
    git -C "$repo_root" checkout -q -b "$branch" || { grill_die "could not create planning branch '$branch'"; return 1; }
  fi

  # Grilling Session Record.
  sessions_dir="$(grill_record_sessions_dir "$ralph_dir")" || return 1
  session_id="$(grill_record_create_dir "$sessions_dir")" || { grill_die "could not create a session directory in $sessions_dir"; return 1; }
  session_dir="$sessions_dir/$session_id"
  record_file="$session_dir/session.json"
  (umask 077 && mkdir -p "$session_dir/logs" "$session_dir/messages") \
    && chmod 700 "$session_dir/logs" "$session_dir/messages"
  if [[ -n "$issue" ]]; then
    printf '# %s\n\n%s\n' "$title" "$(jq -r '.body // ""' <<<"$issue_json")" \
      | grill_record_write_file "$session_dir/requirement.md"
  else
    grill_record_write_file "$session_dir/requirement.md" < "$requirement_file"
  fi

  now="$(grill_record_now)"
  grill_record_write "$record_file" "$(jq -n \
    --arg id "$session_id" \
    --argjson input "$input_json" \
    --arg sha "$(grill_sha256 "$session_dir/requirement.md")" \
    --arg root "$repo_root" --arg remote "$remote" \
    --arg startBranch "$start_branch" --arg branch "$branch" \
    --arg startHead "$start_head" --arg defaultBranch "$default_branch" \
    --argjson grilling "$grilling_config" --argjson answering "$answering_config" \
    --arg now "$now" '{
      id: $id,
      status: "starting",
      blockReason: null,
      input: ($input + {requirementSha256: $sha, requirementPath: "requirement.md"}),
      repo: {root: $root, remote: $remote, startBranch: $startBranch, branch: $branch,
             startHead: $startHead, defaultBranch: $defaultBranch},
      agents: {grilling: $grilling, answering: $answering},
      round: 0,
      decisions: {},
      exchanges: [],
      apply: {commit: null, push: null, issue: null},
      lock: null,
      createdAt: $now,
      updatedAt: $now
    }')" || return 1

  # Native sessions: the Grilling Agent first, then the Answering Agent.
  grilling_native="$(adapter_new_native_id "$grilling_agent")" || return 1
  grill_start_role_session "$record_file" grilling ex-0001 "$grilling_native" || return 1
  grilling_native="$(jq -r '.agents.grilling.nativeSessionId' "$record_file")"

  answering_native="$(adapter_new_native_id "$answering_agent")" || return 1
  if [[ -n "$answering_native" && "$answering_native" == "$grilling_native" ]]; then
    grill_fail_record "$record_file" "native session IDs must differ; both roles got $grilling_native"
    return 1
  fi
  grill_start_role_session "$record_file" answering ex-0002 "$answering_native" || return 1
  answering_native="$(jq -r '.agents.answering.nativeSessionId' "$record_file")"
  if [[ "$answering_native" == "$grilling_native" ]]; then
    grill_fail_record "$record_file" "native session IDs must differ; both roles got $grilling_native"
    return 1
  fi

  grill_record_update "$record_file" '.status = "grilling"' || return 1
  printf '%s\n' "$session_id"
  grill_run "$record_file"
}

grill_resume() {
  local session_id="" sessions_dir record_file status in_flight

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)
        [[ $# -ge 2 && -n "$2" ]] || { grill_usage; grill_die "--id requires a value"; return 1; }
        session_id="$2"
        shift 2
        ;;
      --grilling-agent|--answering-agent|--grilling-model|--grilling-effort|--answering-model|--answering-effort)
        grill_die "resume does not accept $1: the agent configuration is frozen at start"
        return 1
        ;;
      -h|--help)
        grill_usage
        return 0
        ;;
      *)
        grill_usage
        grill_die "unknown argument: $1"
        return 1
        ;;
    esac
  done

  [[ -n "$session_id" ]] || { grill_usage; grill_die "resume requires --id <session-id>"; return 1; }
  [[ "$session_id" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$ ]] || { grill_die "invalid session ID: $session_id"; return 1; }
  sessions_dir="$(cd "$SCRIPT_DIR" && pwd -P)/grilling-sessions"
  record_file="$sessions_dir/$session_id/session.json"
  [[ -f "$record_file" ]] || { grill_die "no Grilling Session Record for $session_id in $sessions_dir"; return 1; }

  status="$(jq -r '.status' "$record_file")"
  [[ "$status" == "grilling" ]] \
    || { grill_die "session $session_id is $status; resume continues only grilling sessions"; return 1; }
  in_flight="$(jq -r '[.exchanges[] | select(.status != "completed") | .id] | join(", ")' "$record_file")"
  [[ -z "$in_flight" ]] \
    || { grill_die "session $session_id has an in-flight exchange ($in_flight); it cannot be resumed yet"; return 1; }

  grill_run "$record_file"
}

# Parses `--id SESSION_ID` and prints the session directory, in place under
# grilling-sessions/<id>/ or archived under archive/grilling/<date>-<id>/.
grill_find_session_dir() {
  local session_id="" ralph_dir session_dir

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)
        [[ $# -ge 2 && -n "$2" ]] || { grill_usage; grill_die "--id requires a value"; return 1; }
        session_id="$2"
        shift 2
        ;;
      *)
        grill_usage
        grill_die "unknown argument: $1"
        return 1
        ;;
    esac
  done

  [[ -n "$session_id" ]] || { grill_usage; grill_die "--id <session-id> is required"; return 1; }
  [[ "$session_id" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$ ]] || { grill_die "invalid session ID: $session_id"; return 1; }
  ralph_dir="$(cd "$SCRIPT_DIR" && pwd -P)"
  for session_dir in "$ralph_dir/grilling-sessions/$session_id" \
    "$ralph_dir"/archive/grilling/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-"$session_id"; do
    if [[ -f "$session_dir/session.json" ]]; then
      printf '%s\n' "$session_dir"
      return 0
    fi
  done
  grill_die "no Grilling Session Record for $session_id in $ralph_dir/grilling-sessions or $ralph_dir/archive/grilling"
}

# Prints a paste-safe summary: never raw logs or the requirement text.
grill_status() {
  local session_dir record_file session_id status block_reason next role

  session_dir="$(grill_find_session_dir "$@")" || return 1
  record_file="$session_dir/session.json"
  session_id="$(jq -r '.id' "$record_file")"
  status="$(jq -r '.status' "$record_file")"
  block_reason="$(jq -r '.blockReason // "none"' "$record_file")"

  case "$status:$block_reason" in
    starting:*) next="wait for grill start to finish" ;;
    grilling:*) next="run: ralph.sh grill resume --id $session_id" ;;
    blocked:awaiting_confirmation)
      next="edit $session_dir/confirmation.md, then run: ralph.sh grill resume --id $session_id" ;;
    blocked:*)
      next="write your input under ## Answers in the human-input file in $session_dir, then run: ralph.sh grill resume --id $session_id" ;;
    applying:*) next="run: ralph.sh grill resume --id $session_id to finish applying" ;;
    *) next="none; delete it with: ralph.sh grill cleanup --id $session_id" ;;
  esac

  printf 'Session: %s\n' "$session_id"
  printf 'Location: %s\n' "$session_dir"
  printf 'State: %s\n' "$status"
  printf 'Block reason: %s\n' "$block_reason"
  printf 'Round: %s\n' "$(jq -r '.round' "$record_file")"
  for role in grilling answering; do
    printf '%s Agent: %s\n' "$(tr '[:lower:]' '[:upper:]' <<<"${role:0:1}")${role:1}" \
      "$(jq -r --arg role "$role" '.agents[$role] | "\(.provider) (model \(.model), effort \(.reasoningEffort))"' "$record_file")"
  done
  printf 'Next action: %s\n' "$next"
}

# Prints summarized provider activity per exchange through the log parser.
grill_logs() {
  local session_dir record_file id kind role log_path provider

  session_dir="$(grill_find_session_dir "$@")" || return 1
  record_file="$session_dir/session.json"

  while IFS=$'\t' read -r id kind role log_path; do
    provider="$(jq -r --arg role "$role" '.agents[$role].provider' "$record_file")"
    printf '== %s %s (%s Agent, %s)\n' "$id" "$kind" "$role" "$provider"
    parse_log "$session_dir/$log_path" "$provider" 10 | sed 's/^/  /'
  done < <(jq -r '.exchanges[] | [.id, .kind, .role, .logPath] | @tsv' "$record_file")
}

# Deletes a terminal session wherever it lives; refuses active ones.
grill_cleanup() {
  local session_dir session_id status

  session_dir="$(grill_find_session_dir "$@")" || return 1
  session_id="$(jq -r '.id' "$session_dir/session.json")"
  status="$(jq -r '.status' "$session_dir/session.json")"
  case "$status" in
    completed|rejected|context_lost|failed) ;;
    *)
      grill_die "session $session_id is $status; cleanup deletes only completed, rejected, context_lost or failed sessions"
      return 1
      ;;
  esac

  rm -rf "${session_dir:?}"
  printf 'Deleted session %s (%s)\n' "$session_id" "$status"
}

# jq definitions shared by the message validators. The coordinator validates
# every message itself and never trusts the provider's schema validation.
GRILL_JQ_DEFS='
def text: type == "string" and length > 0;
def evidence: type == "array" and length > 0 and all(.[]; text);
def envelope: type == "object" and .exchangeId == $exchangeId;
'

# Needs $round and $decided (settled question IDs).
GRILL_JQ_FRONTIER='
envelope
and .round == $round
and (.questions | type == "array")
and ((.reopens // []) | type == "array")
and all(.questions[];
  type == "object"
  and (.id | text and test("^[a-z0-9]+(-[a-z0-9]+)*$"))
  and (.title | text) and (.body | text)
  and (.choices | type == "array" and all(.[]; type == "object" and (.id | text) and (.label | text)))
  and (.recommendation | type == "object" and (.rationale | text) and ((.choiceId | text) or (.text | text))))
and ([.questions[].id] | length == (unique | length))
and all(.questions[].id; IN($decided[]) | not)
and all((.reopens // [])[];
  type == "object" and (.questionId | text and IN($decided[]))
  and (.contradiction | text) and (.evidence | evidence))
and ([(.reopens // [])[].questionId] | length == (unique | length))
'

# Needs $expected (question IDs in the round, reopens included).
GRILL_JQ_ANSWERS='
envelope
and (has("needsHuman") | not)
and (.answers | type == "array")
and all(.answers[];
  type == "object" and (.questionId | text)
  and ((.choiceId | text) or (.text | text))
  and (.rationale | text) and (.evidence | evidence))
and ([.answers[].questionId] | sort) == ($expected | sort)
'

GRILL_JQ_SUMMARY='
envelope and (.decisionSummary | text) and (.issueTitle | text) and (.issueBody | text)
'

GRILL_JQ_SUMMARY_REVIEW='
envelope
and (.faithful | type == "boolean")
and (.discrepancies | type == "array"
  and all(.[]; type == "object" and (.problem | text) and (.fix | text)))
'

grill_next_exchange_id() {
  printf 'ex-%04d\n' "$(( $(jq '.exchanges | length' "$1") + 1 ))"
}

# Prints a per-exchange prompt fragment with {{KEY}} placeholders replaced by
# the given KEY VALUE pairs.
grill_render_fragment() {
  local name="$1"
  shift
  local text

  text="$(<"$SCRIPT_DIR/prompts/grill/$name.md")"
  while [[ $# -ge 2 ]]; do
    text="${text//"{{$1}}"/"$2"}"
    shift 2
  done
  printf '%s\n' "$text"
}

# Prints the validated message of the last completed exchange of a kind, or
# nothing when there is none.
grill_last_message() {
  local record_file="$1"
  local kind="$2"
  local message_rel

  message_rel="$(jq -r --arg kind "$kind" \
    '[.exchanges[] | select(.kind == $kind and .status == "completed")] | last | .messagePath // empty' "$record_file")"
  [[ -z "$message_rel" ]] || cat "$(dirname "$record_file")/$message_rel"
}

# Records, sends, validates and completes one exchange: intent before sending,
# sent while the provider has it, completed once the message validates. The
# validated message is saved to messages/<id>.json and printed. Extra
# arguments are passed to the jq validator.
grill_exchange() {
  local record_file="$1"
  local kind="$2"
  local role="$3"
  local exchange_id="$4"
  local prompt="$5"
  local schema="$6"
  local validator="$7"
  shift 7
  local session_dir log_rel message_rel config native raw message

  session_dir="$(dirname "$record_file")"
  log_rel="logs/$exchange_id-$role.jsonl"
  message_rel="messages/$exchange_id.json"

  grill_record_update "$record_file" \
    '.exchanges += [{id: $id, kind: $kind, role: $role, status: "intent", reemitRequested: false, logPath: $log}]' \
    --arg id "$exchange_id" --arg kind "$kind" --arg role "$role" --arg log "$log_rel" || return 1
  (umask 077 && mkdir -p "$session_dir/logs" "$session_dir/messages") || return 1
  grill_record_write_file "$session_dir/$log_rel" < /dev/null || return 1

  config="$(jq -c --arg role "$role" '.agents[$role] + {repoRoot: .repo.root}' "$record_file")"
  native="$(jq -r --arg role "$role" '.agents[$role].nativeSessionId' "$record_file")"
  grill_record_update "$record_file" '.exchanges |= map(if .id == $id then .status = "sent" else . end)' \
    --arg id "$exchange_id" || return 1

  if ! raw="$(adapter_send "$role" "$config" "$native" "$prompt" "$SCRIPT_DIR/prompts/grill/schemas/$schema.schema.json" \
    "$session_dir/$log_rel")"; then
    grill_fail_record "$record_file" "the $role agent did not answer $exchange_id; see $session_dir/$log_rel"
    return 1
  fi
  if ! message="$(jq -c -s 'if length == 1 then .[0] else error("expected one JSON value") end' <<<"$raw" 2>/dev/null)" \
    || ! jq -e --arg exchangeId "$exchange_id" "$@" "$GRILL_JQ_DEFS $validator" <<<"$message" >/dev/null 2>&1; then
    grill_fail_record "$record_file" "the $role agent sent an invalid $kind message for $exchange_id; see $session_dir/$log_rel"
    return 1
  fi

  jq '.' <<<"$message" | grill_record_write_file "$session_dir/$message_rel" || return 1
  grill_record_update "$record_file" \
    '.exchanges |= map(if .id == $id then .status = "completed" | .messagePath = $message else . end)' \
    --arg id "$exchange_id" --arg message "$message_rel" || return 1
  printf '%s\n' "$message"
}

grill_step_frontier() {
  local record_file="$1"
  local round exchange_id answers prompt

  round=$(( $(jq '.round' "$record_file") + 1 ))
  exchange_id="$(grill_next_exchange_id "$record_file")"
  answers="$(grill_last_message "$record_file" answers)"
  if [[ -n "$answers" ]]; then
    answers="$(jq '.answers' <<<"$answers")"
  else
    answers="None. This is the first round."
  fi
  prompt="$(grill_render_fragment round-frontier EXCHANGE_ID "$exchange_id" ROUND "$round" ANSWERS "$answers")"

  grill_record_update "$record_file" '.round = $round' --argjson round "$round" || return 1
  grill_exchange "$record_file" frontier grilling "$exchange_id" "$prompt" frontier "$GRILL_JQ_FRONTIER" \
    --argjson round "$round" --argjson decided "$(jq -c '.decisions | keys' "$record_file")" >/dev/null
}

# Relays the last Frontier to the Answering Agent, reopens included with their
# contradiction and previous decision, then merges the answers into decisions.
grill_step_answers() {
  local record_file="$1"
  local frontier frontier_id exchange_id questions reopens expected prompt answers

  frontier="$(grill_last_message "$record_file" frontier)"
  frontier_id="$(jq -r '.exchangeId' <<<"$frontier")"
  exchange_id="$(grill_next_exchange_id "$record_file")"
  questions="$(jq '.questions' <<<"$frontier")"
  reopens="$(jq --argjson decisions "$(jq -c '.decisions' "$record_file")" \
    '(.reopens // []) | map(. + {previousDecision: $decisions[.questionId].decision})' <<<"$frontier")"
  expected="$(jq -c '[.questions[].id] + [(.reopens // [])[].questionId]' <<<"$frontier")"
  prompt="$(grill_render_fragment round-answers EXCHANGE_ID "$exchange_id" ROUND "$(jq '.round' "$record_file")" \
    QUESTIONS "$questions" REOPENS "$reopens")"

  answers="$(grill_exchange "$record_file" answers answering "$exchange_id" "$prompt" answers "$GRILL_JQ_ANSWERS" \
    --argjson expected "$expected")" || return 1

  grill_record_update "$record_file" \
    '.decisions += ($answers.answers | map({key: .questionId, value: {
        exchangeId: $answers.exchangeId,
        decision: (.choiceId // .text),
        reopenedBy: (.questionId as $q | if ($reopened | index($q)) then $frontier else null end)}}) | from_entries)' \
    --argjson answers "$answers" --arg frontier "$frontier_id" \
    --argjson reopened "$(jq -c '[(.reopens // [])[].questionId]' <<<"$frontier")"
}

grill_step_summary_draft() {
  local record_file="$1"
  local exchange_id prompt

  exchange_id="$(grill_next_exchange_id "$record_file")"
  prompt="$(grill_render_fragment closing-draft EXCHANGE_ID "$exchange_id" DECISIONS "$(jq '.decisions' "$record_file")")"
  grill_exchange "$record_file" summary_draft grilling "$exchange_id" "$prompt" summary "$GRILL_JQ_SUMMARY" >/dev/null
}

grill_step_summary_review() {
  local record_file="$1"
  local exchange_id prompt

  exchange_id="$(grill_next_exchange_id "$record_file")"
  prompt="$(grill_render_fragment closing-review EXCHANGE_ID "$exchange_id" \
    DRAFT "$(grill_last_message "$record_file" summary_draft)" DECISIONS "$(jq '.decisions' "$record_file")")"
  grill_exchange "$record_file" summary_review answering "$exchange_id" "$prompt" summary-review \
    "$GRILL_JQ_SUMMARY_REVIEW" >/dev/null
}

grill_step_summary_final() {
  local record_file="$1"
  local exchange_id prompt

  exchange_id="$(grill_next_exchange_id "$record_file")"
  prompt="$(grill_render_fragment closing-final EXCHANGE_ID "$exchange_id" \
    REVIEW "$(grill_last_message "$record_file" summary_review)")"
  grill_exchange "$record_file" summary_final grilling "$exchange_id" "$prompt" summary "$GRILL_JQ_SUMMARY" >/dev/null
}

# Writes confirmation.md: the final summary and issue draft, the diff of the
# session's uncommitted changes, flags for out-of-scope paths and HEAD/branch
# drift, and the human's Decision and Answers sections.
grill_write_confirmation() {
  local record_file="$1"
  local session_dir repo_root ralph_rel summary index changed stat diff out_of_scope
  local start_head head branch current_branch path
  local -a flags=() pathspec

  session_dir="$(dirname "$record_file")"
  repo_root="$(jq -r '.repo.root' "$record_file")"
  start_head="$(jq -r '.repo.startHead' "$record_file")"
  branch="$(jq -r '.repo.branch' "$record_file")"
  summary="$(grill_last_message "$record_file" summary_final)"
  ralph_rel="$(grill_ralph_rel "$repo_root")"
  pathspec=(. ":(exclude)${ralph_rel}grilling-sessions" ":(exclude)${ralph_rel}archive")

  # A throwaway index shows untracked files in the diff without touching the
  # real index.
  index="$session_dir/.confirmation-index"
  rm -f "$index"
  if ! GIT_INDEX_FILE="$index" git -C "$repo_root" read-tree HEAD \
    || ! GIT_INDEX_FILE="$index" git -C "$repo_root" add -A -- "${pathspec[@]}"; then
    rm -f "$index"
    grill_die "could not read the working tree diff in $repo_root"
    return 1
  fi
  changed="$(GIT_INDEX_FILE="$index" git -C "$repo_root" diff --cached --no-color --name-only HEAD)"
  stat="$(GIT_INDEX_FILE="$index" git -C "$repo_root" diff --cached --no-color --stat HEAD)"
  diff="$(GIT_INDEX_FILE="$index" git -C "$repo_root" diff --cached --no-color --no-ext-diff HEAD -- CONTEXT.md docs/adr)"
  rm -f "$index"

  out_of_scope="$(grep -v -E '^(CONTEXT\.md|docs/adr/.+)$' <<<"$changed" || true)"
  while IFS= read -r path; do
    [[ -z "$path" ]] || flags+=("- Changed outside CONTEXT.md and docs/adr/: \`$path\`")
  done <<<"$out_of_scope"
  head="$(git -C "$repo_root" rev-parse HEAD)"
  [[ "$head" == "$start_head" ]] || flags+=("- HEAD changed since start: $start_head -> $head")
  current_branch="$(git -C "$repo_root" branch --show-current)"
  [[ "$current_branch" == "$branch" ]] \
    || flags+=("- Branch changed since start: expected \`$branch\`, now \`${current_branch:-detached HEAD}\`")
  [[ ${#flags[@]} -gt 0 ]] || flags=("- No flags.")

  {
    printf '# Confirm Automated Grilling Session %s\n\n' "$(jq -r '.id' "$record_file")"
    printf '## Decision summary\n\n%s\n\n' "$(jq -r '.decisionSummary' <<<"$summary")"
    printf '## Issue draft\n\n### Title\n\n%s\n\n### Body\n\n%s\n\n' \
      "$(jq -r '.issueTitle' <<<"$summary")" "$(jq -r '.issueBody' <<<"$summary")"
    printf '## Flags\n\n'
    printf '%s\n' "${flags[@]}"
    printf '\n## Diff stat\n\n````text\n%s\n````\n\n' "${stat:-No changes.}"
    printf '## Diff (CONTEXT.md and docs/adr/)\n\n````diff\n%s\n````\n\n' "${diff:-No changes.}"
    printf '## Decision\n\n'
    printf 'Write one of `approve`, `reject`, or `correct` on the line below. For `correct`, write the correction under `## Answers`.\n\n'
    printf '## Answers\n\n'
  } | grill_record_write_file "$session_dir/confirmation.md"
}

# The relay loop: each step follows from the last completed exchange, so
# `start` and `resume` share it. Stops at the confirmation gate.
grill_run() {
  local record_file="$1"
  local last_kind frontier

  while true; do
    last_kind="$(jq -r '[.exchanges[] | select(.status == "completed")] | last | .kind' "$record_file")"
    case "$last_kind" in
      session_start|answers)
        grill_step_frontier "$record_file" || return 1
        ;;
      frontier)
        frontier="$(grill_last_message "$record_file" frontier)"
        if jq -e '(.questions | length) == 0 and ((.reopens // []) | length) == 0' <<<"$frontier" >/dev/null; then
          grill_step_summary_draft "$record_file" || return 1
        else
          grill_step_answers "$record_file" || return 1
        fi
        ;;
      summary_draft)
        grill_step_summary_review "$record_file" || return 1
        ;;
      summary_review)
        grill_step_summary_final "$record_file" || return 1
        ;;
      summary_final)
        grill_write_confirmation "$record_file" || return 1
        grill_record_update "$record_file" '.status = "blocked" | .blockReason = "awaiting_confirmation"' || return 1
        echo "Awaiting confirmation: review $(dirname "$record_file")/confirmation.md and write your decision there." >&2
        return 0
        ;;
      *)
        grill_die "cannot continue from exchange kind '$last_kind'"
        return 1
        ;;
    esac
  done
}
