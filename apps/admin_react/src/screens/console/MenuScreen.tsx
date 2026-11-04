import { useCallback, useEffect, useState, type CSSProperties } from 'react';
import { ArrowDownUp, Camera, ChevronLeft, ChevronRight, ChevronsLeft, ChevronsRight, Copy, CupSoda, Lock, MoreHorizontal, MoreVertical, Plus, Sparkles, ListPlus, FileUp, Trash2, Blend, UtensilsCrossed } from 'lucide-react';
import { api, ApiException, errorText, type Json } from '../../api/client';
import { copyText, pickFile } from '../../lib/download';
import { rupees } from '../../lib/format';
import { prepareDishPhoto, type PreparedImage } from '../../lib/image';
import { categoryIsVeg, deriveCode, detectMenuCategory, detectMenuIsVeg, platePalettes, popularExcelCategories, portionLabels, servingUnits, sortByCourse, standardMenuCategories } from '../../lib/menuRules';
import { parseRupees, plainRupees } from '../../lib/money';
import { useSession } from '../../state/auth';
import { useRestaurantLook } from '../../state/app';
import { restaurantShortPrefix } from '../../lib/menuRules';
import { LoadError } from '../../ui/async';
import { CategoryChip, Chip, DishImage, EmptyState, IconButton, MenuButton, PageFrame, PrimaryButton, SearchField, SecondaryButton, Select, SkeletonGrid, Switch, SwitchRow, TextButton, TextField, VegMark } from '../../ui/kit';
import { confirm, Dialog, openDialog, showDone, showError } from '../../ui/overlay';
import { ImportDialog } from './ImportDialog';

