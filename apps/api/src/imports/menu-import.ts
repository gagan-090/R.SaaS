import ExcelJS from 'exceljs';
import { compatible, UNIT_KEYS } from '../common/units';
import { Tx } from '../db/db.service';
import { saveVariants } from '../menu/menu.controller';
import { MENU_SHEETS } from './templates';
import { CellIssue, readSheet, RowReader } from './xlsx';

const cols = (sheet: string) => MENU_SHEETS.find((s) => s.sheet === sheet)!.columns;
const reqCols = (sheet: string) => cols(sheet).filter((c) => c.required === 'yes' || c.required === 'create').map((c) => c.name);
const optCols = (sheet: string) => cols(sheet).filter((c) => c.required === 'no').map((c) => c.name);

export interface MenuPlan {
  categoriesToCreate: string[];
  items: { row: number; code: string; op: 'create' | 'update'; data: Record<string, unknown>; before?: Record<string, unknown> }[];
  variants: { row: number; itemCode: string; code: string; op: 'create' | 'update'; data: Record<string, unknown>; before?: Record<string, unknown> }[];
  recipes: { variantCode: string; rows: number[]; lines: { sku: string; quantity: number; unit: string }[] }[];
}

/**
 * Validates a menu workbook against the restaurant's data and builds the exact plan. Nothing is written.
 * create mode: every code must be new. update mode: every code must exist; blank cells keep current values.
 */
