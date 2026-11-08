#!/usr/bin/env bash
# Tests for init.sh and the scripts against a throwaway playbook clone.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GITHUB_ACTIONS

failures=0
pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1" >&2
  failures=$((failures + 1))
}
check() {
  local name=$1
  shift
  if "$@" >"$work/out" 2>&1; then pass "$name"; else fail "$name"; cat "$work/out" >&2; fi
}
check_output() {
  local name=$1 want=$2 pattern=$3
  shift 3
  if "$@" >"$work/out" 2>&1 && { grep -q "$pattern" "$work/out"; [ $? = "$want" ]; }; then
    pass "$name"
  else
    fail "$name"
    cat "$work/out" >&2
  fi
}
check_fails_with() {
  local name=$1 pattern=$2
  shift 2
  if ! "$@" >"$work/out" 2>&1 && grep -q "$pattern" "$work/out"; then pass "$name"; else fail "$name"; cat "$work/out" >&2; fi
}
check_fails() {
  local name=$1
  shift
  if "$@" >"$work/out" 2>&1; then fail "$name (expected failure)"; cat "$work/out" >&2; else pass "$name"; fi
}

pb=$work/playbook
mkdir -p "$pb/scripts" "$pb/procedures"
cp -R "$root/templates" "$pb/templates"
cp "$root/init.sh" "$pb/init.sh"
cp "$root/scripts/sync-rules.sh" "$pb/scripts/sync-rules.sh"
cp "$root/scripts/update-rules.sh" "$pb/scripts/update-rules.sh"
cp "$root/scripts/agent-guard.sh" "$pb/scripts/agent-guard.sh"
printf '## Rules\n\n- one\n' >"$pb/rules.md"
printf '# A\n' >"$pb/procedures/a.md"
printf '# B\n' >"$pb/procedures/b.md"
git -C "$pb" init -q -b main
git -C "$pb" add -A
git -C "$pb" commit -q -m init
sha1=$(git -C "$pb" rev-parse HEAD)

proj=$work/project
sync() { "$pb/scripts/sync-rules.sh" "$proj"; }
verify() { "$pb/scripts/sync-rules.sh" --check "$proj"; }
block() { awk '/^<!-- playbook:begin /{on=1; next} /^<!-- playbook:end -->$/{on=0} on' "$proj/AGENTS.md"; }

check "init creates a project" "$pb/init.sh" "$proj" 'Name & a/b'
check "init copies templates" test -f "$proj/CLAUDE.md" -a -f "$proj/docs/duck-log.md" -a -f "$proj/.github/workflows/rules.yml" \
  -a -f "$proj/.github/workflows/rules-update.yml" -a -f "$proj/.github/workflows/ci.yml" \
  -a -f "$proj/.claude/settings.json" -a -x "$proj/.claude/hooks/check-commit.sh"
check "init copies the git hooks and the Codex files" test -x "$proj/.githooks/pre-push" -a -x "$proj/.githooks/commit-msg" \
  -a -f "$proj/.codex/hooks.json" -a -f "$proj/.codex/rules/agent-guard.rules"
check "init puts the guard next to the git hooks" test -x "$proj/.githooks/agent-guard.sh"
check "the guard copy equals the playbook script" cmp "$proj/.githooks/agent-guard.sh" "$pb/scripts/agent-guard.sh"
check "init skips the shared branch template" test ! -e "$proj/shared"
check "CLAUDE.md imports AGENTS.md" grep -qx '@AGENTS.md' "$proj/CLAUDE.md"
check "project name substituted literally" grep -qx '# Name & a/b' "$proj/AGENTS.md"
check "block equals rules.md" diff <(block) "$pb/rules.md"
check "marker records the commit" grep -q "playbook@$sha1 " "$proj/AGENTS.md"
check "procedures copied" diff -r "$proj/docs/playbook" "$pb/procedures"
check "check passes after init" verify

echo "local note" >"$proj/docs/stack.md"
check "init does not overwrite" "$pb/init.sh" "$proj" other
check "existing file kept" grep -qx 'local note' "$proj/docs/stack.md"

cp "$proj/AGENTS.md" "$work/agents.bak"
sed -i.tmp 's/^- one$/- one, edited/' "$proj/AGENTS.md" && rm -f "$proj/AGENTS.md.tmp"
check_fails "check fails on a hand-edited block" verify
cp "$work/agents.bak" "$proj/AGENTS.md"

