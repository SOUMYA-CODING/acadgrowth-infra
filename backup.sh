#!/usr/bin/env bash
# Feymi encrypted backups (restic, AES-256). Runs on the Contabo host as root.
#   backup.sh db      -> Postgres dump (hourly)
#   backup.sh files   -> Coolify config + app volumes (nightly)
#   backup.sh prune   -> apply retention + integrity check (weekly)
# Every run goes to BOTH repos (DigitalOcean Spaces + Cloudflare R2) independently.
set -euo pipefail

MODE="${1:?usage: backup.sh db|files|prune}"
CONF_DIR=/etc/feymi-backup
source "$CONF_DIR/common.env"
BACKUP_HOST="${BACKUP_HOST:-feymi-dev}"   # restic --host tag; set per server in common.env

ping_hc() { # $1 = url, $2 = suffix ("" | /start | /fail)
  [ -n "${1:-}" ] && curl -fsS -m 10 --retry 3 -o /dev/null "$1$2" || true
}

case "$MODE" in
  db)    HC="$HC_DB" ;;
  files) HC="$HC_FILES" ;;
  prune) HC="$HC_PRUNE" ;;
  *) echo "unknown mode $MODE" >&2; exit 2 ;;
esac

ping_hc "$HC" /start
trap 'ping_hc "$HC" /fail' ERR

LOG=/var/log/feymi-backup.log
exec >>"$LOG" 2>&1
echo "=== $(date -Is) $MODE ==="

DB_CONTAINER=""
[ -n "${DB_CONTAINER_MATCH:-}" ] && DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -m1 "$DB_CONTAINER_MATCH")
[ "$MODE" = db ] && [ -z "$DB_CONTAINER" ] && { echo "no DB container on this server" >&2; exit 1; }

for REPO_ENV in "$CONF_DIR/repo-do.env" "$CONF_DIR/repo-r2.env"; do
  (
    set -euo pipefail
    source "$REPO_ENV"
    export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
    echo "--> $RESTIC_REPOSITORY"

    case "$MODE" in
      db)
        # Logical dump, custom format. Streamed straight into restic: never written to disk unencrypted.
        docker exec "$DB_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DB" -Fc -Z0 \
          | restic --retry-lock 30m backup --stdin --stdin-filename "$PG_DB.dump" --tag db --host "$BACKUP_HOST"
        docker exec "$DB_CONTAINER" pg_dumpall -U "$PG_USER" --globals-only \
          | restic --retry-lock 30m backup --stdin --stdin-filename globals.sql --tag db-globals --host "$BACKUP_HOST"
        ;;
      files)
        # Coolify's own database (projects, env vars, settings) - only on the Coolify server.
        docker ps --format '{{.Names}}' | grep -qx coolify-db && docker exec coolify-db pg_dump -U coolify -d coolify -Fc -Z0 \
          | restic --retry-lock 30m backup --stdin --stdin-filename coolify.dump --tag files --host "$BACKUP_HOST"
        # Extra small Postgres DBs of Coolify services (e.g. Infisical). EXTRA_PG_MATCH in
        # common.env = space-separated parts of container names; each is dumped with the
        # container's own POSTGRES_USER / POSTGRES_DB.
        for m in ${EXTRA_PG_MATCH:-}; do
          c=$(docker ps --format '{{.Names}}' | grep -m1 "$m") || { echo "no container for $m" >&2; false; }
          docker exec "$c" sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc -Z0' \
            | restic --retry-lock 30m backup --stdin --stdin-filename "$m.dump" --tag files --host "$BACKUP_HOST"
        done
        restic --retry-lock 30m backup --tag files --host "$BACKUP_HOST" \
          --exclude-file "$CONF_DIR/excludes.txt" \
          /data/coolify /var/lib/docker/volumes /etc/feymi-backup/common.env
        ;;
      prune)
        restic --retry-lock 30m forget --prune --tag db --host "$BACKUP_HOST" \
          --keep-hourly 48 --keep-daily 14 --keep-weekly 8 --keep-monthly 12
        restic --retry-lock 30m forget --prune --tag db-globals --host "$BACKUP_HOST" --keep-daily 14 --keep-monthly 12
        restic --retry-lock 30m forget --prune --tag files --host "$BACKUP_HOST" \
          --keep-daily 7 --keep-weekly 4 --keep-monthly 6
        # Re-download and verify 5% of the stored data each week.
        restic --retry-lock 30m check --read-data-subset=5%
        ;;
    esac
  )
done

echo "=== $(date -Is) $MODE OK ==="
ping_hc "$HC" ""
