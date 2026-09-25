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
  ralph_rel="${ralph_dir#"$repo_root"}"
  ralph_rel="${ralph_rel#/}"
  ralph_rel="${ralph_rel:+$ralph_rel/}"

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
  (umask 077 && mkdir -p "$session_dir/logs") && chmod 700 "$session_dir/logs"
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
}
