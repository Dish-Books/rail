#!/usr/bin/env bash
# Checks that PostgreSQL is accepting connections.
set -euo pipefail

postgres_host() { printf '%s' "${DB_HOST:-localhost}"; }
postgres_port() { printf '%s' "${DB_PORT:-5432}"; }

postgres_accepting() {
  if command -v pg_isready >/dev/null 2>&1; then
    pg_isready -q -h "$(postgres_host)" -p "$(postgres_port)" -U postgres
  else
    (exec 3<>"/dev/tcp/$(postgres_host)/$(postgres_port)") 2>/dev/null
  fi
}

wait_for_postgres() {
  if postgres_accepting; then
    return 0
  fi

  local attempt
  for attempt in $(seq 60); do
    if postgres_accepting; then
      return 0
    fi
    sleep 1
  done

  echo "Postgres at $(postgres_host):$(postgres_port) never started accepting connections" >&2
  return 1
}
