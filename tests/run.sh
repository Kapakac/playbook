#!/usr/bin/env bash
# Tests for init.sh and scripts/sync-rules.sh against a throwaway playbook clone.
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
  -a -f "$proj/.github/workflows/rules-update.yml" -a -f "$proj/.github/workflows/ci.yml"
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

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "all tests passed"
