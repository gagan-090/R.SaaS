import ExcelJS from 'exceljs';
import { Prisma } from '@prisma/client';
import type { Actor } from '../common/actor';
import { compatible, convert, UNIT_KEYS } from '../common/units';
import { Tx } from '../db/db.service';
import { InventoryService } from '../inventory/inventory.service';
import { INVENTORY_SHEETS } from './templates';
import { CellIssue, readSheet, RowReader } from './xlsx';

const cols = (sheet: string) => INVENTORY_SHEETS.find((s) => s.sheet === sheet)!.columns;

export interface InventoryPlan {
  suppliersToCreate: string[];
  locationsToCreate: string[];
  products: { row: number; sku: string; op: 'create' | 'update'; data: Record<string, unknown>; before?: Record<string, unknown> }[];
  opening: { row: number; sku: string; quantity: number; unit: string; baseQty: number; baseUnit: string; unitCostPaise: number | null; location: string | null; batchNumber: string | null; expiryDate: string | null; valuePaise: number }[];
}

const num = (v: Prisma.Decimal | number | null | undefined) => (v === null || v === undefined ? 0 : Number(v));

/** Validates an inventory workbook and builds the exact plan (products and the opening-stock movements). */
export async function validateInventory(tx: Tx, inv: InventoryService, wb: ExcelJS.Workbook, mode: 'create' | 'update', issues: CellIssue[]): Promise<InventoryPlan> {
  const all = (s: string) => cols(s).map((c) => c.name);
  const headerReq = (s: string) => cols(s).filter((c) => c.required === 'yes' || (mode === 'create' && c.required === 'create')).map((c) => c.name);
  const prodRows = readSheet(wb, 'Products', headerReq('Products'), all('Products').filter((c) => !headerReq('Products').includes(c)), issues, false) ?? [];
  const openRows = readSheet(wb, 'OpeningStock', headerReq('OpeningStock'), all('OpeningStock').filter((c) => !headerReq('OpeningStock').includes(c)), issues, false) ?? [];
  if (!prodRows.length && !openRows.length && !issues.some((i) => i.severity === 'error')) {
    issues.push({ sheet: 'Products', row: 0, column: '', message: 'Nothing to import: fill the Products and/or OpeningStock sheet', severity: 'error' });
  }
  const [products, suppliers, locations] = await Promise.all([tx.inventoryProduct.findMany({}), tx.supplier.findMany({}), tx.inventoryLocation.findMany({})]);
  const bySku = new Map(products.map((p) => [p.sku.toUpperCase(), p]));
  const supByName = new Map(suppliers.map((s) => [s.name.trim().toLowerCase(), s]));
  const locByName = new Map(locations.map((l) => [l.name.trim().toLowerCase(), l]));
  const plan: InventoryPlan = { suppliersToCreate: [], locationsToCreate: [], products: [], opening: [] };
  const addName = (list: string[], known: Map<string, unknown>, name: string) => {
    if (!known.has(name.toLowerCase()) && !list.some((x) => x.toLowerCase() === name.toLowerCase())) list.push(name);
  };

  const seen = new Map<string, number>();
  for (const r of prodRows) {
    const g = new RowReader('Products', r, issues);
    const sku = g.code('sku');
    if (!sku) continue;
    if (seen.has(sku)) {
      g.error('sku', `Duplicate sku (also on row ${seen.get(sku)})`);
      continue;
    }
    seen.set(sku, r.row);
    const existing = bySku.get(sku);
    if (mode === 'create' && existing) g.error('sku', `${sku} already exists — use "Update existing" to change it`);
    if (mode === 'update' && !existing) g.error('sku', `${sku} is not in your inventory — use "Create only" to add it`);
    const creating = !existing;
    const name = g.text('product_name', { required: creating, max: 120 });
    const category = g.text('category', { max: 60 });
    const base = g.enumOf('base_unit', UNIT_KEYS, creating);
    const purchase = g.enumOf('purchase_unit', UNIT_KEYS, creating);
    const factor = g.number('conversion_factor', { required: creating, positive: true, max: 1_000_000 });
    const cost = g.paise('unit_cost');
    const min = g.number('minimum_stock', { max: 1_000_000_000 });
    const supplier = g.text('supplier', { max: 80 });
    const location = g.text('storage_location', { max: 60 });
    const active = g.bool('active');
    const effBase = base ?? existing?.baseUnit, effPurchase = purchase ?? existing?.purchaseUnit;
    if (effBase && effPurchase && effBase === effPurchase && factor !== null && factor !== 1) g.error('conversion_factor', 'Base and purchase unit are the same, so conversion_factor must be 1');
    if (effBase && effPurchase && compatible(effBase, effPurchase) && effBase !== effPurchase && factor !== null) {
      const expect = convert(1, effPurchase, effBase);
      if (Math.abs(expect - factor) > 1e-6) g.error('conversion_factor', `1 ${effPurchase} is ${expect} ${effBase}, not ${factor}`);
    }
    if (existing && base && base !== existing.baseUnit && (await tx.stockMovement.count({ where: { productId: existing.id } }))) {
      g.error('base_unit', `The base unit of ${sku} cannot change after stock has moved`);
    }
    if (supplier) addName(plan.suppliersToCreate, supByName, supplier);
    if (location) addName(plan.locationsToCreate, locByName, location);
    const data: Record<string, unknown> = {};
    if (name !== null) data.name = name;
    if (category !== null) data.category = category.toUpperCase() === 'CLEAR' ? null : category;
    if (base !== null) data.baseUnit = base;
    if (purchase !== null) data.purchaseUnit = purchase;
    if (factor !== null) data.conversionFactor = factor;
    if (cost !== null) data.unitCostPaise = cost;
    if (min !== null) data.minStock = min;
    if (supplier !== null) data.supplier = supplier;
    if (location !== null) data.location = location;
    if (active !== null) data.active = active;
    else if (creating) data.active = true;
    plan.products.push({
      row: r.row, sku, op: creating ? 'create' : 'update', data,
      ...(existing ? { before: { name: existing.name, category: existing.category, baseUnit: existing.baseUnit, purchaseUnit: existing.purchaseUnit, conversionFactor: num(existing.conversionFactor), unitCostPaise: existing.unitCostPaise, minStock: num(existing.minStock), active: existing.active } } : {}),
    });
  }

  const openingSeen = new Map<string, number>();
  for (const r of openRows) {
    const g = new RowReader('OpeningStock', r, issues);
    const sku = g.code('sku');
    const qty = g.number('quantity', { required: true, positive: true });
    const unit = g.enumOf('unit', UNIT_KEYS, true);
    const cost = g.paise('unit_cost');
    const location = g.text('storage_location', { max: 60 });
    const batch = g.text('batch_number', { max: 40 });
    const expiry = g.date('expiry_date');
    if (!sku || qty === null || !unit) continue;
    const fromFile = plan.products.find((p) => p.sku === sku);
    const existing = bySku.get(sku);
    const prod = existing
      ? { sku, baseUnit: String(fromFile?.data.baseUnit ?? existing.baseUnit), purchaseUnit: String(fromFile?.data.purchaseUnit ?? existing.purchaseUnit), conversionFactor: new Prisma.Decimal(Number(fromFile?.data.conversionFactor ?? existing.conversionFactor)), unitCostPaise: Number(fromFile?.data.unitCostPaise ?? existing.unitCostPaise), defaultLocationId: existing.defaultLocationId }
      : fromFile && fromFile.data.baseUnit
        ? { sku, baseUnit: String(fromFile.data.baseUnit), purchaseUnit: String(fromFile.data.purchaseUnit), conversionFactor: new Prisma.Decimal(Number(fromFile.data.conversionFactor ?? 1)), unitCostPaise: Number(fromFile.data.unitCostPaise ?? 0), defaultLocationId: null }
        : null;
    if (!prod) {
      g.error('sku', `No product ${sku} in the Products sheet or your inventory`);
      continue;
    }
    let baseQty: number;
    try {
      baseQty = inv.toBase(prod, qty, unit);
    } catch (e) {
      g.error('unit', e instanceof Error ? e.message : 'Unit does not convert');
      continue;
    }
    const locName = location ?? (fromFile?.data.location as string | undefined) ?? null;
    if (location) addName(plan.locationsToCreate, locByName, location);
    const locKey = `${sku}@${(locName ?? '').toLowerCase()}`;
    if (openingSeen.has(locKey)) {
      g.error('sku', `Opening stock for ${sku} at this location is already on row ${openingSeen.get(locKey)}`);
      continue;
    }
    openingSeen.set(locKey, r.row);
    if (existing) {
      const locId = locName ? (locByName.get(locName.toLowerCase())?.id ?? '__new__') : existing.defaultLocationId;
      if (locId !== '__new__' && (await tx.stockMovement.findFirst({ where: { productId: existing.id, type: 'opening', locationId: locId ?? null } }))) {
        g.error('sku', `${sku} already has opening stock here. Record a purchase or a stock count instead.`);
        continue;
      }
    }
    // cost per base unit: the row's cost for one "unit", else the product's cost per purchase unit
    const perBase = cost !== null ? cost / inv.toBase(prod, 1, unit) : prod.unitCostPaise / num(prod.conversionFactor);
    plan.opening.push({
      row: r.row, sku, quantity: qty, unit, baseQty, baseUnit: prod.baseUnit, unitCostPaise: cost ?? null, location: locName, batchNumber: batch, expiryDate: expiry,
      valuePaise: Math.round(baseQty * perBase),
    });
  }
  return plan;
}

