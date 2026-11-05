# Feymi Dev — Encrypted Backup & Security Runbook

Goal: prove a production-grade, fully private backup and security setup on **dev**, then copy it as-is to production on Contabo.

## How it works

```
Contabo server (Coolify)
 ├─ Postgres (pgvector)  ── pg_dump every hour ─┐
 ├─ Coolify's own DB     ── pg_dump nightly  ───┤
 └─ /data/coolify + docker volumes (nightly) ───┤
                                                ▼
                          restic: AES-256 encryption ON THE SERVER
                          (nothing leaves the box unencrypted)
                                   │                      │
                                   ▼                      ▼
                      DigitalOcean Spaces (SGP)    Cloudflare R2
                         primary copy               second copy
                      (separate key + password)  (separate key + password)

Every Sunday: restore drill → latest dump restored into a throwaway Postgres
              with no network → checks tenants/schemas/pgvector → deleted.
Every job pings Healthchecks.io → email alert if a job fails or doesn't run.
```

| What | How often | Kept |
|---|---|---|
| App database dump | Hourly | 48 hourly, 14 daily, 8 weekly, 12 monthly |
| Coolify DB + config + volumes (Uptime Kuma, Beszel, media, beat) | Nightly 02:30 | 7 daily, 4 weekly, 6 monthly |
| Retention + 5% re-download integrity check | Sunday 04:00 | — |
| Restore drill | Sunday 05:30 | — |

**Most data you can lose:** 1 hour (Phase 1). In Phase 2, WAL-G point-in-time recovery cuts that to about 1 minute.

**Encryption:** restic encrypts with AES-256 and authenticates with Poly1305 before upload. DigitalOcean and Cloudflare only ever see encrypted blobs. Each repo has its **own password**, so one leaked password doesn't open both.

> ⚠️ **If you lose the restic passwords, the backups cannot be recovered by anyone.** Keep each one in 3 places: on the server (root-only file), in your password manager, and on paper in a safe place.

---

## Files in this folder

| File | Goes to (server) |
|---|---|
| `backup.sh`, `restore-drill.sh` | `/opt/feymi-backup/` |
| `config/*.env.example` | `/etc/feymi-backup/*.env` (fill in, chmod 600) |
| `config/excludes.txt` | `/etc/feymi-backup/excludes.txt` |
| `systemd/*` | `/etc/systemd/system/` |

---

## Phase 1 — set up encrypted backups (one step at a time)

Do each step, run its check, and continue only when the check passes.

### Step 1 — Create the DigitalOcean Spaces bucket
1. DigitalOcean → Spaces → Create → region **SGP1**, name `feymi-backups-dev`, **File listing: Restricted**, CDN **off**.
2. Spaces → Access Keys → New key → **limited to this bucket only**, Read/Write/Delete. Save the key + secret in your password manager.

✅ Check: the bucket shows as Private.

### Step 2 — Create the Cloudflare R2 bucket
1. Cloudflare → R2 → Create bucket `feymi-backups-dev`, location hint **Asia-Pacific**. No public access, no custom domain.
2. R2 → Manage API tokens → Create → **Object Read & Write**, **this bucket only**. Save the Access Key ID, Secret and the S3 endpoint (`https://<ACCOUNT_ID>.r2.cloudflarestorage.com`).

✅ Check: Settings → Public access shows **Disabled**.

### Step 3 — Create 4 Healthchecks.io checks
`feymi-dev-db` (period 1 hour, grace 30 min), `feymi-dev-files` (1 day, 2 h), `feymi-dev-prune` (7 days, 6 h), `feymi-dev-drill` (7 days, 6 h). Copy each ping URL.

### Step 4 — Install restic on the server
```bash
sudo apt update && sudo apt install -y restic && sudo restic self-update && restic version
```
✅ Check: version is **0.16 or newer** (needed for `--retry-lock`).

### Step 5 — Copy the kit to the server
From your Mac, inside the `AcadGrowth` folder:
```bash
scp -r infra-backup deploy@<server>:/tmp/
```
Then on the server:
```bash
sudo install -d -m 700 /opt/feymi-backup /etc/feymi-backup
sudo install -m 700 /tmp/infra-backup/*.sh /opt/feymi-backup/
sudo install -m 600 /tmp/infra-backup/config/excludes.txt /etc/feymi-backup/
sudo install -m 600 /tmp/infra-backup/config/common.env.example /etc/feymi-backup/common.env
sudo install -m 600 /tmp/infra-backup/config/repo-do.env.example /etc/feymi-backup/repo-do.env
sudo install -m 600 /tmp/infra-backup/config/repo-r2.env.example /etc/feymi-backup/repo-r2.env
sudo install -m 644 /tmp/infra-backup/systemd/* /etc/systemd/system/
rm -rf /tmp/infra-backup
```

