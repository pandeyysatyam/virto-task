#!/usr/bin/env bash
# Shared helpers for the scripts in this folder. Source it, do not run it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_OFF=""
fi

log()  { printf '%s[%s]%s %s\n' "$C_DIM" "$(date +%H:%M:%S)" "$C_OFF" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

load_env() {
  [[ -f .env ]] || die ".env not found. Run ./scripts/setup.sh first."
  # image tags given on the command line win over .env (used by deploy/rollback)
  local keep_platform="${PLATFORM_LOCAL_IMAGE:-}" keep_frontend="${FRONTEND_LOCAL_IMAGE:-}"
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
  [[ -n "$keep_platform" ]] && PLATFORM_LOCAL_IMAGE="$keep_platform"
  [[ -n "$keep_frontend" ]] && FRONTEND_LOCAL_IMAGE="$keep_frontend"
  return 0
}

# Floci uses dummy credentials. They are exported only inside the scripts
# that talk to the emulator, never written to ~/.aws.
floci_env() {
  export AWS_ACCESS_KEY_ID=test
  export AWS_SECRET_ACCESS_KEY=test
  export AWS_REGION="${AWS_REGION:-us-east-1}"
  export AWS_DEFAULT_REGION="$AWS_REGION"
  export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}"
  export AWS_PAGER=""
}

floci_up() {
  curl -fsS -m 3 "${AWS_ENDPOINT_URL:-http://localhost:4566}/_floci/health" >/dev/null 2>&1
}

# wait_for <description> <timeout seconds> <command...>
wait_for() {
  local what="$1" timeout="$2"; shift 2
  local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    if (( SECONDS - start > timeout )); then
      return 1
    fi
    sleep 5
  done
  log "$what ready after $((SECONDS - start))s"
}

service_health() {
  local cid
  cid=$(docker compose ps -q "$1" 2>/dev/null)
  if [[ -z "$cid" ]]; then echo "stopped"; return; fi
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo "missing"
}

is_healthy() { [[ "$(service_health "$1")" == "healthy" ]]; }

# get_token <user> <password>  -> prints an access token or nothing
get_token() {
  curl -fsS -m 30 -X POST "${PLATFORM_PUBLIC_URL}/connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "grant_type=password" \
    --data-urlencode "username=$1" \
    --data-urlencode "password=$2" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null || true
}
