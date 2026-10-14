# MORNING.md — night build 2026-10-12 → 13

Branch `night-build/2026-10-12` (11 commits, nothing on `main`, no remote, so nothing was pushed). Details and pasted test output are in
`PROGRESS.md`. Every architecture or library choice is a one-line ADR in `DECISIONS.md`.

## 1. Summary

| Milestone | Status | Proof (run this session) |
|---|---|---|
| M0 Kitchen setup (monorepo, CI, compose, secret scripts) | **PARTIAL**: Docker Desktop never started, so `docker compose up` is untested | 4 workflows parse; tests ran on a private Postgres on :5433 instead |
| M1 Schema, RLS tenancy, grants, seed | DONE | 6 tenancy tests (tenant A sees nothing of B through any endpoint) |
| M2 Auth, refresh rotation, TOTP MFA, step-up, RBAC, audit, rate limits | DONE | 13 tests (AC-03; auditor 403 on every write route) |
| M3 Restaurant lifecycle, licensing, entitlements, contracts | DONE | 12 tests (AC-01, AC-02); OpenAPI 57 routes + 64 recorded fixtures |
| M4 Money core (paise, GST, discounts, tips, round-off) | DONE | 49 Dart tests, of which 38 are golden vectors; the same 38 pass in TS |
| M5 Branch hub (orders, KOT, reversals, transfer, bills, idempotent payments, pairing, TLS, sync) | DONE | 28 hub tests (AC-04…AC-07-lite) + 4 cloud sync tests |
| M6 UI kit "House Plating" + Super Admin portal P1–P11 | DONE | 6 + 4 widget tests; `flutter build web` ✓ |
| M7 POS app, cashier path (S1–S4, C1–C8) | DONE with gaps (see §4) | 6 widget tests; web compile ✓; **Android APK not built** |
| M8 Printing: ESC/POS 80/58 mm, TCP 9100, PDF fallback | DONE | 8 tests: snapshot receipts checked by hand, fake TCP printer |
| M9, M10 (stretch) | Not started | — |

**Final check (07:01 IST, fresh empty database `rsaas_clean`):** 3 migrations applied, seed OK, API **73/73**, core **49/49**,
hub **36/36**, ui_kit **6/6**, admin_web **4/4**, pos_app **6/6**. Analyze and lint are clean everywhere. Full-history gitleaks scan: 10 commits, **no leaks**.

The tests found and fixed these real bugs:
- Refresh-token reuse revocation was rolled back.
- Restaurant codes raced under concurrent onboarding.
- The TS money port returned `-0` for a zero round-off.
- Lines added in the same millisecond came back in random order.
- Admin portal layouts overflowed at narrow widths.
- On 58 mm paper, receipt columns merged and invoice numbers split mid-number.

## 2. Run it in 5 commands

```bash
bash infra/scripts/gen-dev-secrets.sh            # 1. writes .env.local (prints the dev Super Admin login)
docker compose -f infra/docker-compose.yml --env-file .env.local up -d db   # 2. Postgres 16 on :5433 (UNTESTED here, see §4)
pnpm install && pnpm --filter @rsaas/api prisma:generate && pnpm --filter @rsaas/api db:migrate:deploy && pnpm --filter @rsaas/api db:seed   # 3
pnpm --filter @rsaas/api start:dev                # 4. API on :3000, Swagger at /api/docs
cd apps/admin_web && flutter run -d chrome --web-port 8080 --dart-define=API_BASE_URL=http://localhost:3000/api/v1   # 5. portal
```
Port 8080 matters because `CORS_ORIGINS` defaults to `http://localhost:8080`. The POS app runs with `cd apps/pos_app && flutter run -d windows`
on your Windows PC; pick "This device is the hub" on first start. Tests: `pnpm --filter @rsaas/api test`, `dart test` in `packages/core` and
`packages/hub_server`, `flutter test` in `packages/ui_kit`, `apps/admin_web` and `apps/pos_app`.

## 3. Secrets and configuration

✅ = filled with throwaway dev values by `infra/scripts/gen-dev-secrets.sh` / `.ps1`. Nothing real is in git, and `.env.example` holds placeholders only.

