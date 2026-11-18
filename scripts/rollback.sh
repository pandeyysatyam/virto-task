#!/usr/bin/env bash
# Roll back to the previous release recorded by deploy.sh.
#
# Image tags are versioned (never "latest"), so going back is just starting
# the containers with the previous tags. No rebuild.
#
# Usage:
#   ./scripts/rollback.sh               previous release
#   ./scripts/rollback.sh --list        show release history
#   ./scripts/rollback.sh --restore-db  also restore the pre-deploy database backup
#                                       (needed if the newer version migrated the schema)

source "$(dirname "$0")/lib.sh"
load_env

[[ -f .releases ]] || die "no release history (.releases). Deploy at least twice first."

if [[ "${1:-}" == "--list" ]]; then
  nl -w2 -s'. ' .releases
  exit 0
fi

RESTORE_DB=false
[[ "${1:-}" == "--restore-db" ]] && RESTORE_DB=true

(( $(wc -l < .releases) >= 2 )) || die "only one release recorded, nothing to roll back to"

CURRENT=$(tail -n 1 .releases)
PREVIOUS=$(tail -n 2 .releases | head -n 1)
read -r _ PREV_PLATFORM PREV_FRONTEND _ _ <<<"$PREVIOUS"

log "current:  $(cut -d' ' -f2-3 <<<"$CURRENT")"
log "rollback: $PREV_PLATFORM $PREV_FRONTEND"

for img in "$PREV_PLATFORM" "$PREV_FRONTEND"; do
  docker image inspect "$img" >/dev/null 2>&1 || die "image $img no longer exists locally"
done

if $RESTORE_DB; then
  LAST_PRE=""
  for d in backups/*-pre-deploy; do [[ -d "$d" ]] && LAST_PRE=$(basename "$d"); done
  [[ -n "$LAST_PRE" ]] || die "no pre-deploy backup found"
  log "Will restore database from $LAST_PRE"
fi

export PLATFORM_LOCAL_IMAGE="$PREV_PLATFORM" FRONTEND_LOCAL_IMAGE="$PREV_FRONTEND"
docker compose up -d --no-build platform frontend
wait_for "platform" 900 is_healthy platform || die "previous release is not healthy either, see docker compose logs platform"
wait_for "frontend" 120 is_healthy frontend || die "frontend not healthy"

if $RESTORE_DB; then
  ./scripts/restore.sh "$LAST_PRE"
fi

# keep .env in line with what is running
sed -i.bak -e "s|^PLATFORM_LOCAL_IMAGE=.*|PLATFORM_LOCAL_IMAGE=$PREV_PLATFORM|" \
           -e "s|^FRONTEND_LOCAL_IMAGE=.*|FRONTEND_LOCAL_IMAGE=$PREV_FRONTEND|" .env && rm -f .env.bak
# move the bad release to the end of the file marked as rolled back
{ sed '$d' .releases; echo "$PREVIOUS"; } > .releases.tmp && mv .releases.tmp .releases
echo "# rolled back from: $(cut -d' ' -f2-3 <<<"$CURRENT") at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> .rollback.log

ok "rolled back. Run ./scripts/validate.sh"
