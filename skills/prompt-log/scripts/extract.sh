#!/usr/bin/env bash
# Prompt Log v2 - Extract text-only conversation transcript from Claude Code sessions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(pwd -P)"

SESSION_FILE=""
OUTPUT=""
TOPIC_START=""
TOPIC_END=""
CHECK_COMPACTION=false
DETECT_SESSION=false

usage() {
  cat >&2 <<EOF
Usage: extract.sh [options] [session-file]

Options:
  --output, -o FILE       Output markdown file path
  --topic-start TIME      Filter messages starting from this timestamp
  --topic-end TIME        Filter messages ending at this timestamp
  --check-compaction      Check if session has been compacted and exit
  --detect-session        Print the current session file path and exit
  --help, -h              Show this help message

If no session file is provided, uses the current Claude Code session.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|-o) OUTPUT="$2"; shift 2 ;;
    --topic-start) TOPIC_START="$2"; shift 2 ;;
    --topic-end) TOPIC_END="$2"; shift 2 ;;
    --check-compaction) CHECK_COMPACTION=true; shift ;;
    --detect-session) DETECT_SESSION=true; shift ;;
    --help|-h) usage; exit 0 ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -z "$SESSION_FILE" ]]; then
        SESSION_FILE="$1"
        shift
      else
        echo "Unexpected argument: $1" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

