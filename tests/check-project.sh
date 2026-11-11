#!/usr/bin/env bash
# shellcheck disable=SC2016 # backticks in patterns and in the edits are literal
# Tests for scripts/check-project.sh: a project made by init.sh, filled in, then broken one item at a time.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

failures=0
passes() {
  if "$pb/scripts/check-project.sh" "$proj" >"$work/out" 2>&1; then
    echo "ok   $1"
  else
    echo "FAIL $1" >&2
    cat "$work/out" >&2
    failures=$((failures + 1))
  fi
}
fails() {
  local name=$1 pattern=$2
  if ! "$pb/scripts/check-project.sh" "$proj" >"$work/out" 2>&1 && grep -qF -- "$pattern" "$work/out"; then
    echo "ok   $name"
  else
    echo "FAIL $name (want an error with: $pattern)" >&2
    cat "$work/out" >&2
    failures=$((failures + 1))
  fi
}
# Breaks a file, expects the error, then puts the file back.
broken() {
  local name=$1 file=$2 pattern=$3 edit=$4
  cp -p "$proj/$file" "$work/saved"
  eval "$edit"
  fails "$name" "$pattern"
  cp -p "$work/saved" "$proj/$file"
}
# Changes a file in an allowed way, expects a pass, then puts the file back.
allowed() {
  local name=$1 file=$2 edit=$3
  cp -p "$proj/$file" "$work/saved"
  eval "$edit"
  passes "$name"
  cp -p "$work/saved" "$proj/$file"
}

pb=$work/playbook
mkdir -p "$pb"
cp -R "$root/scripts" "$root/templates" "$root/procedures" "$pb/"
cp "$root/init.sh" "$root/rules.md" "$pb/"
git -C "$pb" init -q -b main
git -C "$pb" add -A
git -C "$pb" commit -q -m init

proj=$work/project
"$pb/init.sh" "$proj" Demo >/dev/null
sed -i.tmp -E \
  -e 's/^- Ключ проекта: .*/- Ключ проекта: `demo` — в именах веток./' \
  -e 's/^- Автор коммитов: .*/- Автор коммитов: `Owner <1+owner@users.noreply.github.com>`./' \
  -e 's/^- Ящик `\/quack`: .*/- Ящик `\/quack`: ящика нет./' \
  -e 's/^- Список playbook сверен: .*/- Список playbook сверен: `playbook@0123456`./' \
  -e 's/^- Проверка после деплоя: .*/- Проверка после деплоя: деплоя нет./' \
  "$proj/AGENTS.md"
rm -f "$proj/AGENTS.md.tmp"
printf -- '- Ветку shared не ведём: разборов нет.\n' >>"$proj/AGENTS.md"
printf '# Demo\n\n## Что умеет и как пользоваться\n\n- ничего\n' >"$proj/README.md"

passes "a filled-in project from init.sh passes"

rm "$proj/CLAUDE.md"
fails "a missing CLAUDE.md fails" "CLAUDE.md must be the one line"
printf '@AGENTS.md\n' >"$proj/CLAUDE.md"
broken "a CLAUDE.md with more lines fails" CLAUDE.md "CLAUDE.md must be the one line" 'echo more >>"$proj/CLAUDE.md"'
broken "a hand-edited shared block fails" AGENTS.md "run make sync-rules" \
  'sed -i.tmp "s/^## Общие правила$/## Общие правила!/" "$proj/AGENTS.md"'
broken "a key without backticks fails" AGENTS.md "«Ключ проекта»" 'sed -i.tmp "s/^- Ключ проекта: .*/- Ключ проекта: demo/" "$proj/AGENTS.md"'
broken "a missing author line fails" AGENTS.md "«Автор коммитов»" 'sed -i.tmp "/^- Автор коммитов:/d" "$proj/AGENTS.md"'
broken "a Makefile without hooks fails" Makefile "no hooks target" 'sed -i.tmp "s/^hooks:/x:/" "$proj/Makefile"'
mv "$proj/docs/roadmap.md" "$work/roadmap.md"
fails "a missing roadmap fails" "docs/roadmap.md is missing"
mv "$work/roadmap.md" "$proj/docs/roadmap.md"

broken "an inbox without the duck-log line fails" AGENTS.md "«Просмотрено до №N»" \
  'sed -i.tmp "s/^- Ящик .*/- Ящик \`\/quack\`: эта репа./" "$proj/AGENTS.md"; rm "$proj/docs/duck-log.md"'
