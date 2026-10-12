# Restaurant Billing SaaS

Multi-tenant restaurant billing and management SaaS: Standard, Professional and Premium plans, plus a Super Admin portal.
Start with `MORNING.md` for current status. Read `CLAUDE.md` for the house rules and `docs/ARCHITECTURE.md` for the design.

## Quick start (dev)

Prerequisites: Node ≥ 20, pnpm, Docker, Flutter (stable), Dart ≥ 3.6.

```bash
bash infra/scripts/gen-dev-secrets.sh                                     # 1. throwaway secrets → .env.local
docker compose -f infra/docker-compose.yml --env-file .env.local up -d db # 2. Postgres 16 on localhost:5433
pnpm install && pnpm --filter @rsaas/api prisma:generate
pnpm --filter @rsaas/api db:migrate:deploy && pnpm --filter @rsaas/api db:seed   # 3. migrate + seed
pnpm --filter @rsaas/api start:dev                                        # 4. API on :3000 (docs at /api/docs)
cd apps/admin_web && flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:3000/api/v1   # 5. portal
```

On Windows, use `infra/scripts/gen-dev-secrets.ps1` for step 1.

## Tests

| Suite | Command |
| --- | --- |
| API (needs Postgres) | `pnpm --filter @rsaas/api test` |
| Dart core (golden vectors) | `cd packages/core && dart test` |
| Hub server | `cd packages/hub_server && dart test` |
| UI kit / apps | `flutter test` in `packages/ui_kit`, `apps/admin_web`, `apps/pos_app` |
| Secret scan | `bash infra/scripts/secret-scan.sh` |

## Layout

See `CLAUDE.md` → *Repo layout*.
