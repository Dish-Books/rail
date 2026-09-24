#!/usr/bin/env bash
# Receipt plumbing shared by scripts/ci.sh and scripts/ci-lanes.sh (write) and
# scripts/ci-verify-receipt.sh (read). docs/local-ci.md.
set -euo pipefail

# Bump when the payload shape or the gate set changes; old receipts stop verifying.
RECEIPT_SPEC_VERSION=1
RECEIPT_REF_PREFIX="refs/ci-receipts"

# Keyed on the tree, not the commit, so amend/rebase/reword of an unchanged tree
# keeps its receipt. Any tracked-file change invalidates it.
receipt_tree() {
  git rev-parse "${1:-HEAD}^{tree}"
}

# openssl rather than sha256sum/base64 — the BSD and GNU flags differ, openssl's don't.
receipt_hmac() {
  : "${CI_RECEIPT_KEY:?CI_RECEIPT_KEY is not set (see docs/local-ci.md)}"
  openssl dgst -sha256 -hmac "$CI_RECEIPT_KEY" -hex | awk '{print $NF}'
}

# The toolchain that actually ran, so a stale local install can't quietly sign a
# tree the pinned toolchain would have rejected.
receipt_tool_versions() {
  local elixir otp node pnpm
  elixir=$(elixir -e 'IO.write(System.version())')
  otp=$(elixir -e 'IO.write(:erlang.system_info(:otp_release))')
  node=$(node --version | tr -d 'v')
  pnpm=$(pnpm --version)
  printf '%s|%s|%s|%s' "$elixir" "$otp" "$node" "$pnpm"
}