echo extra >>"$proj/docs/playbook/a.md"
check_fails "check fails on an edited procedure copy" verify
cp "$pb/procedures/a.md" "$proj/docs/playbook/a.md"
rm "$proj/docs/playbook/b.md"
check_fails "check fails on a missing procedure copy" verify
cp "$pb/procedures/b.md" "$proj/docs/playbook/b.md"
echo x >"$proj/docs/playbook/c.md"
check_fails "check fails on an extra file in docs/playbook" verify
rm "$proj/docs/playbook/c.md"
echo '# edited' >>"$proj/.githooks/agent-guard.sh"
check_fails "check fails on an edited guard copy" verify
cp "$pb/scripts/agent-guard.sh" "$proj/.githooks/agent-guard.sh"
chmod -x "$proj/.githooks/agent-guard.sh"
check_fails "check fails on a guard copy that is not executable" verify
rm "$proj/.githooks/agent-guard.sh"
check_output "check only warns about a missing guard copy" 0 "agent-guard.sh is missing" verify
echo '# dirty' >>"$pb/scripts/agent-guard.sh"
check_fails "sync refuses a dirty guard in the playbook" sync
git -C "$pb" checkout -q -- scripts/agent-guard.sh
check "sync puts the guard copy back" sync
check "the guard copy is executable again" test -x "$proj/.githooks/agent-guard.sh"
check "check passes again" verify

printf 'project text after the block\n' >>"$proj/AGENTS.md"
printf '## Rules\n\n- one\n- two\n' >"$pb/rules.md"
check_fails "sync refuses a dirty playbook" sync
git -C "$pb" commit -q -am "more rules"
sha2=$(git -C "$pb" rev-parse HEAD)
check_output "check warns when the playbook moved on" 0 "newer rules" verify
check "sync updates the block" sync
check "new block equals rules.md" diff <(block) "$pb/rules.md"
check "marker records the new commit" grep -q "playbook@$sha2 " "$proj/AGENTS.md"
check "text outside the block kept" grep -qx 'project text after the block' "$proj/AGENTS.md"
check "project section kept" grep -qx '## Проект' "$proj/AGENTS.md"
check_output "no warning after sync" 1 "newer rules" verify

printf '## Rules\n\n- no final newline' >"$pb/rules.md"
printf '# Новая\n' >"$pb/procedures/новая.md"
mkdir -p "$pb/procedures/sub"
printf 'nested\n' >"$pb/procedures/sub/x.md"
git -C "$pb" add -A
git -C "$pb" commit -q -m "edge cases"
sha3=$(git -C "$pb" rev-parse HEAD)
check "sync handles no final newline, non-ASCII names and subdirectories" sync
check "check passes after the edge-case sync" verify
check "non-ASCII procedure copied" diff "$proj/docs/playbook/новая.md" "$pb/procedures/новая.md"
check "subdirectories are not copied" test ! -e "$proj/docs/playbook/sub"
check "end marker on its own line" grep -qx '<!-- playbook:end -->' "$proj/AGENTS.md"

git -C "$pb" checkout -q "$sha2"
check_output "check warns when the clone is older than the marker" 0 "does not contain $sha3" verify
git -C "$pb" checkout -q main

echo x >"$proj/docs/playbook/old.md"
check_output "sync warns about a stale copy" 0 "old.md is not in the playbook" sync
check "sync does not delete the stale copy" test -f "$proj/docs/playbook/old.md"
rm "$proj/docs/playbook/old.md"

printf '# Other\n' >"$work/agents-no-markers.md"
mkdir -p "$work/nomarkers"
cp "$work/agents-no-markers.md" "$work/nomarkers/AGENTS.md"
check_fails "sync fails without markers" "$pb/scripts/sync-rules.sh" "$work/nomarkers"
check_fails "check fails without AGENTS.md" "$pb/scripts/sync-rules.sh" --check "$work"

mkdir -p "$work/never"
cp "$pb/templates/AGENTS.md" "$work/never/AGENTS.md"
check_fails "check fails on a never-synced block" "$pb/scripts/sync-rules.sh" --check "$work/never"

cp "$pb/templates/AGENTS.md" "$pb/AGENTS.md"
check_fails "sync refuses to run on the playbook itself" "$pb/scripts/sync-rules.sh" "$pb"
rm "$pb/AGENTS.md"

