#!/usr/bin/env bash
# Run the PRODUCTION Terraform (envs/aws-prod) against Floci to catch errors
# that "terraform validate" can not see: dependency cycles, values unknown at
# plan time, wrong argument combinations, provider level API validation.
#
# The aws-prod folder is copied to a temp dir and a Terraform override file
# (infra/terraform/floci-overrides/floci_override.tf) switches backend and
# provider to Floci. Nothing is changed in envs/aws-prod and nothing reaches AWS.
#
# Usage: ./scripts/plan-prod-on-floci.sh [--apply]

source "$(dirname "$0")/lib.sh"
floci_env
floci_up || die "Floci is not running. Start it with ./scripts/setup.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/virto-prodsim.XXXXXX")
trap 'log "work dir kept for inspection: $WORK"' EXIT

cp infra/terraform/envs/aws-prod/*.tf "$WORK/"
cp infra/terraform/floci-overrides/floci_override.tf "$WORK/"
sed -i.bak "s#source *= \"../../modules/#source = \"$REPO_ROOT/infra/terraform/modules/#" "$WORK/main.tf" && rm -f "$WORK/main.tf.bak"

ZONE=$(aws route53 list-hosted-zones-by-name --dns-name virto.test --query 'HostedZones[0].Id' --output text 2>/dev/null | sed 's#/hostedzone/##')
if [[ -z "$ZONE" || "$ZONE" == "None" ]]; then
  ZONE=$(aws route53 create-hosted-zone --name virto.test --caller-reference "prodsim-$(date +%s)" \
    --query 'HostedZone.Id' --output text | sed 's#/hostedzone/##')
fi
sed "s/REPLACED_BY_SCRIPT/$ZONE/" infra/terraform/floci-overrides/floci.tfvars > "$WORK/terraform.tfvars"

cd "$WORK" || die "can not enter $WORK"
terraform init -input=false >/dev/null
terraform plan -input=false -out=tf.plan -no-color > plan.log || { tail -n 30 plan.log; die "plan failed"; }
grep -E "^Plan:|No changes" plan.log
if [[ "${1:-}" == "--apply" ]]; then
  terraform apply -input=false -auto-approve tf.plan
fi
