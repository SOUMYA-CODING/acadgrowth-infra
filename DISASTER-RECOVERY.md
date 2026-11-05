# Feymi Dev — Disaster Recovery Guide

Rebuild the whole dev server on a **brand-new server** using only:
- the encrypted backups (DigitalOcean Spaces, or Cloudflare R2 if DigitalOcean is unavailable)
- your password manager

Use it for the **disaster test** (a rehearsal on a spare VPS) and for a **real disaster**. The differences are marked **🧪 TEST** and **🔥 REAL**.

> Do one step at a time and run its ✅ check before moving on.
> Never paste passwords or keys into chat. Replace them with `***` when you share output.

---

## 0. Before you start

### What you need
| Item | Where |
|---|---|
| New VPS: Contabo Cloud VPS 10 (or bigger), **Ubuntu 24.04** | Contabo panel; IP + root password arrive by email |
| Your Mac SSH key `~/.ssh/id_ed25519` (+ passphrase) | your Mac |
| Restic password **DigitalOcean** | Passwords → `Feymi dev backup password: DigitalOcean` |
| DO Spaces access key + secret | Passwords |
| (fallback) Restic password **R2** + R2 key/secret/endpoint | Passwords |
| Secure note **Feymi dev backup config** (contents of `common.env`, `repo-do.env`, `repo-r2.env`) | Passwords |
| This repo folder `infra-backup/` | your Mac |

### Safety rules: 🧪 TEST only
- 🚫 **No DNS changes.** Real domains keep pointing at the real dev server. You reach the test server through an **SSH tunnel** only.
- 🚫 **Disarm the app before deploying it** (Step 9). Otherwise the test copy would send real emails, push notifications and WhatsApp messages, call AI with your keys, and touch the **shared bucket**.
- 🚫 **No Healthchecks pings** from the test server. Leave the `HC_*` values empty.
- 🚫 **Don't turn on the backup timers** on the test server. Two servers writing to the same repos would mix backups.
- ✅ Wipe and cancel the VPS when you're done (Step 12).

### ⏱️ Start a stopwatch now
Write down the start time. The total is your real **RTO** (recovery time objective).

| Step | Started | Finished | Notes |
|---|---|---|---|
| 1 Server basics | | | |
| 2 Firewall | | | |
| 3 Coolify install | | | |
| 4 restic + config | | | |
| 5 Restore Coolify | | | |
| 6 Check Coolify UI | | | |
| 7 Start DB, Redis, PgBouncer | | | |
| 8 Restore app data | | | |
| 9 Disarm + deploy backend | | | |
| 10 Verify | | | |
| **Total** | | | |

---

## 1. Server basics

