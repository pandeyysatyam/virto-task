#!/usr/bin/env bash
# Persistence test: write data through the application, recreate the
# containers, read it back.
#
#   1. create a customer contact through the platform REST API (-> PostgreSQL)
#   2. upload a file through the assets API (-> platform-assets volume)
#   3. docker compose down (containers removed, volumes kept) and up again
#   4. check both are still there
#
# Usage: ./scripts/test-persistence.sh

source "$(dirname "$0")/lib.sh"
load_env

API="$PLATFORM_PUBLIC_URL"
MARK="persist-$(date +%s)"
TOKEN=$(get_token "$VC_ADMIN_USER" "$VC_ADMIN_PASSWORD")
[[ -n "$TOKEN" ]] || die "login failed"

log "1. Creating contact '$MARK'"
CONTACT_ID=$(curl -fsS -m 30 -X POST "$API/api/contacts" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"firstName\":\"Persistence\",\"lastName\":\"$MARK\",\"fullName\":\"Persistence $MARK\",\"memberType\":\"Contact\"}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
ok "contact id $CONTACT_ID"

log "2. Uploading asset $MARK.txt"
echo "persistence check $MARK" > "/tmp/$MARK.txt"
ASSET_URL=$(curl -fsS -m 60 -X POST "$API/api/assets?folderUrl=persistence" \
  -H "Authorization: Bearer $TOKEN" -F "file=@/tmp/$MARK.txt" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["url"])')
rm -f "/tmp/$MARK.txt"
ok "asset at $ASSET_URL"

log "3. Recreating all containers (docker compose down && up, volumes kept)"
docker compose down
docker compose up -d --no-build
wait_for "platform" 900 is_healthy platform || die "platform did not come back"
wait_for "frontend" 120 is_healthy frontend || die "frontend did not come back"

log "4. Reading back"
TOKEN=$(get_token "$VC_ADMIN_USER" "$VC_ADMIN_PASSWORD")
NAME=$(curl -fsS -m 30 "$API/api/contacts/$CONTACT_ID" -H "Authorization: Bearer $TOKEN" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["lastName"])')
[[ "$NAME" == "$MARK" ]] || die "contact lost after restart"
ok "contact $CONTACT_ID still in the database"

BODY=$(curl -fsS -m 30 "$ASSET_URL")
[[ "$BODY" == "persistence check $MARK" ]] || die "asset file lost after restart"
ok "asset file still on the volume"

PRODUCTS=$(curl -fsS -m 60 -X POST "http://localhost:${FRONTEND_PORT}/graphql" -H 'Content-Type: application/json' \
  -d '{"query":"{ products(storeId: \"B2B-store\", first: 1, cultureName: \"en-US\") { totalCount } }"}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["products"]["totalCount"])')
(( PRODUCTS > 0 )) || die "search index lost after restart"
ok "search index still has $PRODUCTS products"

ok "PERSISTENCE TEST PASSED"
