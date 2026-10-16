import { Body, Controller, Get, Param, ParseUUIDPipe, Patch, Post, Put } from '@nestjs/common';
import { ApiBearerAuth, ApiBody, ApiTags } from '@nestjs/swagger';
import { Prisma } from '@prisma/client';
import { z } from 'zod';
import type { Actor, AuditDetails } from '../common/actor';
import { AuditCtx, CurrentActor } from '../common/actor';
import { Audited, RequirePermissions, RequiresFeature } from '../common/decorators';
import { badRequest, conflict, forbidden, notFound } from '../common/errors';
import { UNIT_KEYS } from '../common/units';
import { apiBody, zbody } from '../common/validation';
import { DbService, Tx } from '../db/db.service';
import { uuidv7 } from '../common/uuid';

export const CODE = z.string().trim().regex(/^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$/, 'Codes use letters, digits, - _ . (max 40)');

export const VariantBody = z
  .object({
    id: z.string().uuid().optional(),
    code: CODE.optional(),
    name: z.string().trim().min(1).max(40),
    portionLabel: z.string().trim().max(30).nullish(),
    servingQuantity: z.number().positive().max(1_000_000).nullish(),
    servingUnit: z.enum(UNIT_KEYS).nullish(),
    portionRatio: z.number().positive().max(100).nullish(),
    pricePaise: z.number().int().nonnegative().max(1_000_000_000),
    costPricePaise: z.number().int().nonnegative().max(1_000_000_000).nullish(),
    taxRuleId: z.string().uuid().nullish(),
    available: z.boolean().default(true),
    isDefault: z.boolean().default(false),
  })
  .refine((v) => !v.servingQuantity === !v.servingUnit, { message: 'Give both a serving quantity and its unit, or neither', path: ['servingUnit'] });
export type VariantIn = z.infer<typeof VariantBody>;

const ItemBody = z
  .object({
    categoryId: z.string().uuid(),
    code: CODE.optional(),
    name: z.string().trim().min(1).max(120),
    description: z.string().max(500).optional(),
    taxRuleId: z.string().uuid(),
    available: z.boolean().default(true),
    active: z.boolean().default(true),
    isVeg: z.boolean().default(true),
    plateColors: z.object({ base: z.string(), sauce: z.string(), garnish: z.string() }).optional(),
    variants: z.array(VariantBody).min(1).max(20).optional(),
    // older clients: one price → one "Regular" variant
    pricePaise: z.number().int().nonnegative().optional(),
    unit: z.string().max(20).optional(),
    quantity: z.number().int().positive().optional(),
  })
export const STANDARD_CATEGORIES = [
  'Soups', 'Veg Starters', 'Non-Veg Starters', 'Tandoori Items',
  'Veg Main Course', 'Paneer Special', 'Dal Special', 'Non-Veg Main Course',
  'Seafood', 'Indian Breads', 'Rice', 'Biryani', 'Pulao',
  'Chinese Starters', 'Chinese Main Course', 'South Indian', 'North Indian',
  'Continental', 'Italian', 'Fast Food', 'Street Food / Chaat',
  'Breakfast', 'Snacks', 'Rolls & Wraps', 'Thali / Combos',
  'Salads', 'Raita & Curd', 'Papad & Accompaniments', 'Desserts',
  'Ice Cream', 'Cakes & Bakery', 'Hot Beverages', 'Cold Beverages',
  'Shakes & Smoothies', 'Fresh Juices', 'Mocktails', 'Packaged Beverages',
  'Kids Menu', 'Jain Food', 'Chef Specials',
];

const QuickVariant = z.object({
  name: z.string().trim().min(1).max(40),
  pricePaise: z.number().int().nonnegative().max(1000000000),
  portionLabel: z.string().max(30).optional(),
  servingQuantity: z.number().positive().optional(),
  servingUnit: z.string().max(20).optional(),
  portionRatio: z.number().positive().optional(),
  isDefault: z.boolean().default(false),
});

