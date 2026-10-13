#!/usr/bin/env bash
# Keep-alive ping for the Render free-tier deployment.
#
# Render spins a free web service down after ~15 min without inbound traffic;
# the next visitor then waits through a full cold boot (npm build artifacts are
# cached, but `alembic upgrade head` + model load + seed check still take 30-90s).
# Hitting /healthz every 5 min keeps at least one instance warm so real users
# never pay the cold-start cost.
#
# Usage:
#   FLEET_URL=https://fleet-digital-twin.onrender.com bash scripts/keep-alive.sh
#   bash scripts/keep-alive.sh https://fleet-digital-twin.onrender.com
#
# Exit 0 when the service answers (even "degraded" — that still means the
# process is up and serving). Exit non-zero only when it is unreachable, so a
# cron provider can alert on consecutive failures.
set -euo pipefail

BASE="${1:-${FLEET_URL:-https://fleet-digital-twin.onrender.com}}"
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