export async function validateMenu(tx: Tx, wb: ExcelJS.Workbook, mode: 'create' | 'update', features: string[], issues: CellIssue[]): Promise<MenuPlan> {
  const [items, variants, cats, taxes] = await Promise.all([
    tx.menuItem.findMany({ where: { deleted: false } }),
    tx.menuVariant.findMany({}),
    tx.menuCategory.findMany({ where: { deleted: false } }),
    tx.taxRule.findMany({ where: { deleted: false } }),
  ]);
  const itemByCode = new Map(items.map((i) => [i.code.toUpperCase(), i]));
  const varByCode = new Map(variants.map((v) => [v.code.toUpperCase(), v]));
  const catByName = new Map(cats.map((c) => [c.name.trim().toLowerCase(), c]));
  const taxFor = (s: string) => {
    const t = s.trim().toLowerCase().replace(/%$/, '');
    return taxes.find((x) => x.name.trim().toLowerCase() === s.trim().toLowerCase()) ?? taxes.find((x) => String(x.rateBp / 100) === t || `gst ${x.rateBp / 100}` === t);
  };

  const plan: MenuPlan = { categoriesToCreate: [], items: [], variants: [], recipes: [] };
  const seenItems = new Map<string, number>();
  const seenVars = new Map<string, number>();

  const isPosTemplate = wb.worksheets.some((w) => w.name.trim().toLowerCase() === 'menu database');
  if (isPosTemplate) {
    const itemRows = readSheet(wb, 'Menu Database', ['item code', 'category', 'item name'], ['subcategory', 'food type', 'sample price', 'currency', 'tax rate (%)', 'availability', 'prep time (min)', 'unit', 'image url', 'notes', 'half plate price (inr)', 'full plate price (inr)', 'variant count', 'pricing note', 'variant pricing sheet'], issues, false) ?? [];
    const varRows = readSheet(wb, 'Item Variants', ['item code', 'serving size', 'price (inr)'], ['variant sku', 'category', 'subcategory', 'item name', 'food type', 'quantity', 'unit', 'currency', 'tax rate (%)', 'availability', 'prep time (min)', 'notes'], issues, false) ?? [];

    const defaultTax = taxes.find((x) => x.rateBp === 500) ?? taxes[0];
    if (!defaultTax) {
      issues.push({ sheet: 'Menu Database', row: 1, column: 'tax rate (%)', message: 'No active tax rule found. Create a GST rule in Settings first.', severity: 'error' });
      return plan;
    }

    for (const r of itemRows) {
      const g = new RowReader('Menu Database', r, issues);
      const code = g.code('item code');
      if (!code) continue;
      if (seenItems.has(code)) {
        g.error('item code', `Duplicate item code (also on row ${seenItems.get(code)})`);
        continue;
      }
      seenItems.set(code, r.row);
      const existing = itemByCode.get(code);
      if (mode === 'create' && existing) g.error('item code', `${code} already exists — use "Update existing" to change it`);
      if (mode === 'update' && !existing) g.error('item code', `${code} is not on your menu — use "Create only" to add it`);
      const name = g.text('item name', { required: mode === 'create', max: 120 });
      const category = g.text('category', { required: mode === 'create', max: 60 });
      const desc = g.text('notes', { max: 500 });
      const foodType = String(r.cells['food type'] ?? '').trim().toLowerCase();
      const isVeg = foodType.includes('veg') && !foodType.includes('non');
      const avail = String(r.cells['availability'] ?? 'Available').trim().toLowerCase();
      const active = avail !== 'unavailable';

      if (category && !catByName.has(category.toLowerCase()) && !plan.categoriesToCreate.some((c) => c.toLowerCase() === category.toLowerCase())) {
        plan.categoriesToCreate.push(category);
      }
      const data: Record<string, unknown> = { isVeg };
      if (name !== null) data.name = name;
      if (category !== null) data.category = category;
      if (desc !== null) data.description = desc.toUpperCase() === 'CLEAR' ? null : desc;
      if (active !== null) data.active = active;
      else if (mode === 'create') data.active = true;
      plan.items.push({
        row: r.row, code, op: existing ? 'update' : 'create', data,
        ...(existing ? { before: { name: existing.name, category: cats.find((c) => c.id === existing.categoryId)?.name, description: existing.description, active: existing.active } } : {}),
      });
    }

    const fileItemCodes = new Set(plan.items.map((i) => i.code));
    if (varRows.length > 0) {
      for (const [idx, r] of varRows.entries()) {
        const g = new RowReader('Item Variants', r, issues);
        const itemCode = g.code('item code');
        const rawSku = g.code('variant sku');
        const code = rawSku || `${itemCode}-V${idx + 1}`;
        if (!itemCode || !code) continue;
        if (seenVars.has(code)) {
          g.error('variant sku', `Duplicate variant SKU (also on row ${seenVars.get(code)})`);
          continue;
        }
        seenVars.set(code, r.row);
        if (!fileItemCodes.has(itemCode) && !itemByCode.has(itemCode)) g.error('item code', `Item ${itemCode} is not in the Menu Database or on your menu`);
        const existing = varByCode.get(code);
        const owner = existing ? items.find((i) => i.id === existing.itemId) : undefined;
        if (existing && owner && owner.code.toUpperCase() !== itemCode) g.error('variant sku', `${code} belongs to item ${owner.code}`);
        if (mode === 'create' && existing) g.error('variant sku', `${code} already exists — use "Update existing" to change it`);
        if (mode === 'update' && !existing) g.error('variant sku', `${code} does not exist — use "Create only" to add it`);
        const creating = !existing;
        const name = g.text('serving size', { required: creating, max: 40 }) || 'Regular';
        const qty = g.number('quantity', { positive: true, max: 1_000_000 });
        const rawUnit = String(r.cells['unit'] ?? '').toLowerCase();
        const unit = UNIT_KEYS.includes(rawUnit) ? rawUnit : undefined;
        const price = g.paise('price (inr)', creating);
        const avail = String(r.cells['availability'] ?? 'Available').trim().toLowerCase();
        const available = avail !== 'unavailable';

        const data: Record<string, unknown> = {
          taxRuleId: defaultTax.id,
          taxName: defaultTax.name,
        };
        if (name !== null) data.name = name;
        if (qty !== null && unit !== undefined) Object.assign(data, { servingQuantity: qty, servingUnit: unit });
        if (price !== null) data.pricePaise = price;
        data.available = available;
        plan.variants.push({
          row: r.row, itemCode, code, op: creating ? 'create' : 'update', data,
          ...(existing ? { before: { name: existing.name, pricePaise: existing.pricePaise, available: existing.available } } : {}),
        });
      }
    } else {
      for (const it of plan.items) {
        const itemRow = itemRows.find((r) => String(r.cells['item code'] ?? '').trim().toUpperCase() === it.code);
        const half = itemRow?.cells['half plate price (inr)'] ? Number(itemRow.cells['half plate price (inr)']) : null;
        const full = itemRow?.cells['full plate price (inr)'] ? Number(itemRow.cells['full plate price (inr)']) : null;
        const sample = itemRow?.cells['sample price'] ? Number(itemRow.cells['sample price']) : 100;

        if (half && full) {
          plan.variants.push(
            { row: it.row, itemCode: it.code, code: `${it.code}-HALF`, op: 'create', data: { name: 'Half Plate', pricePaise: Math.round(half * 100), portionLabel: 'half', portionRatio: 0.5, available: true, taxRuleId: defaultTax.id, taxName: defaultTax.name } },
            { row: it.row, itemCode: it.code, code: `${it.code}-FULL`, op: 'create', data: { name: 'Full Plate', pricePaise: Math.round(full * 100), portionLabel: 'full', portionRatio: 1.0, available: true, taxRuleId: defaultTax.id, taxName: defaultTax.name } },
          );
        } else {
          plan.variants.push(
            { row: it.row, itemCode: it.code, code: `${it.code}-REG`, op: 'create', data: { name: 'Regular', pricePaise: Math.round(sample * 100), available: true, taxRuleId: defaultTax.id, taxName: defaultTax.name } },
          );
        }
      }
    }

    for (const it of plan.items.filter((i) => i.op === 'create')) {
      if (!plan.variants.some((v) => v.itemCode === it.code)) {
        issues.push({ sheet: 'Menu Database', row: it.row, column: 'item code', message: `${it.code} needs at least one variant`, severity: 'error' });
      }
    }
    return plan;
  }

  // in update mode only the code columns are mandatory in the header
  const headerReq = (s: string) => (mode === 'create' ? reqCols(s) : cols(s).filter((c) => c.required === 'yes').map((c) => c.name));
  const headerOpt = (s: string) => cols(s).map((c) => c.name).filter((c) => !headerReq(s).includes(c));
  const itemRows = readSheet(wb, 'Items', headerReq('Items'), headerOpt('Items'), issues, mode === 'create') ?? [];
  const varRows = readSheet(wb, 'Variants', headerReq('Variants'), headerOpt('Variants'), issues, mode === 'create') ?? [];
  const recRows = readSheet(wb, 'Recipes', reqCols('Recipes'), optCols('Recipes'), issues, false) ?? [];

  for (const r of itemRows) {
    const g = new RowReader('Items', r, issues);
    const code = g.code('item_code');
    if (!code) continue;
    if (seenItems.has(code)) {
      g.error('item_code', `Duplicate item_code (also on row ${seenItems.get(code)})`);
      continue;
    }
    seenItems.set(code, r.row);
    const existing = itemByCode.get(code);
    if (mode === 'create' && existing) g.error('item_code', `${code} already exists — use "Update existing" to change it`);
    if (mode === 'update' && !existing) g.error('item_code', `${code} is not on your menu — use "Create only" to add it`);
    const name = g.text('item_name', { required: mode === 'create', max: 120 });
    const category = g.text('category', { required: mode === 'create', max: 60 });
    const desc = g.text('description', { max: 500 });
    const active = g.bool('active');
    if (category && !catByName.has(category.toLowerCase()) && !plan.categoriesToCreate.some((c) => c.toLowerCase() === category.toLowerCase())) plan.categoriesToCreate.push(category);
    const data: Record<string, unknown> = {};
    if (name !== null) data.name = name;
    if (category !== null) data.category = category;
    if (desc !== null) data.description = desc.toUpperCase() === 'CLEAR' ? null : desc;
    if (active !== null) data.active = active;
    else if (mode === 'create') data.active = true;
    plan.items.push({
      row: r.row, code, op: existing ? 'update' : 'create', data,
      ...(existing ? { before: { name: existing.name, category: cats.find((c) => c.id === existing.categoryId)?.name, description: existing.description, active: existing.active } } : {}),
    });
  }

  seenVars.clear();
  const fileItemCodes = new Set(plan.items.map((i) => i.code));
  for (const r of varRows) {
    const g = new RowReader('Variants', r, issues);
    const itemCode = g.code('item_code');
    const code = g.code('variant_code');
    if (!itemCode || !code) continue;
    if (seenVars.has(code)) {
      g.error('variant_code', `Duplicate variant_code (also on row ${seenVars.get(code)})`);
      continue;
    }
    seenVars.set(code, r.row);
    if (!fileItemCodes.has(itemCode) && !itemByCode.has(itemCode)) g.error('item_code', `Item ${itemCode} is not in the Items sheet or on your menu`);
    const existing = varByCode.get(code);
    const owner = existing ? items.find((i) => i.id === existing.itemId) : undefined;
    if (existing && owner && owner.code.toUpperCase() !== itemCode) g.error('variant_code', `${code} belongs to item ${owner.code}`);
    if (mode === 'create' && existing) g.error('variant_code', `${code} already exists — use "Update existing" to change it`);
    if (mode === 'update' && !existing) g.error('variant_code', `${code} does not exist — use "Create only" to add it`);
    const creating = !existing;
    const name = g.text('variant_name', { required: creating, max: 40 });
    const portion = g.text('portion_label', { max: 30 });
    const qty = g.number('serving_quantity', { positive: true, max: 1_000_000 });
    const unit = g.enumOf('serving_unit', UNIT_KEYS);
    if ((qty === null) !== (unit === null) && (creating || !g.blank('serving_quantity') || !g.blank('serving_unit'))) {
      g.error('serving_unit', 'Give both serving_quantity and serving_unit, or neither');
    }
    const ratio = g.number('portion_ratio', { positive: true, max: 100 });
    const price = g.paise('selling_price', creating);
    const taxText = g.text('tax_code', { required: creating, max: 40 });
    const tax = taxText ? taxFor(taxText) : undefined;
    if (taxText && !tax) g.error('tax_code', `No GST rule called "${taxText}". Add it in Settings first (e.g. GST 5%).`);
    const available = g.bool('available');
    const data: Record<string, unknown> = {};
    if (name !== null) data.name = name;
    if (portion !== null) data.portionLabel = portion;
    if (qty !== null && unit !== null) Object.assign(data, { servingQuantity: qty, servingUnit: unit });
    if (ratio !== null) data.portionRatio = ratio;
    if (price !== null) data.pricePaise = price;
    if (tax) Object.assign(data, { taxRuleId: tax.id, taxName: tax.name });
    if (available !== null) data.available = available;
    else if (creating) data.available = true;
    plan.variants.push({
      row: r.row, itemCode, code, op: creating ? 'create' : 'update', data,
      ...(existing ? { before: { name: existing.name, pricePaise: existing.pricePaise, available: existing.available, portionLabel: existing.portionLabel } } : {}),
    });
  }
  for (const it of plan.items.filter((i) => i.op === 'create')) {
    if (!plan.variants.some((v) => v.itemCode === it.code)) {
      issues.push({ sheet: 'Items', row: it.row, column: 'item_code', message: `${it.code} needs at least one row in the Variants sheet`, severity: 'error' });
    }
  }

  if (recRows.length) {
    if (!features.includes('inventory')) {
      issues.push({ sheet: 'Recipes', row: 0, column: '', message: 'Recipes need inventory in your plan; this sheet cannot be imported', severity: 'error' });
    } else {
      const products = new Map((await tx.inventoryProduct.findMany({})).map((p) => [p.sku.toUpperCase(), p]));
      const byVar = new Map<string, MenuPlan['recipes'][number]>();
      for (const r of recRows) {
        const g = new RowReader('Recipes', r, issues);
        const vc = g.code('variant_code');
        const sku = g.code('ingredient_sku');
        const qty = g.number('consumption_quantity', { required: true, positive: true, max: 1_000_000 });
        const unit = g.enumOf('consumption_unit', UNIT_KEYS, true);
        if (!vc || !sku || qty === null || unit === null) continue;
        if (!seenVars.has(vc) && !varByCode.has(vc)) g.error('variant_code', `Variant ${vc} is not in the Variants sheet or on your menu`);
        const p = products.get(sku);
        if (!p) {
          g.error('ingredient_sku', `No inventory product with SKU ${sku}`);
          continue;
        }
        if (unit !== p.purchaseUnit && unit !== p.baseUnit && !compatible(unit, p.baseUnit)) {
          g.error('consumption_unit', `${sku} is counted in ${p.baseUnit}; ${unit} cannot be converted to it`);
          continue;
        }
        const rec = byVar.get(vc) ?? { variantCode: vc, rows: [], lines: [] };
        if (rec.lines.some((l) => l.sku === sku)) {
          g.error('ingredient_sku', `${sku} is listed twice for ${vc}`);
          continue;
        }
        rec.rows.push(r.row);
        rec.lines.push({ sku, quantity: qty, unit });
        byVar.set(vc, rec);
      }
      plan.recipes = [...byVar.values()];
    }
  }
  return plan;
}

