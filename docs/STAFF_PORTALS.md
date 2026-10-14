# Owner dashboard and staff web portals

How the restaurant side of House Plating works after the 14 Oct 2026 extension: employees and web sign-in, roles,
plan control, menu sizes, the floor editor, inventory, Excel import, the auditor portal and role dashboards.
Code paths are given so every rule can be checked.

## 1. Hierarchy, plans and permissions

To enable the new features on an existing plan: Super Admin → Plans → Edit → **Web portal & management**.
Choose **Staff web portal (email + PIN)**, **Visual floor editor (drag tables & chairs)** and
**Excel import (menu & inventory)** as needed, then Save. Existing active licenses update immediately;
restaurant users should sign in again to refresh their available actions. In Staff, **Copy sign-in link**
opens the employee login mode directly. Each employee still needs an email, a valid PIN and Web access enabled.
In Floors & tables choose **Edit floor plan**, drag the tables, then **Save plan**. Dragging a table moves
all its chairs with it, including while **Move chairs** is on. In that mode, dragging an individual chair
adjusts only that chair; its offset is retained when the table is moved or the floor is reloaded.
Menu and Inventory each have **Import Excel**, with a sample workbook inside the import dialog.

- **Super Admin** runs the platform and assigns plans (Plans page). A plan is a list of feature flags plus limits.
- **Owner** runs one restaurant. **Restaurant Admin** (`it_admin` in the database), **Chef**, **Cashier**, **Waiter**,
  **Auditor** and **custom roles** work inside that restaurant.
- Every restaurant table carries `tenant_id` and Postgres row-level security confines every query to the signed-in
  restaurant (`app_tenant_ok()`); ids from another restaurant answer 404.
- Permissions are checked on the server on every request (`AuthGuard` loads roles fresh from the database, so a
  deactivated employee is locked out on the very next request). The UI only hides what the server would refuse.
- **Plan features** gate permissions: a permission whose feature is not in the license is dropped from everyone
  (`PERMISSION_FEATURE`, `limitToPlan` in `apps/api/src/common/permissions.ts`). The server then answers
  `403 feature_not_in_plan`, and the screens show "not in your plan — ask House Plating" (owner) or "ask the owner".

| Plan feature | What it unlocks |
| --- | --- |
| `staff_portal` | Employees sign in to the web with email + PIN |
| `roles.custom` | Owner-defined roles |
| `floor.editor` | Visual floor editor (viewing the live floor is always allowed) |
| `inventory` | Stock, recipes, deductions, replenishment |
| `import.excel` | Excel import of menu and inventory |
| `expenses` | Expense records |
| limit `staffPerBranch` | Maximum active employees (owner not counted) |

All of these are in **Premium** by default; the Super Admin can add or remove them per plan, and a plan change applies
to every restaurant on it immediately (licenses are re-signed).

**Downgrade behaviour.** Nothing is ever deleted. Data of a removed feature (stock ledger, recipes, expenses, imports,
custom roles, layout) stay in the database and reappear when the feature returns; only changes stop. The owner's own
account and password sign-in are never blocked by a plan. Employees with a custom role lose those permissions until the
feature returns (they keep any built-in role). Employees above a lower limit stay active; only new activations are refused.

## 2. Employees and web sign-in

Form: full name, **email (required)**, phone (optional), role (built-in or custom), PIN setup, active/inactive, web
portal access (only if the plan has `staff_portal`). Code: `apps/api/src/staff/staff.controller.ts`.

**Who may create whom.** The owner may assign any role the plan allows. A Restaurant Admin may create cashiers, waiters,
chefs and auditors, but never another Restaurant Admin or an owner, never grant discounts they lack themselves, and
only assign custom roles whose permissions they all hold. Ownership is never transferred through these screens.

**One email = one restaurant.** Emails are unique across the platform (`users.email` is unique and is checked against
platform admins too), so there are no multiple memberships and no restaurant picker after sign-in. Creating an
employee with an email that is in use anywhere is refused (`409 email_taken`).

