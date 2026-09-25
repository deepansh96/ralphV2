#!/usr/bin/env bash

# Session adapters for Automated Grilling Sessions. One adapter per provider,
# behind a provider-neutral contract:
#   adapter_capabilities <provider>
#   adapter_new_native_id <provider>
#   adapter_start <role> <config-json> <prompt> <log>   -> prints native session ID
#   adapter_send <role> <config-json> <native-id> <prompt> <schema-file> <log>
#                                                       -> prints the final message
# <config-json> carries provider, model, reasoningEffort, repoRoot and, for
# providers whose IDs the coordinator generates, nativeSessionId.
# Access is always granted through provider-native permission and sandbox
# controls, never --dangerously-skip-permissions. Sessions are only ever
# resumed by explicit native ID, never --continue, --last or --fork-session.

GRILL_CLAUDE_REQUIRED_FLAGS=(
  --session-id
  --resume
  --permission-mode
  --allowedTools
  --disallowedTools
  --settings
  --json-schema
)

adapter_capabilities() {
  local provider="$1"

  case "$provider" in
    claude) claude_adapter_capabilities ;;
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
    *)
      echo "Error: no session adapter is available for provider '$provider'" >&2
      return 1
      ;;
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
# output when the CLI returns one, otherwise the result text.
claude_adapter_send() {
  local role="$1"
  local config="$2"
  local native_id="$3"
  local prompt="$4"
  local schema_file="$5"
  local log_file="$6"

  [[ -n "$native_id" ]] || { echo "Error: claude adapter needs a native session ID to resume" >&2; return 1; }

  if ! claude_adapter_run "$role" "$config" "$prompt" "$log_file" \
    --resume "$native_id" --json-schema "$(jq -c . "$schema_file")"; then
    echo "Error: claude failed to resume the $role session $native_id; see $log_file" >&2
    return 1
  fi

  grep '^{' "$log_file" | jq -s -r '
    [.[] | select(.type == "result")] | last
    | if (.structured_output | type) == "object" then (.structured_output | tojson) else .result end'
}
