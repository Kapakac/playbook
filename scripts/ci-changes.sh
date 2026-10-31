#!/usr/bin/env bash
# Usage: ci-changes.sh [--code <glob>]... <base> [<head>]
#
# Run inside a git repo. Prints code=false when every file changed between the merge base of
# <base> and <head> (default HEAD) is documentation, code=true otherwise. Meant for $GITHUB_OUTPUT.
# Documentation: *.md in the repo root or in .github/, anything under docs/ or shared/.
# A path that matches a --code glob is code even when it looks like documentation.
# When the diff cannot be computed (empty or all-zero base, missing commit), prints code=true.
set -euo pipefail

usage() {
  echo "usage: $0 [--code <glob>]... <base> [<head>]" >&2
  exit 2
}

code_globs=()
while [ $# -gt 0 ]; do
  case $1 in
    --code)
      [ $# -ge 2 ] || usage
      code_globs+=("$2")
      shift 2
      ;;
    *) break ;;
  esac
done
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  usage
fi
base=$1
head=${2:-HEAD}

result() {
  echo "code=$1"
  exit 0
}

is_doc() {
  local path=$1 glob
  for glob in ${code_globs[@]+"${code_globs[@]}"}; do
    # shellcheck disable=SC2053
    [[ $path == $glob ]] && return 1
  done
  case $path in
    docs/* | shared/*) return 0 ;;
    */*.md) [[ $path == .github/* && $path != .github/*/* ]] ;;
    *.md) return 0 ;;
    *) return 1 ;;
  esac
}

if [ -z "$base" ] || [[ $base =~ ^0+$ ]] \
  || ! git cat-file -e "$base^{commit}" 2>/dev/null \
  || ! git cat-file -e "$head^{commit}" 2>/dev/null; then
  echo "ci-changes: cannot compare '$base' with '$head', treating as a code change" >&2
  result true
fi

if ! files=$(git -c core.quotePath=false diff --no-renames --name-only -z "$base...$head" | tr '\0' '\n'); then
  echo "ci-changes: git diff failed, treating as a code change" >&2
  result true
fi

[ -n "$files" ] || result true
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if ! is_doc "$f"; then
    echo "ci-changes: $f is code" >&2
    result true
  fi
done <<<"$files"
echo "ci-changes: documentation only" >&2
result false
