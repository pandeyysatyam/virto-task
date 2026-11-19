# Architecture

This document covers Task 1: what Virto Commerce needs, how the pieces talk to
each other, how it runs locally, how it would run on AWS, and why I chose this
setup.

Diagrams (draw.io, open with app.diagrams.net or the draw.io desktop app):

- `docs/diagrams/architecture.drawio` page 1: local deployment (Docker Compose + Floci)
- `docs/diagrams/architecture.drawio` page 2: proposed AWS deployment
- PNG exports: `docs/diagrams/architecture-local.png` and `docs/diagrams/architecture-aws.png`

## 1. What Virto Commerce is made of

Virto Commerce is a headless B2B commerce platform written in .NET. It has two
parts that are deployed separately:

| Part | What it does | What I deploy |
|---|---|---|
| **Platform** (backend) | ASP.NET Core host that loads modules: catalog, pricing, inventory, cart, orders, customers, search, notifications and the xAPI GraphQL layer. Also serves the admin UI (back office) and the REST API. Runs background jobs with Hangfire. | `ghcr.io/virtocommerce/platform:3.1076.13` + 60 modules baked in at build time |
| **Frontend** (storefront) | The shop that customers use. The current one is **vc-frontend**, a Vue 3 single page app. It talks to the platform only through GraphQL (`/graphql`) and the token endpoint (`/connect/token`). | `vc-frontend` release 2.59.1 served by nginx |

The platform on its own is just a host. Without modules there is no catalog,
no cart and no GraphQL API, so the storefront would not work. That is why my
platform image adds the modules from Virto's official module bundle.

## 2. Dependencies

| Dependency | Required? | Local | AWS | Notes |
|---|---|---|---|---|
| Database | yes | PostgreSQL 18.7 (container) | RDS PostgreSQL 18, Multi AZ | Virto supports SQL Server, PostgreSQL and MySQL. **Platform 3.1076 needs PostgreSQL 18+**, the health check fails on 17 (found during testing, see troubleshooting issue 2). |
| Search engine | yes | Lucene (index files on a volume) | Amazon OpenSearch Service 2.19 | Lucene is built in and needs no extra container, but the index sits on local disk of one instance. With 2+ platform tasks the index must be shared, so AWS uses OpenSearch (`VirtoCommerce.OpenSearch` module added to the image). |
| Cache | optional for 1 instance, required for 2+ | Valkey 8.1 (Redis compatible) | ElastiCache for Valkey, 2 nodes | Used for distributed cache invalidation and SignalR between platform instances. I run it locally too, so the local setup has the same moving parts as AWS. |
| File storage | yes | Docker volumes | EFS (with access point) | Uploaded product images (`wwwroot/assets`) and CMS content (`wwwroot/cms-content`). Virto has no S3 assets provider in the bundle (only Azure Blob and file system), so on AWS the file system provider points at EFS. |
| Background jobs | yes | Hangfire, stored in PostgreSQL | same | Stored in the database so jobs survive restarts and are shared between tasks. |

## 3. Versions and compatibility assumptions

Everything is pinned. No image uses `latest`.

| Component | Version | Source | Why this version |
|---|---|---|---|
| Platform base image | `ghcr.io/virtocommerce/platform:3.1076.13` (amd64, .NET 10, Ubuntu 24.04) | Virto's GitHub Container Registry | This is the platform version named in Virto's stable bundle 16.0.13 (`PlatformImageTag`). See note below about Docker Hub. |
| Module bundle | 16.0.13 (`docker/platform/modules.json`, 59 modules) + `VirtoCommerce.OpenSearch` 3.1005.0 | `VirtoCommerce/vc-modules` bundles/latest | Virto tests modules together as a bundle. Mixing module versions by hand is the most common way to break a Virto install. OpenSearch module needs platform 3.1073.0+, checked in its `module.manifest`. |
| Frontend | vc-frontend 2.59.1, SHA256 `1ee29552...d847f` | GitHub release of `VirtoCommerce/vc-frontend` | The frontend version named in the same bundle (`ThemeB2BVue`). |
| nginx | `nginxinc/nginx-unprivileged:1.30.6-alpine` | Docker Hub (official nginx org) | Stable branch, runs as uid 101 on port 8080. |
| PostgreSQL | `postgres:18.7-alpine3.24` | Docker Hub official | Platform requires 18+. RDS has PostgreSQL 18. |
| Valkey | `valkey/valkey:8.1.11-alpine3.24` | Docker Hub official | ElastiCache supports Valkey 8.1. |
| Floci | `floci/floci:2.5.0` | Docker Hub | Latest release at the time (15 Nov 2026). |
| Terraform | 1.15.4, AWS provider ~> 6.0 | | |

**Docker Hub vs GHCR.** The assignment links `hub.docker.com/r/virtocommerce/platform`.
I checked it: the Linux image there only has the tags `latest` and
`dev-linux-experimental`, and on 18 Nov 2026 `latest` was platform **3.1100.0**,
which is newer than any stable bundle. A moving `latest` tag can not be pinned
or rolled back. Virto publishes the same image with version tags on GHCR
(`ghcr.io/virtocommerce/platform`) and the stable bundle points to it, so I
use that. It is the same publisher and the same Dockerfile, just a registry
that has version tags.

