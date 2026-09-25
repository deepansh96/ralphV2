#!/usr/bin/env bash

# Session adapters for Automated Grilling Sessions. One adapter per provider,
# behind a provider-neutral contract:
#   adapter_capabilities <provider>
#   adapter_new_native_id <provider>
#   adapter_start <role> <config-json> <prompt> <log>   -> prints native session ID
#   adapter_send <role> <config-json> <native-id> <prompt> <schema-file> <log>
#                                                       -> prints the final message
#   adapter_exchange_received <provider> <native-id> <exchange-id>
#                                                       -> prints yes, no or unknown
# adapter_send retries transient CLI failures (RALPH_RETRY_DELAYS) in the same
# native session, and exits GRILL_ADAPTER_CONTEXT_LOST when the native session
# cannot be found.
# <config-json> carries provider, model, reasoningEffort, repoRoot and, for
# providers whose IDs the coordinator generates, nativeSessionId.
# Access is always granted through provider-native permission and sandbox
# controls, never --dangerously-skip-permissions or danger-full-access.
# Sessions are only ever resumed by explicit native ID, never --continue,
# --last or --fork-session.

GRILL_ADAPTER_CONTEXT_LOST=3

GRILL_CLAUDE_REQUIRED_FLAGS=(
  --session-id
  --resume
  --permission-mode
  --allowedTools
  --disallowedTools
  --settings
  --json-schema
)

# Help text each codex command must show: `<command args>|<flag>...`.
GRILL_CODEX_REQUIRED_HELP=(
  "|--sandbox read-only workspace-write --cd --config --model --ask-for-approval"
  "exec|--json --output-schema resume"
  "exec resume|--json --output-schema"
)

adapter_capabilities() {
  local provider="$1"

  case "$provider" in
    claude) claude_adapter_capabilities ;;
    codex) codex_adapter_capabilities ;;
    *)
      echo "Error: no session adapter is available for provider '$provider'" >&2
      return 1
      ;;
  esac
}

adapter_new_native_id() {
  local provider="$1"

  case "$provider" in
    claude) uuidgen | tr '[:upper:]' '[:lower:]' ;;
    *) printf '\n' ;;
  esac
}

adapter_start() {
  local role="$1"
  local config="$2"
  local provider

  provider="$(jq -r '.provider' <<<"$config")"
  case "$provider" in
    claude) claude_adapter_start "$@" ;;
    codex) codex_adapter_start "$@" ;;
    *)
      echo "Error: no session adapter is available for provider '$provider'" >&2
      return 1
      ;;
  esac
}

adapter_send() {
  local role="$1"
  local config="$2"
  local provider

  provider="$(jq -r '.provider' <<<"$config")"
  case "$provider" in
    claude) claude_adapter_send "$@" ;;
    codex) codex_adapter_send "$@" ;;
    *)
      echo "Error: no session adapter is available for provider '$provider'" >&2
      return 1
      ;;
  esac
}

# Answers whether the native session has seen the exchange's
# `[ralph-exchange:<id>]` marker, so a crashed exchange is re-emitted rather
# than resent.
adapter_exchange_received() {
  local provider="$1"

  case "$provider" in
    claude) claude_adapter_exchange_received "$2" "$3" ;;
    codex) codex_adapter_exchange_received "$2" "$3" ;;
    *) printf 'unknown\n' ;;
  esac
}

claude_adapter_capabilities() {
  local help_text flag
  local -a missing=()

  if ! help_text="$(claude --help 2>&1)"; then
    echo "Error: could not run 'claude --help' to check session adapter capabilities" >&2
    return 1
  fi
  for flag in "${GRILL_CLAUDE_REQUIRED_FLAGS[@]}"; do
    grep -qE -- "${flag}([^A-Za-z-]|$)" <<<"$help_text" || missing+=("$flag")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: the installed claude CLI cannot express the required access policy (missing: ${missing[*]})" >&2
    return 1
  fi
}