/** Rows to leave out when importing only the valid rows: errored rows and anything that depends on them. */
export function menuSkips(plan: MenuPlan, issues: CellIssue[]) {
  const bad = (sheet: string) => new Set(issues.filter((i) => i.severity === 'error' && i.sheet === sheet).map((i) => i.row));
  const badItems = bad('Items'), badVars = bad('Variants'), badRec = bad('Recipes');
  const skippedItems = new Set(plan.items.filter((i) => badItems.has(i.row)).map((i) => i.code));
  // a new item is only created with at least one valid size
  for (const it of plan.items.filter((i) => i.op === 'create')) {
    if (!plan.variants.some((v) => v.itemCode === it.code && !badVars.has(v.row))) skippedItems.add(it.code);
  }
  const keepVar = (v: MenuPlan['variants'][number]) => !badVars.has(v.row) && !skippedItems.has(v.itemCode);
  const skippedVars = new Set(plan.variants.filter((v) => !keepVar(v)).map((v) => v.code));
  return {
    items: plan.items.filter((i) => !skippedItems.has(i.code)),
    variants: plan.variants.filter(keepVar),
    recipes: plan.recipes.filter((r) => !skippedVars.has(r.variantCode) && !r.rows.some((row) => badRec.has(row))),
    skipped: [
      ...plan.items.filter((i) => skippedItems.has(i.code)).map((i) => ({ sheet: 'Items', row: i.row, code: i.code })),
      ...plan.variants.filter((v) => !keepVar(v)).map((v) => ({ sheet: 'Variants', row: v.row, code: v.code })),
      ...plan.recipes.filter((r) => skippedVars.has(r.variantCode) || r.rows.some((row) => badRec.has(row))).flatMap((r) => r.rows.map((row) => ({ sheet: 'Recipes', row, code: r.variantCode }))),
    ],
  };
}

