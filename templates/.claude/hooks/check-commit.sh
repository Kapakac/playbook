#!/usr/bin/env bash
# PreToolUse hook for Bash in Claude Code: hands the call to the shared guard .githooks/agent-guard.sh
# (a copy of scripts/agent-guard.sh from the playbook, put there by make sync-rules). The guard reads
# the call as JSON on stdin; exit code 2 blocks the call and shows stderr to the agent.
guard=${CLAUDE_PROJECT_DIR:-.}/.githooks/agent-guard.sh
if [ ! -x "$guard" ]; then
  echo "$guard not found: run make sync-rules, the project's commands are not checked until then" >&2
  exit 1
fi
exec "$guard" tool
