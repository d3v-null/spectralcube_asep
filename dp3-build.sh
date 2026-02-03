#!/usr/bin/env bash
set -euo pipefail

log="dp3-build.log"
pidfile="dp3-build.pid"
statusfile="dp3-build.status"

# If a previous run left a stale pidfile, mark it.
if [[ -f "$pidfile" ]]; then
  oldpid="$(cat "$pidfile" 2>/dev/null || true)"
  if [[ -n "$oldpid" ]] && ! kill -0 "$oldpid" 2>/dev/null; then
    echo "stale:${oldpid}" > "$statusfile" || true
    rm -f "$pidfile" || true
  fi
fi

# Detach-friendly logging: write everything to the log file directly.
# (Avoid tee/pipes so we don't die on SIGHUP/SIGPIPE when the parent exits.)
: > "$log"
exec >>"$log" 2>&1

# Record supervisor PID for monitoring.
echo "$$" > "$pidfile"
echo "running" > "$statusfile"

cleanup() {
  rc="$?"
  if [[ "$rc" -eq 0 ]]; then
    echo "success" > "$statusfile" || true
  else
    echo "failed:$rc" > "$statusfile" || true
  fi
  rm -f "$pidfile" || true
}
trap cleanup EXIT INT TERM HUP

{
  echo "=== $(date -u '+%F %T UTC') starting dp3 build ==="
  echo "pwd=$(pwd)"
  echo "docker=$(docker --version || true)"
  echo "pid=$$"
} 

# Build
set +e
DOCKER_BUILDKIT=1 docker build \
  --progress=plain \
  -f dp3.Dockerfile \
  -t d3vnull0/dp3-mwa:latest \
  .
rc=$?
set -e

echo "=== $(date -u '+%F %T UTC') dp3-build done rc=$rc ==="

# Optional: notify Discord via OpenClaw CLI (if installed).
if command -v openclaw >/dev/null 2>&1; then
  openclaw message send --channel discord --target 1467366630265979117 \
    --message "dp3-build done rc=$rc. Tail:\n$(tail -n 15 \"$log\")" || true
fi

exit "$rc"
