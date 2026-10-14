import { Injectable } from '@nestjs/common';
import { InventoryProduct, Prisma, StockMovementType } from '@prisma/client';
import type { Actor } from '../common/actor';
import { badRequest, conflict, notFound } from '../common/errors';
import { compatible, convert, UNITS } from '../common/units';
import { Tx } from '../db/db.service';

/** Movement kinds a person can post (sales are posted only by the system from paid bills). */
export const MANUAL_TYPES = ['opening', 'purchase', 'consumption', 'wastage', 'return_to_supplier', 'customer_return', 'count', 'adjustment', 'transfer'] as const;
export type ManualType = (typeof MANUAL_TYPES)[number];

/** Who may post what: kitchen staff record use and waste; stock-keeping is for admins and owners. */
export const TYPE_PERMISSION: Record<ManualType, string> = {
  opening: 'inventory.write', purchase: 'inventory.write', return_to_supplier: 'inventory.write', customer_return: 'inventory.write',
  count: 'inventory.write', adjustment: 'inventory.write', transfer: 'inventory.write',
  consumption: 'inventory.consume', wastage: 'inventory.consume',
};
export const REASON_REQUIRED: ManualType[] = ['wastage', 'adjustment', 'count', 'return_to_supplier', 'customer_return'];

export interface MovementInput {
  type: ManualType;
  productId: string;
  quantity: number; // for "count": the counted quantity; for "adjustment": signed
  unit: string;
  locationId?: string | null;
  toLocationId?: string | null;
  unitCostPaise?: number | null; // purchase / opening: cost per entered unit
  supplierId?: string | null;
  reference?: string | null;
  batchNumber?: string | null;
  expiryDate?: string | null;
  reason?: string | null;
  idempotencyKey: string;
  sourceType?: string;
  sourceId?: string;
}

const d = (v: Prisma.Decimal | number | null | undefined) => (v === null || v === undefined ? 0 : Number(v));
const round3 = (n: number) => Math.round(n * 1000) / 1000;

/**
 * The stock ledger. Every change is a new stock_movements row inside the caller's transaction; the product row is
 * locked (SELECT … FOR UPDATE) first, so two terminals can never both spend the same stock.
 *
 * Costing: moving weighted average per base unit. A receipt with a cost re-averages; everything that leaves stock
 * is valued at the current average. Stock value = balance × average.
 */
@Injectable()
export class InventoryService {
  /** Quantity in the product's base unit: its base or purchase unit, or any unit of the same dimension. */
  toBase(p: Pick<InventoryProduct, 'baseUnit' | 'purchaseUnit' | 'conversionFactor' | 'sku'>, qty: number, unit: string): number {
    const f = d(p.conversionFactor);
    if (unit === p.baseUnit) return round3(qty);
    if (unit === p.purchaseUnit) return round3(qty * f);
    if (compatible(unit, p.baseUnit)) return convert(qty, unit, p.baseUnit);
    if (compatible(unit, p.purchaseUnit)) return round3(convert(qty, unit, p.purchaseUnit) * f);
    if (!UNITS[unit]) throw badRequest('unknown_unit', `Unknown unit "${unit}"`);
    throw badRequest('incompatible_units', `${p.sku} is counted in ${p.baseUnit}; ${unit} cannot be converted to it`);
  }

  async lock(tx: Tx, ids: string[]) {
    const sorted = [...new Set(ids)].sort();
    if (sorted.length) await tx.$queryRaw`SELECT id FROM inventory_products WHERE id = ANY(${sorted}::uuid[]) ORDER BY id FOR UPDATE`;
  }

  /** Current stock per product (optionally at one location), from the ledger. */
  async balances(tx: Tx, productIds?: string[], locationId?: string | null): Promise<Map<string, number>> {
    const rows = await tx.stockMovement.groupBy({
      by: ['productId'],
      where: { ...(productIds ? { productId: { in: productIds } } : {}), ...(locationId !== undefined ? { locationId } : {}) },
      _sum: { quantity: true },
    });
    return new Map(rows.map((r) => [r.productId, d(r._sum.quantity)]));
  }

  private async existing(tx: Tx, key: string) {
    return tx.stockMovement.findMany({ where: { idempotencyKey: { in: [key, `${key}:in`] } }, orderBy: { createdAt: 'asc' } });
  }

