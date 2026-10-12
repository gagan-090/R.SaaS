# Cloud API image. Build context: repo root (see infra/docker-compose.yml).
FROM node:22-bookworm-slim AS build
WORKDIR /repo
RUN corepack enable && apt-get update && apt-get install -y --no-install-recommends openssl python3 make g++ && rm -rf /var/lib/apt/lists/*
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml ./
COPY apps/api/package.json apps/api/
RUN pnpm install --frozen-lockfile --filter @rsaas/api
COPY apps/api apps/api
RUN pnpm --filter @rsaas/api exec prisma generate && pnpm --filter @rsaas/api build

FROM node:22-bookworm-slim
WORKDIR /repo
RUN apt-get update && apt-get install -y --no-install-recommends openssl && rm -rf /var/lib/apt/lists/* && corepack enable
COPY --from=build /repo /repo
WORKDIR /repo/apps/api
ENV NODE_ENV=production
USER node
EXPOSE 3000
# Applies pending migrations with the owner URL, then starts as the least-privilege app role.
CMD ["sh", "-c", "node scripts/with-migration-url.js npx prisma migrate deploy && node dist/main.js"]
