# DEPLOYMENT.md — RCC-HIROS

**Author:** Jerome (Yuuseiii) · **Date:** October 2026
**Application:** RCC-HIROS — Human Resource & Inventory Operations System
**Live URL:** `https://<subdomain>.trycloudflare.com` — **quick tunnel; the current URL is printed by `docker compose logs tunnel`** *(see §4 for making it a permanent hostname with a named tunnel)*
**CI/CD config:** [`.github/workflows/deploy.yml`](./.github/workflows/deploy.yml) · [`.github/workflows/ci.yml`](./.github/workflows/ci.yml)

---

## 1. Chosen Infrastructure

**Docker Compose (app + MariaDB + cloudflared) hosted on a dedicated machine, exposed publicly through a Cloudflare Tunnel.**

| Component | Technology | Role |
| :--- | :--- | :--- |
| Application | Next.js 16 standalone image | Web UI + API routes |
| Database | MariaDB 11 (named volume `db-data`) | Persistent relational storage via Prisma 7 (`@prisma/adapter-mariadb`) |
| Schema migration | `prisma db push` (one-shot `migrate` container) | Applies schema before the app starts |
| Public exposure | `cloudflared` quick/named tunnel | HTTPS URL without opening inbound firewall ports |
| CI/CD | GitHub Actions | Lint/type-check/build on every push; auto-deploy on merge to `main` |

### Why this matches the project's architecture

The assignment's Step 1 decision tree puts this project in the *"complex backend, custom dependencies, or microservices → containerization"* branch, for three concrete reasons found in the codebase:

1. **A real relational database with state.** RCC-HIROS is a full HR system (employees, RBAC roles/permissions, leave workflows, evaluations, attendance) on MySQL/MariaDB through Prisma. Serverless PaaS options either don't offer MySQL or push you to a paid external instance.
2. **Local filesystem writes.** Six API routes write/read real files to `uploads/` (employee photos: `src/app/api/employees/[id]/photo/route.ts`; leave documents: `src/app/api/leave-requests/route.ts`; employee files: `src/app/api/employees/[id]/files/route.ts`). PaaS platforms like Vercel give containers a **read-only, ephemeral filesystem** — every upload would silently fail or vanish on the next cold start. A Docker named volume (`uploads:`) persists them.
3. **Local hardware dependency.** The biometric kiosk (ZK fingerprint device) talks to a loopback service at `127.0.0.1:8765` (`src/components/biometric/BiometricsCard.tsx`, `src/app/api/biometric/zk/*`). The app must be able to live on the same network as that device — a hard constraint for serverless platforms.

### Cost
**≈ ₱0 / $0 per month.** Docker Engine, MariaDB, and cloudflared are all open-source and free. The host is the team's own machine; a Cloudflare Tunnel costs nothing (quick tunnels need no account at all, and a named tunnel with a permanent `*.trycloudflare.com` or custom hostname is also on the free plan). Compare: Vercel Pro (₱800+/mo for serverless filesystem + longer builds) or AWS ECS Fargate (~$30–60/mo for two 0.5 vCPU tasks + RDS).

### Scaling
- **Vertical:** bump container resources — no code change.
- **Horizontal:** `docker compose up -d --scale app=3` behind the tunnel; the app is stateless (JWT auth, DB in MariaDB, uploads on the shared volume).
- **Migration path to "real" infra:** the same `Dockerfile` deploys unchanged to any VPS, ECS, Cloud Run, or Fly.io — the container is the portable artifact.

---

## 2. Trade-offs & Rejected Alternatives

### Limitations of this setup
| Limitation | Impact | Mitigation |
| :--- | :--- | :--- |
| Host is a single machine | Vertical scaling ceiling; hardware failure = downtime | Containers rebuild in ~minutes from CI; volumes back up with `backup-database.bat` / `backup-all.bat` |
| Downtime when the host is off | Live URL is only as available as the machine | Host chosen for stability; can migrate the identical compose file to a ₱250/mo VPS later |
| No load balancer by default | No automatic failover | Acceptable for a campus-scale HR system (tens of concurrent users) |
| Cloudflare Tunnel dependency | Public reachability depends on Cloudflare | App remains fully functional on the LAN (`127.0.0.1:3000`) even if the tunnel drops |
| Quick tunnel = random hostname | URL changes each restart unless configured | Named tunnel (free) gives a **permanent** hostname — used for submission |

