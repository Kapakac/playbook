#!/usr/bin/env bash
# Usage: update-rules.sh [project-dir]
#
# For the scheduled workflow: syncs the shared rules if rules.md, procedures/ or the PR template
# changed in this playbook clone since the commit recorded in AGENTS.md, adds new lines of the
# playbook PR template to the project's one, then checks the result.
# Lines removed or changed in the playbook template are left to the agent.
set -euo pipefail

[ $# -le 1 ] || {
  echo "usage: $0 [project-dir]" >&2
  exit 2
}

playbook=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
project=$(cd "${1:-.}" && pwd -P)
sync=$playbook/scripts/sync-rules.sh
template=templates/.github/pull_request_template.md
dest=$project/.github/pull_request_template.md

pb() {
  git -C "$playbook" "$@"
}

[ -f "$project/AGENTS.md" ] || {
  echo "update-rules: $project/AGENTS.md not found" >&2
  exit 1
}
old=$(sed -nE 's/^<!-- playbook:begin playbook@([0-9a-f]{40}) .*/\1/p' "$project/AGENTS.md" | head -n 1)

if [ -n "$old" ] && pb cat-file -e "$old^{commit}" 2>/dev/null \
  && pb diff --quiet "$old" HEAD -- rules.md procedures "$template"; then
  echo "update-rules: nothing new in the playbook since $old"
else
  "$sync" "$project"

  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  pb show "HEAD:$template" >"$work/new"
  if [ ! -f "$dest" ]; then
    mkdir -p "$(dirname "$dest")"
    cp "$work/new" "$dest"
    echo "update-rules: added .github/pull_request_template.md"
  else
    : >"$work/old"
    if [ -n "$old" ]; then
      pb show "$old:$template" >"$work/old" 2>/dev/null || : >"$work/old"
    fi
    # A new line goes after the nearest earlier template line that occurs once in the project's file,
    # past the lines that follow it in both files, so a new checkbox lands in its own section.
    awk '
      FILENAME == ARGV[1] { old[$0] = 1; next }
      FILENAME == ARGV[2] { p[++n] = $0; next }
      { q[++m] = $0; cnt[$0]++ }
      function insert(at, line,   t) {
        for (t = m; t >= at; t--) q[t + 1] = q[t]
        q[at] = line
        m++
        cnt[line]++
      }
      END {
        for (i = 1; i <= n; i++) {
          if (p[i] == "" || (p[i] in old) || cnt[p[i]] > 0) continue
          pos = m; k = i
          for (j = i - 1; j >= 1; j--) {
            if (p[j] == "" || cnt[p[j]] != 1) continue
            for (pos = 1; q[pos] != p[j]; pos++) {}
            k = j + 1
            break
          }
          while (k < i && pos < m && q[pos + 1] == p[k]) { pos++; k++ }
          blank = 1
          for (t = k; t < i; t++) if (p[t] != "") blank = 0
          if (blank) for (t = k; t < i; t++) insert(++pos, "")
          insert(pos + 1, p[i])
        }
        for (t = 1; t <= m; t++) print q[t]
      }
    ' "$work/old" "$work/new" "$dest" >"$work/merged"
    if ! cmp -s "$work/merged" "$dest"; then
      cat "$work/merged" >"$dest"
      echo "update-rules: added new lines to .github/pull_request_template.md"
    fi
  fi
fi

"$sync" --check "$project"
