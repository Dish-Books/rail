#!/usr/bin/env bash
# Runs every CI gate locally.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/ci-postgres.sh

if ! command -v elixir >/dev/null 2>&1; then
  exec mise exec -- bash "${BASH_SOURCE[0]}" "$@"
fi

FAST=0
SERIAL=0
for arg in "$@"; do
  case "$arg" in
    --fast) FAST=1 ;;
    --serial) SERIAL=1 ;;
    *) ;;
  esac
done

LANEDIR=$(mktemp -d)
trap 'rm -rf "$LANEDIR"' EXIT

slug() { printf '%s' "$1" | tr -cs 'a-zA-Z0-9' '_'; }

sub_gate() {
  local name=$1
  shift
  if "$@" >"$LANEDIR/$(slug "$name").log" 2>&1; then
    echo "pass $name" >>"$LANEDIR/results.$LANE"
  else
    echo "FAIL $name" >>"$LANEDIR/results.$LANE"
  fi
}

skip_gate() {
  echo "skip $1" >>"$LANEDIR/results.$LANE"
  : >"$LANEDIR/$(slug "$1").log"
}

# ── lanes ───────────────────────────────────────────────────────────────────

lane_dev() {
  export MIX_ENV=dev
  if [[ $FAST -eq 0 ]]; then
    mix clean --only dev >/dev/null 2>&1 || true
  fi
  sub_gate "compile (no warnings)" mix compile --warnings-as-errors
  if grep -q '^FAIL' "$LANEDIR/results.$LANE"; then
    for g in format credo deps.audit sobelow; do skip_gate "$g"; done
    return
  fi
  sub_gate "format" mix format --check-formatted
  sub_gate "credo" mix credo --strict
  sub_gate "deps.audit" mix deps.audit
  sub_gate "sobelow" mix sobelow --skip
}

lane_tests() {
  export MIX_ENV=test
  sub_gate "tests" bash -c '
    set -e
    mix compile
    mix ecto.create --quiet
    mix ecto.migrate --quiet
    mix coveralls.json --max-cases 4 --warnings-as-errors
    scripts/ci-coverage-100.sh cover/excoveralls.json app'
}

lane_credo() {
  sub_gate "credo/ subproject" bash -c '
    set -e
    cd credo
    MIX_ENV=dev mix deps.get
    MIX_ENV=dev mix compile --warnings-as-errors
    MIX_ENV=dev mix format --check-formatted
    MIX_ENV=dev mix credo --strict
    MIX_ENV=dev mix deps.audit
    MIX_ENV=test mix coveralls.json
    ../scripts/ci-coverage-100.sh cover/excoveralls.json credo/'
}

LANES="dev tests credo"

GATES='compile:compile (no warnings)
format:format
credo:credo
deps.audit:deps.audit
sobelow:sobelow
tests:tests
credo_subproject:credo/ subproject'

# ── serial prelude ──────────────────────────────────────────────────────────
wait_for_postgres
mix deps.get

# ── run ─────────────────────────────────────────────────────────────────────
if [[ $SERIAL -eq 1 ]]; then
  for lane in $LANES; do
    LANE=$lane "lane_$lane"
  done
else
  PIDS=""
  for lane in $LANES; do
    ( LANE=$lane; "lane_$lane" ) &
    PIDS="$PIDS $!"
  done
  for pid in $PIDS; do
    wait "$pid" || true
  done
fi

# ── report ──────────────────────────────────────────────────────────────────
FAILED=0
SUMMARY=""
for lane in $LANES; do
  results="$LANEDIR/results.$lane"
  [[ -f $results ]] || continue
  while read -r status name; do
    printf '\n\033[1m── %s\033[0m\n' "$name"
    cat "$LANEDIR/$(slug "$name").log"
    SUMMARY="$SUMMARY$status $name"$'\n'
    [[ $status == FAIL ]] && FAILED=1
  done <"$results"
done

printf '\n\033[1m── summary\033[0m\n'
while read -r status name; do
  [[ -n $status ]] || continue
  case "$status" in
    pass) printf '  \033[32m✓\033[0m %s\n' "$name" ;;
    skip) printf '  \033[33m–\033[0m %s (skipped)\n' "$name" ;;
    *) printf '  \033[31m✗\033[0m %s\n' "$name" ;;
  esac
done <<<"$SUMMARY"

while IFS=: read -r _id label; do
  [[ -n $label ]] || continue
  if grep -qxF "pass $label" <<<"$SUMMARY"; then
    continue
  fi
  FAILED=1
  if ! grep -qxF "FAIL $label" <<<"$SUMMARY" && ! grep -qxF "skip $label" <<<"$SUMMARY"; then
    printf '  \033[31m✗\033[0m %s (did not run to completion)\n' "$label"
  fi
done <<<"$GATES"

if [[ $FAILED -eq 1 ]]; then
  echo -e "\nci failed" >&2
  exit 1
fi

echo -e "\nall gates passed"
exit 0
