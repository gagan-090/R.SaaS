import { Body, Controller, Get, Param, ParseUUIDPipe, Patch, Post, Put, Query } from '@nestjs/common';
import { ApiBearerAuth, ApiBody, ApiTags } from '@nestjs/swagger';
import { Prisma } from '@prisma/client';
import { z } from 'zod';
import type { Actor, AuditDetails } from '../common/actor';
import { AuditCtx, CurrentActor } from '../common/actor';
import { Audited, RequireAnyPermission, RequirePermissions, RequiresFeature } from '../common/decorators';
import { badRequest, conflict, forbidden, notFound } from '../common/errors';
import { UNIT_KEYS, compatible } from '../common/units';
import { apiBody, zbody, ZodPipe } from '../common/validation';
import { DbService, Tx } from '../db/db.service';
import { CODE } from '../menu/menu.controller';
import { InventoryService, MANUAL_TYPES, TYPE_PERMISSION } from './inventory.service';

const Unit = z.enum(UNIT_KEYS);
const NameBody = z.object({ name: z.string().trim().min(1).max(60), active: z.boolean().default(true) });
const SupplierBody = z.object({
  name: z.string().trim().min(1).max(80), phone: z.string().trim().max(20).nullish(), email: z.string().trim().email().nullish(),
  gstin: z.string().trim().max(15).nullish(), active: z.boolean().default(true),
});
export const ProductBody = z.object({
  sku: CODE,
  name: z.string().trim().min(1).max(120),
  category: z.string().trim().max(60).nullish(),
  baseUnit: Unit,
  purchaseUnit: Unit,
  conversionFactor: z.number().positive().max(1_000_000), // base units in one purchase unit
  unitCostPaise: z.number().int().nonnegative().max(1_000_000_000).default(0), // per purchase unit
  minStock: z.number().nonnegative().max(1_000_000_000).default(0), // base units
  defaultSupplierId: z.string().uuid().nullish(),
  defaultLocationId: z.string().uuid().nullish(),
  active: z.boolean().default(true),
});
const ProductPatch = ProductBody.omit({ sku: true }).partial();
const MovementBody = z.object({
  type: z.enum(MANUAL_TYPES),
  productId: z.string().uuid(),
  quantity: z.number().refine((n) => n !== 0 && Math.abs(n) <= 1_000_000_000, 'Quantity must not be 0'),
  unit: Unit,
  locationId: z.string().uuid().nullish(),
  toLocationId: z.string().uuid().nullish(),
  unitCostPaise: z.number().int().nonnegative().max(1_000_000_000).nullish(),
  supplierId: z.string().uuid().nullish(),
  reference: z.string().trim().max(80).nullish(),
  batchNumber: z.string().trim().max(40).nullish(),
  expiryDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Use YYYY-MM-DD').nullish(),
  reason: z.string().trim().max(300).nullish(),
  idempotencyKey: z.string().min(8).max(100),
}).refine((b) => b.type === 'adjustment' || b.quantity > 0, { message: 'Quantity must be positive', path: ['quantity'] });
const MovementQuery = z.object({
  productId: z.string().uuid().optional(), type: z.string().optional(), from: z.string().optional(), to: z.string().optional(),
  limit: z.coerce.number().int().min(1).max(1000).default(200),
});
const RecipeBody = z.object({
  lines: z.array(z.object({ productId: z.string().uuid(), quantity: z.number().positive().max(1_000_000), unit: Unit })).max(60),
});
const RequestBody = z.object({ productId: z.string().uuid(), quantity: z.number().positive().max(1_000_000), unit: Unit, note: z.string().trim().max(300).nullish() });
const RequestPatch = z.object({ status: z.enum(['ordered', 'received', 'cancelled']) });

const n = (v: Prisma.Decimal | number | null | undefined) => (v === null || v === undefined ? 0 : Number(v));
const DAY = 86_400_000;

/**
 * Inventory (plan feature "inventory"). Reading needs inventory.read; the product list, recipes and suppliers need
 * inventory.manage; each movement type has its own permission (kitchen: consumption & wastage; stock-keeping:
 * receipts, returns, counts, adjustments, transfers). After a downgrade nothing is deleted: the data are kept and
 * reappear when the feature returns.
 */
@ApiTags('inventory')
@ApiBearerAuth()
@Controller()
export class InventoryController {
  constructor(private db: DbService, private inv: InventoryService) {}

