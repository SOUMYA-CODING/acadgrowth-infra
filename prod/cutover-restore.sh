#!/usr/bin/env bash
# CUTOVER: copy the live DigitalOcean database into Contabo prod (fresh `acadgrowth` db).
# Run from your Mac (needs SSH to DO 168.144.146.248, db .54, workers .53).
# Refuses to run unless: Contabo workers/beat are stopped AND DO web/worker/beat are stopped.
# Same pipeline as the 2026-11-05 test restore (79 s for 373 MB).
set -euo pipefail

DO=root@168.144.146.248
DB=root@13.140.253.54
WK=root@13.140.253.53
N=zlsebm2uo75tyjixt58rfvtq          # Contabo Postgres 18 container
IMG=pgvector/pgvector:pg18
SSH="ssh -o BatchMode=yes"

echo "== safety checks"
if $SSH $WK 'docker ps --format "{{.Names}}" | grep -qE "^(worker|beat)-"'; then
  echo "ABORT: Contabo worker/beat are RUNNING. Stop the workers app in Coolify first."; exit 1
fi
echo "ok: Contabo worker + beat stopped"
if $SSH $DO 'systemctl is-active --quiet socralearn-web || systemctl is-active --quiet socralearn-worker || systemctl is-active --quiet socralearn-beat'; then
  echo "ABORT: a DigitalOcean service is still running (web/worker/beat). Stop them first."; exit 1
fi
echo "ok: DigitalOcean web + worker + beat stopped"

echo "== dump DO -> restore Contabo"
$SSH $DO 'grep "^DATABASE_URL=" /var/www/socralearn/.env | cut -d= -f2- | tr -d "\"'"'"'" | sed "s#@private-#@#"' \
| $SSH $DB "set -o pipefail; read -r U; N=$N; IMG=$IMG; umask 077"'
docker exec -i $N psql -U postgres -q -v ON_ERROR_STOP=1 <<SQL
DROP DATABASE IF EXISTS acadgrowth WITH (FORCE);
CREATE DATABASE acadgrowth OWNER acadgrowth_app;
REVOKE ALL ON DATABASE acadgrowth FROM PUBLIC;
GRANT CONNECT, CREATE, TEMP ON DATABASE acadgrowth TO acadgrowth_app;
\c acadgrowth
CREATE EXTENSION IF NOT EXISTS vector;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
ALTER SCHEMA public OWNER TO acadgrowth_app;
SQL
echo "fresh acadgrowth db ready"; S=$(date +%s)
docker run --rm -e U="$U" $IMG sh -c "pg_dump \"\$U\" -Fc -Z0 --no-owner --no-privileges" \
  | docker exec -i $N pg_restore -U postgres -d acadgrowth --no-owner --no-privileges --role=acadgrowth_app 2>/root/restore-errors.log || true
E=$(date +%s)
echo "restore took $((E-S))s; error lines: $(grep -c "error:" /root/restore-errors.log || true) (1 = COMMENT ON EXTENSION vector, harmless)"
grep "error:" /root/restore-errors.log | cut -c1-160 | sort | uniq -c | head -8 || true
Q="select (select count(*) from tenant) || chr(32) || (select count(*) from information_schema.schemata where schema_name not like \$\$pg\\_%\$\$ and schema_name <> \$\$information_schema\$\$) || chr(32) || (select count(*) from information_schema.tables where table_schema not in (\$\$pg_catalog\$\$, \$\$information_schema\$\$))"
A=$(docker run --rm -e U="$U" $IMG psql "$U" -tAc "$Q" | tail -1)
B=$(docker exec $N psql -U postgres -d acadgrowth -tAc "$Q" | tail -1)
echo "tenants schemas tables"
echo "DO      : $A"
echo "Contabo : $B"
[ "$A" = "$B" ] && echo "MATCH - restore OK" || { echo "MISMATCH - do NOT switch DNS, tell Claude"; exit 1; }
'
