#!/usr/bin/env bash
# Session manager for a QA pass against the running dev app.
#
#   qa.sh start [email]    start the dev server if it is down, launch a scratch Chrome, log in
#   qa.sh run <check.mjs>  run one check script against the live browser session
#   qa.sh log [lines]      tail the dev server log (only if this script started the server)
#   qa.sh stop             kill Chrome, and the server only if this script started it
#
# `start` once, `run` many times: Chrome stays up between checks so the session, the scroll position,
# and the cookies survive, and a check script is a few lines rather than a whole boot sequence.
set -euo pipefail

CMD="${1:?usage: qa.sh start|run|log|stop [...]}"
ROOT="$(git rev-parse --show-toplevel)"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$SKILL_DIR/../../record-demo-video/scripts"
. "$DEMO_DIR/platform.sh"

# Every worktree gets its own port block from scripts/setup-worktree.sh, so never hardcode 4000.
read_env() { grep -E "^$1=" "$ROOT/.env" 2>/dev/null | tail -1 | cut -d= -f2 || true; }
PORT="$(read_env PORT)"; PORT="${PORT:-4000}"
SLOT="$(read_env WORKTREE_SLOT)"; SLOT="${SLOT:-0}"
DEBUG_PORT=$((9322 + SLOT))

STATE="${TMPDIR:-/tmp}/dishbooks-qa-$SLOT"
ENV_FILE="$STATE/session.env"
SERVER_LOG="$STATE/server.log"

# Deliberately not `curl -f`: a Phoenix that boots without its database answers every request with a
# 503 error page, and treating that as "down" would start a second server onto a taken port.
# stderr dropped because this is polled in a boot loop: "connection refused" is the expected answer
# for the first minute and printing it once a second reads like a failure.
server_up() { curl -sS -o /dev/null "http://localhost:$PORT/login" 2>/dev/null; }
login_status() { curl -sS -o /dev/null -w '%{http_code}' "http://localhost:$PORT/login"; }