### Why the other class-discussed options were rejected
- **Vercel / Netlify (PaaS):** Excellent for frontend-only or stateless Next.js apps, but rejected here because (a) their serverless filesystem is read-only/ephemeral → all file-upload features break; (b) no MySQL offering → forced migration to a paid external Postgres/MySQL; (c) API routes doing PDF generation (`@react-pdf/renderer`, `src/lib/pdf-export.ts`) risk exceeding serverless function time limits.
- **Cloudflare Pages/Workers:** Static-first platform; long-running Node with local file I/O and a Prisma MariaDB adapter doesn't fit Workers' runtime (V8 isolates, no general Node fs).
- **AWS ECS (or similar managed containers):** Technically capable and the "enterprise" answer, but rejected on cost and complexity for a student project: it needs an ECR registry, task definitions, security groups, an RDS instance, and IAM — roughly $50+/month — while delivering the same container we already run for free.
- **On-premise LAN-only server:** The original dev setup (XAMPP on Windows). Rejected because the assignment requires a **live public URL**, and exposing a campus server to the internet needs port forwarding, TLS, and firewall changes — the Cloudflare Tunnel gives public HTTPS with **zero open inbound ports** (safer and simpler).

---

## 3. CI/CD Pipeline Overview

Manual uploads are not part of the process; every change reaches production through Git.

```
git push / PR                          git push to `main` (merge)
      │                                        │
      ▼                                        ▼
┌─────────────────────┐          ┌─────────────────────────────┐
│  ci.yml             │          │  deploy.yml                 │
│  (ubuntu-latest)    │          │                             │
│ 1. checkout         │          │  Job 1 — "checks" (gate)    │
│ 2. setup-node 22    │          │   same steps as ci.yml:     │
│ 3. npm ci           │          │   npm ci → prisma generate  │
│ 4. prisma generate  │          │   → lint → tsc → build      │
│ 5. npm run lint     │          │          │ needs: passes    │
│ 6. tsc --noEmit     │          │          ▼                  │
│ 7. next build       │          │  Job 2 — "deploy"           │
└─────────────────────┘          │   (self-hosted runner on    │
                                 │    the production host):    │
                                 │ 1. checkout                 │
                                 │ 2. docker compose up -d     │
                                 │    --build --remove-orphans │
                                 │    · build app image        │
                                 │    · migrate: prisma db push│
                                 │    · app: rolling restart   │
                                 │    · tunnel: re-point       │
                                 │ 3. poll /api/health (verify)│
                                 │ 4. print public tunnel URL  │
                                 └─────────────────────────────┘
```

**CI (continuous integration)** — `.github/workflows/ci.yml`, every push & PR:
1. `npm ci` — clean, lockfile-exact dependency install.
2. `npx prisma generate` — regenerates the typed client from `prisma/schema.prisma`.
3. `npm run lint` — ESLint; any violation fails the pipeline.
4. `npx tsc --noEmit` — full type-check.
5. `npm run build` — a real `next build` proves the app compiles.

**CD (continuous deployment)** — `.github/workflows/deploy.yml`, on merge to `main`:
1. **Quality gate:** re-runs all CI checks; a failing lint/type/build **blocks the deploy**.
2. **Build & roll out:** a self-hosted GitHub Actions runner on the production host executes `docker compose up -d --build`, which rebuilds the app image, runs `prisma db push` in a one-shot `migrate` container (schema applied automatically), then restarts the app and tunnel containers.
3. **Verification:** polls `GET /api/health` for up to 5 minutes; on failure the job exits red and dumps container logs — a deploy either verifiably works or visibly fails.

---

## 4. Repository Layout (deployment-related)

```
RCC-HIROS/
├── Dockerfile                    # multi-stage: deps → builder → migrate → runner
├── docker-compose.yml            # app + MariaDB + prisma migrate + cloudflared
├── .dockerignore
├── .env / .env.example           # secrets (gitignored) & template
├── .github/workflows/
│   ├── ci.yml                    # lint + type-check + build on push/PR
│   └── deploy.yml                # auto-deploy on merge to main
└── src/app/api/health/route.ts   # liveness endpoint for HEALTHCHECK & CD gate
```

