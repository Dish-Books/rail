#!/usr/bin/env bash
# Pulls the latest rail and rebuilds its stack on the rail VM. Run with sudo.
set -euo pipefail

cd "$(dirname "$0")/.."
git pull --ff-only

secret() { gcloud secrets versions access latest --project dishbooks-shared --secret "$1"; }

(
  umask 077
  {
    secret rail-env
    echo
    echo "TUNNEL_TOKEN=$(secret rail-tunnel-token)"
  } > .env
)

echo "Restarting rail stops any agent run in flight." >&2
docker compose up -d --build --remove-orphans
docker image prune -f
