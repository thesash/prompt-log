#!/usr/bin/env bash
# Extract conversation transcript from AI coding session logs
# Supports Clawdbot, Claude Code, and Codex
#
# Usage: extract.sh <session-file> [--after "timestamp"] [--before "timestamp"] [--output "file.md"]
#
# If no output specified, writes to ./prompt-log-YYYY-MM-DD-HHMMSS.md

set -euo pipefail

SESSION_FILE="${1:-}"
AFTER=""
BEFORE=""
OUTPUT=""

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --after) AFTER="$2"; shift 2 ;;
    --before) BEFORE="$2"; shift 2 ;;
    --output|-o) OUTPUT="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$SESSION_FILE" ]]; then
  echo "Usage: extract.sh <session-file> [--after timestamp] [--before timestamp] [--output file.md]" >&2
  echo "" >&2
  echo "Supported formats:" >&2
  echo "  - Clawdbot: ~/.clawdbot/agents/main/sessions/*.jsonl" >&2
  echo "  - Claude Code: ~/.claude/projects/<project>/*.jsonl" >&2
  echo "  - Codex: ~/.codex/sessions/YYYY/MM/DD/*.jsonl" >&2
  exit 1
fi

if [[ ! -f "$SESSION_FILE" ]]; then
  echo "File not found: $SESSION_FILE" >&2
  exit 1
fi

# Default output to .prompt-log/ directory
if [[ -z "$OUTPUT" ]]; then
  mkdir -p .prompt-log
  OUTPUT=".prompt-log/$(date +%Y-%m-%d-%H%M%S).md"
fi

# Detect format
detect_format() {
  local first_line second_line
  first_line=$(head -1 "$SESSION_FILE")
  
  if echo "$first_line" | jq -e '.type == "session"' >/dev/null 2>&1; then
    echo "clawdbot"
  elif echo "$first_line" | jq -e '.userType == "external"' >/dev/null 2>&1; then
    echo "claude-code"
  elif echo "$first_line" | jq -e '.type == "session_meta"' >/dev/null 2>&1; then
    echo "codex"
  else
    second_line=$(sed -n '2p' "$SESSION_FILE")
    if echo "$second_line" | jq -e '.type == "message"' >/dev/null 2>&1; then
      echo "clawdbot"
    elif echo "$second_line" | jq -e '.userType == "external"' >/dev/null 2>&1; then
      echo "claude-code"
    elif echo "$second_line" | jq -e '.type == "response_item"' >/dev/null 2>&1; then
      echo "codex"
    else
      echo "unknown"
    fi
  fi
}

FORMAT=$(detect_format)

# Build time filter
TIME_FILTER="true"
if [[ -n "$AFTER" ]]; then
  TIME_FILTER="$TIME_FILTER and .timestamp >= \"$AFTER\""
fi
if [[ -n "$BEFORE" ]]; then
  TIME_FILTER="$TIME_FILTER and .timestamp <= \"$BEFORE\""
fi

# Format timestamp to readable form (e.g., "Jan 12, 2026 9:15 PM")
format_ts() {
  local ts="$1"
  # Convert ISO timestamp to readable format
  if command -v gdate &>/dev/null; then
    gdate -d "$ts" "+%b %d, %Y %-I:%M %p" 2>/dev/null || echo "$ts"
  else
    date -j -f "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" "+%b %d, %Y %-I:%M %p" 2>/dev/null || echo "$ts"
  fi
}

# Create temp file for output
TMPOUT=$(mktemp)
trap "rm -f $TMPOUT" EXIT

# Get session date range for title
get_session_info() {
  local first_ts last_ts
  first_ts=$(jq -r 'select(.timestamp) | .timestamp' "$SESSION_FILE" | head -1)
  last_ts=$(jq -r 'select(.timestamp) | .timestamp' "$SESSION_FILE" | tail -1)
  echo "$first_ts|$last_ts"
}

SESSION_INFO=$(get_session_info)
FIRST_TS="${SESSION_INFO%%|*}"
LAST_TS="${SESSION_INFO##*|}"

# Write header
{
  echo "# Prompt Log"
  echo ""
  echo "**Session:** $(basename "$SESSION_FILE" .jsonl)"
  echo ""
  echo "---"
  echo ""
} > "$TMPOUT"

