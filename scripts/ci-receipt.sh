#!/usr/bin/env bash
# Receipt plumbing shared by scripts/ci.sh and scripts/ci-lanes.sh (write) and
# scripts/ci-verify-receipt.sh (read). docs/local-ci.md.
set -euo pipefail

# Bump when the payload shape or the gate set changes; old receipts stop verifying.
# 2: a sha256 digest in place of the HMAC keyed with CI_RECEIPT_KEY.
RECEIPT_SPEC_VERSION=2
RECEIPT_REF_PREFIX="refs/ci-receipts"

# Keyed on the tree, not the commit, so amend/rebase/reword of an unchanged tree
# keeps its receipt. Any tracked-file change invalidates it.
receipt_tree() {
  git rev-parse "${1:-HEAD}^{tree}"
}

# A digest, not a keyed signature: it catches a corrupt or hand-edited payload, not
# a forged one. Authenticity rests on who can push refs/ci-receipts to origin.
# openssl rather than sha256sum — the BSD and GNU flags differ, openssl's don't.
receipt_digest() {
  openssl dgst -sha256 -hex | awk '{print $NF}'
}

# The toolchain that actually ran, so a stale local install can't quietly attest to a
# tree the pinned toolchain would have rejected.
receipt_tool_versions() {
  local elixir otp node pnpm
  elixir=$(elixir -e 'IO.write(System.version())')
  otp=$(elixir -e 'IO.write(:erlang.system_info(:otp_release))')
  node=$(node --version | tr -d 'v')
  pnpm=$(pnpm --version)
  printf '%s|%s|%s|%s' "$elixir" "$otp" "$node" "$pnpm"
}