# Prints the Claude settings JSON for a role: sandboxed Bash with no escape
# hatch, whole-machine reads, web reads, read-only gh, and no Git/gh writes.
# The Answering Agent additionally has every write denied.
claude_adapter_settings() {
  local role="$1"

  jq -n -c --arg role "$role" '{
    sandbox: {
      enabled: true,
      autoAllowBashIfSandboxed: true,
      allowUnsandboxedCommands: false
    },
    permissions: {
      allow: [
        "Read", "Glob", "Grep", "WebFetch", "WebSearch",
        "Bash(gh issue view:*)", "Bash(gh issue list:*)",
        "Bash(gh pr view:*)", "Bash(gh pr list:*)", "Bash(gh pr diff:*)",
        "Bash(gh repo view:*)", "Bash(gh search:*)"
      ],
      deny: ([
        "Bash(git push:*)", "Bash(git commit:*)", "Bash(git checkout:*)",
        "Bash(git switch:*)", "Bash(git branch:*)", "Bash(git reset:*)",
        "Bash(git merge:*)", "Bash(git rebase:*)", "Bash(git tag:*)",
        "Bash(git stash:*)",
        "Bash(gh issue create:*)", "Bash(gh issue edit:*)",
        "Bash(gh issue close:*)", "Bash(gh issue comment:*)",
        "Bash(gh pr create:*)", "Bash(gh pr edit:*)",
        "Bash(gh pr merge:*)", "Bash(gh pr comment:*)",
        "Bash(gh api:*)"
      ] + (if $role == "answering" then ["Edit(//**)"] else [] end))
    }
  }'
}

claude_adapter_policy_args() {
  local role="$1"

  case "$role" in
    grilling)
      # acceptEdits auto-approves edits only inside the working directory (the
      # target repository); anything else would need approval, which print
      # mode denies.
      printf '%s\n' --permission-mode acceptEdits
      ;;
    answering)
      printf '%s\n' --permission-mode default --disallowedTools Edit Write NotebookEdit
      ;;
    *)
      echo "Error: unknown grilling role '$role'" >&2
      return 1
      ;;
  esac
  printf '%s\n' --settings "$(claude_adapter_settings "$role")"
}

# Runs one claude print-mode call for a role with its access policy, writing
# the raw stream to <log>. Extra arguments select the session and schema.
claude_adapter_run() {
  local role="$1"
  local config="$2"
  local prompt="$3"
  local log_file="$4"
  shift 4
  local model effort repo_root policy status
  local -a claude_args policy_args

  model="$(jq -r '.model // empty' <<<"$config")"
  effort="$(jq -r '.reasoningEffort // empty' <<<"$config")"
  repo_root="$(jq -r '.repoRoot' <<<"$config")"

  policy="$(claude_adapter_policy_args "$role")" || return 1
  mapfile -t policy_args <<<"$policy"

  claude_args=(-p "$prompt" "$@" --output-format stream-json --verbose)
  [[ -z "$model" ]] || claude_args+=(--model "$model")
  [[ -z "$effort" ]] || claude_args+=(--effort "$effort")
  claude_args+=("${policy_args[@]}")

  set +e
  (cd "$repo_root" && claude "${claude_args[@]}") < /dev/null > "$log_file" 2>&1
  status=$?
  set -e

  [[ "$status" -eq 0 ]] \
    && grep '^{' "$log_file" | jq -se 'any(.[]; .type == "result" and .is_error != true)' >/dev/null 2>&1
}

claude_adapter_start() {
  local role="$1"
  local config="$2"
  local prompt="$3"
  local log_file="$4"
  local native_id

  native_id="$(jq -r '.nativeSessionId // empty' <<<"$config")"
  [[ -n "$native_id" ]] || { echo "Error: claude adapter needs a coordinator-generated session ID" >&2; return 1; }

  if ! claude_adapter_run "$role" "$config" "$prompt" "$log_file" --session-id "$native_id"; then
    echo "Error: claude failed to start the $role session; see $log_file" >&2
    return 1
  fi

  printf '%s\n' "$native_id"
}