/** O3 Menu: categories, dishes with sizes / price / GST / veg / availability, and photos. Changes reach the hub on its next pull. */
export function MenuScreen() {
  const me = useSession();
  const look = useRestaurantLook();
  const can = (p: string) => !!me?.can(p);
  const edit = can('menu.publish');
  const isOwner = !!me?.roles.includes('owner');
  const prefix = restaurantShortPrefix(me?.restaurantName ?? look?.name, me?.restaurantCode);
  const [cats, setCats] = useState<Json[] | null>(null);
  const [items, setItems] = useState<Json[]>([]);
  const [taxes, setTaxes] = useState<Json[]>([]);
  const [error, setError] = useState<unknown>(null);
  const [cat, setCat] = useState<string | null>(null); // null = all
  const [q, setQ] = useState('');
  const [page, setPage] = useState(0);
  const [pageSize, setPageSize] = useState(24);
  const [narrow, setNarrow] = useState(() => window.innerWidth < 900);

  useEffect(() => {
    const on = () => setNarrow(window.innerWidth < 900);
    window.addEventListener('resize', on);
    return () => window.removeEventListener('resize', on);
  }, []);

  const load = useCallback(async () => {
    try {
      const [c, i, t] = await Promise.all([api.categories(), api.items(), api.taxRules()]);
      setCats(c);
      setItems(i);
      setTaxes(t);
      setError(null);
      setCat((cur) => (cur != null && !c.some((x) => x.id === cur) ? null : cur));
    } catch (e) {
      setError(e);
    }
  }, []);
  useEffect(() => void load(), [load]);

  const run = async (f: () => Promise<unknown>, done?: string) => {
    try {
      await f();
      await load();
      if (done) showDone(done);
    } catch (e) {
      showError(e);
    }
  };

  // ---------------- categories
  const editCategory = async (c?: Json) => {
    const name = await openDialog<string>((close) => <NameDialog title={c == null ? 'New category' : 'Rename category'} label="Name, e.g. Starters" initial={c?.name ?? ''} close={close} />);
    if (!name?.trim()) return;
    await run(() => (c == null ? api.createCategory(name.trim(), cats?.length ?? 0) : api.updateCategory(c.id, { name: name.trim() })), c == null ? 'Category added' : 'Category renamed');
  };
  /** Moves a category one place up or down; the POS shows categories in this order. */
  const moveCategory = async (c: Json, by: number) => {
    const ids = cats!.map((x) => x.id as string);
    const i = ids.indexOf(c.id), j = i + by;
    if (j < 0 || j >= ids.length) return;
    ids.splice(i, 1);
    ids.splice(j, 0, c.id);
    await run(() => api.orderCategories(ids), 'Order saved');
  };
  /** Serving order (soups → starters → mains → breads → rice → desserts → drinks); same-course categories keep their order. */
  const arrangeByCourse = () => run(() => api.orderCategories(sortByCourse(cats!, (c) => `${c.name}`).map((c) => c.id)), 'Menu arranged by course');
  const deleteCategory = async (c: Json) => {
    if (await confirm({ title: `Delete ${c.name}?`, message: 'Only empty categories can be deleted. Terminals remove it on their next sync.' })) await run(() => api.deleteCategory(c.id), 'Category deleted');
  };
  const toggleCategory = (c: Json) => run(() => api.updateCategory(c.id, { active: c.active === false }), c.active === false ? `${c.name} is back on the POS` : `${c.name} hidden from the POS`);

  // ---------------- dishes
  const ensureTax = async (): Promise<Json[]> => {
    if (taxes.length) return taxes;
    await api.createTaxRule('GST 5%', 500);
    const t = await api.taxRules();
    setTaxes(t);
    return t;
  };

  const seedCategories = async () => {
    if (
      !(await confirm({
        title: 'Add the standard categories?',
        message: 'Adds up to 40 common restaurant categories (Soups, Starters, Main Course, Biryani, Breads, Desserts, Beverages, …) to your menu. Categories you already have are skipped, and nothing is deleted. Empty ones you do not need can be removed later.',
        confirmLabel: 'Add categories',
        destructive: false,
      }))
    )
      return;
    await run(async () => {
      const r = await api.seedCategories();
      const created = r.created ?? 0;
      showDone(created === 0 ? 'All standard categories are already on your menu' : `Added ${created} standard categories`);
    });
  };

  const quickAdd = async () => {
    let t: Json[];
    try {
      t = await ensureTax();
    } catch (e) {
      return showError(e);
    }
    const defaultCat = cats!.find((c) => c.id === cat)?.name ?? 'Main course';
    if ((await openDialog<boolean>((close) => <QuickAddDialog defaultCategory={`${defaultCat}`} taxRuleId={t[0].id} close={close} />)) === true) {
      await load();
      showDone('Menu created');
    }
  };

  const editItem = async (item?: Json) => {
    let t: Json[];
    try {
      t = await ensureTax();
    } catch (e) {
      return showError(e);
    }
    const defaultCat = cat ?? (cats!.length ? cats![0].id : 'standard:Main Course');
    const saved = await openDialog<boolean>((close) => (
      <ItemEditor item={item} categories={cats!} taxes={t} defaultCategory={defaultCat} paletteIndex={items.length} restaurantPrefix={prefix} canMapRecipes={can('inventory.manage')} close={close} />
    ));
    if (saved === true) {
      await load();
      showDone(item == null ? 'Dish added' : 'Dish saved');
    }
  };

  const toggle = (item: Json, available: boolean) => run(() => api.updateItem(item.id, { available }), available ? `${item.name} is back on` : `${item.name} marked sold out`);

  const importMenu = async () => {
    if (!can('import.run')) return showError('Excel import is not in your plan. Ask the Super Admin to enable "Excel import (menu & inventory)" in Plans, then sign in again.');
    if ((await openDialog<boolean>((close) => <ImportDialog kind="menu" close={close} />)) === true) await load();
  };

  if (error != null) return <LoadError error={error} page="Menu" onRetry={load} />;
  if (cats == null) return <SkeletonGrid min={260} h={180} />;

  // categories and "All dishes" follow the serving order
  const ordered = sortByCourse(cats, (c) => `${c.name}`);
  const pos = new Map(ordered.map((c, i) => [c.id, i]));
  const visible = items
    .filter((i) => cat == null || i.categoryId === cat)
    .filter((i) => q === '' || `${i.name} ${i.code ?? ''}`.toLowerCase().includes(q.toLowerCase()))
    .sort((a, b) => (pos.get(a.categoryId) ?? 1 << 20) - (pos.get(b.categoryId) ?? 1 << 20));
  const catName = new Map(cats.map((c) => [c.id, c.name]));
  const totalPages = pageSize > 0 ? Math.max(1, Math.ceil(visible.length / pageSize)) : 1;
  const current = Math.min(page, totalPages - 1);
  const paged = pageSize > 0 ? visible.slice(current * pageSize, current * pageSize + pageSize) : visible;
  const count = (id: string | null) => items.filter((i) => id == null || i.categoryId === id).length;

  const rail = narrow ? (
    <div className="chip-scroll">
      <CategoryChip label="All" count={count(null)} on={cat == null} onClick={() => (setCat(null), setPage(0))} />
      {ordered.map((c) => (
        <CategoryChip key={c.id} label={`${c.name}`} count={count(c.id)} on={cat === c.id} onClick={() => (setCat(c.id), setPage(0))} />
      ))}
      {edit && <Chip label="Category" icon={Plus} testId="add-category" onClick={() => editCategory()} />}
      {edit && cats.length > 1 && <Chip label="Arrange by course" icon={ArrowDownUp} testId="arrange-by-course" onClick={arrangeByCourse} />}
    </div>
  ) : (
    <div className="card" style={{ padding: 8 }}>
      <div className="t-overline" style={{ padding: '8px 12px' }}>
        Categories
      </div>
      {[null, ...ordered].map((c) => {
        const id = c?.id ?? null;
        const name = c ? `${c.name}` : 'All dishes';
        const sel = cat === id;
        const hidden = c?.active === false;
        return (
          <div key={id ?? 'all'} className="row" data-testid={`category-${name}`} style={{ borderRadius: 12, background: sel ? 'var(--raised)' : 'transparent', padding: '2px 4px 2px 12px', marginBottom: 2, cursor: 'pointer', minHeight: 40 }} onClick={() => (setCat(id), setPage(0))}>
            <span className={`t-label grow ellipsis${hidden ? ' faint' : sel ? '' : ' muted'}`}>{hidden ? `${name} · hidden` : name}</span>
            <span className="faint">{count(id)}</span>
            {edit && c && (
              <span onClick={(e) => e.stopPropagation()}>
                <MenuButton
                  title="Category actions"
                  icon={MoreVertical}
                  items={[
                    { label: 'Rename', onClick: () => editCategory(c) },
                    { label: 'Move up', onClick: () => moveCategory(c, -1) },
                    { label: 'Move down', onClick: () => moveCategory(c, 1) },
                    { label: hidden ? 'Show on the POS' : 'Hide from the POS', onClick: () => toggleCategory(c) },
                    { label: 'Delete', danger: true, onClick: () => deleteCategory(c) },
                  ]}
                />
              </span>
            )}
          </div>
        );
      })}
      {edit && (
        <div className="col mt-8" style={{ alignItems: 'flex-start', gap: 0 }}>
          <TextButton label="Add category" icon={Plus} testId="add-category" onClick={() => editCategory()} />
          {cats.length > 1 && <TextButton label="Arrange by course" icon={ArrowDownUp} testId="arrange-by-course" onClick={arrangeByCourse} />}
        </div>
      )}
    </div>
  );

  const pager = (compact: boolean) => <Pager total={visible.length} page={current} pageSize={pageSize} compact={compact} onPage={setPage} onSize={(s) => (setPageSize(s), setPage(0))} />;

  const grid =
    visible.length === 0 ? (
      <EmptyState
        icon={UtensilsCrossed}
        title={items.length === 0 ? 'Your menu is empty' : 'No dishes match'}
        message={items.length === 0 ? 'Add categories and dishes. Photos are optional — every dish gets an illustrated plate.' : undefined}
        action={edit && items.length === 0 && <PrimaryButton label="Add your first dish" icon={Plus} onClick={() => editItem()} />}
      />
    ) : (
      <div className="col gap-12">
        {pager(true)}
        <div className="grid-auto" style={{ '--min': '280px', gap: 12 } as CSSProperties}>
          {paged.map((i) => (
            <ItemTile
              key={i.id}
              item={i}
              category={`${catName.get(i.categoryId) ?? ''}`}
              imageUrl={i.imageId == null ? null : api.mediaUrl(i.imageId)}
              canEdit={edit}
              onEdit={() => editItem(i)}
              onToggle={(v) => toggle(i, v)}
              onDelete={async () => {
                if (await confirm({ title: `Delete ${i.name}?`, message: 'It disappears from every terminal on the next sync. Past bills keep their copy of the name and price.' })) await run(() => api.deleteItem(i.id), 'Dish deleted');
              }}
            />
          ))}
        </div>
        {pager(false)}
      </div>
    );

  return (
    <PageFrame
      title="Menu"
      subtitle={`${items.length} dishes · ${cats.length} categories · changes reach your terminals within a minute`}
      actions={
        <>
          <div style={{ width: narrow ? '100%' : 260 }}>
            <SearchField hint="Search dishes" onChange={(v) => (setQ(v), setPage(0))} />
          </div>
          {edit && (can('import.run') || isOwner) && <SecondaryButton label="Import Excel" icon={can('import.run') ? FileUp : Lock} testId="import-menu" onClick={importMenu} />}
          {edit && (
            <>
              <SecondaryButton label="Add standard categories" icon={ListPlus} testId="seed-categories" onClick={seedCategories} />
              <SecondaryButton label="Quick add / paste" onClick={quickAdd} />
            </>
          )}
          <PrimaryButton label="Add dish" icon={Plus} height={48} testId="add-dish" onClick={() => editItem()} />
        </>
      }
    >
      {narrow ? (
        <div className="col gap-16">
          {rail}
          {grid}
        </div>
      ) : (
        <div className="row-top gap-24">
          <div style={{ width: 240, flex: 'none' }}>{rail}</div>
          <div className="grow">{grid}</div>
        </div>
      )}
    </PageFrame>
  );
}