case "$CMD" in
  start)
    # Before anything is started, so a missing node fails here rather than half way through a boot.
    resolve_node
    EMAIL="${2:-$(read_env DEV_LOGIN_EMAIL)}"
    EMAIL="${EMAIL:-admin@dishbooks.com}"
    mkdir -p "$STATE"
    : >"$ENV_FILE"

    if server_up; then
      echo "dev server already up on $PORT (left alone; qa.sh stop will not touch it)"
    else
      echo "starting dev server on $PORT, logging to $SERVER_LOG"
      (cd "$ROOT" && nohup mise exec -- mix phx.server >"$SERVER_LOG" 2>&1 &
        echo "QA_SERVER_PID=$!" >>"$ENV_FILE")
      # First boot compiles, so allow well past the usual few seconds before giving up.
      for _ in $(seq 120); do server_up && break; sleep 1; done
      server_up || { echo "server never came up; see $SERVER_LOG" >&2; tail -30 "$SERVER_LOG" >&2; exit 1; }
    fi

    # Port 4000 is a popular default: make sure whatever answered is actually this app before QA'ing
    # someone else's server for twenty minutes.
    if ! curl -sSI "http://localhost:$PORT/login" | grep -qi '_dishbooks_key'; then
      echo "the server on port $PORT is not DishBooks (no _dishbooks_key session cookie)." >&2
      echo "another project is squatting the port - stop it, or set PORT in .env." >&2
      exit 1
    fi

    STATUS="$(login_status)"
    case "$STATUS" in
      2*|3*) ;;
      *)
        echo "GET /login returns $STATUS - the app is broken before QA starts." >&2
        echo "Diagnose it and tell the dev; do not reset or recreate the dev database." >&2
        curl -sS "http://localhost:$PORT/login" | grep -o '<title>[^<]*</title>' | head -1 >&2 || true
        exit 1
        ;;
    esac

    CHROME_PID="$(launch_chrome "$DEBUG_PORT" "$STATE/chrome-profile" "$STATE/chrome.log")"
    echo "QA_CHROME_PID=$CHROME_PID" >>"$ENV_FILE"
    # Killed here rather than left for `qa.sh stop`: a Chrome that never answered is of no use to
    # anyone, and leaving it holding the port makes the next start fail the same way.
    wait_for_cdp "$DEBUG_PORT" || {
      kill "$CHROME_PID" 2>/dev/null || true
      echo "Chrome never opened its debug port $DEBUG_PORT; see $STATE/chrome.log" >&2
      exit 1
    }

    # Dev-only states that make the app unusable before QA even starts - see usable_login.exs. Run
    # before the link is minted so the first page load is already past them.
    set +e
    REPAIRS="$(cd "$ROOT" && mise exec -- mix run "$SKILL_DIR/usable_login.exs" "$EMAIL" 2>&1)"
    set -e
    printf '%s\n' "$REPAIRS" | grep USABLE_LOGIN >&2 || {
      echo "could not check whether $EMAIL can use the app; usable_login.exs said:" >&2
      printf '%s\n' "$REPAIRS" | tail -5 >&2
    }

    # Magic link, never a typed password.
    # `set -e` plus `pipefail` would kill the script on grep's no-match exit before the message below
    # ever printed, so an unknown email failed with no output at all. Capture first, then report.
    set +e
    LOGIN_OUTPUT="$(cd "$ROOT" && mise exec -- mix run "$DEMO_DIR/login_link.exs" "$EMAIL" "$PORT" 2>&1)"
    set -e
    LOGIN_URL="$(printf '%s\n' "$LOGIN_OUTPUT" | grep MAGIC_LINK | awk '{print $2}' || true)"
    if [ -z "$LOGIN_URL" ]; then
      echo "could not mint a login link for $EMAIL" >&2
      echo "  set DEV_LOGIN_EMAIL in $ROOT/.env, or pass the address as the second argument." >&2
      echo "  login_link.exs said:" >&2
      printf '%s\n' "$LOGIN_OUTPUT" | tail -5 >&2
      exit 1
    fi

    QA_PORT="$PORT" QA_DEBUG_PORT="$DEBUG_PORT" QA_SCRATCH="$STATE/shots" \
      QA_DRIVER="$SKILL_DIR/qa-driver.mjs" QA_LOGIN_URL="$LOGIN_URL" \
      "${NODE_CMD[@]}" --input-type=module -e '
        const { openQaSession } = await import(process.env.QA_DRIVER)
        const qa = await openQaSession({
          port: Number(process.env.QA_PORT),
          debugPort: Number(process.env.QA_DEBUG_PORT),
          scratchDir: process.env.QA_SCRATCH
        })
        await qa.login(process.env.QA_LOGIN_URL)
        // Structural, not copy: a successful magic-link login redirects off /login, while a failed
        // one sits on /login/<token>. Sniffing for "log in"/"sign in" in the page text flagged a
        // *successful* login as failed, because the settings page it lands on says "Sign in with
        // Google".
        const path = await qa.evaluate("location.pathname")
        if (/^\/login/.test(path)) throw new Error(`login did not take (still on ${path})`)
        await qa.finish()
      '

    cat >>"$ENV_FILE" <<EOF
QA_PORT=$PORT
QA_DEBUG_PORT=$DEBUG_PORT
QA_SCRATCH=$STATE/shots
QA_DRIVER=$SKILL_DIR/qa-driver.mjs
EOF
    echo "logged in as $EMAIL; screenshots go to $STATE/shots"
    ;;

  run)
    CHECK="${2:?usage: qa.sh run <check.mjs>}"
    [ -f "$ENV_FILE" ] || { echo "no session: run qa.sh start first" >&2; exit 1; }
    set -a; . "$ENV_FILE"; set +a
    resolve_node
    cd "$ROOT"
    "${NODE_CMD[@]}" "$CHECK"
    ;;

  log)
    tail -n "${2:-80}" "$SERVER_LOG"
    ;;

  stop)
    [ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
    [ -n "${QA_CHROME_PID:-}" ] && kill "$QA_CHROME_PID" 2>/dev/null || true
    # Only ever stops a server this script started; one the dev was already running is left alone.
    [ -n "${QA_SERVER_PID:-}" ] && kill "$QA_SERVER_PID" 2>/dev/null || true
    rm -f "$ENV_FILE"
    echo "qa session stopped"
    ;;

  *) echo "unknown command $CMD" >&2; exit 1 ;;
esac
