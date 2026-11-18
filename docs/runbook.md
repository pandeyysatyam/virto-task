# Deployment runbook

Step by step procedures for the local environment. For AWS see
[aws-deployment.md](aws-deployment.md) section 4 and 5.

Every step lists the command and what you should see. If you see something
else, go to [troubleshooting.md](troubleshooting.md).

## 0. Before you start

```bash
docker info >/dev/null && echo docker ok
docker compose version
terraform version
aws --version
```

Ports 8088, 8090 and 4566 must be free (`lsof -nP -iTCP:8088 -sTCP:LISTEN`
prints nothing). If a port is busy, change it in `.env` after step 1.

## 1. First time setup

```bash
./scripts/setup.sh
```

Expected end of output:

```
[ OK ] Floci already running on http://localhost:4566     (or: Floci ready after 5s)
[ OK ] AWS CLI talks to Floci (account 000000000000)
[ OK ] Floci resources ready: 83 in state
[ OK ] .env written (mode 600). Passwords come from Secrets Manager on Floci
```

## 2. Deploy

```bash
./scripts/deploy.sh
```

What it does, in order:
1. if the stack is already running: `backup.sh --tag pre-deploy`
2. `docker compose build` (first time about 5 to 10 minutes)
3. `docker compose up -d`, waits for db, cache, platform, frontend to be healthy
4. `setup-platform.sh`: sample data, search index, admin password
5. records the release in `.releases` and in SSM `/virto/local/releases/NNNN`

Expected end of output:

```
[ OK ] all containers healthy
[ OK ] sample data imported
[ OK ] search index built
[ OK ] default admin password replaced and verified
[ OK ] release 1 recorded in SSM Parameter Store (Floci)
[ OK ] Storefront:   http://localhost:8088
```

Options: `--no-build` (use existing images), `--skip-sample-data`.

## 3. Verify

```bash
./scripts/validate.sh            # expect: passed: 24  failed: 0
./scripts/validate.sh --save     # same, and keeps a copy in docs/evidence/
```

Manual check: open http://localhost:8088, the B2B store with categories
(Bolts, Snacks, Soft Drinks ...) appears. Open http://localhost:8090 and log
in as `admin` with `VC_ADMIN_PASSWORD` from `.env`.

## 4. Stop and start

| Goal | Command | Data |
|---|---|---|
| pause everything | `docker compose stop` | kept |
| resume | `docker compose start` | kept |
| remove containers | `docker compose down` or `./scripts/teardown.sh` | kept (volumes) |
| start again after down | `./scripts/deploy.sh --no-build` | kept |
| restart only the platform | `docker compose restart platform` | kept |

## 5. Upgrade to a new version

1. Change the version:
   - platform/modules: replace `docker/platform/modules.json` with the new
     bundle, run `python3 scripts/gen-modules-lock.py docker/platform/modules.json > docker/platform/modules.lock`,
     update `PLATFORM_IMAGE` and `PLATFORM_LOCAL_IMAGE` in `.env` and `.env.example`
   - frontend: update `FRONTEND_VERSION`, `FRONTEND_SHA256` (Dockerfile) and
     `FRONTEND_LOCAL_IMAGE`
2. `./scripts/deploy.sh` (takes a pre-deploy backup automatically)
3. `./scripts/validate.sh`
4. If something is wrong: section 6.

## 6. Roll back

```bash
./scripts/rollback.sh --list     # release history
./scripts/rollback.sh            # previous images, no rebuild
./scripts/validate.sh
```

If the bad version changed the database schema (check the platform log for
"Applying migration"), the old version may not start on the new schema. Then:

```bash
./scripts/rollback.sh --restore-db   # previous images + the latest pre-deploy backup
```

## 7. Backup and restore

```bash
./scripts/backup.sh                       # manual backup, uploaded to S3 on Floci
./scripts/restore.sh --list
./scripts/restore.sh 20261118-171225-demo # or no argument for the latest
```

Restore stops the platform and frontend, recreates the database, refills the
volumes, starts again and rebuilds the search index. Downtime about 1 minute
for the sample data size.

## 8. Monitoring

```bash
./scripts/monitor.sh --watch     # every 60 s: health metric + logs to CloudWatch (Floci)
```

Check the alarm:

```bash
export AWS_ENDPOINT_URL=http://localhost:4566 AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_REGION=us-east-1
aws cloudwatch describe-alarms --query 'MetricAlarms[].[AlarmName,StateValue]' --output text
aws cloudwatch describe-alarm-history --alarm-name virto-local-unhealthy-services --output text
```

## 9. Incident checklist

1. `docker compose ps`: which container is not healthy?
2. `curl -s localhost:8090/health | python3 -m json.tool`: which check fails?
3. `docker compose logs --tail 200 <service>`
4. Database down? `docker compose start db`. The platform reconnects by itself
   (tested, about 6 s).
5. Platform crashed? `restart: unless-stopped` brings it back (tested, about
   14 s). If it keeps crashing, look for the first `ERR` / `FTL` line in the log.
6. Still broken after a deploy? Roll back (section 6).
7. Data lost or damaged? Restore (section 7).
8. Write down what happened in `docs/troubleshooting.md`.

## 10. Cleanup

See README section 14.
