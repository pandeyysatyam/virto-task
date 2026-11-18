# Shortcuts. Every target is a thin wrapper around a script in ./scripts,
# so the scripts can also be run directly.

.PHONY: help setup deploy validate evidence persistence drill backup restore rollback \
        monitor logs ps stop start teardown floci-up floci-down infra-plan infra-apply \
        prod-validate prod-plan-floci lint

help:
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-16s %s\n",$$1,$$2}'

setup:          ## start Floci, apply local Terraform, write .env from Secrets Manager
	./scripts/setup.sh

deploy:         ## build images, start the stack, init platform (admin pw, sample data, index)
	./scripts/deploy.sh

validate:       ## run the smoke tests
	./scripts/validate.sh

evidence:       ## run the smoke tests and save the output in docs/evidence
	./scripts/validate.sh --save

persistence:    ## write data, recreate containers, check the data survived
	./scripts/test-persistence.sh

drill:          ## failure drills: database outage + platform crash
	./scripts/failure-drill.sh all

backup:         ## pg_dump + volume archives, uploaded to S3 on Floci
	./scripts/backup.sh

restore:        ## restore the latest backup
	./scripts/restore.sh

rollback:       ## go back to the previous release
	./scripts/rollback.sh

monitor:        ## push health metric and logs to CloudWatch on Floci
	./scripts/monitor.sh

logs:           ## follow platform and frontend logs
	docker compose logs -f --tail 100 platform frontend

ps:             ## container status
	docker compose ps

stop:           ## stop containers, keep everything
	docker compose stop

start:          ## start stopped containers
	docker compose start

teardown:       ## remove containers (data volumes kept)
	./scripts/teardown.sh

floci-up:       ## start the AWS emulator only
	docker compose -f infra/floci/docker-compose.yml up -d

floci-down:     ## stop the AWS emulator
	docker compose -f infra/floci/docker-compose.yml down

infra-plan:     ## terraform plan for the Floci environment
	terraform -chdir=infra/terraform/envs/floci-local init -input=false >/dev/null
	terraform -chdir=infra/terraform/envs/floci-local plan

infra-apply:    ## terraform apply for the Floci environment
	terraform -chdir=infra/terraform/envs/floci-local apply

prod-validate:  ## terraform validate for the real AWS environment (no credentials needed)
	terraform -chdir=infra/terraform/envs/aws-prod init -backend=false -input=false >/dev/null
	terraform -chdir=infra/terraform/envs/aws-prod validate

prod-plan-floci: ## plan the real AWS environment against Floci (catches plan-time errors)
	./scripts/plan-prod-on-floci.sh

lint:           ## shellcheck, terraform fmt, compose config
	shellcheck scripts/*.sh
	terraform fmt -recursive -check infra/terraform
	docker compose config -q