function Pager({ total, page, pageSize, compact, onPage, onSize }: { total: number; page: number; pageSize: number; compact: boolean; onPage: (p: number) => void; onSize: (s: number) => void }) {
  const totalPages = pageSize > 0 ? Math.max(1, Math.ceil(total / pageSize)) : 1;
  const cur = Math.min(page, totalPages - 1);
  const start = total === 0 ? 0 : cur * pageSize + 1;
  const end = pageSize > 0 ? Math.min(cur * pageSize + pageSize, total) : total;
  let buttons: number[] = [];
  if (totalPages <= 7) buttons = Array.from({ length: totalPages }, (_, i) => i);
  else {
    const s = Math.max(0, Math.min(cur - 2, totalPages - 5));
    const e = Math.max(4, Math.min(s + 4, totalPages - 1));
    for (let i = s; i <= e; i++) buttons.push(i);
  }
  const pill = (i: number) => (
    <button key={i} type="button" className={`page-pill${i === cur ? ' on' : ''}`} data-testid={`page-pill-${i + 1}`} onClick={i === cur ? undefined : () => onPage(i)}>
      {i + 1}
    </button>
  );
  const tag = compact ? 'top' : 'bottom';
  return (
    <div className="pager">
      <span className="t-label" style={{ fontSize: 13 }}>
        {total === 0 ? '0 dishes' : `Showing ${start}–${end} of ${total} ${total === 1 ? 'dish' : 'dishes'}`}
      </span>
      <div className="row" style={{ gap: 4, flexWrap: 'wrap' }}>
        <span className="muted" style={{ fontSize: 12 }}>
          Per page:
        </span>
        <select className="mini-select" data-testid={`page-size-${tag}`} value={pageSize} onChange={(e) => onSize(Number(e.target.value))} aria-label="Dishes per page">
          <option value={24}>24</option>
          <option value={48}>48</option>
          <option value={96}>96</option>
          <option value={0}>All</option>
        </select>
        {totalPages > 1 && (
          <>
            <IconButton title="First page" icon={ChevronsLeft} sm size={18} testId={`page-first-${tag}`} onClick={cur > 0 ? () => onPage(0) : null} />
            <IconButton title="Previous page" icon={ChevronLeft} sm size={18} testId={`page-prev-${tag}`} onClick={cur > 0 ? () => onPage(cur - 1) : null} />
            {compact ? (
              <span className="t-label" style={{ fontSize: 13, padding: '0 8px' }}>
                {cur + 1} / {totalPages}
              </span>
            ) : (
              <>
                {buttons[0] > 0 && (
                  <>
                    {pill(0)}
                    {buttons[0] > 1 && <span className="muted">…</span>}
                  </>
                )}
                {buttons.map(pill)}
                {buttons[buttons.length - 1] < totalPages - 1 && (
                  <>
                    {buttons[buttons.length - 1] < totalPages - 2 && <span className="muted">…</span>}
                    {pill(totalPages - 1)}
                  </>
                )}
              </>
            )}
            <IconButton title="Next page" icon={ChevronRight} sm size={18} testId={`page-next-${tag}`} onClick={cur < totalPages - 1 ? () => onPage(cur + 1) : null} />
            <IconButton title="Last page" icon={ChevronsRight} sm size={18} testId={`page-last-${tag}`} onClick={cur < totalPages - 1 ? () => onPage(totalPages - 1) : null} />
          </>
        )}
      </div>
    </div>
  );
}

/** "₹340" for one size; "₹30 – ₹90 · 3 sizes" when the dish comes in several. */
function tilePrice(item: Json) {
  const vs = (item.variants ?? []) as Json[];
  if (vs.length <= 1) return rupees(Number(vs[0]?.pricePaise ?? item.pricePaise ?? 0));
  const prices = vs.map((v) => Number(v.pricePaise)).sort((a, b) => a - b);
  return `${rupees(prices[0])} – ${rupees(prices[prices.length - 1])} · ${vs.length} sizes`;
}

