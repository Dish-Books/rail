#!/usr/bin/env bash
# The same gates as scripts/ci.sh, split so prek runs one pre-push hook per lane
# and the terminal names what is in flight. ci.sh stays the single-shot entry
# (`mise run ci`). docs/local-ci.md.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# A hook inherits the pushing shell's environment, which may carry neither the
# pinned toolchain nor the .env holding CI_RECEIPT_KEY. mise supplies both.
if [[ -z ${CI_LANES_REEXEC:-} ]] &&
  { ! command -v elixir >/dev/null 2>&1 || [[ -z ${CI_RECEIPT_KEY:-} ]]; } &&
  command -v mise >/dev/null 2>&1; then
  CI_LANES_REEXEC=1 exec mise exec -- bash scripts/ci-lanes.sh "$@"
fi
: "${CI_RECEIPT_KEY:?is not set, so no receipt can be verified or written (docs/local-ci.md); push --no-verify to skip the hook}"

# Inherited by every git command below, so a hook fired by a push from inside this
# run does nothing — the backstop if a push forgets --no-verify.
if [[ -n ${CI_LANES_ACTIVE:-} ]]; then
  echo "already inside a local CI run — nothing to do"
  exit 0
fi
export CI_LANES_ACTIVE=1

source scripts/ci-receipt.sh
source scripts/ci-postgres.sh

TREE=$(receipt_tree)
# Keyed on the tree, so a lane result left by an earlier run can never be counted.
STATE="_build/ci-lanes/$TREE"
COVERED="$STATE/covered"

# One per priority-1 hook in .pre-commit-config.yaml.
LANES="dev tests credo"

slug() { printf '%s' "$1" | tr -cs 'a-zA-Z0-9' '_'; }

# Progress goes to stdout, which prek shows live under the hook's line; the
# command's own output goes to a log, printed only when the lane fails.
step() {
  local log=$1 name=$2
  shift 2
  echo "→ $name"
  if "$@" >>"$log" 2>&1; then
    echo "✓ $name"
  else
    echo "✗ $name"
    return 1
  fi
}

# Gates record their receipt id, and the receipt is built from what passed, so it
# can never claim a gate that did not run.
gate() {
  local id=$1
  shift
  local log="$STATE/$(slug "$id").log"
  : >"$log"
  if step "$log" "$id" "$@"; then
    echo "pass $id" >>"$STATE/results.$LANE"
  else
    echo "FAIL $id" >>"$STATE/results.$LANE"
  fi
}

# One gate, several named steps.
staged_gate() {
  local id=$1
  shift
  local log="$STATE/$(slug "$id").log"
  : >"$log"
  local status=pass
  while [[ $# -gt 0 ]]; do
    local name=$1 cmd=$2
    shift 2
    if ! step "$log" "$name" bash -c "$cmd"; then
      status=FAIL
      break
    fi
  done
  echo "$status $id" >>"$STATE/results.$LANE"
}

skip_gate() {
  echo "skip $1" >>"$STATE/results.$LANE"
  echo "– $1 (skipped)"
  : >"$STATE/$(slug "$1").log"
}

# ── lanes ───────────────────────────────────────────────────────────────────
# The build lock is per _build/<env>, so dev and test never block each other; the
# deps lock is shared, hence the single deps.get in the prelude.

lane_dev() {
  export MIX_ENV=dev
  if [[ ${CI_FAST:-0} -eq 0 ]]; then
    # --only, or mix cleans every environment and wipes the test lane's build.
    if ! step "$STATE/clean.log" clean mix clean --only dev; then
      cat "$STATE/clean.log"
      exit 1
    fi
  fi
  gate compile mix compile --warnings-as-errors
  if grep -q '^FAIL' "$STATE/results.$LANE"; then
    for g in format credo deps.audit sobelow; do skip_gate "$g"; done
    return
  fi
  gate format mix format --check-formatted
  gate credo mix credo --strict
  gate deps.audit mix deps.audit
  gate sobelow mix sobelow --skip
}

lane_tests() {
  export MIX_ENV=test
  staged_gate tests \
    "compile" "mix compile" \
    "ecto.create" "mix ecto.create --quiet" \
    "ecto.migrate" "mix ecto.migrate --quiet" \
    "coveralls" "mix coveralls.json --max-cases 4 --warnings-as-errors" \
    "coverage" "scripts/ci-coverage-100.sh cover/excoveralls.json app"
}

lane_credo() {
  staged_gate credo_subproject \
    "deps.get" "cd credo && MIX_ENV=dev mix deps.get" \
    "compile" "cd credo && MIX_ENV=dev mix compile --warnings-as-errors" \
    "format" "cd credo && MIX_ENV=dev mix format --check-formatted" \
    "credo" "cd credo && MIX_ENV=dev mix credo --strict" \
    "deps.audit" "cd credo && MIX_ENV=dev mix deps.audit" \
    "coveralls" "cd credo && MIX_ENV=test mix coveralls.json" \
    "coverage" "scripts/ci-coverage-100.sh credo/cover/excoveralls.json credo/"
}

# ── modes ───────────────────────────────────────────────────────────────────

usage() {
  echo "usage: ci-lanes.sh prelude | lane <dev|tests|credo> | receipt" >&2
  exit 2
}

case ${1:-} in
prelude)
  mkdir -p "$STATE"
  # One receipt check for the whole run; later hooks read the marker.
  if out=$(scripts/ci-verify-receipt.sh "$TREE" 2>&1); then
    touch "$COVERED"
    echo "$out"
    echo "every later hook is a no-op"
    exit 0
  fi
  echo "$out" >&2

  if [[ ${CI_FAST:-0} -eq 0 && -n "$(git status --porcelain)" ]]; then
    echo "error: working tree is dirty — the gates would test a tree other than $TREE" >&2
    git status --short >&2
    exit 1
  fi

  rm -rf "$STATE"
  mkdir -p "$STATE"
  log="$STATE/prelude.log"
  : >"$log"
  if ! step "$log" "postgres" wait_for_postgres || ! step "$log" "deps.get" mix deps.get; then
    cat "$log"
    exit 1
  fi
  ;;

lane)
  LANE=${2:-}
  [[ -n $LANE ]] || usage
  [[ $(type -t "lane_$LANE") == function ]] || usage
  [[ -e $COVERED ]] && exit 0
  mkdir -p "$STATE"

  "lane_$LANE"

  # prek keeps a hook's output only when it fails, which is also when the log matters.
  results="$STATE/results.$LANE"
  [[ -f $results ]] || { echo "lane $LANE recorded nothing" >&2; exit 1; }
  if grep -q '^FAIL' "$results"; then
    while read -r status id; do
      [[ $status == FAIL ]] || continue
      printf '\n── %s\n' "$id"
      cat "$STATE/$(slug "$id").log"
    done <"$results"
    exit 1
  fi
  ;;

