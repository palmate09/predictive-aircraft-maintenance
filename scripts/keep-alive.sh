#!/usr/bin/env bash
# Health ping for the deployed stack.
#
# Originally a Render free-tier keep-alive: Render spins a free web service down after
# ~15 min without inbound traffic and the next visitor waits through a cold boot. That
# does not apply to the VPS deployment, so this is now a plain reachability check —
# useful as a manual smoke test from Actions, and usable directly as the URL target for
# an external monitor (UptimeRobot, Better Stack, cron-job.org) on a 5-minute interval.
#
# Usage:
#   bash scripts/keep-alive.sh https://fleet.example.com
#   FLEET_URL=https://fleet.example.com bash scripts/keep-alive.sh
#
# Exit 0 when the service answers (even "degraded" — that still means the
# process is up and serving). Exit non-zero only when it is unreachable, so a
# cron provider can alert on consecutive failures.
set -euo pipefail

BASE="${1:-${FLEET_URL:?pass the base URL as \$1 or set FLEET_URL}}"
BASE="${BASE%/}"
TIMEOUT="${KEEP_ALIVE_TIMEOUT:-45}"

echo "keep-alive: pinging ${BASE}/healthz (timeout ${TIMEOUT}s)"

code=$(curl -s -o /tmp/keep-alive.json -w "%{http_code}" \
  --max-time "$TIMEOUT" --retry 1 --retry-delay 5 \
  "${BASE}/healthz" || true)

if [ "$code" = "200" ]; then
  status=$(python3 -c "import json;print(json.load(open('/tmp/keep-alive.json')).get('status','?'))" 2>/dev/null || echo "?")
  echo "keep-alive: OK (HTTP 200, status=${status})"
  exit 0
fi

echo "keep-alive: MISS (HTTP ${code:-connection-failed}) — service may be cold-booting; next run in 5 min"
exit 1