### Local production-parity run
```bash
cp .env.example .env        # then edit DB_ROOT_PASSWORD and JWT_SECRET
docker compose up -d --build
docker compose logs -f tunnel    # prints the public https://…trycloudflare.com URL
```

### First-time setup on the deployment host
1. **Install Docker Desktop** (Windows) — required once; `docker compose up` then works.
2. **Provision secrets:** place the real `.env` at a fixed path outside the repo (e.g. `C:\rcc-hiros-secrets\.env`) and set the `SECRET_ENV_PATH` repository variable to that path — the deploy workflow copies it into the fresh checkout (see deploy.yml).
3. **Seed the database once** (a brand-new MariaDB volume is empty):
   ```bash
   docker compose run --rm migrate npx tsx prisma/seed.ts
   ```
4. **Register a self-hosted runner:** GitHub → repo → Settings → Actions → Runners → New self-hosted runner (Windows), installed as a **service** so deploys work even when you're not logged in.
5. **(Recommended) Permanent hostname:** create a free *named tunnel* in the Cloudflare Zero Trust dashboard (Networks → Tunnels → Create), paste its token into `.env` as `TUNNEL_TOKEN`, and change the `tunnel` service command in `docker-compose.yml` to `["tunnel", "--no-autoupdate", "run"]`. The random `*.trycloudflare.com` quick-tunnel URL then becomes a fixed hostname that survives restarts.

---

## 5. Post-Deploy Checklist

1. `docker compose ps` — all services `running`/`healthy`.
2. `GET /api/health` returns `{"status":"ok","service":"rcc-hiros",…}`.
3. Log in with the seeded admin account; create an employee; upload a photo and a leave document (verifies DB **and** the `uploads` volume survived the deploy).
4. Submit the tunnel URL + `.github/workflows/deploy.yml` link + this file.

---

## 6. Deployment Journey (Step-by-Step Log)

The deployment was executed iteratively: each step was attempted, verified (or failed visibly), diagnosed, and fixed with a dedicated commit. Every step below links to its **actual evidence** — the commit diff, the files involved, and the CI/CD run logs.

