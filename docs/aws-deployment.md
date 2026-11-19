# Real AWS deployment: design and steps

> **Status: designed, not deployed.** The Terraform in `infra/terraform/envs/aws-prod`
> is validated (`terraform validate`), formatted, and planned + applied against
> the Floci emulator to catch plan-time errors. It has **not** been applied to a
> real AWS account. The assignment says not to create paid resources without
> approval, and no account was provided.

Diagram: `docs/diagrams/architecture.drawio`, page "AWS".

## 1. Target layout

```
                    Route 53: shop.example.com, admin.example.com
                                      │
                         ACM certificate (DNS validated)
                                      │
 Internet ──► ALB (public subnets, HTTPS 443, HTTP 80 -> 301 to HTTPS)
               │ host shop.*                         │ host admin.* + source IP in office/VPN list
               ▼                                     ▼
      ECS service "frontend"                ECS service "platform"
      Fargate, 2-4 tasks                    Fargate, 2-4 tasks
      nginx + vc-frontend                   Virto platform + modules
      app subnets, no public IP             app subnets, no public IP
               │  /graphql etc via Cloud Map DNS     │
               └──────────────► platform.virto-prod.local:8080
                                                     │
                     ┌───────────────┬───────────────┼────────────────┐
                     ▼               ▼               ▼                ▼
               RDS PostgreSQL   ElastiCache     OpenSearch          EFS
               18, Multi AZ     Valkey, 2 nodes 2 nodes, 2 AZ       assets
                          (data subnets, no internet route)

 ECS tasks reach ECR, CloudWatch, Secrets Manager through the NAT gateway.
 S3 traffic goes through a free gateway endpoint.
```

## 2. Terraform layout

```
infra/terraform/
  modules/
    network/        VPC, 3 subnet tiers x 2 AZ, IGW, NAT, route tables, S3 endpoint, security groups
    storage/        KMS key (with policy for Logs and CloudWatch), S3 backup bucket, EFS + access point
    secrets/        random passwords -> Secrets Manager; settings -> SSM Parameter Store
    registry/       ECR repos, immutable tags, scan on push, lifecycle
    data/           RDS PostgreSQL 18, ElastiCache Valkey, OpenSearch
    app/            ALB, listeners and rules, target groups, ECS cluster, task definitions,
                    services, Cloud Map, autoscaling
    iam/            ECS execution role, task roles, GitHub OIDC deploy role
    observability/  log groups, SNS topic, alarms
  envs/
    floci-local/    emulator: network, storage, secrets, registry, iam, observability
    aws-prod/       real AWS: every module + ACM, Route 53 records, AWS Backup
  floci-overrides/  override file used to plan aws-prod against Floci
```

`envs/floci-local` and `envs/aws-prod` share the modules. Emulator settings
(endpoints, dummy keys, local backend) exist only in `envs/floci-local/providers.tf`
and `floci-overrides/`. `aws-prod` has no emulator settings and pins
`allowed_account_ids`, so it refuses to run against the wrong account.

## 3. Key design decisions

| Area | Decision | Why |
|---|---|---|
| Compute | ECS Fargate | No servers to patch, per task isolation, native ALB and Secrets Manager integration. EKS is overkill for two services. |
| CPU arch | X86_64 | Virto images are amd64 only. |
| Search | OpenSearch + `VirtoCommerce.OpenSearch` module | Lucene keeps the index on local disk, which breaks with more than one platform task. |
| Cache | ElastiCache Valkey, 2 nodes | Needed for cache invalidation and SignalR across tasks. Valkey is about 20% cheaper than Redis OSS on ElastiCache. |
| Files | EFS through an access point (uid 1654) | Shared between tasks, survives task replacement. Virto has no S3 assets provider in the bundle. |
| Service to service | Cloud Map private DNS | nginx resolves upstreams with its own DNS resolver and does not read the `/etc/hosts` entries that ECS Service Connect adds, so plain DNS is the simple and working choice. |
| Admin UI | separate host name, ALB rule with source IP condition | Back office is not exposed to the internet. |
| TLS | ends at the ALB, policy `ELBSecurityPolicy-TLS13-1-2-2021-06` | Traffic ALB to task stays inside the VPC. `ASPNETCORE_FORWARDEDHEADERS_ENABLED=true` so the platform knows the original request was HTTPS. |
| Deploy safety | ECS circuit breaker with rollback, min healthy 100% | A bad image never replaces all healthy tasks. |
| Secrets | Secrets Manager, injected by ECS at task start | Not in images, not in task definition plain text, not in Git. |
| CI auth | GitHub OIDC role limited to `refs/heads/main` of one repo | No long lived AWS keys anywhere. |
| State | S3 backend with `use_lockfile` | Terraform 1.10+ native locking, no DynamoDB table. |

