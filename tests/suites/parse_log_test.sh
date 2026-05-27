#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/test_helpers.sh"

test_parse_log_claude_extracts_text_and_tool_use() {
  local log_file output

  log_file="$(mktemp)"
  cat > "$log_file" <<'JSONL'
{"type":"system","subtype":"init","session_id":"fake"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Reading the file now to understand the structure."}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/foo.sh"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"The file looks correct. I will make the changes."}]}}
{"type":"result","subtype":"success","result":"done"}
JSONL

  source "$ROOT_DIR/scripts/parse-log.sh"
  output="$(parse_log "$log_file" "claude" 10)"
  rm -f "$log_file"

  assert_contains "$output" "[text] Reading the file now"
  assert_contains "$output" "[tool] Read: file_path=/tmp/foo.sh"
  assert_contains "$output" "[text] The file looks correct"
  [[ "$output" != *"system"* ]] || fail "expected system events to be filtered out"
  [[ "$output" != *"result"* ]] || fail "expected result events to be filtered out"
}

test_parse_log_codex_extracts_messages_and_commands() {
  local log_file output

  log_file="$(mktemp)"
  cat > "$log_file" <<'JSONL'
{"type":"turn.started"}
{"type":"item.started","item":{"type":"command_execution"}}
{"type":"item.completed","item":{"type":"command_execution","command":"npm test"}}
{"type":"item.completed","item":{"type":"agent_message","text":"All tests pass. Committing now."}}
{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}
JSONL

  source "$ROOT_DIR/scripts/parse-log.sh"
  output="$(parse_log "$log_file" "codex" 10)"
  rm -f "$log_file"

  assert_contains "$output" "[cmd] npm test"
  assert_contains "$output" "[text] All tests pass. Committing now."
  [[ "$output" != *"turn.started"* ]] || fail "expected turn.started to be filtered out"
  [[ "$output" != *"turn.completed"* ]] || fail "expected turn.completed to be filtered out"
  [[ "$output" != *"item.started"* ]] || fail "expected item.started to be filtered out"
}

test_parse_log_empty_file_shows_starting() {
  local log_file output

  log_file="$(mktemp)"
  : > "$log_file"

  source "$ROOT_DIR/scripts/parse-log.sh"
  output="$(parse_log "$log_file" "claude" 10)"
  rm -f "$log_file"

  assert_contains "$output" "Starting..."

  output="$(parse_log "/nonexistent/file/does/not/exist" "claude" 10)"
  assert_contains "$output" "Starting..."
}

test_parse_log_partial_write_skips_truncated_lines() {
  local log_file output

  log_file="$(mktemp)"
  cat > "$log_file" <<'JSONL'
{"type":"assistant","message":{"content":[{"type":"text","text":"Valid line before truncation."}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Trun
JSONL

  source "$ROOT_DIR/scripts/parse-log.sh"
  output="$(parse_log "$log_file" "claude" 10)"
  rm -f "$log_file"

  assert_contains "$output" "[text] Valid line before truncation."
  [[ "$output" != *"Trun"* ]] || fail "expected truncated line to be skipped"
}

run_test test_parse_log_claude_extracts_text_and_tool_use
run_test test_parse_log_codex_extracts_messages_and_commands
run_test test_parse_log_empty_file_shows_starting
run_test test_parse_log_partial_write_skips_truncated_lines

echo "parse_log_test.sh passed"