git clone -q --bare "$pb" "$work/origin.git"
git -C "$pb" remote add origin "$work/origin.git"
git -C "$pb" fetch -q origin
check_output "no behind warning for an up-to-date clone" 1 "behind origin/main" sync
git clone -q "$work/origin.git" "$work/other"
printf '## Rules\n\n- newer\n' >"$work/other/rules.md"
git -C "$work/other" commit -q -am newer
git -C "$work/other" push -q origin main
check_output "sync warns when the clone is behind origin/main" 0 "behind origin/main" sync
git -C "$pb" remote remove origin

update() { "$pb/scripts/update-rules.sh" "$proj"; }
marker() { sed -nE 's/^<!-- playbook:begin playbook@([0-9a-f]{40}) .*/\1/p' "$proj/AGENTS.md"; }
tpl=$proj/.github/pull_request_template.md
cp "$proj/AGENTS.md" "$work/agents.before"
check_output "update does nothing when the playbook has nothing new" 0 "nothing new" update
check "update leaves AGENTS.md as it was" cmp "$proj/AGENTS.md" "$work/agents.before"

echo readme >"$pb/README.md"
git -C "$pb" add -A
git -C "$pb" commit -q -m "readme only"
check_output "update ignores playbook commits outside the rules" 0 "nothing new" update
check "marker kept after a readme-only commit" test "$(marker)" = "$sha3"

sed -i.tmp 's/^- \[ \] CI зелёный$/- [ ] CI зелёный\
- [ ] project check/' "$tpl" && rm -f "$tpl.tmp"
sed -i.tmp '/^Что нашлось и что исправлено\.$/d' "$tpl" && rm -f "$tpl.tmp"
sed -i.tmp 's/^- \[ \] CI зелёный$/- [ ] CI зелёный\
- [ ] new check/' "$pb/templates/.github/pull_request_template.md"
rm -f "$pb/templates/.github/pull_request_template.md.tmp"
printf '\n## New section\n' >>"$pb/templates/.github/pull_request_template.md"
git -C "$pb" commit -q -am "template lines"
sha4=$(git -C "$pb" rev-parse HEAD)
check "update syncs after a template change" update
check "marker moves to the template commit" test "$(marker)" = "$sha4"
after_ci() { grep -A1 -xF -- '- [ ] CI зелёный' "$tpl" | tail -n 1; }
check "new template line placed after its neighbour" test "$(after_ci)" = '- [ ] new check'
check "project template line kept" grep -qxF -- '- [ ] project check' "$tpl"
check "removed template line not added back" test "$(grep -cxF 'Что нашлось и что исправлено.' "$tpl")" = 0
check "new section appended" test "$(tail -n 2 "$tpl" | head -n 1)" = "" -a "$(tail -n 1 "$tpl")" = "## New section"
cp "$tpl" "$work/tpl.after"
check_output "second update has nothing new" 0 "nothing new" update
check "second update keeps the template" cmp "$tpl" "$work/tpl.after"

printf '## Rules\n\n- updated\n' >"$pb/rules.md"
git -C "$pb" commit -q -am "rules for update"
sha5=$(git -C "$pb" rev-parse HEAD)
rm "$tpl"
check "update syncs new rules" update
check "update moves the marker" test "$(marker)" = "$sha5"
check "update block equals rules.md" diff <(block) "$pb/rules.md"
check "update adds a missing PR template" cmp "$tpl" "$pb/templates/.github/pull_request_template.md"

printf '## Rules\n\n- dirty\n' >"$pb/rules.md"
mkdir -p "$work/dirty"
check_fails "init refuses a dirty playbook" "$pb/init.sh" "$work/dirty" x
check "init copies nothing from a dirty playbook" test ! -e "$work/dirty/AGENTS.md"