# Expand tilde and make output path absolute
if [[ -n "$OUTPUT" ]]; then
  OUTPUT="${OUTPUT/#\~/$HOME}"
  if [[ "$OUTPUT" != /* ]]; then
    OUTPUT="$ROOT_DIR/$OUTPUT"
  fi
fi

# Require jq
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required in PATH." >&2
  exit 1
fi

# Convert a directory path to Claude's project directory name
# /Users/foo/bar -> -Users-foo-bar
path_to_project_dir() {
  local path="$1"
  echo "$path" | sed 's|/|-|g'
}

# Find the current Claude Code session file
find_current_session() {
  local project_dir
  project_dir=$(path_to_project_dir "$ROOT_DIR")
  local claude_project_path="$HOME/.claude/projects/$project_dir"

  if [[ ! -d "$claude_project_path" ]]; then
    return 1
  fi

  # Find most recently modified .jsonl file
  local latest
  latest=$(find "$claude_project_path" -maxdepth 1 -name "*.jsonl" -type f -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null \
    | head -n 1)

  if [[ -z "$latest" ]]; then
    return 1
  fi

  printf '%s' "$latest"
}

# Check if a session file has been compacted (contains summary entries)
check_compaction() {
  local session="$1"
  if jq -e 'select(.type == "summary")' "$session" >/dev/null 2>&1; then
    return 0  # Has compaction
  fi
  return 1  # No compaction
}

# Handle --detect-session mode
if [[ "$DETECT_SESSION" == true ]]; then
  session=$(find_current_session 2>/dev/null || true)
  if [[ -z "$session" ]]; then
    echo "No session found for: $ROOT_DIR" >&2
    exit 1
  fi
  echo "$session"
  exit 0
fi

# Find session file if not provided
if [[ -z "$SESSION_FILE" ]]; then
  SESSION_FILE=$(find_current_session 2>/dev/null || true)
  if [[ -z "$SESSION_FILE" ]]; then
    echo "No session file found for current directory." >&2
    echo "Looked in: ~/.claude/projects/$(path_to_project_dir "$ROOT_DIR")/" >&2
    exit 1
  fi
fi

# Validate session file exists
if [[ ! -f "$SESSION_FILE" ]]; then
  echo "File not found: $SESSION_FILE" >&2
  exit 1
fi

# Handle --check-compaction mode
if [[ "$CHECK_COMPACTION" == true ]]; then
  if check_compaction "$SESSION_FILE"; then
    echo "compacted"
    exit 0
  else
    echo "not-compacted"
    exit 0
  fi
fi

# Set default output path
if [[ -z "$OUTPUT" ]]; then
  mkdir -p "$ROOT_DIR/.prompt-log"
  timestamp=$(date +%Y%m%d%H%M)
  OUTPUT="$ROOT_DIR/.prompt-log/prompt-log-v2-${timestamp}.md"
fi

# Create temporary file for output
TMPOUT=$(mktemp)
trap 'rm -f "$TMPOUT"' EXIT

# Check for compaction and handle accordingly
HAS_COMPACTION=false
if check_compaction "$SESSION_FILE"; then
  HAS_COMPACTION=true
fi

# Generate markdown header
{
  echo "# Conversation Log"
  echo ""
  echo "Generated: $(date '+%Y-%m-%d %H:%M')"
  echo "Session: $ROOT_DIR"
  if [[ "$HAS_COMPACTION" == true ]]; then
    echo "Note: This conversation was compacted. Earlier context is summarized."
  fi
  echo ""
  echo "---"
  echo ""
} > "$TMPOUT"

# Extract messages - text only, no tool calls
# For Claude Code sessions, we extract:
# - type="user" messages with text content
# - type="assistant" messages with text content (skip tool_use blocks)
# - type="summary" for compaction context

# Use a heredoc for cleaner jq script
read -r -d '' JQ_SCRIPT << 'JQEOF' || true
def extract_text:
  .message.content |
  if type == "string" then .
  elif type == "array" then
    map(
      select(.type == "text" or .type == "input_text") |
      .text // empty
    ) | join("\n")
  elif type == "object" and has("text") then .text
  else "" end;

# Determine fence length needed to wrap text containing backticks
# Returns the appropriate fence string (``` or ```` or ````` etc)
def get_fence($text):
  # Find longest sequence of backticks in text and use one more
  ([$text | scan("(`+)") | .[0]] | map(length) | max // 0) as $max_ticks |
  if $max_ticks < 3 then "```"
  else ([$max_ticks + 1, 3] | max) as $needed | ("`" * $needed)
  end;

def format_block($role; $ts; $text):
  if ($text | length) == 0 then empty
  else
    get_fence($text) as $fence |
    "\($role) \($ts)\n\($fence)\n\($text)\n\($fence)\n"
  end;

def process_summary:
  select(.type == "summary") |
  get_fence(.summary) as $fence |
  "## Compacted Context\n\n\($fence)\n" + .summary + "\n\($fence)\n\n---\n";

select(.type == "user" or .type == "assistant") |
extract_text as $text |
if $text == "" then empty
else
  if .type == "user" then
    format_block("User"; .timestamp; $text)
  else
    format_block($agent; .timestamp; $text)
  end
end
JQEOF

# Handle topic filtering by modifying the script
if [[ -n "$TOPIC_START" && -n "$TOPIC_END" ]]; then
  JQ_SCRIPT="select(.timestamp >= \"$TOPIC_START\" and .timestamp <= \"$TOPIC_END\") | $JQ_SCRIPT"
elif [[ -n "$TOPIC_START" ]]; then
  JQ_SCRIPT="select(.timestamp >= \"$TOPIC_START\") | $JQ_SCRIPT"
elif [[ -n "$TOPIC_END" ]]; then
  JQ_SCRIPT="select(.timestamp <= \"$TOPIC_END\") | $JQ_SCRIPT"
fi

# Extract summaries first if compacted
if [[ "$HAS_COMPACTION" == true ]]; then
  jq -r '
    def get_fence($text):
      ([$text | scan("(`+)") | .[0]] | map(length) | max // 0) as $max_ticks |
      if $max_ticks < 3 then "```"
      else ([$max_ticks + 1, 3] | max) as $needed | ("`" * $needed)
      end;
    select(.type == "summary") |
    get_fence(.summary) as $fence |
    "## Compacted Context\n\n\($fence)\n" + .summary + "\n\($fence)\n\n---\n"
  ' "$SESSION_FILE" >> "$TMPOUT" 2>/dev/null || true
fi

# Extract messages
jq -r --arg agent "Claude Code" "$JQ_SCRIPT" "$SESSION_FILE" >> "$TMPOUT"

# Count messages extracted
MSG_COUNT=$(grep -c "^User \|^Claude Code " "$TMPOUT" 2>/dev/null || echo "0")

# Move to final output location
mkdir -p "$(dirname "$OUTPUT")"
mv "$TMPOUT" "$OUTPUT"

echo "Wrote transcript to: $OUTPUT"
echo "Messages extracted: $MSG_COUNT"
if [[ "$HAS_COMPACTION" == true ]]; then
  echo "Note: Session was compacted - includes summary context"
fi
