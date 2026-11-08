#!/usr/bin/env bash
# shellcheck disable=SC2016  # commands under test are single-quoted on purpose
# Tests for scripts/agent-guard.sh: agent hook calls, the git hooks from templates/.githooks/ on real
# pushes and commits, and the Claude Code and Codex hook files from templates/.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
guard=$root/scripts/agent-guard.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

failures=0
result() {
  set -- "${1//$'\n'/⏎}" "$2" "$3"
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1 (exit $3, want $2)" >&2
    cat "$work/out" >&2
    failures=$((failures + 1))
  fi
}
# expect <name> <exit code> <command…>
expect() {
  local name=$1 want=$2 got=0
  shift 2
  "$@" >"$work/out" 2>&1 || got=$?
  result "$name" "$want" "$got"
}

# The command as a hook call, the way Claude Code and Codex pass it: JSON with tool_input.command.
json() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  printf '{"session_id":"s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s","description":"x"}}' "$repo" "$s"
}
call() { json "$1" | "$guard" tool; }
allow() { expect "allows: $1" 0 call "$1"; }
deny() { expect "refuses: $1" 2 call "$1"; }

repo=$work/project
git init -q -b main "$repo"
git -C "$repo" commit -q --allow-empty -m init
git -C "$repo" checkout -q -b feature

allow 'git status'
allow 'ls -la && echo "use ssh later"'
allow 'git commit -m "Forbid ssh and rm -rf; also scp"'
allow 'cat <<< "ssh host"'
allow '# ssh host'
allow 'rm -r build'
allow 'rm -f file'
allow 'grep -r ssh docs'
deny 'ssh host uptime'
deny 'cd x && /usr/bin/ssh host'
deny 'FOO=1 rsync -a dist host:app'
deny 'sudo -n scp file host:'
deny 'env -i sftp host'
deny 'bash -lc "ssh host"'
deny 'echo $(ssh host)'
deny 'if true; then ssh host; fi'
deny $'cat <<EOF\nssh is fine here\nEOF\nssh host'
deny 'rm -rf build'
deny 'rm -fr build'
deny 'rm -r -f build'
deny 'rm --recursive --force build'

allow 'git push'
allow 'git push -u origin feature'
allow 'git push origin feature:feature'
deny 'git push --force'
deny 'git push -f origin feature'
deny 'git push -uf origin feature'
deny 'git push --force-with-lease origin feature'
deny 'git push --mirror'
deny 'git push origin +feature'
deny 'git push origin main'
deny 'git push origin HEAD:main'
deny 'git push origin HEAD:refs/heads/main'
deny 'git push origin feature:main'
deny 'git push origin :main'
deny 'git push --delete origin main'
deny 'git push --all'
deny 'git -C . push origin main'
deny 'git push --no-verify origin feature'
git -C "$repo" checkout -q main
deny 'git push'
deny 'git push -u origin'
deny 'git push origin HEAD'
allow 'git push origin feature'
git -C "$repo" checkout -q feature

allow 'git commit -am "Add cart"'
allow 'git commit -m "The guard catches Co-Authored-By lines"'
allow $'git commit -F - <<\'EOF\'\nAdd cart\n\nssh and rm -rf are blocked\nEOF'
allow $'git commit -m "Add cart\n\nCo-Authored-By: Colleague <2+colleague@users.noreply.github.com>"'
deny 'git commit --no-verify -m x'
deny 'git commit -anm x'
deny $'git commit -m "Add cart\n\nCo-Authored-By: Claude <noreply@anthropic.com>"'
deny 'git commit -m "Add cart" -m "Co-Authored-By: Claude <noreply@anthropic.com>"'
deny $'git commit -F - <<\'EOF\'\nAdd cart\n\nClaude-Session: https://claude.ai/code/session_1\nEOF'
deny $'git commit -m "Add cart\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)"'