function ItemTile({ item, category, imageUrl, canEdit, onEdit, onToggle, onDelete }: { item: Json; category: string; imageUrl: string | null; canEdit: boolean; onEdit: () => void; onToggle: (v: boolean) => void; onDelete: () => void }) {
  const available = item.available === true;
  const code = `${item.code ?? ''}`.trim();
  const copySku = async () => (await copyText(code)) && showDone(`Copied SKU ${code} to clipboard`);
  return (
    <div className={`card dish-tile${canEdit ? ' clickable' : ''}`} data-testid={`item-${item.name}`} onClick={canEdit ? onEdit : undefined}>
      <DishImage src={imageUrl} plate={item.plateColors} size={64} dim={!available} />
      <div className="grow">
        <div className="row-top" style={{ gap: 6 }}>
          <span style={{ marginTop: 3 }}>
            <VegMark isVeg={item.isVeg === true} size={14} />
          </span>
          <span className="t-label clamp-2" title={`${item.name}`}>
            {`${item.name}`}
          </span>
        </div>
        <div className="muted ellipsis" style={{ fontSize: 12, marginTop: 2 }}>
          {category}
          {!available && <span className="danger-text"> · Sold out</span>}
        </div>
        <div className="row mt-8" style={{ gap: 8, flexWrap: 'wrap' }}>
          <span className="t-label">{tilePrice(item)}</span>
          {code && (
            <button type="button" className="tag" title={`Copy SKU ${code}`} data-testid={`copy-sku-${code}`} onClick={(e) => (e.stopPropagation(), void copySku())}>
              {code}
              <Copy size={11} aria-hidden />
            </button>
          )}
        </div>
      </div>
      <div className="col" style={{ alignItems: 'flex-end', gap: 4, flex: 'none' }} onClick={(e) => e.stopPropagation()}>
        <span title={available ? 'On the menu — switch off when sold out' : 'Sold out — switch on to sell again'}>
          <Switch checked={available} onChange={canEdit ? onToggle : undefined} testId={`available-${item.name}`} label="Available" />
        </span>
        {canEdit && (
          <MenuButton
            title="Dish actions"
            icon={MoreHorizontal}
            items={[
              { label: 'Edit & photo', onClick: onEdit },
              code !== '' && { label: 'Copy SKU / Code', icon: Copy, onClick: copySku },
              { label: 'Delete', icon: Trash2, danger: true, onClick: onDelete },
            ]}
          />
        )}
      </div>
    </div>
  );
}

function NameDialog({ title, label, initial, close }: { title: string; label: string; initial: string; close: (v?: string) => void }) {
  const [v, setV] = useState(initial);
  return (
    <Dialog
      title={title}
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={() => close()} />
          <PrimaryButton label="Save" height={56} onClick={() => close(v)} />
        </>
      }
    >
      <TextField label={label} value={v} onChange={setV} autoFocus onEnter={() => close(v)} testId="category-name" />
    </Dialog>
  );
}

/** Paste names and prices (from Excel or typed): "Name | Price", "Name | Veg | Half | Full", "Name | Half 180 | Full 320". */
export function parseQuickRows(text: string): { items: Json[] } | { error: string } {
  const items: Json[] = [];
  for (const line of text.split('\n').filter((l) => l.trim() !== '')) {
    const raw = line.trim().split(/\t|\s*\|\s*/).map((s) => s.trim()).filter(Boolean);
    if (raw.length === 0) continue;
    let parts = [...raw];
    let dishName = raw[0];
    let dishCat: string | null = null;
    let isVeg = true;
    const variants: Json[] = [];
    let single: number | null = null;
    const match = standardMenuCategories.find((sc) => sc.toLowerCase() === parts[0].toLowerCase());
    if (match && parts.length >= 3) {
      dishCat = match;
      parts = parts.slice(1);
      dishName = parts[0];
    }
    const vegIdx = parts.findIndex((p) => /^(veg|vegetarian|non-?veg|non-vegetarian|egg)$/i.test(p));
    if (vegIdx >= 0) {
      isVeg = !parts[vegIdx].toLowerCase().includes('non');
      parts.splice(vegIdx, 1);
    }
    const vals = parts.length > 1 ? parts.slice(1) : [];
    if (vals.length === 1) single = parseRupees(vals[0]);
    else if (vals.length === 2 && parseRupees(vals[0]) != null && parseRupees(vals[1]) != null) {
      variants.push({ name: 'Half Plate', pricePaise: parseRupees(vals[0]), portionLabel: 'half', portionRatio: 0.5, isDefault: false });
      variants.push({ name: 'Full Plate', pricePaise: parseRupees(vals[1]), portionLabel: 'full', portionRatio: 1.0, isDefault: true });
    } else {
      for (const vp of vals) {
        const m = /^(.*?)\s*[:=]?\s*(\d+(?:\.\d+)?)$/.exec(vp);
        if (m) {
          const p = parseRupees(m[2]);
          if (p != null) variants.push({ name: m[1].trim() || 'Regular', pricePaise: p, isDefault: variants.length === 0 });
        } else {
          const p = parseRupees(vp);
          if (p != null) variants.push({ name: `Size ${variants.length + 1}`, pricePaise: p, isDefault: variants.length === 0 });
        }
      }
    }
    if (variants.length === 0 && single == null) return { error: `Could not parse price in: "${line}".\nUse: Name | Price or Name | Veg/Non-Veg | HalfPrice | FullPrice` };
    items.push({ name: dishName, ...(dishCat ? { categoryName: dishCat } : {}), isVeg, ...(single != null && variants.length === 0 ? { pricePaise: single } : {}), ...(variants.length ? { variants } : {}) });
  }
  return { items };
}