const QuickMenuItem = z.object({
  name: z.string().trim().min(1).max(120),
  categoryName: z.string().trim().min(1).max(60).optional(),
  pricePaise: z.number().int().nonnegative().max(1000000000).optional(),
  isVeg: z.boolean().default(true),
  variants: z.array(QuickVariant).min(1).max(20).optional(),
});

const QuickMenuBody = z.object({
  categoryName: z.string().trim().min(1).max(60).optional().default('Main Course'),
  taxRuleId: z.string().uuid(),
  items: z.array(QuickMenuItem).min(1).max(200),
});
const ItemPatch = z.object({
  categoryId: z.string().uuid().optional(),
  name: z.string().trim().min(1).max(120).optional(),
  description: z.string().max(500).nullable().optional(),
  taxRuleId: z.string().uuid().optional(),
  available: z.boolean().optional(),
  active: z.boolean().optional(),
  isVeg: z.boolean().optional(),
  plateColors: z.object({ base: z.string(), sauce: z.string(), garnish: z.string() }).optional(),
  pricePaise: z.number().int().nonnegative().optional(), // older clients: sets the default variant's price
});
const VariantsBody = z.object({ variants: z.array(VariantBody).min(1).max(20) });
const CategoryOrderBody = z.object({ ids: z.array(z.string().uuid()).min(1).max(500) });

const num = (d: Prisma.Decimal | null | undefined) => (d === null || d === undefined ? null : Number(d));
export const variantOut = (v: Prisma.MenuVariantGetPayload<object>) => ({
  id: v.id, itemId: v.itemId, code: v.code, name: v.name, portionLabel: v.portionLabel, servingQuantity: num(v.servingQuantity),
  servingUnit: v.servingUnit, portionRatio: num(v.portionRatio), pricePaise: v.pricePaise, costPricePaise: v.costPricePaise,
  taxRuleId: v.taxRuleId, available: v.available, isDefault: v.isDefault, sortOrder: v.sortOrder,
});
const audited = (vs: { code: string; name: string; pricePaise: number; available: boolean; deleted?: boolean }[]) =>
  vs.map((v) => ({ code: v.code, name: v.name, pricePaise: v.pricePaise, available: v.available, ...(v.deleted ? { deleted: true } : {}) }));

const slug = (s: string) => s.toUpperCase().replace(/[^A-Z0-9]+/g, '').slice(0, 10) || 'V';

/** Next free ITEM-0001 style code in the restaurant. */
export async function nextItemCode(tx: Tx) {
  const n = await tx.menuItem.count();
  for (let i = n + 1; ; i++) {
    const code = `ITEM-${String(i).padStart(4, '0')}`;
    if (!(await tx.menuItem.findFirst({ where: { code } }))) return code;
  }
}

/**
 * Replaces an item's sizes / portions. Matches incoming rows to existing ones by id, else by code; rows not sent are
 * retired (soft-deleted, never removed, so past orders keep their reference). Exactly one default; codes are unique in
 * the restaurant and never reused. The item's legacy price follows the default variant.
 */