raw() { printf '%s' "$1" | "$guard" tool; }
expect "an argument list is checked" 2 raw '{"tool_input":{"command":["bash","-lc","git push origin main"]}}'
expect "the cmd field is checked" 2 raw '{"tool_input":{"cmd":"rm -rf /"}}'
expect "\\u escapes are decoded" 2 raw '{"tool_input":{"command":"ssh host"}}'
expect "a call without a command passes" 0 raw '{"tool_name":"Read","tool_input":{"file_path":"x"}}'
expect "the refusal names the rule" 0 grep -q 'rules.md, «Ветки, коммиты и PR»' <(raw '{"tool_input":{"command":"git push --force"}}' 2>&1 || true)

text() { printf '%s' "$1" | "$guard" text; }
expect "text without traces passes" 0 text $'Add cart\n\nПроверка ловит Co-Authored-By и «Generated with».'
expect "text with a session line fails" 2 text $'Add cart\n\nClaude-Session: https://e'
expect "text with Generated with fails" 2 text '🤖 Generated with Claude Code'
expect "an unknown mode is a usage error" 64 "$guard" nope

# The git hooks from the template, on real pushes and commits.
hooks=$repo/.githooks
mkdir -p "$hooks"
cp "$root/templates/.githooks/pre-push" "$root/templates/.githooks/commit-msg" "$hooks/"
cp "$guard" "$hooks/agent-guard.sh"
git init -q --bare "$work/origin.git"
git -C "$repo" remote add origin "$work/origin.git"
git -C "$repo" push -q origin main feature
git -C "$repo" config core.hooksPath .githooks
commit() { git -C "$repo" commit -q --allow-empty -m "$1"; }
push() { git -C "$repo" push -q "$@"; }

expect "commit-msg passes a clean commit" 0 commit "Add cart"
expect "commit-msg refuses an agent co-author" 1 commit $'Add cart\n\nCo-Authored-By: Claude <noreply@anthropic.com>'
expect "commit-msg refuses a session line" 1 commit $'Add cart\n\nClaude-Session: https://e'
expect "commit-msg passes a human co-author" 0 commit $'Add cart\n\nCo-Authored-By: Colleague <2+colleague@users.noreply.github.com>'
expect "pre-push passes a push of the branch" 0 push origin feature
expect "pre-push refuses a push to main" 1 push origin feature:main
expect "pre-push refuses HEAD:main" 1 push origin HEAD:main
git -C "$repo" checkout -q main
commit "On main"
expect "pre-push refuses a plain push from main" 1 push origin main
git -C "$repo" checkout -q feature
git -C "$repo" reset -q --hard HEAD~1
expect "pre-push refuses a force-push" 1 push --force origin feature
expect "pre-push refuses deleting main" 1 push origin :main
expect "pre-push allows deleting another branch" 0 push origin :feature
expect "main on the remote is unchanged" 0 test "$(git -C "$work/origin.git" rev-parse main)" = "$(git -C "$repo" rev-parse main~1)"

# The agent hook files from templates/ call the same guard.
claude() { printf '%s' "$1" | CLAUDE_PROJECT_DIR=$repo "$root/templates/.claude/hooks/check-commit.sh"; }
expect "the Claude Code hook refuses through the guard" 2 claude '{"tool_input":{"command":"git push origin HEAD:main"}}'
expect "the Claude Code hook lets a command through" 0 claude '{"tool_input":{"command":"git status"}}'
expect "the Claude Code hook without the guard is a visible error, not a refusal" 1 \
  env CLAUDE_PROJECT_DIR="$work/none" "$root/templates/.claude/hooks/check-commit.sh" </dev/null
if command -v jq >/dev/null; then
  codex_cmd=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command' "$root/templates/.codex/hooks.json")
  codex() { (cd "$repo" && printf '%s' "$1" | sh -c "$codex_cmd"); }
  expect "the Codex hook refuses through the guard" 2 codex '{"tool_input":{"command":"ssh host"}}'
  expect "the Codex hook lets a command through" 0 codex '{"tool_input":{"command":"git status"}}'
  expect "the Claude Code settings call the hook" 0 test "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$root/templates/.claude/settings.json")" \
    = '"$CLAUDE_PROJECT_DIR"/.claude/hooks/check-commit.sh'
else
  echo "skip the Codex hook file: jq is not installed"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures agent-guard test(s) failed" >&2
  exit 1
fi
echo "all agent-guard tests passed"
