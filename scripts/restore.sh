#!/usr/bin/env bash
# Restore a backup made by backup.sh.
#
# Usage:
#   ./scripts/restore.sh                 latest backup from S3 on Floci (or local if Floci is down)
#   ./scripts/restore.sh <backup name>   a specific one, e.g. 20261118-171500-manual
#   ./scripts/restore.sh --list          list available backups
#
# Steps: download, verify checksums, stop platform, recreate database,
# pg_restore, refill volumes, start platform, wait for health.

source "$(dirname "$0")/lib.sh"
load_env
floci_env

BUCKET=""
if floci_up; then
  BUCKET=$(aws ssm get-parameter --name /virto/local/config/backup_bucket --query Parameter.Value --output text 2>/dev/null || true)
fi

list_backups() {
  if [[ -n "$BUCKET" ]]; then
    aws s3 ls "s3://$BUCKET/platform/backups/" | awk '{print $2}' | tr -d '/'
  else
    ls backups 2>/dev/null
  fi
}

if [[ "${1:-}" == "--list" ]]; then
  list_backups
  exit 0
fi

NAME="${1:-$(list_backups | sort | tail -n 1)}"
[[ -n "$NAME" ]] || die "no backups found"
DIR="backups/$NAME"

if [[ ! -f "$DIR/db.dump" ]]; then
  [[ -n "$BUCKET" ]] || die "backup $NAME not found locally and Floci is not running"
  log "Downloading $NAME from s3://$BUCKET"
  mkdir -p "$DIR"
  aws s3 cp --recursive --only-show-errors "s3://$BUCKET/platform/backups/$NAME/" "$DIR/"
fi

( cd "$DIR" && shasum -a 256 -c SHA256SUMS ) || die "checksum mismatch, backup is damaged"
ok "checksums verified for $NAME"

log "Stopping platform and frontend"
docker compose stop frontend platform

log "Recreating database $POSTGRES_DB"
docker compose exec -T db psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$POSTGRES_DB' AND pid <> pg_backend_pid();" >/dev/null
docker compose exec -T db dropdb -U "$POSTGRES_USER" --if-exists "$POSTGRES_DB"
docker compose exec -T db createdb -U "$POSTGRES_USER" "$POSTGRES_DB"
docker compose exec -T db pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --exit-on-error < "$DIR/db.dump"
ok "database restored"

for vol in assets content; do
  log "Restoring volume platform-$vol"
  docker run --rm -i -v "virto_platform-$vol:/data" alpine:3.22 \
    sh -c 'find /data -mindepth 1 -delete && tar -C /data -xzf -' < "$DIR/$vol.tar.gz"
done

# Lucene index is derived data: drop it, the platform rebuilds what it needs
docker run --rm -v virto_platform-search:/data alpine:3.22 sh -c 'find /data -mindepth 1 -delete'

log "Starting platform and frontend"
docker compose start platform frontend
wait_for "platform" 900 is_healthy platform || die "platform not healthy after restore"
./scripts/setup-platform.sh --skip-sample-data
ok "restore of $NAME complete"
