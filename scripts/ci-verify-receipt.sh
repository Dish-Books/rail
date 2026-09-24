#!/usr/bin/env bash
# Verifies the receipt scripts/ci.sh or ci-lanes.sh wrote for a tree. Exit 0 =
# verified. Used by pr.yaml and the pre-push hook. docs/local-ci.md.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/ci-receipt.sh

TREE=${1:?usage: ci-verify-receipt.sh <tree-sha>}
REF="$RECEIPT_REF_PREFIX/$TREE"

fail() { echo "receipt not verified: $*" >&2; exit 1; }

# Prefer origin, but a receipt only in this clone still proves the tree was gated:
# ci.sh writes the ref before pushing it. A workflow checkout has no local refs.
if ! git fetch --quiet --no-tags origin "+$REF:$REF" 2>/dev/null; then
  git rev-parse --quiet --verify "$REF" >/dev/null || fail "no receipt for tree $TREE"
fi

PAYLOAD=$(mktemp)
trap 'rm -f "$PAYLOAD"' EXIT
git cat-file blob "$REF:payload.json" >"$PAYLOAD" || fail "receipt has no payload"
SIG=$(git cat-file blob "$REF:sig" | tr -d '[:space:]')

EXPECTED=$(receipt_hmac <"$PAYLOAD")
[[ "$SIG" == "$EXPECTED" ]] || fail "signature mismatch"

# Everything below is signed, so these checks are about it being the right
# receipt, not about it being authentic.
jq -e --argjson spec "$RECEIPT_SPEC_VERSION" '.spec == $spec' "$PAYLOAD" >/dev/null \
  || fail "spec version is not $RECEIPT_SPEC_VERSION"
jq -e --arg tree "$TREE" '.tree == $tree' "$PAYLOAD" >/dev/null \
  || fail "receipt is for a different tree"

REQUIRED='["compile","format","credo","deps.audit","sobelow","tests","credo_subproject"]'
jq -e --argjson required "$REQUIRED" '$required - .gates == []' "$PAYLOAD" >/dev/null \
  || fail "receipt does not cover every required gate"

# A receipt signed by a stale toolchain proves the wrong thing.
pin() { grep -E "^$1 *=" mise.toml | sed 's/.*"\(.*\)".*/\1/'; }
ELIXIR_PIN=$(pin elixir)
check_tool() {
  local key=$1 want=$2 got
  got=$(jq -r ".tools.$key" "$PAYLOAD")
  [[ "$got" == "$want" ]] || fail "$key was $got locally, mise.toml pins $want"
}
check_tool elixir "${ELIXIR_PIN%%-otp-*}"
check_tool otp "${ELIXIR_PIN##*-otp-}"
check_tool node "$(pin node)"
check_tool pnpm "$(pin pnpm)"

echo "verified: $(jq -r '"tree \(.tree[0:12]) by \(.ran_by) at \(.ran_at)"' "$PAYLOAD")"
