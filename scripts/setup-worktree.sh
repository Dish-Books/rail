#!/usr/bin/env bash
#
# Set up a git worktree to run its own Phoenix server alongside the primary
# checkout and every other worktree. The dishbooks script of the same name, minus
# the docker stack: Rail's Postgres is whatever answers at DB_HOST/DB_PORT.
#
# Isolation is by database name: each worktree gets a `DB_SUFFIX`, so its own
# `rail_dev<suffix>` / `rail_test<suffix>`, and a deterministic "slot" written to a
# gitignored `.env` that mise loads:
#
#   slot 0 -> the primary checkout: default ports, no DB_SUFFIX
#   slot N -> PORT/TEST_PORT 4050/4052 + N*100, DB_SUFFIX=_wtN
#
# The +50 keeps clear of dishbooks' worktrees, which take 4000 + N*100 on the same
# machine. A worktree Rail made (RAIL_WORKTREE_SLOT and RAIL_PORT_BASE set) takes
# PORT/TEST_PORT = RAIL_PORT_BASE and +2, DB_SUFFIX=_rail<slot>, WORKTREE_SLOT =
# 1000 + its Rail slot.
#
# A fresh worktree inherits the developer's own vars (secrets, the vault key, ...)
# from the primary checkout's `.env`. Only the managed block is rewritten on rerun.
#
# `deps` and `_build` are copied from the primary checkout (copy-on-write where
# supported) so the first compile is incremental. `rail_dev<suffix>` is created as
# a copy of `rail_dev`; anything that stops the copy exits non-zero rather than
# leaving an empty database.
#
# Usage:
#   scripts/setup-worktree.sh                    # .env, copy db
#   scripts/setup-worktree.sh --no-db            # write .env only
#   scripts/setup-worktree.sh --force            # reassign a slot even if .env exists
#   scripts/setup-worktree.sh --force-db-copy    # recopy over an existing dev database
#   scripts/setup-worktree.sh --force-cache-copy # recopy deps/_build over existing ones
set -euo pipefail

PORT_STEP=100
CREATE_DB=1
FORCE=0
FORCE_DB_COPY=0
FORCE_CACHE_COPY=0
for arg in "$@"; do
  case "$arg" in
    --no-db) CREATE_DB=0 ;;
    --force) FORCE=1 ;;
    --force-db-copy) FORCE_DB_COPY=1 ;;
    --force-cache-copy) FORCE_CACHE_COPY=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

print_next_steps() {
  echo "Done. Next:"
  echo "  mise exec -- mix setup"
  echo "  mise exec -- iex -S mix phx.server"
}

worktree_root="$(git rev-parse --show-toplevel)"
env_file="$worktree_root/.env"

# The primary checkout is the first entry in `git worktree list`.
primary_root="$(git worktree list --porcelain | sed -n 's/^worktree //p' | head -1)"

# The shared Postgres's address, as the primary checkout's .env has it. Read before
# the .env write below, which may be that very file.
env_value() {
  value="$(grep -E "^$1=" "$primary_root/.env" 2>/dev/null | head -1 | cut -d= -f2 || true)"
  [ -n "$value" ] && printf '%s' "$value" || printf '%s' "$2"
}
db_host="$(env_value DB_HOST localhost)"
db_port="$(env_value DB_PORT 5432)"

# postgres/postgres, the credentials config/{dev,test}.exs hardcode.
in_db() { PGHOST="$db_host" PGPORT="$db_port" PGUSER=postgres PGPASSWORD=postgres "$@"; }

is_primary=0
[ "$worktree_root" = "$primary_root" ] && is_primary=1

# Rail hands each of its worktrees a slot unique across every project it runs, and
# ports to go with it. 1000 up is a range the scan below never reaches.
rail_slot="${RAIL_WORKTREE_SLOT:-}"
rail_port_base="${RAIL_PORT_BASE:-}"
rail_slot_offset=1000
lock_dir=""

if [ "$is_primary" -eq 0 ] && [ -n "$rail_slot" ] && [ -n "$rail_port_base" ]; then
  slot=$((rail_slot_offset + rail_slot))
  app_port="$rail_port_base"
  test_port=$((rail_port_base + 2))
  db_suffix="_rail${rail_slot}"
  # Rail reuses a freed slot, so a new worktree on it must not inherit the last one's database.
  [ -f "$env_file" ] || FORCE_DB_COPY=1
