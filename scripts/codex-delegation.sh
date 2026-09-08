#!/usr/bin/env bash
CODEX_DELEGATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CODEX_DELEGATION_DIR/delegation.sh"

# The current attempt's parent thread is the single supported thread.started
# record in its `codex exec --json` log. Nonzero means no trustworthy parent;
# diagnostics never echo log content.
codex_delegation_parent_id() {
  local log="$1" parent
  [[ -f "$log" ]] || return 1
  parent="$(jq -rse '
    map(select(.type == "thread.started") | .thread_id)
    | if length == 1 and (.[0] | type == "string" and test("^[a-zA-Z0-9_-]{1,200}$")) then .[0]
      else error("no single parent") end
  ' "$log" 2>/dev/null)" || return 1
  printf '%s\n' "$parent"
}

# Sanitized facts on stdin; PLAN is an optional QA plan file that maps
# qa_r<run>_<digest> worker names to immutable assignments. Nonzero means
# unbound or ambiguous evidence; never interpret it as zero workers.
codex_delegation_normalize() {
  local parent="$1" plan_file="${2:-}" plan=null children
  if [[ -n "$plan_file" ]]; then
    plan="$(cat "$plan_file")" || return 1
    delegation_validate plan <<< "$plan" || return 1
  fi
  children="$(jq -ce --arg parent "$parent" --argjson plan "$plan" -f "$CODEX_DELEGATION_DIR/codex-delegation-normalize.jq" 2>/dev/null)" || return 1
  delegation_sort_children <<< "$children"
}

# Sanitized thread facts from a fresh read-only App Server process. CODEX_BIN
# overrides the binary, as in the isolated review skill. Nonzero means the
# server, parent, or a required read was unavailable or malformed.
codex_delegation_threads() {
  node "$CODEX_DELEGATION_DIR/codex-delegation-collect.cjs" "$1"
}

codex_delegation_collect() {
  local parent="$1" plan_file="${2:-}" threads
  threads="$(codex_delegation_threads "$parent")" || return 1
  if [[ -n "$plan_file" ]]; then
    codex_delegation_normalize "$parent" "$plan_file" <<< "$threads"
  else
    codex_delegation_normalize "$parent" <<< "$threads"
  fi
}

# Collector envelope for the future verifier: the shared children plus the
# allowlisted thread facts they were derived from. This is not a manifest.
codex_delegation_evidence() {
  local parent="$1" plan_file="${2:-}" threads children
  threads="$(codex_delegation_threads "$parent")" || return 1
  if [[ -n "$plan_file" ]]; then
    children="$(codex_delegation_normalize "$parent" "$plan_file" <<< "$threads")" || return 1
  else
    children="$(codex_delegation_normalize "$parent" <<< "$threads")" || return 1
  fi
  jq -nc --arg parent "$parent" --argjson children "$children" --argjson threads "$threads" \
    '{parentId:$parent,children:$children,threads:$threads.threads}'
}
