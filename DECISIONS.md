# Decisions (one-line ADRs)

Format: date · decision · why · alternative rejected.

- 2026-10-12 · Repo root is this folder (`R.SaaS/`), not a nested `restaurant-saas/` dir · the folder is already the project root holding `docs/` · nesting one level deeper.
- 2026-10-12 · Source docs kept under their real filenames (`Restaurant_Billing_System_Developer_SRS.pdf` etc.), mapped in CLAUDE.md · renaming the client's files is unnecessary churn · renaming to `SRS_v1.0.pdf`.
- 2026-10-12 · Build Specification PDF is treated as authoritative detail under the Playbook · it is the most specific document and is derived from both · ignoring it (the overnight prompt didn't list it).
- 2026-10-12 · `packages/ui_kit/STYLE.md` ("House Plating · Midnight Masala": dark espresso service theme, light paper back-office theme, Fraunces + DM Sans) overrides the overnight prompt's M6 palette/fonts (Lora + Inter, cream) · it is Gagan's newer, more detailed brief and keeps the wine/saffron/cream/olive/ink family for back office · following the older one-line palette.
- 2026-10-12 · Compose Postgres is published on host port **5433** · a native Postgres already listens on 5432 on Gagan's Mac · stopping the user's Postgres.
- 2026-10-12 · Two DB roles: `rsaas_owner` (migrations, seed) and `rsaas_app` (runtime, NOBYPASSRLS, no UPDATE/DELETE on audit_events) · RLS does not apply to table owners, and append-only audit needs a role without those grants · single superuser connection.
- 2026-10-12 · RLS uses transaction-local `set_config('app.tenant_id', …, true)` and `app.platform='on'` for platform-admin requests, via a `db.tenant(...)`/`db.platform(...)` helper that wraps Prisma interactive transactions · pooled connections must not leak tenant context · session-level `SET`.
- 2026-10-12 · Prisma 6.x (not 7) · stable `url = env()` datasource + mature migrate; 7 requires driver adapters/config rewrite · Prisma 7, TypeORM.
- 2026-10-12 · NestJS 11 + zod env validation + @nestjs/throttler + argon2 (Argon2id) + otplib (TOTP) + jsonwebtoken · matches Playbook "Pantry" · passport strategies (more boilerplate for no gain).
- 2026-10-12 · Ed25519 keys are passed as one-line base64 DER (PKCS#8 private / SPKI public) · avoids multi-line PEM in env vars · PEM strings with `\n` escapes.
- 2026-10-12 · License token format: `base64url(json payload).base64url(ed25519 signature)` (compact, JWS-like, alg fixed to Ed25519) · trivially verifiable in Dart and TS without a JOSE dependency · full JWS/JWT library (alg-confusion risk, bigger dep).