export async function saveVariants(tx: Tx, tenantId: string, item: { id: string; code: string }, incoming: VariantIn[]) {
  const existing = await tx.menuVariant.findMany({ where: { itemId: item.id } });
  const byId = new Map(existing.map((v) => [v.id, v]));
  const byCode = new Map(existing.map((v) => [v.code.toUpperCase(), v]));
  const taxIds = [...new Set(incoming.map((v) => v.taxRuleId).filter((x): x is string => !!x))];
  if (taxIds.length && (await tx.taxRule.count({ where: { id: { in: taxIds }, deleted: false } })) !== taxIds.length) throw notFound('Tax rule');
  const defaults = incoming.filter((v) => v.isDefault).length;
  if (defaults > 1) throw badRequest('one_default', 'Only one size can be the default');

  const used = new Set<string>();
  const plan = incoming.map((v, i) => {
    const match = v.id ? byId.get(v.id) : v.code ? byCode.get(v.code.toUpperCase()) : undefined;
    if (v.id && !match) throw notFound('Variant');
    let code = (v.code ?? match?.code ?? `${item.code}-${slug(v.name)}`).toUpperCase();
    if (!v.code && !match) {
      for (let n = 2; used.has(code); n++) code = `${item.code}-${slug(v.name)}${n}`.toUpperCase();
    }
    if (used.has(code)) throw conflict('duplicate_code', `Code ${code} is used twice`);
    used.add(code);
    return { v, match, code, isDefault: defaults ? v.isDefault : i === 0, sortOrder: i };
  });
  // codes must be unique across the restaurant (other items, and retired variants too: codes are never reused)
  const clash = await tx.menuVariant.findFirst({ where: { code: { in: [...used] }, itemId: { not: item.id } } });
  if (clash) throw conflict('duplicate_code', `Variant code ${clash.code} already belongs to another item`);

  const keep = new Set<string>();
  for (const p of plan) {
    const data = {
      code: p.code, name: p.v.name, portionLabel: p.v.portionLabel ?? null, servingQuantity: p.v.servingQuantity ?? null,
      servingUnit: p.v.servingUnit ?? null, portionRatio: p.v.portionRatio ?? null, pricePaise: p.v.pricePaise,
      costPricePaise: p.v.costPricePaise ?? null, taxRuleId: p.v.taxRuleId ?? null, available: p.v.available,
      isDefault: p.isDefault, sortOrder: p.sortOrder, deleted: false,
    };
    const row = p.match
      ? await tx.menuVariant.update({ where: { id: p.match.id }, data })
      : await tx.menuVariant.create({ data: { ...data, tenantId, itemId: item.id } });
    keep.add(row.id);
  }
  const retired = existing.filter((v) => !keep.has(v.id) && !v.deleted);
  if (retired.length) await tx.menuVariant.updateMany({ where: { id: { in: retired.map((v) => v.id) } }, data: { deleted: true, available: false, isDefault: false } });
  const def = plan.find((p) => p.isDefault)!;
  await tx.menuItem.update({ where: { id: item.id }, data: { pricePaise: def.v.pricePaise } });
  return {
    before: audited(existing.filter((v) => !v.deleted)),
    after: audited(plan.map((p) => ({ code: p.code, name: p.v.name, pricePaise: p.v.pricePaise, available: p.v.available }))),
  };
}

/** Menu items with their sizes / portions, category ordering and deactivation. Prices are integer paise. */
@ApiTags('menu')
@ApiBearerAuth()
@Controller('menu')
export class MenuController {
  constructor(private db: DbService) {}

  private t<T>(a: Actor, fn: (tx: Tx) => Promise<T>) {
    if (!a.tenantId) throw forbidden('tenant_only', 'Restaurant account required');
    return this.db.tenant(a.tenantId, fn);
  }

  private bump = (tx: Tx, a: Actor) => tx.restaurantTenant.update({ where: { id: a.tenantId }, data: { menuVersion: { increment: 1 } } });

  private async withVariants(tx: Tx, where: Prisma.MenuItemWhereInput) {
    const items = await tx.menuItem.findMany({
      where: { deleted: false, ...where },
      include: { variants: { where: { deleted: false }, orderBy: { sortOrder: 'asc' } } },
      orderBy: { name: 'asc' },
    });
    return items.map(({ variants, seq: _s, ...it }) => ({ ...it, variants: variants.map(variantOut) }));
  }

  @RequirePermissions('menu.read')
  @RequiresFeature('menu')
  @Get('items')
  items(@CurrentActor() a: Actor) {
    return this.t(a, (tx) => this.withVariants(tx, {}));
  }

  @RequirePermissions('menu.read')
  @RequiresFeature('menu')
  @Get('items/:id')
  async item(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string) {
    const [it] = await this.t(a, (tx) => this.withVariants(tx, { id }));
    if (!it) throw notFound('Menu item');
    return it;
  }