| Variable | Used by | Required for | Where to get it (prod) | Example | gen-dev |
|---|---|---|---|---|---|
| `DATABASE_URL` | API runtime (role `rsaas_app`, RLS applies) | API start | Managed Postgres; app role created by `infra/db-init/01-app-role.sh` | `postgresql://rsaas_app:…@db:5432/rsaas` | ✅ |
| `MIGRATION_DATABASE_URL` | `prisma migrate`, seed (owner role) | deploys | same DB, owner role | `postgresql://rsaas_owner:…@db:5432/rsaas` | ✅ |
| `POSTGRES_PASSWORD` / `APP_DB_PASSWORD` | docker compose db | local and VPS Postgres | generate (`openssl rand -base64 24`) | — | ✅ |
| `JWT_ACCESS_SECRET` | API | API start | generate, ≥ 32 chars | random | ✅ |
| `JWT_REFRESH_SECRET` | API | API start | generate, different from access | random | ✅ |
| `LICENSE_SIGNING_PRIVATE_KEY` | API only (never ship) | issuing licenses | `node -e` Ed25519 keypair → PKCS#8 DER base64; keep offline backup | base64 | ✅ |
| `LICENSE_PUBLIC_KEY` | API → hubs (via `register-hub`) | offline license checks | pair of the above (SPKI DER base64) | base64 | ✅ |
| `MFA_ENCRYPTION_KEY` | API | MFA enrolment | 32 random bytes base64; **rotating it orphans all TOTP secrets** | base64 | ✅ |
| `BOOTSTRAP_SUPERADMIN_EMAIL` / `_PASSWORD` | seed | first Super Admin | your choice; change on first login | `gagan@…` | ✅ |
| `CORS_ORIGINS` | API | admin portal in a browser | portal URL(s) | `https://admin.example.com` | default |
| `PUBLIC_API_URL` | API (email links) | verification emails | public API URL | `https://api.example.com` | default |
| `SMTP_HOST` / `PORT` / `USER` / `PASS`, `MAIL_FROM` | API mailer | real email (dev logs links to the console) | SES / Postmark / Zoho SMTP credentials | `smtp.zoho.in` | — |
| `S3_ENDPOINT` / `REGION` / `BUCKET` / `ACCESS_KEY_ID` / `SECRET_ACCESS_KEY` | (not used yet) | menu images, backups off-site | S3 / R2 / Wasabi | `ap-south-1` | — |
| `SENTRY_DSN_API` / `SENTRY_DSN_FLUTTER` | (not wired yet) | error monitoring | sentry.io project settings | `https://…@sentry.io/1` | — |
| `API_BASE_URL` | Flutter `--dart-define` | admin_web, POS sign-in to cloud | public API URL + `/api/v1` | `http://localhost:3000/api/v1` | default |
| `HUB_BRANCH_ID`, `HUB_BRANCH_CODE`, `HUB_CLOUD_DEVICE_TOKEN`, `CLOUD_API_URL`, `HUB_DATA_DIR`, `HUB_PORT` | standalone `bin/hub.dart` (POS hub mode sets these itself) | running the hub headless | branch from the portal; token from `POST /devices/register-hub` (shown once) | `BR01`, `8443` | — |
| `DEPLOY_HOST` / `DEPLOY_USER` / `DEPLOY_SSH_KEY` | CI deploy (**no deploy workflow yet**) | VPS deploys | your VPS; a deploy-only SSH key as a GitHub secret | `203.0.113.10` | — |
| `ANDROID_KEYSTORE_BASE64` / `_PASSWORD`, `ANDROID_KEY_ALIAS` / `_PASSWORD` | CI release (**not yet**) | signed APK/AAB | `keytool -genkey …`; base64 into GitHub secrets; **back it up, it cannot be replaced** | — | — |
| `WINDOWS_CERT_PFX_BASE64` / `_PASSWORD` | CI release (**not yet**) | signed Windows installer | code-signing cert from a CA (paid, so your call) | — | — |

## 4. Blocked / needs Gagan

1. **Docker Desktop daemon never came up.** `docker info` hung and there was no socket; it probably needs its first-run GUI and licence click.
   Open Docker Desktop once, then run command 2 above. Until then, compose, Caddy and `backup.sh`/`restore.sh` are untested.
   Overnight tests used a private Postgres 18 cluster in `.localdb/pg` (gitignored), started with
   `/Library/PostgreSQL/18/bin/pg_ctl -D .localdb/pg -o "-p 5433 -k /tmp" start`. It is still running (`… stop` to stop it). It holds databases
   `rsaas` (dev) and `rsaas_clean` (final check). Both are safe to drop.
2. **Android release APK: built (13 Oct).** `release/HousePlatingPOS-0.1.0-release.apk` (gitignored, 42.6 MB, arm + arm64,
   signed with the new upload key in `apps/pos_app/android/keystore/` + `key.properties`, both gitignored; **back them up**).
   Phone setup and every role: `docs/ANDROID.md`. Not yet run on a physical phone (none was connected). Disk is still nearly full
   (~1.4 GB free); `~/.gradle` is 23 GB if you need space.
3. **Windows build needs your Windows PC** (`flutter build windows`). It has never been compiled for Windows; only web, analyze and widget tests ran.
4. **Xcode is incomplete**, so there are no macOS desktop builds. That is not needed for the product.
5. **POS gaps**, not built: camera QR scanning (paste the payload or type IP + code instead), C10 shift summary and its print,
   waiter assigned-table scoping, KDS recipe/approval/stock screens (K2–K4). Kitchen display, reprint, adjustments, printers, tips and
   all six role homes are built (see `docs/SCREEN_MAP.md`). Hub mode on Android runs while the app is open (no background service yet).
6. **Cloud side of sync is storage only.** Hub events land in `sync_events` and are deduped. Projection into cloud orders/bills and the reconciliation report is Day-10 work.
7. Cleanup you can do: delete the old typo folder `pakages/` (its `style.md` was copied to `packages/ui_kit/STYLE.md`) and `docs/*(1).pdf`
   (byte-identical duplicate of the playbook). Both are gitignored, not deleted.

