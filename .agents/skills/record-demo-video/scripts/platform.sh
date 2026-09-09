#!/usr/bin/env bash
# Shared by record.sh and qa/scripts/qa.sh: everything that differs between macOS and Linux.
# Source it, do not run it.

# Chrome sits in a different place on every platform, so guess in order and let CHROME_BIN win.
find_chrome() {
  if [ -n "${CHROME_BIN:-}" ]; then
    command -v "$CHROME_BIN" 2>/dev/null && return 0
    echo "CHROME_BIN is set to '$CHROME_BIN' but that is not an executable" >&2
    return 1
  fi

  local candidate
  for candidate in \
    google-chrome google-chrome-stable chromium chromium-browser /snap/bin/chromium \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium"
  do
    command -v "$candidate" 2>/dev/null && return 0
  done

  echo "no Chrome or Chromium found. Install one, or point CHROME_BIN at the binary." >&2
  return 1
}

# Launches headless Chrome on a scratch profile and prints its pid, so the caller can trap a kill.
# Never the user's real profile: the demo logs in as someone else and would clobber their session.
# The extra[@] expansion is guarded: macOS ships bash 3.2, where an empty array under `set -u` is an
# unbound variable, so a mac with no Linux or root flags to add never got Chrome started at all.
launch_chrome() { # <debug-port> <profile-dir> <log-file>
  local debug_port="$1" profile="$2" log="$3" chrome extra=()
  chrome="$(find_chrome)" || return 1

  # /dev/shm is small in containers and a shared-memory crash looks exactly like a hung page.
  if [ "$(uname -s)" = Linux ]; then extra+=(--disable-gpu --disable-dev-shm-usage); fi
  # Chrome refuses to run as root with a sandbox, which is how it lands in a docker-based worktree.
  if [ "$(id -u)" = 0 ]; then extra+=(--no-sandbox); fi

  "$chrome" --headless=new --remote-debugging-port="$debug_port" \
    --user-data-dir="$profile" --window-size=1280,860 \
    --hide-scrollbars --force-device-scale-factor=1 \
    --disable-web-security \
    --no-first-run --no-default-browser-check ${extra[@]+"${extra[@]}"} about:blank >"$log" 2>&1 &
  printf '%s\n' "$!"
}

# Quiet on purpose: the first attempts fail while Chrome boots, which is not worth reporting.
wait_for_cdp() { # <debug-port>
  for _ in $(seq 20); do
    curl -fs -o /dev/null "http://127.0.0.1:$1/json/version" && return 0
    sleep 0.5
  done
  return 1
}

# node is mise-managed in this repo, so a non-interactive shell has no `node` on PATH and every bare
# call died mid-run. Resolve it once into NODE_CMD; callers run "${NODE_CMD[@]}" instead of `node`.
resolve_node() {
  local resolved
  if [ -n "${NODE_BIN:-}" ]; then NODE_CMD=("$NODE_BIN"); return 0; fi
  if command -v node >/dev/null 2>&1; then NODE_CMD=(node); return 0; fi
  # `mise which` is run from the repo (that is where the toolchain is pinned) and prints an absolute
  # path, so the caller stays free to work from any directory.
  if command -v mise >/dev/null 2>&1 &&
     resolved="$(cd "${ROOT:-$PWD}" && mise which node 2>/dev/null)" && [ -x "$resolved" ]; then
    NODE_CMD=("$resolved")
    return 0
  fi

  echo "no node on PATH, and none installed under mise." >&2
  echo "  run 'mise install' in the repo, or point NODE_BIN at a node binary." >&2
  return 1
}