  @RequirePermissions('menu.publish')
  @RequiresFeature('menu')
  @Audited('menu.categories_seeded')
  @Post('seed-categories')
  async seedCategories(@CurrentActor() a: Actor, @AuditCtx() audit: AuditDetails) {
    const seeded = await this.t(a, async tx => {
      const existing = await tx.menuCategory.findMany({ where: { deleted: false } });
      const existingNames = new Set(existing.map(c => c.name.trim().toLowerCase()));
      let order = existing.length * 10;
      const toCreate: { tenantId: string; name: string; sortOrder: number }[] = [];
      for (const name of STANDARD_CATEGORIES) {
        if (!existingNames.has(name.trim().toLowerCase())) {
          order += 10;
          toCreate.push({ tenantId: a.tenantId!, name, sortOrder: order });
        }
      }
      if (toCreate.length > 0) {
        await tx.menuCategory.createMany({ data: toCreate });
        await this.bump(tx, a);
      }
      return { created: toCreate.length, total: existing.length + toCreate.length };
    });
    Object.assign(audit, { objectType: 'menu', objectId: a.tenantId, after: seeded });
    return seeded;
  }

  @RequirePermissions('menu.publish')
  @RequiresFeature('menu')
  @Audited('menu.quick_created')
  @Post('quick-create')
  @ApiBody(apiBody(QuickMenuBody))
  async quickCreate(@CurrentActor() a: Actor, @Body(zbody(QuickMenuBody)) b: z.infer<typeof QuickMenuBody>, @AuditCtx() audit: AuditDetails) {
    const result = await this.t(a, async tx => {
      await tx.$queryRaw`SELECT id FROM restaurant_tenants WHERE id = ${a.tenantId!}::uuid FOR UPDATE`;
      if (!(await tx.taxRule.findFirst({ where: { id: b.taxRuleId, deleted: false } }))) throw notFound('Tax rule');

      const existingCats = await tx.menuCategory.findMany({ where: { deleted: false } });
      const catMap = new Map<string, string>();
      for (const c of existingCats) catMap.set(c.name.trim().toLowerCase(), c.id);

      const ensureCat = async (name: string) => {
        const key = name.trim().toLowerCase();
        if (catMap.has(key)) return catMap.get(key)!;
        const count = await tx.menuCategory.count();
        const created = await tx.menuCategory.create({ data: { tenantId: a.tenantId!, name: name.trim(), sortOrder: count * 10 } });
        catMap.set(key, created.id);
        return created.id;
      };

      // Check for repeated dish names in the same category within the request
      const categoryItemNames = new Map<string, Set<string>>();
      for (const line of b.items) {
        const catKey = (line.categoryName || b.categoryName || 'Main Course').trim().toLowerCase();
        let set = categoryItemNames.get(catKey);
        if (!set) {
          set = new Set<string>();
          categoryItemNames.set(catKey, set);
        }
        const nameKey = line.name.trim().toLowerCase();
        if (set.has(nameKey)) {
          throw conflict('duplicate_dish', 'Remove repeated dish names before saving');
        }
        set.add(nameKey);
      }

      const defaultCatId = await ensureCat(b.categoryName || 'Main Course');
      const itemRows: { id: string; tenantId: string; categoryId: string; taxRuleId: string; code: string; name: string; pricePaise: number; isVeg: boolean; unit: string; quantity: number }[] = [];
      const variantRows: { tenantId: string; itemId: string; code: string; name: string; pricePaise: number; portionLabel?: string; servingQuantity?: Prisma.Decimal; servingUnit?: string; portionRatio?: Prisma.Decimal; available: boolean; isDefault: boolean; sortOrder: number }[] = [];

      for (const line of b.items) {
        const id = uuidv7();
        const catId = line.categoryName ? await ensureCat(line.categoryName) : defaultCatId;
        const code = `Q-${id.replace(/-/g, '')}`;

        const vars = (line.variants && line.variants.length > 0)
          ? line.variants
          : [{ name: 'Regular', pricePaise: line.pricePaise ?? 0, isDefault: true, servingQuantity: 1, servingUnit: 'plate', portionRatio: 1 }];

        const def = vars.find(v => v.isDefault) ?? vars[0];
        itemRows.push({
          id, tenantId: a.tenantId!, categoryId: catId, taxRuleId: b.taxRuleId, code, name: line.name,
          pricePaise: def.pricePaise, isVeg: line.isVeg, unit: def.servingUnit || 'plate', quantity: Math.max(1, Math.round(def.servingQuantity || 1)),
        });

        vars.forEach((v, idx) => {
          const varCode = (vars.length === 1 && (!v.name || v.name === 'Regular'))
            ? `${code}-REG`
            : `${code}-${slug(v.name)}-${idx + 1}`;
          variantRows.push({
            tenantId: a.tenantId!, itemId: id, code: varCode, name: v.name || 'Regular',
            pricePaise: v.pricePaise, portionLabel: v.portionLabel,
            servingQuantity: v.servingQuantity ? new Prisma.Decimal(v.servingQuantity) : undefined,
            servingUnit: v.servingUnit,
            portionRatio: v.portionRatio ? new Prisma.Decimal(v.portionRatio) : undefined,
            available: true, isDefault: v.isDefault ?? (idx === 0), sortOrder: idx,
          });
        });
      }

      const targetCatIds = Array.from(new Set(itemRows.map(i => i.categoryId)));
      const existing = await tx.menuItem.findMany({
        where: { categoryId: { in: targetCatIds }, deleted: false },
        select: { categoryId: true, name: true },
      });
      for (const row of itemRows) {
        if (existing.some(e => e.categoryId === row.categoryId && e.name.toLowerCase() === row.name.toLowerCase())) {
          throw conflict('duplicate_dish', 'A dish already exists in this category. Edit it from the menu instead.');
        }
      }

      await tx.menuItem.createMany({ data: itemRows });
      await tx.menuVariant.createMany({ data: variantRows });
      await this.bump(tx, a);
      return { count: b.items.length, categoryId: defaultCatId, categoriesCount: catMap.size };
    });
    Object.assign(audit, { objectType: 'menu', objectId: a.tenantId, after: { dishes: b.items.map(i => i.name), count: result.count } });
    return result;
  }

