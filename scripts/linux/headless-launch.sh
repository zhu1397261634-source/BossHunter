#!/usr/bin/env bash
# BossHunter headless Linux launcher.
#
# Starts a headless Chrome with CDP enabled, then launches the BossHunter web
# dashboard. Designed for containers / NAS / headless Linux servers where a
# desktop browser is unavailable.
#
# Usage:
#   ./scripts/linux/headless-launch.sh              # start Chrome + dashboard
#   ./scripts/linux/headless-launch.sh --check      # verify prerequisites only
#   ./scripts/linux/headless-launch.sh --no-chrome  # dashboard only (Chrome already running)
#
# Environment:
#   ANTHROPIC_API_KEY   required for AI scoring / greetings
#   ANTHROPIC_BASE_URL  optional, e.g. https://tokencenter.rynnova.com
#   PLAYWRIGHT_BROWSERS_PATH  where the chromium build lives

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

VENV="$REPO_ROOT/.venv"
PY="$VENV/bin/python"
CHROME_PORT="${BOSSHUNTER_CHROME_PORT:-9222}"
PROFILE_DIR="${BOSSHUNTER_CHROME_PROFILE:-/tmp/bosshunter-chrome-profile}"
WEB_PORT="${BOSSHUNTER_WEB_PORT:-8686}"
BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/tmp/pw-browsers}"

log()  { printf '\033[1;34m[bosshunter]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bosshunter]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bosshunter]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Proxy variables MUST be cleared.
#
# The environment this was developed in exported NO_PROXY="localhost,127.0.0.1,::1,[::1]".
# The bracketed IPv6 form is not valid for httpx2's URL parser and raises
#     httpx2.InvalidURL: Invalid port: ':1]'
# Additionally, when any *_PROXY variable is present BossHunter builds a
# custom `httpx.Client` and hands it to the Anthropic SDK, but anthropic>=2.12
# requires `httpx2.Client`. The mismatch raises
#     TypeError: Invalid `http_client` argument; `httpx.Client` is from the
#     `httpx` package, but this SDK uses `httpx2`
# Both failures surface as a silent `None` return from the AI call, so the
# dashboard appears to work while scoring never produces output.
# ---------------------------------------------------------------------------
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
unset http_proxy https_proxy all_proxy no_proxy

# ---------------------------------------------------------------------------
# 2. Locate a usable Chrome build.
#
# The full `chromium-*/chrome-linux64/chrome` binary crashes on this class of
# machine (Trace/breakpoint trap, crashpad handler aborts with
# "--database is required"). Only the headless shell survives, so we probe for
# it first and fall back to the full build.
# ---------------------------------------------------------------------------
find_chrome() {
  local candidates=(
    "${BROWSERS_PATH}/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell"
    "${BROWSERS_PATH}/chromium-*/chrome-linux64/chrome"
    "${HOME}/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell"
    "${HOME}/.cache/ms-playwright/chromium-*/chrome-linux64/chrome"
  )
  local c f
  for c in "${candidates[@]}"; do
    # Resolve the glob to concrete paths; "$c" alone is still a pattern.
    for f in $c; do
      if [ -x "$f" ]; then
        echo "$f"
        return 0
      fi
    done
  done
  return 1
}

# ---------------------------------------------------------------------------
# 3. Preflight checks
# ---------------------------------------------------------------------------
preflight() {
  log "running preflight checks"

  command -v node >/dev/null 2>&1 || die "node not found (Node.js 22+ required)"
  local node_major
  node_major="$(node --version | sed 's/^v//' | cut -d. -f1)"
  if [ "$node_major" -lt 22 ]; then
    warn "node v$(node --version) detected; Node.js 22+ is recommended"
  else
    log "node $(node --version) ok"
  fi

  if [ -x "$PY" ]; then
    log "python venv ok: $VENV"
  else
    die "python venv missing. Run: python3 -m venv .venv && .venv/bin/pip install -e ."
  fi

  if [ ! -d "$REPO_ROOT/src/bosshunter/web/frontend/dist" ]; then
    die "frontend/dist missing. Run: npm --prefix src/bosshunter/web/frontend ci && npm --prefix src/bosshunter/web/frontend run build"
  fi
  log "frontend build ok"

  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    warn "ANTHROPIC_API_KEY is not set - AI scoring will not work"
  else
    log "ANTHROPIC_API_KEY present"
  fi

  local chrome
  if chrome="$(find_chrome)"; then
    log "chrome found: $chrome"
  else
    warn "no chrome build found under $BROWSERS_PATH"
    warn "install one with: PLAYWRIGHT_BROWSERS_PATH=$BROWSERS_PATH .venv/bin/python -m patchright install chromium"
  fi
}

# ---------------------------------------------------------------------------
# 4. Chrome with CDP
# ---------------------------------------------------------------------------
start_chrome() {
  if curl -s -m 5 "http://127.0.0.1:${CHROME_PORT}/json/version" >/dev/null 2>&1; then
    log "chrome already listening on port $CHROME_PORT - reusing it"
    return 0
  fi

  local chrome
  chrome="$(find_chrome)" || die "no chrome build found"

  mkdir -p "$PROFILE_DIR"
  log "starting headless chrome on port $CHROME_PORT"

  "$chrome" \
    --no-sandbox \
    --disable-gpu \
    --disable-dev-shm-usage \
    --disable-crash-reporter \
    --remote-debugging-port="$CHROME_PORT" \
    --remote-debugging-address=127.0.0.1 \
    --user-data-dir="$PROFILE_DIR" \
    about:blank > /tmp/bosshunter-chrome.log 2>&1 &

  local waited=0
  while [ "$waited" -lt 20 ]; do
    if curl -s -m 3 "http://127.0.0.1:${CHROME_PORT}/json/version" >/dev/null 2>&1; then
      log "chrome CDP ready after ${waited}s"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  warn "chrome did not expose CDP within 20s - check /tmp/bosshunter-chrome.log"
  return 1
}

# ---------------------------------------------------------------------------
# 5. Main
# ---------------------------------------------------------------------------
START_CHROME=1
for arg in "$@"; do
  case "$arg" in
    --check)     START_CHROME=0; preflight; exit 0 ;;
    --no-chrome) START_CHROME=0 ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
  esac
done

preflight

if [ "$START_CHROME" -eq 1 ]; then
  start_chrome || true
fi

export PLAYWRIGHT_BROWSERS_PATH="$BROWSERS_PATH"

log "starting dashboard on http://127.0.0.1:${WEB_PORT}"
exec "$PY" -m bosshunter.main web