receipt)
  # Already signed, but the receipt may only exist locally (ci.sh writes the ref
  # before pushing it). A tree the PR check cannot see is not covered, so publish it.
  if [[ -e $COVERED ]]; then
    ref="$RECEIPT_REF_PREFIX/$TREE"
    if [[ -n $(git ls-remote origin "$ref" 2>/dev/null) ]]; then
      exit 0
    fi
    git rev-parse --quiet --verify "$ref" >/dev/null ||
      { echo "receipt for $TREE is on neither origin nor this clone" >&2; exit 1; }
    echo "→ receipt was local only, publishing it"
    git push --no-verify --force origin "$ref:$ref"
    exit 0
  fi

  # Named, not globbed: a lane that never ran leaves no file, and a glob would
  # sign a shorter gate list.
  results=()
  for lane in $LANES; do
    f="$STATE/results.$lane"
    [[ -f $f ]] || { echo "no receipt written — lane $lane left no result" >&2; exit 1; }
    results+=("$f")
  done

  incomplete=$(awk '$1 != "pass" { print $2 }' "${results[@]}" | sort -u | tr '\n' ' ')
  if [[ -n ${incomplete// /} ]]; then
    echo "no receipt written — did not pass: $incomplete" >&2
    exit 1
  fi

  if [[ ${CI_FAST:-0} -eq 1 ]]; then
    echo "no receipt (CI_FAST skips the clean rebuild)"
    exit 0
  fi

  IFS='|' read -r ELIXIR_V OTP_V NODE_V PNPM_V <<<"$(receipt_tool_versions)"

  # jq, not a heredoc: one quote in ran_by would produce an unverifiable payload.
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
    --arg gates "$(awk '$1 == "pass" { print $2 }' "${results[@]}" | sort -u)" \
    '{spec: $spec, tree: $tree, commit: $commit, ran_at: $ran_at, ran_by: $ran_by,
      tools: {elixir: $elixir, otp: $otp, node: $node, pnpm: $pnpm},
      gates: ($gates | split("\n") | map(select(length > 0)))}' >"$STATE/payload.json"

  receipt_hmac <"$STATE/payload.json" >"$STATE/sig"

  PAYLOAD_BLOB=$(git hash-object -w "$STATE/payload.json")
  SIG_BLOB=$(git hash-object -w "$STATE/sig")
  RECEIPT_TREE=$(printf '100644 blob %s\tpayload.json\n100644 blob %s\tsig\n' \
    "$PAYLOAD_BLOB" "$SIG_BLOB" | git mktree)
  RECEIPT_COMMIT=$(git commit-tree "$RECEIPT_TREE" -m "ci receipt for tree $TREE")
  git update-ref "$RECEIPT_REF_PREFIX/$TREE" "$RECEIPT_COMMIT"

  if [[ ${CI_NO_PUSH:-0} -eq 1 ]]; then
    echo "receipt written locally, not pushed"
    exit 0
  fi

  # --no-verify or this push fires the hook we are running inside, which runs the
  # suite again, whose receipt push fires it again.
  echo "→ pushing the receipt"
  git push --no-verify --force origin "$RECEIPT_COMMIT:$RECEIPT_REF_PREFIX/$TREE"
  # Re-verify the way the PR check will, so a lane that never reported is caught here.
  scripts/ci-verify-receipt.sh "$TREE"
  ;;

*) usage ;;
esac
