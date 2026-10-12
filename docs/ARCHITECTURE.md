# Architecture

Restaurant Billing SaaS is one multi-tenant product made of a cloud API, a Super Admin web portal, and a Flutter POS app that becomes the **branch hub** on one device per branch. The cloud owns master data; the hub owns live operations. Offline LAN is the normal way the restaurant runs, not a fallback.

Sources: Kitchen Playbook §04–05 (decisions), Build Specification §02, §05, §09–10 (detail), SRS v1.0 (baseline).

## Components

```
                    Super Admin portal (Flutter Web, apps/admin_web)
                                   │ HTTPS /api/v1 (JWT, TOTP MFA)
                                   ▼
  ┌──────────────────────── Cloud (India region) ─────────────────────────┐
  │  Cloud API — NestJS + Prisma (apps/api)                                │
  │   auth · RBAC · MFA · licensing (Ed25519) · audit · restaurants ·      │
  │   menu/tables master data · /sync/push · /sync/pull · reports          │
  │  PostgreSQL 16 — RLS on tenant_id · append-only audit_events           │
  │  Object storage (S3 Mumbai / R2) — menu images (WebP ≤ 1 MB), PDFs     │
  └───────────────────────────────▲───────────────────────────────────────┘
          up: outbox push (orders, bills, payments, stock)  │  down: config pull by cursor
                                                            │  (menu, tax, users, tables, license token)
  ┌──────────────────── Restaurant branch (Wi-Fi LAN) ─────┴──────────────┐
  │  Branch hub = POS app in Hub mode on the cashier PC (packages/hub_server)
  │   Dart shelf HTTP + WebSocket · SQLite (drift) · sync outbox           │
  │   verifies signed license offline · serialises payments ·              │
  │   issues gap-free invoice numbers · ESC/POS printing                   │
  │      ▲ pinned TLS + device token        ▲                ▲             │
  │  Cashier terminals    Waiter phones    Kitchen display   Printers :9100│
  └────────────────────────────────────────────────────────────────────────┘
```

| Path | Role | Tech |
| --- | --- | --- |
| `apps/api` | Cloud API, single writer for tenants/licenses/users/roles/plans/menu/tax/tables | NestJS 11, Prisma 6, Postgres 16 |
| `apps/admin_web` | Super Admin portal | Flutter Web |
| `apps/pos_app` | Every restaurant-side screen; starts the hub in Hub mode | Flutter (Windows, Android) |
| `packages/core` | Money (paise), GST, totals, validation, golden vectors — shared by hub and clients | Dart |
| `packages/hub_server` | Branch hub: HTTP + WebSocket, SQLite, outbox, pairing, printing | Dart shelf, drift |
| `packages/ui_kit` | "House Plating" design system (`STYLE.md`) | Flutter |
| `packages/contracts` | OpenAPI generated from the API + mock fixtures for screens | OpenAPI 3 |

## Single writer per data type

| Data | Writer | Flow |
| --- | --- | --- |
| Tenants, licenses, users, roles, plans, menu, tax rules, tables, published recipes | Cloud | Cloud → hub via `GET /sync/pull?since=<cursor>` |
| Orders, bills, payments, reversals, table transfers, KDS tickets, stock movements, shifts | Branch hub | Hub → cloud via `POST /sync/push` (outbox) |
| Audit events | Where the action happened | Hub events pushed; cloud stores permanently |

**Pull cursor.** Every insert/update of cloud-owned config gets `seq = nextval('config_seq')` from a trigger. The hub stores the highest `seq` it has applied and asks for `since=<seq>`. Deletes are soft (`deleted = true`) so tombstones travel through the same cursor. The response also carries the current signed license token.

**Push.** Each hub write and its outbox event (UUIDv7 `event_id`) commit in one SQLite transaction. A worker pushes batches of up to 200 events, with exponential backoff up to 5 minutes. The cloud stores each event once (`sync_events.event_id` primary key), so a replay returns `duplicate`. Events the cloud cannot accept go to `sync_conflicts` with a reason and return `rejected`; the hub stops retrying them.

## Tenancy