  private t<T>(a: Actor, fn: (tx: Tx) => Promise<T>) {
    if (!a.tenantId) throw forbidden('tenant_only', 'Restaurant account required');
    return this.db.tenant(a.tenantId, fn);
  }

  // ---------------------------------------------------------------- locations & suppliers

  @RequirePermissions('inventory.read')
  @Get('inventory/locations')
  locations(@CurrentActor() a: Actor) {
    return this.t(a, (tx) => tx.inventoryLocation.findMany({ orderBy: { name: 'asc' } }));
  }

  @RequirePermissions('inventory.manage')
  @RequiresFeature('inventory')
  @Audited('inventory.location_created')
  @Post('inventory/locations')
  @ApiBody(apiBody(NameBody))
  async createLocation(@CurrentActor() a: Actor, @Body(zbody(NameBody)) b: z.infer<typeof NameBody>, @AuditCtx() audit: AuditDetails) {
    const l = await this.t(a, async (tx) => {
      if (await tx.inventoryLocation.findFirst({ where: { name: b.name } })) throw conflict('duplicate_name', 'A location with that name exists');
      return tx.inventoryLocation.create({ data: { ...b, tenantId: a.tenantId! } });
    });
    Object.assign(audit, { objectType: 'inventory_location', objectId: l.id, after: l });
    return l;
  }

  @RequirePermissions('inventory.manage')
  @RequiresFeature('inventory')
  @Audited('inventory.location_updated')
  @Patch('inventory/locations/:id')
  @ApiBody(apiBody(NameBody.partial()))
  async updateLocation(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @Body(zbody(NameBody.partial())) b: Partial<z.infer<typeof NameBody>>, @AuditCtx() audit: AuditDetails) {
    const r = await this.t(a, async (tx) => {
      const before = await tx.inventoryLocation.findUnique({ where: { id } });
      if (!before) throw notFound('Location');
      return { before, after: await tx.inventoryLocation.update({ where: { id }, data: b }) };
    });
    Object.assign(audit, { objectType: 'inventory_location', objectId: id, before: r.before, after: r.after });
    return r.after;
  }

  @RequirePermissions('inventory.read')
  @Get('inventory/suppliers')
  suppliers(@CurrentActor() a: Actor) {
    return this.t(a, (tx) => tx.supplier.findMany({ orderBy: { name: 'asc' } }));
  }

  @RequirePermissions('inventory.manage')
  @RequiresFeature('inventory')
  @Audited('inventory.supplier_created')
  @Post('inventory/suppliers')
  @ApiBody(apiBody(SupplierBody))
  async createSupplier(@CurrentActor() a: Actor, @Body(zbody(SupplierBody)) b: z.infer<typeof SupplierBody>, @AuditCtx() audit: AuditDetails) {
    const s = await this.t(a, async (tx) => {
      if (await tx.supplier.findFirst({ where: { name: b.name } })) throw conflict('duplicate_name', 'A supplier with that name exists');
      return tx.supplier.create({ data: { ...b, tenantId: a.tenantId! } });
    });
    Object.assign(audit, { objectType: 'supplier', objectId: s.id, after: s });
    return s;
  }

  @RequirePermissions('inventory.manage')
  @RequiresFeature('inventory')
  @Audited('inventory.supplier_updated')
  @Patch('inventory/suppliers/:id')
  @ApiBody(apiBody(SupplierBody.partial()))
  async updateSupplier(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @Body(zbody(SupplierBody.partial())) b: Partial<z.infer<typeof SupplierBody>>, @AuditCtx() audit: AuditDetails) {
    const r = await this.t(a, async (tx) => {
      const before = await tx.supplier.findUnique({ where: { id } });
      if (!before) throw notFound('Supplier');
      return { before, after: await tx.supplier.update({ where: { id }, data: b }) };
    });
    Object.assign(audit, { objectType: 'supplier', objectId: id, before: r.before, after: r.after });
    return r.after;
  }

  // ---------------------------------------------------------------- products

