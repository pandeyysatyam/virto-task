# Floci: local AWS emulator

Task 3. Floci (https://floci.io, MIT license) emulates AWS APIs on
`http://localhost:4566`. No AWS account, no cost.

> A working Floci run does **not** mean the app runs on AWS. Here Floci holds the
> AWS side of the local setup (secrets, parameters, backups, logs, alarms,
> network design) while the application runs in Docker Compose. Real AWS was
> not used.

## Start and check

```bash
docker compose -f infra/floci/docker-compose.yml up -d     # or: make floci-up
curl -s http://localhost:4566/_floci/health

export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
export AWS_REGION=us-east-1 AWS_ENDPOINT_URL=http://localhost:4566
aws sts get-caller-identity
```

Configuration choices in `infra/floci/docker-compose.yml`:

| Setting | Value | Why |
|---|---|---|
| image | `floci/floci:2.5.0` | pinned |
| port | `127.0.0.1:4566` | not reachable from the network |
| `FLOCI_STORAGE_MODE` | `hybrid` | in memory, flushed to the volume every few seconds, so secrets and backups survive a Floci restart |
| Docker socket | **not mounted** | the socket gives full control of the host Docker. Only needed for Docker backed services, which this project does not use locally |
| UI | off | not needed |

`AWS_ENDPOINT_URL` (supported by AWS CLI v2 and the SDKs) sends every command
to Floci, so the commands in the scripts are the same ones that would run
against AWS. The scripts set it with `floci_env` in `scripts/lib.sh`, they do
not write anything to `~/.aws`.

## Provision with Terraform

```bash
cd infra/terraform/envs/floci-local
terraform init
terraform apply          # about 80 resources, about 1 minute
terraform output
```

Or `./scripts/setup.sh`, which also writes `.env`.

What gets created (same modules as production):

| Module | Resources on Floci |
|---|---|
| network | VPC 10.30.0.0/16, 6 subnets (public/app/data x 2 AZ), IGW, route tables, 7 security groups with chained rules |
| storage | KMS key + alias, S3 backup bucket (versioning, SSE-KMS, public access block, lifecycle) |
| secrets | 4 Secrets Manager secrets (db, cache, search, admin) with generated values; 5 SSM parameters |
| registry | 2 ECR repos (immutable, scan on push, lifecycle) |
| iam | ECS execution role, platform and frontend task roles with policies |
| observability | 2 log groups, SNS topic, alarm on `UnhealthyServices` |

Proof (`docs/evidence/floci-resources.txt`) is produced with:

```bash
aws ec2 describe-subnets --query 'Subnets[].[Tags[?Key==`Name`]|[0].Value,CidrBlock]' --output text
aws secretsmanager list-secrets --query 'SecretList[].Name'
aws s3api get-bucket-versioning --bucket virto-local-backups-000000000000
aws cloudwatch describe-alarms --query 'MetricAlarms[].[AlarmName,StateValue]'
```

## How the local stack uses it

| Script | AWS calls (to Floci) |
|---|---|
| `setup.sh` | `sts get-caller-identity`, Terraform apply, `secretsmanager get-secret-value` |
| `deploy.sh` | `ssm put-parameter /virto/local/releases/NNNN` (release history) |
| `backup.sh` | `ssm get-parameter` (bucket name), `s3 cp --recursive` |
| `restore.sh` | `s3 ls`, `s3 cp` |
| `monitor.sh` | `cloudwatch put-metric-data`, `logs put-log-events`, `cloudwatch describe-alarms` |
| `validate.sh` | `secretsmanager describe-secret`, `s3api get-bucket-versioning`, `logs describe-log-groups` |

## Planning production against Floci

`scripts/plan-prod-on-floci.sh` copies `envs/aws-prod` to a temp folder, adds
the override file `infra/terraform/floci-overrides/floci_override.tf`
(Terraform merges `*_override.tf` files over the main config) and runs
`plan`. `--apply` also applies. The real folder is never changed.

Result (`docs/evidence/prod-stack-on-floci.txt`): plan 133 resources, apply
created 123 including VPC, NAT, ALB with listeners and rules, ECS cluster,
task definitions and services, RDS instance record, ElastiCache group, EFS,
ACM, Route 53 records, AWS Backup plan, alarms. This found two bugs that
`terraform validate` did not (troubleshooting issues 4 and 5).

## Services used and limitations that affect this solution

| Service | Works in Floci for us? | Limitation |
|---|---|---|
| S3 | yes | plain HTTP endpoint, so the deny-non-TLS bucket policy is switched off in floci-local (Floci enforces bucket policies) |
| Secrets Manager, SSM, KMS, STS | yes | KMS encryption is emulated, not real HSM |
| CloudWatch Logs / Metrics / Alarms, SNS | yes | alarms change state; SNS email is not delivered |
| IAM | stored | not enforced by default, so least privilege can not be proven locally |
| EC2 VPC / subnets / SG | stored | no routing, NAT, NACL or SG filtering. Floci returns `referenced_security_group_id` as `000000000000/sg-...` instead of `sg-...`, so every plan shows the 9 SG rules as "update in-place" (cosmetic drift, nothing changes) |
| ECR | control plane yes | `docker push` needs Floci's Docker backed `registry:2`, which needs the Docker socket |
| ECS | control plane yes | running tasks needs the Docker socket |
| RDS, ElastiCache | control plane yes | real databases need the Docker socket |
| OpenSearch | **no** without socket | domain stays "processing" forever in real mode; mock mode only stores metadata |
| ELBv2 (ALB) | control plane yes | listeners can forward locally, but no ACM TLS like AWS |
| ACM, Route 53 | records only | no real DNS validation |
| Cost / quotas / HA | n/a | nothing to measure |

Why not mount the Docker socket to get ECS/RDS/ECR running in Floci? It would
make Floci start containers on my host with full Docker access. For this
assignment Docker Compose already runs the real app, so the extra risk buys
little. It is listed as an optional improvement: a separate
`docker-compose.docker-backed.yml` for a throwaway VM.

## Emulator settings are kept separate

| | Floci | AWS |
|---|---|---|
| Root module | `envs/floci-local` | `envs/aws-prod` |
| Provider | endpoints to localhost, `test` keys, skip checks | no endpoints, credentials from environment, `allowed_account_ids` |
| Backend | local file (ignored by Git) | S3 with lock file, values in `backend.hcl` (ignored by Git) |
| Names | `virto-local-*`, `virto/local/*` | `virto-prod-*`, `virto/prod/*` |
| Network | no NAT, no S3 endpoint | NAT, S3 endpoint |
| Data tier, ALB, ECS | not created | created |