  @RequirePermissions('menu.publish')
  @RequiresFeature('menu')
  @Audited('menu.item_created')
  @Post('items')
  @ApiBody(apiBody(ItemBody))
  async createItem(@CurrentActor() a: Actor, @Body(zbody(ItemBody)) b: z.infer<typeof ItemBody>, @AuditCtx() audit: AuditDetails) {
    const r = await this.t(a, async (tx) => {
      if (!(await tx.menuCategory.findFirst({ where: { id: b.categoryId, deleted: false } }))) throw notFound('Category');
      if (!(await tx.taxRule.findFirst({ where: { id: b.taxRuleId, deleted: false } }))) throw notFound('Tax rule');
      const code = (b.code ?? (await nextItemCode(tx))).toUpperCase();
      if (await tx.menuItem.findFirst({ where: { code } })) throw conflict('duplicate_code', `Item code ${code} is already used`);
      const variants: VariantIn[] = b.variants ?? [
        { name: 'Regular', pricePaise: b.pricePaise!, servingQuantity: b.quantity ?? 1, servingUnit: b.unit && UNIT_KEYS.includes(b.unit) ? b.unit : 'plate', portionRatio: 1, available: true, isDefault: true },
      ];
      const def = variants.find((v) => v.isDefault) ?? variants[0];
      const created = await tx.menuItem.create({
        data: {
          tenantId: a.tenantId!, categoryId: b.categoryId, code, name: b.name, description: b.description, taxRuleId: b.taxRuleId,
          available: b.available, active: b.active, isVeg: b.isVeg, plateColors: b.plateColors, pricePaise: def.pricePaise,
          unit: def.servingUnit ?? 'plate', quantity: Math.max(1, Math.round(def.servingQuantity ?? 1)),
        },
      });
      const v = await saveVariants(tx, a.tenantId!, created, variants);
      await this.bump(tx, a);
      return { created, variants: v.after };
    });
    Object.assign(audit, { objectType: 'menu_item', objectId: r.created.id, after: { code: r.created.code, name: r.created.name, categoryId: r.created.categoryId, variants: r.variants } });
    return this.item(a, r.created.id);
  }