  private async productRows(tx: Tx, where: Prisma.InventoryProductWhereInput) {
    const products = await tx.inventoryProduct.findMany({ where, orderBy: [{ category: 'asc' }, { name: 'asc' }] });
    const bal = await this.inv.balances(tx, products.map((p) => p.id));
    const soon = new Date(Date.now() + 7 * DAY);
    const expiring = await this.expiringBatches(tx, soon);
    return products.map((p) => {
      const stock = Math.round((bal.get(p.id) ?? 0) * 1000) / 1000;
      const avg = n(p.avgCostPaise);
      return {
        id: p.id, sku: p.sku, name: p.name, category: p.category, baseUnit: p.baseUnit, purchaseUnit: p.purchaseUnit,
        conversionFactor: n(p.conversionFactor), unitCostPaise: p.unitCostPaise, avgCostPaise: Math.round(avg * 100) / 100,
        minStock: n(p.minStock), defaultSupplierId: p.defaultSupplierId, defaultLocationId: p.defaultLocationId, active: p.active,
        stock, valuePaise: Math.round(Math.max(stock, 0) * avg),
        low: p.active && stock <= n(p.minStock) && n(p.minStock) > 0, negative: stock < 0,
        expiring: expiring.filter((x) => x.productId === p.id).map(({ productId: _p, ...x }) => x),
      };
    });
  }

  /** Batches with stock left whose expiry is on or before [until]. */
  private async expiringBatches(tx: Tx, until: Date) {
    const rows = await tx.stockMovement.groupBy({
      by: ['productId', 'batchNumber', 'expiryDate'],
      where: { expiryDate: { not: null, lte: until } },
      _sum: { quantity: true },
    });
    return rows
      .filter((r) => n(r._sum.quantity) > 0)
      .map((r) => ({ productId: r.productId, batchNumber: r.batchNumber, expiryDate: r.expiryDate!.toISOString().slice(0, 10), quantity: n(r._sum.quantity), expired: r.expiryDate! < new Date() }));
  }

  @RequirePermissions('inventory.read')
  @Get('inventory/products')
  products(@CurrentActor() a: Actor, @Query('includeInactive') includeInactive?: string) {
    return this.t(a, (tx) => this.productRows(tx, includeInactive === 'true' ? {} : { active: true }));
  }

  @RequirePermissions('inventory.read')
  @Get('inventory/products/:id')
  async product(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string) {
    return this.t(a, async (tx) => {
      const [p] = await this.productRows(tx, { id });
      if (!p) throw notFound('Product');
      const byLocation = await tx.stockMovement.groupBy({ by: ['locationId'], where: { productId: id }, _sum: { quantity: true } });
      const batches = await tx.stockMovement.groupBy({ by: ['batchNumber', 'expiryDate'], where: { productId: id, batchNumber: { not: null } }, _sum: { quantity: true } });
      return {
        ...p,
        byLocation: byLocation.map((r) => ({ locationId: r.locationId, quantity: n(r._sum.quantity) })),
        batches: batches.filter((b) => n(b._sum.quantity) !== 0).map((b) => ({ batchNumber: b.batchNumber, expiryDate: b.expiryDate?.toISOString().slice(0, 10) ?? null, quantity: n(b._sum.quantity) })),
      };
    });
  }

  private async checkRefs(tx: Tx, b: Partial<z.infer<typeof ProductBody>>) {
    if (b.defaultSupplierId && !(await tx.supplier.findUnique({ where: { id: b.defaultSupplierId } }))) throw notFound('Supplier');
    if (b.defaultLocationId && !(await tx.inventoryLocation.findUnique({ where: { id: b.defaultLocationId } }))) throw notFound('Location');
  }

  @RequirePermissions('inventory.manage')
  @RequiresFeature('inventory')
  @Audited('inventory.product_created')
  @Post('inventory/products')
  @ApiBody(apiBody(ProductBody))
  async createProduct(@CurrentActor() a: Actor, @Body(zbody(ProductBody)) b: z.infer<typeof ProductBody>, @AuditCtx() audit: AuditDetails) {
    const p = await this.t(a, async (tx) => {
      const sku = b.sku.toUpperCase();
      if (await tx.inventoryProduct.findFirst({ where: { sku } })) throw conflict('duplicate_sku', `SKU ${sku} already exists`);
      await this.checkRefs(tx, b);
      return tx.inventoryProduct.create({ data: { ...b, sku, tenantId: a.tenantId!, avgCostPaise: b.unitCostPaise / b.conversionFactor } });
    });
    Object.assign(audit, { objectType: 'inventory_product', objectId: p.id, after: { sku: p.sku, name: p.name, baseUnit: p.baseUnit, purchaseUnit: p.purchaseUnit, conversionFactor: n(p.conversionFactor), unitCostPaise: p.unitCostPaise } });
    return (await this.t(a, (tx) => this.productRows(tx, { id: p.id })))[0];
  }

