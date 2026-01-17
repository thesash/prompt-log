---
name: prompt-log
description: Extract conversation transcripts from AI coding session logs (Clawdbot, Claude Code, Codex). Use when asked to export prompt history, session logs, or transcripts from .jsonl session files.
---

# Prompt Log

## Quick start

Run the bundled script (defaults to the latest session for the current platform):

```bash
scripts/extract.sh
```

Custom output path:

```bash
scripts/extract.sh --output my-transcript.md
```

## Inputs

- **Session file**: Optional. A `.jsonl` session log from Clawdbot, Claude Code, or Codex.
- **Optional output**: `--output` path for the markdown transcript.

## Output rules

- The transcript is for the current conversation only.
- When no session file is provided, use the latest session for the current platform.
- For Codex sessions, prefer the latest session ID in `~/.codex/history.jsonl` to target the current chat.
- If the user asks for a focused slice (example: "portion relevant to macos fix"), extract the full session and then trim to the relevant blocks with a small amount of surrounding context while preserving order.
- If the log contains pasted content from another agent, clean it up and place it where it naturally fits in the flow.

## Outputs

- Writes a markdown transcript. Defaults to `.prompt-log/YYYYMMDDHHMM.md` when `--output` is not provided.

## Output format

Each message is emitted as a role line with a timestamp, followed by a fenced code block with the content.

```text
Codex 2026-01-17T06:44:01.941Z
```
```
<assistant text>
```

User messages are labeled `User`, and assistant messages are labeled `Codex`, `Claude Code`, or `Clawdbot` depending on the session source.

## Examples

```bash
scripts/extract.sh
scripts/extract.sh ~/.codex/sessions/2026/01/12/abcdef.jsonl
scripts/extract.sh ~/.claude/projects/my-proj/xyz.jsonl --output my-transcript.md
scripts/extract.sh ~/.clawdbot/agents/main/sessions/123.jsonl
```

## Dependencies

- Requires `jq` in PATH.
