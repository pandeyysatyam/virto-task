#!/usr/bin/env bash
# First time setup:
#   1. check tools and free ports
#   2. start Floci and create the local AWS resources with Terraform
#   3. build .env, taking every password from Secrets Manager on Floci
#
# Usage: ./scripts/setup.sh [--offline]
#   --offline  skip Floci and generate random passwords locally instead

source "$(dirname "$0")/lib.sh"

OFFLINE=false
[[ "${1:-}" == "--offline" ]] && OFFLINE=true

TF_DIR=infra/terraform/envs/floci-local

check_tools() {
  log "Checking tools"
  local missing=0
  for t in docker curl python3 openssl; do
    command -v "$t" >/dev/null || { warn "missing: $t"; missing=1; }
  done
  if ! $OFFLINE; then
    for t in aws terraform; do
      command -v "$t" >/dev/null || { warn "missing: $t"; missing=1; }
    done
  fi
  docker compose version >/dev/null 2>&1 || { warn "missing: docker compose v2"; missing=1; }
  docker info >/dev/null 2>&1 || { warn "docker daemon is not running"; missing=1; }
  (( missing == 0 )) || die "install the missing tools and run again"

  local mem_gb
  mem_gb=$(( $(docker info --format '{{.MemTotal}}') / 1024 / 1024 / 1024 ))
  (( mem_gb >= 6 )) || warn "Docker has ${mem_gb} GB memory, 6 GB or more is recommended"
  ok "docker $(docker version --format '{{.Server.Version}}'), compose $(docker compose version --short), ${mem_gb} GB for containers"
  $OFFLINE || ok "$(terraform version | head -1), $(aws --version 2>&1 | cut -d' ' -f1)"
}

check_ports() {
  local port_vars=(FRONTEND_PORT PLATFORM_PORT)
  local src=.env
  [[ -f .env ]] || src=.env.example
  for v in "${port_vars[@]}"; do
    local p
    p=$(grep "^$v=" "$src" | cut -d= -f2)
    # ignore ports that our own containers already hold
    if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 \
       && ! docker compose ps --format '{{.Ports}}' 2>/dev/null | grep -q ":$p->"; then
      die "port $p ($v) is already in use. Change $v in .env"
    fi
  done
  ok "ports free"
}

start_floci() {
  floci_env
  if floci_up; then
    ok "Floci already running on $AWS_ENDPOINT_URL"
  else
    log "Starting Floci"
    docker compose -f infra/floci/docker-compose.yml up -d
    wait_for "Floci" 60 floci_up || die "Floci did not start, see: docker compose -f infra/floci/docker-compose.yml logs"
  fi
  aws sts get-caller-identity --query Account --output text >/dev/null \
    || die "AWS CLI can not reach Floci"
  ok "AWS CLI talks to Floci (account $(aws sts get-caller-identity --query Account --output text))"
}

provision() {
  log "terraform init/apply in $TF_DIR"
  terraform -chdir="$TF_DIR" init -input=false >/dev/null
  terraform -chdir="$TF_DIR" apply -input=false -auto-approve >/dev/null
  ok "Floci resources ready: $(terraform -chdir="$TF_DIR" state list | wc -l | tr -d ' ') in state"
}

secret_field() {
  # secret_field <secret id> <json key>
  aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['$2'])"
}

write_env() {
  local db_pw cache_pw
  if $OFFLINE; then
    db_pw=$(openssl rand -hex 16)
    cache_pw=$(openssl rand -hex 20)
  else
    db_pw=$(secret_field virto/local/db password)
    cache_pw=$(secret_field virto/local/cache password)
  fi

  if [[ -f .env ]]; then
    cp .env ".env.bak.$(date +%Y%m%d%H%M%S)"
    warn "existing .env saved as .env.bak.*. If the database volume already exists"
    warn "with the old password, run ./scripts/teardown.sh --volumes first."
  fi

  sed -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${db_pw}|" \
      -e "s|^CACHE_PASSWORD=.*|CACHE_PASSWORD=${cache_pw}|" \
      .env.example > .env
  chmod 600 .env
  ok ".env written (mode 600). Passwords come from $($OFFLINE && echo 'openssl rand' || echo 'Secrets Manager on Floci')"
}

check_tools
check_ports
if ! $OFFLINE; then
  start_floci
  provision
fi
write_env
log "Next: ./scripts/deploy.sh"
