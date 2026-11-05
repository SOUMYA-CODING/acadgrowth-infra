#!/usr/bin/env bash
# One-time PITR setup on the PROD db server (after setup-backup.sh). Run as root.
# Creates the replication role + slot inside Postgres, installs pitr.sh and its units.
# Expects the kit in /root/kit (pitr/ folder). The weekly PITR drill is NOT enabled here.
set -euo pipefail

CONF=/etc/feymi-backup
REPL_USER=acadgrowth_repl
SLOT=feymi_wal
source "$CONF/common.env"
DB=$(docker ps --format '{{.Names}}' | grep -m1 "$DB_CONTAINER_MATCH")
[ -n "$DB" ] || { echo "db container not found" >&2; exit 1; }

umask 077
# Replication password: generated here, used only by the throwaway pg_receivewal/basebackup containers.
if [ ! -s "$CONF/repl.docker.env" ]; then
  echo "PGPASSWORD=$(openssl rand -base64 33 | tr -d '/+=\n')" > "$CONF/repl.docker.env"
fi
echo "REPL_USER=$REPL_USER" > "$CONF/repl.env"
PW=$(sed -n 's/^PGPASSWORD=//p' "$CONF/repl.docker.env")

docker exec -i "$DB" psql -U postgres -v ON_ERROR_STOP=1 -v pw="$PW" -q <<'SQL'
SELECT format('CREATE ROLE acadgrowth_repl LOGIN REPLICATION PASSWORD %L', :'pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'acadgrowth_repl') \gexec
ALTER ROLE acadgrowth_repl PASSWORD :'pw';
SELECT pg_create_physical_replication_slot('feymi_wal')
WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'feymi_wal');
ALTER SYSTEM SET max_slot_wal_keep_size = '4GB';
SQL

# Allow replication logins only from the Docker network on this host (samenet), never from outside.
docker exec "$DB" sh -c 'f=$PGDATA/pg_hba.conf; grep -q "^host replication acadgrowth_repl samenet" $f ||
  echo "host replication acadgrowth_repl samenet scram-sha-256" >> $f'
docker exec "$DB" psql -U postgres -qtAc "select pg_reload_conf()" >/dev/null

install -m 700 /root/kit/pitr/pitr.sh /opt/feymi-backup/pitr.sh
install -m 644 /root/kit/pitr/feymi-wal-receiver.service /root/kit/pitr/feymi-pitr-*.service \
  /root/kit/pitr/feymi-pitr-*.timer /etc/systemd/system/
chmod 600 "$CONF"/*
systemctl daemon-reload
echo "pitr installed (role $REPL_USER, slot $SLOT). Next: start the receiver."