  @RequirePermissions('inventory.manage')
  @RequiresFeature('inventory')
  @Audited('inventory.product_updated')
  @Patch('inventory/products/:id')
  @ApiBody(apiBody(ProductPatch))
  async updateProduct(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @Body(zbody(ProductPatch)) b: z.infer<typeof ProductPatch>, @AuditCtx() audit: AuditDetails) {
    const r = await this.t(a, async (tx) => {
      const before = await tx.inventoryProduct.findUnique({ where: { id } });
      if (!before) throw notFound('Product');
      await this.checkRefs(tx, b);
      // the base unit cannot change once stock has moved (every movement is stored in it)
      if (b.baseUnit && b.baseUnit !== before.baseUnit && (await tx.stockMovement.count({ where: { productId: id } }))) {
        throw conflict('base_unit_locked', 'The base unit cannot change after stock movements exist');
      }
      return { before, after: await tx.inventoryProduct.update({ where: { id }, data: b }) };
    });
    const pick = (x: typeof r.before) => ({ name: x.name, category: x.category, baseUnit: x.baseUnit, purchaseUnit: x.purchaseUnit, conversionFactor: n(x.conversionFactor), unitCostPaise: x.unitCostPaise, minStock: n(x.minStock), active: x.active });
    Object.assign(audit, { objectType: 'inventory_product', objectId: id, before: pick(r.before), after: pick(r.after) });
    return (await this.t(a, (tx) => this.productRows(tx, { id })))[0];
  }

  // ---------------------------------------------------------------- movements

  /** Posts a stock movement. Each type checks its own permission; a retried request returns the first result. */
  @RequirePermissions('inventory.read')
  @RequireAnyPermission('inventory.write', 'inventory.consume')
  @RequiresFeature('inventory')
  @Audited('inventory.movement')
  @Post('inventory/movements')
  @ApiBody(apiBody(MovementBody))
  async move(@CurrentActor() a: Actor, @Body(zbody(MovementBody)) b: z.infer<typeof MovementBody>, @AuditCtx() audit: AuditDetails) {
    const need = TYPE_PERMISSION[b.type];
    if (!a.permissions.has(need)) throw forbidden('missing_permission', `Missing permission: ${need}`);
    const r = await this.t(a, (tx) => this.inv.record(tx, a, b));
    Object.assign(audit, {
      action: `inventory.${b.type}`, objectType: 'inventory_product', objectId: b.productId, reason: b.reason ?? undefined,
      after: r.movements.map((m) => ({ id: m.id, type: m.type, quantity: n(m.quantity), valuePaise: m.valuePaise, locationId: m.locationId, reference: m.reference, batchNumber: m.batchNumber })),
    });
    if (r.duplicate) Object.assign(audit, { action: 'inventory.movement_retry' });
    return { duplicate: r.duplicate, movements: r.movements.map((m) => ({ ...m, quantity: n(m.quantity), enteredQty: n(m.enteredQty), unitCostPaise: n(m.unitCostPaise) })) };
  }

  @RequirePermissions('inventory.read')
  @Get('inventory/movements')
  async movements(@CurrentActor() a: Actor, @Query(new ZodPipe(MovementQuery)) q: z.infer<typeof MovementQuery>) {
    return this.t(a, async (tx) => {
      const rows = await tx.stockMovement.findMany({
        where: {
          ...(q.productId ? { productId: q.productId } : {}),
          ...(q.type ? { type: { in: q.type.split(',') as never } } : {}),
          ...(q.from || q.to ? { createdAt: { ...(q.from ? { gte: new Date(q.from) } : {}), ...(q.to ? { lt: new Date(q.to) } : {}) } } : {}),
        },
        include: { product: { select: { sku: true, name: true, baseUnit: true } } },
        orderBy: { createdAt: 'desc' },
        take: q.limit,
      });
      const users = new Map((await tx.user.findMany({ select: { id: true, name: true } })).map((u) => [u.id, u.name]));
      return rows.map((m) => ({
        id: m.id, type: m.type, productId: m.productId, sku: m.product.sku, productName: m.product.name, baseUnit: m.product.baseUnit,
        quantity: n(m.quantity), enteredQty: n(m.enteredQty), enteredUnit: m.enteredUnit, valuePaise: m.valuePaise, locationId: m.locationId,
        supplierId: m.supplierId, reference: m.reference, batchNumber: m.batchNumber, expiryDate: m.expiryDate?.toISOString().slice(0, 10) ?? null,
        reason: m.reason, sourceType: m.sourceType, sourceId: m.sourceId, actorId: m.actorId, actorName: m.actorId ? (users.get(m.actorId) ?? 'Former staff') : 'System', actorRole: m.actorRole,
        createdAt: m.createdAt,
      }));
    });
  }