  /** Posts one manual movement (two for a transfer). A repeated idempotency key returns the first result. */
  async record(tx: Tx, a: Actor, input: MovementInput) {
    const already = await this.existing(tx, input.idempotencyKey);
    if (already.length) return { movements: already, duplicate: true };
    if (REASON_REQUIRED.includes(input.type) && !input.reason?.trim()) throw badRequest('reason_required', `A reason is required for ${input.type.replace(/_/g, ' ')}`);
    await this.lock(tx, [input.productId]);
    const p = await tx.inventoryProduct.findUnique({ where: { id: input.productId } });
    if (!p) throw notFound('Product');
    if (!p.active) throw conflict('product_inactive', `${p.name} is inactive`);
    for (const loc of [input.locationId, input.toLocationId]) {
      if (loc && !(await tx.inventoryLocation.findFirst({ where: { id: loc, active: true } }))) throw notFound('Storage location');
    }
    if (input.supplierId && !(await tx.supplier.findUnique({ where: { id: input.supplierId } }))) throw notFound('Supplier');
    const location = input.locationId ?? p.defaultLocationId ?? null;
    const entered = this.toBase(p, Math.abs(input.quantity), input.unit);
    const avg = d(p.avgCostPaise);
    const atLoc = (await this.balances(tx, [p.id], location)).get(p.id) ?? 0;
    const total = (await this.balances(tx, [p.id])).get(p.id) ?? 0;

    let qty: number;
    let type: StockMovementType = input.type as StockMovementType;
    switch (input.type) {
      case 'opening':
        if (await tx.stockMovement.findFirst({ where: { productId: p.id, type: 'opening', locationId: location } })) {
          throw conflict('opening_exists', `${p.name} already has opening stock here. Use a purchase, count or adjustment instead.`);
        }
        qty = entered;
        break;
      case 'purchase':
      case 'customer_return':
        qty = entered;
        break;
      case 'consumption':
      case 'wastage':
      case 'return_to_supplier':
        qty = -entered;
        break;
      case 'adjustment':
        qty = input.quantity < 0 ? -entered : entered;
        break;
      case 'count':
        // counted quantity → movement for the difference (none when it matches)
        qty = round3(entered - atLoc);
        type = 'count_adjustment';
        break;
      case 'transfer':
        if (!input.toLocationId || input.toLocationId === location) throw badRequest('transfer_target', 'Choose a different location to move stock to');
        qty = -entered;
        type = 'transfer_out';
        break;
    }
    if (qty === 0 && input.type !== 'count') throw badRequest('zero_quantity', 'Quantity must be more than 0');
    if (qty < 0 && atLoc + qty < -0.0005) {
      throw conflict('insufficient_stock', `Only ${round3(atLoc)} ${p.baseUnit} of ${p.name} in stock here; this would take it below zero`);
    }

    // value and moving-average cost
    const perBase = input.unitCostPaise !== null && input.unitCostPaise !== undefined && entered > 0
      ? input.unitCostPaise / this.toBase(p, 1, input.unit)
      : null;
    let costUsed = qty >= 0 ? (perBase ?? avg) : avg;
    let newAvg = avg;
    if (qty > 0 && perBase !== null && ['opening', 'purchase'].includes(input.type)) {
      newAvg = total + qty > 0 ? (Math.max(total, 0) * avg + qty * perBase) / (Math.max(total, 0) + qty) : perBase;
      costUsed = perBase;
    }
    const base = {
      tenantId: a.tenantId!, productId: p.id, enteredQty: Math.abs(input.quantity), enteredUnit: input.unit, supplierId: input.supplierId ?? null,
      reference: input.reference ?? null, batchNumber: input.batchNumber ?? null, expiryDate: input.expiryDate ? new Date(input.expiryDate) : null,
      reason: input.reason ?? null, sourceType: input.sourceType ?? 'manual', sourceId: input.sourceId ?? null,
      actorId: a.id, actorRole: a.roles.join(','),
    };
    const out = [];
    if (qty !== 0) {
      out.push(await tx.stockMovement.create({
        data: { ...base, type, locationId: location, quantity: qty, valuePaise: Math.round(qty * costUsed), unitCostPaise: costUsed, idempotencyKey: input.idempotencyKey },
      }));
    }
    if (input.type === 'transfer') {
      out.push(await tx.stockMovement.create({
        data: { ...base, type: 'transfer_in', locationId: input.toLocationId!, quantity: -qty, valuePaise: Math.round(-qty * avg), unitCostPaise: avg, idempotencyKey: `${input.idempotencyKey}:in` },
      }));
    }
    if (newAvg !== avg || (perBase !== null && ['opening', 'purchase'].includes(input.type))) {
      await tx.inventoryProduct.update({
        where: { id: p.id },
        data: { avgCostPaise: newAvg, ...(input.unitCostPaise ? { unitCostPaise: Math.round(input.unitCostPaise * (input.unit === p.purchaseUnit ? 1 : this.toBase(p, 1, p.purchaseUnit) / this.toBase(p, 1, input.unit))) } : {}) },
      });
    }
    return { movements: out, duplicate: false, product: p };
  }