# Extract based on format
case "$FORMAT" in
  clawdbot)
    # For Clawdbot, extract clean messages with timestamps
    USER_MSGS=$(mktemp)
    ASST_MSGS=$(mktemp)
    trap "rm -f $TMPOUT $USER_MSGS $ASST_MSGS" EXIT

    # Extract user messages
    jq -r '
      select(.type == "message" and .message.role == "user") |
      select('"$TIME_FILTER"') |
      {
        ts: .timestamp,
        raw: .message.content[0].text
      } |
      .ts as $ts |
      .raw |
      split("[Current message") | last |
      capture("Z\\]\\s*(?<msg>.+?)\\n\\[message_id") |
      .msg |
      select(. != null and . != "") |
      "\($ts)\tUSER\t\(.)"
    ' "$SESSION_FILE" > "$USER_MSGS" 2>/dev/null || true

    # Extract assistant messages from tool calls
    jq -r '
      select(.type == "message" and .message.role == "assistant") |
      select('"$TIME_FILTER"') |
      .timestamp as $ts |
      .message.content[] |
      select(.type == "toolCall" and .name == "message" and .arguments.action == "send") |
      select(.arguments.message != null and .arguments.message != "") |
      "\($ts)\tASST\t\(.arguments.message)"
    ' "$SESSION_FILE" >> "$ASST_MSGS" 2>/dev/null || true

    # Also get any direct text responses
    jq -r '
      select(.type == "message" and .message.role == "assistant") |
      select('"$TIME_FILTER"') |
      .timestamp as $ts |
      .message.content[] |
      select(.type == "text") |
      .text |
      select(. != null and . != "" and (length > 50)) |
      "\($ts)\tASST\t\(.)"
    ' "$SESSION_FILE" >> "$ASST_MSGS" 2>/dev/null || true

    # Merge, sort, and format
    cat "$USER_MSGS" "$ASST_MSGS" | sort -u | while IFS=$'\t' read -r ts role msg; do
      [[ -z "$msg" ]] && continue
      if [[ "$role" == "USER" ]]; then
        echo "User:"
      else
        echo "Assistant:"
      fi
      echo '```'
      echo "$msg"
      echo '```'
      echo ""
    done >> "$TMPOUT"
    ;;

  claude-code)
    jq -r '
      select(.type == "user" or .type == "assistant") |
      select('"$TIME_FILTER"') |
      {
        ts: .timestamp,
        role: .type,
        text: (
          .message.content | 
          if type == "array" then
            map(select(.type == "text") | .text) | join("\n")
          else ""
          end
        )
      } |
      select(.text != "") |
      "\(.ts)\t\(.role)\t\(.text)"
    ' "$SESSION_FILE" 2>/dev/null | while IFS=$'\t' read -r ts role msg; do
      [[ -z "$msg" ]] && continue
      if [[ "$role" == "user" ]]; then
        echo "User:"
      else
        echo "Assistant:"
      fi
      echo '```'
      echo "$msg"
      echo '```'
      echo ""
    done >> "$TMPOUT"
    ;;

  codex)
    jq -r '
      select(.type == "response_item" and .payload.type == "message") |
      select('"$TIME_FILTER"') |
      {
        ts: .timestamp,
        role: .payload.role,
        text: (
          .payload.content | 
          if type == "array" then
            map(
              if .type == "input_text" then .text
              elif .type == "text" then .text
              elif .type == "output_text" then .text
              else empty
              end
            ) | join("\n")
          else ""
          end
        )
      } |
      select(.text != "") |
      select((.text | test("^# AGENTS|^<environment|^<INSTRUCTIONS|^# Repository")) | not) |
      "\(.ts)\t\(.role)\t\(.text)"
    ' "$SESSION_FILE" 2>/dev/null | while IFS=$'\t' read -r ts role msg; do
      [[ -z "$msg" ]] && continue
      if [[ "$role" == "user" ]]; then
        echo "User:"
      else
        echo "Assistant:"
      fi
      echo '```'
      echo "$msg"
      echo '```'
      echo ""
    done >> "$TMPOUT"
    ;;

  *)
    echo "Unknown session format: $FORMAT" >&2
    exit 1
    ;;
esac

# Write output
mv "$TMPOUT" "$OUTPUT"
echo "Wrote transcript to: $OUTPUT"