repo=$work/changes
git init -q -b main "$repo"
cd_changes() { (cd "$repo" && "$root/scripts/ci-changes.sh" "$@"); }
commit_files() {
  local f
  for f in "$@"; do
    mkdir -p "$repo/$(dirname "$f")"
    echo "$RANDOM" >>"$repo/$f"
  done
  git -C "$repo" add -A
  git -C "$repo" commit -q -m change
}
commit_files main.go
c0=$(git -C "$repo" rev-parse HEAD)
commit_files README.md docs/a.md docs/img.png shared/x.md .github/pull_request_template.md
c1=$(git -C "$repo" rev-parse HEAD)
check_output "docs-only change is not code" 0 '^code=false$' cd_changes "$c0" "$c1"
check_output "head defaults to HEAD" 0 '^code=false$' cd_changes "$c0"
check_output "--code glob overrides docs" 0 '^code=true$' cd_changes --code 'docs/*.png' "$c0"
commit_files tests/fixtures/README.md
check_output "nested .md outside docs is code" 0 '^code=true$' cd_changes "$c1"
c2=$(git -C "$repo" rev-parse HEAD)
commit_files .github/workflows/notes.md
check_output ".md under .github subfolders is code" 0 '^code=true$' cd_changes "$c2"
c3=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" mv main.go docs/main.md
git -C "$repo" commit -q -m rename
check_output "renaming code into docs is code" 0 '^code=true$' cd_changes "$c3"
c4=$(git -C "$repo" rev-parse HEAD)
commit_files "docs/новый файл.md"
check_output "non-ASCII doc names are docs" 0 '^code=false$' cd_changes "$c4"
check_output "zero base is code" 0 '^code=true$' cd_changes 0000000000000000000000000000000000000000
check_output "empty base is code" 0 '^code=true$' cd_changes ''
check_output "unknown base is code" 0 '^code=true$' cd_changes deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
check_output "empty diff is code" 0 '^code=true$' cd_changes HEAD
git -C "$repo" checkout -q -b side "$c4"
commit_files docs/side.md
git -C "$repo" checkout -q main
commit_files app.py
check_output "base moved on with code: only the branch counts" 0 '^code=false$' cd_changes main side
check_fails "no arguments is an error" cd_changes

stub=$work/stub
mkdir -p "$stub"
cat >"$stub/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "GH_TOKEN=$GH_TOKEN" "$@" >"$STUB_LOG"
exit "${STUB_EXIT:-0}"
STUB
chmod +x "$stub/gh"
export STUB_LOG=$work/gh.log
notify() { env -u RULES_NOTIFY_REPO -u RULES_NOTIFY_TOKEN "$@" PATH="$stub:$PATH" "$root/scripts/notify-rules.sh"; }
rm -f "$STUB_LOG"
check_output "notify warns without secrets" 0 '^::warning::' notify
check_output "notify warns without the token" 0 '^::warning::' notify RULES_NOTIFY_REPO=o/r RULES_NOTIFY_TOKEN=
check_output "notify warns without the repo" 0 '^::warning::' notify RULES_NOTIFY_TOKEN=t
check "notify does not call GitHub without both secrets" test ! -e "$STUB_LOG"
check "notify starts the workflow" notify RULES_NOTIFY_REPO=o/r RULES_NOTIFY_TOKEN=t
check "notify posts to the dispatch endpoint on main with the token" diff "$STUB_LOG" <(printf '%s\n' GH_TOKEN=t api --method POST --silent \
  repos/o/r/actions/workflows/rules-update-all.yml/dispatches -f ref=main)
check_fails "notify fails when the call fails" notify STUB_EXIT=1 RULES_NOTIFY_REPO=o/r RULES_NOTIFY_TOKEN=t
notify_failed() { notify "$@" || true; }
check_output "notify reports the failure as an error" 0 '^::error::' notify_failed STUB_EXIT=1 RULES_NOTIFY_REPO=o/r RULES_NOTIFY_TOKEN=t
check_fails "notify rejects arguments" "$root/scripts/notify-rules.sh" x

