#!/usr/bin/env bash
# One time platform initialisation, safe to run again:
#   - imports the B2B sample store (catalog, prices, customers)
#   - builds the search index so the storefront can list products
#   - replaces the default admin password (admin / store) with VC_ADMIN_PASSWORD
#
# Usage: ./scripts/setup-platform.sh [--skip-sample-data]

source "$(dirname "$0")/lib.sh"
load_env

SKIP_SAMPLE=false
[[ "${1:-}" == "--skip-sample-data" ]] && SKIP_SAMPLE=true

API="$PLATFORM_PUBLIC_URL"
DEFAULT_PASSWORD="store"

api() {
  # api <method> <path> [json body]
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -fsS -m 60 -X "$method" "$API$path" -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' -d "$body"
  else
    curl -fsS -m 60 -X "$method" "$API$path" -H "Authorization: Bearer $TOKEN"
  fi
}

# wait_job <notification id> <timeout s>
wait_job() {
  local id="$1" timeout="$2" start=$SECONDS state
  while (( SECONDS - start < timeout )); do
    state=$(api POST /api/platform/pushnotifications "{\"Ids\":[\"$id\"],\"start\":0,\"count\":1}" \
      | python3 -c '
import json,sys
e=json.load(sys.stdin)["notifyEvents"][0]
print("done" if e.get("finished") else "run", e.get("errorCount",0), (e.get("description") or "").replace(" ","_"))')
    read -r status errors desc <<<"$state"
    log "  ${desc//_/ }"
    if [[ "$status" == "done" ]]; then
      (( errors == 0 )) || die "job finished with $errors errors"
      return 0
    fi
    sleep 10
  done
  die "job $id did not finish in ${timeout}s"
}

is_healthy platform || wait_for "platform" 900 is_healthy platform || die "platform is not healthy"

# Log in with the configured password, or the factory default on a fresh install
TOKEN=$(get_token "$VC_ADMIN_USER" "$VC_ADMIN_PASSWORD")
[[ -n "$TOKEN" ]] || TOKEN=$(get_token "$VC_ADMIN_USER" "$DEFAULT_PASSWORD")
[[ -n "$TOKEN" ]] || die "can not log in with VC_ADMIN_PASSWORD or the default password"

# 1. sample data
if $SKIP_SAMPLE; then
  warn "sample data skipped"
else
  STORES=$(curl -fsS -m 30 -X POST "http://localhost:${FRONTEND_PORT}/graphql" -H 'Content-Type: application/json' \
    -d '{"query":"{ store(domain: \"localhost\") { storeId } }"}' \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(((d.get("data") or {}).get("store") or {}).get("storeId",""))' || true)
  if [[ -n "$STORES" ]]; then
    ok "sample store already present ($STORES)"
  else
    log "Importing sample data (about 60 MB download)"
    JOB=$(api POST /api/platform/sampledata/autoinstall | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
    wait_job "$JOB" 1800
    ok "sample data imported"
  fi
fi

# 2. search index
COUNT=$(api GET /api/search/indexes | python3 -c '
import json,sys
print(sum(x.get("indexedDocumentsCount") or 0 for x in json.load(sys.stdin) if x.get("documentType")=="Product"))')
if (( COUNT > 0 )); then
  ok "search index has $COUNT products"
else
  log "Building search index"
  JOB=$(api POST /api/search/indexes/index \
    '[{"documentType":"Product","deleteExistingIndex":true},{"documentType":"Category","deleteExistingIndex":true},{"documentType":"Member","deleteExistingIndex":true}]' \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  wait_job "$JOB" 1200
  ok "search index built"
fi

# 3. admin password. Done LAST on purpose: the sample data import contains
#    platform users and puts the admin password back to "store".
if [[ -z "$(get_token "$VC_ADMIN_USER" "$DEFAULT_PASSWORD")" ]]; then
  ok "default admin password is not accepted"
else
  BODY=$(python3 -c 'import json,os; print(json.dumps({"oldPassword":"store","newPassword":os.environ["VC_ADMIN_PASSWORD"]}))')
  RESULT=$(api POST "/api/platform/security/users/${VC_ADMIN_USER}/changepassword" "$BODY")
  # the API answers HTTP 200 even when the change is refused, so read the body
  python3 -c 'import json,sys; r=json.loads(sys.argv[1]); sys.exit(0 if r.get("succeeded") else 1)' "$RESULT" \
    || die "password change refused: $RESULT"
  [[ -z "$(get_token "$VC_ADMIN_USER" "$DEFAULT_PASSWORD")" ]] || die "default password still works after the change"
  [[ -n "$(get_token "$VC_ADMIN_USER" "$VC_ADMIN_PASSWORD")" ]] || die "login with the new password failed"
  ok "default admin password replaced and verified"
fi
