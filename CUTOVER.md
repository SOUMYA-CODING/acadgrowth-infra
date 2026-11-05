# Production cutover: DigitalOcean + Vercel → Contabo

Do the steps in order and tick each box. Paste each step's output to Claude before moving on.
Expected downtime: about 10 minutes, from step C1 to step C8.

| Server | IP |
|---|---|
| DigitalOcean (old) | 168.144.146.248 |
| Contabo frontends | 13.140.253.50 |
| Contabo api | 13.140.253.52 |

---

## Part A: Pre-flight (no downtime, about 20 minutes)

- [ ] **A1. Test sites still work**
  - school-test, student-test and admin.acadgrowth.co.in: log in and open 2–3 pages on each.
  - Do NOT pay or message real users. That data is a stale copy and gets replaced.
- [ ] **A2. Save the old DNS records (needed for rollback).** In the Cloudflare account that holds acadgrowth.org + feymi.app:
  - Open **DNS → Records** for each zone.
  - Screenshot the records for `acadgrowth.org`, `www.acadgrowth.org`, `api.acadgrowth.org`, `admin.acadgrowth.org`, `feymi.app` and `www.feymi.app`.
- [ ] **A3. SSL mode = Full (strict)** on BOTH zones (**SSL/TLS → Overview**).
  - With "Flexible", Cloudflare talks http to Coolify, Coolify redirects to https, and you get an endless redirect loop.
- [ ] **A4. Bot Fight Mode OFF** on the acadgrowth.org zone (**Security → Bots**). It can block Razorpay webhooks once `api.acadgrowth.org` becomes orange-cloud.
- [ ] **A5. Disable the old DO auto-deploy.**
  - GitHub → **acadgrowth-admin/feymibackend** (the old DO repo, remote `origin`) → **Actions → "Deploy to DigitalOcean" → ⋯ → Disable workflow**. Do the same on SOUMYA-CODING/acadgrowthbackend if it shows there too.
  - Contabo deploys from **SOUMYA-CODING/acadgrowthbackend** (remote `acadgrowthbackend`). The old repo gets removed in Part D.
  - Otherwise a push to master would restart DO's worker and beat on the old DB, and users would get duplicate notifications. This is reversible.
- [ ] **A6. No pushes to master** in any repo until Part D is done.
- [ ] **A7. Contabo workers app is stopped** (Coolify → acadgrowth-prod-backend-workers shows Exited).

## Part B: Downtime starts

- [ ] **C1. Stop DigitalOcean (API goes down now).** Run on your Mac:
  ```bash
  ssh root@168.144.146.248 'systemctl stop socralearn-web socralearn-worker socralearn-beat && systemctl disable socralearn-web socralearn-worker socralearn-beat && systemctl is-active socralearn-web socralearn-worker socralearn-beat'
  ```
  Expected: three lines of `inactive`. Disabling them means a reboot of the droplet won't bring them back.
- [ ] **C2. Copy any last local media files to the bucket** (idempotent; never deletes):
  ```bash
  ssh root@168.144.146.248 'cd /var/www/socralearn && . venv/bin/activate && set -a && . ./.env && set +a && python manage.py copy_local_files_to_bucket --apply | tail -5'
  ```
  Expected: a summary line `copied=… already_in_bucket=… missing=…`. Small "missing" numbers are fine; those files were already gone on DO.
- [ ] **C3. Copy the database** (about 80 s). Run on your Mac:
  ```bash
  bash "/Users/soumyaprakashsahu/Documents/Client Projects/AcadGrowth/infra-backup/prod/cutover-restore.sh"
  ```
  Expected: two `ok:` safety lines, `restore took ~80s`, and **`MATCH - restore OK`**. If you see ABORT or MISMATCH, stop and tell Claude.
- [ ] **C4. Restart the Contabo API** (it holds connections to the old copy):
  - Coolify → acadgrowth-prod-backend-api → **Restart current version**. Wait until it is healthy.
  - Check with:
  ```bash
  curl -s -o /dev/null -w '%{http_code}\n' https://api.acadgrowth.co.in/api/health/
  ```
  Expected: `200`.
