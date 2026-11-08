#!/usr/bin/env bash
# Usage: agent-guard.sh tool            (an agent hook: the tool call as JSON on stdin)
#        agent-guard.sh pre-push <remote> <url>   (git pre-push hook: the refs on stdin)
#        agent-guard.sh commit-msg <file>         (git commit-msg hook)
#        agent-guard.sh text            (any text on stdin: a commit message, a PR text)
#
# Refuses what the shared rules forbid an agent, whichever agent it is: ssh, scp, sftp, rsync,
# rm -rf, force-push, push to main in any spelling, skipping the git hooks with --no-verify, and
# commit messages with agent traces. Exit code 2 refuses (Claude Code and Codex hooks read it as
# «deny» and show stderr to the agent; git stops the push or the commit), 0 lets it through.
# The playbook copies this script into each project as .githooks/agent-guard.sh (make sync-rules);
# templates/.githooks/, templates/.claude/ and templates/.codex/ only call it.
# Plain bash 3.2 (macOS): no set -u, which breaks on empty arrays there.
set -eo pipefail

agent='anthropic\.com|openai\.com|claude|codex|copilot'
# A trace is a whole line (so that text about these lines still passes) or a signature anywhere.
trace_line='[[:space:]_*]*(co-authored-by:.*('"$agent"'|gpt)|claude-session:|requested by)'
trace_any='generated (with|by) \[?(claude|codex|copilot|chatgpt)|claude\.ai/code|chatgpt\.com/codex'
traces="^$trace_line|$trace_any"
# In a command the message also starts right after a quote: git commit -m "…" -m "Co-Authored-By: …".
command_traces="(^|[\"'])$trace_line|$trace_any"
main=main
zero=0000000000000000000000000000000000000000

usage() {
  sed -n '2,5p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 64
}

deny() {
  echo "agent-guard: $1" >&2
  exit 2
}

rule_branches='rules.md, «Ветки, коммиты и PR»'
deny_traces() {
  deny "the commit message carries agent traces (Co-Authored-By, Claude-Session, Generated with …): commit again without them ($rule_branches)"
}

# Splits shell text into simple commands, one per line, words separated by \037; a newline inside
# a word becomes \035. Quotes, backslashes, comments and here-document bodies are taken into account.
split_commands() {
  awk '
    function endword() {
      if (inword) {
        if (heredoc_next) { pending[++np] = word; heredoc_next = 0 }
        else if (word ~ /^<<</) { }
        else if (word ~ /^<<-?$/) heredoc_next = 1
        else if (word ~ /^<<-?./) { sub(/^<<-?/, "", word); pending[++np] = word }
        else cmd = cmd (cmd == "" ? "" : "\037") word
      }
      word = ""; inword = 0
    }
    function endcmd() { endword(); if (cmd != "") print cmd; cmd = "" }
    { text = text (NR > 1 ? "\n" : "") $0 }
    END {
      n = length(text); q = ""; skip = 0
      for (i = 1; i <= n; i++) {
        c = substr(text, i, 1)
        if (skip) {
          j = index(substr(text, i), "\n"); line = j ? substr(text, i, j - 1) : substr(text, i)
          sub(/^[ \t]+/, "", line)
          if (line == pending[skip]) { skip++; if (skip > np) { skip = 0; np = 0 } }
          if (!j) break
          i += j - 1; continue
        }
        if (q == "\047") { if (c == "\047") q = ""; else word = word (c == "\n" ? "\035" : c); continue }
        if (q == "\"") {
          if (c == "\"") q = ""
          else if (c == "\\" && index("\"\\$`\n", substr(text, i + 1, 1))) { i++; if (substr(text, i, 1) != "\n") word = word substr(text, i, 1) }
          else word = word (c == "\n" ? "\035" : c)
          continue
        }
        if (c == "\\") { i++; if (substr(text, i, 1) != "\n") { word = word substr(text, i, 1); inword = 1 } continue }
        if (c == "\047" || c == "\"") { q = c; inword = 1; continue }
        if (c == "#" && !inword) { while (i < n && substr(text, i + 1, 1) != "\n") i++; continue }
        if (c == " " || c == "\t") { endword(); continue }
        if (c == "\n") { endcmd(); if (np) skip = 1; continue }
        if (index(";&|()`{}", c)) { endcmd(); continue }
        word = word c; inword = 1
      }
      endcmd()
    }
  '
}

current_branch() {
  git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null || true
}

