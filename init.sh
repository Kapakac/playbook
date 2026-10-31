#!/usr/bin/env bash
# Usage: init.sh <project-dir> <project-name>
#
# Copies templates/ into the project without overwriting existing files, then syncs the shared rules.
# templates/shared/ is the root of the separate shared branch, not part of main, so it is skipped.
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <project-dir> <project-name>" >&2
  exit 2
fi

playbook=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
mkdir -p "$1"
project=$(cd "$1" && pwd -P)
name=$2

if [ "$project" = "$playbook" ]; then
  echo "init.sh: the project directory must not be the playbook itself" >&2
  exit 1
fi

if ! git -C "$playbook" diff --quiet HEAD -- rules.md procedures \
  || [ -n "$(git -C "$playbook" ls-files --others --exclude-standard -- procedures)" ]; then
  echo "init.sh: the playbook clone has uncommitted changes in rules.md or procedures/: commit them first" >&2
  exit 1
fi

created_agents=false
created_makefile=false
while read -r f; do
  rel=${f#./}
  dest=$project/$rel
  if [ -e "$dest" ]; then
    echo "skip $rel: already exists"
    continue
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$playbook/templates/$rel" "$dest"
  echo "add $rel"
  case $rel in
    AGENTS.md) created_agents=true ;;
    Makefile) created_makefile=true ;;
  esac
done < <(cd "$playbook/templates" && find . -path ./shared -prune -o -type f -print | sort)

if $created_agents; then
  content=$(cat "$project/AGENTS.md")
  printf '%s\n' "${content//\{\{PROJECT_NAME\}\}/"$name"}" >"$project/AGENTS.md"
fi

if grep -q '^<!-- playbook:begin ' "$project/AGENTS.md"; then
  "$playbook/scripts/sync-rules.sh" "$project"
else
  echo "AGENTS.md has no playbook markers: add them as in templates/AGENTS.md, then run make sync-rules"
fi

$created_makefile || echo "Makefile already existed: add the sync-rules and check-rules targets from templates/Makefile"
echo "Next: fill in the «Проект» section of AGENTS.md and docs/stack.md, docs/roadmap.md"
