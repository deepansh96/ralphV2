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
