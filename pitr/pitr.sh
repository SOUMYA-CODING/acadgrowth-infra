#!/usr/bin/env bash
# Point-in-time recovery for the Coolify Postgres, using only stock PostgreSQL tools
# in throwaway containers (the database container itself is never modified).
#   pitr.sh receive               -> stream WAL into $WAL_DIR (run by feymi-wal-receiver.service)
#   pitr.sh push                  -> encrypt + upload $WAL_DIR to both repos (every 5 min)
#   pitr.sh base                  -> nightly pg_basebackup to both repos + retention
#   pitr.sh drill [do|r2]         -> restore to "10 minutes ago" in a throwaway DB and check it
#   pitr.sh restore do|r2 'TIME'  -> same, to TIME (e.g. '2026-11-02 15:42:00+05:30'), and KEEP it
set -euo pipefail

MODE="${1:?usage: pitr.sh receive|push|base|drill|restore}"
CONF_DIR=/etc/feymi-backup
source "$CONF_DIR/common.env"
source "$CONF_DIR/repl.env"          # REPL_USER
BACKUP_HOST="${BACKUP_HOST:-feymi-dev}"   # restic --host tag; set per server in common.env
REPL_ENV_FILE="$CONF_DIR/repl.docker.env"   # PGPASSWORD=... (docker --env-file, chmod 600)
WAL_DIR=/var/lib/feymi-wal
NET=coolify
SLOT=feymi_wal
LOG=/var/log/feymi-backup.log

db_host() { docker ps --format '{{.Names}}' | grep -m1 "$DB_CONTAINER_MATCH"; }
ping_hc() { [ -n "${1:-}" ] && curl -fsS -m 10 --retry 3 -o /dev/null "$1$2" || true; }
in_repo() { # $1 = do|r2, rest = command
  local r="$1"; shift
  ( set -a; source "$CONF_DIR/repo-$r.env"; set +a; "$@" )
}