  @RequirePermissions('menu.publish')
  @RequiresFeature('menu')
  @Audited('menu.item_updated')
  @Patch('items/:id')
  @ApiBody(apiBody(ItemPatch))
  async updateItem(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @Body(zbody(ItemPatch)) b: z.infer<typeof ItemPatch>, @AuditCtx() audit: AuditDetails) {
    const r = await this.t(a, async (tx) => {
      const before = await tx.menuItem.findUnique({ where: { id } });
      if (!before || before.deleted) throw notFound('Menu item');
      if (b.categoryId && !(await tx.menuCategory.findFirst({ where: { id: b.categoryId, deleted: false } }))) throw notFound('Category');
      if (b.taxRuleId && !(await tx.taxRule.findFirst({ where: { id: b.taxRuleId, deleted: false } }))) throw notFound('Tax rule');
      const { pricePaise, ...rest } = b;
      const after = await tx.menuItem.update({ where: { id }, data: { ...rest, ...(pricePaise !== undefined ? { pricePaise } : {}) } });
      if (pricePaise !== undefined) await tx.menuVariant.updateMany({ where: { itemId: id, isDefault: true, deleted: false }, data: { pricePaise } });
      await this.bump(tx, a);
      const pick = (x: typeof before) => ({ name: x.name, categoryId: x.categoryId, taxRuleId: x.taxRuleId, available: x.available, active: x.active, pricePaise: x.pricePaise, description: x.description });
      return { before: pick(before), after: pick(after) };
    });
    Object.assign(audit, { objectType: 'menu_item', objectId: id, before: r.before, after: r.after });
    return this.item(a, id);
  }

  /** Owner flow step "Add variants → set quantities and prices": replaces the item's sizes / portions. */
  @RequirePermissions('menu.publish')
  @RequiresFeature('menu')
  @Audited('menu.variants_updated')
  @Put('items/:id/variants')
  @ApiBody(apiBody(VariantsBody))
  async setVariants(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @Body(zbody(VariantsBody)) b: z.infer<typeof VariantsBody>, @AuditCtx() audit: AuditDetails) {
    const r = await this.t(a, async (tx) => {
      const it = await tx.menuItem.findUnique({ where: { id } });
      if (!it || it.deleted) throw notFound('Menu item');
      const out = await saveVariants(tx, a.tenantId!, it, b.variants);
      await this.bump(tx, a);
      return out;
    });
    Object.assign(audit, { objectType: 'menu_item', objectId: id, before: r.before, after: r.after });
    return this.item(a, id);
  }

  /** Drag-and-drop order of categories (the POS shows them in this order). */
  @RequirePermissions('menu.publish')
  @RequiresFeature('menu')
  @Audited('menu.categories_reordered')
  @Put('categories/order')
  @ApiBody(apiBody(CategoryOrderBody))
  async order(@CurrentActor() a: Actor, @Body(zbody(CategoryOrderBody)) b: z.infer<typeof CategoryOrderBody>, @AuditCtx() audit: AuditDetails) {
    await this.t(a, async (tx) => {
      const found = await tx.menuCategory.count({ where: { id: { in: b.ids }, deleted: false } });
      if (found !== new Set(b.ids).size) throw notFound('Category');
      for (const [i, id] of b.ids.entries()) await tx.menuCategory.update({ where: { id }, data: { sortOrder: (i + 1) * 10 } });
      await this.bump(tx, a);
    });
    Object.assign(audit, { objectType: 'menu_category', after: { order: b.ids } });
    return { ok: true };
  }
}
