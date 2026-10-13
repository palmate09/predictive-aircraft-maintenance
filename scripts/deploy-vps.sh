#!/usr/bin/env bash
# Deploy the current checkout to the VPS Docker stack.
#
# Intended to be driven by .github/workflows/deploy.yml over SSH, but it is a plain
# script with no GitHub coupling: run it by hand on the VPS to reproduce a deploy, or
# to recover when Actions is the thing that is broken.
#
#   ./scripts/deploy-vps.sh                 # backup -> build -> up -> health gate
#   ./scripts/deploy-vps.sh --skip-backup   # skip the pg_dump (fast re-deploys)
#   ./scripts/deploy-vps.sh --prune         # also drop dangling images and build cache
#
# The caller is responsible for `git pull` before invoking this, so the version of this
# script that runs is always the one being deployed. Reverting is `git revert <sha>` +
# re-run; the database is migrated forward by the API on boot, never down.
#
# Exit codes: 0 deployed and healthy · 1 preflight failed · 2 build/up failed ·
#             3 health gate timed out (stack is up but not serving).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

COMPOSE_FILES=(-f docker-compose.yml -f docker-compose.prod.yml)
BACKUP_DIR="backend/backups"
KEEP_BACKUPS=3
HEALTH_TIMEOUT="${DEPLOY_HEALTH_TIMEOUT:-240}"

SKIP_BACKUP=0
PRUNE=0
for arg in "$@"; do
  case "$arg" in
    --skip-backup) SKIP_BACKUP=1 ;;
    --prune)       PRUNE=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mXX  %s\033[0m\n' "$*" >&2; }

# ── preflight ─────────────────────────────────────────────────────────────────
# Everything that silently degrades the running app is checked here rather than
# discovered in the browser: a missing .env boots with dev defaults, and a repo whose
# tracked data files are missing replays an empty fleet.
step "Preflight"

[ -f .env ] || { fail ".env not found — it is gitignored; copy .env.example and set it"; exit 1; }
for f in backend/data/cmapss/train_FD001.txt backend/data/ml/all/xgboost_all_full.json; do
  [ -f "$f" ] || { fail "missing tracked data file: $f"; exit 1; }
done
command -v docker >/dev/null || { fail "docker not on PATH"; exit 1; }
docker compose version >/dev/null 2>&1 || { fail "docker compose v2+ required"; exit 1; }
docker info >/dev/null 2>&1 || { fail "cannot talk to the docker daemon — is the user in the docker group?"; exit 1; }
git remote get-url ci >/dev/null 2>&1 || {
  fail "the 'ci' remote (read-only deploy key) is missing — add it with:"
  echo "    git remote add ci git@github.com-fdt:palmate09/predictive-aircraft-maintenance.git" >&2
  exit 1
}

# A dirty tree means `git pull` silently did nothing or merged something unexpected.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  fail "tracked files are modified on the VPS; commit or stash before deploying"
  git --no-pager status --short
  exit 1
fi

echo "    commit  $(git rev-parse --short HEAD)  ($(git rev-parse --abbrev-ref HEAD))"
echo "    free    $(df -h --output=avail "$REPO_ROOT" | tail -1 | tr -d ' ')"

if [ "$PRUNE" -eq 1 ]; then
  step "Pruning dangling images and build cache"
  docker image prune -f
  docker builder prune -f --filter until=168h
fi

# ── database backup ──────────────────────────────────────────────────────────
# Compose may recreate the db container and run migrations on boot; a dump taken
# beforehand is the only thing that makes a bad migration reversible.
if [ "$SKIP_BACKUP" -eq 0 ]; then
  step "Backing up PostgreSQL"
  if docker compose "${COMPOSE_FILES[@]}" ps --status running --services | grep -qx db; then
    mkdir -p "$BACKUP_DIR"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    out="${BACKUP_DIR}/fdt-${stamp}.sql.gz"
    set +e
    # shellcheck disable=SC2086
    docker compose "${COMPOSE_FILES[@]}" exec -T db \
      pg_dump -U "${POSTGRES_USER:-fdt}" "${POSTGRES_DB:-fdt}" 2>/dev/null | gzip > "$out"
    status=${PIPESTATUS[0]}
    set -e
    if [ "$status" -eq 0 ] && [ -s "$out" ]; then
      echo "    wrote $out ($(du -h "$out" | cut -f1))"
      # Never let backups outgrow the 49 GB root volume.
      ls -1t "${BACKUP_DIR}"/fdt-*.sql.gz | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f
    else
      rm -f "$out"
      warn "pg_dump failed (exit ${status}) — continuing without a backup"
    fi
  else
    warn "db is not running — skipping backup (first deploy)"
  fi
else
  step "Skipping backup (--skip-backup)"
fi

# ── build and start ──────────────────────────────────────────────────────────
# Only `web` publishes a port in the prod override; api and db stay on the compose
# network. Migrations are applied by the API on startup (backend/app/main.py), so
# there is deliberately no separate migrate step to race against it.
step "Building images and starting the stack"
docker compose "${COMPOSE_FILES[@]}" up -d --build --remove-orphans
docker compose "${COMPOSE_FILES[@]}" ps

# ── health gate ──────────────────────────────────────────────────────────────
# /healthz is nginx proxying the API's own check, so a 200 proves nginx, the API and
# its database are all reachable — serving static files would not catch a dead db.
step "Health gate (timeout ${HEALTH_TIMEOUT}s)"
WEB_PORT="$(grep -E '^WEB_PORT=' .env | cut -d= -f2- || true)"
WEB_PORT="${WEB_PORT:-8080}"
URL="http://127.0.0.1:${WEB_PORT}/healthz"

for i in $(seq 1 $((HEALTH_TIMEOUT / 5))); do
  code="$(curl -s -o /tmp/fdt-health.json -w '%{http_code}' --max-time 5 "$URL" || true)"
  if [ "$code" = "200" ]; then
    echo "    healthy after $((i * 5))s"
    cat /tmp/fdt-health.json; echo
    step "Deploy complete"
    exit 0
  fi
  # surface the reason early rather than making the operator read container logs
  unhealthy="$(docker compose "${COMPOSE_FILES[@]}" ps --format '{{.Service}}:{{.Health}}' \
    | grep -v ':healthy$' | tr '\n' ' ' || true)"
  printf '    %3ss  HTTP %s  %s\n' "$((i * 5))" "${code:-000}" "$unhealthy"
  sleep 5
done

fail "not healthy after ${HEALTH_TIMEOUT}s — last 60 log lines:"
docker compose "${COMPOSE_FILES[@]}" logs --tail=60 web api >&2
exit 3