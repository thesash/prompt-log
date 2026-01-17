#!/usr/bin/env bash
# Extract a minimal transcript from AI coding session logs.

set -euo pipefail

SESSION_FILE=""
OUTPUT=""

usage() {
  echo "Usage: extract.sh [session-file] [--output file.md]" >&2
  echo "" >&2
  echo "Defaults to the latest session for the current platform." >&2
  echo "" >&2
  echo "Supported formats:" >&2
  echo "  - Clawdbot: ~/.clawdbot/agents/main/sessions/*.jsonl" >&2
  echo "  - Claude Code: ~/.claude/projects/<project>/*.jsonl" >&2
  echo "  - Codex: ~/.codex/sessions/YYYY/MM/DD/*.jsonl" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|-o) OUTPUT="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *)
      if [[ -z "$SESSION_FILE" ]]; then
        SESSION_FILE="$1"
        shift
      else
        echo "Unknown option: $1" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required in PATH." >&2
  exit 1
fi

detect_source() {
  if [[ -n "${CODEX_CI:-}" || -n "${CODEX_HOME:-}" || -n "${CODEX_SESSION:-}" ]]; then
    echo "codex"
    return
  fi
  if [[ -n "${CLAUDE_PROJECT:-}" || -n "${CLAUDE_CODE:-}" ]]; then
    echo "claude-code"
    return
  fi
  if [[ -n "${CLAWDBOT_SESSION_ID:-}" || -n "${CLAWDBOT_AGENT:-}" ]]; then
    echo "clawdbot"
    return
  fi
  echo ""
}

codex_session_from_history() {
  local history="$HOME/.codex/history.jsonl"
  local session_id=""
  local match=""
  if [[ ! -f "$history" ]]; then
    return 1
  fi
  session_id=$(tail -n 1 "$history" | jq -r '.session_id // empty' 2>/dev/null)
  if [[ -z "$session_id" || "$session_id" == "null" ]]; then
    return 1
  fi
  shopt -s nullglob
  match=$(ls -t "$HOME/.codex/sessions/"*/*/*/*"${session_id}".jsonl 2>/dev/null | head -n 1)
  shopt -u nullglob
  if [[ -z "$match" ]]; then
    return 1
  fi
  printf '%s' "$match"
}

