#!/usr/bin/env bash
# Usage: check-pr.sh [--key <project key>] <base> <head>
#
# Run inside the project repo on a pull request. Checks what a machine can check of the shared
# rules («Ветки, коммиты и PR»): the branch name, the PR title, the author of every commit
# between <base> and <head>, and agent traces in commit messages, the title and the PR text.
# The branch, title and text come from PR_BRANCH, PR_TITLE and PR_BODY; the key is read from
# AGENTS.md when --key is not given. Errors go out as ::error:: lines; exit code 1 when any.
# A branch imposed by the agent's environment (claude/...) is allowed with a warning.
set -euo pipefail

usage() {
  echo "usage: $0 [--key <project key>] <base> <head>" >&2
  exit 2
}

key=
if [ "${1:-}" = --key ]; then
  [ $# -ge 2 ] || usage
  key=$2
  shift 2
fi
[ $# -eq 2 ] || usage
base=$1
head=$2
branch=${PR_BRANCH:-}
title=${PR_TITLE:-}
body=${PR_BODY:-}

if [ -z "$key" ]; then
  # shellcheck disable=SC2016
  key=$(sed -nE 's/^- Ключ проекта: `([^`]+)`.*/\1/p' AGENTS.md 2>/dev/null | head -n 1)
fi
if [ -z "$key" ]; then
  echo "::error::AGENTS.md needs the «Ключ проекта» line with the key in backticks, or pass --key"
  exit 1
fi

errors=0
err() {
  echo "::error::$1"
  errors=$((errors + 1))
}

rest=${branch#"$key"-}
if [ "$rest" != "$branch" ] && [[ $rest =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  :
elif [[ $branch == claude/* ]]; then
  echo "::warning::branch '$branch' was imposed by the agent's environment; the rules want $key-<task>-<topic>-<suffix> (prepare-pr.md, step 1)"
else
  err "branch '$branch' is not $key-<task>-<topic>-<suffix> in lowercase latin letters (prepare-pr.md, step 1)"
fi

rest=${title#"$key"}
if [ "$rest" = "$title" ] || ! [[ $rest =~ ^(-[0-9]+)?:\  ]]; then
  err "title '$title' does not start with '$key: ' or '$key-<task>: ' (prepare-pr.md, step 9)"
fi

agent='anthropic\.com|openai\.com|claude|codex|copilot'
while IFS= read -r author; do
  [ -n "$author" ] || continue
  if printf '%s' "$author" | grep -qiE "$agent"; then
    err "commit author '$author' is an agent, not a person (rules.md, «Ветки, коммиты и PR»)"
  fi
done < <(git log --format='%an <%ae>' "$base..$head" | sort -u)

# Anchored to the start of a line so that text about these lines (a rules PR, a how-to) still passes.
traces='^[[:space:]_*]*(co-authored-by:.*('"$agent"'|gpt)|claude-session:|requested by)|generated (with|by) \[?(claude|codex|copilot|chatgpt)|claude\.ai/code|chatgpt\.com/codex'
if git log --format=%B "$base..$head" | grep -qiE "$traces"; then
  err "a commit message carries agent traces (Co-Authored-By, Claude-Session, Generated with …): rewrite it (rules.md, «Ветки, коммиты и PR»)"
fi
if printf '%s\n%s\n' "$title" "$body" | grep -qiE "$traces"; then
  err "the PR title or text carries agent traces (Generated with …, Requested by …, a session link): edit them out (rules.md, «Ветки, коммиты и PR»)"
fi

if [ "$errors" -gt 0 ]; then
  echo "check-pr: $errors problem(s)" >&2
  exit 1
fi
echo "check-pr: branch, title, authors and messages follow the rules"
