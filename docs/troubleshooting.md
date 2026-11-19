# Troubleshooting

Part 1 lists the real problems I hit while building this, with root cause and
fix. Part 2 is a quick reference for common errors.

## Part 1: issues found during the build

### Issue 1: vc-build failed while installing modules (HttpClient timeout)

**Symptom.** First version of `docker/platform/Dockerfile` used Virto's own CLI
(`vc-build install --package-manifest-path modules.json`) in a .NET SDK build
stage. The build failed after about 4 minutes:

```
InstallPlatform   Succeeded  2:32
InstallModules    Failed     1:40  // ArgumentException: Errors occurred while installing modules.
[ERR] System.Threading.Tasks.TaskCanceledException: The request was canceled due to
      the configured HttpClient.Timeout of 100 seconds elapsing.
```

**Investigation.**
- `--progress=plain` showed the timeout was on downloading module zips.
- Measured the link: `curl -w '%{speed_download}'` on one module from GitHub
  releases gave about 20 to 90 KB/s on this network at that time.
- vc-build uses a fixed 100 s HttpClient timeout per file and has no option to
  change it. It also downloaded the whole platform again (2.5 minutes), which
  we do not need because the base image already has it.
- The SDK stage ran under amd64 emulation because of `--platform linux/amd64`,
  making it slower still.

**Fix.**
- Generate a lock file (`docker/platform/modules.lock`) once with
  `scripts/gen-modules-lock.py`: module id, version and exact GitHub release URL
  for all modules of bundle 16.0.13.
- In the Dockerfile, download with `curl --retry 5 --retry-all-errors`,
  6 in parallel, in an Alpine stage that runs on the build machine's native
  architecture (`FROM --platform=$BUILDPLATFORM`). Modules are plain zips, so
  the architecture does not matter.
- Check that the number of unpacked modules equals the number of lines in the
  lock file, so a partial download can not produce an image.

**Result.** Build finished, `modules installed: 59 of 59` (60 after adding
OpenSearch). Layer is cached, so later builds skip the download unless the lock
file changes.

### Issue 2: platform unhealthy, "Virto Commerce requires PostgreSQL 18+"

**Symptom.** Containers started, but the platform stayed `health: starting`
and then `unhealthy`. The storefront returned errors.

**Investigation.**
```bash
docker compose logs platform | grep ERR
[16:38:36 ERR] Health check PostgreSql health with status Unhealthy completed after 24.8ms
               with message 'PostgreSQL 170012 is not supported. Virto Commerce requires PostgreSQL 18+.'
```
The migrations had actually run (195 tables were created), so the connection
worked. The platform's own health check rejects PostgreSQL 17.

**Root cause.** I picked PostgreSQL 17 because it is the most common RDS major
version. Platform 3.1076 requires 18. Virto's own `start-local` uses 18.3,
which confirmed it.

**Fix.** `postgres:18.7-alpine3.24`. PostgreSQL 18 images also changed the data
path: the volume now mounts at `/var/lib/postgresql` (not `/var/lib/postgresql/data`),
otherwise the container refuses to start with the old layout. The database
volume was empty test data, so it was recreated. On AWS: RDS engine version
`18` and parameter group family `postgres18`.

**Lesson.** Read the health endpoint output, not only the container state.
`curl localhost:8090/health` lists every check with a message.

### Issue 3: frontend unhealthy, nginx had no config

**Symptom.** `frontend` container `unhealthy`, `curl localhost:8088` gave
connection refused, although the nginx log said "start worker processes".

**Investigation.**
```
20-envsubst-on-templates.sh: ERROR: /etc/nginx/templates exists, but /etc/nginx/conf.d is not writable
10-listen-on-ipv6-by-default.sh: info: /etc/nginx/conf.d/default.conf is not a file or does not exist
```
nginx started with no server block, so nothing listened on 8080.

**Root cause.** For hardening I set `read_only: true` and added tmpfs mounts.
Docker creates tmpfs mounts owned by root, and the unprivileged nginx image
runs as uid 101, so the entrypoint could not write the rendered config.

**Fix.** `tmpfs: - /etc/nginx/conf.d:uid=101,gid=101` (same for `/tmp` and
`/var/cache/nginx`). The frontend now runs read-only and non-root, and
`validate.sh` checks both.

### Issue 4: production Terraform, `count` depends on values known only after apply

**Symptom.** `terraform validate` passed for `envs/aws-prod`, but planning it
against Floci failed:

```
Error: Invalid count argument
  on modules/observability/main.tf line 42, in resource "aws_cloudwatch_metric_alarm" "alb_5xx":
  42:   count = var.alb_arn_suffix == null ? 0 : 1
The "count" value depends on resource attributes that cannot be determined until apply
```

**Root cause.** The alarm module switched alarms on "if the ALB ARN is given".
In production the ARN comes from the ALB created in the same apply, so it is
unknown during plan, and `count` must be known at plan time.

**Fix.** Plain boolean switches (`enable_alb_alarms`, `enable_rds_alarms`,
`enable_ecs_alarms`) and `for_each` over fixed keys (`frontend`, `platform`).
This is the kind of error you only see with a real plan, which is why
`scripts/plan-prod-on-floci.sh` exists.

### Issue 5: ALB `access_logs` block with a null bucket

**Symptom.** Same plan run: `The argument "access_logs.0.bucket" is required`.

**Fix.** `dynamic "access_logs"` block that is only rendered when a bucket
name is passed.

### Issue 6: port 8080 already in use

`Bind for 0.0.0.0:8080 failed: port is already allocated`. Another project on
the laptop used 8080. Default frontend port moved to **8088**, and
`setup.sh` now checks the ports in `.env` before starting and says which
variable to change.

### Issue 7: S3 access denied on Floci for the production bucket

When the production stack was applied to Floci, reading bucket tags failed with
`AccessDenied`. The bucket policy denies requests without TLS
(`aws:SecureTransport = false`), Floci enforces bucket policies, and Floci's
endpoint is HTTP. Correct behaviour from the policy. `envs/floci-local` sets
`enforce_tls_bucket_policy = false` for this reason; production keeps it on.

### Issue 8: storefront showed no products after sample data import

GraphQL `products` returned `totalCount: 0` although the catalog had products.
The search index was empty: sample data import does not build the index.
`setup-platform.sh` now triggers a full index for Product, Category and Member
document types and waits for the job.

### Issue 9: default admin password worked again after deploy (security bug found by the tests)

**Symptom.** `deploy.sh` printed `default admin password replaced`, but
`validate.sh` then failed two checks: the password from `.env` was rejected
and `admin / store` was accepted again.

**Investigation.**
- Called the change password API by hand: HTTP 200 with
  `{"succeeded":true}`, and it worked. So the API call itself was fine.
- Looked at the users table:
  ```
  admin       | LastPasswordChangedDate 17:05:54 ...
  b2badmin    | created 17:06:09
  b2bagent    | created 17:06:09
  b2bemployee | created 17:06:09
  ```
  The password was changed at 17:05:54, and the sample data import created
  platform users at 17:06:09. The sample data package contains security data,
  and importing it put the admin password back to the default.
- Second problem: the script only checked the HTTP status, but this API
  answers 200 even when it refuses a password (`succeeded: false`).

**Fix.** In `setup-platform.sh` the password is changed **after** sample data
and indexing. The script reads `succeeded` from the response body, then
proves that `admin/store` is rejected and the new password works, and fails
the deploy otherwise. `validate.sh` keeps both checks so a regression shows up.

**Lesson.** A security control is only done when a test proves it. The deploy
log said "replaced"; only the independent check caught that it was not true.

### Issue 10: rollback used the wrong image tags

`FRONTEND_LOCAL_IMAGE=virto-frontend:2.59.1-r2 ./scripts/deploy.sh` deployed
`2.59.1` instead. `load_env` sources `.env` with `set -a`, which overwrote the
value given on the command line. Fix: `load_env` keeps image tags that are
already set in the environment. After the fix: release 2 deployed, recorded in
SSM, and `rollback.sh` went back to release 1 (`docs/evidence/rollback-test.txt`).

### Issue 11: crash drill did not crash anything

First version of the drill ran `docker exec platform kill -9 1`. Nothing
happened: PID 1 of a PID namespace ignores signals sent from inside the same
namespace. Second try `docker kill -s KILL`: the container stopped with exit
code 137 and stayed stopped, because Docker treats `docker kill` as a manual
stop and does not apply the restart policy. Final version kills the process
from the Docker host PID namespace (`docker run --pid=host alpine kill -9 <pid>`),
which looks like a real crash: Docker restarted the container (restart count
1 -> 2) and the platform was healthy again 14 s later.

### Issue 12: Floci plan never clean (SG rule drift)

After a successful apply, `terraform plan` on `envs/floci-local` still shows
`Plan: 0 to add, 9 to change, 0 to destroy.`. All changes are security group rules:

```
~ referenced_security_group_id = "000000000000/sg-b52cf75425b1a89bc" -> "sg-b52cf75425b1a89bc"
```