## 5. Decisions to confirm (all in DECISIONS.md)

- **Round-off is half-up to the rupee**: exactly 50 paise rounds up.
- **The invoice number is issued when the bill is generated**, not at payment. Numbers stay gap-free, but a generated-then-cancelled bill still uses a number.
- **Admin portal tokens live in memory only**: reloading the browser means signing in again. This is safer against XSS, at some cost to convenience.
- **Plan prices are placeholders (₹0)** in the seed. Set the real Standard / Professional / Premium prices.
- **Single-printer branches print KOTs on the bill printer**, and receipts show "Rs" instead of ₹ because printer code pages vary.
- The Build Spec is treated as authoritative over the prompt where they differ, and `STYLE.md` "House Plating" over the prompt's Lora/Inter/cream palette.

## 6. Contracts ready for Aditya

- `packages/contracts/openapi.json`: 57 cloud routes, request schemas derived from the zod validators.
  Regenerate with `AUTH_RATE_LIMIT_PER_MIN=10000 NODE_ENV=test pnpm --filter @rsaas/api openapi` (regenerated after the last API change).
- `packages/contracts/fixtures/`: 64 real recorded responses plus `INDEX.md`. `apps/admin_web/test/fixture_api.dart` shows how to drive widget tests from them.
- `packages/ui_kit` and `STYLE.md`: tokens, both themes and components (buttons, StatusChip, OfflineBanner, states, dialogs, keypad, TableTile, OrderCard…).
- Hub LAN API: routes are in `packages/hub_server/lib/src/server.dart`. There is **no OpenAPI for the hub yet**, so a good first task is writing one.
  `apps/pos_app/test/fake_hub.dart` is a working fake of it.
- `packages/core/test/golden/*.json`: billing vectors that any UI total must match. `packages/hub_server/test/golden_receipts/`: receipt layouts.
- `docs/SCREEN_MAP.md`: every screen, its route and API, and its build status.

## 7. Suggested next 3 tasks (Day 2 of the playbook)

1. **Gagan:** unblock the machine (Docker first run, disk space, Android licences), run §2 end to end, and review `ARCHITECTURE.md`,
   `PERMISSIONS.md` (the generated permission matrix) and the §5 decisions. Then build the remaining tenant-side auth, users and RBAC routes
   (owner/staff management, PIN set and reset) on the M2 guards, plus the seed for a demo branch with menu, tables and staff.
2. **Aditya:** in `ui_kit`, add the missing components (keyboard-shortcut hints, toast variants) and polish the login screens (P1/P2 and S3) and
   the portal shell against `STYLE.md`, using the contract fixtures. Then wire the C8 reprint/PDF buttons and the C9 adjustment dialog to the existing hub routes.
3. **Both:** write the hub OpenAPI (v1) from `server.dart`, then run the Windows POS build plus one real thermal printer test print
   (T3 route `POST /printers/bill/test`) on the restaurant LAN.


## Open items from the 14 Oct staff-portal work (honest list)

1. **Plan editor repaired on 14 Oct:** Super Admin → Plans → Edit now exposes Staff web portal, Custom roles,
   Visual floor editor, Excel import and Expenses under "Web portal & management". The local `rsaas_dev` Premium plan
   has Staff web portal, Visual floor editor and Excel import enabled; its four active licenses were re-signed with
   unchanged dates, prices and limits, and the repair was audited. Refresh the rebuilt web page and sign in again.
   Other environments still require their Super Admin to enable the desired features. Custom roles and Expenses
   remain controlled by their own existing plan selections.
2. **Web order entry and billing are not built.** Cashier and waiter portals show live tables, open orders, today's bills
   and payments, but orders, KOTs, bills and payments are taken on the POS app (the offline-first single writer).
3. **Batch / expiry balances are approximate.** Kitchen use and sales do not say which batch they used (no FIFO), so a
   batch's remaining quantity only falls when a movement names that batch; expiry alerts can list batches already used.
4. **Stock moves when the paid bill reaches the cloud**, not on the hub; while the hub is offline the cloud stock lags.
   Inventory is restaurant-wide (not per branch).
5. **One email = one restaurant**: no multi-restaurant memberships, so no restaurant picker.
6. **Shift / break tracking does not exist** in the app, so it is not in the audit view.
7. **Employee invite emails**: the Resend sandbox only delivers to the account's own address until a domain is
   verified; for other employees the owner sees the one-time link to pass on.
8. **Intermittent API test failure**: twice in ~6 *parallel* runs (`npx jest`, not the official serial `pnpm test`) one
   test failed in a different suite each time (restaurants.spec, console.spec); never reproduced alone or serially.
   Likely suites sharing the one test database in parallel; not yet diagnosed.
9. **Not on the phone yet**: `release/HousePlatingPOS-0.6.0-release.apk` is built; the phone was not connected.
10. The handwritten notes mentioned in the request were not attached, so only the written requirements were used.
11. Floor editor has no undo (Cancel reverts to the last save). Import error report is CSV, not .xlsx. Imports are
    capped at 5 MB / 20,000 rows per sheet.
