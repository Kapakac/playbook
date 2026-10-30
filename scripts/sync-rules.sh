#!/usr/bin/env bash
# Usage: sync-rules.sh [--check] [project-dir]
#
# Sync: copies rules.md of this playbook clone into the marked block of <project-dir>/AGENTS.md
# and procedures/*.md into <project-dir>/docs/playbook/, recording the playbook commit in the marker.
# Check: fails if the block or the copies differ from the playbook at the recorded commit,
# warns if the playbook has moved on since.
set -euo pipefail

usage() {
  echo "usage: $0 [--check] [project-dir]" >&2
  exit 2
}

mode=sync
case "${1:-}" in
  --check) mode=check; shift ;;
  -h | --help) usage ;;
esac
[ $# -le 1 ] || usage

playbook=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
project=$(cd "${1:-.}" && pwd -P)
agents=$project/AGENTS.md
copies=$project/docs/playbook
begin_re='^<!-- playbook:begin Kapakac/playbook@[0-9a-f]{40} '
end_line='<!-- playbook:end -->'

self=false
[ "$project" != "$playbook" ] || self=true

fail() {
  echo "sync-rules: $*" >&2
  exit 1
}

warn() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    echo "::warning::$*"
  else
    echo "sync-rules: warning: $*" >&2
  fi
}

pb() {
  git -C "$playbook" "$@"
}

[ -f "$agents" ] || fail "$agents not found: create it from templates/AGENTS.md or run init.sh"
[ "$(grep -cE "$begin_re" "$agents")" = 1 ] && [ "$(grep -cxF "$end_line" "$agents")" = 1 ] \
  || fail "AGENTS.md must contain exactly one begin marker and one end marker (see templates/AGENTS.md)"
begin_n=$(grep -nE "$begin_re" "$agents" | cut -d: -f1)
end_n=$(grep -nxF "$end_line" "$agents" | cut -d: -f1)
[ "$begin_n" -lt "$end_n" ] || fail "the begin marker must come before the end marker in AGENTS.md"

block() {
  awk -v b="$begin_n" -v e="$end_n" 'NR > b && NR < e' "$agents"
}

procedure_names() {
  git -c core.quotePath=false -C "$playbook" ls-tree "$1" procedures/ \
    | awk -F '\t' '$1 ~ / blob / { sub(/^procedures\//, "", $2); print $2 }'
}

# A missing final newline would glue the end marker to the last line, so both sync and check add one.
show() {
  pb show "$1" | awk 1
}

if [ "$mode" = sync ]; then
  if ! pb diff --quiet HEAD -- rules.md procedures \
    || [ -n "$(pb ls-files --others --exclude-standard -- procedures)" ]; then
    $self || fail "the playbook clone has uncommitted changes in rules.md or procedures/: commit them first"
  fi
  sha=$(pb rev-parse HEAD)
  ! $self || sha=0000000000000000000000000000000000000000
  if ! $self && pb rev-parse --verify --quiet origin/main >/dev/null; then
    GIT_TERMINAL_PROMPT=0 pb fetch --quiet origin main 2>/dev/null || warn "git fetch of the playbook failed"
    pb merge-base --is-ancestor "$sha" origin/main \
      || warn "playbook HEAD $sha is not in origin/main: sync from an up-to-date main (git -C $playbook pull)"
  fi

  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  {
    head -n "$((begin_n - 1))" "$agents"
    echo "<!-- playbook:begin Kapakac/playbook@$sha (не править руками, обновлять: make sync-rules) -->"
    if $self; then awk 1 "$playbook/rules.md"; else show "$sha:rules.md"; fi
    echo "$end_line"
    tail -n "+$((end_n + 1))" "$agents"
  } >"$tmp"

  # Procedures go first so that a failure leaves the old marker, and check keeps pointing at the old commit.
  if ! $self; then
    mkdir -p "$copies"
    names=$(procedure_names "$sha")
    count=0
    while read -r name; do
      [ -n "$name" ] || continue
      show "$sha:procedures/$name" >"$copies/$name"
      count=$((count + 1))
    done <<<"$names"
    echo "docs/playbook/: $count procedures"
    for f in "$copies"/*; do
      [ -e "$f" ] || continue
      grep -qxF "$(basename "$f")" <<<"$names" \
        || warn "docs/playbook/$(basename "$f") is not in the playbook any more: ask Arsenii before deleting it"
    done
  fi

  cat "$tmp" >"$agents"
  echo "AGENTS.md: shared block from playbook@$sha"
  exit 0
fi

errors=0
problem() {
  echo "sync-rules: $*" >&2
  errors=$((errors + 1))
}

if $self; then
  diff -q <(block) <(awk 1 "$playbook/rules.md") >/dev/null \
    || problem "the shared block in AGENTS.md differs from rules.md: run make sync-rules"
  [ "$errors" = 0 ] || exit 1
  echo "AGENTS.md matches rules.md"
  exit 0
fi

sha=$(sed -nE "${begin_n}s/.*Kapakac\/playbook@([0-9a-f]{40}).*/\1/p" "$agents")
pb cat-file -e "$sha^{commit}" 2>/dev/null \
  || fail "playbook commit $sha not found: fetch the full playbook history, or the block was never synced (run make sync-rules)"

pb cat-file -e "$sha:rules.md" 2>/dev/null || fail "playbook@$sha has no rules.md: the marker points at a wrong commit"
diff -q <(block) <(show "$sha:rules.md") >/dev/null \
  || problem "the shared block in AGENTS.md differs from rules.md at playbook@$sha: change the playbook, then run make sync-rules"

names=$(procedure_names "$sha")
while read -r name; do
  [ -n "$name" ] || continue
  if [ ! -f "$copies/$name" ]; then
    problem "docs/playbook/$name is missing: run make sync-rules"
  elif ! diff -q "$copies/$name" <(show "$sha:procedures/$name") >/dev/null; then
    problem "docs/playbook/$name differs from playbook@$sha: change the playbook, then run make sync-rules"
  fi
done <<<"$names"
for f in "$copies"/*; do
  [ -e "$f" ] || continue
  grep -qxF "$(basename "$f")" <<<"$names" \
    || problem "docs/playbook/$(basename "$f") is not in playbook@$sha"
done

[ "$errors" = 0 ] || exit 1

head_sha=$(pb rev-parse HEAD)
if ! pb merge-base --is-ancestor "$sha" "$head_sha"; then
  warn "the playbook clone (at $head_sha) does not contain $sha on its branch: update the clone before syncing"
elif ! pb diff --quiet "$sha" "$head_sha" -- rules.md procedures; then
  warn "the playbook has newer rules than $sha (now $head_sha): run make sync-rules in a separate PR"
fi
echo "AGENTS.md and docs/playbook/ match playbook@$sha"