**PIN policy** (`apps/api/src/staff/pin-policy.ts`):
- 6 to 8 digits; not one digit repeated (111111); not a straight run up or down (123456, 987654); not a common PIN.
- Stored only as an Argon2id hash. Never logged, audited, emailed or returned by any endpoint.
- 5 wrong PINs or passwords lock the account for 15 minutes (owner/admin can unlock); every auth route is also
  throttled per IP.
- PINs set before this policy (4–5 digits) keep working on the POS but the web refuses them (`pin_change_required`)
  until the employee picks a new one through a reset link.

**Invite and reset.** The recommended path emails a one-time link (`/#/set-pin?token=…`, 72 hours) so the employee
chooses their own PIN; only the SHA-256 of the token is stored. Owners/admins can also set a PIN in person, or send a
reset link later. "Forgot PIN" on the sign-in page always answers the same, so it never reveals whether an email
exists. If the email provider refuses a message, the owner sees the link to pass on in person.

**Sessions.** Sign-in returns the same short-lived access token + rotating refresh token as password sign-in; logout
revokes the refresh family. Turning an employee off or removing web access revokes their sessions at once.

## 3. Menu: categories, sizes and portions

- Categories can be created, renamed, reordered (Move up / down → `PUT /menu/categories/order`) and hidden from the POS
  (`active = false`) without losing their items.
- Every item has a stable `code` and one or more **variants** (`menu_variants`): stable code / SKU, display name,
  portion label, serving quantity + unit, portion ratio, selling price, optional own tax rule, availability, default.
- Serving quantity, portion ratio, recipe consumption, cost price and selling price are separate fields. The portion
  ratio is only a default for scaling a recipe when a size has none of its own — prices are always explicit.
- Variant codes are unique in the restaurant and never reused; removed sizes are retired (soft-deleted), so past
  orders keep their reference. Older items were given one "Regular" size with their old price.
- POS: a dish with several sizes asks which one; the hub stores the size id, code and name on the order line with the
  price and tax snapshot. KOTs, bills and reports show "Dish · Size". Later price changes never alter past orders.

## 4. Floor layout editor

Console → Floors & tables → Floor plan. Owners/admins with `floor.manage` and the `floor.editor` feature can drag,
rotate (15° steps or slider), resize, change shape (round / square / long), add, duplicate and remove tables, move
chairs one by one, snap to a 10 cm grid, zoom and pan (mouse or touch), and Save / Cancel / Reload. The floor canvas has
its own size. Everyone else (including waiters and auditors) sees the live floor: available, occupied, bill printed,
reserved, out of use. Staff who take orders can mark a table reserved or out of use.

Rules (`apps/api/src/floors/layout.controller.ts`): table names are unique in the branch; overlaps are a warning, not an
error; a save carries the version it started from and is refused if someone saved since (`409 layout_changed`); a
table with an open order cannot be removed; removed tables are retired so old orders keep them. The hub receives
shape, position, size, rotation, chairs and status; the POS has a Floor plan view and refuses new orders on tables
that are out of use.

## 5. Inventory

Code: `apps/api/src/inventory/`. Default rights: Owner — everything; Restaurant Admin — products, receipts, counts,
adjustments, transfers, imports, reports; Chef — view stock, record kitchen use and wastage, request replenishment;
Auditor — read only. Custom roles can combine these within the plan.

- Products: SKU, name, category, base unit, purchase unit + conversion factor, cost per purchase unit, reorder level,
  supplier, storage location, active. **Current stock is never a stored field.**
- **Ledger** (`stock_movements`, append-only by grants and a trigger): opening, purchase, sale, consumption, wastage
  (reason required), return to supplier, customer return, count (records the difference), adjustment, transfer
  out/in. Each row has the product, signed quantity in the base unit, the quantity and unit as entered, value, cost,
  supplier, reference, batch, expiry, reason, actor and role, time and source document.
