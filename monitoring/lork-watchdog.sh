#!/usr/bin/env bash
# Temporary workaround for https://github.com/The-Treeline-Project/Lork-Releases/issues/1
#
# Follows Lork's logs and restarts the container when it gets wedged. Two triggers:
#   1. A browser slot stuck reconnecting to a dead DevTools port
#      ("Connect call failed ('127.0.0.1', <port>)") - THRESHOLD hits within WINDOW seconds.
#   2. Every PTC login page load timing out ("Page load timed out") - STALL_THRESHOLD
#      timeouts in a row with no browser getting past the login page in between.
# Lives in monitoring/, next to Lork's docker-compose.yml; restarts Lork via the compose file in
# the parent folder. Set COMPOSE_DIR if Lork's compose file is somewhere else.
set -u

SERVICE="${SERVICE:-lork}"
COMPOSE_DIR="${COMPOSE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
THRESHOLD="${THRESHOLD:-5}"               # this many refused connections...
WINDOW="${WINDOW:-120}"                   # ...within this many seconds triggers a restart
STALL_THRESHOLD="${STALL_THRESHOLD:-8}"  # this many page load timeouts with no progress triggers a restart
COOLDOWN="${COOLDOWN:-180}"               # ignore errors for this long after a restart

PATTERN="Connect call failed \\(.127\\.0\\.0\\.1., [0-9]+\\)"
TIMEOUT_PATTERN="BrowserAuth.*Page load timed out"
# BrowserAuth steps logged before the login page loads; any other BrowserAuth INFO line means progress
PRELOAD_PATTERN="Fetching reese cookie|Starting Chrome|Chrome started|Loading PTC login page"

log() { printf '%s [lork-watchdog] %s\n' "$(date '+%F %T')" "$*"; }

cd "$COMPOSE_DIR" || { log "Cannot cd to $COMPOSE_DIR"; exit 1; }
log "Watching '$SERVICE' in $COMPOSE_DIR (refused: $THRESHOLD in ${WINDOW}s, stall: $STALL_THRESHOLD timeouts, cooldown ${COOLDOWN}s)"

last_restart=$(( -COOLDOWN ))

restart() {
  log "$1, restarting $SERVICE"
  if docker compose restart "$SERVICE"; then
    log "Restarted $SERVICE"
  else
    log "Restart failed"
  fi
  last_restart=$SECONDS
  hits=()
  stalls=0
}

while true; do
  hits=()
  stalls=0
  # --since 0s: only new lines, so old errors don't trigger a restart on reattach
  # sed strips ANSI colour codes so the patterns match reliably
  while IFS= read -r line; do
    now=$SECONDS
    (( now - last_restart < COOLDOWN )) && continue

    if [[ $line =~ $TIMEOUT_PATTERN ]]; then
      (( stalls++ ))
      if (( stalls >= STALL_THRESHOLD )); then
        restart "$stalls page load timeouts in a row with no progress"
      fi
      continue
    fi

    if [[ $line == *BrowserAuth* && $line == *INFO* && ! $line =~ $PRELOAD_PATTERN ]]; then
      stalls=0
      continue
    fi

    [[ $line =~ $PATTERN ]] || continue
    hits+=("$now")
    recent=()
    for t in "${hits[@]}"; do
      (( now - t < WINDOW )) && recent+=("$t")
    done
    hits=("${recent[@]}")

    if (( ${#hits[@]} >= THRESHOLD )); then
      restart "${#hits[@]} refused DevTools connections in ${WINDOW}s (last: ${BASH_REMATCH[0]})"
    fi
  done < <(docker compose logs --no-log-prefix --since 0s -f "$SERVICE" 2>&1 | sed -u 's/\x1b\[[0-9;]*m//g')

  log "Log stream ended, reattaching in 5s"
  sleep 5
done
