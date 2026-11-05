#!/usr/bin/env bash
# Only Cloudflare may reach the web ports (80/443) that Docker publishes for Traefik.
# Docker-published ports bypass INPUT, so the rules live in DOCKER-USER (IPv4 + IPv6).
#   cf-origin-lock.sh apply    -> refresh Cloudflare IP sets + add rules + arm a 10-min auto-undo (NOT saved)
#   cf-origin-lock.sh confirm  -> cancel the auto-undo and save rules + sets (survive reboot)
#   cf-origin-lock.sh refresh  -> refresh the Cloudflare IP sets only (weekly timer)
#   cf-origin-lock.sh undo     -> remove the rules
set -euo pipefail

IFACE=eth0
MODE="${1:?usage: cf-origin-lock.sh apply|confirm|refresh|undo}"

load_set() { # $1 = set name, $2 = family, $3 = url, $4 = minimum entries
  local tmp="$1-new" list
  list=$(curl -fsS --retry 3 -m 20 "$3")
  [ "$(printf '%s\n' "$list" | grep -c .)" -ge "$4" ] || { echo "Cloudflare list $3 looks wrong; aborting" >&2; exit 1; }
  ipset create -exist "$1" hash:net family "$2"
  ipset create -exist "$tmp" hash:net family "$2"
  ipset flush "$tmp"
  printf '%s\n' "$list" | while read -r net; do [ -n "$net" ] && ipset add "$tmp" "$net"; done
  ipset swap "$tmp" "$1"
  ipset destroy "$tmp"
}

rules() { # $1 = -C | -I | -D
  local op="$1"
  for spec in "iptables cf4" "ip6tables cf6"; do
    set -- $spec
    for proto_port in "tcp 80" "tcp 443" "udp 443"; do
      set -- $spec $proto_port
      local args=(DOCKER-USER -i "$IFACE" -p "$3" -m conntrack --ctorigdstport "$4" --ctdir ORIGINAL -m set ! --match-set "$2" src -j DROP)
      case "$op" in
        -I) "$1" -C "${args[@]}" 2>/dev/null || "$1" -I "${args[@]}" ;;
        -D) while "$1" -C "${args[@]}" 2>/dev/null; do "$1" -D "${args[@]}"; done ;;
      esac
    done
  done
}

case "$MODE" in
  refresh)
    load_set cf4 inet  https://www.cloudflare.com/ips-v4 10
    load_set cf6 inet6 https://www.cloudflare.com/ips-v6 5
    ;;
  apply)
    load_set cf4 inet  https://www.cloudflare.com/ips-v4 10
    load_set cf6 inet6 https://www.cloudflare.com/ips-v6 5
    systemd-run --quiet --unit=cf-lock-undo --on-active=10min /usr/local/sbin/cf-origin-lock.sh undo
    rules -I
    echo "Applied. Auto-undo in 10 minutes unless you run: cf-origin-lock.sh confirm"
    ;;
  confirm)
    systemctl stop cf-lock-undo.timer 2>/dev/null || true
    netfilter-persistent save
    echo "Confirmed and saved."
    ;;
  undo)
    rules -D
    echo "Rules removed (not saved state unchanged)."
    ;;
  *) echo "unknown mode $MODE" >&2; exit 2 ;;
esac