function QuickAddDialog({ defaultCategory, taxRuleId, close }: { defaultCategory: string; taxRuleId: string; close: (v?: boolean) => void }) {
  const [category, setCategory] = useState(defaultCategory);
  const [rows, setRows] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const create = async () => {
    const r = parseQuickRows(rows);
    if ('error' in r) return setError(r.error);
    const items = r.items;
    if (items.length === 0 || items.length > 200 || (category.trim() === '' && !items.some((i) => 'categoryName' in i))) return setError('Enter a category and 1–200 dishes.');
    setBusy(true);
    setError(null);
    try {
      await api.quickMenu({ categoryName: category.trim() === '' ? 'Main course' : category.trim(), taxRuleId, items });
      close(true);
    } catch (e) {
      setBusy(false);
      setError(errorText(e));
    }
  };
  return (
    <Dialog
      title="Quick menu entry"
      size="wide"
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={busy ? null : () => close()} />
          <PrimaryButton label="Create dishes" busy={busy} onClick={busy ? null : create} />
        </>
      }
    >
      <div className="col gap-12">
        <TextField label="Default category (created automatically if new)" value={category} onChange={setCategory} />
        <div className="t-overline">Quick category suggestions</div>
        <div className="wrap" style={{ gap: 6 }}>
          {['Soups', 'Veg Starters', 'Non-Veg Starters', 'Tandoori Items', 'Veg Main Course', 'Biryani', 'Indian Breads', 'Desserts', 'Hot Beverages', 'Cold Beverages'].map((c) => (
            <Chip key={c} small label={c} onClick={() => setCategory(c)} />
          ))}
        </div>
        <TextField
          label="Paste names and prices from Excel, or type"
          multiline={8}
          value={rows}
          onChange={setRows}
          placeholder={'Tomato Soup | Veg | 145 | 210\nPaneer Tikka | Veg | 240\nChicken Biryani | Non-Veg | Half 180 | Full 320\nButter Naan | 50'}
        />
        <span className="muted" style={{ fontSize: 12 }}>
          Supports copying columns from Excel or typing. Single price creates Regular; 2 prices create Half & Full plate. Optional Veg/Non-Veg tag supported.
        </span>
        {error && (
          <span className="danger-text" style={{ whiteSpace: 'pre-line' }}>
            {error}
          </span>
        )}
      </div>
    </Dialog>
  );
}

// ---------------------------------------------------------------- dish editor

type SizeDraft = { key: number; id: string | null; code: string; name: string; price: string; qty: string; unit: string | null; portion: string | null; ratio: string; available: boolean; isDefault: boolean };
let sizeKey = 1;
const blank = (p: Partial<SizeDraft> = {}): SizeDraft => ({ key: sizeKey++, id: null, code: '', name: 'Regular', price: '', qty: '', unit: null, portion: null, ratio: '', available: true, isDefault: false, ...p });
const numText = (x: unknown) => (x == null ? '' : Number(x) % 1 === 0 ? `${Math.trunc(Number(x))}` : `${x}`);
const fromVariant = (v: Json): SizeDraft =>
  blank({ id: v.id ?? null, code: `${v.code ?? ''}`, name: `${v.name}`, price: plainRupees(Number(v.pricePaise)), qty: numText(v.servingQuantity), unit: v.servingUnit ?? null, portion: v.portionLabel ?? null, ratio: numText(v.portionRatio), available: v.available !== false, isDefault: v.isDefault === true });

function sizeProblem(s: SizeDraft): string | null {
  const n = s.name.trim();
  if (n === '') return 'Every size needs a name, e.g. "500 ml" or "Half plate"';
  if (parseRupees(s.price) == null) return `Enter a price in rupees for ${n}, e.g. 249`;
  const q = s.qty.trim();
  if (q !== '' && !(Number(q) > 0)) return `Serving quantity for ${n} must be a number above 0`;
  if ((q === '') !== (s.unit == null)) return `Give ${n} both a serving quantity and a unit, or neither`;
  const r = s.ratio.trim();
  if (r !== '' && !(Number(r) > 0)) return `Portion ratio for ${n} must be above 0 (1 = full portion)`;
  return null;
}
const sizeJson = (s: SizeDraft): Json => ({
  ...(s.id != null ? { id: s.id } : {}),
  ...(s.code.trim() ? { code: s.code.trim().toUpperCase() } : {}),
  name: s.name.trim(),
  pricePaise: parseRupees(s.price),
  portionLabel: s.portion,
  servingQuantity: s.qty.trim() === '' ? null : Number(s.qty.trim()),
  servingUnit: s.unit,
  portionRatio: s.ratio.trim() === '' ? null : Number(s.ratio.trim()),
  available: s.available,
  isDefault: s.isDefault,
});

