#!/usr/bin/env bash
# Smoke tests for the local deployment. Exit code is the number of failed checks.
#
# Usage: ./scripts/validate.sh [--save]
#   --save  also write the output to docs/evidence/validate-<timestamp>.txt

source "$(dirname "$0")/lib.sh"
load_env

if [[ "${1:-}" == "--save" ]]; then
  mkdir -p docs/evidence
  OUT="docs/evidence/validate-$(date +%Y%m%d-%H%M%S).txt"
  exec > >(tee "$OUT") 2>&1
fi

FE="http://localhost:${FRONTEND_PORT}"
PASS=0
FAIL=0
check() {
  # check <name> <command...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '%s[PASS]%s %s\n' "$C_OK" "$C_OFF" "$name"; PASS=$((PASS + 1))
  else
    printf '%s[FAIL]%s %s\n' "$C_ERR" "$C_OFF" "$name"; FAIL=$((FAIL + 1))
  fi
}

gql() {
  curl -fsS -m 60 -X POST "$FE/graphql" -H 'Content-Type: application/json' -d "{\"query\":\"$1\"}"
}

echo "Validation run $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "------------------------------------------------------------"
docker compose ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
echo "------------------------------------------------------------"

echo "# containers"
for svc in db cache platform frontend; do
  check "$svc container is healthy" is_healthy "$svc"
done

echo "# platform"
check "platform /health reports every check Healthy" bash -c \
  "curl -fsS -m 30 '$PLATFORM_PUBLIC_URL/health' | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(any(v[\"Status\"]!=\"Healthy\" for v in d.values()))'"
check "admin can log in with the password from .env" bash -c \
  "[[ -n \"\$(source scripts/lib.sh; get_token '$VC_ADMIN_USER' '$VC_ADMIN_PASSWORD')\" ]]"
check "default password admin/store is rejected" bash -c \
  "[[ -z \"\$(source scripts/lib.sh; get_token admin store)\" ]]"
check "admin UI page is served" bash -c "curl -fsS -m 30 '$PLATFORM_PUBLIC_URL/' | grep -qi '<html'"

echo "# frontend"
check "storefront index.html is served (200)" bash -c "curl -fsS -m 10 '$FE/' | grep -q 'id=\"app\"'"
check "unknown SPA route falls back to index.html" bash -c "curl -fsS -m 10 '$FE/catalog/some/page' | grep -q 'id=\"app\"'"
check "security headers present" bash -c \
  "curl -fsSI -m 10 '$FE/' | grep -qi 'x-content-type-options: nosniff'"

echo "# frontend to platform (through nginx)"
check "GraphQL via frontend returns the B2B store" bash -c \
  "curl -fsS -m 60 -X POST '$FE/graphql' -H 'Content-Type: application/json' \
   -d '{\"query\":\"{ store(domain: \\\"localhost\\\") { storeId } }\"}' | grep -q 'B2B-store'"
check "product search via frontend returns products" bash -c \
  "curl -fsS -m 60 -X POST '$FE/graphql' -H 'Content-Type: application/json' \
   -d '{\"query\":\"{ products(storeId: \\\"B2B-store\\\", first: 1, cultureName: \\\"en-US\\\") { totalCount } }\"}' \
   | python3 -c 'import json,sys; sys.exit(json.load(sys.stdin)[\"data\"][\"products\"][\"totalCount\"] < 1)'"
check "token endpoint is reachable via frontend" bash -c \
  "code=\$(curl -s -o /dev/null -w '%{http_code}' -m 30 -X POST '$FE/connect/token' -d 'grant_type=password&username=x&password=y'); [[ \$code == 400 ]]"

echo "# network boundaries"
check "database port is not published on the host" bash -c \
  "! docker compose ps --format '{{.Ports}}' db | grep -q -- '->'"
check "cache port is not published on the host" bash -c \
  "! docker compose ps --format '{{.Ports}}' cache | grep -q -- '->'"
check "backend network is internal (no internet)" bash -c \
  "[[ \$(docker network inspect virto_backend --format '{{.Internal}}') == true ]]"
check "frontend container can not reach the database" bash -c \
  "! docker compose exec -T frontend sh -c 'nc -z -w 3 db 5432'"
check "platform and frontend ports bound to 127.0.0.1 only" bash -c \
  "docker compose ps --format '{{.Ports}}' | grep -E '(8080|8090|8088)' | grep -vq '0.0.0.0'"

echo "# containers run as non-root"
check "platform runs as uid 1654" bash -c "[[ \$(docker compose exec -T platform id -u) == 1654 ]]"
check "frontend runs as uid 101 with read-only root fs" bash -c \
  "[[ \$(docker compose exec -T frontend id -u) == 101 ]] && ! docker compose exec -T frontend touch /usr/share/nginx/html/x"

floci_env
if floci_up; then
  echo "# emulated AWS (Floci)"
  check "Secrets Manager has the db secret" aws secretsmanager describe-secret --secret-id virto/local/db
  check "S3 backup bucket exists with versioning" bash -c \
    "aws s3api get-bucket-versioning --bucket virto-local-backups-000000000000 | grep -q Enabled"
  check "CloudWatch log groups exist" bash -c "aws logs describe-log-groups --log-group-name-prefix /virto-local | grep -q platform"
else
  warn "Floci not running, AWS checks skipped"
fi

echo "------------------------------------------------------------"
echo "passed: $PASS  failed: $FAIL"
exit "$FAIL"
