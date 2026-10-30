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
check "init copies templates" test -f "$proj/CLAUDE.md" -a -f "$proj/docs/duck-log.md" -a -f "$proj/.github/workflows/rules.yml"
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
printf '## Rules\n\n- one\n- two\n- three\n' >"$pb/rules.md"
check_fails "self check fails before sync" "$pb/scripts/sync-rules.sh" --check "$pb"
check "self sync takes uncommitted rules.md" "$pb/scripts/sync-rules.sh" "$pb"
check "self check passes" "$pb/scripts/sync-rules.sh" --check "$pb"
check "self sync does not copy procedures" test ! -e "$pb/docs/playbook"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "all tests passed"
