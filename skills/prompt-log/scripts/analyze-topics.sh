#!/usr/bin/env bash
# Prompt Log v2 - Analyze conversation topics based on time gaps and content.
#
# Outputs JSON with topic boundaries for use by the skill.

set -euo pipefail

ROOT_DIR="$(pwd -P)"
SESSION_FILE="${1:-}"
TIME_GAP_MINUTES="${TIME_GAP_MINUTES:-30}"

if [[ -z "$SESSION_FILE" ]]; then
  echo "Usage: analyze-topics.sh <session-file>" >&2
  exit 1
fi

if [[ ! -f "$SESSION_FILE" ]]; then
  echo "File not found: $SESSION_FILE" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required in PATH." >&2
  exit 1
fi

# Convert ISO timestamp to epoch seconds
iso_to_epoch() {
  local ts="$1"
  # Handle both formats: 2026-01-17T21:00:00.000Z and 2026-01-17T21:00:00Z
  if command -v gdate >/dev/null 2>&1; then
    gdate -d "$ts" +%s 2>/dev/null || echo "0"
  else
    date -j -f "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" +%s 2>/dev/null || \
    date -d "$ts" +%s 2>/dev/null || echo "0"
  fi
}

# Extract user messages with timestamps for topic detection
# We focus on user messages as they define topic boundaries
extract_user_messages() {
  jq -c '
    select(.type == "user") |
    {
      timestamp: .timestamp,
      text: (
        .message.content |
        if type == "string" then .
        elif type == "array" then
          map(select(.type == "text" or .type == "input_text") | .text // empty) | join(" ")
        else "" end
      )
    } |
    select(.text != "" and .text != null)
  ' "$SESSION_FILE"
}

# Get first N words of text as a summary hint
first_words() {
  local text="$1"
  local n="${2:-10}"
  echo "$text" | tr '\n' ' ' | sed 's/  */ /g' | cut -d' ' -f1-"$n" | sed 's/[[:space:]]*$//'
}

# Check if any topic relates to current git changes
check_git_relevance() {
  local changed_files
  changed_files=$(git diff --name-only 2>/dev/null || true)
  changed_files+=$'\n'$(git diff --cached --name-only 2>/dev/null || true)
  changed_files+=$'\n'$(git status --porcelain 2>/dev/null | awk '{print $2}' || true)

  if [[ -z "$changed_files" ]]; then
    echo "false"
    return
  fi

  # Check if any changed file is mentioned in user messages
  local messages
  messages=$(extract_user_messages | jq -r '.text' 2>/dev/null || true)

  while IFS= read -r file; do
    if [[ -n "$file" && "$messages" == *"$file"* ]]; then
      echo "true"
      return
    fi
    # Also check basename
    local basename="${file##*/}"
    if [[ -n "$basename" && "$messages" == *"$basename"* ]]; then
      echo "true"
      return
    fi
  done <<< "$changed_files"

  echo "false"
}

# Main analysis
main() {
  local messages
  local topics=()
  local current_topic_start=""
  local current_topic_end=""
  local current_topic_text=""
  local prev_epoch=0
  local gap_seconds=$((TIME_GAP_MINUTES * 60))

  # Read messages and group by time gaps
  while IFS= read -r msg; do
    local ts
    local text
    local epoch

    ts=$(echo "$msg" | jq -r '.timestamp')
    text=$(echo "$msg" | jq -r '.text')
    epoch=$(iso_to_epoch "$ts")

    # If this is the first message or gap is large, start new topic
    if [[ -z "$current_topic_start" ]] || [[ $((epoch - prev_epoch)) -gt $gap_seconds ]]; then
      # Save previous topic if exists
      if [[ -n "$current_topic_start" ]]; then
        local summary
        summary=$(first_words "$current_topic_text" 8)
        topics+=("{\"start\":\"$current_topic_start\",\"end\":\"$current_topic_end\",\"summary\":\"$summary...\"}")
      fi

      # Start new topic
      current_topic_start="$ts"
      current_topic_end="$ts"
      current_topic_text="$text"
    else
      # Continue current topic
      current_topic_end="$ts"
      # Keep first message text as the topic summary source
    fi

    prev_epoch=$epoch
  done < <(extract_user_messages)

  # Save last topic
  if [[ -n "$current_topic_start" ]]; then
    local summary
    summary=$(first_words "$current_topic_text" 8)
    topics+=("{\"start\":\"$current_topic_start\",\"end\":\"$current_topic_end\",\"summary\":\"$summary...\"}")
  fi

  # Build output JSON
  local topic_count=${#topics[@]}
  local is_single="false"
  if [[ $topic_count -le 1 ]]; then
    is_single="true"
  fi

  local git_relevant
  git_relevant=$(check_git_relevance)

  # Output JSON
  echo "{"
  echo "  \"topics\": ["

  local i=0
  for topic in "${topics[@]}"; do
    if [[ $i -gt 0 ]]; then
      echo ","
    fi
    echo -n "    $topic"
    ((i++))
  done

  echo ""
  echo "  ],"
  echo "  \"topic_count\": $topic_count,"
  echo "  \"is_single_topic\": $is_single,"
  echo "  \"relates_to_git_changes\": $git_relevant"
  echo "}"
}

main
