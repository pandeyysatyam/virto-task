#!/usr/bin/env bash
# Stop and remove everything this project created locally.
#
# Usage:
#   ./scripts/teardown.sh             remove containers and networks, keep data volumes
#   ./scripts/teardown.sh --volumes   also delete database, cache and file volumes
#   ./scripts/teardown.sh --all       --volumes + destroy Floci resources + stop Floci
#                                     + remove the locally built images

source "$(dirname "$0")/lib.sh"

MODE="${1:-}"

if [[ "$MODE" == "--volumes" || "$MODE" == "--all" ]]; then
  read -r -p "This deletes the local database and uploaded files. Type 'yes' to continue: " answer
  [[ "$answer" == "yes" ]] || die "cancelled"
  docker compose down --volumes --remove-orphans
  ok "containers, networks and volumes removed"
else
  docker compose down --remove-orphans
  ok "containers and networks removed, volumes kept"
fi

if [[ "$MODE" == "--all" ]]; then
  floci_env
  if floci_up; then
    terraform -chdir=infra/terraform/envs/floci-local destroy -auto-approve -input=false >/dev/null \
      && ok "Floci resources destroyed"
  fi
  docker compose -f infra/floci/docker-compose.yml down --volumes
  ok "Floci stopped and its data volume removed"
  set +e
  load_env 2>/dev/null
  docker image rm "${PLATFORM_LOCAL_IMAGE:-}" "${FRONTEND_LOCAL_IMAGE:-}" 2>/dev/null
  set -e
  ok "local images removed"
fi