  /** Low stock, negative stock, and batches expiring within 7 days (or already expired). */
  @RequirePermissions('inventory.read')
  @Get('inventory/alerts')
  async alerts(@CurrentActor() a: Actor) {
    return this.t(a, async (tx) => {
      const rows = await this.productRows(tx, { active: true });
      return {
        low: rows.filter((p) => p.low && !p.negative).map((p) => ({ id: p.id, sku: p.sku, name: p.name, stock: p.stock, minStock: p.minStock, unit: p.baseUnit })),
        negative: rows.filter((p) => p.negative).map((p) => ({ id: p.id, sku: p.sku, name: p.name, stock: p.stock, unit: p.baseUnit })),
        expiring: rows.flatMap((p) => p.expiring.map((e) => ({ id: p.id, sku: p.sku, name: p.name, unit: p.baseUnit, ...e }))),
      };
    });
  }

  /** Stock value at moving average cost, by category; plus this month's movement totals. */
  @RequirePermissions('inventory.read')
  @Get('inventory/valuation')
  async valuation(@CurrentActor() a: Actor) {
    return this.t(a, async (tx) => {
      const rows = await this.productRows(tx, {});
      const byCat = new Map<string, number>();
      for (const p of rows) byCat.set(p.category ?? 'Other', (byCat.get(p.category ?? 'Other') ?? 0) + p.valuePaise);
      const from = new Date(new Date().getFullYear(), new Date().getMonth(), 1);
      const month = await tx.stockMovement.groupBy({ by: ['type'], where: { createdAt: { gte: from } }, _sum: { valuePaise: true } });
      return {
        method: 'Moving weighted-average cost per base unit',
        totalPaise: rows.reduce((s, p) => s + p.valuePaise, 0),
        byCategory: [...byCat].map(([category, valuePaise]) => ({ category, valuePaise })).sort((x, y) => y.valuePaise - x.valuePaise),
        thisMonth: month.map((m) => ({ type: m.type, valuePaise: m._sum.valuePaise ?? 0 })),
        products: rows.map((p) => ({ id: p.id, sku: p.sku, name: p.name, category: p.category, stock: p.stock, unit: p.baseUnit, avgCostPaise: p.avgCostPaise, valuePaise: p.valuePaise })),
      };
    });
  }

  // ---------------------------------------------------------------- recipes (menu variant → stock)

  @RequirePermissions('inventory.read')
  @Get('menu/variants/:id/recipe')
  async recipe(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string) {
    return this.t(a, async (tx) => {
      const v = await tx.menuVariant.findUnique({ where: { id } });
      if (!v) throw notFound('Variant');
      const own = await tx.recipeLine.findMany({ where: { variantId: id }, include: { product: true } });
      const effective = await this.inv.recipeFor(tx, id);
      const products = new Map((await tx.inventoryProduct.findMany({ where: { id: { in: effective.map((e) => e.productId) } } })).map((p) => [p.id, p]));
      // cost of one serving at average cost (selling price stays separate)
      const costPaise = Math.round(effective.reduce((s, e) => {
        const p = products.get(e.productId);
        return p ? s + this.inv.toBase(p, e.quantity, e.unit) * n(p.avgCostPaise) : s;
      }, 0));
      return {
        variantId: id, own: own.length > 0,
        lines: effective.map((e) => ({ ...e, sku: products.get(e.productId)?.sku, name: products.get(e.productId)?.name })),
        costPaise, pricePaise: v.pricePaise,
      };
    });
  }

