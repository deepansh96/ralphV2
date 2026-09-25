#!/usr/bin/env bash

# Grilling Session Record store. Records live at
# <ralph-dir>/grilling-sessions/<id>/session.json and are mutated with jq only,
# through atomic write-then-rename under umask 077 (dirs 0700, files 0600).

grill_record_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

grill_record_new_id() {
  printf '%s-%s\n' "$(date +%Y%m%d-%H%M%S)" "$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
}

grill_record_sessions_dir() {
  local ralph_dir="$1"
  local sessions_dir="$ralph_dir/grilling-sessions"

  (umask 077 && mkdir -p "$sessions_dir") || return 1
  chmod 700 "$sessions_dir"
  printf '%s\n' "$sessions_dir"
}

# Creates a fresh owner-only session directory and prints its ID.
grill_record_create_dir() {
  local sessions_dir="$1"
  local id

  while true; do
    id="$(grill_record_new_id)"
    if (umask 077 && mkdir "$sessions_dir/$id") 2>/dev/null; then
      chmod 700 "$sessions_dir/$id"
      printf '%s\n' "$id"
      return 0
    fi
    [[ -d "$sessions_dir/$id" ]] || return 1
  done
}

# Writes stdin to <path> atomically with mode 0600.
grill_record_write_file() {
  local path="$1"
  local tmp

  (
    umask 077
    tmp="$(mktemp "$path.tmp.XXXXXX")" || exit 1
    if ! cat > "$tmp"; then
      rm -f "$tmp"
      exit 1
    fi
    chmod 600 "$tmp"
    mv "$tmp" "$path"
  )
}

grill_record_write() {
  local record_file="$1"
  local record_json="$2"

  jq '.' <<<"$record_json" | grill_record_write_file "$record_file"
}

# Applies a jq filter (plus any extra jq arguments) to the record and stamps
# updatedAt.
grill_record_update() {
  local record_file="$1"
  local filter="$2"
  shift 2
  local updated

  updated="$(jq --arg now "$(grill_record_now)" "$@" "($filter) | .updatedAt = \$now" "$record_file")" \
    || return 1
  printf '%s\n' "$updated" | grill_record_write_file "$record_file"
}

# Session lock: an atomic mkdir of <session-dir>/lock holding the owner PID.
# A live owner fails the caller clearly; a dead owner's lock is reclaimed.
grill_record_lock() {
  local session_dir="$1"
  local lock_dir="$session_dir/lock"
  local pid

  while ! (umask 077 && mkdir "$lock_dir") 2>/dev/null; do
    pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    if [[ -z "$pid" ]] || ps -p "$pid" >/dev/null 2>&1; then
      echo "Error: session $(basename "$session_dir") is locked by another coordinator (PID ${pid:-unknown}); wait for it to exit, or remove $lock_dir if no coordinator is running" >&2
      return 1
    fi
    rm -rf "$lock_dir"
  done
  printf '%s\n' "$$" | grill_record_write_file "$lock_dir/pid"
}

# Moves a session directory to <ralph-dir>/archive/grilling/<YYYY-MM-DD>-<id>/
# and prints the new location.
grill_record_archive() {
  local session_dir="$1"
  local ralph_dir archive_dir target

  ralph_dir="$(cd "$session_dir/../.." && pwd -P)"
  archive_dir="$ralph_dir/archive/grilling"
  target="$archive_dir/$(date +%Y-%m-%d)-$(basename "$session_dir")"
  (umask 077 && mkdir -p "$archive_dir") || return 1
  mv "$session_dir" "$target" || return 1
  printf '%s\n' "$target"
}

# Releases the session lock if this process owns it.
grill_record_unlock() {
  local lock_dir="$1/lock"

  if [[ "$(cat "$lock_dir/pid" 2>/dev/null || true)" == "$$" ]]; then
    rm -rf "$lock_dir"
  fi
}
