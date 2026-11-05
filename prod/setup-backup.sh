#!/usr/bin/env bash
# One-time install of the restic backup kit on a PROD server. Run as root, interactively.
#   setup-backup.sh <backup-host-tag> [db-container-match]
#   e.g. setup-backup.sh acadgrowth-prod-db lkrnuawsehjn4gdhgy1z1y0t
# Expects the kit in /root/kit (backup.sh, restore-drill.sh, config/, systemd/).
# Secrets are typed at hidden prompts and land only in /etc/feymi-backup (root, 600).
set -euo pipefail

HOST_TAG="${1:?usage: setup-backup.sh <backup-host-tag> [db-container-match]}"
DB_MATCH="${2:-}"
KIT=/root/kit
CONF=/etc/feymi-backup
BUCKET=acadgrowth-backups-prod

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -f "$KIT/backup.sh" ] || { echo "kit not found in $KIT" >&2; exit 1; }

DEBIAN_FRONTEND=noninteractive apt-get -qq -y install restic >/dev/null
umask 077
mkdir -p /opt/feymi-backup "$CONF"
install -m 700 "$KIT/backup.sh" "$KIT/restore-drill.sh" /opt/feymi-backup/
install -m 600 "$KIT/config/excludes.txt" "$CONF/excludes.txt"
install -m 644 "$KIT"/systemd/feymi-backup-*.service "$KIT"/systemd/feymi-backup-*.timer /etc/systemd/system/

# restic encryption passwords: generated here, never typed, never leave the server except
# via the user copying them to the password manager.
for r in do r2; do
  [ -s "$CONF/restic-$r.key" ] || openssl rand -base64 48 | tr -d '\n' > "$CONF/restic-$r.key"
done

if [ ! -s "$CONF/common.env" ]; then
  cat > "$CONF/common.env" <<EOF
BACKUP_HOST=$HOST_TAG
DB_CONTAINER_MATCH=$DB_MATCH
DB_IMAGE=pgvector/pgvector:pg17
PG_USER=postgres
PG_DB=acadgrowth
# Healthchecks.io ping URLs (fill in later; empty = skip)
HC_DB=
HC_FILES=
HC_PRUNE=
HC_DRILL=
EOF
fi

ask() { local v; read -r -s -p "$1: " v; echo >&2; printf '%s' "$v"; }

if [ ! -s "$CONF/repo-do.env" ]; then
  echo "== DigitalOcean Spaces key (AcadGrowth PROD - backup DO Spaces key)"
  K=$(ask "DO access key"); S=$(ask "DO secret")
  cat > "$CONF/repo-do.env" <<EOF
RESTIC_REPOSITORY=s3:https://sgp1.digitaloceanspaces.com/$BUCKET/restic
RESTIC_PASSWORD_FILE=$CONF/restic-do.key
AWS_ACCESS_KEY_ID=$K
AWS_SECRET_ACCESS_KEY=$S
AWS_DEFAULT_REGION=us-east-1
EOF
fi

if [ ! -s "$CONF/repo-r2.env" ]; then
  echo "== Cloudflare R2 key (AcadGrowth PROD - backup R2 key)"
  A=$(ask "R2 account id (the part before .r2.cloudflarestorage.com)")
  K=$(ask "R2 access key id"); S=$(ask "R2 secret access key")
  cat > "$CONF/repo-r2.env" <<EOF
RESTIC_REPOSITORY=s3:https://$A.r2.cloudflarestorage.com/$BUCKET/restic
RESTIC_PASSWORD_FILE=$CONF/restic-r2.key
AWS_ACCESS_KEY_ID=$K
AWS_SECRET_ACCESS_KEY=$S
AWS_DEFAULT_REGION=auto
EOF
fi
chmod 600 "$CONF"/*

cat > /etc/logrotate.d/feymi-backup <<'EOF'
/var/log/feymi-backup.log {
  su root syslog
  weekly
  rotate 8
  compress
  missingok
  notifempty
}
EOF

# Create each repo once (a second server sharing the bucket reuses it).
for r in do r2; do
  ( set -a; source "$CONF/repo-$r.env"; set +a
    if restic cat config >/dev/null 2>&1; then echo "$r repo: exists"
    else restic init >/dev/null && echo "$r repo: created"; fi )
done

systemctl daemon-reload
echo "installed for $HOST_TAG. Timers are NOT enabled yet."
