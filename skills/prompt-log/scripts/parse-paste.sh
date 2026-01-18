#!/usr/bin/env bash
# Prompt Log v2 - Parse pasted conversation text into structured markdown.
#
# Reads from stdin or file argument and outputs formatted markdown.
# Detects patterns like:
#   - "User 2026-01-17T21:00:00.000Z" followed by content
#   - "Claude Code 2026-01-17T21:00:00.000Z" followed by content
#   - "User:" or "Claude:" simple prefixes

set -euo pipefail

ROOT_DIR="$(pwd -P)"
INPUT_FILE="${1:-}"
OUTPUT="${2:-}"

# Read input from file or stdin
if [[ -n "$INPUT_FILE" && -f "$INPUT_FILE" ]]; then
  INPUT=$(cat "$INPUT_FILE")
elif [[ -n "$INPUT_FILE" && "$INPUT_FILE" != "-" ]]; then
  # Argument is the paste content itself
  INPUT="$INPUT_FILE"
else
  # Read from stdin
  INPUT=$(cat)
fi

if [[ -z "$INPUT" ]]; then
  echo "No input provided. Pipe text or provide as argument." >&2
  exit 1
fi

# Set default output path
if [[ -z "$OUTPUT" ]]; then
  mkdir -p "$ROOT_DIR/.prompt-log"
  timestamp=$(date +%Y%m%d%H%M)
  OUTPUT="$ROOT_DIR/.prompt-log/prompt-log-v2-${timestamp}.md"
fi

# Create output file
TMPOUT=$(mktemp)
trap 'rm -f "$TMPOUT"' EXIT

# Header
{
  echo "# Conversation Log"
  echo ""
  echo "Generated: $(date '+%Y-%m-%d %H:%M')"
  echo "Source: Pasted content"
  echo ""
  echo "---"
  echo ""
} > "$TMPOUT"

# Parse the input
# We look for role markers and extract content between them
parse_conversation() {
  local input="$1"
  local current_role=""
  local current_timestamp=""
  local current_content=""
  local line_num=0

  # Pattern for role with timestamp: "User 2026-01-17T21:00:00.000Z" or "Claude Code 2026-01-17T21:00:00.000Z"
  local ts_pattern='^(User|Claude Code|Claude|Assistant|Codex|Clawdbot)[[:space:]]+(20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z?)'

  # Pattern for simple role prefix: "User:" or "Claude:"
  local simple_pattern='^(User|Claude Code|Claude|Assistant|Codex|Clawdbot):[[:space:]]*(.*)'

  # Pattern for code block markers
  local codeblock_start='^```'
  local codeblock_end='^```$'

  local in_codeblock=false

  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_num++))

    # Check for role with timestamp
    if [[ "$line" =~ $ts_pattern ]]; then
      # Emit previous block if exists
      if [[ -n "$current_role" && -n "$current_content" ]]; then
        emit_block "$current_role" "$current_timestamp" "$current_content"
      fi

      current_role="${BASH_REMATCH[1]}"
      current_timestamp="${BASH_REMATCH[2]}"
      current_content=""
      in_codeblock=false
      continue
    fi

    # Check for simple role prefix (User: or Claude:)
    if [[ "$line" =~ $simple_pattern ]]; then
      # Emit previous block if exists
      if [[ -n "$current_role" && -n "$current_content" ]]; then
        emit_block "$current_role" "$current_timestamp" "$current_content"
      fi

      current_role="${BASH_REMATCH[1]}"
      current_timestamp="(no timestamp)"
      # Include rest of line as start of content
      current_content="${BASH_REMATCH[2]}"
      in_codeblock=false
      continue
    fi

    # Skip code block delimiters from input (we'll add our own)
    if [[ "$line" =~ $codeblock_start ]]; then
      in_codeblock=true
      continue
    fi
    if [[ "$in_codeblock" == true && "$line" =~ $codeblock_end ]]; then
      in_codeblock=false
      continue
    fi

    # Accumulate content
    if [[ -n "$current_role" ]]; then
      if [[ -n "$current_content" ]]; then
        current_content+=$'\n'"$line"
      else
        current_content="$line"
      fi
    fi
  done <<< "$input"

  # Emit final block
  if [[ -n "$current_role" && -n "$current_content" ]]; then
    emit_block "$current_role" "$current_timestamp" "$current_content"
  fi
}

emit_block() {
  local role="$1"
  local timestamp="$2"
  local content="$3"

  # Normalize role names
  case "$role" in
    Claude|Assistant) role="Claude Code" ;;
  esac

  # Trim leading/trailing whitespace from content
  content=$(echo "$content" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  if [[ -z "$content" ]]; then
    return
  fi

  echo "$role $timestamp"
  echo '```'
  echo "$content"
  echo '```'
  echo ""
}

# Run parser and append to output
parse_conversation "$INPUT" >> "$TMPOUT"

# Count messages
MSG_COUNT=$(grep -c "^User \|^Claude Code " "$TMPOUT" 2>/dev/null || echo "0")

# Move to final location
mkdir -p "$(dirname "$OUTPUT")"
mv "$TMPOUT" "$OUTPUT"

echo "Wrote transcript to: $OUTPUT"
echo "Messages parsed: $MSG_COUNT"