/** Add / edit a dish, with photo upload (cropped and compressed in the browser) or the illustrated plate. */
function ItemEditor({ item, categories, taxes, defaultCategory, paletteIndex, restaurantPrefix, canMapRecipes, close }: {
  item?: Json;
  categories: Json[];
  taxes: Json[];
  defaultCategory: string;
  paletteIndex: number;
  restaurantPrefix: string;
  canMapRecipes: boolean;
  close: (v?: boolean) => void;
}) {
  const [name, setName] = useState<string>(item?.name ?? '');
  const [code, setCode] = useState<string>(item?.code ?? '');
  const [sizes, setSizes] = useState<SizeDraft[]>(() => {
    const vs = (item?.variants ?? []) as Json[];
    return vs.length ? vs.map(fromVariant) : [blank({ isDefault: true })];
  });
  const [desc, setDesc] = useState<string>(item?.description ?? '');
  const [category, setCategory] = useState<string>(item?.categoryId ?? defaultCategory);
  const [tax, setTax] = useState<string>(item?.taxRuleId ?? (taxes.find((t) => t.rateBp === 500) ?? taxes[0]).id);
  const catName = (id: string) => (id.startsWith('standard:') ? id.substring(9) : `${categories.find((c) => c.id === id)?.name ?? ''}`);
  const autoVegFor = (n: string, catId: string) => detectMenuIsVeg(n) && (categoryIsVeg(catName(catId)) ?? true);
  const [veg, setVeg] = useState<boolean>(item?.isVeg ?? autoVegFor(item?.name ?? '', item?.categoryId ?? defaultCategory));
  const [vegTouched, setVegTouched] = useState(false); // once the owner flips the switch, the category no longer decides it
  const [available, setAvailable] = useState<boolean>(item?.available ?? true);
  const imageId = (item?.imageId as string | undefined) ?? null;
  const [photo, setPhoto] = useState<PreparedImage | null>(null);
  const [removePhoto, setRemovePhoto] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [detected, setDetected] = useState<string | null>(null);
  const [userChangedCategory, setUserChangedCategory] = useState(false);

  const plate = () => {
    const c = platePalettes[paletteIndex % platePalettes.length];
    return { base: c[0], sauce: c[1], garnish: c[2] };
  };
  const pc = (item?.plateColors as Json | undefined) ?? plate();
  const photoSrc = photo ? photo.dataUrl : !removePhoto && imageId ? api.mediaUrl(imageId) : null;

  const findCat = (n: string) => categories.find((c) => `${c.name ?? ''}`.trim().toLowerCase() === n.trim().toLowerCase());

  const onName = (v: string) => {
    setName(v);
    const d = detectMenuCategory(v);
    setDetected(d);
    let nextCat = category;
    if (!userChangedCategory && d != null) {
      const m = findCat(d);
      if (m) nextCat = m.id;
      else if (categories.length > 1 || categories.length === 0) nextCat = `standard:${d}`;
      setCategory(nextCat);
    }
    // a meat word in the name always wins; otherwise the category decides
    if (!vegTouched) setVeg(autoVegFor(v, nextCat));
  };

  const pickCategory = (id: string) => {
    setCategory(id);
    setUserChangedCategory(true);
    if (!vegTouched) setVeg(autoVegFor(name, id));
  };
  const selectByName = (n: string) => {
    const m = findCat(n);
    pickCategory(m ? m.id : `standard:${n}`);
  };
  const isSelected = (n: string) => catName(category).toLowerCase() === n.toLowerCase();

  // existing categories, then the 40 standard ones not yet on the menu ("Excel Standard")
  const catOptions: [string, string][] = (() => {
    const seen = new Set<string>();
    const out: [string, string][] = [];
    for (const c of categories) {
      const n = `${c.name ?? ''}`.trim();
      if (n && !seen.has(n.toLowerCase())) {
        seen.add(n.toLowerCase());
        out.push([c.id, n]);
      }
    }
    for (const s of standardMenuCategories) {
      if (!seen.has(s.toLowerCase())) {
        seen.add(s.toLowerCase());
        out.push([`standard:${s}`, `${s} · Excel Standard`]);
      }
    }
    if (!out.some(([v]) => v === category)) out.unshift([category, category.replace('standard:', '')]);
    return out;
  })();

  const pick = async () => {
    try {
      const f = await pickFile('image/*');
      if (!f) return;
      setPhoto(await prepareDishPhoto(f));
      setRemovePhoto(false);
      setError(null);
    } catch (e) {
      setError(errorText(e));
    }
  };

  const setSize = (k: number, p: Partial<SizeDraft>) => setSizes((ss) => ss.map((s) => (s.key === k ? { ...s, ...p } : s)));
  const preset = (list: Partial<SizeDraft>[]) => setSizes(list.map((p) => blank(p)));

  const save = async () => {
    if (!name.trim()) return setError('Give the dish a name');
    const problem = sizes.map(sizeProblem).find((x) => x != null);
    if (problem) return setError(problem);
    const codes = sizes.map((s) => s.code.trim().toUpperCase()).filter(Boolean);
    if (new Set(codes).size !== codes.length) return setError('Two sizes have the same code');
    const final = sizes.some((s) => s.isDefault) ? sizes : sizes.map((s, i) => ({ ...s, isDefault: i === 0 }));
    setBusy(true);
    setError(null);
    try {
      let catId = category;
      if (catId.startsWith('standard:')) catId = (await api.createCategory(catId.substring(9), categories.length * 10)).id;
      const variants = final.map(sizeJson);
      let itemCode: string | null = code.trim() ? code.trim().toUpperCase() : null;
      if (itemCode == null && item == null && name.trim()) itemCode = deriveCode(name, restaurantPrefix || 'DISH-');
      const body: Json = { name: name.trim(), categoryId: catId, taxRuleId: tax, isVeg: veg, available, ...(itemCode ? { code: itemCode } : {}), ...(desc.trim() ? { description: desc.trim() } : {}) };
      let saved: Json;
      if (item == null) saved = await api.createItem({ ...body, plateColors: plate(), variants });
      else {
        await api.updateItem(item.id, body);
        saved = await api.setVariants(item.id, variants);
      }
      const id = saved.id as string;
      if (photo) await api.setItemImage(id, photo.contentType, photo.base64);
      else if (removePhoto && imageId) await api.removeItemImage(id);
      close(true);
    } catch (e) {
      setError(e instanceof ApiException ? e.message : errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const firstWord = name.trim().split(/\s+/)[0]?.toUpperCase().replace(/[^A-Z0-9]/g, '') ?? '';
  return (
    <Dialog
      title={item == null ? 'Add a dish' : `Edit ${item.name}`}
      size="xwide"
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={busy ? null : () => close()} />
          <PrimaryButton label="Save" busy={busy} height={56} onClick={save} testId="save-dish" />
        </>
      }
    >
      <div className="col gap-12">
        <div className="row gap-16">
          <DishImage src={photoSrc} plate={pc} size={88} />
          <div className="grow">
            <div className="t-label">{photoSrc == null ? 'Illustrated plate' : 'Photo'}</div>
            <div className="muted" style={{ fontSize: 12 }}>
              Square photos look best. We crop and compress it for you.
            </div>
            <div className="wrap mt-8">
              <button type="button" className="outlined-btn" data-testid="pick-photo" disabled={busy} onClick={pick}>
                <Camera size={18} aria-hidden />
                {photoSrc == null ? 'Upload photo' : 'Change'}
              </button>
              {photoSrc != null && <TextButton label="Remove" onClick={busy ? null : () => (setPhoto(null), setRemovePhoto(true))} />}
            </div>
          </div>
        </div>
        <div className="cols" style={{ '--cols': '3fr 2fr' } as CSSProperties}>
          <TextField
            label="Dish name"
            placeholder="e.g. Coke, Butter Chicken, Cold Coffee, Paneer Tikka"
            value={name}
            onChange={onName}
            testId="dish-name"
            suffix={detected ? <span title={`Auto-detected category: ${detected}`} style={{ display: 'flex', padding: 8, color: 'var(--success)' }}><Sparkles size={18} /></span> : undefined}
          />
          <TextField
            label="SKU / Code"
            upper
            value={code}
            onChange={setCode}
            testId="dish-code"
            placeholder={restaurantPrefix ? (name.trim() ? `e.g. ${restaurantPrefix}${firstWord}` : `e.g. ${restaurantPrefix}001`) : 'e.g. RST-001'}
            suffix={<IconButton title="Auto-generate SKU" icon={Sparkles} sm onClick={() => setCode(deriveCode(name, restaurantPrefix || 'DISH-'))} />}
          />
        </div>
        <div className="chip-scroll" style={{ gap: 6 }}>
          {popularExcelCategories.map((c) => (
            <Chip key={c} small label={c} on={isSelected(c)} onClick={() => selectByName(c)} />
          ))}
        </div>
        <div className="cols" style={{ '--cols': '3fr 2fr' } as CSSProperties}>
          <Select<string> label="Category" value={category} options={catOptions} onChange={pickCategory} help={<span style={{ color: detected ? 'var(--success)' : undefined }}>{detected ? `Auto-detected: ${detected}` : 'All 40 standard categories from Excel catalog'}</span>} />
          <Select<string> label="GST Rate" value={tax} options={taxes.map((t) => [t.id as string, `${t.name}`])} onChange={setTax} help="Split as CGST + SGST" />
        </div>
        <div className="row mt-8">
          <span className="t-overline grow">Sizes & pricing</span>
          <TextButton label="Add size" icon={Plus} testId="add-size" onClick={sizes.length >= 20 ? null : () => setSizes((s) => [...s, blank()])} />
        </div>
        <span className="muted" style={{ fontSize: 12 }}>
          For single items (e.g. 1 Coke), just type the price below. Click presets for multi-size portions.
        </span>
        <div className="wrap" style={{ gap: 4 }}>
          <TextButton small icon={CupSoda} label="Drinks: 200 / 300 / 500 ml / 1 L" onClick={() => preset([200, 300, 500, 1000].map((q) => ({ name: `${q} ml`, qty: `${q}`, unit: 'ml', isDefault: q === 300 })))} />
          <TextButton small label="Half / Full Plate" onClick={() => preset([['Half', 0.5], ['Full', 1]].map(([n, r]) => ({ name: `${n} plate`, portion: `${n}`.toLowerCase(), ratio: `${r}`, qty: `${r}`, unit: 'plate', isDefault: r === 1 })))} />
          <TextButton small label="Cup 150 ml / Bowl 250 ml" onClick={() => preset([{ name: 'Cup 150 ml', qty: '150', unit: 'ml' }, { name: 'Bowl 250 ml', qty: '250', unit: 'ml', isDefault: true }])} />
          <TextButton small label={'Pizza: 7" / 10" / 12"'} onClick={() => preset(['Small 7"', 'Medium 10"', 'Large 12"'].map((s) => ({ name: s, unit: 'piece', isDefault: s.startsWith('Medium') })))} />
          <TextButton small label="Ice cream: 1 / 2 / 3 scoops" onClick={() => preset(['1 Scoop', '2 Scoops', '3 Scoops'].map((s) => ({ name: s, unit: 'scoop', isDefault: s.startsWith('1') })))} />
          <TextButton small label="Pieces: 1 / 2 / 4" onClick={() => preset(['1 Piece', '2 Pieces', '4 Pieces'].map((s) => ({ name: s, unit: 'piece', isDefault: s.startsWith('2') })))} />
          <TextButton small label="1 Thali / Combo" onClick={() => preset([{ name: '1 Thali / Combo', unit: 'combo', isDefault: true }])} />
        </div>
        {sizes.map((s, i) => (
          <SizeRow
            key={s.key}
            index={i}
            size={s}
            prefix={restaurantPrefix}
            canRemove={sizes.length > 1}
            onChange={(p) => setSize(s.key, p)}
            onDefault={() => setSizes((ss) => ss.map((x) => ({ ...x, isDefault: x.key === s.key })))}
            onRemove={() =>
              setSizes((ss) => {
                const rest = ss.filter((x) => x.key !== s.key);
                return rest.some((x) => x.isDefault) ? rest : rest.map((x, j) => ({ ...x, isDefault: j === 0 }));
              })
            }
            onRecipe={canMapRecipes && s.id != null ? () => openDialog<void>((c) => <RecipeDialog variantId={s.id!} title={`${name.trim()} · ${s.name.trim()}`} close={c} />) : undefined}
          />
        ))}
        {canMapRecipes && sizes.some((s) => s.id == null) && (
          <span className="muted" style={{ fontSize: 12 }}>
            Save the dish first, then map each size to its ingredients with "Recipe".
          </span>
        )}
        <TextField label="Description (optional)" multiline={2} value={desc} onChange={setDesc} />
        <SwitchRow title="Vegetarian" leading={<VegMark isVeg={veg} />} checked={veg} onChange={(v) => (setVegTouched(true), setVeg(v))} />
        <SwitchRow title="Available now" sub="Turn off when it is sold out" checked={available} onChange={setAvailable} />
        {error && (
          <span className="danger-text" data-testid="dish-error">
            {error}
          </span>
        )}
      </div>
    </Dialog>
  );
}

function SizeRow({ index, size: s, prefix, canRemove, onChange, onDefault, onRemove, onRecipe }: {
  index: number;
  size: SizeDraft;
  prefix: string;
  canRemove: boolean;
  onChange: (p: Partial<SizeDraft>) => void;
  onDefault: () => void;
  onRemove: () => void;
  onRecipe?: () => void;
}) {
  const qtyLabel = s.unit === 'ml' || s.unit === 'l' ? 'Volume' : s.unit === 'g' || s.unit === 'kg' ? 'Weight' : 'Portion qty';
  const portions = [...new Set([...portionLabels, ...(s.portion ? [s.portion] : [])])];
  const units = [...new Set([...servingUnits, ...(s.unit ? [s.unit] : [])])];
  return (
    <div className="card raised pad-12" style={{ borderRadius: 10, borderColor: s.isDefault ? 'color-mix(in srgb, var(--accent) 50%, transparent)' : undefined }}>
      <div className="cols" style={{ '--cols': '3fr 2fr' } as CSSProperties}>
        <TextField label="Size / portion" placeholder="e.g. Regular, 300 ml, Half plate" value={s.name} onChange={(v) => onChange({ name: v })} testId={`size-name-${index}`} />
        <TextField label="Price" prefix="₹" inputMode="decimal" value={s.price} onChange={(v) => onChange({ price: v })} testId={`size-price-${index}`} />
      </div>
      <div className="wrap-end mt-8">
        <TextField label={qtyLabel} dense inputMode="decimal" placeholder={s.unit === 'ml' || s.unit === 'l' ? 'e.g. 200' : 'e.g. 1'} value={s.qty} onChange={(v) => onChange({ qty: v })} testId={`size-qty-${index}`} style={{ width: 110 }} />
        <Select<string | null> label="Unit" dense testId={`size-unit-${index}`} value={s.unit} options={[[null, '—'], ...units.map((u) => [u, u] as [string, string])]} onChange={(v) => onChange({ unit: v })} style={{ width: 105 }} />
        <Select<string | null> label="Portion" dense value={s.portion} options={[[null, '—'], ...portions.map((l) => [l, l ? l[0].toUpperCase() + l.substring(1) : '—'] as [string, string])]} onChange={(v) => onChange({ portion: v })} style={{ width: 110 }} />
        <span title="Default recipe scale vs the full portion (1 = full). Prices are never derived from it.">
          <TextField label="Ratio" dense inputMode="decimal" value={s.ratio} onChange={(v) => onChange({ ratio: v })} style={{ width: 90 }} />
        </span>
        <TextField label="Code (optional)" dense upper placeholder={prefix ? `e.g. ${prefix}500` : 'e.g. COLA-500'} value={s.code} onChange={(v) => onChange({ code: v })} style={{ width: 130 }} />
      </div>
      <div className="wrap mt-8" style={{ gap: '4px 16px' }}>
        <label className="row" style={{ gap: 6, cursor: 'pointer' }}>
          <input type="radio" data-testid={`size-default-${index}`} checked={s.isDefault} onChange={onDefault} style={{ accentColor: 'var(--accent)' }} />
          <span style={{ fontSize: 13 }}>Default</span>
        </label>
        <span className="row" style={{ gap: 6 }}>
          <Switch checked={s.available} onChange={(v) => onChange({ available: v })} label="In stock" />
          <span style={{ fontSize: 13 }}>{s.available ? 'In stock' : 'Sold out'}</span>
        </span>
        {onRecipe && <TextButton small label="Recipe" icon={Blend} testId={`size-recipe-${index}`} onClick={onRecipe} />}
        {canRemove && <TextButton small danger label="Remove" icon={Trash2} testId={`size-remove-${index}`} onClick={onRemove} />}
      </div>
    </div>
  );
}

/**
 * What one sold unit of a size uses from stock. Without its own recipe a size uses the full portion's recipe scaled
 * by its portion ratio; saving here gives it its own. Shows the cost of one serving next to its selling price.
 */
function RecipeDialog({ variantId, title, close }: { variantId: string; title: string; close: () => void }) {
  const [recipe, setRecipe] = useState<Json | null>(null);
  const [products, setProducts] = useState<Json[] | null>(null);
  const [lines, setLines] = useState<{ key: number; productId: string | null; qty: string; unit: string }[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    Promise.all([api.recipe(variantId), api.invProducts()]).then(
      ([r, p]) => {
        setRecipe(r);
        setProducts(p);
        setLines((r.lines as Json[]).map((l) => ({ key: sizeKey++, productId: l.productId ?? null, qty: `${l.quantity}`, unit: `${l.unit}` })));
      },
      (e) => setError(errorText(e)),
    );
  }, [variantId]);

  const save = async () => {
    const out: Json[] = [];
    for (const l of lines) {
      const q = Number(l.qty.trim());
      if (l.productId == null || !(q > 0)) return setError('Every ingredient needs a product and a quantity above 0');
      out.push({ productId: l.productId, quantity: q, unit: l.unit });
    }
    setBusy(true);
    setError(null);
    try {
      setRecipe(await api.setRecipe(variantId, out));
      close();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const set = (k: number, p: Partial<(typeof lines)[number]>) => setLines((ls) => ls.map((l) => (l.key === k ? { ...l, ...p } : l)));
  return (
    <Dialog
      title={`Recipe · ${title}`}
      size="wide"
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={busy ? null : close} />
          <PrimaryButton label="Save recipe" busy={busy} height={56} testId="save-recipe" onClick={products == null ? null : save} />
        </>
      }
    >
      {recipe == null ? (
        error == null ? <div className="progress indeterminate"><div /></div> : <span className="danger-text">{error}</span>
      ) : (
        <div className="col gap-8">
          <span className="muted">
            {recipe.own === true ? 'One sold serving uses:' : lines.length === 0 ? 'No recipe yet: selling it takes nothing from stock.' : "Using the full portion × this size's ratio. Save to give this size its own amounts."}
          </span>
          {lines.map((l, i) => (
            <div key={l.key} className="row" style={{ alignItems: 'flex-end' }}>
              <Select<string | null>
                label="Ingredient"
                testId={`recipe-product-${i}`}
                style={{ flex: 3 }}
                value={l.productId}
                options={(products ?? []).map((x) => [x.id as string, `${x.name} (${x.sku})`])}
                onChange={(v) => set(l.key, { productId: v, unit: `${products!.find((x) => x.id === v)?.baseUnit ?? l.unit}` })}
              />
              <TextField label="Qty" inputMode="decimal" value={l.qty} onChange={(v) => set(l.key, { qty: v })} testId={`recipe-qty-${i}`} style={{ width: 90 }} />
              <Select<string> label="Unit" style={{ width: 96 }} value={l.unit} options={[...new Set([l.unit, 'g', 'kg', 'ml', 'l', 'piece', 'bottle', 'can', 'packet'])].map((u) => [u, u])} onChange={(v) => set(l.key, { unit: v })} />
              <IconButton title="Remove" icon={Trash2} onClick={() => setLines((ls) => ls.filter((x) => x.key !== l.key))} />
            </div>
          ))}
          <div>
            <TextButton
              label={(products ?? []).length === 0 ? 'Add products in Inventory first' : 'Add ingredient'}
              icon={Plus}
              testId="add-ingredient"
              onClick={(products ?? []).length === 0 ? null : () => setLines((ls) => [...ls, { key: sizeKey++, productId: null, qty: '', unit: 'g' }])}
            />
          </div>
          <hr className="divider" />
          <span className="t-label" data-testid="recipe-cost">
            Cost of one serving {rupees(Number(recipe.costPaise))} · sells for {rupees(Number(recipe.pricePaise))}
          </span>
          {error && <span className="danger-text">{error}</span>}
        </div>
      )}
    </Dialog>
  );
}
