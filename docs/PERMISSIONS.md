# Permission matrix (role × action × plan)

> Generated from `apps/api/src/common/permissions.ts` by `pnpm --filter @rsaas/api exec ts-node --transpile-only scripts/gen-permissions-doc.ts`. Do not edit by hand.

Enforcement: every API route declares `@RequirePermissions(...)` (or is explicitly `@Public`/`@AuthenticatedOnly`); routes without a declaration are refused. Tenant routes also declare `@RequiresFeature(flag)`, checked against the **signed** license token, and writes are refused while the license is read-only (expired past 7-day grace, suspended, blocked or revoked). The hub applies the same keys offline.

## Platform tier (Super Admin portal)

| Permission | Meaning | Super Admin | Onboarding Admin | Platform Auditor |
| --- | --- | --- | --- | --- |
| `platform.restaurant.read` | View restaurants, their licenses, devices and payments | Y | Y | R |
| `platform.restaurant.create` | Register a restaurant (sends owner verification email) | Y | Y | — |
| `platform.restaurant.update` | Edit restaurant profile fields | Y | Y | — |
| `platform.restaurant.status` | Activate, suspend, block or reactivate a restaurant (with reason) | Y | Y | — |
| `platform.license.manage` | Issue, renew, upgrade, downgrade or revoke licenses | Y | Y | — |
| `platform.payment.record` | Record a subscription payment | Y | Y | — |
| `platform.plan.manage` | Create and edit subscription plans | Y | — | — |
| `platform.admin.read` | List platform admins and roles | Y | — | R |
| `platform.admin.invite` | Invite platform admins | Y | — | — |
| `platform.admin.roles` | Assign roles to platform admins / create roles | Y | — | — |
| `platform.admin.deactivate` | Deactivate a platform admin | Y | — | — |
| `platform.mfa.reset` | Reset another admin's MFA (requires step-up) | Y | — | — |
| `platform.audit.read` | Read the platform audit log | Y | — | R |

Platform roles are data (`platform_roles`); Super Admins can create more. Guards: an admin can only grant permissions they hold, cannot change their own roles, and cannot edit an admin who holds more authority. MFA reset additionally needs a 5-minute step-up token (password + TOTP).

## Restaurant tier (POS / owner)

| Permission | Meaning | owner | it_admin | cashier | waiter | chef | auditor | custom |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `restaurant.profile.read` | View restaurant profile and tax settings | Y | Y | — | — | — | Y | — |
| `restaurant.profile.manage` | Edit restaurant profile and tax settings | Y | Y | — | — | — | — | — |
| `license.read` | View own license and plan | Y | Y | — | — | — | Y | — |
| `staff.read` | View staff users and roles | Y | Y | — | — | — | Y | — |
| `staff.manage` | Manage staff users and roles | Y | Y | — | — | — | — | — |
| `device.manage` | Pair devices, set hub, technical settings | Y | Y | — | — | — | — | — |
| `floor.read` | View floors and tables | Y | Y | Y | Y | — | Y | — |
| `floor.manage` | Manage floors and tables | Y | Y | — | — | — | — | — |
| `menu.read` | View menu, categories and tax rules | Y | Y | Y | Y | Y | Y | — |
| `menu.submit` | Submit menu item / ingredient change | Y | Y | Y | — | — | — | — |
| `menu.approve` | Approve recipe and ingredient changes | Y | — | — | — | Y | — | — |
| `menu.publish` | Publish menu changes and prices; manage menu master data | Y | Y | — | — | — | — | — |
| `order.read` | View orders | Y | Y | Y | Y | Y | Y | — |
| `order.write` | Create / edit orders | Y | — | Y | Y | — | — | — |
| `order.transfer` | Transfer an order to another table | Y | — | Y | Y | — | — | — |
| `order.reverse` | Reverse an item not yet sent to kitchen | Y | — | Y | Y | — | — | — |
| `order.reverse.sent` | Reverse an item already sent to kitchen (or approve with PIN) | Y | — | — | — | — | — | — |
| `discount.apply` | Apply a discount | Y | — | G | — | — | — | — |
| `payment.take` | Take payment, close bill, assign tip | Y | — | Y | — | — | — | — |
| `bill.adjust` | Post an adjustment to a paid bill (or approve with PIN) | Y | — | — | — | — | — | — |
| `kds.read` | View kitchen queue | Y | Y | Y | Y | Y | Y | — |
| `kds.update` | Kitchen queue: accept / preparing / ready / served | Y | — | — | — | Y | — | — |
| `recipe.read` | View recipes | Y | — | — | — | Y | Y | — |
| `recipe.write` | Create and version recipes | Y | — | — | — | Y | — | — |
| `inventory.read` | View stock, products and movement history | Y | Y | — | — | Y | Y | — |
| `inventory.manage` | Inventory products, suppliers, locations and recipe mapping | Y | Y | — | — | — | — | — |
| `inventory.write` | Opening stock, purchases/receipts, returns, stock counts, adjustments, transfers | Y | Y | — | — | — | — | — |
| `inventory.consume` | Record kitchen consumption and wastage | Y | Y | — | — | Y | — | — |
| `inventory.request` | Request replenishment | Y | Y | — | — | Y | — | — |
| `expense.read` | View purchases and expenses | Y | Y | — | — | — | Y | — |
| `expense.write` | Record expenses | Y | Y | — | — | — | — | — |
| `import.run` | Import menu / inventory from Excel | Y | Y | — | — | — | — | — |
| `shift.read` | View shifts and attendance setup | Y | Y | — | — | — | Y | — |
| `shift.manage` | Shifts, breaks, attendance setup | Y | Y | — | — | — | — | — |
| `clock` | Clock in / out, start / end break | Y | Y | Y | Y | Y | — | — |
| `reports.read` | Reports and dashboards (branch-scoped) | Y | Y | — | — | — | Y | — |
| `reports.own` | Own shift / own tips reports | Y | — | Y | Y | — | — | — |
| `audit.read` | Restaurant audit log | Y | Y | — | — | — | Y | — |
| `audit.export` | Export restaurant records and audit log | Y | Y | — | — | — | Y | — |
| `roles.manage` | Create and edit custom roles | Y | — | — | — | — | — | — |

