# Progress — night build 2026-10-12

## Toolchain (checked 2026-10-12 ~22:45 IST, macOS 26.6.2 x86_64)
| Tool | Version | Note |
| --- | --- | --- |
| git | 2.50.1 | |
| node | v24.11.0 | CI uses Node 22 |
| pnpm | 11.23.0 | |
| dart | 3.12.2 | |
| flutter | 3.44.2 stable | |
| docker | Docker Desktop 4.88.0 installed; daemon did not come up during the session (`docker info` hung) | see MORNING.md Blocked |
| postgres | local Postgres 18 binaries used to run a private throwaway cluster on :5433 in `.localdb/` (gitignored) for tests | compose uses postgres:16 |
| gitleaks | installed via Homebrew during session | |

## Milestones

### M0 Kitchen setup — PARTIAL (23:11 IST)
Built: monorepo (pnpm workspace + Dart workspace), `.gitignore`, `.editorconfig`, `.prettierrc`, `.env.example` (every var commented),
`infra/scripts/gen-dev-secrets.sh/.ps1`, `secret-scan.sh` (gitleaks; grep fallback) + local pre-commit hook, `infra/docker-compose.yml`
(postgres:16 + healthcheck, api, caddy profile), `infra/db-init/01-app-role.sh`, Caddyfile, backup/restore scripts, 4 workflows, README.
Verified: all 4 workflow files + compose parse as valid YAML (`ruby -ryaml`).
NOT verified: `docker compose up -d db` — Docker Desktop daemon never came up on this Mac (see MORNING.md → Blocked).
A private Postgres 18 cluster on :5433 (`.localdb/`, gitignored) stands in for tests.

### M1 Schema and tenancy — DONE (23:11 IST)
Built: Prisma schema (all listed entities + RefreshToken, Notification, RestaurantRegistration, SyncEvent; hub-side SyncOutbox lives in SQLite),
RLS migration (`app_tenant_ok()` policy on every tenant table), `rsaas_app` least-privilege role, append-only audit (grants + trigger),
paid-bill immutability trigger, config cursor sequence + triggers, seed (3 plans, Super Admin from env, Demo Dhaba), `docs/ARCHITECTURE.md`,
generated `docs/PERMISSIONS.md`.
Test: `pnpm --filter @rsaas/api test -- test/tenancy.spec.ts` → **6 passed** (cross-tenant isolation incl. every GET endpoint, WITH CHECK, audit append-only, paid bill immutable).

### M2 Auth, RBAC, MFA, audit — DONE (23:15 IST)
Built: login (Argon2id, lockout 5→15 min), JWT access 15 min, rotating hashed refresh with reuse detection, logout, TOTP enrol/confirm,
10 hashed recovery codes, encrypted TOTP secrets, step-up, MFA reset (permission + step-up + audit + notification), platform admin invite/accept,
roles with self-escalation guards, permission/feature guards (undeclared routes refused), audit interceptor with redaction, auth rate limit.
Test: `test/auth.spec.ts` + `test/ratelimit.spec.ts` → **13 passed** (AC-03; auditor 403 on all 30+ write routes for platform + restaurant auditor).
Bug found and fixed by the tests: refresh-reuse revocation was rolled back with the throwing transaction.

### M3 Restaurant lifecycle and licensing — DONE (23:24 IST)
Built: register → emailed verification link (console mailer in dev, SMTP when `SMTP_HOST` set) → tenant + BR01 branch + owner + signed license;
list/search/filter/sort/paginate; detail; edit; activate/suspend/block/reactivate with reason; plans CRUD; license issue/renew/upgrade/downgrade/revoke;
Ed25519 token; `@RequiresFeature()`; grace (7 days) then read-only; payments; tenant setup routes (profile, floors, tables, tax, menu, users, audit);
hub registration + `/sync/push|pull|status`. `packages/contracts/openapi.json` (57 routes, zod-derived request schemas) + 64 recorded fixtures.
Test: `test/restaurants.spec.ts` → **12 passed** (AC-01, AC-02 incl. tampered token, grace, read-only, blocked, revoked, upgrade).
Bug found and fixed: tenant code from `count(*)` raced under parallel onboarding → now a sequence.

API suite summary (23:24 IST):
```
PASS test/auth.spec.ts
PASS test/restaurants.spec.ts
PASS test/tenancy.spec.ts
PASS test/ratelimit.spec.ts
Test Suites: 4 passed, 4 total
Tests:       31 passed, 31 total
```