- Every restaurant-scoped table carries `tenant_id`; branch-scoped tables also carry `branch_id`.
- Postgres RLS is enabled on every tenant table with one policy: `app_tenant_ok(tenant_id)`, which is true when `app.tenant_id` equals the row's tenant **or** `app.platform = 'on'`.
- The API connects as **`rsaas_app`**: `NOSUPERUSER NOBYPASSRLS`, not the table owner, so RLS always applies. Migrations and seed run as `rsaas_owner`.
- All data access goes through `DbService.tenant(tenantId, fn)` or `DbService.platform(fn)`. Both open a transaction and use `set_config(..., true)`, so the context is transaction-local and never leaks across pooled connections. Without a context, `rsaas_app` sees zero tenant rows.
- Tests prove: zero rows of tenant B under tenant A, `WITH CHECK` blocks cross-tenant inserts, and every GET endpoint called by tenant A's owner returns nothing belonging to tenant B (`apps/api/test/tenancy.spec.ts`).

## Security model

| Concern | Implementation |
| --- | --- |
| Passwords | Argon2id (m=19 MiB, t=2, p=1) |
| Sessions | JWT access token, HS256, 15 min (`JWT_ACCESS_SECRET`). Refresh tokens are opaque, stored as SHA-256 hashes, and rotate on every use. Reusing a rotated token revokes the whole family. |
| MFA | TOTP (otplib, ±1 step, replay guard per step). Mandatory for platform admins, who must enrol at first login. 10 single-use recovery codes, stored hashed. Secrets are AES-256-GCM encrypted with `MFA_ENCRYPTION_KEY`. |
| Step-up | `POST /auth/step-up` (password + TOTP) issues a 5-minute token. MFA reset requires it plus `platform.mfa.reset`, and writes an audit event and a `notifications` row in the same transaction. |
| Lockout and rate limits | 5 failed logins lock the account for 15 min. Auth routes are limited to 10/min/IP (`AUTH_RATE_LIMIT_PER_MIN`), all other routes to 300/min (`API_RATE_LIMIT_PER_MIN`). |
| RBAC | Permission keys per route (`@RequirePermissions`). Undeclared routes are refused. Restaurant roles map to keys in `permissions.ts`. Branch scope comes from `branch_ids`. |
| Entitlements | `@RequiresFeature(flag)` checks the flag inside the Ed25519-signed license token. Writes are refused when the token is read-only. |
| Audit | `AuditInterceptor` records each `@Audited` write after it succeeds: actor, tenant, branch, action, object, before/after, reason, session, device, IP, UTC time. Values are redacted for anything that looks like a password, token, secret, PIN, TOTP or card. `rsaas_app` has INSERT/SELECT only, and a trigger blocks UPDATE/DELETE even for the owner. |
| Paid bills | A trigger blocks UPDATE/DELETE on `bills` where `status = 'paid'`. Corrections are `bill_adjustments`. |
| Secrets | Environment only, validated by zod at startup (`src/config/env.ts`), which fails fast naming the variable. `.env.example` is documented. `gitleaks` runs in CI. |

## License token

`base64url(JSON payload) "." base64url(Ed25519 signature)`. The payload is `{v, lic, tid, plan, features[], limits{}, nbf, exp, grace_days, iat}`. The cloud signs it with `LICENSE_SIGNING_PRIVATE_KEY`. The hub verifies it offline with `LICENSE_PUBLIC_KEY`.

State over time: `not_started` → `active` (until `exp`) → `grace` (7 days, full access, renewal banner) → `read_only` (history and reports only). A suspended or blocked tenant is read-only immediately. Revoking the license also makes the tenant read-only.

## Money

Every amount is integer paise end to end. The rules live in `packages/core` and are mirrored in `apps/api/src/money` for reconciliation only. Both are tested against the same golden vectors (`packages/core/test/golden/*.json`).

- Line amount = price snapshot × qty.
- A discount comes off the taxable subtotal. It is spread across lines in proportion to their amount; the last line absorbs the remainder.
- Each line's GST is rounded half-up, then split into CGST and SGST (an odd paisa goes to CGST).
- A tip is added after tax and is not taxed.
- Round-off to the nearest rupee is a separate visible line.

## Invoice numbers

Issued only by the hub when a bill closes: `<branch code>/<FY>/<6-digit seq>`, e.g. `BR01/26-27/000123`. The financial year runs April to March. Numbers come from `invoice_counters` in the same SQLite transaction as the bill, so they are gap-free and never reused.

## Hub off / failure cases

Build Spec §10 lists the failure cases. If the hub is switched off, other devices show "Kitchen hub offline" and stop taking orders, so there is never a second writer. If the internet is down but Wi-Fi is up, everything keeps working and the outbox drains when the connection returns. Clients retry with the same idempotency keys.