On your **Mac**, copy your key to the new server (asks for the root password from Contabo's email):
```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@NEW_IP
```
Log in:
```bash
ssh root@NEW_IP
```
On the **new server**:
```bash
apt update && apt -y upgrade
apt install -y restic curl python3 iptables-persistent ipset ipset-persistent
timedatectl set-timezone Asia/Kolkata
restic version
```
✅ You log in with the key (no password prompt), and restic shows `0.16` or newer.

Turn off password login:
```bash
cat > /etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
systemctl reload ssh
```
⚠️ Keep this terminal open. Open a **second** terminal and run `ssh root@NEW_IP` to confirm the key still works before closing the first one.

---

## 2. Firewall: SSH only (do this before Coolify)

Host firewall:
```bash
iptables -P INPUT ACCEPT
iptables -F INPUT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
iptables -P INPUT DROP
ip6tables -P INPUT ACCEPT
ip6tables -F INPUT
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT
ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
ip6tables -P INPUT DROP
netfilter-persistent save
```
✅ Your second SSH session still works.

> Docker-published ports bypass INPUT. Step 3 closes them in `DOCKER-USER`, right after Docker is installed.

---

## 3. Install Coolify (same version: 4.4.7)

```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash -s 4.4.7
```
**Right after it finishes**, block every new inbound connection to Docker containers from the internet (IPv4 + IPv6). Replies to the containers' own outbound traffic still work:
```bash
iptables  -I DOCKER-USER -i eth0 -m conntrack --ctstate NEW -j DROP
ip6tables -I DOCKER-USER -i eth0 -m conntrack --ctstate NEW -j DROP
netfilter-persistent save
docker ps --format '{{.Names}}  {{.Status}}' | grep coolify
```
✅ `coolify`, `coolify-db`, `coolify-redis` and `coolify-proxy` are Up.

From your **Mac**, prove nothing is exposed:
```bash
curl -s -m 5 -o /dev/null -w "8000: %{http_code}\n" http://NEW_IP:8000/
```
✅ `8000: 000`

> 🔥 REAL: keep this rule until Step 11. At Step 11 you switch to the Cloudflare-only lock.

---

## 4. restic + backup config

```bash
install -d -m 700 /etc/feymi-backup /opt/feymi-backup
nano /etc/feymi-backup/repo-do.env
```
Paste the `repo-do.env` part of your **Feymi dev backup config** note. It has 5 lines: `RESTIC_REPOSITORY`, `RESTIC_PASSWORD_FILE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION`. Save.

Create the password file. `nano` it and paste **only** the DigitalOcean restic password, on one line:
```bash
nano /etc/feymi-backup/restic-do.key
chmod 600 /etc/feymi-backup/*
```

Test the repo (read-only):
```bash
bash -c 'set -a; . /etc/feymi-backup/repo-do.env; restic --no-lock snapshots --compact | tail -15'
```
✅ You see recent snapshots tagged `db`, `files`, `pitr-base` and `pitr-wal`.

> If DigitalOcean is down or the key fails, do the same with `repo-r2.env` and `restic-r2.key`, and use `r2` instead of `do` in the rest of this guide.

---

## 5. Restore Coolify (its database, APP_KEY and SSH keys)

**5a. Pull the Coolify backups out of restic:**
```bash
mkdir -m 700 /root/restore
cd /root/restore
bash -c 'set -a; . /etc/feymi-backup/repo-do.env
  restic --no-lock dump --tag files --path /coolify.dump latest /coolify.dump > coolify.dump
  restic --no-lock restore latest --tag files --path /data/coolify --path /etc/feymi-backup/common.env --path /var/lib/docker/volumes \
    --include /data/coolify/source/.env --include /data/coolify/ssh --include /etc/feymi-backup/common.env --target /root/restore'
ls -la /root/restore/data/coolify/source/.env /root/restore/data/coolify/ssh/keys/
ls -la coolify.dump
```
✅ `.env` exists, `ssh/keys/` has one or more key files, and `coolify.dump` is several MB.

> `restore` with several `--path` filters picks the snapshot that has *all* those paths, which is the nightly "files" folder snapshot.

**5b. Stop Coolify, except its own database:**
```bash
docker stop coolify coolify-realtime coolify-redis 2>/dev/null; docker ps --format '{{.Names}}' | grep coolify
```
✅ Only `coolify-db` (and maybe `coolify-proxy`) are still running.

**5c. Restore the Coolify database:**
```bash
docker exec -i coolify-db pg_restore --clean --if-exists --no-acl --no-owner -U coolify -d coolify < /root/restore/coolify.dump
echo "exit=$?"
```
✅ `exit=0`. A few "does not exist" notices are fine.

**5d. Restore Coolify's SSH keys** (Coolify manages "localhost" over SSH with them):
```bash
cp -a /root/restore/data/coolify/ssh/keys/. /data/coolify/ssh/keys/
for k in /root/restore/data/coolify/ssh/keys/*; do ssh-keygen -y -f "$k" >> /root/.ssh/authorized_keys 2>/dev/null; done
sort -u -o /root/.ssh/authorized_keys /root/.ssh/authorized_keys
```

**5e. Bring back the old APP_KEY.** It decrypts the env vars stored in Coolify's DB. Look at the old key without printing it fully:
```bash
grep '^APP_KEY=' /root/restore/data/coolify/source/.env | cut -c1-20
```
Open the **new** `.env` and add the **old** key as `APP_PREVIOUS_KEYS`:
```bash
nano /data/coolify/source/.env
```
Add this line, copying the full old value from `/root/restore/data/coolify/source/.env`:
```
APP_PREVIOUS_KEYS=base64:OLD-KEY-VALUE-HERE
```
Save. Then re-run the installer. It keeps your data and restarts everything with the right keys:
```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash -s 4.4.7
```
⚠️ The installer may reset firewall rules. Check that the Step 3 rule is still first, and re-add it if not:
```bash
iptables -S DOCKER-USER | head -3; ip6tables -S DOCKER-USER | head -3
```

---

## 6. Open Coolify through an SSH tunnel

On your **Mac** (leave it running):
```bash
ssh -N -L 8000:localhost:8000 root@NEW_IP
```
Open **http://localhost:8000** in the browser and log in with your **usual Coolify login**.

✅ Check:
- **Projects:** My first project (backend), PostgreSQL (feymi-dev-db + feymi-dev-pgbouncer), Redis, Uptime Kuma, Beszel are all listed.
- **Servers → localhost:** status is reachable (green). If it's red, click **Validate**. Step 5d added its SSH key, and if validation still fails, run `docker restart coolify`.
- Open the backend → **Environment Variables**. The values are readable (not blank or garbled). That proves the APP_KEY restore worked.

---

## 7. Start the data services (empty for now)

In Coolify:
1. **PostgreSQL → feymi-dev-db → Start.** It comes up **empty**, with the same container name `dwdxeo7cdv7qkjn6gvoo3i2w` and the same password.
2. **Redis → start.**
3. **PostgreSQL → feymi-dev-pgbouncer → Deploy.**

Server check:
```bash
docker ps --format '{{.Names}}  {{.Status}}' | grep -E 'dwdxeo|lct5|pgbouncer'
```
✅ All three are Up (healthy).

---

## 8. Restore the app database (point-in-time)

**8a. Install the restore tools from the repo.** From your **Mac**:
```bash
cd "/Users/soumyaprakashsahu/Documents/Client Projects/AcadGrowth"
scp infra-backup/pitr/pitr.sh infra-backup/restore-drill.sh root@NEW_IP:/opt/feymi-backup/
```
On the **server**:
```bash
chmod 700 /opt/feymi-backup/*.sh
cp /root/restore/etc/feymi-backup/common.env /etc/feymi-backup/common.env
sed -i -E 's#^(HC_[A-Z_]+)=.*#\1=#' /etc/feymi-backup/common.env      # 🧪 TEST: no Healthchecks pings
echo 'REPL_USER=feymi_repl' > /etc/feymi-backup/repl.env
: > /etc/feymi-backup/repl.docker.env
chmod 600 /etc/feymi-backup/*
grep -c '^HC_.*=$' /etc/feymi-backup/common.env
```
✅ The count matches the number of `HC_` lines (all empty).

**8b. Restore a copy of the DB to a moment.** For the 🧪 TEST, use about **10 minutes ago**. For a 🔥 REAL disaster, use just before the server died:
```bash
T=$(date -d '10 minutes ago' '+%Y-%m-%d %H:%M:%S%:z'); echo "$T"
/opt/feymi-backup/pitr.sh restore do "$T"
```
✅ It ends with `recovery stopping before commit … / archive recovery complete`, `tenants=2`, and prints the restored copy's **container name**, for example `feymi-pitr-restore-12345`. Note it.

> If PITR fails, fall back to the hourly dump:
> `bash -c 'set -a; . /etc/feymi-backup/repo-do.env; restic --no-lock dump --tag db latest /postgres.dump' > /root/restore/app.dump`
> Then skip to 8d using that file.

**8c. Export from the restored copy:**
```bash
COPY=feymi-pitr-restore-XXXXX        # the name printed above
docker exec "$COPY" pg_dump -U postgres -d postgres -Fc > /root/restore/app.dump
ls -la /root/restore/app.dump
```

**8d. Load it into the new Coolify database:**
```bash
docker exec -i dwdxeo7cdv7qkjn6gvoo3i2w pg_restore -U postgres -d postgres --clean --if-exists --no-owner < /root/restore/app.dump
docker exec dwdxeo7cdv7qkjn6gvoo3i2w psql -U postgres -tAc "select count(*) from tenant" -c "select count(*) from user_profile" -c "select extname from pg_extension where extname='vector'"
```
✅ Tenant count = 2 (or whatever production has), users > 0, `vector` present.

**8e. Remove the temporary copy:**
```bash
docker rm -f "$COPY"; rm -rf /root/pitr.*
```

---

## 9. Disarm, then deploy the backend

### 🧪 TEST: disarm first
In Coolify → backend (My first project) → **Environment Variables**, change these to `disabled-for-dr-test`. Each one stops a real-world side effect:

| Variable | Stops |
|---|---|
| `ZEPTOMAIL_SEND_MAIL_TOKEN` | real emails |
| `OPENROUTER_API_KEY`, `OPENROUTER_MANAGEMENT_API_KEY`, `GEMINI_API_KEY`, `CLAUDE_API_KEY`, `OPENAI_MODERATION_KEY` | AI calls on your bill |
| `WHATSAPP_API_KEY`, `SMS_API_KEY` | messages |
| `FIREBASE_SERVICE_ACCOUNT_JSON` | push notifications |
| `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY` | **writes or deletes in the shared bucket** |
| `RAZORPAY_KEY_SECRET`, `STRIPE_SECRET_KEY`, `PAYU_SALT_KEY` | payment calls |

> 🔥 REAL: skip this table. You want everything live.

### Deploy
Click **Deploy** on the backend. It builds from GitHub, which proves the restored GitHub App works. Expect 10–15 minutes.

**🧪 TEST: as soon as it's up, stop the background workers:**
```bash
docker stop $(docker ps --format '{{.Names}}' | grep -E '^(worker|beat)-')
docker ps --format '{{.Names}}  {{.Status}}' | grep -E '^(web|worker|beat)-'
```
✅ Only `web-…` is running.

---

## 10. Verify

```bash
W=$(docker ps --format '{{.Names}}' | grep -m1 '^web-')
docker exec "$W" curl -s -o /dev/null -w "health: %{http_code}\n" http://localhost:8000/api/health/
docker exec "$W" python manage.py check --deploy 2>&1 | tail -2
docker exec dwdxeo7cdv7qkjn6gvoo3i2w psql -U postgres -tAc "select count(*) from tenant" -c "select count(*) from pg_stat_activity where client_addr is not null"
```
✅ `health: 200`, Django loads its settings (any warnings are fine), tenants = 2, and the DB has connections (through PgBouncer).

**⏱️ Stop the stopwatch.** Fill in the table in Step 0.

### 🧪 TEST: optional extras
- **Uptime Kuma data:** restore just that volume, then copy it over the new one while Kuma is stopped:
  `bash -c 'set -a; . /etc/feymi-backup/repo-do.env; restic --no-lock restore latest --tag files --path /data/coolify --path /etc/feymi-backup/common.env --path /var/lib/docker/volumes --include "/var/lib/docker/volumes/*uptime-kuma-data*" --target /root/restore'`
  Then stop Kuma in Coolify, run `cp -a /root/restore/var/lib/docker/volumes/<name>/_data/. /var/lib/docker/volumes/<name>/_data/`, and start Kuma.
- **Login test in a browser:** add a temporary tunnel to Traefik, `ssh -N -L 8443:localhost:443 root@NEW_IP`, plus a hosts-file entry. Optional; the health check plus data counts are enough for this test.

---

## 11. 🔥 REAL disaster only: go live

1. **Re-arm the real secrets.** You skipped Step 9's table, so nothing to do.
2. **Start workers:** Coolify → backend → Restart (worker and beat come back).
3. **DNS:** in Cloudflare, change the 4 A records (`apidev`, `coolifydev`, `uptime`, `beszel`) to the **new IP**, all 🟧 Proxied. AAAA records too, if you added any.
4. **Firewall:** remove the "block all new" rule and apply the Cloudflare-only lock plus the internal-port blocks:
   ```bash
   iptables  -D DOCKER-USER -i eth0 -m conntrack --ctstate NEW -j DROP
   ip6tables -D DOCKER-USER -i eth0 -m conntrack --ctstate NEW -j DROP
   for p in 8000 6001 6002 8080; do
     iptables  -I DOCKER-USER -i eth0 -p tcp -m conntrack --ctorigdstport $p --ctdir ORIGINAL -j DROP
     ip6tables -I DOCKER-USER -i eth0 -p tcp -m conntrack --ctorigdstport $p --ctdir ORIGINAL -j DROP
   done
   ```
   Then install `security/cf-origin-lock.sh` and run `apply` → test → `confirm`, as in the RUNBOOK.
5. **Backups:** reinstall the full kit (RUNBOOK Phase 1 Steps 5–11 and Phase 2). Use the **same repos and passwords**, so history continues. Recreate the replication role, slot and pg_hba line (RUNBOOK Phase 2) on the new DB.
6. **Monitoring:** check that Uptime Kuma and Beszel are green, and that Healthchecks pings resume.
7. **Cloudflare Access:** nothing to change. It follows the hostnames, not the IP.
8. Write down what happened and how long it took.

---

## 12. 🧪 TEST only: wipe and cancel

```bash
shred -u /etc/feymi-backup/*.key /etc/feymi-backup/*.env 2>/dev/null
rm -rf /root/restore /root/pitr.* /etc/feymi-backup
docker ps -q | xargs -r docker stop
```
Then in the **Contabo panel**: cancel or delete the VPS. Optionally **reinstall the OS** first, which wipes the disk.

✅ Nothing restored stays on a server you no longer control.

---

## 13. After the test: fix the runbook

Write down:
- Total time (RTO) and the slowest step
- Anything missing from backups or the password manager
- Any command that didn't work as written (fix it in this file)

**Pass criteria:**
| Must be true | |
|---|---|
| Rebuilt with **only** backups + password manager | ☐ |
| Coolify projects + env vars restored and readable | ☐ |
| App DB restored with PITR (tenants = 2) | ☐ |
| Backend built from GitHub and `/api/health/` = 200 | ☐ |
| No real email, AI call, message or bucket write happened from the test server | ☐ |
| Test VPS wiped and cancelled | ☐ |
| RTO recorded | ☐ ____ minutes |
