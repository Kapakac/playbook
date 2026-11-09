#!/usr/bin/env bash
# Usage: check-pr.sh [--key <project key>] <base> <head>
#
# Run inside the project repo on a pull request. Checks what a machine can check of the shared
# rules («Ветки, коммиты и PR»): the branch name, the PR title, the author of every commit
# between <base> and <head>, and agent traces in commit messages, the title and the PR text.
# The branch, title and text come from PR_BRANCH, PR_TITLE and PR_BODY; the key is read from
# AGENTS.md when --key is not given. Errors go out as ::error:: lines; exit code 1 when any.
# A branch imposed by the agent's environment (claude/...) is allowed with a warning.
# It also fails when the «Список playbook сверен» commit in AGENTS.md is missing or behind the
# playbook clone this script lives in (or PLAYBOOK): the README section «Что должно быть в
# проекте», templates/ (except the PR template and templates/openspec/) or procedures/no-repo-agent.md changed since
# (procedures/checklist.md).
# It also fails when the PR text lacks a filled «README:» line from the PR template: «README:
# обновлён …» or «README: не нужно, потому что <reason>».
# Rules auto-update PRs (*-rules-auto branches) and the playbook repo itself skip these two checks.
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
  err "title '$title' does not start with '$key: ' or '$key-<task>: ' (prepare-pr.md, step 10)"
fi

checklist_section() {
  git -C "$playbook" show "$1:README.md" 2>/dev/null |
    awk '/^## /{on = ($0 == "## Что должно быть в проекте")} on'
}

playbook=${PLAYBOOK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
here=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
here=$(cd "$here" && pwd -P)
checklist="go through docs/playbook/checklist.md and set the line to the current playbook commit"
skip_project=0
if [[ $branch == *-rules-auto ]] || [ "$here" = "$(cd "$playbook" && pwd -P)" ]; then
  skip_project=1
fi
if [ "$skip_project" = 0 ]; then
  # shellcheck disable=SC2016
  checked=$(sed -nE 's/^- Список playbook сверен: `playbook@([0-9a-f]{7,40})`.*/\1/p' AGENTS.md 2>/dev/null | head -n 1)
  if [ -z "$checked" ]; then
    err "AGENTS.md has no «Список playbook сверен: \`playbook@<commit>\`» line: $checklist"
  elif ! git -C "$playbook" rev-parse -q --verify "$checked^{commit}" >/dev/null; then
    err "«Список playbook сверен» names playbook@$checked, which the playbook clone does not have: $checklist"
  else
    changed=()
    if [ "$(checklist_section "$checked")" != "$(checklist_section HEAD)" ]; then
      changed+=("README «Что должно быть в проекте»")
    fi
    # The PR template reaches projects through update-rules.sh, and templates/openspec/ is read from the playbook
    # when a spec is written (procedures/spec.md), so neither alone is a reason to re-check the list.
    if ! git -C "$playbook" diff --quiet "$checked" HEAD -- templates ':!templates/.github/pull_request_template.md' ':!templates/openspec'; then
      changed+=("templates/")
    fi
    if ! git -C "$playbook" diff --quiet "$checked" HEAD -- procedures/no-repo-agent.md; then
      changed+=("procedures/no-repo-agent.md")
    fi
    if [ ${#changed[@]} -gt 0 ]; then
      latest=$(git -C "$playbook" rev-parse --short HEAD)
      list=$(printf '%s, ' "${changed[@]}")
      err "«Список playbook сверен» is playbook@$checked, but the playbook changed ${list%, } since then (now playbook@$latest): $checklist"
    fi
  fi
fi

readme="fill the PR template line «README: обновлён» or «README: не нужно, потому что <reason>» (prepare-pr.md, step 10)"
if [ "$skip_project" = 0 ]; then
  line=$(printf '%s\n' "$body" | tr -d '\r' | grep -m 1 -E '^[[:space:]>*_-]*README[*_]*:' || true)
  value=$(printf '%s' "$line" | sed -E 's/^[[:space:]>*_-]*README[*_]*:[*_[:space:]]*//; s/[[:space:]*_]*$//')
  reason=$(printf '%s' "$value" | sed -E 's/^(Н|н)е нужно//; s/^([[:space:],:;.-]|—|–)*//; s/^потому что//; s/^([[:space:],:;.-]|—|–|…)*//')
  if [ -z "$line" ]; then
    err "the PR text has no «README:» line: $readme"
  elif [[ $value =~ ^(О|о)бновл(ё|е)н[[:space:]]*/[[:space:]]*(Н|н)е\ нужно ]]; then
    err "the «README:» line is left as in the template: $readme"
  elif [[ $value =~ ^(О|о)бновл(ё|е)н ]]; then
    :
  elif [[ $value =~ ^(Н|н)е\ нужно ]] && [ -n "$reason" ]; then
    :
  elif [[ $value =~ ^(Н|н)е\ нужно ]]; then
    err "the «README:» line says «не нужно» without a reason: $readme"
  else
    err "the «README:» line says '$value': $readme"
  fi
fi

agent='anthropic\.com|openai\.com|claude|codex|copilot'
while IFS= read -r author; do
  [ -n "$author" ] || continue
  if printf '%s' "$author" | grep -qiE "$agent"; then
    err "commit author '$author' is an agent, not a person (rules.md, «Ветки, коммиты и PR»)"
  fi
done < <(git log --format='%an <%ae>' "$base..$head" | sort -u)

# The trace expressions live in agent-guard.sh, which the git commit-msg hook and the agent hooks use too.
guard=$(dirname "${BASH_SOURCE[0]}")/agent-guard.sh
if ! git log --format=%B "$base..$head" | "$guard" text 2>/dev/null; then
  err "a commit message carries agent traces (Co-Authored-By, Claude-Session, Generated with …): rewrite it (rules.md, «Ветки, коммиты и PR»)"
fi
if ! printf '%s\n%s\n' "$title" "$body" | "$guard" text 2>/dev/null; then
  err "the PR title or text carries agent traces (Generated with …, Requested by …, a session link): edit them out (rules.md, «Ветки, коммиты и PR»)"
fi

if [ "$errors" -gt 0 ]; then
  echo "check-pr: $errors problem(s)" >&2
  exit 1
fi
echo "check-pr: branch, title, authors, messages and the PR text follow the rules"