cp "$pb/templates/docs/duck-log.md" "$proj/docs/duck-log.md"
sed -i.tmp 's/^- Ящик .*/- Ящик `\/quack`: эта репа./' "$proj/AGENTS.md"
passes "an inbox with docs/duck-log.md passes"
sed -i.tmp 's/^- Ящик .*/- Ящик `\/quack`: ящика пока нет./' "$proj/AGENTS.md"
rm "$proj/docs/duck-log.md"
passes "«ящика пока нет» needs no duck-log"

broken "a PR template without a template line fails" .github/pull_request_template.md "lacks the template line" \
  'sed -i.tmp "/^README:/d" "$proj/.github/pull_request_template.md"'
allowed "a PR template with lines of its own passes" .github/pull_request_template.md \
  'echo "- [ ] project line" >>"$proj/.github/pull_request_template.md"'

broken "an edited rules.yml fails" .github/workflows/rules.yml "rules.yml differs" 'echo "# x" >>"$proj/.github/workflows/rules.yml"'
broken "an old rules-update.yml fails" .github/workflows/rules-update.yml "rules-update.yml differs" \
  'sed -i.tmp "/check-project.sh/d" "$proj/.github/workflows/rules-update.yml"; rm "$proj/.github/workflows/rules-update.yml.tmp"'
broken "a git hook that is not executable fails" .githooks/pre-push "pre-push is not executable" 'chmod -x "$proj/.githooks/pre-push"'
broken "an edited commit-msg hook fails" .githooks/commit-msg "commit-msg differs" 'echo "# x" >>"$proj/.githooks/commit-msg"'
broken "an edited Codex rules file fails" .codex/rules/agent-guard.rules "agent-guard.rules differs" 'echo "# x" >>"$proj/.codex/rules/agent-guard.rules"'

broken "settings.json without a deny rule fails" .claude/settings.json 'deny rule from the template: Bash(rsync:*)' \
  'jq "del(.permissions.deny[] | select(. == \"Bash(rsync:*)\"))" "$work/saved" >"$proj/.claude/settings.json"'
allowed "settings.json with more rules passes" .claude/settings.json \
  'jq ".permissions.deny += [\"Bash(curl:*)\"] | .model = \"x\"" "$work/saved" >"$proj/.claude/settings.json"'
broken "settings.json without the hook fails" .claude/settings.json "hook from the template" \
  'jq "del(.hooks)" "$work/saved" >"$proj/.claude/settings.json"'
broken "settings.json that is not JSON fails" .claude/settings.json "is not valid JSON" 'echo "{" >"$proj/.claude/settings.json"'
broken "Codex hooks.json without the hook fails" .codex/hooks.json "hook from the template" \
  'jq "del(.hooks)" "$work/saved" >"$proj/.codex/hooks.json"'

broken "«Защиты» without .codex/ fails" AGENTS.md "does not name .codex/" 'sed -i.tmp "s/, Codex (\`.codex\/\`)//" "$proj/AGENTS.md"'
mv "$proj/.codex" "$work/codex"
fails "«Защиты» naming a missing .codex/ fails" "names .codex/, which is not in the repo"
mv "$work/codex" "$proj/.codex"
broken "a missing «Защиты» line fails" AGENTS.md "no «Защиты» line" 'sed -i.tmp "/^- Защиты:/d" "$proj/AGENTS.md"'

ci=.github/workflows/ci.yml
broken "a workflow without permissions fails" "$ci" "ci.yml has no top-level permissions" \
  'sed -i.tmp "/^permissions:/,/^$/d" "$proj/$ci"'
broken "a job without timeout-minutes fails" "$ci" "job check has no timeout-minutes" \
  'sed -i.tmp "/timeout-minutes: 30/d" "$proj/$ci"'
broken "a heavy job without the code condition fails" "$ci" "job check needs needs: changes" \
  'sed -i.tmp "/if: needs.changes.outputs.code/d" "$proj/$ci"'
broken "a heavy job without needs fails" "$ci" "job check needs needs: changes" \
  'sed -i.tmp "/^    needs: changes/d" "$proj/$ci"'
broken "check-rules on every push fails" "$ci" "make check-rules step needs if" \
  'sed -i.tmp "/if: github.event_name == .pull_request./d" "$proj/$ci"'
broken "check-pr on every event fails" "$ci" "check-pr.sh step needs if" \
  'sed -i.tmp "/if: github.event.action == .synchronize./d" "$proj/$ci"'
broken "a shallow playbook checkout fails" "$ci" "needs fetch-depth: 0" \
  'awk "/path: .playbook/{print; getline; print \"          fetch-depth: 1\"; next} 1" "$work/saved" >"$proj/$ci"'