else
  # Slot allocation runs under a lock, so worktrees started at once never collide.
  # mkdir is atomic on macOS and Linux, where flock is not everywhere.
  lock_dir="/tmp/rail-worktree-slot-$(id -u).lock"
  lock_waited=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    lock_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
      rm -rf "$lock_dir"
      continue
    fi
    if [ "$lock_waited" -ge 60 ]; then
      echo "Timed out waiting for ${lock_dir}." >&2
      echo "  Remove it by hand if no other setup-worktree.sh is running." >&2
      exit 1
    fi
    sleep 1
    lock_waited=$((lock_waited + 1))
  done
  echo $$ > "$lock_dir/pid"
  trap 'rm -rf "$lock_dir"' EXIT
  trap 'rm -rf "$lock_dir"; exit 130' INT
  trap 'rm -rf "$lock_dir"; exit 143' TERM

  # Slots claimed by sibling worktrees, space-padded for bash 3.2.
  used_slots=" "
  [ "$is_primary" -eq 0 ] && used_slots=" 0 "
  existing_slot=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        wt_path="${line#worktree }"
        wt_env="$wt_path/.env"
        [ -f "$wt_env" ] || continue
        slot="$(grep -E '^WORKTREE_SLOT=' "$wt_env" 2>/dev/null | head -1 | cut -d= -f2 || true)"
        [ -n "$slot" ] || continue
        if [ "$wt_path" = "$worktree_root" ]; then
          existing_slot="$slot"
        else
          used_slots="${used_slots}${slot} "
        fi
        ;;
    esac
  done < <(git worktree list --porcelain)

  # An existing rail_dev_wt<N> holds slot N too, even if its worktree's .env is gone.
  for db_name in $(in_db psql -qtAX -d postgres \
    -c "SELECT datname FROM pg_database WHERE datname ~ '^rail_dev_wt[0-9]+\$'" 2>/dev/null || true); do
    s="${db_name#rail_dev_wt}"
    [ "$s" = "$existing_slot" ] && continue
    used_slots="${used_slots}${s} "
  done

  # A slot Rail handed out is not one this scan can reuse: its ports came from Rail.
  case "$existing_slot" in *[!0-9]*) existing_slot="" ;; esac
  [ -n "$existing_slot" ] && [ "$existing_slot" -ge "$rail_slot_offset" ] && existing_slot=""

  if [ "$is_primary" -eq 1 ]; then
    slot=0
  elif [ -n "$existing_slot" ] && [ "$FORCE" -eq 0 ]; then
    slot="$existing_slot"
  else
    slot=1
    while [ "${used_slots#* $slot }" != "$used_slots" ]; do
      slot=$((slot + 1))
    done
  fi

  if [ "$slot" -eq 0 ]; then
    app_port=4000
    test_port=4002
    db_suffix=""
  else
    app_port=$((4050 + slot * PORT_STEP))
    test_port=$((4052 + slot * PORT_STEP))
    db_suffix="_wt${slot}"
  fi
fi
dev_db="rail_dev${db_suffix}"

# The vars we own; everything else in the .env is the developer's and kept verbatim.
managed_re='^(WORKTREE_SLOT|DB_SUFFIX|PORT|TEST_PORT|DB_HOST|DB_PORT)='

# Our own .env on a rerun, the primary checkout's for a fresh worktree.
source_env=""
inherited_from=""
if [ -f "$env_file" ]; then
  source_env="$env_file"
elif [ "$is_primary" -eq 0 ] && [ -f "$primary_root/.env" ]; then
  source_env="$primary_root/.env"
  inherited_from="$primary_root/.env"
fi

preserved=""
if [ -n "$source_env" ]; then
  preserved="$(awk -v re="$managed_re" '
    /^# >>> setup-worktree managed block/ { inblock=1; next }
    /^# <<< setup-worktree managed block/ { inblock=0; next }
    inblock { next }
    $0 ~ re { next }
    { if (!started && $0 ~ /^[[:space:]]*$/) next; started = 1; print }
  ' "$source_env")"
fi

# source_env is read in full above, so truncating env_file is safe when they match.
{
  echo "# >>> setup-worktree managed block (slot ${slot}) >>>"
  echo "# Managed by scripts/setup-worktree.sh — rerun the script to reassign."
  echo "# Your own vars go OUTSIDE this block; they are kept."
  echo "WORKTREE_SLOT=${slot}"
  echo "DB_SUFFIX=${db_suffix}"
  echo "PORT=${app_port}"
  echo "TEST_PORT=${test_port}"
  echo "DB_HOST=${db_host}"
  echo "DB_PORT=${db_port}"
  echo "# <<< setup-worktree managed block <<<"
  if [ -n "$preserved" ]; then
    echo ""
    printf '%s\n' "$preserved"
  fi
} > "$env_file"

echo "Worktree slot ${slot}"
echo "  Phoenix     http://localhost:${app_port}"
echo "  Test server localhost:${test_port}"
echo "  Postgres    ${db_host}:${db_port} (shared)"
echo "  Databases   ${dev_db} / rail_test${db_suffix}"
[ -n "$inherited_from" ] && echo "  inherited developer vars from ${inherited_from}"
echo "  wrote ${env_file}"

# Our slot is on disk now, so a sibling scanning for free slots will see it.
trap - EXIT INT TERM
[ -n "$lock_dir" ] && rm -rf "$lock_dir"