- Units convert only within a dimension (kg ↔ g, l ↔ ml); a product's purchase unit converts with its own factor
  (1 case = 24 bottles). Incompatible units are refused.
- **Concurrency.** Every movement locks the product row (`SELECT … FOR UPDATE`) in the same transaction. Manual
  movements cannot take stock below zero.
- **Retries.** Manual movements carry an idempotency key (the web generates one per dialog), so a retried request
  returns the first result.
- **Costing:** moving weighted-average cost per base unit. A purchase or opening entry with a cost re-averages;
  everything that leaves stock is valued at the current average. Stock value = balance × average.
- **Sales deduction:** when the hub syncs a paid bill to the cloud. Each order line's recipe (the size's own, or the
  full portion's scaled by the portion ratio) becomes `sale` movements keyed by (bill line, product). A retried sync or
  a repeated bill event adds nothing. Reversed lines deduct nothing. Refunds and corrections do not return prepared
  food to stock; a returned packaged item is a manual "customer return". Sales that already happened are always
  recorded even if stock goes below zero — that shows as a negative-stock alert.
- Alerts: low stock (at or below reorder level), below zero, batches expiring within 7 days or expired.

## 6. Excel import

Templates: `docs/templates/house-plating-menu-import-template.xlsx` and
`docs/templates/house-plating-inventory-import-template.xlsx` (regenerate with
`pnpm --filter @rsaas/api exec ts-node --transpile-only scripts/gen-import-templates.ts`; the API serves the same
files). Each has an Instructions sheet that explains every column, quantity, amount and ratio.

Flow: Download template → Upload → Validate → Preview → Confirm → Results.
- Only `.xlsx` up to 5 MB; macro-enabled files and fake extensions are refused; formula cells are errors (paste values).
- Errors are listed by sheet, row and column and can be downloaded as CSV.
- **Create only** refuses codes that exist; **Update existing** refuses unknown codes and keeps the current value
  for blank cells (write CLEAR to empty a description or category). Matching is by code / SKU, never by name.
- Nothing is written until the person confirms. With errors, confirming is refused unless they explicitly choose
  "import only the valid rows" — then errored rows and anything that depends on them are skipped and listed.
- A confirmed import runs in one transaction, and confirming again returns the first result.
- **Opening stock is not a product field:** each OpeningStock row becomes an `opening` ledger movement keyed to the file
  and row, so re-uploading the same file adds nothing. A product that already has opening stock at that location is
  refused (use a purchase or a count).
- `import_jobs` keeps the actor, time, file name, size and SHA-256, counts, errors and the outcome.

## 7. Auditor portal and logs

Console → Audit & records (`audit.read`). The activity log merges cloud actions (`audit_events`) and POS actions synced
from the hub (reversals, approvals, discounts…). Each entry shows the restaurant, the actor and their **role and name at
the time**, action, record, time, before/after, reason and the request id (which ties together everything one request
changed). Filters: date range, employee, role, area (module), action, record / request id / reason text. Export to CSV
needs `audit.export` (auditors, owners, admins). Sales & payments lists bills, payments by method, discounts, refunds /
corrections and voided lines, with CSV export. Imports lists every import with its outcome.

Logs cannot be changed by restaurant users: there are no write endpoints, `rsaas_app` has INSERT/SELECT only on
`audit_events` and `stock_movements`, and triggers refuse UPDATE/DELETE even for the table owner. Passwords, PINs,
tokens, MFA secrets and card data are redacted before any audit row is written.

## 8. Role dashboards

Owner, Restaurant Admin and Auditor (they read reports) open on the business dashboard. Everyone else opens on panels
matching their permissions — custom roles included:
- **Chef:** kitchen orders with KOT status and notes, low / expiring stock, links to record use and wastage and to
  request stock.
- **Cashier:** today's bills and payments by method, open orders.
- **Waiter:** the live floor plan with table states and open orders.

Order entry, billing and payments are done on the **POS app**, which is the single writer for live operations and works
offline. The web portals show the synced state (a few seconds behind) and never write orders or bills.