Floci returns the referenced group as `<account>/<sg-id>`, real AWS returns
`sg-id` (or `<account>/<sg-id>` only for cross account references). It is an
emulator difference, not a config error, so I did not add `ignore_changes`
for it: that would also hide real drift on AWS. Listed in floci.md limitations.

### Issue 13: first CI run on GitHub failed (2 jobs)

- `build`: `Unable to resolve action aquasecurity/trivy-action@0.28.0`. The tag
  format is `v0.x.y`. Fixed by pinning the action to the commit of `v0.36.0`
  (`ed142fd...`). A commit SHA can not be moved later, a tag can.
- `terraform` / tflint: (1) the Floci override file has no `required_version`
  (correct for an override file, ignored with a file level `tflint-ignore-file`
  comment), (2) `variable "shop_domain" is declared but not used` in the app
  module. That one was a real gap: the HTTPS listener sent **every** host name
  to the shop, including scanners hitting the ALB DNS name. Now `shop.*` has
  its own listener rule and the default action returns 404. The production
  plan went from 133 to 134 resources.

### Issue 14: CI security gate blocked the frontend image

Second CI run: `trivy scan frontend (gate)` failed.

```
virto-frontend:2.59.1 (alpine 3.24.2)   Total: 1 (CRITICAL: 1)
brotli-libs  CVE-2026-111497  CRITICAL  fixed  1.2.0-r1 -> 1.2.1-r0  Out-of-Bounds Write in Google Brotli Decoder
```

The base image `nginxinc/nginx-unprivileged:1.30.6-alpine` was published
before the Alpine fix. The gate did what it is there for. Fix: `apk upgrade
--no-cache` in the runtime stage (as root, then back to uid 101). Local Trivy
0.69.3 scan after the change: 0 CRITICAL. The platform scan stays report
only, its base image is Virto's.

### Issue 15: product images would be blocked on AWS (found in review)

**Symptom.** Found while reading the AWS config end to end, not in a run (the
AWS stack is not deployed). The platform builds image links from
`Assets__FileSystem__PublicUrl`, which on AWS is `https://<admin domain>/assets/`.
The ALB only lets office/VPN IPs reach the admin host and answers 403 to
everyone else, so shoppers would see the shop without product images.

**Why it did not show up locally.** Locally the asset URL is
`http://localhost:8090/assets/` and nothing restricts that port on the laptop.

**Fix.** New listener rule `public_files` (priority 5, before the admin rules):
admin host + path `/assets/*` or `/cms-content/*` goes to the platform from
any IP. The rest of the admin host is still IP restricted. Plan on Floci went
from 134 to 135 resources.

## Part 2: common errors

| Symptom | Check | Fix |
|---|---|---|
| `platform` stays `health: starting` for minutes | `docker compose logs -f platform` | First start runs migrations and, on Apple Silicon, runs under emulation. 2 to 5 minutes is normal. `start_period` is 600 s. |
| `platform` unhealthy | `curl -s localhost:8090/health \| jq` | The failing check is named: PostgreSql, Redis, Modules, Background jobs. |
| `password authentication failed for user "virto"` | `.env` was regenerated but the DB volume is older | `./scripts/teardown.sh --volumes` then deploy, or set the old password back in `.env`. |
| `Redis health Unhealthy` | `docker compose exec cache valkey-cli ping` | Password in `.env` must match the one the cache started with; `docker compose up -d cache`. |
| storefront 502 on `/graphql` | `docker compose logs frontend` | Platform not up yet. nginx re-resolves the name every 10 s, no restart needed. |
| storefront shows no store / no products | `make validate` | Run `./scripts/setup-platform.sh` (sample data + index). |
| login to admin fails with `store` | expected | The default password is replaced. Use `VC_ADMIN_PASSWORD` from `.env`. |
| `invalid_request ... HTTPS` from `/connect/token` | | `VirtoCommerce__AllowInsecureHttp=true` missing. |
| `.env not found` | | `./scripts/setup.sh` (or `--offline`). |
| AWS CLI goes to real AWS | `echo $AWS_ENDPOINT_URL` | Use the scripts or `export AWS_ENDPOINT_URL=http://localhost:4566`. |
| `Floci did not start` | `docker compose -f infra/floci/docker-compose.yml logs` | Port 4566 taken by LocalStack or another Floci. |
| Docker build slow at "downloaded VirtoCommerce..." | | 60 modules, about 300 MB. Cached after the first build. |
| `exec format error` | | Image built for the wrong architecture. Keep `platform: linux/amd64` for the platform. |
