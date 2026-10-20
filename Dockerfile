# ═══════════════════════════════════════════════════════════════
# RCC-HIROS — Multi-stage production image
# Stage 1 (deps):     install all deps (incl. prisma CLI, devDeps)
# Stage 2 (builder):  generate prisma client + next build (standalone)
# Stage 3 (migrate):  reused by docker-compose to run `prisma db push`
# Stage 4 (runner):   slim runtime with only the standalone server
# ═══════════════════════════════════════════════════════════════

FROM node:22-bookworm-slim AS base
WORKDIR /app
# openssl is required by prisma engines; ca-certificates by HTTPS fetches
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── Stage 1: dependencies ──────────────────────────────────────
FROM base AS deps
COPY package.json package-lock.json ./
RUN npm ci

# ── Stage 2: build ─────────────────────────────────────────────
FROM deps AS builder
COPY . .

# prisma-client generation + next build need these present
ENV DATABASE_URL="mysql://placeholder:placeholder@localhost:3306/rcc_hiros"
ARG JWT_SECRET="build-time-placeholder-not-used-at-runtime"
ENV JWT_SECRET=$JWT_SECRET
ENV NEXT_TELEMETRY_DISABLED=1

RUN npx prisma generate
RUN npm run build

# ── Stage 3: migration image (target used by the `migrate` service) ──
FROM builder AS migrate
# docker-compose overrides the command with `npx prisma db push`

# ── Stage 4: production runtime ────────────────────────────────
FROM base AS runner
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

# Standalone output: server.js + pruned node_modules
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public

# Persistent data dirs (mounted as volumes in compose)
RUN mkdir -p /app/uploads /app/uploads/employees /app/uploads/leave-docs

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3000/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "server.js"]
