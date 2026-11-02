#!/usr/bin/env bash
# Usage: notify-rules.sh
#
# For the playbook's own workflow after a push to main: starts the workflow that runs rules-update
# in every project. Reads RULES_NOTIFY_REPO (owner/repo of that workflow) and RULES_NOTIFY_TOKEN.
# Without them it only warns: an owner who has no such workflow keeps a green run.
set -euo pipefail

[ $# -eq 0 ] || {
  echo "usage: $0" >&2
  exit 2
}

workflow=rules-update-all.yml

if [ -z "${RULES_NOTIFY_REPO:-}" ] || [ -z "${RULES_NOTIFY_TOKEN:-}" ]; then
  echo "::warning::RULES_NOTIFY_REPO or RULES_NOTIFY_TOKEN is not set, the projects get the new rules on their own schedule"
  exit 0
fi

# gh workflow run resolves the default branch over GraphQL, which a token with only the Actions permission cannot read.
if GH_TOKEN=$RULES_NOTIFY_TOKEN gh api --method POST --silent \
  "repos/$RULES_NOTIFY_REPO/actions/workflows/$workflow/dispatches" -f ref=main; then
  echo "Started $workflow"
else
  echo "::error::Could not start $workflow: check RULES_NOTIFY_TOKEN (Actions: Read and write on that repo, not expired) and RULES_NOTIFY_REPO"
  exit 1
fi
