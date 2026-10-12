# CLAUDE.md — rules for every session in this repo

Read `PROGRESS.md` first (resume from the first unfinished milestone), then `DECISIONS.md`.
Source documents, in order of authority: `docs/Restaurant_SaaS_Kitchen_Playbook.pdf` (decisions) →
`docs/Restaurant_SaaS_Build_Specification.pdf` (detail) → `docs/Restaurant_Billing_System_Developer_SRS.pdf` (baseline).
Follow `packages/ui_kit/STYLE.md` for every screen.

## Non-negotiables
- **Secrets**: never commit a real secret, key, password, token or certificate. Secrets come only from env vars,
  validated at startup (zod in `apps/api/src/config/env.ts`); missing var → fail fast naming it. `.env.example` lists
  every var with a comment, never real values. Dev values come from `infra/scripts/gen-dev-secrets.sh` into `.env.local`
  (gitignored with `*.pem *.pfx *.jks *.keystore`). Run `infra/scripts/secret-scan.sh` before every commit; abort on a hit.
- **Unattended safety**: no deploys, no remotes other than `origin`, no purchases, no cloud accounts, no paid APIs,
  nothing outside this repo. Never force-push or rewrite history. Commit to `night-build/2026-10-12`, never `main`.
- **Money** is integer paise end to end. No floats in money paths.
- **Tenancy**: every restaurant-scoped table has `tenant_id`; branch-scoped tables also `branch_id`. Postgres RLS
  enforces it (`app.tenant_id` set per transaction); the API runtime role `rsaas_app` is NOT the table owner.
- **Permissions** are enforced on the server (API guards / hub checks), never only by hiding UI.
- **Audit** is append-only: `rsaas_app` has INSERT/SELECT only on `audit_events`. Never log passwords, tokens,
  MFA secrets or card data.
- **Paid bills are never edited**; corrections are `BillAdjustment` rows.
- **Payments** carry an idempotency key; a repeated key returns the first result.
- **Honesty**: a milestone is done only when its tests ran and passed in this session; paste the summary into PROGRESS.md.
  No hidden TODOs claiming completion — unfinished work is listed in MORNING.md and stubbed with a `NotImplemented` error.

## Repo layout
```
apps/api/            NestJS + Prisma cloud API (TypeScript, pnpm)
apps/pos_app/        Flutter: Windows + Android (cashier, waiter, KDS, owner, hub mode)
apps/admin_web/      Flutter Web: Super Admin portal
packages/core/       Dart: models, money (paise), GST, totals, validation, golden vectors
packages/hub_server/ Dart: shelf server + WebSocket, drift (SQLite), outbox
packages/ui_kit/     Flutter: "House Plating" design system (STYLE.md)
packages/contracts/  OpenAPI spec (generated from the API) + mock JSON fixtures
infra/               docker-compose.yml, caddy/Caddyfile, db-init/, scripts/
.github/workflows/   api.yml, dart.yml, flutter.yml, secret-scan.yml
docs/                source PDFs, ARCHITECTURE.md, PERMISSIONS.md, SCREEN_MAP.md
```
Workspaces: pnpm (TypeScript) and a Dart pub workspace driven by melos (root `pubspec.yaml`).

## Working loop
Small step → code + test → run → fix → commit (conventional message) when green. Update PROGRESS.md after each
milestone; log each architecture/library choice as a one-line ADR in DECISIONS.md.