  /** Owner flow step "Map inventory / recipe": what one sold unit of this size uses. An empty list removes it. */
  @RequirePermissions('inventory.manage')
  @RequiresFeature('inventory')
  @Audited('inventory.recipe_updated')
  @Put('menu/variants/:id/recipe')
  @ApiBody(apiBody(RecipeBody))
  async setRecipe(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @Body(zbody(RecipeBody)) b: z.infer<typeof RecipeBody>, @AuditCtx() audit: AuditDetails) {
    const r = await this.t(a, async (tx) => {
      const v = await tx.menuVariant.findUnique({ where: { id } });
      if (!v || v.deleted) throw notFound('Variant');
      if (new Set(b.lines.map((l) => l.productId)).size !== b.lines.length) throw badRequest('duplicate_ingredient', 'An ingredient appears twice');
      const products = await tx.inventoryProduct.findMany({ where: { id: { in: b.lines.map((l) => l.productId) } } });
      for (const l of b.lines) {
        const p = products.find((x) => x.id === l.productId);
        if (!p) throw notFound('Product');
        if (l.unit !== p.purchaseUnit && !compatible(l.unit, p.baseUnit)) throw badRequest('incompatible_units', `${p.sku} is counted in ${p.baseUnit}; ${l.unit} cannot be converted to it`);
      }
      const before = await tx.recipeLine.findMany({ where: { variantId: id } });
      await tx.recipeLine.deleteMany({ where: { variantId: id } });
      if (b.lines.length) await tx.recipeLine.createMany({ data: b.lines.map((l) => ({ ...l, tenantId: a.tenantId!, variantId: id })) });
      const sku = new Map(products.map((p) => [p.id, p.sku]));
      return {
        before: before.map((l) => ({ productId: l.productId, quantity: n(l.quantity), unit: l.unit })),
        after: b.lines.map((l) => ({ sku: sku.get(l.productId), quantity: l.quantity, unit: l.unit })),
        code: v.code,
      };
    });
    Object.assign(audit, { objectType: 'menu_variant', objectId: id, before: r.before, after: { variant: r.code, lines: r.after } });
    return this.recipe(a, id);
  }

  // ---------------------------------------------------------------- replenishment

  @RequirePermissions('inventory.read')
  @Get('inventory/requests')
  requests(@CurrentActor() a: Actor, @Query('status') status?: string) {
    return this.t(a, async (tx) => {
      const rows = await tx.replenishmentRequest.findMany({
        where: status ? { status } : {}, include: { product: { select: { sku: true, name: true } } }, orderBy: { createdAt: 'desc' }, take: 200,
      });
      const users = new Map((await tx.user.findMany({ select: { id: true, name: true } })).map((u) => [u.id, u.name]));
      return rows.map((r) => ({ ...r, quantity: n(r.quantity), requestedByName: users.get(r.requestedBy) ?? 'Former staff', handledByName: r.handledBy ? users.get(r.handledBy) : null }));
    });
  }

  @RequirePermissions('inventory.request')
  @RequiresFeature('inventory')
  @Audited('inventory.request_created')
  @Post('inventory/requests')
  @ApiBody(apiBody(RequestBody))
  async request(@CurrentActor() a: Actor, @Body(zbody(RequestBody)) b: z.infer<typeof RequestBody>, @AuditCtx() audit: AuditDetails) {
    const r = await this.t(a, async (tx) => {
      const p = await tx.inventoryProduct.findUnique({ where: { id: b.productId } });
      if (!p) throw notFound('Product');
      this.inv.toBase(p, b.quantity, b.unit); // unit must fit the product
      return tx.replenishmentRequest.create({ data: { ...b, tenantId: a.tenantId!, requestedBy: a.id } });
    });
    Object.assign(audit, { objectType: 'replenishment_request', objectId: r.id, after: { productId: r.productId, quantity: n(r.quantity), unit: r.unit, note: r.note } });
    return { ...r, quantity: n(r.quantity) };
  }

  @RequirePermissions('inventory.write')
  @RequiresFeature('inventory')
  @Audited('inventory.request_updated')
  @Patch('inventory/requests/:id')
  @ApiBody(apiBody(RequestPatch))
  async updateRequest(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @Body(zbody(RequestPatch)) b: z.infer<typeof RequestPatch>, @AuditCtx() audit: AuditDetails) {
    const r = await this.t(a, async (tx) => {
      const before = await tx.replenishmentRequest.findUnique({ where: { id } });
      if (!before) throw notFound('Request');
      if (before.status === 'received' || before.status === 'cancelled') throw conflict('request_closed', `This request is already ${before.status}`);
      return { before, after: await tx.replenishmentRequest.update({ where: { id }, data: { status: b.status, handledBy: a.id } }) };
    });
    Object.assign(audit, { objectType: 'replenishment_request', objectId: id, before: { status: r.before.status }, after: { status: r.after.status } });
    return { ...r.after, quantity: n(r.after.quantity) };
  }
}