### Step 1 — Environment refactor
**Commit:** [`b9152a6`](https://github.com/Yuuseiii/RCC-HIROS-Jerome/commit/b9152a69473b301b98199874d49b086a1e3f1bb5) · **Files:** [`src/lib/db.ts`](https://github.com/Yuuseiii/RCC-HIROS-Jerome/blob/main/src/lib/db.ts) · [`src/app/api/health/route.ts`](https://github.com/Yuuseiii/RCC-HIROS-Jerome/blob/main/src/app/api/health/route.ts)

Before containerizing, the database credentials hardcoded in `src/lib/db.ts` (`localhost`, empty password) were replaced with `DATABASE_URL` env-var parsing, and a `/api/health` liveness route was added. This decouples the app from any specific host — the same image runs anywhere.

### Step 2 — Containerize & compose stack
**Commit:** [`b9152a6`](https://github.com/Yuuseiii/RCC-HIROS-Jerome/commit/b9152a69473b301b98199874d49b086a1e3f1bb5) · **Files:** [`Dockerfile`](https://github.com/Yuuseiii/RCC-HIROS-Jerome/blob/main/Dockerfile) · [`docker-compose.yml`](https://github.com/Yuuseiii/RCC-HIROS-Jerome/blob/main/docker-compose.yml) · [`.github/workflows/ci.yml`](https://github.com/Yuuseiii/RCC-HIROS-Jerome/blob/main/.github/workflows/ci.yml) · [`.github/workflows/deploy.yml`](https://github.com/Yuuseiii/RCC-HIROS-Jerome/blob/main/.github/workflows/deploy.yml)

Multi-stage `Dockerfile` (deps → builder → migrate → runner on Next.js standalone output) plus a 4-service `docker-compose.yml` (MariaDB with persistent volume → one-shot Prisma migration → app with `uploads` volume → cloudflared tunnel). First `docker compose up -d --build` pulled base images and built successfully.

### Step 3 — CI workflow validation (failed run → fix)
**Failed run (raw log):** [actions/runs/39371118622](https://github.com/Yuuseiii/RCC-HIROS-Jerome/actions/runs/39371118622) ❌ · **Fix commit:** [`04a44bf`](https://github.com/Yuuseiii/RCC-HIROS-Jerome/commit/04a44bf73e27789d0be6474bf326b68a0399f6b8) ✅

The first CI run **failed instantly (0 s)** — GitHub Actions rejects `branches` **and** `branches-ignore` on the same event. Diagnosed from the run's error log; fixed by using `branches-ignore` alone. Subsequent runs went green (`npm ci → prisma generate → lint → tsc → build` — see the green **Pre-deploy checks** job in [run/39371123693](https://github.com/Yuuseiii/RCC-HIROS-Jerome/actions/runs/39371123693)).

### Step 4 — Schema migration fix
**Commit:** [`06374b9`](https://github.com/Yuuseiii/RCC-HIROS-Jerome/commit/06374b91d146d85bfed1581e3b596963e7c05b45) · **File:** [`docker-compose.yml`](https://github.com/Yuuseiii/RCC-HIROS-Jerome/blob/main/docker-compose.yml) (migrate service)

The `migrate` service exited with code 1. Its logs showed Prisma 7 removed the `db push --skip-generate` flag. Removed the flag; migration then completed (exit 0) and the schema was applied to the fresh MariaDB volume automatically.

### Step 5 — Health probe vs. HTTPS redirect
**Commit:** [`06374b9`](https://github.com/Yuuseiii/RCC-HIROS-Jerome/commit/06374b91d146d85bfed1581e3b596963e7c05b45) · **File:** [`src/middleware.ts`](https://github.com/Yuuseiii/RCC-HIROS-Jerome/blob/main/src/middleware.ts) (matcher)

The app container built and started but was marked **unhealthy**. Diagnosis: `/api/health` returned `301 → https://…` because the production middleware redirects non-HTTPS requests — correct through the tunnel (which sets `x-forwarded-proto: https`), but the Docker HEALTHCHECK probes the container directly over plain HTTP, so it looped. Fix: excluded `api/health` from the middleware matcher; the probe then returned `200` and the container went healthy.

### Step 6 — Tunnel command fix
**Commit:** [`92ded3d`](https://github.com/Yuuseiii/RCC-HIROS-Jerome/commit/92ded3ddeb998dc4e75834a15fd858832c9d8de4) · **File:** [`docker-compose.yml`](https://github.com/Yuuseiii/RCC-HIROS-Jerome/blob/main/docker-compose.yml) (tunnel service)

The `tunnel` service crash-looped with *"you need to explicitly pass the --url flag"*. Root cause: the official `cloudflare/cloudflared` image is **scratch-based (no shell)**, so the compose `command` using `sh -c 'if …'` never executed as a shell — cloudflared received the shell script as its arguments. Fix: replaced the conditional with a plain exec-form command, documented how to switch to a named tunnel.

### Step 7 — Seed & end-to-end verification
**Commit:** [`4e22950`](https://github.com/Yuuseiii/RCC-HIROS-Jerome/commit/4e22950c65b1f14a6f4df1565ab06874aa195884) (journey log) · **Script:** [`prisma/seed.ts`](https://github.com/Yuuseiii/RCC-HIROS-Jerome/blob/main/prisma/seed.ts)

The fresh database was seeded (`prisma/seed.ts`: roles, admin account, demo employees, leave-workflow samples). End-to-end verification through the public tunnel URL:
- `GET /api/health` → `200 {"status":"ok",…}`
- `GET /` (login UI) → `200`
- `POST /api/auth/login` with the seeded admin → `200` + signed JWT — proving tunnel → container → API → Prisma → MariaDB → bcrypt → JWT all work in production.

### Lessons learned (reflected in the rubric's "trade-offs" requirement)
1. **Configuration errors fail fast and loudly** — the CI and migration failures surfaced in seconds with precise logs, exactly why the pipeline gates deploys on green checks.
2. **Dev/prod parity matters** — the HTTPS-redirect bug only appeared in the containerized environment (TLS terminates at the tunnel, not the app); local `next dev` never hit it.
3. **Platform constraints are discovered at deploy time** — Prisma 7's removed flag and the scratch-based cloudflared image were both documented platform behaviors that the initial implementation missed.
