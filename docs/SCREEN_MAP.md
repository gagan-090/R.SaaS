# Screen map

Every screen from Build Specification §11–§12, where it lives, and which API it uses. Style: `packages/ui_kit/STYLE.md`. The back-office (light) theme is for the portal; the service (dark) theme is for the POS.
Status: **Built** = implemented and covered by widget tests · **Shell** = navigable with real data, polish pending · **Planned** = not started.

## Super Admin portal — `apps/admin_web` (Flutter Web, back-office theme)

| # | Screen | Route | API (packages/contracts) | Status |
| --- | --- | --- | --- | --- |
| P1 | Login | `/login` | `POST /auth/login` | Built (test: wrong password, success path) |
| P2 | MFA verify / first-time enrolment with QR + 10 recovery codes | `/mfa` | `POST /auth/mfa/verify`, `POST /me/mfa/enroll`, `POST /me/mfa/confirm` | Built (test: verify path) |
| P3 | Dashboard: active / suspended / blocked / expiring in 30 days, recent audit | `/` | `GET /restaurants?status=…`, `GET /restaurants?expiresBefore=…`, `GET /platform/audit` | Built |
| P4 | Restaurants list: search, filter by status / plan / owner, paginate | `/restaurants` | `GET /restaurants` | Built (test: filter sends `status`) |
| P5 | Register restaurant (sends verification email) | dialog on P4 | `POST /restaurants` | Built |
| P6 | Restaurant detail: profile, status actions with reason, branches, devices, payments, audit tab | `/restaurants/:id` | `GET /restaurants/:id`, `POST /restaurants/:id/status`, `GET /platform/audit?tenantId=` | Built (test: suspend needs a reason) |
| P7 | License actions: issue / renew / upgrade / downgrade / revoke with reason; record payment | panel on P6 | `POST /restaurants/:id/licenses`, `POST /restaurants/:id/payments` | Built |
| P8 | Plans with feature flags and limits | `/plans` | `GET /plans` (edit: `POST/PATCH /plans`, API only for now) | Shell (read-only UI) |
| P9 | Platform admins: invite, edit roles, deactivate | `/admins` | `GET/POST /platform/admins`, `PATCH /platform/admins/:id/roles`, `POST …/deactivate`, `GET /platform/roles` | Built |
| P10 | MFA reset: warning → reason → step-up (password + own TOTP) → toast notes the notification | menu on P9 | `POST /auth/step-up`, `POST /platform/admins/:id/mfa/reset` (`X-Step-Up-Token`) | Built (test: header carries the step-up token) |
| P11 | Audit viewer: filter by action / restaurant; expand for before/after | `/audit` | `GET /platform/audit` | Built (CSV export: Planned) |

Every portal screen uses `AsyncView` for loading, empty and error states. Every destructive action opens `ReasonDialog`.

## POS app — `apps/pos_app` (Flutter Windows + Android, service theme)

| # | Screen | Role | Plan | Hub API | Status |
| --- | --- | --- | --- | --- | --- |
| S1 | Device setup: "This device is the hub" / pair with hub (QR or IP + code) | all | All | `GET /pairing/info`, `POST /pairing/claim` | Built — QR payload paste or IP + code; camera scan not built (test: pairing stores the device token) |
| S2 | Hub status: pairing QR, paired devices, sync counts, license state | hub | All | `GET /sync/status` | Built (embedded hub on IO platforms) |
| S3 | Staff login: user tiles + PIN pad | all | All | `POST /session/login` | Built (test: wrong then right PIN) |
| S4 | Status bar: hub online/offline, sync pending/failed, license banner | all | All | `GET /health`, WS `/events` | Built (test: hub + sync chips) |
| C1 | Table map: free / occupied / bill printed, running totals | cashier | All | `GET /state`, WS | Built |
| C2 | Order screen: category rail, item grid, order panel, KOT | cashier | All | `POST /orders`, `POST /orders/:id/lines`, `PATCH …/lines/:id`, `POST /orders/:id/kot` | Built (test: order + KOT) |
| C3 | Table transfer | cashier | All | `POST /orders/:id/transfer` | Built |
| C4 | Reversal dialog: reason required, PIN pad if sent | cashier | All | `POST /orders/:id/lines/:id/reverse` | Built (test: reason required, owner PIN for sent line) |
| C5 | Bill preview: lines, subtotal, discount, CGST, SGST, tip, round-off, total | cashier | All | `POST /orders/:id/bill` | Built |
| C6 | Payment: cash keypad + change, UPI, card, split across modes | cashier | All | `POST /bills/:id/payments` (`Idempotency-Key`) | Built (tests: split UPI + cash with change; retry reuses the same idempotency key) |
| C7 | Tip: waiter picker (defaults to the order's waiter) | cashier | All | `POST /bills/:id/tip` | Built (test: tip to a waiter) |
| C8 | Bill history: today's bills, reprint | cashier | All | `GET /bills?date=`, `POST /bills/:id/print` | Built (test: owner reprint prints DUPLICATE; no printer → message) |
| C9 | Adjustment dialog (PIN) | cashier | All | `POST /bills/:id/adjustments` | Built from C8 (tests: owner posts directly; cashier needs owner + PIN) |
| C10 | Shift summary | cashier | All | — | Planned |
| W1–W4 | Waiter: my tables, take order, order status, my tips | waiter | Pro+ | same order routes, `GET /reports/tips` (own only) | Built on C1/C2: waiter opens tables as themselves, sends KOT, sees KOT status (READY), cannot bill; Tips shows own tips. Assigned-table scoping not built |
| K1 | KDS queue: tickets with table, waiter, age, notes, cancelled lines; Start → Ready → Served | chef | Premium | `GET /kds/tickets`, `POST /kds/tickets/:id/status` | Built (hub tests + widget test: chef moves ticket, waiter sees READY) |
| K2–K4 | Recipe editor, approval inbox, kitchen stock | chef | Premium | — | Planned (Days 14–16) |
| O1–O6 | Owner dashboard, reports, menu management, publish, staff, franchise invoice | owner | All / Premium | cloud tenant routes | Planned |
| T0 | IT admin home: printers, hub & devices, sync health | IT admin | Premium | — | Built |
| T3 | Printers: bill / kitchen printer IP, port, 80/58 mm, test print | IT admin, owner | All | `GET/PUT /printers`, `POST /printers/:target/test` | Built (test: IT admin saves + test print; cashier refused by hub) |
| T1, T2, T4, T5 | Devices list, floors & tables editor, inventory, shifts | IT admin | All / Premium | cloud tenant routes | Planned |
| A0 | Auditor: read-only table map, orders and bill history (no write buttons; hub refuses writes) | auditor | Premium | read routes | Built (test + e2e) |
| A1–A2 | Audit log, read-only reports | auditor | Premium | `GET /audit` | Planned |

Shared requirements: loading, empty and error states on every screen; Windows keyboard shortcuts for the cashier; touch targets of at least 48 dp on Android.

Phones (< 720 dp wide): the order screen becomes Menu / Order tabs, the status bar compacts to icons, staff tiles shrink, and the bill screen is one column. Wide screens (≥ 900 dp) show bill totals and the payment keypad side by side so Pay is always visible. `test/roles_test.dart` runs every role at 1280×800, 360×740 and 411×891 and fails on any overflow.

Role homes after PIN login: owner / cashier / waiter / auditor → table map; chef → K1 kitchen display; IT admin → T0 setup. The status-bar menu lists only what the role may open (Tables, Kitchen display, Bill history, Tips, Printers, Hub & devices).