case "$MODE" in
  receive)
    mkdir -p "$WAL_DIR"; chmod 700 "$WAL_DIR"
    exec docker run --rm --name feymi-wal-receiver --network "$NET" --env-file "$REPL_ENV_FILE" \
      -v "$WAL_DIR:/wal" "$DB_IMAGE" \
      pg_receivewal -h "$(db_host)" -U "$REPL_USER" -D /wal -S "$SLOT" --synchronous -n
    ;;

  push)
    exec >>"$LOG" 2>&1
    ping_hc "${HC_WAL:-}" /start
    trap 'ping_hc "${HC_WAL:-}" /fail' ERR
    for r in do r2; do
      in_repo "$r" restic --retry-lock 10m backup --quiet --tag pitr-wal --host "$BACKUP_HOST" "$WAL_DIR"
    done
    # Keep 3 days locally; older segments live in the repos.
    find "$WAL_DIR" -type f ! -name '*.partial' -mmin +4320 -delete
    ping_hc "${HC_WAL:-}" ""
    ;;

  base)
    exec >>"$LOG" 2>&1
    echo "=== $(date -Is) pitr base ==="
    ping_hc "${HC_PITR_BASE:-}" /start
    trap 'ping_hc "${HC_PITR_BASE:-}" /fail; rm -f /root/pitr-base.tar' ERR
    umask 077
    docker run --rm --network "$NET" --env-file "$REPL_ENV_FILE" "$DB_IMAGE" \
      pg_basebackup -h "$(db_host)" -U "$REPL_USER" -D - -Ft -X fetch -c fast > /root/pitr-base.tar
    for r in do r2; do
      in_repo "$r" restic --retry-lock 30m backup --tag pitr-base --host "$BACKUP_HOST" --stdin --stdin-filename base.tar < /root/pitr-base.tar
      in_repo "$r" restic --retry-lock 30m forget --prune --tag pitr-base --host "$BACKUP_HOST" --keep-daily 8
      in_repo "$r" restic --retry-lock 30m forget --prune --tag pitr-wal  --host "$BACKUP_HOST" --keep-within 9d
    done
    shred -u /root/pitr-base.tar
    echo "=== $(date -Is) pitr base OK ==="
    ping_hc "${HC_PITR_BASE:-}" ""
    ;;

  drill|restore)
    REPO="${2:-do}"
    if [ "$MODE" = drill ]; then
      TARGET=$(date -d '10 minutes ago' '+%Y-%m-%d %H:%M:%S%:z'); KEEP=0
      exec >>"$LOG" 2>&1
      ping_hc "${HC_DRILL:-}" /start
    else
      TARGET="${3:?give a target time like '2026-11-02 15:42:00+05:30'}"; KEEP=1
    fi
    NAME="feymi-pitr-$MODE-$$"
    WORK=$(mktemp -d /root/pitr.XXXX); chmod 700 "$WORK"
    cleanup() { [ "$KEEP" = 1 ] && return; docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
    trap 'cleanup; [ "$MODE" = drill ] && ping_hc "${HC_DRILL:-}" /fail' ERR
    trap cleanup EXIT
    echo "=== $(date -Is) pitr $MODE ($REPO) target=$TARGET ==="

    # Newest base backup taken before the target.
    TARGET_EPOCH=$(date -d "$TARGET" +%s)
    BASE_ID=$(in_repo "$REPO" restic snapshots --json --tag pitr-base --host "$BACKUP_HOST" | python3 -c '
import json, sys, datetime
t = int(sys.argv[1])
snaps = [s for s in json.load(sys.stdin)
         if datetime.datetime.fromisoformat(s["time"][:26] + s["time"][-6:]).timestamp() <= t]
print(max(snaps, key=lambda s: s["time"])["short_id"] if snaps else "")' "$TARGET_EPOCH")
    [ -n "$BASE_ID" ] || { echo "no base backup before $TARGET"; false; }

    mkdir -p "$WORK/data" "$WORK/wal"
    in_repo "$REPO" restic dump "$BASE_ID" /base.tar | tar -x -C "$WORK/data"
    in_repo "$REPO" restic restore latest --tag pitr-wal --host "$BACKUP_HOST" --target "$WORK/walr" >/dev/null
    cp -a "$WORK/walr$WAL_DIR/." "$WORK/wal/"
    for f in "$WORK"/wal/*.partial; do [ -e "$f" ] && cp "$f" "${f%.partial}"; done
    rm -rf "$WORK/walr"

    cat >> "$WORK/data/postgresql.auto.conf" <<EOF
restore_command = 'cp /wal/%f %p'
recovery_target_time = '$TARGET'
recovery_target_action = 'promote'
EOF
    touch "$WORK/data/recovery.signal"
    chown -R 999:999 "$WORK/data" "$WORK/wal"; chmod 700 "$WORK/data"

    # PGDATA explicit: the pg18 image defaults to /var/lib/postgresql/18/docker and would
    # otherwise ignore this mount and start an empty cluster.
    docker run -d --name "$NAME" --network none -e PGDATA=/var/lib/postgresql/data \
      -v "$WORK/data:/var/lib/postgresql/data" -v "$WORK/wal:/wal:ro" "$DB_IMAGE" >/dev/null

    STATE=""
    for i in $(seq 1 90); do
      STATE=$(docker exec "$NAME" psql -U "$PG_USER" -d "$PG_DB" -tAc "select pg_is_in_recovery()" 2>/dev/null || true)
      [ "$STATE" = f ] && break
      docker ps -q -f name="$NAME" | grep -q . || { docker logs --tail 20 "$NAME"; false; }
      sleep 5
    done
    [ "$STATE" = f ] || { docker logs --tail 20 "$NAME"; false; }

    docker logs "$NAME" 2>&1 | grep -E "recovery stopping|archive recovery complete|reached target" | tail -2
    TENANTS=$(docker exec "$NAME" psql -U "$PG_USER" -d "$PG_DB" -tAc "select count(*) from tenant")
    echo "base=$BASE_ID tenants=$TENANTS"
    [ "$TENANTS" -ge 1 ]

    if [ "$MODE" = drill ]; then
      echo "=== pitr drill OK ==="; ping_hc "${HC_DRILL:-}" ""
    else
      echo "Restored copy is running in container $NAME (data in $WORK). Inspect it, then remove with:"
      echo "  docker rm -f $NAME && rm -rf $WORK"
    fi
    ;;

  *) echo "unknown mode $MODE" >&2; exit 2 ;;
esac