broken "a CI without gitleaks fails" "$ci" "no gitleaks step" 'sed -i.tmp "s/gitleaks git/echo/" "$proj/$ci"'
cat >>"$proj/$ci" <<'EOF'

  e2e:
    needs: check
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: make e2e
EOF
passes "a job behind a gated job passes"
cat >>"$proj/$ci" <<'EOF'

  secrets:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: gitleaks/gitleaks-action@v2
EOF
fails "a separate gitleaks job fails" "job secrets runs gitleaks"
fails "a separate job without needs fails" "job secrets needs needs: changes"
cp "$pb/templates/$ci" "$proj/$ci"
printf 'jobs:\n  x:\n    runs-on: ubuntu-latest\n    steps: []\n' >"$proj/.github/workflows/deploy.yml"
fails "another workflow is checked too" "deploy.yml has no top-level permissions"
fails "another workflow's jobs are checked too" "deploy.yml: job x has no timeout-minutes"
rm "$proj/.github/workflows/deploy.yml"

broken "an item without a mode fails" AGENTS.md "no mode" \
  'sed -i.tmp "s/^### Агент может без вопроса$/&\n\n- обновлять зависимости/" "$proj/AGENTS.md"'
allowed "an item with a mode passes" AGENTS.md \
  'sed -i.tmp "s/^### Агент может без вопроса$/&\n\n- обновлять зависимости — \`сам\`/" "$proj/AGENTS.md"'
broken "a missing «Агент может без вопроса» fails" AGENTS.md "no «### Агент может без вопроса»" \
  'sed -i.tmp "s/^### Агент может без вопроса$/### Другое/" "$proj/AGENTS.md"'
broken "a missing handbook line fails" AGENTS.md "«Справочник группы»" 'sed -i.tmp "/^- Справочник группы:/d" "$proj/AGENTS.md"'
broken "a missing deploy check line fails" AGENTS.md "«Проверка после деплоя»" 'sed -i.tmp "/^- Проверка после деплоя:/d" "$proj/AGENTS.md"'
broken "a missing checklist line fails" AGENTS.md "«Список playbook сверен" 'sed -i.tmp "/^- Список playbook сверен:/d" "$proj/AGENTS.md"'
broken "a README without «Что умеет» fails" README.md "«## Что умеет и как пользоваться»" 'printf "# Demo\n" >"$proj/README.md"'

# The shared branch: without the refusal line the project needs it on origin.
sed -i.tmp '/^- Ветку shared не ведём/d' "$proj/AGENTS.md"
git -C "$proj" init -q -b main
fails "no origin means no shared branch" "no shared branch on origin"
git init -q --bare "$work/origin.git"
git -C "$proj" remote add origin "$work/origin.git"
fails "no shared branch on origin fails" "no shared branch on origin"
shared=$work/shared
git init -q -b shared "$shared"
cp -R "$pb/templates/shared/." "$shared/"
git -C "$shared" add -A
git -C "$shared" commit -q -m shared
git -C "$shared" push -q "$work/origin.git" shared
passes "a shared branch from the template passes"
mkdir "$proj/shared"
fails "a shared/ folder in main fails" "main has a shared/ folder"
rmdir "$proj/shared"
echo "# x" >>"$shared/.github/workflows/secrets.yml"
git -C "$shared" commit -q -am edit
git -C "$shared" push -q "$work/origin.git" shared
fails "an edited secrets.yml in shared fails" "secrets.yml differs"
git -C "$shared" rm -q README.md .github/workflows/secrets.yml
git -C "$shared" commit -q -m empty
git -C "$shared" push -q "$work/origin.git" shared
fails "a shared branch without README.md fails" "the shared branch has no README.md"
printf -- '- Ветку `shared` не ведём: разборов нет.\n' >>"$proj/AGENTS.md"
passes "the refusal line skips the shared branch"

rm "$proj/AGENTS.md"
fails "a missing AGENTS.md fails" "AGENTS.md is missing"
out=$("$pb/scripts/check-project.sh" "$proj" 2>&1 || true)
if [ "$(grep -c '^::error::' <<<"$out")" -gt 3 ]; then
  echo "ok   every problem is printed, not only the first"
else
  echo "FAIL every problem is printed, not only the first" >&2
  failures=$((failures + 1))
fi
if "$pb/scripts/check-project.sh" "$work/none" >/dev/null 2>&1; then
  echo "FAIL a missing directory is an error" >&2
  failures=$((failures + 1))
else
  echo "ok   a missing directory is an error"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "all check-project tests passed"
