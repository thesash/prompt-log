# prompt-log

Extract conversation transcripts from AI coding sessions.

## Why?

I built this because documenting AI-assisted development in PRs is valuable but annoying to do by hand. See [clawdbot/clawdbot#763](https://github.com/clawdbot/clawdbot/pull/763) for an example of what good "prompt history" documentation looks like — and why I didn't want to format that manually ever again.

## Supported Platforms

| Platform | Session Location |
|----------|-----------------|
| Clawdbot | `~/.clawdbot/agents/main/sessions/*.jsonl` |
| Claude Code | `~/.claude/projects/<project>/*.jsonl` |
| Codex | `~/.codex/sessions/YYYY/MM/DD/*.jsonl` |

Format is auto-detected.

## Usage

```bash
# Basic extraction (outputs to .prompt-log/YYYY-MM-DD-HHMMSS.md)
./skills/prompt-log/scripts/extract.sh <session-file>

# Custom output file
./skills/prompt-log/scripts/extract.sh <session-file> --output my-transcript.md

# Time-bounded extraction
./skills/prompt-log/scripts/extract.sh <session-file> --after "2026-01-12T10:00:00" --before "2026-01-12T12:00:00"
```

Output defaults to `.prompt-log/` directory to keep transcripts tidy in project folders.

## Finding Sessions

```bash
# Clawdbot - recent sessions
ls -lt ~/.clawdbot/agents/main/sessions/*.jsonl | head -10

# Claude Code - project sessions
ls -lt ~/.claude/projects/*/*.jsonl | head -10

# Codex - recent sessions
find ~/.codex/sessions -name "*.jsonl" -mtime -7 | head -10

# Search all for a keyword
grep -l "keyword" ~/.clawdbot/agents/main/sessions/*.jsonl 2>/dev/null
```

## Example

See [examples/building-prompt-log.md](examples/building-prompt-log.md) for a real transcript — it's the conversation where this tool was built.

## License

MIT
