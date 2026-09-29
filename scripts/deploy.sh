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

if grep -q '^POSTHOG_API_KEY=.' .env; then export COMPOSE_PROFILES=posthog; fi

# Compose adds the rail container to the docker group, so it can start sandboxes.
DOCKER_GID="$(getent group docker | cut -d: -f3)"
export DOCKER_GID

# Sandboxes are not compose containers, so neither --remove-orphans nor the image prune
# below touches them, and the image they run is only replaced for the ones started next.
docker build --target sandbox -t rail-sandbox:latest .

echo "Agent runs, setup and CI keep running in their sandboxes while rail restarts." >&2
docker compose up -d --build --remove-orphans
docker image prune -f