# Resumes the stored session and prints its final message: the structured
# output when the CLI returns one, otherwise the result text. Transient
# failures are retried in the same session; each failed attempt's log is kept
# as <log>.attempt-N.
claude_adapter_send() {
  local role="$1"
  local config="$2"
  local native_id="$3"
  local prompt="$4"
  local schema_file="$5"
  local log_file="$6"
  local attempt=1 max_attempts
  local -a delays

  [[ -n "$native_id" ]] || { echo "Error: claude adapter needs a native session ID to resume" >&2; return 1; }
  read -r -a delays <<<"$(agent_retry_delays)"
  max_attempts=$(( ${#delays[@]} + 1 ))

  until claude_adapter_run "$role" "$config" "$prompt" "$log_file" \
    --resume "$native_id" --json-schema "$(jq -c . "$schema_file")"; do
    if grep -q 'No conversation found with session ID' "$log_file"; then
      echo "Error: claude could not find the $role session $native_id; see $log_file" >&2
      return "$GRILL_ADAPTER_CONTEXT_LOST"
    fi
    if [[ "$attempt" -ge "$max_attempts" ]] || ! agent_log_has_transient_error "$log_file"; then
      echo "Error: claude failed to resume the $role session $native_id; see $log_file" >&2
      return 1
    fi
    mv "$log_file" "$log_file.attempt-$attempt"
    agent_sleep_before_retry "$attempt"
    attempt=$((attempt + 1))
  done

  grep '^{' "$log_file" | jq -s -r '
    [.[] | select(.type == "result")] | last
    | if (.structured_output | type) == "object" then (.structured_output | tojson) else .result end'
}

# Looks for the exchange marker in Claude's local session store,
# <config-dir>/projects/<encoded-cwd>/<native-id>.jsonl. Anything but a
# readable JSON Lines transcript is an unrecognized layout: unknown.
claude_adapter_exchange_received() {
  local native_id="$1"
  local exchange_id="$2"
  local projects_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
  local transcript

  transcript="$(find "$projects_dir" -mindepth 2 -maxdepth 2 -type f -name "$native_id.jsonl" 2>/dev/null | head -n 1)"
  if [[ -z "$native_id" || -z "$transcript" ]] \
    || ! jq -s -e 'length > 0 and all(.[]; type == "object")' "$transcript" >/dev/null 2>&1; then
    printf 'unknown\n'
  elif grep -qF "[ralph-exchange:$exchange_id]" "$transcript"; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

codex_adapter_capabilities() {
  local entry command help_text flag
  local -a command_args profile_args missing=()

  for entry in "${GRILL_CODEX_REQUIRED_HELP[@]}"; do
    command="${entry%%|*}"
    read -r -a command_args <<<"$command"
    if ! help_text="$(codex "${command_args[@]}" --help 2>&1)"; then
      echo "Error: could not run 'codex${command:+ $command} --help' to check session adapter capabilities" >&2
      return 1
    fi
    for flag in ${entry#*|}; do
      grep -qE -- "${flag}([^A-Za-z-]|$)" <<<"$help_text" || missing+=("${command:+$command }$flag")
    done
  done
  # Network access under read-only needs permission profiles; probe the
  # sandbox with the Answering Agent's profile, without starting a session.
  mapfile -t profile_args < <(codex_adapter_answering_profile_args)
  if ! codex sandbox "${profile_args[@]}" -- true >/dev/null 2>&1; then
    missing+=("network access under read-only (permission profiles)")
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: the installed codex CLI cannot express the required access policy (missing: ${missing[*]})" >&2
    return 1
  fi
}

# Config overrides for a read-only permission profile with network enabled.
codex_adapter_answering_profile_args() {
  printf '%s\n' \
    -c 'default_permissions="ralph-answering"' \
    -c 'permissions.ralph-answering.extends=":read-only"' \
    -c 'permissions.ralph-answering.network.enabled=true'
}

# Prints the global codex options for a role, one per line. They precede
# `exec`, so start and resume carry the same policy: the Answering Agent is
# read-only, the Grilling Agent writes only inside the target repository (no
# tmp write roots); both have network access and never ask for approval.
codex_adapter_policy_args() {
  local role="$1"
  local repo_root="$2"

  printf '%s\n' --ask-for-approval never --cd "$repo_root"
  case "$role" in
    grilling)
      printf '%s\n' --sandbox workspace-write \
        -c 'sandbox_workspace_write.network_access=true' \
        -c 'sandbox_workspace_write.exclude_tmpdir_env_var=true' \
        -c 'sandbox_workspace_write.exclude_slash_tmp=true'
      ;;
    answering)
      printf '%s\n' --sandbox read-only
      codex_adapter_answering_profile_args
      ;;
    *)
      echo "Error: unknown grilling role '$role'" >&2
      return 1
      ;;
  esac
}

# Runs one `codex exec` call for a role with its access policy, the prompt on
# stdin and the JSON event stream in <log>. Extra arguments follow `exec`.
codex_adapter_run() {
  local role="$1"
  local config="$2"
  local prompt="$3"
  local log_file="$4"
  shift 4
  local model effort repo_root policy status
  local -a codex_args policy_args

  model="$(jq -r '.model // empty' <<<"$config")"
  effort="$(jq -r '.reasoningEffort // empty' <<<"$config")"
  repo_root="$(jq -r '.repoRoot' <<<"$config")"

  policy="$(codex_adapter_policy_args "$role" "$repo_root")" || return 1
  mapfile -t policy_args <<<"$policy"

  codex_args=("${policy_args[@]}")
  [[ -z "$model" ]] || codex_args+=(--model "$model")
  [[ -z "$effort" ]] || codex_args+=(-c "model_reasoning_effort=\"$effort\"")
  codex_args+=(exec "$@")

  set +e
  printf '%s' "$prompt" | (cd "$repo_root" && codex "${codex_args[@]}") > "$log_file" 2>&1
  status=$?
  set -e

  [[ "$status" -eq 0 ]] \
    && grep '^{' "$log_file" | jq -se 'any(.[]; .type == "turn.completed") and all(.[]; .type != "turn.failed")' >/dev/null 2>&1
}

codex_adapter_start() {
  local role="$1"
  local config="$2"
  local prompt="$3"
  local log_file="$4"
  local thread_id

  if ! codex_adapter_run "$role" "$config" "$prompt" "$log_file" --json -; then
    echo "Error: codex failed to start the $role session; see $log_file" >&2
    return 1
  fi
  thread_id="$(grep '^{' "$log_file" | jq -r 'select(.type == "thread.started") | .thread_id // empty' 2>/dev/null | head -n 1)"
  [[ -n "$thread_id" ]] || { echo "Error: codex reported no thread ID for the $role session; see $log_file" >&2; return 1; }

  printf '%s\n' "$thread_id"
}

# Resumes the stored thread and prints its final agent message. The output
# schema is a hint; the coordinator validates the message. Transient failures
# are retried in the same thread; each failed attempt's log is kept as
# <log>.attempt-N.
codex_adapter_send() {
  local role="$1"
  local config="$2"
  local native_id="$3"
  local prompt="$4"
  local schema_file="$5"
  local log_file="$6"
  local attempt=1 max_attempts
  local -a delays

  [[ -n "$native_id" ]] || { echo "Error: codex adapter needs a native thread ID to resume" >&2; return 1; }
  read -r -a delays <<<"$(agent_retry_delays)"
  max_attempts=$(( ${#delays[@]} + 1 ))

  until codex_adapter_run "$role" "$config" "$prompt" "$log_file" \
    resume --json --output-schema "$schema_file" "$native_id" -; do
    if grep -qiE 'no rollout found|(thread|session|conversation) not found' "$log_file"; then
      echo "Error: codex could not find the $role thread $native_id; see $log_file" >&2
      return "$GRILL_ADAPTER_CONTEXT_LOST"
    fi
    if [[ "$attempt" -ge "$max_attempts" ]] || ! agent_log_has_transient_error "$log_file"; then
      echo "Error: codex failed to resume the $role thread $native_id; see $log_file" >&2
      return 1
    fi
    mv "$log_file" "$log_file.attempt-$attempt"
    agent_sleep_before_retry "$attempt"
    attempt=$((attempt + 1))
  done

  grep '^{' "$log_file" | jq -s -r '
    [.[] | select(.type == "item.completed" and .item.type == "agent_message") | .item.text] | last // ""'
}

# Looks for the exchange marker in Codex's local session store,
# $CODEX_HOME/sessions/YYYY/MM/DD/rollout-<timestamp>-<thread-id>.jsonl, whose
# first record is the thread's session_meta. Anything else is an unrecognized
# layout: unknown.
codex_adapter_exchange_received() {
  local native_id="$1"
  local exchange_id="$2"
  local sessions_dir="${CODEX_HOME:-$HOME/.codex}/sessions"
  local rollout

  [[ -n "$native_id" ]] \
    && rollout="$(find "$sessions_dir" -mindepth 4 -maxdepth 4 -type f -name "rollout-*-$native_id.jsonl" 2>/dev/null | head -n 1)"
  if [[ -z "$native_id" || -z "$rollout" ]] \
    || ! head -n 1 "$rollout" | jq -e --arg id "$native_id" '.type == "session_meta" and .payload.id == $id' >/dev/null 2>&1; then
    printf 'unknown\n'
  elif grep -qF "[ralph-exchange:$exchange_id]" "$rollout"; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}