pr=$work/pr
git init -q -b main "$pr"
# shellcheck disable=SC2016
printf -- '- Ключ проекта: `shop` — в именах веток.\n- Автор коммитов: `Owner <1+owner@users.noreply.github.com>`.\n' >"$pr/AGENTS.md"
git -C "$pr" add -A
git -C "$pr" commit -q -m "init"
pr_base=$(git -C "$pr" rev-parse HEAD)
pr_commit() {
  local message=$1 author=${2:-Owner <1+owner@users.noreply.github.com>}
  echo "$RANDOM" >>"$pr/file"
  git -C "$pr" add -A
  git -C "$pr" commit -q --author="$author" -m "$message"
}
check_pr() { (cd "$pr" && env PLAYBOOK="$pb" "$@" "$root/scripts/check-pr.sh" "$pr_base" HEAD); }
printf '# P\n\n## Что должно быть в проекте\n\n- item\n\n### Что делает агент\n\n- step\n\n## Other\n\n- text\n' >"$pb/README.md"
git -C "$pb" commit -q -m "list" -- README.md
checked=$(git -C "$pb" rev-parse HEAD)
set_checked() {
  sed -i.tmp '/^- Список playbook сверен:/d' "$pr/AGENTS.md" && rm -f "$pr/AGENTS.md.tmp"
  # shellcheck disable=SC2016
  [ -z "$1" ] || printf -- '- Список playbook сверен: `playbook@%s` — сверяли.\n' "$1" >>"$pr/AGENTS.md"
}
pb_change() {
  local file=$1 from=$2 to=$3
  mkdir -p "$pb/$(dirname "$file")"
  if [ -n "$from" ]; then
    sed -i.tmp "s/^$from\$/$to/" "$pb/$file" && rm -f "$pb/$file.tmp"
  else
    echo "$to" >>"$pb/$file"
  fi
  git -C "$pb" add -- "$file"
  git -C "$pb" commit -q -m "change $file" -- "$file"
}
set_checked "$checked"
pr_commit "add a thing"
readme_ok='README: обновлён'
good=(PR_BRANCH=shop-12-cart-69d429 PR_TITLE='shop-12: корзина' PR_BODY=$'## Что изменено\n\nREADME: обновлён')
check "PR with a task number passes" check_pr "${good[@]}"
check "PR outside tasks passes" check_pr PR_BRANCH=shop-cart-69d429 PR_TITLE='shop: корзина' PR_BODY="$readme_ok"
check_output "branch from the environment only warns" 0 '^::warning::branch' check_pr PR_BRANCH=claude/thread-1 PR_TITLE='shop: корзина' PR_BODY="$readme_ok"
check_fails "branch without the key fails" check_pr PR_BRANCH=cart-69d429 PR_TITLE='shop: корзина' PR_BODY="$readme_ok"
check_fails "branch with capitals fails" check_pr PR_BRANCH=shop-Cart PR_TITLE='shop: корзина' PR_BODY="$readme_ok"
check_fails "title without the key fails" check_pr PR_BRANCH=shop-cart-69d429 PR_TITLE='корзина' PR_BODY="$readme_ok"
check_fails "title with another key fails" check_pr PR_BRANCH=shop-cart-69d429 PR_TITLE='shopping: корзина' PR_BODY="$readme_ok"
check_fails "PR text with a session link fails" check_pr PR_BRANCH=shop-cart-69d429 PR_TITLE='shop: корзина' PR_BODY=$'text\n\nhttps://claude.ai/code/session_1'
check_fails "PR text with Generated with fails" check_pr PR_BRANCH=shop-cart-69d429 PR_TITLE='shop: корзина' PR_BODY='🤖 Generated with Claude Code'
check_fails "PR text with a Requested by line fails" check_pr PR_BRANCH=shop-cart-69d429 PR_TITLE='shop: корзина' PR_BODY=$'text\n\n_Requested by @owner_'
check "PR text that only talks about the traces passes" check_pr PR_BRANCH=shop-cart-69d429 PR_TITLE='shop: корзина' PR_BODY=$'Проверка ловит Co-Authored-By, Claude-Session, «Generated with» и «Requested by» в описании.\n\nREADME: обновлён'
readme() { check_pr PR_BRANCH=shop-cart-69d429 PR_TITLE='shop: корзина' PR_BODY="$1"; }
readme_fails() { check_fails_with "$1" "$2" readme "$3"; }
check "README updated with details passes" readme $'## Что изменено\n\n- cart\n\n**README:** обновлён: раздел «Корзина», docs/a/b.md'
check "README updated without ё passes" readme '- README: Обновлен'
check "README not needed with a reason passes" readme $'README: не нужно, потому что поменялись только тесты\r'
check "README not needed with a dash reason passes" readme 'README: Не нужно — только рефакторинг'
readme_fails "a PR text without the README line fails" "has no «README:» line" $'## Что изменено\n\n- cart'
readme_fails "the README line from the template fails" "left as in the template" $'## Что изменено\n\nREADME: обновлён / не нужно, потому что …'
readme_fails "an empty README line fails" "says ''" 'README:'
readme_fails "not needed without a reason fails" "without a reason" 'README: не нужно, потому что …'
readme_fails "not needed with only a comma fails" "without a reason" 'README: не нужно,'
readme_fails "another README answer fails" "says 'потом'" 'README: потом'
readme_fails "README.md mentioned elsewhere does not count" "has no «README:» line" '- [x] Документы актуальны: README.md, docs/'
check "the template line is in the PR template" grep -qx 'README: обновлён / не нужно, потому что …' "$root/templates/.github/pull_request_template.md"
stale=(PR_BRANCH=shop-12-cart-69d429 PR_TITLE='shop-12: корзина' PR_BODY="$readme_ok")
pb_change README.md '- text' '- other text'
check "a README change outside the list passes" check_pr "${stale[@]}"
set_checked "${checked:0:7}"
check "a short checked commit passes" check_pr "${stale[@]}"
pb_change README.md '- step' '- new step'
check_fails_with "a changed list fails" "changed README «Что должно быть в проекте» since" check_pr "${stale[@]}"
check "a rules auto-update PR skips the list and README checks" check_pr PR_BRANCH=shop-rules-auto PR_TITLE='shop: обновить общие правила' PR_BODY=
checked=$(git -C "$pb" rev-parse HEAD)
set_checked "$checked"
check "the list check passes after the line moves" check_pr "${stale[@]}"
pb_change templates/.github/pull_request_template.md '' '## New section'
check "a PR template change alone passes" check_pr "${stale[@]}"
pb_change templates/new.md '' x
check_fails_with "a templates change fails" "changed templates/ since" check_pr "${stale[@]}"
set_checked "$(git -C "$pb" rev-parse HEAD)"
pb_change procedures/no-repo-agent.md '' x
check_fails_with "a no-repo-agent block change fails" "changed procedures/no-repo-agent.md since" check_pr "${stale[@]}"
pb_change procedures/a.md '' x
set_checked "$(git -C "$pb" rev-parse HEAD)"
check "another procedure change passes" check_pr "${stale[@]}"
set_checked deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
check_fails_with "a commit the clone lacks fails" "does not have" check_pr "${stale[@]}"
set_checked ''
check_fails_with "a missing line fails" "has no «Список playbook сверен" check_pr "${stale[@]}"
set_checked "$(git -C "$pb" rev-parse HEAD)"
check_self() { (cd "$root" && env PR_BRANCH=playbook-x PR_TITLE='playbook: x' PR_BODY= "$root/scripts/check-pr.sh" HEAD HEAD); }
check "the playbook repo itself skips the list check" check_self
pr_commit "check the list"
check_pr_key() { (cd "$pr" && env PLAYBOOK="$pb" PR_BRANCH=x-1-y PR_TITLE='x-1: y' PR_BODY="$readme_ok" "$root/scripts/check-pr.sh" --key x "$pr_base" HEAD); }
check "explicit key overrides AGENTS.md" check_pr_key
pr_commit "fix" "Claude <noreply@anthropic.com>"
check_fails "commit by an agent fails" check_pr "${good[@]}"
git -C "$pr" reset -q --hard HEAD~1
pr_commit $'fix\n\nCo-Authored-By: Claude <noreply@anthropic.com>'
check_fails "commit message with an agent co-author fails" check_pr "${good[@]}"
git -C "$pr" reset -q --hard HEAD~1
pr_commit $'fix\n\nClaude-Session: https://example.com/s'
check_fails "commit message with a session line fails" check_pr "${good[@]}"
git -C "$pr" reset -q --hard HEAD~1
pr_commit $'fix\n\nCo-Authored-By: Colleague <2+colleague@users.noreply.github.com>' "Colleague <2+colleague@users.noreply.github.com>"
check "a human co-author and another participant pass" check_pr "${good[@]}"
check_fails "no arguments is an error" "$root/scripts/check-pr.sh"
rm "$pr/AGENTS.md"
check_fails "missing key is an error" check_pr "${good[@]}"

