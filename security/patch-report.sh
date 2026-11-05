#!/usr/bin/env bash
# Read-only monthly patch report: what needs updating on this server.
# Changes nothing except pulling newer images into the local cache (running containers are untouched).
set -uo pipefail

hr() { printf '\n== %s ==\n' "$1"; }

hr "Ubuntu packages waiting"
apt-get -qq update 2>/dev/null
apt list --upgradable 2>/dev/null | grep -v '^Listing' | awk -F/ '{print "  " $1}' | head -40
[ -f /var/run/reboot-required ] && echo "  >> REBOOT REQUIRED (kernel/libc): $(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null)" || echo "  no reboot required"

hr "Docker engine"
echo "  installed: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
apt list --upgradable 2>/dev/null | grep -E '^(docker-ce|containerd)' | sed 's/^/  update: /' || true

hr "Coolify (pinned on purpose)"
echo "  running: $(docker inspect coolify --format '{{.Config.Image}}' 2>/dev/null)"
echo "  latest:  $(curl -fsS -m 10 https://cdn.coollabs.io/coolify/versions.json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["coolify"]["v4"]["version"])' 2>/dev/null || echo unknown)"
echo "  -> upgrade only after reading release notes, on dev first, after a fresh backup"

hr "Container images (newer image available?)"
for c in $(docker ps --format '{{.Names}}'); do
  img=$(docker inspect "$c" --format '{{.Config.Image}}')
  case "$img" in socralearn-backend*|coollabsio/*|ghcr.io/coollabsio/*) continue ;; esac
  running=$(docker inspect "$c" --format '{{.Image}}')
  docker pull -q "$img" >/dev/null 2>&1 || { echo "  ?  $img (pull failed)"; continue; }
  latest=$(docker image inspect "$img" --format '{{.Id}}' 2>/dev/null)
  if [ "$running" = "$latest" ]; then echo "  ok      $img"; else echo "  UPDATE  $img   (container: $c)"; fi
done | sort -u

hr "Postgres version"
docker exec "$(docker ps --format '{{.Names}}' | grep -m1 dwdxeo7cdv7qkjn6gvoo3i2w)" psql -U postgres -tAc 'select version()' 2>/dev/null | cut -c1-40 | sed 's/^/  /'

hr "Disk"
df -h / | tail -1 | awk '{print "  used " $5 " of " $2}'
docker system df --format '  {{.Type}}: {{.Size}} (reclaimable {{.Reclaimable}})' 2>/dev/null

echo
echo "Nothing was changed. Apply updates using infra-backup/PATCHING.md."