/** Writes a validated menu plan in the caller's transaction. */
export async function commitMenu(tx: Tx, tenantId: string, plan: Pick<MenuPlan, 'items' | 'variants' | 'recipes'> & { categoriesToCreate: string[] }) {
  const cats = new Map((await tx.menuCategory.findMany({ where: { deleted: false } })).map((c) => [c.name.trim().toLowerCase(), c.id]));
  let order = await tx.menuCategory.count();
  for (const name of plan.categoriesToCreate) {
    if (cats.has(name.toLowerCase())) continue;
    if (!plan.items.some((i) => String(i.data.category ?? '').toLowerCase() === name.toLowerCase())) continue;
    cats.set(name.toLowerCase(), (await tx.menuCategory.create({ data: { tenantId, name, sortOrder: (++order) * 10 } })).id);
  }
  const counts = { itemsCreated: 0, itemsUpdated: 0, variantsCreated: 0, variantsUpdated: 0, recipesSet: 0 };
  const ids = new Map((await tx.menuItem.findMany({ where: { deleted: false } })).map((i) => [i.code.toUpperCase(), i]));
  for (const it of plan.items) {
    const d = it.data as { name?: string; category?: string; description?: string | null; active?: boolean };
    if (it.op === 'create') {
      const vs = plan.variants.filter((v) => v.itemCode === it.code);
      const first = vs[0].data as { pricePaise: number; taxRuleId: string };
      const created = await tx.menuItem.create({
        data: {
          tenantId, code: it.code, name: d.name!, categoryId: cats.get(d.category!.toLowerCase())!, description: d.description ?? null,
          active: d.active ?? true, isVeg: (d as { isVeg?: boolean }).isVeg ?? true, taxRuleId: first.taxRuleId, pricePaise: first.pricePaise,
        },
      });
      await saveVariants(tx, tenantId, created, vs.map((v, i) => ({ ...(v.data as never as object), code: v.code, isDefault: i === 0, available: (v.data.available as boolean) ?? true }) as never));
      ids.set(it.code, created);
      counts.itemsCreated++;
      counts.variantsCreated += vs.length;
    } else {
      const ex = ids.get(it.code)!;
      await tx.menuItem.update({
        where: { id: ex.id },
        data: {
          ...(d.name !== undefined ? { name: d.name } : {}), ...(d.category !== undefined ? { categoryId: cats.get(d.category.toLowerCase())! } : {}),
          ...(d.description !== undefined ? { description: d.description } : {}), ...(d.active !== undefined ? { active: d.active } : {}),
          ...((d as { isVeg?: boolean }).isVeg !== undefined ? { isVeg: (d as { isVeg?: boolean }).isVeg } : {}),
        },
      });
      counts.itemsUpdated++;
    }
  }
  // sizes of items that already existed (create mode: new sizes; update mode: changed fields only)
  for (const v of plan.variants.filter((x) => !plan.items.some((i) => i.code === x.itemCode && i.op === 'create'))) {
    const item = ids.get(v.itemCode)!;
    const d = { ...(v.data as Record<string, unknown>) };
    delete d.taxName; // shown in the preview only
    if (v.op === 'create') {
      const n = await tx.menuVariant.count({ where: { itemId: item.id } });
      await tx.menuVariant.create({ data: { ...(d as object), name: String(d.name), pricePaise: Number(d.pricePaise), tenantId, itemId: item.id, code: v.code, sortOrder: n, isDefault: false } });
      counts.variantsCreated++;
    } else {
      const row = await tx.menuVariant.update({ where: { tenantId_code: { tenantId, code: v.code } }, data: d });
      if (row.isDefault && d.pricePaise !== undefined) await tx.menuItem.update({ where: { id: item.id }, data: { pricePaise: Number(d.pricePaise) } });
      counts.variantsUpdated++;
    }
  }
  if (plan.recipes.length) {
    const products = new Map((await tx.inventoryProduct.findMany({})).map((p) => [p.sku.toUpperCase(), p.id]));
    for (const r of plan.recipes) {
      const v = await tx.menuVariant.findUniqueOrThrow({ where: { tenantId_code: { tenantId, code: r.variantCode } } });
      await tx.recipeLine.deleteMany({ where: { variantId: v.id } });
      await tx.recipeLine.createMany({ data: r.lines.map((l) => ({ tenantId, variantId: v.id, productId: products.get(l.sku)!, quantity: l.quantity, unit: l.unit })) });
      counts.recipesSet++;
    }
  }
  await tx.restaurantTenant.update({ where: { id: tenantId }, data: { menuVersion: { increment: 1 } } });
  return counts;
}