hook=$root/templates/.claude/hooks/check-commit.sh
hook_input() { printf '%s' "$1" | CLAUDE_PROJECT_DIR=$proj "$hook"; }
check "hook lets an ordinary command through" hook_input '{"tool_name":"Bash","tool_input":{"command":"git status"}}'
check "hook lets a clean commit through" hook_input '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"Add cart\""}}'
check_fails "hook blocks a commit with a co-author line" hook_input '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"Add cart\n\nCo-Authored-By: Claude <noreply@anthropic.com>\""}}'
hook_exit() { printf '%s' "$1" | CLAUDE_PROJECT_DIR=$proj "$hook" >/dev/null 2>&1; echo $?; }
check "hook blocks with exit code 2" test "$(hook_exit '{"tool_input":{"command":"git commit -m \"x\n\nClaude-Session: https://e\""}}')" = 2

check "rules.md fits the size limit" "$root/scripts/check-rules-size.sh" "$root/rules.md"
printf 'x\n%.0s' $(seq 61) >"$work/long.md"
check_fails "61 lines fail the size limit" "$root/scripts/check-rules-size.sh" "$work/long.md"
head -c 8193 /dev/zero | tr '\0' x >"$work/big.md"
check_fails "8193 bytes fail the size limit" "$root/scripts/check-rules-size.sh" "$work/big.md"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "all tests passed"