**Old storefront image.** `virtocommerce/storefront` on Docker Hub was last
updated in April 2024. It is the old ASP.NET Core storefront that Virto
replaced with vc-frontend. I did not use it because:

- it is no longer maintained, so no security fixes for its .NET runtime and packages
- it was built against older platform APIs and is not part of the current bundle
- the official local setup from Virto (`VirtoCommerce/start-local`) uses vc-frontend behind nginx, the same way I do

**Architecture (CPU).** Both Virto images are amd64 only. On an Apple Silicon
Mac they run through Rosetta emulation (the compose file sets
`platform: linux/amd64`). It works, but the first start is slower. On AWS the
task definitions set `cpu_architecture = X86_64` for the same reason, so
Graviton (cheaper ARM) is not an option until Virto publishes arm64 images.

## 4. Containers, communication and ports

```
browser ──► frontend (nginx :8080) ──► /graphql, /connect/token, /files, /cms-content ... ──► platform (:8080)
browser ──► platform (:8080) admin UI + REST API                                             │
                                                                                            ├─► db    (PostgreSQL :5432)
                                                                                            └─► cache (Valkey :6379)
```

| Container | Listens on | Published to host | Networks |
|---|---|---|---|
| frontend | 8080 | `127.0.0.1:8088` | frontend |
| platform | 8080 | `127.0.0.1:8090` | frontend, backend |
| db | 5432 | not published | backend (internal) |
| cache | 6379 | not published | backend (internal) |
| floci | 4566 | `127.0.0.1:4566` | floci_default |

Points worth explaining:

- **nginx proxies API calls to the platform.** The SPA calls `/graphql` on its
  own origin. nginx forwards it to `platform:8080`. So the browser only talks
  to one origin, there is no CORS setup, and the platform does not need to be
  public for the shop to work. This is the same pattern as Virto's own
  `start-local` nginx config, which I used as the starting point.
- **nginx resolves the platform name at request time** (`resolver` +
  variable in `proxy_pass`). Without this, nginx fails to start if the platform
  container is not up yet, and keeps an old IP after the platform restarts.
- **Two networks.** `backend` is marked `internal: true`: no internet access
  and nothing in it is reachable from the frontend container. Only the
  platform is on both networks. This copies the public/private subnet split on
  AWS. `validate.sh` checks that the frontend container can not open a
  connection to `db:5432`.
- **Ports bound to 127.0.0.1.** Nothing is reachable from the LAN.
- **Port 8080 inside containers.** Both containers run as non-root users,
  and non-root processes can not bind ports below 1024.

## 5. Persistent storage and configuration

| Data | Where (local) | Where (AWS) | Survives |
|---|---|---|---|
| Database | volume `virto_pgdata` | RDS, Multi AZ, automated backups 14 days + AWS Backup | restart, container removal |
| Uploaded images | volume `virto_platform-assets` | EFS | same |
| CMS content | volume `virto_platform-content` | EFS (same file system) | same |
| Search index | volume `virto_platform-search` | OpenSearch | same. It is derived data and can be rebuilt from the database. |
| Cache data | volume `virto_cachedata` (AOF on) | ElastiCache | cache only, safe to lose |
| Modules | inside the image | inside the image | n/a, changes only with a new image |

I deliberately **do not** put the `modules` folder on a volume (Virto's own
compose file does). If modules live on a volume, a new image with newer modules
is silently ignored because the old volume content wins. With modules in the
image, the image tag is the single source of truth for the code that runs.

Configuration is 100% environment variables. ASP.NET Core maps
`Section__Key` env vars onto `appsettings.json` (`ConnectionStrings__VirtoCommerce`
overrides `ConnectionStrings:VirtoCommerce`). The values come from `.env`,
which `setup.sh` fills from Secrets Manager. On ECS the same variable names are
injected from Secrets Manager by the task definition.

## 6. Proposed AWS architecture

Region: ap-south-1 (Mumbai), two availability zones. Full design and
implementation steps: [aws-deployment.md](aws-deployment.md).

- **VPC** 10.20.0.0/16, three subnet tiers per AZ: public (ALB, NAT), app (ECS
  tasks), data (RDS, ElastiCache, OpenSearch, EFS). Data subnets have no route
  to the internet.
- **Route 53 + ACM**: `shop.example.com` and `admin.example.com`, one
  certificate, DNS validated.
- **ALB** with HTTPS (TLS 1.2/1.3 policy), HTTP redirects to HTTPS.
  `shop.*` goes to the frontend target group. `admin.*` goes to the platform
  target group, but only from office/VPN IP ranges, everyone else gets 403.
  Exception: `/assets/*` and `/cms-content/*` on that host are open to everyone,
  because product images and CMS files are linked from the shop.