  /**
   * Ingredients one sold unit of a variant uses: its own recipe, else the full portion's recipe scaled by the
   * portion ratio (a default the owner can override by giving the variant its own recipe).
   */
  async recipeFor(tx: Tx, variantId: string): Promise<{ productId: string; quantity: number; unit: string }[]> {
    const own = await tx.recipeLine.findMany({ where: { variantId } });
    if (own.length) return own.map((l) => ({ productId: l.productId, quantity: d(l.quantity), unit: l.unit }));
    const v = await tx.menuVariant.findUnique({ where: { id: variantId } });
    if (!v) return [];
    const siblings = await tx.menuVariant.findMany({ where: { itemId: v.itemId, id: { not: v.id }, recipeLines: { some: {} } }, include: { recipeLines: true } });
    const baseV = siblings.find((s) => d(s.portionRatio) === 1) ?? siblings.find((s) => s.isDefault) ?? siblings[0];
    if (!baseV || !v.portionRatio || !baseV.portionRatio) return [];
    const k = d(v.portionRatio) / d(baseV.portionRatio);
    return baseV.recipeLines.map((l) => ({ productId: l.productId, quantity: round3(d(l.quantity) * k), unit: l.unit }));
  }

  /**
   * Stock leaves when a bill is paid (the moment the cloud learns of the sale). One movement per bill line and
   * ingredient; the unique (source_type, source_id, product_id) makes a retried sync a no-op. Reversed lines and
   * dishes without a recipe deduct nothing; refunds and corrections never put prepared food back into stock.
   */
  async deductForPaidBill(tx: Tx, tenantId: string, bill: { id: string; order_id: string }) {
    const events = await tx.syncEvent.findMany({ where: { entity: 'order_line', payload: { path: ['order_id'], equals: bill.order_id } }, orderBy: { createdAt: 'asc' } });
    const lines = new Map<string, Record<string, unknown>>();
    for (const e of events) lines.set(e.entityId, { ...lines.get(e.entityId), ...(e.payload as Record<string, unknown>) });
    const rows: Prisma.StockMovementCreateManyInput[] = [];
    const recipes = new Map<string, Awaited<ReturnType<InventoryService['recipeFor']>>>();
    const products = new Map<string, InventoryProduct | null>();
    for (const [lineId, l] of lines) {
      if (l.status === 'reversed') continue;
      let variantId = l.variant_id ? String(l.variant_id) : null;
      if (!variantId && l.menu_item_id) {
        variantId = (await tx.menuVariant.findFirst({ where: { itemId: String(l.menu_item_id), isDefault: true } }))?.id ?? null;
      }
      if (!variantId) continue;
      if (!recipes.has(variantId)) recipes.set(variantId, await this.recipeFor(tx, variantId));
      for (const r of recipes.get(variantId)!) {
        if (!products.has(r.productId)) products.set(r.productId, await tx.inventoryProduct.findUnique({ where: { id: r.productId } }));
        const p = products.get(r.productId);
        if (!p) continue;
        const qty = -round3(this.toBase(p, r.quantity, r.unit) * Number(l.qty ?? 1));
        const avg = d(p.avgCostPaise);
        rows.push({
          tenantId, productId: p.id, locationId: p.defaultLocationId, type: 'sale', quantity: qty, enteredQty: Math.abs(qty), enteredUnit: p.baseUnit,
          valuePaise: Math.round(qty * avg), unitCostPaise: avg, sourceType: 'bill_line', sourceId: lineId, reference: bill.id,
          reason: `Sold: ${String(l.name_snapshot ?? '')} × ${Number(l.qty ?? 1)}`,
        });
      }
    }
    if (!rows.length) return 0;
    await this.lock(tx, rows.map((r) => r.productId));
    return (await tx.stockMovement.createMany({ data: rows, skipDuplicates: true })).count;
  }
}
