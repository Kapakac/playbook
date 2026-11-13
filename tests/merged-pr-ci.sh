#!/usr/bin/env bash
# shellcheck disable=SC2016 # the fake gh is written with literal $ signs
# Tests for scripts/merged-pr-ci.sh with a fake gh that answers from saved API replies.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir "$work/bin"
cat >"$work/bin/gh" <<'GH'
#!/usr/bin/env bash
# gh api <endpoint> --jq <filter>: the reply comes from $REPLIES/pulls.json or runs.json.
case $2 in
  */pulls) reply=$REPLIES/pulls.json ;;
  */actions/workflows/ci.yml/runs\?head_sha=head1\&per_page=1) reply=$REPLIES/runs.json ;;
  *) echo "unexpected endpoint $2" >&2; exit 1 ;;
esac
jq -r "$4" "$reply"
GH
chmod +x "$work/bin/gh"
export PATH=$work/bin:$PATH REPLIES=$work GITHUB_REPOSITORY=owner/project GITHUB_SHA=merge1

failures=0
run() {
  local name=$1 want=$2 pattern=$3
  local code=0
  "$root/scripts/merged-pr-ci.sh" >"$work/out" 2>&1 || code=$?
  if [ "$code" = "$want" ] && grep -qF -- "$pattern" "$work/out"; then
    echo "ok   $name"
  else
    echo "FAIL $name (want exit $want and: $pattern)" >&2
    cat "$work/out" >&2
    failures=$((failures + 1))
  fi
}

merged='[{"head": {"sha": "other"}, "merged_at": null}, {"head": {"sha": "head1"}, "merged_at": "2026-11-13T10:00:00Z"}]'
echo "$merged" >"$work/pulls.json"

export GITHUB_EVENT_NAME=push
echo '{"workflow_runs": [{"status": "completed", "conclusion": "success"}]}' >"$work/runs.json"
run "a green last run passes" 0 "is green"
echo '{"workflow_runs": [{"status": "completed", "conclusion": "failure"}]}' >"$work/runs.json"
run "a red last run fails" 1 "not green: completed failure"
echo '{"workflow_runs": [{"status": "in_progress", "conclusion": null}]}' >"$work/runs.json"
run "a running CI fails" 1 "not green: in_progress null"
echo '{"workflow_runs": []}' >"$work/runs.json"
run "no CI run fails" 1 "not green: no run"
echo '[{"head": {"sha": "head1"}, "merged_at": null}]' >"$work/pulls.json"
run "a commit without a merged PR fails" 1 "came without a PR"
echo "$merged" >"$work/pulls.json"

export GITHUB_EVENT_NAME=workflow_dispatch
rm "$work/runs.json"
run "a run by the button skips the check" 0 "not a push"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "all merged-pr-ci tests passed"
