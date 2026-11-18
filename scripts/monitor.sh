#!/usr/bin/env bash
# Local stand-in for CloudWatch agent + Container Insights.
#
# Every run:
#   - counts unhealthy containers and publishes it as the custom metric
#     Virto/virto-local UnhealthyServices to CloudWatch on Floci
#   - ships the last minute of platform and frontend logs to the CloudWatch
#     log groups /virto-local/platform and /virto-local/frontend
#   - prints the state of the alarm virto-local-unhealthy-services
#
# Usage: ./scripts/monitor.sh            one run
#        ./scripts/monitor.sh --watch    every 60 seconds until Ctrl+C

source "$(dirname "$0")/lib.sh"
load_env
floci_env
floci_up || die "Floci is not running"

NS="Virto/virto-local"
ALARM="virto-local-unhealthy-services"

ship_logs() {
  local svc="$1" group="/virto-local/$1" stream
  stream="$svc/$(date -u +%Y/%m/%d)"
  aws logs create-log-stream --log-group-name "$group" --log-stream-name "$stream" 2>/dev/null || true
  docker compose logs --no-color --no-log-prefix --since 60s "$svc" 2>/dev/null | tail -n 200 \
    | python3 -c '
import json,sys,time
now=int(time.time()*1000)
ev=[{"timestamp":now,"message":l.rstrip("\n")[:4000]} for l in sys.stdin if l.strip()]
print(json.dumps(ev))' > /tmp/virto-events.json
  if [[ "$(cat /tmp/virto-events.json)" != "[]" ]]; then
    aws logs put-log-events --log-group-name "$group" --log-stream-name "$stream" \
      --log-events file:///tmp/virto-events.json >/dev/null
    log "shipped $(python3 -c 'import json;print(len(json.load(open("/tmp/virto-events.json"))))' ) $svc log lines to $group"
  fi
  rm -f /tmp/virto-events.json
}

run_once() {
  local unhealthy=0 svc
  for svc in db cache platform frontend; do
    if ! is_healthy "$svc"; then
      unhealthy=$((unhealthy + 1))
      warn "$svc is $(service_health "$svc")"
    fi
  done
  aws cloudwatch put-metric-data --namespace "$NS" --metric-name UnhealthyServices \
    --value "$unhealthy" --unit Count
  log "published UnhealthyServices=$unhealthy to $NS"
  ship_logs platform
  ship_logs frontend
  log "alarm $ALARM: $(aws cloudwatch describe-alarms --alarm-names "$ALARM" --query 'MetricAlarms[0].StateValue' --output text)"
}

if [[ "${1:-}" == "--watch" ]]; then
  while true; do run_once; sleep 60; done
else
  run_once
fi