### Step 6 — Create the two encryption passwords
```bash
sudo sh -c 'umask 077; openssl rand -base64 48 > /etc/feymi-backup/restic-do.key; openssl rand -base64 48 > /etc/feymi-backup/restic-r2.key'
sudo cat /etc/feymi-backup/restic-do.key /etc/feymi-backup/restic-r2.key
```
Copy both into your password manager **and** write them on paper now. Then clear the terminal (`clear`).

### Step 7 — Fill in the config
```bash
sudo docker ps --format '{{.Names}}  {{.Image}}'   # find the Postgres container name
sudo docker volume ls                              # find the postgres + redis volume names
sudo nano /etc/feymi-backup/common.env              # container match, PG user/db, 4 HC URLs
sudo nano /etc/feymi-backup/repo-do.env             # Spaces key + secret
sudo nano /etc/feymi-backup/repo-r2.env             # R2 endpoint + key + secret
sudo nano /etc/feymi-backup/excludes.txt            # real postgres/redis volume names
```
`PG_USER` / `PG_DB` are in Coolify → PostgreSQL → `feymi-dev-db` → General.

### Step 8 — Initialise both repos
```bash
sudo bash -c 'set -a; . /etc/feymi-backup/repo-do.env; restic init'
sudo bash -c 'set -a; . /etc/feymi-backup/repo-r2.env; restic init'
```
✅ Check: both print `created restic repository`.

### Step 9 — First manual runs
```bash
sudo /opt/feymi-backup/backup.sh db
sudo /opt/feymi-backup/backup.sh files
sudo tail -40 /var/log/feymi-backup.log
sudo bash -c 'set -a; . /etc/feymi-backup/repo-do.env; restic snapshots'
```
✅ Check: the log ends with `OK` for both, and snapshots show `db`, `db-globals` and `files` tags. Repeat `snapshots` with `repo-r2.env`.

### Step 10 — Restore drill by hand
```bash
sudo /opt/feymi-backup/restore-drill.sh do
sudo /opt/feymi-backup/restore-drill.sh r2
sudo tail -5 /var/log/feymi-backup.log
```
✅ Check: `tenants=N schemas=N vector_ext=1` and `restore drill OK` for both.

