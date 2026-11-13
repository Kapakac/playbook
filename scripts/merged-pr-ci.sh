#!/usr/bin/env bash
# Usage: merged-pr-ci.sh
#
# First step of a project's deploy.yml (README, «Деплой»): the deploy runs on push to main and CI does
# not, so this checks that the last ci.yml run of the merged PR head completed with success.
# The project calls it from a checkout of playbook main, so a fix here reaches every deploy at once.
# Needs gh with GH_TOKEN (actions: read, pull-requests: read), GITHUB_REPOSITORY and GITHUB_SHA.
set -euo pipefail

if [ "${GITHUB_EVENT_NAME:-}" != push ]; then
  echo "merged-pr-ci: ${GITHUB_EVENT_NAME:-no event}, not a push: nothing to check"
  exit 0
fi
: "${GITHUB_REPOSITORY:?}" "${GITHUB_SHA:?}"

head=$(gh api "repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/pulls" --jq 'map(select(.merged_at)) | .[0].head.sha // empty')
if [ -z "$head" ]; then
  echo "::error::$GITHUB_SHA came without a PR"
  exit 1
fi
# The newest run first: a run on a draft is skipped as a whole, the one after «ready» comes on top.
run=$(gh api "repos/$GITHUB_REPOSITORY/actions/workflows/ci.yml/runs?head_sha=$head&per_page=1" \
  --jq '.workflow_runs[0] | if . then "\(.status) \(.conclusion)" else "no run" end')
if [ "$run" != "completed success" ]; then
  echo "::error::CI of the merged PR is not green: $run"
  exit 1
fi
echo "merged-pr-ci: the last ci.yml run of $head is green"
