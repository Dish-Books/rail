#!/usr/bin/env bash
# Receipt plumbing shared by scripts/ci.sh.
set -euo pipefail

RECEIPT_SPEC_VERSION=1
RECEIPT_REF_PREFIX="refs/ci-receipts"

receipt_tree() {
  git rev-parse "${1:-HEAD}^{tree}"
}

receipt_ref() {
  echo "${RECEIPT_REF_PREFIX}/$(receipt_tree "${1:-HEAD}")"
}

receipt_hmac() {
  : "${CI_RECEIPT_KEY:?CI_RECEIPT_KEY is not set}"
  openssl dgst -sha256 -hmac "$CI_RECEIPT_KEY" -hex | awk '{print $NF}'
}

receipt_b64() {
  openssl base64 -A
}

receipt_tool_versions() {
  local elixir otp node pnpm
  elixir=$(elixir -e 'IO.write(System.version())')
  otp=$(elixir -e 'IO.write(:erlang.system_info(:otp_release))')
  node=$(node --version | tr -d 'v')
  pnpm=$(pnpm --version)
  printf '%s|%s|%s|%s' "$elixir" "$otp" "$node" "$pnpm"
}