### Step 11 — Turn on the timers
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now feymi-backup-db.timer feymi-backup-files.timer feymi-backup-prune.timer feymi-backup-drill.timer
systemctl list-timers 'feymi-*'
```
✅ Check: 4 timers listed with next run times; after an hour, Healthchecks shows `feymi-dev-db` green.

### Step 12 — Log rotation
```bash
sudo tee /etc/logrotate.d/feymi-backup >/dev/null <<'EOF'
/var/log/feymi-backup.log { weekly rotate 8 compress missingok notifempty }
EOF
```

### Step 13 — Off-server copy of the config (not the passwords)
Keep a copy of `/etc/feymi-backup/*.env` in your password manager as a secure note. With that plus the two passwords, you can restore onto a brand-new server.

---

## Full disaster restore (new server)

1. New Ubuntu server → install Docker, Coolify 4.4.7, restic.
2. Put `repo-do.env` + `restic-do.key` back into `/etc/feymi-backup/`.
3. Restore Coolify config:
   ```bash
   sudo bash -c 'set -a; . /etc/feymi-backup/repo-do.env; restic restore latest --tag files --target /restore'
   ```
   Copy `/restore/data/coolify/source/.env` and `/restore/data/coolify/ssh` back, restore `coolify.dump` into `coolify-db`, then restart Coolify.
4. Create `feymi-dev-db` in Coolify, then:
   ```bash
   restic dump --tag db latest /postgres.dump > /root/db.dump
   docker cp /root/db.dump <db-container>:/tmp/ && docker exec <db-container> pg_restore -U postgres -d postgres --no-owner /tmp/db.dump
   shred -u /root/db.dump
   ```
5. Redeploy the backend from Coolify, update the Cloudflare A records, and check `/api/health/`.

**Target:** under 2 hours. Practise this once on a spare 1-day Contabo VPS before going to production.

---

## Phase 2 — point-in-time recovery (after Phase 1 runs cleanly for a week)

- Custom DB image `FROM pgvector/pgvector:pg17` with the **WAL-G** binary added.
- `archive_mode=on`, `archive_command='wal-g wal-push %p'`, `archive_timeout=60`.
- WAL-G encrypts with **libsodium** (its own key, stored like the restic passwords) and pushes to Spaces; a nightly `wal-g backup-push` takes a base backup.
- The restore drill also replays to a timestamp.
- Result: restore to any second, losing at most about 1 minute of data.

---

## Phase 3 — security hardening (do alongside)

| # | Item | Why |
|---|---|---|
| 1 | **Cloudflare Access (Zero Trust, free)** in front of `coolifydev`, `uptime` and `beszel` (email OTP to your address only) | Admin panels become invisible to the internet |
| 2 | **Coolify 2FA** on, registration off (already off) | Second lock on the control plane |
| 3 | Allow 80/443 **only from Cloudflare IP ranges** in iptables, plus Cloudflare SSL **Full (strict)** | Nobody can bypass Cloudflare/WAF by hitting the server IP directly |
| 4 | `unattended-upgrades` for **security updates only**; Coolify auto-update stays OFF | Kernel/OpenSSL patches without surprise app upgrades |
| 5 | Docker log limits in `/etc/docker/daemon.json` (`max-size 10m`, `max-file 3`) | Logs can't fill the disk and kill the DB |
| 6 | Postgres: app uses a **non-superuser role** that owns only its DB; superuser only for backups | A SQL injection can't drop everything |
| 7 | Postgres + Redis stay private (no public port), Redis with a password | Already done; keep it that way |
| 8 | Disk alert at 80% in Beszel | Full disk = failed backups + crashed DB |
| 9 | Rotate the old Railway passwords and delete the Railway dev DB | They leaked in chat during setup |
| 10 | Quarterly: full disaster restore onto a spare VPS | The only real proof backups work |

---

## Part B — PgBouncer connection pooling

### Why
Django runs with `CONN_MAX_AGE=0`, so **every request opens a brand-new Postgres connection** (a full SCRAM login, about 5–20 ms, plus a new Postgres process). Celery workers, beat and the LangGraph pool all add more. PgBouncer sits in front of Postgres and keeps a small set of warm connections that everyone reuses.

```
web (gunicorn) ─┐
worker (celery) ┼──▶ PgBouncer :5432 ──(≤ 85 warm conns)──▶ Postgres
beat            │     session mode, DISCARD ALL on reuse
LangGraph pool ─┘
backups/drill ───────────── direct (docker exec into Postgres) ───────▶
```

### ⚠️ Why session mode, not transaction mode
django-tenants picks the school with `SET search_path TO <school_schema>, public`. In **transaction** mode, PgBouncer may run that SET on one Postgres connection and the next query on another one, which can still hold a different school's search_path. **That leaks data across schools.** **Session** mode keeps one Postgres connection per Django connection for its whole life, and `DISCARD ALL` wipes the search_path before the connection is reused. Safe.

You still get: no new Postgres process per request, a hard cap on total DB connections (Postgres can't be overloaded into `too many connections`), fast reconnects, and a queue instead of errors under bursts.

Never switch to transaction mode unless the backend first gets a tested fix that sets search_path inside every transaction.

### Step B1 — Find the Postgres internal hostname and user
Coolify → PostgreSQL → `feymi-dev-db` → General: note the **container name** (internal host, e.g. `dwdxeo7cdv7qkjn6gvoo3i2w`), user and password. Check **Postgres URL (internal)**.

### Step B2 — Create the PgBouncer resource
1. Coolify → Projects → **PostgreSQL** project → + New → **Docker Compose Empty**.
2. Paste `infra-backup/pgbouncer/docker-compose.yml`.
3. Environment variables: `DB_HOST`, `DB_USER`, `DB_PASSWORD` from Step B1.
4. Turn **ON** "Connect to Predefined Network". Leave domains **empty** (never public).
5. Name it `feymi-dev-pgbouncer` and deploy.

✅ Check: the status is **Healthy**, and the logs show `listening on 0.0.0.0:5432` with no `auth failed`.

### Step B3 — Test from the backend container
Coolify → backend → Terminal → `web` container. Use the PgBouncer container's name as the host (shown in Coolify):
```bash
python - <<'EOF'
import psycopg2
c = psycopg2.connect(host="<pgbouncer-container-name>", port=5432, dbname="postgres", user="postgres", password="<DB_PASSWORD>")
cur = c.cursor(); cur.execute("select current_setting('search_path'), version()"); print(cur.fetchone())
EOF
```
✅ Check: it prints `"$user", public` and the Postgres 17 version.

### Step B4 — Point the backend at PgBouncer
Coolify → backend → Environment Variables:

| Variable | Change |
|---|---|
| `DATABASE_URL` | host → `<pgbouncer-container-name>`, port `5432` (user, password and db unchanged) |
| `LANGGRAPH_POSTGRES_URI` | same host change |
| `DB_CONN_MAX_AGE` | **leave at `0`**. The backend runs under ASGI (uvicorn workers), where Django's own persistent connections can pile up; Django's docs say to use 0 plus an external pooler, which is exactly PgBouncer |

Redeploy. `migrate` also runs through PgBouncer; session mode supports it.

✅ Check:
1. `/api/health/` returns 200, and Uptime Kuma is green.
2. **Tenant isolation test:** log in as a teacher at School A and as a teacher at School B in two browsers. Click around both quickly for a minute; each must only ever see its own school's data.
3. A Celery task runs (e.g. a small AI generation) and finishes.

### Step B5 — Watch the pool
```bash
# from the web container terminal
psql "postgresql://postgres:<pw>@<pgbouncer-container-name>:5432/pgbouncer" -c "SHOW POOLS;" -c "SHOW STATS;"
```
Healthy: `cl_waiting` is 0 most of the time, and `sv_active + sv_idle` stays ≤ 85. If `cl_waiting` stays above 0, raise `DEFAULT_POOL_SIZE` (keep `MAX_DB_CONNECTIONS` below Postgres `max_connections` minus 10 for backups and admin).

### Rollback
Put the old `DATABASE_URL` / `LANGGRAPH_POSTGRES_URI` back and redeploy (about 2 minutes). PgBouncer can stay running unused.

### Sizing rule (keep for production)
`Postgres max_connections` ≥ `MAX_DB_CONNECTIONS` + 10.
In session mode each live Django or Celery connection holds one server connection, so `DEFAULT_POOL_SIZE` must be ≥ gunicorn workers × 2 + Celery concurrency + LangGraph pool max + 5.
**Dev today:** the LangGraph checkpointer opens its own pool in *every* gunicorn worker (min 1, max 10), so 4 workers can hold up to 40 connections on their own. `docker-compose.coolify.yml` already defaults `GUNICORN_WORKERS` to 3 (server has 4 CPU): 3×1 + 3×10 + Celery 2 + beat 1 + 5 = **41 ≤ 70**. Leave it.
Later, cut LangGraph `max_size` to 3: chat checkpoints don't need 10 per worker.

**SSL:** on dev the backend uses `?sslmode=disable` in `DATABASE_URL`, because the backend → PgBouncer traffic never leaves the Docker network on one host (`LANGGRAPH_POSTGRES_URI` is empty and copies `DATABASE_URL`). **In production, where the DB is on another server, enable TLS:** give PgBouncer `CLIENT_TLS_SSLMODE=require` plus a cert/key, and set the app back to `sslmode=require`.

In production, run one PgBouncer on the DB server, reached over the Contabo private network.

---

## Moving to production

Same kit, with these changes:
- New buckets `feymi-backups-prod` (Spaces + R2) and **new passwords and keys** (never share them with dev).
- Phase 2 (PITR) is **required** for production.
- On R2, turn on a **bucket lock rule** (e.g. 30 days on `data/`) once retention settles, so even a stolen key can't delete history.
- The restore drill runs on a separate small VPS, not on the production DB server.

---

## Phase 3: done on dev (2026-11-02)

| Item | State |
|---|---|
| Security auto-updates | Already active (Ubuntu base + security only, no auto-reboot). Docker and Coolify are not touched |
| Beszel alerts | Status down 10 min, Disk > 80%, Memory > 90%, CPU > 90% (10 min). Email via ZeptoMail SMTP (`smtp.zeptomail.in:587`, from `noreply@acadgrowth.org`), set in PocketBase `/_/` → Mail settings |
| Cloudflare proxy | beszel, uptime, coolifydev and apidev are all Proxied. SSL mode: Automatic (Full) |
| Upload cap | `MATERIAL_MAX_UPLOAD_BYTES=99614720` (95 MB), below Cloudflare's free 100 MB body limit. Direct-to-bucket uploads would remove the cap |
| Cloudflare Access (team `late-pine-ff57`) | Policies `Feymi admins` (Allow, your emails, 24 h) and `Bypass – machines` (Bypass, Everyone). Apps: Coolify webhooks (`coolifydev/webhooks`, bypass), ACME renewals (`/.well-known/acme-challenge` on 3 hosts, bypass), Feymi dev admin panels (coolifydev, uptime, beszel), Feymi dev API admin (apidev `admin`, `swagger`, `redoc`, `api/schema`) |
| IPv6 hole closed | Docker publishes ports on IPv6 and ip6tables `DOCKER-USER` was empty, so Coolify :8000 answered on IPv6. Now 8000/6001/6002/8080 are dropped from eth0 on v4 and v6 |
| Origin lock | `security/cf-origin-lock.sh` (apply → test → confirm, 10-min auto-undo): 80/443 tcp + 443 udp only from Cloudflare ipsets `cf4`/`cf6` (v4 + v6). `cf-ips-refresh.timer` runs Mondays 03:15. Needs `ipset ipset-persistent` |
| Docker log limits | Already in `/etc/docker/daemon.json` (10 MB × 3) |
| Reboot test | Everything came back by itself: containers, firewall, ipsets, timers, API 200 |
| Non-superuser app DB role | **Deferred to production.** Re-owning every object in an existing django-tenants database is risky. On production, create `feymi_app` as owner of a fresh database and restore into it (`pg_restore --no-owner --role=feymi_app`) |

**Note for production:** check `ip6tables -S DOCKER-USER` on every server. Docker opens published ports on IPv6, which INPUT rules don't cover.

---

## Phase 2: point-in-time recovery, done on dev (2026-11-02)

Built with stock PostgreSQL tools in throwaway containers. The Postgres container and its image are **not modified**. The script is `pitr/pitr.sh`, installed at `/opt/feymi-backup/pitr.sh`.

| Piece | How |
|---|---|
| Replication login | `feymi_repl` (REPLICATION LOGIN only). Password in `/etc/feymi-backup/repl.docker.env` (600); `REPL_USER` in `repl.env` |
| DB changes | slot `feymi_wal`; `ALTER SYSTEM SET max_slot_wal_keep_size='4GB'`; pg_hba line `host replication feymi_repl samenet scram-sha-256`; reload only, no restart |
| WAL receiver | `feymi-wal-receiver.service` runs `pg_receivewal` (pgvector/pg17 image, `coolify` network) into `/var/lib/feymi-wal` |
| WAL upload | `feymi-pitr-push.timer` every 5 min: restic to DigitalOcean + R2, tag `pitr-wal`. Local WAL kept 3 days. Healthcheck `HC_WAL` |
| Base backup | `feymi-pitr-base.timer` daily 01:30: `pg_basebackup -Ft -X fetch` to both repos, tag `pitr-base`. Retention: base 8 daily, WAL within 9 days. Healthcheck `HC_PITR_BASE` |
| Drill | `feymi-pitr-drill.timer` Sundays 06:30, on DigitalOcean then R2: restore to "10 minutes ago" in a network-less container, check `tenants` |
| Most data lost | about 5 minutes (upload interval). Hourly `pg_dump` stays as an independent second net |

First drill: target 15:10:50 IST, "recovery stopping before commit … 09:41:00 UTC", tenants=2, 53 s.

### Restore the real database to a moment in time (incident)
1. Find the time just **before** the bad event, e.g. `'2026-11-02 15:42:00+05:30'`.
2. `/opt/feymi-backup/pitr.sh restore do '2026-11-02 15:42:00+05:30'` gives a running **copy** (the container name is printed). Check the data in it.
3. Put the app in maintenance (stop web, worker and beat in Coolify) and take a fresh `pg_dump` of the bad live DB for safety.
4. Copy the good data back:
   - **Whole DB:** `pg_dump` from the copy, then `pg_restore --clean` into live.
   - **One school or table:** `pg_dump -n <schema>` / `-t <table>` from the copy into live.
5. Start the app again, then remove the copy using the command the script printed.

---

## Gap found: bucket files are not backed up (fix in production)

Uploaded files (materials, images, PDFs) live in object storage: Railway `t3.storageapi.dev` on dev, DigitalOcean Spaces on prod. restic covers the database, Coolify and server volumes, **not the bucket**.

**Production must add:** turn on DigitalOcean Spaces versioning, plus a nightly encrypted copy of the bucket to R2 (rclone `crypt` remote or restic over an rclone mount). Monitor it with a Healthchecks check like the other jobs.

---

## DB hardening settings (dev, 2026-11-02)

Applied with `ALTER SYSTEM` + `pg_reload_conf()`, no restart:
`idle_in_transaction_session_timeout=15min` (5 min risks killing long AI jobs that wait inside a transaction), `log_min_duration_statement=2s`, `log_connections=on`, `log_disconnections=on`, `log_lock_waits=on`. View the logs in Coolify → feymi-dev-db → Logs.

Checked: no published DB/Redis ports, Redis requires a password, fail2ban is active (8 bans on day one).

**Open DB items:**
- Production: `feymi_app` non-superuser role and TLS to the DB server.
- Accepted: no disk encryption at rest on the VPS (backups are encrypted).
- Separate project: app-level encryption of sensitive personal fields (DPDP, minors).
- Monthly: patch day for the image versions.
