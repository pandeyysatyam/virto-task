# Security and operations

Task 5. For every control the table says whether it is **implemented and
tested locally**, **implemented in Terraform** (written, validated, applied to
Floci, not to real AWS) or **proposed** (described only).

## Summary

| # | Control | Local (Docker + Floci) | AWS Terraform | Notes |
|---|---|---|---|---|
| 1 | No hard coded secrets | implemented | implemented | `.env` is generated, mode 600, in `.gitignore`. Values come from Secrets Manager. Repo has only `change-me` placeholders. |
| 2 | Default admin password replaced | implemented | implemented (same script) | Virto ships with `admin / store`. `setup-platform.sh` changes it on first run; `validate.sh` checks that `admin/store` is rejected. |
| 3 | Least privilege IAM | n/a (Floci does not enforce IAM) | implemented | Separate execution role, task roles and CI role, resource scoped. |
| 4 | Network boundaries | implemented | implemented | Internal Docker network vs public/app/data subnets + SG chaining. |
| 5 | TLS / HTTPS | not used (localhost) | implemented | ALB with ACM, TLS 1.2+ policy, HTTP to HTTPS redirect, RDS `force_ssl`, Valkey TLS, OpenSearch HTTPS, EFS TLS. |
| 6 | Database access restriction | implemented | implemented | Port not published; on AWS only the platform SG can reach 5432. Not publicly accessible. |
| 7 | Image pinning | implemented | implemented | Every image has a version tag, frontend zip has a SHA256 check, ECR tags immutable. |
| 8 | Vulnerability scanning | in CI (Trivy) | implemented | Trivy in GitHub Actions, ECR scan on push. |
| 9 | Non-root containers | implemented | implemented | platform uid 1654, nginx uid 101 with read-only root filesystem. |
| 10 | Logs | implemented | implemented | json-file with rotation; shipped to CloudWatch on Floci; awslogs driver on ECS. |
| 11 | Health checks | implemented | implemented | Docker HEALTHCHECK on every container; ALB target health; ECS container health. |
| 12 | Monitoring and alerting | implemented (Floci) | implemented | Custom metric + alarm + SNS on Floci; ALB, RDS, ECS alarms on AWS. |
| 13 | Backup and restore | implemented, tested | implemented | `pg_dump` + volumes to S3 (Floci), restore tested; AWS Backup + RDS PITR. |
| 14 | Availability and scaling | single host | implemented | 2 AZ, Multi AZ RDS, 2 node cache and search, autoscaling, circuit breaker. |
| 15 | Encryption at rest | Docker volumes are not encrypted | implemented | One KMS key with rotation for S3, RDS, EFS, ElastiCache, OpenSearch, Secrets, Logs, ECR. |
| 16 | WAF | | proposed | AWS managed rule sets on the ALB (about 10 to 15 USD/month). |
| 17 | GuardDuty, Security Hub, CloudTrail org trail | | proposed | Account level, normally owned by the platform/security team. |
| 18 | Secret rotation | | proposed | RDS managed master password with rotation, or a rotation Lambda. |

## 1. Secrets

- `.env.example` has only placeholders. `.env` is ignored by Git.
- `setup.sh` reads passwords from Secrets Manager (`virto/local/db`,
  `virto/local/cache`, `virto/local/platform-admin`). Terraform generated them
  with `random_password`. If Floci is not available, `--offline` makes random
  ones with `openssl rand`.
- On ECS the task definition references secrets by ARN (`valueFrom`), so the
  values never appear in the task definition, in Terraform plan output, or in
  the image. Only the execution role can read them, and only those ARNs.
- Known gap: `random_password` values are in Terraform state. The state bucket
  must be encrypted with tight access. Improvement: RDS managed master user
  password (`manage_master_user_password = true`) so Terraform never sees it.
- Evidence and screenshots in `docs/evidence` contain no passwords. Scripts
  print where a password lives, never the value.

## 2. IAM (least privilege)

Defined in `infra/terraform/modules/iam/main.tf`:

| Role | Who uses it | Can do |
|---|---|---|
| `virto-prod-ecs-execution` | ECS agent before the container starts | pull from the 2 ECR repos, write to the 2 log groups, read the 4 app secrets and the app SSM parameters, decrypt with the app KMS key |
| `virto-prod-platform-task` | platform code | read/write `s3://<backup bucket>/platform/*` only, mount the EFS file system only through its access point, ECS Exec channels |
| `virto-prod-frontend-task` | nginx | nothing |
| `virto-prod-github-deploy` | GitHub Actions via OIDC | push to the 2 ECR repos, register task definitions, update only the 2 services, pass only the 3 roles above and only to `ecs-tasks.amazonaws.com`. Trust limited to `repo:<org>/<repo>:ref:refs/heads/main`. |
| `virto-prod-backup` | AWS Backup | AWS managed backup policy |

The only `"*"` resources are actions that AWS does not allow to be scoped
(`ecr:GetAuthorizationToken`, `ecs:RegisterTaskDefinition`,
`ecs:DescribeTaskDefinition`, ECS Exec `ssmmessages:*`).

## 3. Network boundaries

Local:

- `backend` Docker network is `internal: true`: db and cache have no internet
  and are not reachable from the frontend container (checked by `validate.sh`).
