# Feymi — Patching Guide

**When:** first Tuesday of every month (dev), then the same items on production 2–3 days later.
**Emergency:** a critical CVE in Postgres, OpenSSL, Docker, Traefik or Coolify gets patched within 48 hours, **on dev first**.

Rule: **dev first → wait a day → production.** Always take a fresh backup before patching.

---

## 1. What patches itself vs what you patch

| Component | How it's updated |
|---|---|
| Ubuntu security packages | ✅ Automatic daily (unattended-upgrades) |
| Linux kernel | Installed automatically, **active only after a reboot** (monthly) |
| Backend base image (python:3.12-slim) | ✅ Every deploy pulls the latest Debian fixes |
| Docker engine | Manual, monthly. **Restarts every container** |
| Coolify | Manual, deliberate (it's pinned; 4.4.5 once broke the panel) |
| Postgres / Redis / PgBouncer / Uptime Kuma / Beszel images | Manual, monthly |
| Python packages (`requirements.txt`) | Manual, monthly: `pip-audit` |
| Frontend packages (Nuxt / React) | Manual, monthly: `pnpm audit` |
| restic | Ubuntu package (auto security updates) |

---

## 2. Monthly patch day (about 30–45 minutes)

### Step 1: see what needs updating (read-only)
```bash
/usr/local/sbin/patch-report.sh
```

### Step 2: fresh backup
```bash
/opt/feymi-backup/backup.sh db && /opt/feymi-backup/pitr.sh base && tail -2 /var/log/feymi-backup.log
```

### Step 3: Ubuntu + Docker engine + kernel (one reboot)
```bash
apt update && apt -y upgrade
reboot
```
After about 2 minutes, run the **post-reboot check**:
```bash
docker ps --format '{{.Names}}  {{.Status}}' | grep -vE 'healthy|Up' ; echo "(empty above = all containers fine)"
iptables -S DOCKER-USER | grep -c cf4; ip6tables -S DOCKER-USER | grep -c cf6; ip6tables -S DOCKER-USER | grep -c 8000
systemctl is-active feymi-wal-receiver
curl -s -o /dev/null -w "api %{http_code}\n" https://apidev.acadgrowth.co.in/api/health/
```
✅ `3`, `3`, `1`, `active`, `api 200`.

> ⚠️ An `apt upgrade` that updates `docker-ce` restarts Docker, and with it every container. That's why this step happens in the patch window.

### Step 4: service images (one at a time, check each)
For every `UPDATE` line in the report:

| Service | How to update in Coolify | Check after |
|---|---|---|
| **Postgres** (`pgvector:pg17`) | PostgreSQL → feymi-dev-db → **Restart** (it uses the newly pulled image). Minor versions only (17.x → 17.y) | `select version()`, app health 200, `pg_stat_replication` shows the WAL receiver streaming again |
| **Redis** (`7.2`) | Redis → Restart | app health 200 |
| **PgBouncer** | Edit the compose image tag to the new pinned version (check Docker Hub: 2+ weeks old, stable) → Deploy | `SHOW POOLS`, app health 200 |
| **Uptime Kuma** | Restart (tag `2` follows 2.x) | the UI loads, monitors are green |
| **Beszel** (pinned) | Bump both hub and agent tags together → Deploy | the system shows up |

> 🚫 **Never** jump a Postgres **major** version (17 → 18) on patch day. That's a planned migration with `pg_upgrade` or dump/restore, tested on a copy first.

### Step 5: Coolify (only if worth it)
1. Read the release notes for every version between 4.4.7 and the target.
2. Wait until the target version has been out for **2+ weeks** with no "broken" reports in GitHub issues.
3. Fresh backup (Step 2), plus a copy of `/data/coolify/source/.env` saved on your Mac.
4. Upgrade:
   ```bash
   curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash -s <VERSION>
   ```
5. If the panel breaks (like 4.4.5 did), roll back with the same command and `4.4.7`. Data is kept.
6. Check that **Auto Update is still OFF** in Settings.

### Step 6: app dependencies (on your Mac)
Backend:
```bash
cd socralearnbackend && pip install pip-audit && pip-audit -r requirements.txt
```
Frontends:
```bash
cd schoolteacherdashboard && pnpm audit --prod
```
```bash
cd studentdashboard && pnpm audit --prod
```
Fix **high/critical** findings by bumping the package. Test on dev, then deploy.

### Step 7: write it down
| Date | What was updated | Problems | Done by |
|---|---|---|---|
| | | | |

---

## 3. Also check monthly (2 minutes)
- [ ] Healthchecks.io: all checks green, none paused
- [ ] Beszel: disk under 70%
- [ ] `fail2ban-client status sshd`: still banning
- [ ] Cloudflare → Security → Events: nothing unusual
- [ ] The Sunday restore drills passed (`grep "drill OK" /var/log/feymi-backup.log | tail -4`)
- [ ] Remove old images: `docker image prune -f` (frees disk; doesn't touch running containers)
