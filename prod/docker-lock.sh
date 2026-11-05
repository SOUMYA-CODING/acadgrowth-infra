#!/usr/bin/env bash
# Block Docker-published internal ports from the internet (IPv4 + IPv6).
# Docker's published ports skip INPUT and go through DOCKER-USER, so bootstrap.sh's
# firewall does not cover them. Private network (eth1) stays allowed.
# Run after Docker is installed, and again after any Docker reinstall.
set -euo pipefail

PUB_IF=eth0
PORTS="8000 6001 6002 8080"   # Coolify UI, realtime x2, Traefik dashboard

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

for t in iptables ip6tables; do
  if ! $t -S DOCKER-USER >/dev/null 2>&1; then
    echo "$t: no DOCKER-USER chain (Docker not using $t) - skipped"
    continue
  fi
  for p in $PORTS; do
    # ctorigdstport = the port the client asked for, before Docker's DNAT rewrites it
    $t -C DOCKER-USER -i "$PUB_IF" -p tcp -m conntrack --ctorigdstport "$p" -j DROP 2>/dev/null ||
      $t -I DOCKER-USER -i "$PUB_IF" -p tcp -m conntrack --ctorigdstport "$p" -j DROP
  done
  echo "$t: blocked $PORTS on $PUB_IF"
done

netfilter-persistent save >/dev/null
echo "saved"
