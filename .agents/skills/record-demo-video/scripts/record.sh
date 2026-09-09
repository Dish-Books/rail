#!/usr/bin/env bash
# Records a scenario against the running dev app and encodes it to mp4.
#
#   .claude/skills/record-demo-video/scripts/record.sh <scenario.mjs> <output.mp4> [email]
#
# Launches its own headless Chrome (never the user's profile), mints a magic login link, runs the
# scenario, encodes the frames, then cleans up. Needs the dev server already running.
set -euo pipefail

SCENARIO="${1:?usage: record.sh <scenario.mjs> <output.mp4> [email]}"
OUTPUT="${2:?usage: record.sh <scenario.mjs> <output.mp4> [email]}"

ROOT="$(git rev-parse --show-toplevel)"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SKILL_DIR/platform.sh"
# Fails here rather than after Chrome is up and a login link has been minted.
resolve_node

read_env() { grep -E "^$1=" "$ROOT/.env" 2>/dev/null | tail -1 | cut -d= -f2 || true; }

# Same default as qa.sh: the dev's own login from .env, not a hardcoded address that may not exist
# in this worktree's database.
EMAIL="${3:-$(read_env DEV_LOGIN_EMAIL)}"
EMAIL="${EMAIL:-admin@dishbooks.com}"

# Every worktree gets its own port block from scripts/setup-worktree.sh, so never hardcode 4000.
# DEMO_PORT wins, for recording against a server started on a spare port rather than the dev's own.
PORT="${DEMO_PORT:-$(read_env PORT)}"
PORT="${PORT:-4000}"

# Offset the debug port by the worktree slot too, so two worktrees can record at the same time.
SLOT="$(read_env WORKTREE_SLOT)"
DEBUG_PORT="${DEMO_DEBUG_PORT:-$((9222 + ${SLOT:-0}))}"
FPS="${DEMO_FPS:-8}"
FRAME_DIR="${DEMO_FRAME_DIR:-${TMPDIR:-/tmp}/demo-frames-$$}"

# A bare filename lands in the video directory, which sits beside the worktrees rather than inside
# one: videos then survive post-merge-cleanup and can never be committed by accident. Anything with a
# slash in it is taken exactly as written. Override the directory with DEMO_VIDEO_DIR, in the
# environment or in .env.
VIDEO_DIR="${DEMO_VIDEO_DIR:-$(read_env DEMO_VIDEO_DIR)}"
VIDEO_DIR="${VIDEO_DIR:-$(dirname "$ROOT")/qa_videos}"
case "$OUTPUT" in
  */*) ;;
  *) mkdir -p "$VIDEO_DIR"; OUTPUT="$VIDEO_DIR/$OUTPUT" ;;
esac

if ! curl -fsS -o /dev/null "http://localhost:$PORT/login"; then
  echo "no dev server on port $PORT: start it first (preview_start, or mix phx.server)" >&2
  exit 1
fi

PROFILE="${TMPDIR:-/tmp}/demo-chrome-profile-$DEBUG_PORT"
CHROME_PID="$(launch_chrome "$DEBUG_PORT" "$PROFILE" "${TMPDIR:-/tmp}/demo-chrome-$DEBUG_PORT.log")"
trap 'kill "$CHROME_PID" 2>/dev/null || true' EXIT
wait_for_cdp "$DEBUG_PORT" || { echo "Chrome never opened its debug port $DEBUG_PORT" >&2; exit 1; }

cd "$ROOT"
# `set -e` plus `pipefail` would kill the script on grep's no-match exit before the message below
# ever printed, so the whole run failed with no output at all. Capture first, then report.
set +e
LOGIN_OUTPUT="$(mise exec -- mix run "$SKILL_DIR/login_link.exs" "$EMAIL" "$PORT" 2>&1)"
set -e
LOGIN_URL="$(printf '%s\n' "$LOGIN_OUTPUT" | grep MAGIC_LINK | awk '{print $2}' || true)"
if [ -z "$LOGIN_URL" ]; then
  echo "could not mint a login link for $EMAIL" >&2
  echo "  set DEV_LOGIN_EMAIL in $ROOT/.env, or pass the address as the third argument." >&2
  echo "  login_link.exs said:" >&2
  printf '%s\n' "$LOGIN_OUTPUT" | tail -5 >&2
  exit 1
fi

DEMO_FRAME_DIR="$FRAME_DIR" DEMO_PORT="$PORT" DEMO_DEBUG_PORT="$DEBUG_PORT" DEMO_LOGIN_URL="$LOGIN_URL" \
  DEMO_DRIVER="$SKILL_DIR/driver.mjs" "${NODE_CMD[@]}" "$SCENARIO"

"$SKILL_DIR/encode.sh" "$FRAME_DIR" "$OUTPUT" "$FPS"
echo "FRAMES_KEPT $FRAME_DIR"
