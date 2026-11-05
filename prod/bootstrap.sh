#!/usr/bin/env bash
# AcadGrowth prod server hardening. Run as root on a fresh Ubuntu 24.04 server.
#   bootstrap.sh apply <hostname>   packages + SSH key-only + firewall (auto-undo in 10 min)
#   bootstrap.sh confirm            keep the firewall (cancel the auto-undo, save rules)
#   bootstrap.sh undo               open the firewall again right now
# Firewall: public = SSH only; private network 10.0.0.0/22 on eth1 = everything.
set -euo pipefail

PRIV_NET=10.0.0.0/22
PRIV_IF=eth1
STATE=/root/fw-before

die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"

fw_undo() {
  for t in iptables ip6tables; do
    $t -P INPUT ACCEPT
    $t -F INPUT
  done
  echo "firewall opened (INPUT ACCEPT)"
}

case "${1:-}" in
apply)
  host="${2:-}"; [ -n "$host" ] || die "usage: bootstrap.sh apply <hostname>"
  # Never lock root out: a key must already be installed.
  [ -s /root/.ssh/authorized_keys ] || die "no SSH key in /root/.ssh/authorized_keys - run ssh-copy-id first"
  ip -br addr show "$PRIV_IF" | grep -q '10\.0\.0\.' || die "$PRIV_IF has no 10.0.0.x address"

  hostnamectl set-hostname "$host"

  echo "== packages"
  export DEBIAN_FRONTEND=noninteractive
  echo iptables-persistent iptables-persistent/autosave_v4 boolean false | debconf-set-selections
  echo iptables-persistent iptables-persistent/autosave_v6 boolean false | debconf-set-selections
  apt-get -qq update
  apt-get -qq -y upgrade
  apt-get -qq -y install unattended-upgrades fail2ban iptables-persistent ipset curl ca-certificates
  dpkg-reconfigure -f noninteractive unattended-upgrades
  systemctl enable --now fail2ban

  echo "== journald limits"
  mkdir -p /etc/systemd/journald.conf.d
  printf '[Journal]\nSystemMaxUse=500M\nMaxRetentionSec=1month\n' > /etc/systemd/journald.conf.d/limits.conf
  systemctl restart systemd-journald

  echo "== SSH key-only"
  # 00- sorts before Ubuntu's 50-cloud-init.conf; first value wins in sshd.
  cat > /etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 3
X11Forwarding no
EOF
  sshd -t
  systemctl reload ssh

  echo "== firewall (auto-undo in 10 min unless confirmed)"
  iptables-save > "$STATE.v4"; ip6tables-save > "$STATE.v6"
  systemctl stop fw-undo.timer 2>/dev/null || true
  systemd-run --quiet --unit=fw-undo --on-active=10min "$(readlink -f "$0")" undo
  for t in iptables ip6tables; do
    $t -F INPUT
    $t -A INPUT -i lo -j ACCEPT
    $t -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    $t -A INPUT -m conntrack --ctstate INVALID -j DROP
    $t -A INPUT -p tcp --dport 22 -j ACCEPT
  done
  iptables  -A INPUT -p icmp -j ACCEPT
  ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
  iptables  -A INPUT -i "$PRIV_IF" -s "$PRIV_NET" -j ACCEPT
  iptables  -P INPUT DROP
  ip6tables -P INPUT DROP

  echo
  echo "DONE on $host. Now open a NEW terminal on your Mac and log in again."
  echo "If that works, run here:  $(readlink -f "$0") confirm"
  echo "If you do nothing, the firewall opens again by itself in 10 minutes."
  ;;
confirm)
  systemctl stop fw-undo.timer 2>/dev/null || true
  netfilter-persistent save >/dev/null
  echo "firewall kept and saved (survives reboot)"
  ;;
undo)
  fw_undo
  ;;
*)
  die "usage: bootstrap.sh apply <hostname> | confirm | undo"
  ;;
esac