export function inventorySkips(plan: InventoryPlan, issues: CellIssue[]) {
  const bad = (sheet: string) => new Set(issues.filter((i) => i.severity === 'error' && i.sheet === sheet).map((i) => i.row));
  const badP = bad('Products'), badO = bad('OpeningStock');
  const skippedSkus = new Set(plan.products.filter((p) => badP.has(p.row) && p.op === 'create').map((p) => p.sku));
  const products = plan.products.filter((p) => !badP.has(p.row));
  const opening = plan.opening.filter((o) => !badO.has(o.row) && !skippedSkus.has(o.sku));
  return {
    products, opening,
    skipped: [
      ...plan.products.filter((p) => badP.has(p.row)).map((p) => ({ sheet: 'Products', row: p.row, code: p.sku })),
      ...plan.opening.filter((o) => badO.has(o.row) || skippedSkus.has(o.sku)).map((o) => ({ sheet: 'OpeningStock', row: o.row, code: o.sku })),
    ],
  };
}

/** Writes a validated inventory plan: names, products, then each opening-stock row as an idempotent ledger movement. */
export async function commitInventory(tx: Tx, inv: InventoryService, a: Actor, jobId: string, fileSha: string, plan: InventoryPlan) {
  const tenantId = a.tenantId!;
  const sup = new Map((await tx.supplier.findMany({})).map((s) => [s.name.trim().toLowerCase(), s.id]));
  const loc = new Map((await tx.inventoryLocation.findMany({})).map((l) => [l.name.trim().toLowerCase(), l.id]));
  const counts = { productsCreated: 0, productsUpdated: 0, suppliersCreated: 0, locationsCreated: 0, openingMovements: 0, openingAlreadyImported: 0 };
  const needSup = new Set(plan.products.map((p) => p.data.supplier as string | undefined).filter(Boolean).map((s) => s!.toLowerCase()));
  const needLoc = new Set([...plan.products.map((p) => p.data.location as string | undefined), ...plan.opening.map((o) => o.location ?? undefined)].filter(Boolean).map((s) => s!.toLowerCase()));
  for (const s of plan.suppliersToCreate) {
    if (!sup.has(s.toLowerCase()) && needSup.has(s.toLowerCase())) {
      sup.set(s.toLowerCase(), (await tx.supplier.create({ data: { tenantId, name: s } })).id);
      counts.suppliersCreated++;
    }
  }
  for (const l of plan.locationsToCreate) {
    if (!loc.has(l.toLowerCase()) && needLoc.has(l.toLowerCase())) {
      loc.set(l.toLowerCase(), (await tx.inventoryLocation.create({ data: { tenantId, name: l } })).id);
      counts.locationsCreated++;
    }
  }
  for (const p of plan.products) {
    const { supplier, location, ...d } = p.data as Record<string, unknown> & { supplier?: string; location?: string };
    const data = {
      ...d,
      ...(supplier !== undefined ? { defaultSupplierId: sup.get(supplier.toLowerCase()) ?? null } : {}),
      ...(location !== undefined ? { defaultLocationId: loc.get(location.toLowerCase()) ?? null } : {}),
    } as Prisma.InventoryProductUncheckedUpdateInput;
    if (p.op === 'create') {
      const factor = Number(d.conversionFactor);
      await tx.inventoryProduct.create({ data: { ...(data as object), tenantId, sku: p.sku, avgCostPaise: Number(d.unitCostPaise ?? 0) / factor } as Prisma.InventoryProductUncheckedCreateInput });
      counts.productsCreated++;
    } else {
      await tx.inventoryProduct.update({ where: { tenantId_sku: { tenantId, sku: p.sku } }, data });
      counts.productsUpdated++;
    }
  }
  const ids = new Map((await tx.inventoryProduct.findMany({})).map((p) => [p.sku.toUpperCase(), p.id]));
  for (const o of plan.opening) {
    const r = await inv.record(tx, a, {
      type: 'opening', productId: ids.get(o.sku)!, quantity: o.quantity, unit: o.unit,
      locationId: o.location ? loc.get(o.location.toLowerCase()) : undefined,
      unitCostPaise: o.unitCostPaise ?? undefined, batchNumber: o.batchNumber, expiryDate: o.expiryDate,
      reason: 'Opening stock (Excel import)',
      // the same file row never adds stock twice, even if the import is retried or the file uploaded again
      idempotencyKey: `import:${fileSha}:opening:${o.row}`, sourceType: 'import', sourceId: jobId,
    });
    if (r.duplicate) counts.openingAlreadyImported++;
    else counts.openingMovements++;
  }
  return counts;
}
