#!/usr/bin/env bash
# Weekly proof that backups actually restore.
# Restores the latest DB dump from a repo into a throwaway Postgres (no network),
# runs sanity checks, then deletes everything.
#   restore-drill.sh            -> uses DigitalOcean repo
#   restore-drill.sh r2         -> uses Cloudflare R2 repo
set -euo pipefail

CONF_DIR=/etc/feymi-backup
source "$CONF_DIR/common.env"
WHICH="${1:-do}"
source "$CONF_DIR/repo-$WHICH.env"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

ping_hc() { [ -n "${HC_DRILL:-}" ] && curl -fsS -m 10 --retry 3 -o /dev/null "$HC_DRILL$1" || true; }
ping_hc /start

NAME="feymi-restore-drill-$$"
WORK=$(mktemp -d /root/drill.XXXX)
chmod 700 "$WORK"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap 'cleanup; ping_hc /fail' ERR
trap cleanup EXIT

exec >>/var/log/feymi-backup.log 2>&1
echo "=== $(date -Is) restore drill ($WHICH) ==="

restic dump --tag db latest "/$PG_DB.dump" > "$WORK/db.dump"
restic dump --tag db-globals latest /globals.sql > "$WORK/globals.sql"

docker run -d --name "$NAME" --network none \
  -e POSTGRES_PASSWORD=drill -e POSTGRES_USER="$PG_USER" -e POSTGRES_DB="$PG_DB" \
  -v "$WORK:/drill:ro" "$DB_IMAGE" >/dev/null

for i in $(seq 1 60); do
  docker exec "$NAME" pg_isready -U "$PG_USER" >/dev/null 2>&1 && break
  sleep 2
done

docker exec "$NAME" psql -U "$PG_USER" -d postgres -q -f /drill/globals.sql || true  # roles may already exist
docker exec "$NAME" pg_restore -U "$PG_USER" -d "$PG_DB" --no-owner --exit-on-error /drill/db.dump

TENANTS=$(docker exec "$NAME" psql -U "$PG_USER" -d "$PG_DB" -tAc "select count(*) from tenant")
SCHEMAS=$(docker exec "$NAME" psql -U "$PG_USER" -d "$PG_DB" -tAc \
  "select count(*) from information_schema.schemata where schema_name not in ('pg_catalog','information_schema','public') and schema_name not like 'pg_%'")
VECTOR=$(docker exec "$NAME" psql -U "$PG_USER" -d "$PG_DB" -tAc "select count(*) from pg_extension where extname='vector'")

echo "tenants=$TENANTS schemas=$SCHEMAS vector_ext=$VECTOR"
[ "$TENANTS" -ge 1 ] && [ "$SCHEMAS" -ge 1 ] && [ "$VECTOR" = 1 ]

echo "=== restore drill OK ==="
ping_hc ""
