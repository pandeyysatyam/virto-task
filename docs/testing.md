# Testing

Task 6. Every test is a script that another engineer can run. Outputs from
my runs are in `docs/evidence/` (no passwords in them).

| # | What | Command | Evidence | Result |
|---|---|---|---|---|
| 1 | Platform and frontend startup | `./scripts/deploy.sh` | `deploy-first-run.txt` | all 4 containers healthy, platform healthy 21 s after start |
| 2 | Application access | browser + `validate.sh` | `storefront-home.png`, `admin-login.png` | shop and admin load |
| 3 | Platform to frontend communication | `validate.sh` (section "frontend to platform") | `validate-*.txt` | GraphQL through nginx returns the B2B store and 147 products; `/connect/token` reachable |
| 4 | Container health and logs | `docker compose ps`, `monitor.sh` | `validate-*.txt`, `monitor-run-*.txt` | healthy; logs shipped to CloudWatch (Floci) |
| 5 | Persistence after restart | `./scripts/test-persistence.sh` | `persistence-test.txt` | contact (DB), uploaded file (volume) and search index survive `docker compose down` + `up` |
| 6 | Deliberate failure + recovery | `./scripts/failure-drill.sh` | `failure-drill.txt` | DB outage: recovered 6 s after DB start, no restart. Process crash: restarted by Docker, healthy in 14 s |
| 7 | Backup and restore | `./scripts/test-backup-restore.sh` | `backup-restore-test.txt` | restore from S3 (Floci), data back to the backup point |
| 8 | Rollback | `deploy.sh` with a new tag, then `rollback.sh` | `rollback-test.txt` | back to release 1, history in SSM |
| 9 | Alerting | stop frontend, `monitor.sh` | `alarm-demo.txt` | alarm OK -> ALARM -> OK |
| 10 | Infrastructure | `terraform validate`, `plan-prod-on-floci.sh` | `floci-resources.txt`, `prod-stack-on-floci.txt` | floci-local applied; aws-prod plan 135 (133 at the time of the apply test), 123 created on Floci |
| 11 | Troubleshooting example | | `troubleshooting.md` issue 2 and 9 | root cause + fix documented |

## 1. Smoke tests: validate.sh

24 checks in 7 groups:

```
# containers                 db, cache, platform, frontend healthy
# platform                   /health all Healthy, admin login with .env password,
                             admin/store rejected, admin UI served
# frontend                   index.html, SPA fallback, security headers
# frontend to platform       store via GraphQL, product search, token endpoint
# network boundaries         db/cache not published, backend network internal,
                             frontend can not reach db, ports on 127.0.0.1 only
# containers run as non-root platform uid 1654, frontend uid 101 + read-only fs
# emulated AWS (Floci)       secret exists, bucket versioned, log groups exist
```

Exit code = number of failed checks, so it can gate CI.

The first run after the first deploy failed 4 checks. Two were bugs in the
test itself (`docker compose port` returns 0 even when nothing is published),
two were a real security bug: the admin password had gone back to the default
(troubleshooting issue 9). After the fixes: `passed: 24 failed: 0`.

## 2. Persistence

```
1. create contact "persist-<time>" through the REST API     -> PostgreSQL
2. upload persist-<time>.txt through the assets API          -> platform-assets volume
3. docker compose down (containers deleted, volumes kept), docker compose up -d
4. GET the contact by id, download the file, search products
```

Output: `[ OK ] PERSISTENCE TEST PASSED`.

## 3. Failure drills

**Database outage** (what users see):

| | /health | admin login | product search | shop page |
|---|---|---|---|---|
| before | 200 | ok | ok | 200 |
| db stopped | 503, PostgreSql Unhealthy | failed | ok (served from Lucene + cache) | 200 |
| db started | 200 after 6 s | ok | ok | 200 |

Interesting result: product browsing kept working during the outage because
search reads the index, but anything that writes or logs in failed. The
platform did not need a restart.

**Process crash**: SIGKILL from the host. Docker restart policy started the
container again (restart count 1 -> 2), healthy after 14 s; nginx reconnected
on its own because it re-resolves the platform name every 10 s.

## 4. Backup / restore

```
1. backup.sh --tag restore-test           -> local + s3://virto-local-backups-.../platform/backups/
2. create a contact after the backup, check it exists (GET by id, i.e. from the DB)
3. delete the local copy (restore must use S3)
4. restore.sh <name>: download, SHA256 check, recreate DB, pg_restore, refill volumes, reindex
5. the contact from step 2 is gone; the shop still lists 147 products
```

A first version of this test checked step 2 with the search API, which reads
the index, so it saw 0 contacts before and after and proved nothing. Changed
to a lookup by id.

## 5. Rollback

```
release 1: virto-frontend:2.59.1
release 2: virto-frontend:2.59.1-r2   (deploy.sh, pre-deploy backup taken, recorded in SSM)
rollback.sh -> frontend runs 2.59.1 again, .env updated, history kept
```

## 6. In CI

`.github/workflows/ci.yml` job `e2e` runs `setup.sh`, `deploy.sh --no-build`,
`validate.sh --save`, `test-persistence.sh` and `backup.sh` on a GitHub
runner (amd64, so no emulation) and uploads `docs/evidence` as an artifact.
The pipeline file is written and linted, but it has not run on GitHub yet
because the repository is not pushed.
