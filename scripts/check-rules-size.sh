#!/usr/bin/env bash
# Usage: check-rules-size.sh [<file>]
#
# Fails when rules.md (or <file>) is longer than 60 lines or 8 KiB. The block is pasted into the
# AGENTS.md of every project and Codex reads at most 32 KiB of instructions in total, so
# details belong in procedures/, not here.
set -euo pipefail

file=${1:-rules.md}
max_lines=60
max_bytes=8192

lines=$(wc -l <"$file")
bytes=$(wc -c <"$file")
if [ "$lines" -gt "$max_lines" ] || [ "$bytes" -gt "$max_bytes" ]; then
  echo "$file is $lines lines and $bytes bytes; the limit is $max_lines lines and $max_bytes bytes: move details to procedures/" >&2
  exit 1
fi
echo "$file: $lines lines, $bytes bytes (limit $max_lines lines, $max_bytes bytes)"
