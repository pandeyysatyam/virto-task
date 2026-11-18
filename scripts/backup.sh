#!/usr/bin/env bash
# Back up the database and the platform file volumes, then upload the
# backup to the S3 bucket on Floci (same layout the AWS bucket would use).
#
#   backups/<timestamp>-<tag>/
#     db.dump            pg_dump custom format
#     assets.tar.gz      platform-assets volume (uploaded images)
#     content.tar.gz     platform-content volume (CMS content)
#     SHA256SUMS
#
# Usage: ./scripts/backup.sh [--tag name]

source "$(dirname "$0")/lib.sh"
load_env

TAG="manual"
[[ "${1:-}" == "--tag" ]] && TAG="${2:?tag name}"

STAMP="$(date -u +%Y%m%d-%H%M%S)-${TAG}"
DIR="backups/$STAMP"
mkdir -p "$DIR"

is_healthy db || die "database container is not healthy"

log "Dumping database $POSTGRES_DB"
docker compose exec -T db pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc --no-owner > "$DIR/db.dump"
[[ -s "$DIR/db.dump" ]] || die "empty dump"

# Volumes are read through a throwaway alpine container, so this works
# without knowing where Docker keeps volumes on the host.
for vol in assets content; do
  log "Archiving volume platform-$vol"
  docker run --rm -v "virto_platform-$vol:/data:ro" alpine:3.22 \
    tar -C /data -czf - . > "$DIR/$vol.tar.gz"
done

( cd "$DIR" && shasum -a 256 db.dump assets.tar.gz content.tar.gz > SHA256SUMS )
ok "local backup: $DIR ($(du -sh "$DIR" | cut -f1))"

floci_env
if floci_up; then
  BUCKET=$(aws ssm get-parameter --name /virto/local/config/backup_bucket --query Parameter.Value --output text 2>/dev/null || true)
  if [[ -n "$BUCKET" && "$BUCKET" != "None" ]]; then
    aws s3 cp --recursive --only-show-errors "$DIR" "s3://$BUCKET/platform/backups/$STAMP/"
    ok "uploaded to s3://$BUCKET/platform/backups/$STAMP/ (Floci)"
  else
    warn "backup bucket not found in SSM, run ./scripts/setup.sh"
  fi
else
  warn "Floci not running, backup kept locally only"
fi
echo "$STAMP"
