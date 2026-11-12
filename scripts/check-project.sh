#!/usr/bin/env bash
# shellcheck disable=SC2016 # backticks in patterns and in the edits are literal
# Usage: check-project.sh [<project dir>]
#
# Checks a project repo against the items of the README section «Что должно быть в проекте»
# marked «скрипт»: files in place, copies equal to templates/, workflow rules, lines of the
# «Проект» section. Prints every problem as an ::error:: line and exits 1 when there is any.
# Items marked «вручную» (repo settings, the agent's instruction, the tracker, the bot) stay with
# the agent (procedures/checklist.md). The playbook is the clone this script lives in, or PLAYBOOK.
# Needs git, jq and yq (either the Go or the Python one: both are on GitHub runners or easy to get).
set -euo pipefail

dir=${1:-.}
[ -d "$dir" ] || {
  echo "usage: $0 [<project dir>]" >&2
  exit 2
}
dir=$(cd "$dir" && pwd -P)
playbook=${PLAYBOOK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
tpl=$playbook/templates

for tool in jq yq; do
  command -v "$tool" >/dev/null || {
    echo "::error::check-project needs $tool"
    exit 2
  }
done

errors=0
err() {
  echo "::error::$1"
  errors=$((errors + 1))
}

# The on: of a workflow as an object; YAML 1.1 parsers read the key on as true.
triggers() {
  jq -c '.on // .["true"] // {} | if type == "string" then {(.): {}} elif type == "array" then map({(.): {}}) | add // {} else . end'
}

yaml_json() {
  if yq --version 2>&1 | grep -q mikefarah; then yq -o=json '.' "$1"; else yq '.' "$1"; fi
}

same() {
  local file=$1 want=$2
  if [ ! -f "$dir/$file" ]; then
    err "$file is missing (copy it from playbook $want)"
  elif ! cmp -s "$dir/$file" "$playbook/$want"; then
    err "$file differs from playbook $want: replace it with the template"
  fi
}

executable() {
  [ ! -f "$dir/$1" ] || [ -x "$dir/$1" ] || err "$1 is not executable (chmod +x, git add --chmod=+x)"
}

agents=$dir/AGENTS.md
section() {
  awk -v want="$1" '/^#+ /{on = ($0 == want); next} on' "$agents"
}

# AGENTS.md: the shared block, the key and the author.
if [ ! -f "$agents" ]; then
  err "AGENTS.md is missing"
  agents=/dev/null
else
  "$playbook/scripts/sync-rules.sh" --check "$dir" >/dev/null 2>&1 ||
    err "the shared block, docs/playbook/ or .githooks/agent-guard.sh differ from the playbook: run make sync-rules"
  grep -qE '^- Ключ проекта: `[^`]+`' "$agents" || err "AGENTS.md has no «Ключ проекта» line with the key in backticks"
  grep -qE '^- Автор коммитов: `[^`]+`' "$agents" || err "AGENTS.md has no «Автор коммитов» line with the author in backticks"
fi
if [ ! -f "$dir/CLAUDE.md" ] || [ "$(cat "$dir/CLAUDE.md")" != @AGENTS.md ]; then
  err "CLAUDE.md must be the one line @AGENTS.md"
fi
for target in sync-rules check-rules hooks; do
  grep -qE "^$target:" "$dir/Makefile" 2>/dev/null || err "Makefile has no $target target (templates/Makefile)"
done

for doc in stack roadmap decisions; do
  [ -f "$dir/docs/$doc.md" ] || err "docs/$doc.md is missing (templates/docs/)"
done
inbox=$(grep -m 1 -E '^- Ящик `/quack`:' "$agents" || true)
if [ -n "$inbox" ] && ! [[ $inbox =~ ящика\ (пока\ )?нет ]]; then
  grep -q 'Просмотрено до №' "$dir/docs/duck-log.md" 2>/dev/null ||
    err "the project has a /quack inbox, but docs/duck-log.md has no «Просмотрено до №N» line"
fi

# The PR template keeps every line of the playbook one.
pr_tpl=.github/pull_request_template.md
if [ ! -f "$dir/$pr_tpl" ]; then
  err "$pr_tpl is missing"
else
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qxF -- "$line" "$dir/$pr_tpl" || err "$pr_tpl lacks the template line: $line"
  done <"$tpl/$pr_tpl"
fi

# Copies of the templates.
same .github/workflows/rules.yml templates/.github/workflows/rules.yml
same .github/workflows/rules-update.yml templates/.github/workflows/rules-update.yml
same .claude/hooks/check-commit.sh templates/.claude/hooks/check-commit.sh
same .githooks/pre-push templates/.githooks/pre-push
same .githooks/commit-msg templates/.githooks/commit-msg
same .codex/rules/agent-guard.rules templates/.codex/rules/agent-guard.rules
for file in .claude/hooks/check-commit.sh .githooks/pre-push .githooks/commit-msg; do executable "$file"; done

# Agent settings may carry more than the template, but not less.
json_subset() {
  local file=$1 query=$2 what=$3
  if [ ! -f "$dir/$file" ]; then
    err "$file is missing (templates/$file)"
    return
  fi
  local missing
  if ! missing=$(jq -rn --slurpfile want "$tpl/$file" --slurpfile have "$dir/$file" \
    "[\$want[0] | $query] - [\$have[0] | $query] | .[]" 2>/dev/null); then
    err "$file is not valid JSON"
    return
  fi
  while IFS= read -r item; do
    [ -z "$item" ] || err "$file lacks the $what from the template: $item"
  done <<<"$missing"
}
json_subset .claude/settings.json '.permissions.deny[]?' "deny rule"
json_subset .claude/settings.json '.hooks.PreToolUse[]?.hooks[]?.command' "hook"
json_subset .codex/hooks.json '.hooks.PreToolUse[]?.hooks[]?.command' "hook"

# The «Защиты» line names the agent hooks that are in the repo.
protection=$(grep -m 1 -E '^- Защиты:' "$agents" || true)
if [ -z "$protection" ]; then
  err "AGENTS.md has no «Защиты» line (templates/AGENTS.md)"
else
  for agent_dir in .claude .codex; do
    if [ -d "$dir/$agent_dir" ] && [[ $protection != *"$agent_dir/"* ]]; then
      err "the «Защиты» line does not name $agent_dir/, which is in the repo"
    elif [ ! -d "$dir/$agent_dir" ] && [[ $protection == *"$agent_dir/"* ]]; then
      err "the «Защиты» line names $agent_dir/, which is not in the repo"
    fi
  done
fi

# Every workflow: permissions on top and timeout-minutes on every job.
for wf in "$dir"/.github/workflows/*.yml "$dir"/.github/workflows/*.yaml; do
  [ -f "$wf" ] || continue
  name=.github/workflows/$(basename "$wf")
  if ! json=$(yaml_json "$wf" 2>/dev/null); then
    err "$name is not valid YAML"
    continue
  fi
  jq -e 'has("permissions")' <<<"$json" >/dev/null || err "$name has no top-level permissions:"
  while IFS= read -r job; do
    [ -z "$job" ] || err "$name: job $job has no timeout-minutes"
  done < <(jq -r '.jobs // {} | to_entries[] | select(.value | has("timeout-minutes") or has("uses") | not) | .key' <<<"$json")
done

# CI: quick checks are steps of the job changes, heavy jobs wait for it.
ci=$dir/.github/workflows/ci.yml
if [ ! -f "$ci" ]; then
  err ".github/workflows/ci.yml is missing (templates/.github/workflows/ci.yml)"
elif json=$(yaml_json "$ci" 2>/dev/null); then
  if ! jq -e '.jobs.changes' <<<"$json" >/dev/null; then
    err "ci.yml has no job changes (README playbook, «CI не гоняем на документах»)"
  else
    step_if() { jq -r --arg re "$1" '[.jobs.changes.steps[]? | select((.run // "") | test($re)) | .if // ""] | first // "none"' <<<"$json"; }
    [ "$(step_if 'gitleaks git')" != none ] || err "ci.yml: job changes has no gitleaks step"
    [ "$(step_if 'make check-rules')" != none ] || err "ci.yml: job changes has no make check-rules step"
    case $(step_if 'check-pr\.sh') in
      none) err "ci.yml: job changes has no check-pr.sh step" ;;
      '') ;;
      *) err "ci.yml: the check-pr.sh step must have no if: it runs on every CI event, rules.yml checks only edits of the PR text" ;;
    esac
    jq -e '.jobs.changes.if // "" | test("!\\s*github\\.event\\.pull_request\\.draft")' <<<"$json" >/dev/null ||
      err "ci.yml: job changes needs if: \${{ !github.event.pull_request.draft }} (CI skips drafts)"
    depth=$(jq -r '[.jobs.changes.steps[]? | select((.with.repository // "") | test("/playbook$")) | .with["fetch-depth"] // "none"] | first // "missing"' <<<"$json")
    case $depth in
      0) ;;
      missing) err "ci.yml: job changes does not check out the playbook" ;;
      *) err "ci.yml: the playbook checkout in job changes needs fetch-depth: 0" ;;
    esac
  fi
  on=$(triggers <<<"$json")
  jq -e 'has("push")' <<<"$on" >/dev/null &&
    err "ci.yml runs on push: CI only on PRs, a deploy starts from the push itself (README playbook, «Минуты Actions»)"
  jq -e '["opened", "reopened", "synchronize", "ready_for_review"] - (.pull_request.types // []) | length == 0' <<<"$on" >/dev/null ||
    err "ci.yml: on.pull_request.types needs [opened, reopened, synchronize, ready_for_review] as in the template"
  while IFS= read -r job; do
    [ -z "$job" ] || err "ci.yml: job $job runs gitleaks: make it a step of job changes (a separate job costs a minute)"
  done < <(jq -r '.jobs // {} | to_entries[] | select(.key != "changes") | select([.value.steps[]? | (.run // "") + (.uses // "")] | any(test("gitleaks"))) | .key' <<<"$json")
  # A job waits for changes directly, with the code condition, or through jobs that do.
  while IFS= read -r job; do
    [ -z "$job" ] || err "ci.yml: job $job needs needs: changes and if: needs.changes.outputs.code == 'true'"
  done < <(jq -r '
    (.jobs // {}) as $jobs
    | def needs($j): ($jobs[$j].needs // []) | if type == "string" then [.] else . end;
      def gated($j; $seen):
        if ($seen | index($j)) then false
        elif (needs($j) | index("changes")) then (($jobs[$j].if // "") | test("needs\\.changes\\.outputs\\.code == .true."))
        else (needs($j) | length > 0) and all(needs($j)[]; gated(.; $seen + [$j]))
        end;
    $jobs | keys[] | select(. != "changes") | select(gated(.; []) | not)' <<<"$json")
else
  err "ci.yml is not valid YAML"
fi

# A deploy starts from the push to main and skips documentation; CI no longer runs on main.
# Keep doc_paths in step with is_doc in ci-changes.sh (tests/check-project.sh compares them).
doc_paths='["*.md", ".github/*.md", "docs/**", "shared/**", "openspec/**"]'
for wf in "$dir"/.github/workflows/*.yml "$dir"/.github/workflows/*.yaml; do
  [ -f "$wf" ] || continue
  name=.github/workflows/$(basename "$wf")
  json=$(yaml_json "$wf" 2>/dev/null) || continue
  on=$(triggers <<<"$json")
  jq -e '.workflow_run.workflows // [] | index("CI")' <<<"$on" >/dev/null &&
    err "$name waits for CI, which no longer runs on main: start it on push to main (README playbook, «Минуты Actions»)"
  if ! jq -e 'has("workflow_run")' <<<"$on" >/dev/null; then
    while IFS= read -r job; do
      [ -z "$job" ] || err "$name: job $job checks workflow_run, which never starts it now: drop that if (README playbook, «Деплой»)"
    done < <(jq -r '.jobs // {} | to_entries[] | select((.value.if // "") | tostring | test("workflow_run")) | .key' <<<"$json")
  fi
  jq -e 'has("push") and ((.push // {}).branches // ["main"] | index("main"))' <<<"$on" >/dev/null || continue
  if jq -e '.push // {} | has("paths") or has("paths-ignore") | not' <<<"$on" >/dev/null; then
    err "$name runs on every push to main: add paths-ignore for documentation (README playbook, «Минуты Actions»)"
  fi
  while IFS= read -r path; do
    [ -z "$path" ] || err "$name: paths-ignore $path is not documentation by ci-changes.sh"
  done < <(jq -r --argjson docs "$doc_paths" '((.push // {})["paths-ignore"] // []) - $docs | .[]' <<<"$on")
done

# «Агент может без вопроса»: present, every item with its mode.
if ! grep -qx '### Агент может без вопроса' "$agents"; then
  err "AGENTS.md has no «### Агент может без вопроса» subsection (it may say «Пока пусто»)"
else
  while IFS= read -r item; do
    [ -z "$item" ] || err "«Агент может без вопроса»: no mode \`наблюдаю\` or \`сам\` in: $item"
  done < <(section '### Агент может без вопроса' | grep -E '^- ' | grep -vE '`(наблюдаю|сам)`|^- Пока ' || true)
fi

grep -qE '^- Справочник группы:' "$agents" || err "AGENTS.md has no «Справочник группы» line"
grep -qE '^- Проверка после деплоя:' "$agents" || err "AGENTS.md has no «Проверка после деплоя» line: the main scenario to check after a deploy, or «деплоя нет» (templates/AGENTS.md)"
grep -qE '^- Список playbook сверен: `playbook@[0-9a-f]{7,40}`' "$agents" ||
  err "AGENTS.md has no «Список playbook сверен: \`playbook@<commit>\`» line (procedures/checklist.md)"
grep -qx '## Что умеет и как пользоваться' "$dir/README.md" 2>/dev/null ||
  err "README.md has no section «## Что умеет и как пользоваться»"

# The shared branch, unless the project said it does not keep one.
if ! grep -qE '^- Ветку `?shared`? не ведём' "$agents"; then
  [ ! -d "$dir/shared" ] || err "main has a shared/ folder: reviews for participants live in the shared branch"
  if ! git -C "$dir" fetch -q --depth=1 origin shared 2>/dev/null; then
    err "no shared branch on origin (README playbook, «Ветка shared»), or origin is unreachable"
  else
    git -C "$dir" cat-file -e FETCH_HEAD:README.md 2>/dev/null || err "the shared branch has no README.md"
    if ! cmp -s <(git -C "$dir" show FETCH_HEAD:.github/workflows/secrets.yml 2>/dev/null) "$tpl/shared/.github/workflows/secrets.yml"; then
      err "the shared branch: .github/workflows/secrets.yml differs from playbook templates/shared/"
    fi
  fi
fi

if [ "$errors" -gt 0 ]; then
  echo "check-project: $errors problem(s); README playbook, «Что должно быть в проекте», says how to fix each" >&2
  exit 1
fi
echo "check-project: every item marked «скрипт» in «Что должно быть в проекте» is in place"
