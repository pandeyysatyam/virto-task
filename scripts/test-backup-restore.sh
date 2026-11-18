#!/usr/bin/env bash
# Backup / restore test:
#   1. take a backup (uploaded to S3 on Floci)
#   2. create a contact AFTER the backup
#   3. delete the local copy, so the restore must download from S3
#   4. restore
#   5. the contact from step 2 must be gone, the catalog must be intact
#
# Usage: ./scripts/test-backup-restore.sh

source "$(dirname "$0")/lib.sh"
load_env

API="$PLATFORM_PUBLIC_URL"

# GET by id reads the database directly (search would read the index)
contact_exists() {
  local token code
  token=$(get_token "$VC_ADMIN_USER" "$VC_ADMIN_PASSWORD")
  code=$(curl -s -o /tmp/virto-contact.json -w '%{http_code}' -m 30 "$API/api/contacts/$1" -H "Authorization: Bearer $token")
  [[ "$code" == 200 ]] && [[ -s /tmp/virto-contact.json ]] && grep -q "\"id\"" /tmp/virto-contact.json
}

log "1. Backup"
NAME=$(./scripts/backup.sh --tag restore-test | tail -n 1)
ok "backup $NAME"

log "2. Creating a contact after the backup"
MARK="after-backup-$(date +%s)"
TOKEN=$(get_token "$VC_ADMIN_USER" "$VC_ADMIN_PASSWORD")
ID=$(curl -fsS -m 30 -X POST "$API/api/contacts" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"firstName\":\"Restore\",\"lastName\":\"$MARK\",\"fullName\":\"Restore $MARK\",\"memberType\":\"Contact\"}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
contact_exists "$ID" || die "new contact $ID not readable, test can not continue"
ok "contact $ID exists before restore"

log "3. Removing local copy backups/$NAME (restore has to use S3)"
rm -rf "backups/$NAME"

log "4. Restore"
./scripts/restore.sh "$NAME"

log "5. Checks"
contact_exists "$ID" && die "contact $ID created after the backup is still there"
ok "contact $ID created after the backup is gone (database is back at the backup point)"
PRODUCTS=$(curl -fsS -m 60 -X POST "http://localhost:${FRONTEND_PORT}/graphql" -H 'Content-Type: application/json' \
  -d '{"query":"{ products(storeId: \"B2B-store\", first: 1, cultureName: \"en-US\") { totalCount } }"}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["products"]["totalCount"])')
(( PRODUCTS > 0 )) || die "catalog missing after restore"
ok "storefront lists $PRODUCTS products after restore"
ok "BACKUP / RESTORE TEST PASSED"
