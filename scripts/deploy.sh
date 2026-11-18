#!/usr/bin/env bash
# Build (if needed) and start the local stack, then initialise the platform.
#
# Every successful deploy is recorded as a "release" in SSM Parameter Store
# on Floci (/virto/local/releases/<n>) and in .releases locally. rollback.sh
# uses that history to go back to the previous images.
#
# Usage: ./scripts/deploy.sh [--no-build] [--skip-sample-data]

source "$(dirname "$0")/lib.sh"
load_env

BUILD=true
SETUP_ARGS=()
for a in "$@"; do
  case "$a" in
    --no-build) BUILD=false ;;
    --skip-sample-data) SETUP_ARGS+=(--skip-sample-data) ;;
    *) die "unknown option $a" ;;
  esac
done

# Image tags can be overridden from the shell (rollback.sh does this)
export PLATFORM_LOCAL_IMAGE FRONTEND_LOCAL_IMAGE
log "platform image: $PLATFORM_LOCAL_IMAGE"
log "frontend image: $FRONTEND_LOCAL_IMAGE"

# Safety net: if the stack is already running, back up first. Virto applies
# database migrations on start, so a rollback may need this dump.
if [[ -n "$(docker compose ps -q db 2>/dev/null)" ]] && is_healthy db; then
  log "Stack is running, taking a pre-deploy backup"
  ./scripts/backup.sh --tag pre-deploy || warn "pre-deploy backup failed, continuing"
fi

if $BUILD; then
  log "Building images (first build downloads about 300 MB of modules)"
  docker compose build
fi

for img in "$PLATFORM_LOCAL_IMAGE" "$FRONTEND_LOCAL_IMAGE"; do
  docker image inspect "$img" >/dev/null 2>&1 || die "image $img not found. Run without --no-build"
done

log "Starting containers"
docker compose up -d --no-build --remove-orphans

for svc in db cache; do
  wait_for "$svc" 120 is_healthy "$svc" || die "$svc not healthy. Check: docker compose logs $svc"
done
log "Waiting for the platform (first start runs database migrations, 1 to 5 minutes)"
wait_for "platform" 900 is_healthy platform || die "platform not healthy. Check: docker compose logs platform"
wait_for "frontend" 120 is_healthy frontend || die "frontend not healthy. Check: docker compose logs frontend"
ok "all containers healthy"

./scripts/setup-platform.sh "${SETUP_ARGS[@]+"${SETUP_ARGS[@]}"}"

# Record the release
PLATFORM_ID=$(docker image inspect --format '{{.Id}}' "$PLATFORM_LOCAL_IMAGE" | cut -c8-19)
FRONTEND_ID=$(docker image inspect --format '{{.Id}}' "$FRONTEND_LOCAL_IMAGE" | cut -c8-19)
RELEASE="$(date -u +%Y-%m-%dT%H:%M:%SZ) $PLATFORM_LOCAL_IMAGE $FRONTEND_LOCAL_IMAGE $PLATFORM_ID $FRONTEND_ID"
LAST=$(tail -n 1 .releases 2>/dev/null | cut -d' ' -f2-3 || true)
if [[ "$LAST" != "$PLATFORM_LOCAL_IMAGE $FRONTEND_LOCAL_IMAGE" ]]; then
  echo "$RELEASE" >> .releases
  floci_env
  if floci_up; then
    N=$(wc -l < .releases | tr -d ' ')
    aws ssm put-parameter --name "/virto/local/releases/$(printf '%04d' "$N")" \
      --type String --value "$RELEASE" --overwrite >/dev/null \
      && ok "release $N recorded in SSM Parameter Store (Floci)"
  fi
fi

echo
ok "Storefront:   http://localhost:${FRONTEND_PORT}"
ok "Admin (back office): ${PLATFORM_PUBLIC_URL}  user: ${VC_ADMIN_USER}  password: see VC_ADMIN_PASSWORD in .env"
log "Run ./scripts/validate.sh to check everything"
