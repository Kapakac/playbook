#!/usr/bin/env bash
# PreToolUse hook for Bash in Claude Code: refuses a git commit whose message carries agent traces.
# Claude Code pipes the tool call as JSON to stdin; exit code 2 blocks the call and shows stderr to the agent.
set -euo pipefail

input=$(cat)
case $input in
  *"git commit"*) ;;
  *) exit 0 ;;
esac
if printf '%s' "$input" | grep -qiE 'co-authored-by|claude-session|generated (with|by)|requested by|claude\.ai/code'; then
  echo "The commit message carries agent traces (Co-Authored-By, Claude-Session, Generated with …): commit again without them (rules.md, «Ветки, коммиты и PR»)." >&2
  exit 2
fi