- [ ] **C5. Start the Contabo workers.** Coolify → acadgrowth-prod-backend-workers → **Deploy** (or Start). Wait until both worker and beat show Running.
- [ ] **C6. Switch DNS** (Cloudflare, acadgrowth.org + feymi.app account). Delete the old Vercel / DO records for each name, then add these. All must be **Proxied (orange cloud)**.

  | Name | Type | Value |
  |---|---|---|
  | `acadgrowth.org` | A | 13.140.253.50 |
  | `www.acadgrowth.org` | A | 13.140.253.50 |
  | `feymi.app` | A | 13.140.253.50 |
  | `www.feymi.app` | A | 13.140.253.50 |
  | `api.acadgrowth.org` | A | 13.140.253.52 |

  - Do NOT touch MX / TXT records (Zoho mail, verifications).
  - Leave `admin.acadgrowth.org` on Vercel for now. It talks to api.acadgrowth.org, so it keeps working. Retire it in Part D.
- [ ] **C7. Add the domains in Coolify** (each one starts with `https://`), then click **Redeploy**. The same commit reuses the built image, so this is quick.
  - School dashboard app: `https://acadgrowth.org,https://www.acadgrowth.org` (keep school-test for now).
  - Student app: `https://feymi.app,https://www.feymi.app` (keep student-test for now).
  - API app, **web** service: add `https://api.acadgrowth.org:8000` next to the .co.in one.
- [ ] **C8. Certificates.** Traefik fetches Let's Encrypt certs within about 1–2 minutes. Until then the sites may show a Cloudflare 526 error. That's expected; wait and refresh.
  ```bash
  for u in https://acadgrowth.org https://www.feymi.app https://feymi.app https://api.acadgrowth.org/api/health/; do printf '%s ' $u; curl -s -o /dev/null -w '%{http_code}\n' $u; done
  ```
  Expected: `200` for all of them (or `301`/`308` for a www/apex redirect). **Downtime ends here.**

## Part C: Smoke test (about 10 minutes)

- [ ] **S1.** Log in on acadgrowth.org as a school admin and as a teacher; open the dashboard, a class and the library.
- [ ] **S2.** Log in on feymi.app as a student; send one AI chat message; open a course.
- [ ] **S3.** Parent login on feymi.app.
- [ ] **S4.** Mobile app (installed APK) logs in. It uses api.acadgrowth.org.
- [ ] **S5.** Upload one small file (material or assignment) and open it again.
- [ ] **S6.** Super admin at admin.acadgrowth.co.in: log in and open schools.
- [ ] **S7.** Celery is working: something async (e.g. an AI notes or quiz job) completes, and Coolify worker logs show tasks with no errors.
- [ ] **S8.** Uptime Kuma: add or update monitors for acadgrowth.org, feymi.app and api.acadgrowth.org/api/health/. All green.
- [ ] **S9.** Razorpay dashboard → Webhooks: the next delivery to api.acadgrowth.org shows 200. If unsure, use the Razorpay "test webhook" button. Do not make a real payment just to test.

## Rollback (only if Part C fails badly)

Decide within about 1 hour. Anything users write on Contabo after the switch would be lost by a rollback.

1. In Coolify, **stop** the workers app (and the API app).
2. Cloudflare: put the old records back. These were recorded 2026-11-05:

   | Name | Type | Value | Proxy |
   |---|---|---|---|
   | `acadgrowth.org` | CNAME | 48b95835cff11f0a.vercel-dns-017.com | DNS only |
   | `www.acadgrowth.org` | CNAME | 48b95835cff11f0a.vercel-dns-017.com | DNS only |
   | `api.acadgrowth.org` | A | 168.144.146.248 | Proxied |
   | `feymi.app` | CNAME | 36d01b4acf9ad863.vercel-dns-017.com | DNS only |
   | `www.feymi.app` | CNAME | 36d01b4acf9ad863.vercel-dns-017.com | DNS only |
3. Bring DigitalOcean back:
   ```bash
   ssh root@168.144.146.248 'systemctl enable --now socralearn-web socralearn-worker socralearn-beat && systemctl is-active socralearn-web socralearn-worker socralearn-beat'
   ```
   Expected: three lines of `active`.
4. Re-enable the GitHub workflow later, only if staying on DO.

If more than about 1 hour has passed with real users on Contabo, **fix forward instead**. If you really must go back, copy the data Contabo → DO with the same script reversed (Claude prepares it).

## Part D: After cutover (about 1 week of stable running)

The full list is in memory, post-cutover-cleanup:
- Remove test domains and CORS_EXTRA_ORIGINS.
- Retire admin.acadgrowth.org (redirect it to admin.acadgrowth.co.in), then delete the Vercel projects and vercel.json.
- Delete deploy.yml.
- Remove the DO trusted source.
- Scope the keys.
- Decommission DO and Railway.
- Clean up .md/.pdf files (confirm the list first).