- **ECS on Fargate**: platform service (2 to 4 tasks, 2 vCPU / 4 GB) and
  frontend service (2 to 4 tasks, 0.25 vCPU / 512 MB). CPU target tracking
  autoscaling. Deployment circuit breaker with automatic rollback. The frontend
  finds the platform through Cloud Map private DNS (`platform.virto-prod.local`).
- **RDS PostgreSQL 18**, Multi AZ, encrypted with KMS, `rds.force_ssl=1`,
  14 day PITR, deletion protection.
- **ElastiCache for Valkey**, 2 nodes, failover, TLS + auth token.
- **OpenSearch** 2 nodes in 2 AZs, encryption at rest and in transit, fine
  grained access control.
- **EFS** for assets, encrypted, mounted through an access point that forces
  uid 1654 (the user the platform runs as).
- **ECR** repositories, immutable tags, scan on push.
- **Secrets Manager** for DB, cache, search and admin credentials, injected
  into tasks at start. **SSM Parameter Store** for non-secret settings.
- **CloudWatch** logs (30 days), Container Insights, alarms to SNS.
- **AWS Backup** daily and monthly plans for RDS and EFS, plus logical
  `pg_dump` backups to S3.
- **GitHub Actions** deploys through an OIDC role (no AWS keys stored in GitHub).

## 7. Local development architecture with Floci

Floci is a free AWS emulator (MIT license) on port 4566. I use it for the AWS
side of the local setup, not to run the app:

| AWS service (emulated) | What uses it locally |
|---|---|
| Secrets Manager | `setup.sh` reads the DB, cache and admin passwords from it to build `.env`, the same way ECS injects them |
| SSM Parameter Store | image versions, backup bucket name, release history used by `rollback.sh` |
| S3 | `backup.sh` uploads dumps there, `restore.sh` downloads them |
| KMS | encrypts secrets, bucket, logs, ECR |
| CloudWatch Logs + Metrics + Alarms, SNS | `monitor.sh` pushes a health metric and container logs, the alarm changes state |
| EC2 (VPC, subnets, security groups) | same network module as production, to check the design |
| IAM | same least privilege roles as production |
| ECR | repositories created (pushing images needs Floci's Docker backed registry, see limitations) |

The app itself (platform, frontend, PostgreSQL, Valkey) runs in Docker
Compose. Same Terraform modules are used for Floci and AWS, only the
environment folder and provider settings differ.

## 8. Emulator vs real AWS

| Topic | Floci (what I ran) | Real AWS |
|---|---|---|
| Credentials | dummy `test/test`, account `000000000000` | SSO / OIDC role, real account |
| Endpoints | `http://localhost:4566` for every service | regional HTTPS endpoints |
| IAM | policies stored, not enforced by default | every call checked |
| Networking | VPC, subnets, SGs are records only. No routing, NAT or SG filtering (SG enforcement is off by default) | real isolation |
| S3 bucket policy | enforced, which is why the TLS-only policy is off locally (Floci is plain HTTP) | enforced over HTTPS |
| RDS, ElastiCache, OpenSearch, ECS tasks, ECR push | need the Docker socket mounted into Floci. I did not mount it (it gives root on the host). The control plane works, the data plane does not | managed services |
| Durability, HA, scaling | none | Multi AZ |
| Cost | free | see cost estimate |

**What was actually deployed where:**

1. **Local Docker deployment**: Virto platform + frontend + PostgreSQL + Valkey,
   running and tested. This is the working application.
2. **Emulated AWS resources (Floci)**: about 80 resources from `envs/floci-local`
   used by the scripts, plus the full production stack applied once as a test
   (123 of 133 resources created, see `docs/evidence/prod-stack-on-floci.txt`).
3. **Real AWS**: **not deployed.** The production Terraform is written,
   validated and planned against the emulator. It was not applied to an AWS
   account because no account was authorised for this assignment.

## 9. Why this approach

- **Docker Compose locally**: matches the assignment, easy to reproduce on any
  laptop, and the same images go to ECS later.
- **Modules baked into the image**: immutable images, reliable rollback,
  autoscaled tasks start with exactly the same code.
- **PostgreSQL instead of SQL Server**: SQL Server images do not run on Apple
  Silicon at all, and on AWS RDS PostgreSQL costs less than RDS SQL Server
  (no licence). Virto supports PostgreSQL officially.
- **ECS Fargate instead of EKS or EC2**: two stateless services do not need
  Kubernetes. Fargate means no nodes to patch. EKS adds about 73 USD/month for
  the control plane plus a lot of operational work. EC2 would be cheaper per
  CPU but needs AMI patching and capacity management.
- **OpenSearch instead of Elasticsearch on AWS**: managed by AWS, inside the
  VPC, and Virto has a dedicated module for it.
- **One set of Terraform modules for both environments**: the emulator run
  exercises the same code that would go to production. Running the production
  root module against Floci found two real bugs before any AWS account was
  involved (troubleshooting issues 4 and 5).