# Copies land in a temp dir and are moved in, so an interrupt can't leave a partial
# cache. `-c` is macOS clonefile, `--reflink=auto` GNU's; each rejects the other.
copy_cache_dir() {
  cache_dir="$1"
  source_dir="$primary_root/$cache_dir"
  target_dir="$worktree_root/$cache_dir"
  temp_dir="$worktree_root/.${cache_dir}.setup-worktree-tmp"

  if [ ! -d "$source_dir" ]; then
    echo "  ${cache_dir}: primary checkout has none, skipped"
    return 0
  elif [ -d "$target_dir" ] && [ "$FORCE_CACHE_COPY" -eq 0 ]; then
    echo "  ${cache_dir}: already present, kept (recopy with --force-cache-copy)"
    return 0
  fi

  copied=0
  for cp_opts in "-Rc" "-R --reflink=auto" "-R"; do
    rm -rf "$temp_dir"
    # Unquoted on purpose: cp_opts is a list of flags.
    if cp $cp_opts "$source_dir" "$temp_dir" 2>/dev/null; then copied=1; break; fi
  done
  if [ "$copied" -eq 0 ]; then
    rm -rf "$temp_dir"
    echo "  ${cache_dir}: copy failed, will be rebuilt by 'mix setup'" >&2
    return 0
  fi
  rm -rf "$target_dir"
  mv "$temp_dir" "$target_dir"
  echo "  ${cache_dir}: copied from ${source_dir}"
}

if [ "$is_primary" -eq 0 ]; then
  echo "Warming compile caches..."
  copy_cache_dir deps
  copy_cache_dir _build
fi

# A worktree is a new directory to mise, so its mise.toml starts untrusted.
if command -v mise >/dev/null 2>&1; then
  ( cd "$worktree_root" && mise trust --quiet ) || echo "  'mise trust' failed — run it by hand" >&2
fi

if [ "$CREATE_DB" -eq 0 ]; then
  echo "Skipped the database (--no-db), so ${dev_db} was not created."
  exit 0
fi

db_ready=0
for _ in $(seq 1 15); do
  if in_db pg_isready -q -d postgres >/dev/null 2>&1; then db_ready=1; break; fi
  sleep 1
done
if [ "$db_ready" -eq 0 ]; then
  echo "Cannot copy rail_dev: nothing is accepting connections at ${db_host}:${db_port}." >&2
  echo "  Start your Postgres, or set DB_HOST/DB_PORT in ${primary_root}/.env, then rerun." >&2
  exit 1
fi

if [ "$is_primary" -eq 1 ]; then
  echo "Skipped copying rail_dev (this is the primary checkout — it *is* the source)."
  print_next_steps
  exit 0
fi

# Every probe tells "the query answered" from "the query failed": swallowing a
# failure is what silently starts a worktree on an empty database.
probe() {
  probe_out=""
  probe_status=0
  set +e
  probe_out="$("$@" 2>&1)"
  probe_status=$?
  set -e
}

probe in_db psql -qtAX -d postgres -c "SELECT 1 FROM pg_database WHERE datname = 'rail_dev'"
if [ "$probe_status" -ne 0 ]; then
  echo "Cannot copy rail_dev: could not query Postgres." >&2
  echo "  psql said: ${probe_out}" >&2
  exit 1
elif [ "$(printf '%s' "$probe_out" | tr -d '[:space:]')" != "1" ]; then
  echo "Cannot copy rail_dev: there is no rail_dev database." >&2
  echo "  Run 'mise exec -- mix setup' in ${primary_root}, then rerun this script." >&2
  exit 1
fi

probe in_db psql -qtAX -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '${dev_db}'"
if [ "$probe_status" -ne 0 ]; then
  echo "Cannot copy rail_dev: could not query Postgres for ${dev_db}." >&2
  echo "  psql said: ${probe_out}" >&2
  exit 1
fi

# A target with tables holds work we must not throw away; unreadable means unknown.
if [ "$(printf '%s' "$probe_out" | tr -d '[:space:]')" = "1" ]; then
  probe in_db psql -qtAX -d "$dev_db" -c "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'"
  if [ "$probe_status" -ne 0 ]; then
    echo "Cannot copy rail_dev: could not read ${dev_db}." >&2
    echo "  psql said: ${probe_out}" >&2
    echo "  Refusing to drop a database whose contents are unknown." >&2
    exit 1
  fi
  table_count="$(printf '%s' "$probe_out" | tr -d '[:space:]')"
  case "$table_count" in '' | *[!0-9]*) table_count=0 ;; esac
else
  table_count=0
fi

if [ "$table_count" -gt 0 ] && [ "$FORCE_DB_COPY" -eq 0 ]; then
  echo "Kept existing ${dev_db} (${table_count} tables). Recopy with --force-db-copy."
else
  echo "Copying rail_dev -> ${dev_db}..."
  in_db dropdb --if-exists --force "$dev_db"
  # A template copy is near-instant but refused while anything is connected to
  # rail_dev, i.e. whenever the primary's server runs. A dump has no such limit.
  if in_db createdb -T rail_dev "$dev_db" 2>/dev/null; then
    echo "  copied ${dev_db} (template copy)"
  else
    echo "  rail_dev is in use — copying via pg_dump instead"
    in_db createdb "$dev_db"
    in_db pg_dump --no-owner --no-privileges -d rail_dev \
      | in_db psql -q -o /dev/null -v ON_ERROR_STOP=1 -d "$dev_db"
    echo "  copied ${dev_db}"
  fi
fi

print_next_steps
