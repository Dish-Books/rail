#!/usr/bin/env bash
# Holds a coverage report at 100%.
set -euo pipefail

report=${1:?usage: ci-coverage-100.sh <excoveralls.json> [label]}
label=${2:-coverage}

if [[ ! -f $report ]]; then
  echo "$label: no coverage report at $report" >&2
  exit 1
fi

# A null entry is a line coverage does not count; 0 is a relevant line nothing ran. The line
# numbers are printed because CI keeps no report: a miss that only happens there can't be rerun.
uncovered=$(jq -r '
  [.source_files[]
   | {name, lines: ([.coverage | to_entries[] | select(.value == 0) | .key + 1])}
   | select(.lines != [])]
  | sort_by(-(.lines | length))[]
  | "  \(.lines | length)\t\(.name)\t(lines \(.lines | map(tostring) | join(", ")))"
' "$report")

if [[ -z $uncovered ]]; then
  echo "$label: 100%"
  exit 0
fi

{
  echo "$label: below 100% - uncovered lines by file (missed, file, lines):"
  echo "$uncovered"
} >&2
exit 1