- db and cache ports are not published. Platform and frontend are published on
  `127.0.0.1` only.

AWS:

- Public subnets: only the ALB and the NAT gateway. `map_public_ip_on_launch = false`.
- App subnets: ECS tasks, no public IP, outbound through NAT.
- Data subnets: route table with local routes only.
- Security groups reference each other: `alb -> frontend -> platform -> db/cache/efs/search`.
  Nothing in the data tier accepts traffic from a CIDR.
- Admin host name only from `admin_allowed_cidrs`, everyone else gets 403 from the ALB.
- Floci limitation: it stores VPCs and SGs but does not enforce them (no routing,
  SG enforcement is off by default), so these boundaries are verified on Docker
  networks locally and only designed for AWS.

## 4. TLS

- ALB: ACM certificate for `shop` and `admin`, `ELBSecurityPolicy-TLS13-1-2-2021-06`,
  port 80 only redirects. `drop_invalid_header_fields = true`.
- Platform sees HTTP from the ALB. `ASPNETCORE_FORWARDEDHEADERS_ENABLED=true`
  makes it trust `X-Forwarded-Proto`. `VirtoCommerce__AllowInsecureHttp=true`
  is needed because the OpenID token endpoint otherwise refuses non-HTTPS
  requests, and the hop ALB to task is HTTP inside the VPC.
- RDS parameter `rds.force_ssl = 1`, connection string `SSL Mode=Require`.
- ElastiCache `transit_encryption_enabled` + auth token, `ssl=true` in the
  connection string.
- OpenSearch `enforce_https`, node to node encryption. EFS mount with
  `transit_encryption = ENABLED`.
- S3 bucket policy denies any request without TLS.

## 5. Container images

- Pinned tags for every image (see architecture.md section 3). Base images are
  not `latest`. The module list is a lock file, and the frontend zip is checked
  against its SHA256.
- Platform image runs as uid 1654, frontend as uid 101 with a read-only root
  filesystem and three tmpfs folders.
- Platform image adds only `curl` (for the health check).
- CI runs Trivy on both images. The frontend gate fails on CRITICAL findings
  that have a fix. The platform scan is report only: the base image belongs to
  Virto and has findings we can not fix ourselves; they are tracked and the
  response is to move to a newer bundle.
- ECR `scan_on_push = true`, immutable tags, keeps the last 20 images.
- Proposed: sign images (cosign) and verify on deploy; Dependabot for the
  pinned versions.

## 6. Logs, health checks, monitoring, alerting

| Signal | Local | AWS |
|---|---|---|
| Container logs | json-file driver, 10 MB x 5 files per container; `make logs` | awslogs to `/virto-prod/<service>`, 30 days, KMS encrypted |
| Health | Docker HEALTHCHECK: `/health` (platform, checks DB, Redis, modules, Hangfire), `/nginx-health` (frontend), `pg_isready`, `valkey-cli ping` | same checks in ECS + ALB target group health checks |
| Metrics | `monitor.sh` publishes `UnhealthyServices` to CloudWatch on Floci | Container Insights (enhanced), ALB, RDS, ElastiCache metrics |
| Alerts | alarm `virto-local-unhealthy-services` -> SNS topic (Floci) | ALB 5xx, unhealthy targets per TG, p95 latency, RDS CPU and free storage, ECS memory -> SNS -> email |
| Tracing | no | proposed: `VirtoCommerce.OpenTelemetry` module (already in the bundle) to AWS X-Ray / ADOT |

## 7. Backup and restore

| What | Local | AWS |
|---|---|---|
| Database | `backup.sh`: `pg_dump -Fc` | RDS automated backups 14 days (PITR) + AWS Backup daily (35 days) and monthly (1 year, cold storage after 30 days) |
| Files | `backup.sh`: tar of assets and content volumes | AWS Backup of EFS |
| Off-site copy | upload to S3 bucket (Floci), versioned, lifecycle 30 days | same bucket design: versioning, KMS, TLS only, IA after 30 days, delete after 90 |
| Integrity | `SHA256SUMS` checked by `restore.sh` before touching anything | AWS Backup + S3 checksums |
| Restore | `restore.sh [name]`: tested, see testing.md | RDS PITR to a new instance, EFS restore job |
| Before every deploy | `deploy.sh` takes a `pre-deploy` backup automatically | snapshot before migrations (proposed as a CI step) |

Targets proposed for production: RPO 5 minutes (PITR), RTO 1 hour.

## 8. Availability, scaling, recovery

- Two AZs for everything. Single NAT gateway by default to save about 32 USD;
  switch `single_nat_gateway = false` to remove that single point of failure.
- Platform 2 to 4 tasks, frontend 2 to 4 tasks, CPU target 60%. Scaling the
  platform needs shared cache (Valkey) and shared search (OpenSearch), which is
  exactly why those are separate services on AWS.
- Deployment circuit breaker rolls back automatically.
- Locally: `restart: unless-stopped`, health based `depends_on`, nginx that
  re-resolves the platform after restarts. Recovery from a DB outage and a
  process crash is tested by `failure-drill.sh`.

## 9. Cost

See [cost-estimate.md](cost-estimate.md). About 543 USD/month for the
production layout, staging about 150 USD.
