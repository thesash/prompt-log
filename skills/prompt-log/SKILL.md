---
name: prompt-log
description: Extract current conversation to markdown for PR documentation. Analyzes topics, detects compaction, handles paste mode.
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# Prompt Log v2

Extract the current Claude Code conversation to clean markdown for PR documentation. Focuses on text-only content (no tool calls or diffs), with intelligent topic analysis and compaction detection.

## Modes

### 1. Current Session Mode (default)

When invoked without arguments, extract the current conversation:

```bash
# Run from the skill directory
SKILL_DIR="$(dirname "$0")"
"$SKILL_DIR/scripts/extract.sh"
```

### 2. Paste Mode

When the user provides conversation text directly (contains "User:" and "Claude Code:" patterns), parse it:

```bash
"$SKILL_DIR/scripts/parse-paste.sh" <<< "$PASTE_CONTENT"
```

## Workflow

Follow this decision tree when the skill is invoked:

### Step 1: Detect Mode

Check if arguments contain pasted conversation text:
- Look for patterns like `User ` followed by timestamps or `Claude Code `
- If paste detected → Run `scripts/parse-paste.sh` with the content
- Otherwise → Continue to Step 2

### Step 2: Find Current Session

The current session file is located at:
```
~/.claude/projects/-{cwd-with-dashes}/{session-id}.jsonl
```

Find it by:
1. Convert current working directory to the project directory name (replace `/` with `-`)
2. Find the most recently modified `.jsonl` in that directory

Run: `scripts/extract.sh --detect-session` to get the session path.

### Step 3: Check for Compaction

Run: `scripts/extract.sh --check-compaction "$SESSION_FILE"`

If compacted:
- Inform user: "This conversation has been compacted. The transcript will include summary context plus remaining messages."
- The extract script handles reconstruction automatically

### Step 4: Analyze Topics

Run: `scripts/analyze-topics.sh "$SESSION_FILE"`

This outputs JSON with detected topic boundaries:
```json
{
  "topics": [
    {"start": "2026-01-17T20:00:00Z", "end": "2026-01-17T20:30:00Z", "summary": "Implementing auth flow"},
    {"start": "2026-01-17T21:15:00Z", "end": "2026-01-17T21:45:00Z", "summary": "Debugging test failures"}
  ],
  "is_single_topic": false,
  "relates_to_git_changes": true
}
```

### Step 5: Handle Multiple Topics

If `is_single_topic` is false, use AskUserQuestion:

```
Which topics should be included in the transcript?

Options:
1. All topics (full conversation)
2. [Topic 1 summary] (time range)
3. [Topic 2 summary] (time range)
4. Only topics related to current git changes
```

### Step 6: Generate Output

Run the extraction with selected options:

```bash
# Full extraction
scripts/extract.sh "$SESSION_FILE" --output ".prompt-log/prompt-log-v2-$(date +%Y%m%d%H%M).md"

# Topic-filtered extraction
scripts/extract.sh "$SESSION_FILE" --topic-start "2026-01-17T21:15:00Z" --topic-end "2026-01-17T21:45:00Z" --output "..."
```

### Step 7: Report Results

Tell the user:
- Where the file was written
- How many exchanges were captured
- Whether compaction summaries were included

## Output Format

The generated markdown follows this structure:

```markdown
# Conversation Log

Generated: 2026-01-17 21:27
Session: /path/to/working/directory

---

User 2026-01-17T21:00:00.000Z
```
User's message text here...
```

Claude Code 2026-01-17T21:00:05.000Z
```
Assistant's response text here...
```

---
```

Key formatting rules:
- Chronological order (oldest first)
- Role + timestamp header above each message
- Content in fenced code blocks
- Only text content (no tool calls, no diffs, no system messages)
- `---` separator between exchanges

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `scripts/extract.sh` | Main extraction, compaction handling, session detection |
| `scripts/analyze-topics.sh` | Topic boundary detection using time gaps and semantics |
| `scripts/parse-paste.sh` | Parse pasted conversation text into markdown |

## Dependencies

- `jq` - JSON processing
- Bash 4+ for associative arrays

## Output Location

Default: `.prompt-log/prompt-log-v2-{YYYYMMDDHHMM}.md` in current working directory.