## 4. Implementation steps (when an account is approved)

1. **Bootstrap (once, by an admin)**
   - Create the state bucket (versioning, SSE-KMS, block public access).
   - Create a public Route 53 hosted zone for the domain or use an existing one.
   - Set an AWS Budget with an alert (for example 600 USD/month).
2. **Configure**
   ```bash
   cd infra/terraform/envs/aws-prod
   cp terraform.tfvars.example terraform.tfvars   # fill account, domains, zone id, admin CIDRs
   cat > backend.hcl <<EOF
   bucket       = "<state-bucket>"
   key          = "virto/prod/terraform.tfstate"
   region       = "ap-south-1"
   encrypt      = true
   use_lockfile = true
   EOF
   aws sso login --profile virto-prod && export AWS_PROFILE=virto-prod
   terraform init -backend-config=backend.hcl
   ```
3. **Create the registry first, push images**
   ```bash
   terraform apply -target=module.registry -target=module.storage
   REG=$(terraform output -json ecr_repositories | jq -r .platform | cut -d/ -f1)
   aws ecr get-login-password | docker login --username AWS --password-stdin "$REG"
   docker tag virto-platform:3.1076.13-b16.0.13 "$REG/virto-prod/platform:3.1076.13-b16.0.13"
   docker tag virto-frontend:2.59.1            "$REG/virto-prod/frontend:2.59.1"
   docker push "$REG/virto-prod/platform:3.1076.13-b16.0.13"
   docker push "$REG/virto-prod/frontend:2.59.1"
   ```
4. **Apply everything**
   ```bash
   terraform plan -out=prod.plan    # review: about 135 resources
   terraform apply prod.plan        # RDS + OpenSearch take 15 to 25 minutes
   ```
5. **First start of the platform**: the first task runs the database migrations
   (about 2 to 5 minutes). Watch it with
   `aws logs tail /virto-prod/platform --follow`.
6. **Platform init**: run `scripts/setup-platform.sh` with
   `PLATFORM_PUBLIC_URL=https://admin.example.com` and the admin password from
   Secrets Manager (`virto/prod/platform-admin`), from a machine inside the
   admin CIDR list. Skip sample data for a real shop.
7. **Check**: `curl https://shop.example.com/nginx-health`,
   `curl https://admin.example.com/health`, open the shop, log in to admin.
8. **Hand over to CI**: put `deploy_role_arn` output into the GitHub secret
   `AWS_DEPLOY_ROLE_ARN`, create the `production` environment with required
   reviewers. From then on, the `deploy` job pushes images and rolls the services.

## 5. Operations on AWS

| Task | How |
|---|---|
| Deploy new version | CI `deploy` job (manual approval). Registers a new task definition with the new image tag, updates the services, waits for `services-stable`. |
| Rollback | Automatic if new tasks fail health checks (circuit breaker). Manual: `aws ecs update-service --task-definition virto-prod-platform:<previous revision>`. If the new version migrated the schema, restore RDS to a point in time before the deploy. |
| Scale | Autoscaling on CPU 60%. Manual: change `platform_min_tasks`. |
| Logs | CloudWatch Logs `/virto-prod/platform`, `/virto-prod/frontend`, Logs Insights. |
| Shell into a task | `aws ecs execute-command` (ECS Exec, logged in CloudTrail). |
| DB access | Only from tasks. For admin access use ECS Exec or an SSM port forward through a bastion task; RDS is not public. |
| Backup restore | RDS point in time restore to a new instance, then switch the secret's host. EFS restore from AWS Backup. Logical `pg_dump` files in S3 for portability. |
| Rotate DB password | change `random_password.db` (taint) and apply, then force a new ECS deployment. Proposed improvement: RDS managed master password with rotation. |

## 6. Cleanup

```bash
# deletion protection is on for RDS and the ALB on purpose, switch it off first:
terraform apply -var deletion_protection=false
terraform destroy -var deletion_protection=false
```
Then delete the state bucket and the hosted zone if they were created only for this.
