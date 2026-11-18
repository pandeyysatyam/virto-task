#!/usr/bin/env bash
# Safe failure drills. Each one breaks something on purpose, shows what the
# user and the health checks see, then shows the recovery.
#
# Usage: ./scripts/failure-drill.sh [db|platform-crash|all]
#
#   db              stop PostgreSQL for about 15 s. Expect platform /health 503 and
#                   logins failing; after start, recovery without restarting the platform.
#   platform-crash  SIGKILL the platform process from the host PID namespace (what a
#                   crash or OOM kill looks like). Expect the restart policy
#                   (unless-stopped) to start it again and the health check to go green.
#
# Notes from building this:
#   - "kill -9 1" inside the container does nothing: PID 1 of a PID namespace
#     ignores signals sent from inside that namespace.
#   - "docker kill" counts as a manual stop, so Docker does NOT apply the restart
#     policy. A real crash has to come from outside Docker's API.

source "$(dirname "$0")/lib.sh"
load_env

FE="http://localhost:${FRONTEND_PORT}"

http() { curl -s -o /dev/null -w '%{http_code}' -m 20 "$@"; }

# product search is served from the search index (Lucene) and cache
search_api() {
  curl -s -m 20 -X POST "$FE/graphql" -H 'Content-Type: application/json' \
    -d '{"query":"{ products(storeId: \"B2B-store\", first: 1, cultureName: \"en-US\") { totalCount } }"}' \
    | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin); print("ok, %s products" % d["data"]["products"]["totalCount"] if d.get("data") and d["data"].get("products") else "error: %s" % d.get("errors",[{}])[0].get("message","?")[:60])
except Exception: print("no response")'
}

# login needs the database (users table)
login_api() {
  if [[ -n "$(get_token "$VC_ADMIN_USER" "$VC_ADMIN_PASSWORD")" ]]; then echo "ok"; else echo "failed"; fi
}

pg_health() {
  curl -s -m 20 "$PLATFORM_PUBLIC_URL/health" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("PostgreSql health",{}).get("Status","?"))' 2>/dev/null || echo "no-response"
}

state() {
  echo "/health HTTP $(http "$PLATFORM_PUBLIC_URL/health") (PostgreSql $(pg_health)), login: $(login_api), product search: $(search_api), shop page HTTP $(http "$FE/")"
}

platform_ok() { [[ "$(http "$PLATFORM_PUBLIC_URL/health")" == 200 ]]; }

drill_db() {
  log "=== Drill 1: database outage ==="
  log "before: $(state)"
  log "stopping db"
  docker compose stop db >/dev/null
  sleep 15
  log "during: $(state)"
  log "starting db"
  local t0=$SECONDS
  docker compose start db >/dev/null
  wait_for "db" 120 is_healthy db || die "db did not recover"
  wait_for "platform /health" 300 platform_ok || die "platform did not recover"
  log "after:  $(state)"
  ok "recovered $((SECONDS - t0))s after the database came back, platform was not restarted (Npgsql pool reconnects)"
}

drill_crash() {
  log "=== Drill 2: platform process crash ==="
  local cid before pid
  cid=$(docker compose ps -q platform)
  before=$(docker inspect --format '{{.RestartCount}}' "$cid")
  pid=$(docker inspect --format '{{.State.Pid}}' "$cid")
  log "before: restart count $before, $(state)"
  log "SIGKILL to the platform process (pid $pid in the Docker host namespace)"
  docker run --rm --pid=host alpine:3.22 kill -9 "$pid"
  sleep 3
  log "during: container $(docker inspect --format '{{.State.Status}}' "$cid"), shop page HTTP $(http "$FE/"), product search: $(search_api)"
  local t0=$SECONDS
  wait_for "platform healthy" 900 is_healthy platform || die "platform did not recover"
  log "after:  restart count $(docker inspect --format '{{.RestartCount}}' "$cid") (restart: unless-stopped), $(state)"
  ok "platform back $((SECONDS - t0))s after the crash, nginx reconnected on its own"
}

case "${1:-all}" in
  db) drill_db ;;
  platform-crash) drill_crash ;;
  all) drill_db; echo; drill_crash ;;
  *) die "unknown drill $1" ;;
esac
