#!/usr/bin/env bash
# Holds a coverage report at 100%.
set -euo pipefail

report=${1:?usage: ci-coverage-100.sh <excoveralls.json> [label]}
label=${2:-coverage}

if [[ ! -f $report ]]; then
  echo "$label: no coverage report at $report" >&2
  exit 1
fi

# A null entry is a line coverage does not count; 0 is a relevant line nothing ran.
uncovered=$(jq -r '
  [.source_files[]
   | {name, missed: ([.coverage[] | select(. == 0)] | length)}
   | select(.missed > 0)]
  | sort_by(-.missed)[]
  | "  \(.missed)\t\(.name)"
' "$report")

if [[ -z $uncovered ]]; then
  echo "$label: 100%"
  exit 0
fi

{
  echo "$label: below 100% - uncovered lines by file (missed, file):"
  echo "$uncovered"
  echo
  echo "mix coveralls.detail --filter <file> shows which lines."
} >&2
exit 1