check_push() {
  local dir=$1
  shift
  local positional=() a dst
  while [ $# -gt 0 ]; do
    a=$1
    shift
    case $a in
      --no-verify) deny "git push --no-verify skips the project's git hooks: push without it ($rule_branches)" ;;
      --force | --force-with-lease | --force-with-lease=* | --mirror)
        deny "force-push rewrites history that others may have: push without $a, or make a new commit ($rule_branches)" ;;
      --all | --branches) deny "git push $a pushes $main too: push only your branch ($rule_branches)" ;;
      -o | --push-option | --repo | --receive-pack | --exec) shift || true ;;
      --) positional+=("$@"); break ;;
      --*) ;;
      -*)
        case $a in *f*) deny "force-push rewrites history that others may have: push without -f, or make a new commit ($rule_branches)" ;; esac ;;
      *) positional+=("$a") ;;
    esac
  done
  local refspecs=("${positional[@]:1}")
  if [ ${#refspecs[@]} -eq 0 ]; then
    refspecs=(HEAD)
  fi
  for a in "${refspecs[@]}"; do
    case $a in +*) deny "the refspec '$a' force-pushes: drop the + ($rule_branches)" ;; esac
    dst=${a##*:}
    if [ "$dst" = HEAD ]; then
      dst=$(current_branch "$dir")
    fi
    dst=${dst#refs/heads/}
    if [ "$dst" = "$main" ]; then
      deny "push to $main: only through a PR that the owner merges; push your branch and open a PR ($rule_branches)"
    fi
  done
}

check_simple() {
  local dir=$1 raw=$2 depth=$3
  shift 3
  local w=("$@") name i dir2 sub a r f
  while [ ${#w[@]} -gt 0 ]; do
    case ${w[0]} in
      [A-Za-z_]*=*) [[ ${w[0]} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || break ;;
      sudo | env | command | exec | nohup | time | xargs | nice | '!' | if | then | else | elif | do | while | until)
        w=("${w[@]:1}")
        while [ ${#w[@]} -gt 0 ] && [[ ${w[0]} == -* ]]; do w=("${w[@]:1}"); done
        continue ;;
      *) break ;;
    esac
    w=("${w[@]:1}")
  done
  [ ${#w[@]} -gt 0 ] || return 0
  name=${w[0]##*/}
  case $name in
    ssh | scp | sftp | rsync)
      deny "$name is blocked for agents: the agent does not go to servers, the owner runs server commands and deploys (rules.md, «Документы проекта»)" ;;
    rm)
      r=0 f=0
      for a in "${w[@]:1}"; do
        case $a in
          --) break ;;
          --recursive) r=1 ;;
          --force) f=1 ;;
          --*) ;;
          -*)
            if [[ $a == *[rR]* ]]; then r=1; fi
            if [[ $a == *f* ]]; then f=1; fi ;;
        esac
      done
      if [ "$r$f" = 11 ]; then
        deny "rm -rf is blocked for agents: deleting anything needs the owner's «да» on that exact deletion (rules.md, «Только с согласия владельца»)"
      fi ;;
    sh | bash | zsh | dash | ksh)
      for ((i = 1; i < ${#w[@]} - 1; i++)); do
        if [[ ${w[i]} =~ ^-[a-z]*c[a-z]*$ ]]; then
          check_string "$dir" "${w[i + 1]//$'\035'/$'\n'}" $((depth + 1))
          break
        fi
      done ;;
    eval)
      check_string "$dir" "${w[*]:1}" $((depth + 1)) ;;
    git)
      dir2=$dir
      i=1
      while [ "$i" -lt ${#w[@]} ]; do
        case ${w[i]} in
          -C)
            if [[ ${w[i + 1]:-.} == /* ]]; then dir2=${w[i + 1]}; else dir2=$dir2/${w[i + 1]:-.}; fi
            i=$((i + 2)) ;;
          -c | --git-dir | --work-tree | --namespace) i=$((i + 2)) ;;
          -*) i=$((i + 1)) ;;
          *) break ;;
        esac
      done
      sub=${w[i]:-}
      case $sub in
        push) check_push "$dir2" "${w[@]:i+1}" ;;
        commit)
          for a in "${w[@]:i+1}"; do
            case $a in
              --no-verify) deny "git commit --no-verify skips the project's git hooks: commit without it ($rule_branches)" ;;
              --*) ;;
              -*n*)
                if [[ $a =~ ^-[a-zA-Z]+$ ]]; then
                  deny "git commit -n skips the project's git hooks: commit without it ($rule_branches)"
                fi ;;
            esac
          done
          if printf '%s\n' "$raw" | grep -qiE "$command_traces"; then deny_traces; fi ;;
      esac ;;
  esac
  return 0
}

check_string() {
  local dir=$1 text=$2 depth=$3 line
  [ "$depth" -le 3 ] || return 0
  while IFS= read -r line; do
    local words=()
    IFS=$'\037' read -r -a words <<<"$line"
    check_simple "$dir" "$text" "$depth" "${words[@]}"
  done < <(printf '%s\n' "$text" | split_commands)
  return 0
}

# Prints the command of a hook call: the string under "command" (or "cmd"), or each string of an
# argument list and then all of them joined by spaces; records are separated by \036.
json_command() {
  awk '
    function hex(s,   v, k) { v = 0; for (k = 1; k <= length(s); k++) v = v * 16 + index("0123456789abcdef", tolower(substr(s, k, 1))) - 1; return v }
    function str(   out, c, e) {
      out = ""
      for (p++; p <= n; p++) {
        c = substr(s, p, 1)
        if (c == "\"") { p++; return out }
        if (c != "\\") { out = out c; continue }
        e = substr(s, ++p, 1)
        if (e == "n") out = out "\n"; else if (e == "t") out = out "\t"; else if (e == "r") out = out "\r"
        else if (e == "b" || e == "f") { }
        else if (e == "u") { v = hex(substr(s, p + 1, 4)); p += 4; out = out (v < 128 ? sprintf("%c", v) : "?") }
        else out = out e
      }
      return out
    }
    function blank() { while (p <= n && index(" \t\r\n", substr(s, p, 1))) p++ }
    { s = s (NR > 1 ? "\n" : "") $0 }
    END {
      n = length(s)
      if (!match(s, /"(command|cmd)"[ \t\r\n]*:[ \t\r\n]*/)) exit
      p = RSTART + RLENGTH
      c = substr(s, p, 1)
      if (c == "\"") { printf "%s", str(); exit }
      if (c != "[") exit
      all = ""; p++
      while (p <= n) {
        blank(); c = substr(s, p, 1)
        if (c == "\"") { one = str(); printf "%s\036", one; all = all (all == "" ? "" : " ") one; blank(); if (substr(s, p, 1) == ",") p++; continue }
        break
      }
      printf "%s", all
    }
  '
}

json_cwd() {
  sed -nE 's/.*"cwd"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' | head -n 1 | sed 's/\\\(.\)/\1/g'
}

mode=${1:-}
case $mode in
  tool)
    [ $# -eq 1 ] || usage
    input=$(cat)
    dir=$(printf '%s\n' "$input" | json_cwd)
    [ -n "$dir" ] || dir=$PWD
    while IFS= read -r -d $'\036' cmd; do
      check_string "$dir" "$cmd" 0
    done < <(printf '%s\n' "$input" | json_command; printf '\036')
    ;;
  pre-push)
    [ $# -ge 1 ] || usage
    while read -r _ local_sha remote_ref remote_sha; do
      [ -n "${remote_ref:-}" ] || continue
      if [ "$remote_ref" = "refs/heads/$main" ]; then
        deny "push to $main: only through a PR that the owner merges; push your branch and open a PR ($rule_branches)"
      fi
      if [ "$local_sha" != "$zero" ] && [ "$remote_sha" != "$zero" ]; then
        if ! git cat-file -e "$remote_sha^{commit}" 2>/dev/null; then
          deny "${remote_ref#refs/heads/} on the remote has commits you do not have: git fetch and build on them, do not force-push ($rule_branches)"
        elif ! git merge-base --is-ancestor "$remote_sha" "$local_sha"; then
          deny "this push rewrites ${remote_ref#refs/heads/} on the remote (force-push): make a new commit on top instead ($rule_branches)"
        fi
      fi
    done
    ;;
  commit-msg)
    [ $# -eq 2 ] || usage
    if grep -v '^#' "$2" | grep -qiE "$traces"; then deny_traces; fi
    ;;
  text)
    [ $# -eq 1 ] || usage
    if grep -qiE "$traces"; then
      deny "the text carries agent traces (Co-Authored-By, Claude-Session, Generated with …, Requested by …, a session link) ($rule_branches)"
    fi
    ;;
  *) usage ;;
esac
