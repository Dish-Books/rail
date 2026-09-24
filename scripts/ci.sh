#!/usr/bin/env bash
# Runs every gate .github/workflows/tests.yaml runs, then writes a signed receipt
# so pr.yaml can verify instead of repeat. docs/local-ci.md.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/ci-receipt.sh
source scripts/ci-postgres.sh

# `mise run ci` puts the pinned toolchain on PATH; a direct invocation may not.
if ! command -v elixir >/dev/null 2>&1; then
  exec mise exec -- bash "${BASH_SOURCE[0]}" "$@"
fi

FAST=0
PUSH=1
SERIAL=0
for arg in "$@"; do
  case "$arg" in
    --fast) FAST=1 ;;
    --no-push) PUSH=0 ;;
    --serial) SERIAL=1 ;;
    *) echo "usage: mise run ci [--fast] [--no-push] [--serial]" >&2; exit 2 ;;
  esac
done

# A receipt attests to HEAD's tree, so anything uncommitted would sign a tree we
# never tested. --fast writes no receipt, so it doesn't care.
if [[ $FAST -eq 0 && -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is dirty — commit first, or run with --fast" >&2
  git status --short >&2
  exit 1
fi

LANEDIR=$(mktemp -d)
trap 'rm -rf "$LANEDIR"' EXIT

slug() { printf '%s' "$1" | tr -cs 'a-zA-Z0-9' '_'; }

# Output is buffered per gate and replayed in lane order at the end.
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
# The build lock is per _build/<env>, so dev and test never block each other; the
# deps lock is shared, hence the single deps.get in the prelude.

lane_dev() {
  export MIX_ENV=dev
  if [[ $FAST -eq 0 ]]; then
    # --only, or mix cleans every environment and wipes the test lane's build.
    mix clean --only dev >/dev/null
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
  # rail's VM runs several suites at once, so each gets half the cores; elsewhere, ExUnit's default.
  unset MAX_CASES
  if [ -n "${RAIL_WORKTREE_SLOT:-}" ]; then export MAX_CASES=$(( $(getconf _NPROCESSORS_ONLN) * 2 / 4 )); fi
  sub_gate "tests" bash -c '
    set -e
    mix compile
    mix ecto.create --quiet
    mix ecto.migrate --quiet
    mix coveralls.json ${MAX_CASES:+--max-cases "$MAX_CASES"} --warnings-as-errors
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

# The gate set, as `receipt id:display label`. The summary, the completeness check
# and the receipt's gate list all derive from it.

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

# A lane that dies outside a gate leaves no result line, which would otherwise
# read as a pass by absence.
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
  echo -e "\nno receipt written" >&2
  exit 1
fi

if [[ $FAST -eq 1 ]]; then
  echo -e "\nall gates passed — no receipt (--fast skips the clean rebuild)"
  exit 0
fi

# ── receipt ─────────────────────────────────────────────────────────────────
TREE=$(receipt_tree)
IFS='|' read -r ELIXIR_V OTP_V NODE_V PNPM_V <<<"$(receipt_tool_versions)"

# jq, not a heredoc: ran_by comes from git config, and one quote in it would
# produce a payload that only fails verification after it is pushed.
jq -n \
  --argjson spec "$RECEIPT_SPEC_VERSION" \
  --arg tree "$TREE" \
  --arg commit "$(git rev-parse HEAD)" \
  --arg ran_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg ran_by "$(git config user.email)" \
  --arg elixir "$ELIXIR_V" \
  --arg otp "$OTP_V" \
  --arg node "$NODE_V" \
  --arg pnpm "$PNPM_V" \
  --arg gates "$(cut -d: -f1 <<<"$GATES")" \
  '{spec: $spec, tree: $tree, commit: $commit, ran_at: $ran_at, ran_by: $ran_by,
    tools: {elixir: $elixir, otp: $otp, node: $node, pnpm: $pnpm},
    gates: ($gates | split("\n") | map(select(length > 0)))}' >"$LANEDIR/payload.json"

receipt_hmac <"$LANEDIR/payload.json" >"$LANEDIR/sig"

# A commit, not a bare blob — GitHub only reliably accepts commit objects at a ref.
PAYLOAD_BLOB=$(git hash-object -w "$LANEDIR/payload.json")
SIG_BLOB=$(git hash-object -w "$LANEDIR/sig")
RECEIPT_TREE=$(printf '100644 blob %s\tpayload.json\n100644 blob %s\tsig\n' \
  "$PAYLOAD_BLOB" "$SIG_BLOB" | git mktree)
RECEIPT_COMMIT=$(git commit-tree "$RECEIPT_TREE" -m "ci receipt for tree $TREE")

# The ref goes in first either way, so a push that never lands doesn't cost the
# whole suite on the next attempt.
git update-ref "$RECEIPT_REF_PREFIX/$TREE" "$RECEIPT_COMMIT"

if [[ $PUSH -eq 1 ]]; then
  # --no-verify: this push is what puts the receipt on origin, so no receipt there can cover it.
  git push --no-verify --force origin "$RECEIPT_COMMIT:$RECEIPT_REF_PREFIX/$TREE"
  echo -e "\nall gates passed — receipt pushed for tree $TREE"
else
  echo -e "\nall gates passed — receipt written locally (not pushed)"
fi