Key: Y = allowed · G = only if granted to that user (`extra_permissions`) · — = refused. Owner/manager **PIN** approval on the hub covers "reverse a sent item" and "adjust a paid bill" for cashiers. In Premium every restaurant role is scoped to `branch_ids` (empty = all branches). Auditor holds read keys only, so every write route returns 403 (tested across all routes).

## Plans × feature flags

| Flag | Gates | Standard | Professional | Premium |
| --- | --- | --- | --- | --- |
| `tables` | Tables, free/occupied status, table transfer | Y | Y | Y |
| `orders.dinein` | Dine-in orders | Y | Y | Y |
| `orders.takeaway` | Takeaway orders | Y | Y | Y |
| `menu` | Categories, items, images, tax per item | Y | Y | Y |
| `billing` | Bills, taxes, discounts, tips, reversals, adjustments, print | Y | Y | Y |
| `offline.single` | Device runs as its own hub | Y | Y | Y |
| `floors` | Multiple floors, per-floor layout, cross-floor transfer | — | Y | Y |
| `multi_cashier` | More than one concurrent cashier session | — | Y | Y |
| `waiter_app` | Waiter role on Android | — | Y | Y |
| `lan_hub` | Other devices pair to the hub over Wi-Fi | — | Y | Y |
| `franchise` | Multiple branches, consolidated dashboard and invoice | — | — | Y |
| `roles.extended` | IT Admin, Chef, Auditor roles; branch-scoped RBAC | — | — | Y |
| `kds` | Kitchen Display System | — | — | Y |
| `recipes` | Recipe versions | — | — | Y |
| `menu.approval` | Chef approval workflow | — | — | Y |
| `inventory` | Departments, stock, receipts, transfers, wastage, consumption | — | — | Y |
| `shifts` | Shift templates, breaks, attendance | — | — | Y |
| `branding` | Restaurant's own colour, logo and text style on the console, POS and bills | — | — | Y |
| `staff_portal` | Employees sign in to the web portal with email + PIN | — | — | Y |
| `roles.custom` | Owner-defined roles with chosen permissions | — | — | Y |
| `floor.editor` | Visual floor layout editor (table shapes, chairs, positions) | — | — | Y |
| `import.excel` | Excel import of menu and inventory | — | — | Y |
| `expenses` | Purchases and expense records | — | — | Y |

### Limits (configurable per plan; `null` = set by client)

| Limit | Standard | Professional | Premium |
| --- | --- | --- | --- |
| branches | 1 | 1 | client |
| floorsPerBranch | 1 | client | client |
| devicesPerBranch | 1 | client | client |
| concurrentCashiers | 1 | client | client |
| staffPerBranch | client | client | client |