latest_from_glob() {
  local pattern="$1"
  local files=()
  local latest=""
  shopt -s nullglob
  files=( $pattern )
  shopt -u nullglob
  if [[ ${#files[@]} -eq 0 ]]; then
    return 1
  fi
  latest=$(ls -t "${files[@]}" 2>/dev/null | head -n 1)
  if [[ -z "$latest" ]]; then
    return 1
  fi
  printf '%s' "$latest"
}

latest_for_source() {
  local source="$1"
  case "$source" in
    clawdbot)
      latest_from_glob "$HOME/.clawdbot/agents/main/sessions/"*.jsonl
      ;;
    claude-code)
      latest_from_glob "$HOME/.claude/projects/"*/*.jsonl
      ;;
    codex)
      latest_from_glob "$HOME/.codex/sessions/"*/*/*/*.jsonl
      ;;
    *)
      return 1
      ;;
  esac
}

file_mtime() {
  local file="$1"
  if stat -f %m "$file" >/dev/null 2>&1; then
    stat -f %m "$file"
  else
    stat -c %Y "$file"
  fi
}

latest_any() {
  local candidate=""
  local candidates=()
  local best=""
  local best_mtime=0
  local mtime=0

  candidate=$(latest_for_source "clawdbot" 2>/dev/null || true)
  if [[ -n "$candidate" ]]; then
    candidates+=("$candidate")
  fi
  candidate=$(latest_for_source "claude-code" 2>/dev/null || true)
  if [[ -n "$candidate" ]]; then
    candidates+=("$candidate")
  fi
  candidate=$(latest_for_source "codex" 2>/dev/null || true)
  if [[ -n "$candidate" ]]; then
    candidates+=("$candidate")
  fi

  if [[ ${#candidates[@]} -eq 0 ]]; then
    return 1
  fi

  for candidate in "${candidates[@]}"; do
    mtime=$(file_mtime "$candidate" 2>/dev/null || echo 0)
    if [[ -z "$best" || "$mtime" -gt "$best_mtime" ]]; then
      best="$candidate"
      best_mtime="$mtime"
    fi
  done

  printf '%s' "$best"
}

if [[ -z "$SESSION_FILE" ]]; then
  source_override=$(detect_source)
  if [[ -n "$source_override" ]]; then
    if [[ "$source_override" == "codex" ]]; then
      SESSION_FILE=$(codex_session_from_history 2>/dev/null || true)
    fi
    if [[ -z "$SESSION_FILE" ]]; then
      SESSION_FILE=$(latest_for_source "$source_override" 2>/dev/null || true)
    fi
  fi
  if [[ -z "$SESSION_FILE" ]]; then
    SESSION_FILE=$(latest_any 2>/dev/null || true)
  fi
  if [[ -z "$SESSION_FILE" ]]; then
    echo "No session files found." >&2
    usage
    exit 1
  fi
fi

if [[ ! -f "$SESSION_FILE" ]]; then
  echo "File not found: $SESSION_FILE" >&2
  exit 1
fi

if [[ -z "$OUTPUT" ]]; then
  mkdir -p .prompt-log
  timestamp=$(date +%Y%m%d%H%M)
  OUTPUT=".prompt-log/${timestamp}.md"
fi

detect_format() {
  if jq -e 'select(.type == "session")' "$SESSION_FILE" >/dev/null 2>&1; then
    echo "clawdbot"
  elif jq -e 'select(.userType == "external")' "$SESSION_FILE" >/dev/null 2>&1; then
    echo "claude-code"
  elif jq -e 'select(.type == "session_meta" or .type == "response_item")' "$SESSION_FILE" >/dev/null 2>&1; then
    echo "codex"
  else
    echo "unknown"
  fi
}

FORMAT=$(detect_format)

if [[ "$FORMAT" == "unknown" ]]; then
  echo "Unknown session format for: $SESSION_FILE" >&2
  exit 1
fi

TMPOUT=$(mktemp)
trap 'rm -f "$TMPOUT"' EXIT

case "$FORMAT" in
  clawdbot)
    jq -r --arg agent "Clawdbot" '
      def clean_user:
        .message.content[0].text // "" |
        (split("[Current message") | last) as $chunk |
        ($chunk | capture("Z\\]\\s*(?<msg>.+?)\\n\\[message_id")?.msg) as $parsed |
        (if $parsed != null and $parsed != "" then $parsed else $chunk end) |
        gsub("^\\s+|\\s+$"; "");
      def assistant_text:
        .message.content
        | map(
            if .type == "toolCall" and .name == "message" and .arguments.action == "send" then .arguments.message
            elif .type == "text" then .text
            else empty
            end
          )
        | map(select(. != null and . != "") | gsub("^\\[\\[reply_to:[^\\]]+\\]\\]\\s*"; ""))
        | join("\n\n");
      def emit($role; $timestamp; $text):
        if ($text | length) == 0 then empty
        else "\($role) \($timestamp)\n```\n\($text)\n```\n\n"
        end;
      select(.type == "message") |
      if .message.role == "user" then
        emit("User"; .timestamp; clean_user)
      elif .message.role == "assistant" then
        emit($agent; .timestamp; assistant_text)
      else empty end
    ' "$SESSION_FILE" > "$TMPOUT"
    ;;
  claude-code)
    jq -r --arg agent "Claude Code" '
      def message_text:
        .message.content |
        if type == "string" then .
        elif type == "array" then
          map(select(.type == "text" or .type == "input_text") | .text) | join("\n")
        elif type == "object" and has("text") then .text
        else "" end;
      def emit($role; $timestamp; $text):
        if ($text | length) == 0 then empty
        else "\($role) \($timestamp)\n```\n\($text)\n```\n\n"
        end;
      select(.type == "user" or .type == "assistant") |
      message_text as $text |
      if $text == "" then empty
      else
        if .type == "user" then emit("User"; .timestamp; $text) else emit($agent; .timestamp; $text) end
      end
    ' "$SESSION_FILE" > "$TMPOUT"
    ;;
  codex)
    jq -r --arg agent "Codex" '
      def message_text:
        .payload.content |
        if type == "array" then
          map(
            if .type == "input_text" then .text
            elif .type == "output_text" then .text
            elif .type == "text" then .text
            else empty
            end
          ) | join("\n")
        else "" end;
      def emit($role; $timestamp; $text):
        if ($text | length) == 0 then empty
        else "\($role) \($timestamp)\n```\n\($text)\n```\n\n"
        end;
      select(.type == "response_item" and .payload.type == "message") |
      message_text as $text |
      if $text == "" then empty
      elif ($text | test("^# AGENTS|^<environment|^<INSTRUCTIONS|^# Repository")) then empty
      else
        if .payload.role == "user" then emit("User"; .timestamp; $text)
        elif .payload.role == "assistant" then emit($agent; .timestamp; $text)
        else empty end
      end
    ' "$SESSION_FILE" > "$TMPOUT"
    ;;
  *)
    echo "Unknown session format: $FORMAT" >&2
    exit 1
    ;;
esac

mv "$TMPOUT" "$OUTPUT"
echo "Wrote transcript to: $OUTPUT"
