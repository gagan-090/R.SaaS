import { useCallback, useEffect, useState, type CSSProperties } from 'react';
import {
  ArrowLeftRight, CalendarX, ChefHat, ClipboardCheck, Copy, CornerDownLeft, Flag, History, Lock, MoreVertical, Package, Pencil, Plus, ShoppingCart, SlidersHorizontal, Sparkles, Tags, Trash2, Truck, Undo2, FileUp, CheckCircle2, X,
  type LucideIcon,
} from 'lucide-react';
import { api, ApiException, errorText, type Json } from '../../api/client';
import { copyText } from '../../lib/download';
import { qtyText, rupees, shortDate } from '../../lib/format';
import { deriveCode, restaurantShortPrefix } from '../../lib/menuRules';
import { parseRupees, plainRupees } from '../../lib/money';
import { useSession } from '../../state/auth';
import { useRestaurantLook } from '../../state/app';
import { useAsync } from '../../ui/async';
import { CategoryChip, Chip, EmptyState, ErrorState, IconButton, KpiCard, LoadingState, MenuButton, PageFrame, PrimaryButton, SearchField, SecondaryButton, SectionCard, Select, Skeleton, StatusChip, SwitchRow, TextButton, TextField } from '../../ui/kit';
import { Dialog, openDialog, showDone, showError } from '../../ui/overlay';
import { ImportDialog } from './ImportDialog';

const stockUnits = ['g', 'kg', 'mg', 'ml', 'l', 'piece', 'dozen', 'bottle', 'can', 'packet', 'box', 'case', 'plate', 'portion'];
const standardInvCategories = ['Grains & Flour', 'Dairy & Eggs', 'Produce & Veg', 'Meat & Seafood', 'Oils & Condiments', 'Spices & Seasoning', 'Beverages', 'Packaging & Disposables'];
const unitPresets: [string, string, string, number, string][] = [
  ['Grains & Flour', 'g', 'kg', 1000, 'Grains: 1 kg = 1000 g'],
  ['Liquids & Dairy', 'ml', 'l', 1000, 'Liquids: 1 L = 1000 ml'],
  ['Packaged Drinks', 'can', 'case', 24, 'Drinks: 1 case = 24 cans'],
  ['Bottles', 'bottle', 'box', 12, 'Bottles: 1 box = 12 btl'],
  ['Eggs', 'piece', 'dozen', 12, 'Eggs: 1 doz = 12 pcs'],
  ['Spices & Herbs', 'g', 'packet', 500, 'Spices: 1 pkt = 500 g'],
  ['Meat & Fish', 'g', 'kg', 1000, 'Meat: 1 kg = 1000 g'],
  ['Packaging', 'piece', 'box', 100, 'Pack: 1 box = 100 pcs'],
  ['Single Portion', 'portion', 'portion', 1, 'Portion: 1 = 1'],
];

/** Movement types a person can post, with the words staff see and the permission each needs. */
const movementTypes: [string, string, string, LucideIcon][] = [
  ['purchase', 'Receive stock', 'inventory.write', Truck],
  ['consumption', 'Kitchen use', 'inventory.consume', ChefHat],
  ['wastage', 'Wastage', 'inventory.consume', Trash2],
  ['count', 'Stock count', 'inventory.write', ClipboardCheck],
  ['adjustment', 'Adjust', 'inventory.write', SlidersHorizontal],
  ['return_to_supplier', 'Return to supplier', 'inventory.write', Undo2],
  ['customer_return', 'Customer return', 'inventory.write', CornerDownLeft],
  ['transfer', 'Move to another location', 'inventory.write', ArrowLeftRight],
  ['opening', 'Opening stock', 'inventory.write', Flag],
];
const typeLabels: Record<string, string> = {
  opening: 'Opening stock', purchase: 'Received', sale: 'Sold (from bills)', consumption: 'Kitchen use', wastage: 'Wastage',
  return_to_supplier: 'Returned to supplier', customer_return: 'Customer return', count_adjustment: 'Count correction',
  adjustment: 'Adjustment', transfer_out: 'Moved out', transfer_in: 'Moved in',
};
const wastageReasons = ['Spoiled', 'Expired', 'Burnt / over-cooked', 'Dropped / spilled', 'Prepared but not sold', 'Returned by guest'];

/** One key per dialog: a double tap or a retry after a network error never records the movement twice. */
const newIdempotencyKey = (prefix = 'web') => `${prefix}-${crypto.randomUUID?.() ?? `${Date.now()}-${Math.floor(Math.random() * 2 ** 32)}`}`;
const trimZeros = (v: unknown) => `${v}`.replace(/\.0+$/, '');

/**
 * Inventory (plan feature "inventory"): stock, purchases, movements, alerts, replenishment requests, suppliers & locations,
 * valuation. What each person can do follows their permissions; the API checks them again.
 */
export function InventoryScreen() {
  const me = useSession();
  const look = useRestaurantLook();
  const can = (p: string) => !!me?.can(p);
  const isOwner = !!me?.roles.includes('owner');
  const prefix = restaurantShortPrefix(me?.restaurantName ?? look?.name, me?.restaurantCode);
  const [products, setProducts] = useState<Json[] | null>(null);
  const [locations, setLocations] = useState<Json[]>([]);
  const [suppliers, setSuppliers] = useState<Json[]>([]);
  const [alerts, setAlerts] = useState<Json | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [q, setQ] = useState('');
  const [stockCat, setStockCat] = useState<string | null>(null);
  const [tab, setTab] = useState(0);
  const [reload, setReload] = useState(0);

  const load = useCallback(async () => {
    try {
      const [p, l, s, a] = await Promise.all([api.invProducts(), api.invLocations(), api.invSuppliers(), api.invAlerts()]);
      setProducts(p);
      setLocations(l);
      setSuppliers(s);
      setAlerts(a);
      setError(null);
      setReload((n) => n + 1);
    } catch (e) {
      setError(e);
    }
  }, []);
  useEffect(() => void load(), [load]);

  const purchase = async () => {
    if (!products?.length || suppliers.length === 0) return showError('Add products and a supplier first, then receive your purchase here.');
    if ((await openDialog<boolean>((close) => <PurchaseDialog products={products} suppliers={suppliers} locations={locations} close={close} />)) === true) {
      await load();
      showDone('Purchase received. Stock and cost updated.');
    }
  };

  const editProduct = async (p?: Json, initialCategory?: string) => {
    const known = [...new Set((products ?? []).map((x) => x.category as string | null).filter((c): c is string => !!c))];
    const saved = await openDialog<string>((close) => <ProductEditor product={p} locations={locations} suppliers={suppliers} initialCategory={initialCategory} restaurantPrefix={prefix} knownCategories={known} close={close} />);
    if (saved != null) {
      await load();
      showDone(saved);
    }
  };

  const addCategory = async () => {
    const c = await openDialog<string>((close) => <NewCategoryDialog close={close} />);
    if (!c?.trim()) return;
    setStockCat(c.trim());
    await editProduct(undefined, c.trim());
  };

  const move = async (p: Json, type: string) => {
    const done = await openDialog<string>((close) => <MovementDialog product={p} type={type} locations={locations} suppliers={suppliers} close={close} />);
    if (done != null) {
      await load();
      showDone(done);
    }
  };

  const importInventory = async () => {
    if (!can('import.run')) return showError('Excel import is not in your plan. Ask the Super Admin to enable "Excel import (menu & inventory)" in Plans, then sign in again.');
    if ((await openDialog<boolean>((close) => <ImportDialog kind="inventory" close={close} />)) === true) await load();
  };

  if (error instanceof ApiException && error.code === 'feature_not_in_plan')
    return (
      <PageFrame title="Inventory">
        <EmptyState testId="inventory-locked" icon={Lock} title="Inventory is not in your plan" message="Ask House Plating to add inventory to your plan. Stock, recipes and wastage tracking then appear here." />
      </PageFrame>
    );
  if (error != null) return <ErrorState message={errorText(error)} onRetry={load} />;
  if (products == null || alerts == null) return <LoadingState />;

  const alertCount = (alerts.low as Json[]).length + (alerts.negative as Json[]).length + (alerts.expiring as Json[]).length;
  const allowed = movementTypes.filter((m) => can(m[2]));

  const stockTab = () => {
    const existing = [...new Set(products.map((x) => `${x.category ?? ''}`.trim()).filter(Boolean))].sort();
    const shown = products.filter((x) => (stockCat == null || x.category === stockCat) && (q === '' || `${x.name} ${x.sku} ${x.category ?? ''}`.toLowerCase().includes(q.toLowerCase())));
    return (
      <div className="col gap-12">
        <div className="wrap" style={{ gap: 8 }}>
          <div style={{ flex: '1 1 240px', minWidth: 0 }}>
            <SearchField hint="Search name, SKU or category" onChange={(v) => setQ(v.trim())} />
          </div>
          {can('inventory.manage') && <SecondaryButton label="Add category" icon={Plus} height={48} testId="inv-category-plus" onClick={addCategory} />}
        </div>
        <div className="chip-scroll" style={{ gap: 6 }}>
          <CategoryChip testId="inv-cat-all" label={`All (${products.length})`} on={stockCat == null} onClick={() => setStockCat(null)} />
          {existing.map((c) => (
            <CategoryChip key={c} testId={`inv-cat-${c}`} label={`${c} (${products.filter((x) => x.category === c).length})`} on={stockCat === c} onClick={() => setStockCat(c)} />
          ))}
        </div>
        {shown.length === 0 ? (
          <EmptyState icon={Package} title={products.length === 0 ? 'No products yet' : 'Nothing matches'} message={products.length === 0 ? 'Add ingredients and packaged drinks, or import them from Excel.' : 'Try another search or select another category.'} />
        ) : (
          <div className="card list">
            {shown.map((x) => {
              const copySku = async () => (await copyText(`${x.sku}`)) && showDone(`Copied SKU ${x.sku}`);
              return (
                <div key={x.id} className="list-row row-chips no-lead" data-testid={`product-${x.sku}`}>
                  <div className="grow">
                    <div className={`t-label${x.active === true ? '' : ' faint'}`}>{`${x.name}`}</div>
                    <div className="wrap mt-4" style={{ gap: 6 }}>
                      <button type="button" className="tag" title={`Click to copy SKU: ${x.sku}`} data-testid={`copy-sku-${x.sku}`} onClick={copySku}>
                        {`${x.sku}`}
                        <Copy size={11} aria-hidden />
                      </button>
                      {x.category != null && <span className="muted">· {`${x.category}`}</span>}
                      <span className="muted">
                        · avg {rupees(Math.round(Number(x.avgCostPaise)))}/{`${x.baseUnit}`}
                      </span>
                    </div>
                  </div>
                  <div className="wrap chips" style={{ gap: 8, justifyContent: 'flex-end' }}>
                    {x.negative === true ? <StatusChip label="Below zero" tone="danger" /> : x.low === true ? <StatusChip label="Low" tone="saffron" /> : null}
                    {((x.expiring ?? []) as Json[]).length > 0 && <StatusChip label="Expiring" tone="danger" icon={CalendarX} />}
                    <span className="t-label" data-testid={`stock-${x.sku}`}>
                      {qtyText(Number(x.stock), `${x.baseUnit}`)}
                    </span>
                    {(allowed.length > 0 || can('inventory.manage')) && (
                      <MenuButton
                        title="Record a movement"
                        icon={MoreVertical}
                        testId={`actions-${x.sku}`}
                        items={[
                          ...allowed.map(([t, l, , Icon]) => ({ label: l, icon: Icon, onClick: () => move(x, t) })),
                          { label: 'Copy SKU', icon: Copy, onClick: copySku },
                          can('inventory.manage') && { label: 'Edit product', icon: Pencil, onClick: () => editProduct(x) },
                        ]}
                      />
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>
    );
  };

  const tabs: [string, () => JSX.Element][] = [
    ['Stock', stockTab],
    [
      'Purchases',
      () => (
        <div className="col gap-16">
          {can('inventory.write') && (
            <div className="row" style={{ justifyContent: 'flex-end' }}>
              <PrimaryButton label="Receive purchase" icon={Truck} onClick={purchase} />
            </div>
          )}
          <MovementsTab key={`purchases-${reload}`} initialType="purchase" />
        </div>
      ),
    ],
    ['Movements', () => <MovementsTab key={`mv-${reload}`} />],
    [`Alerts${alertCount > 0 ? ` · ${alertCount}` : ''}`, () => <AlertsTab alerts={alerts} />],
    ['Requests', () => <RequestsTab key={`rq-${reload}`} products={products} canRequest={can('inventory.request')} canHandle={can('inventory.write')} />],
    ['Suppliers & places', () => <PlacesTab locations={locations} suppliers={suppliers} canManage={can('inventory.manage')} onChanged={load} />],
    ['Value', () => <ValuationTab key={`val-${reload}`} />],
  ];

  return (
    <PageFrame
      title="Inventory"
      subtitle={`${products.length} products · stock comes only from recorded movements`}
      actions={
        <>
          {(can('import.run') || isOwner) && can('inventory.manage') && can('inventory.write') && <SecondaryButton label="Import Excel" icon={can('import.run') ? FileUp : Lock} testId="import-inventory" onClick={importInventory} />}
          {can('inventory.manage') && <PrimaryButton label="Add product" icon={Plus} height={48} testId="add-product" onClick={() => editProduct()} />}
        </>
      }
    >
      <div className="chip-scroll">
        {tabs.map(([l], i) => (
          <CategoryChip key={i} testId={`inv-tab-${i}`} label={l} on={tab === i} onClick={() => setTab(i)} />
        ))}
      </div>
      <div className="mt-16">{tabs[tab][1]()}</div>
    </PageFrame>
  );
}

// ---------------------------------------------------------------- dialogs

function NewCategoryDialog({ close }: { close: (v?: string) => void }) {
  const [v, setV] = useState('');
  return (
    <Dialog
      title="New inventory category"
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={() => close()} />
          <PrimaryButton label="Add & create product" height={52} onClick={() => close(v)} />
        </>
      }
    >
      <div className="col gap-8">
        <TextField label="Category name" placeholder="e.g. Dairy & Eggs, Spices, Oils" value={v} onChange={setV} autoFocus testId="new-inv-cat-input" />
        <div className="wrap" style={{ gap: 6 }}>
          {standardInvCategories.map((c) => (
            <Chip key={c} small label={c} onClick={() => setV(c)} />
          ))}
        </div>
      </div>
    </Dialog>
  );
}

function ProductEditor({ product, locations, suppliers, initialCategory, restaurantPrefix, knownCategories, close }: {
  product?: Json;
  locations: Json[];
  suppliers: Json[];
  initialCategory?: string;
  restaurantPrefix: string;
  knownCategories: string[];
  close: (v?: string) => void;
}) {
  const isNew = product == null;
  const [sku, setSku] = useState<string>(product?.sku ?? (restaurantPrefix ? `${restaurantPrefix}INV-` : ''));
  const [name, setName] = useState<string>(product?.name ?? '');
  const [cat, setCat] = useState<string>(product?.category ?? initialCategory ?? '');
  const [factor, setFactor] = useState(trimZeros(product?.conversionFactor ?? 1));
  const [cost, setCost] = useState(product == null ? '' : plainRupees(Number(product.unitCostPaise)));
  const [opening, setOpening] = useState('');
  const [min, setMin] = useState(trimZeros(product?.minStock ?? 0));
  const [base, setBase] = useState<string>(product?.baseUnit ?? 'g');
  const [purchase, setPurchase] = useState<string>(product?.purchaseUnit ?? 'kg');
  const [supplier, setSupplier] = useState<string | null>(product?.defaultSupplierId ?? null);
  const [location, setLocation] = useState<string | null>(product?.defaultLocationId ?? null);
  const [active, setActive] = useState<boolean>(product?.active ?? true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const applyPreset = (u: (typeof unitPresets)[number]) => {
    setBase(u[1]);
    setPurchase(u[2]);
    setFactor(trimZeros(u[3]));
  };

  const save = async () => {
    // same unit both ways: nothing to convert, whatever the box held
    const f = base === purchase ? 1 : Number(factor.trim());
    const open = opening.trim() === '' ? 0 : Number(opening.trim());
    const costPaise = cost.trim() === '' ? 0 : parseRupees(cost);
    const m = min.trim() === '' ? 0 : Number(min.trim());
    if (isNew && !/^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$/.test(sku.trim())) return setError('SKU: letters, digits, - _ . (no spaces)');
    if (!name.trim()) return setError('Enter a product name');
    if (!(f > 0)) return setError('Conversion must be a number above 0');
    if (costPaise == null || costPaise < 0) return setError('Cost must be a number (₹ per purchase unit)');
    if (!Number.isFinite(m) || m < 0) return setError('Reorder level must be 0 or more');
    if (!Number.isFinite(open) || open < 0) return setError('Stock in hand must be 0 or more');
    setBusy(true);
    setError(null);
    const body: Json = { name: name.trim(), category: cat.trim() === '' ? null : cat.trim(), baseUnit: base, purchaseUnit: purchase, conversionFactor: f, unitCostPaise: costPaise, minStock: m, defaultSupplierId: supplier, defaultLocationId: location, active };
    try {
      if (isNew) {
        const created = await api.createInvProduct({ ...body, sku: sku.trim().toUpperCase() });
        // stock only changes through movements, so the "stock in hand" box records the opening stock right away
        if (open > 0 && created.id != null) {
          await api.invMove({ type: 'opening', productId: created.id, quantity: open, unit: purchase, locationId: location, unitCostPaise: costPaise, idempotencyKey: newIdempotencyKey('web-open') });
        }
      } else await api.updateInvProduct(product!.id, body);
      close(`${name.trim()} saved`);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const unitSelect = (testId: string, label: string, value: string, on: (v: string) => void) => <Select<string> label={label} testId={testId} value={value} options={stockUnits.map((u) => [u, u])} onChange={on} />;
  const quickCats = [...new Set([...knownCategories, ...standardInvCategories])].slice(0, 8);

  return (
    <Dialog
      title={isNew ? 'Add a product' : `Edit ${product!.name}`}
      size="wide"
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={busy ? null : () => close()} />
          <PrimaryButton label="Save" busy={busy} height={56} testId="save-product" onClick={save} />
        </>
      }
    >
      <div className="col gap-12">
        <div className="cols" style={{ '--cols': '1fr 2fr' } as CSSProperties}>
          <TextField
            label="SKU (stable code)"
            upper
            value={sku}
            onChange={setSku}
            disabled={!isNew}
            testId="product-sku"
            placeholder={restaurantPrefix ? `e.g. ${restaurantPrefix}001` : 'RICE-BAS'}
            suffix={isNew ? <IconButton title="Generate SKU" icon={Sparkles} sm onClick={() => setSku(deriveCode(name, restaurantPrefix || 'INV-'))} /> : undefined}
          />
          <TextField label="Product name" value={name} onChange={setName} testId="product-name" />
        </div>
        <div className="row" style={{ alignItems: 'flex-end' }}>
          <TextField label="Category" placeholder="Grains, Dairy, Packaged drinks" value={cat} onChange={setCat} testId="product-cat" style={{ flex: 1 }} />
          <Chip
            label="New category"
            icon={Plus}
            testId="editor-cat-plus"
            onClick={async () => {
              const c = await openDialog<string>((cl) => <QuickCategory close={cl} />);
              if (c?.trim()) setCat(c.trim());
            }}
          />
        </div>
        <div className="wrap" style={{ gap: 6 }}>
          {quickCats.map((c) => (
            <Chip
              key={c}
              small
              label={c}
              onClick={() => {
                setCat(c);
                const m = unitPresets.find((u) => u[0].toLowerCase().includes(c.toLowerCase()) || c.toLowerCase().includes(u[0].toLowerCase()));
                if (m) applyPreset(m);
              }}
            />
          ))}
        </div>
        <div className="t-overline">Specialize unit according to product:</div>
        <div className="wrap" style={{ gap: 6 }}>
          {unitPresets.map((u) => (
            <Chip key={u[4]} small label={u[4]} onClick={() => applyPreset(u)} />
          ))}
        </div>
        <span className="muted" style={{ fontSize: 12 }}>
          "Count in" is how recipes and stock are measured (e.g. g). "Buy in" is how the supplier sells it (e.g. kg). When they differ, say how many of one fit in the other — 1 kg = 1000 g.
        </span>
        <div className="cols" style={{ '--cols': '1fr 1fr 1fr', alignItems: 'start' } as CSSProperties}>
          {unitSelect('base-unit', 'Count in', base, setBase)}
          {unitSelect('purchase-unit', 'Buy in', purchase, setPurchase)}
          {base === purchase ? (
            <TextField label="Conversion" value="Same unit" disabled testId="product-factor-same" />
          ) : (
            <TextField label={`${base} in 1 ${purchase}`} inputMode="decimal" value={factor} onChange={setFactor} help={`e.g. 1 ${purchase} = ${factor || '?'} ${base}`} testId="product-factor" />
          )}
        </div>
        {isNew ? (
          <TextField label={`Stock in hand now (optional, ${purchase})`} inputMode="decimal" value={opening} onChange={setOpening} help="Saved as opening stock. Later stock comes from Received, Kitchen use and bills." testId="product-opening" />
        ) : (
          <span className="muted" style={{ fontSize: 12 }} data-testid="product-stock-note">
            In stock: {qtyText(Number(product!.stock ?? 0), base)}. To add or correct stock, use "Receive stock" or "Stock count" from the product's ⋮ menu — this form does not change the quantity.
          </span>
        )}
        <div className="cols">
          <TextField label={`Cost per ${purchase}`} prefix="₹" inputMode="decimal" value={cost} onChange={setCost} testId="product-cost" />
          <TextField label={`Reorder level (${base})`} inputMode="decimal" value={min} onChange={setMin} testId="product-min" />
        </div>
        <Select<string | null> label="Usual supplier" value={supplier} options={[[null, '—'], ...suppliers.map((s) => [s.id as string, `${s.name}`] as [string, string])]} onChange={setSupplier} />
        <Select<string | null> label="Stored in" value={location} options={[[null, 'Main store'], ...locations.map((l) => [l.id as string, `${l.name}`] as [string, string])]} onChange={setLocation} />
        <SwitchRow title="Active" checked={active} onChange={setActive} />
        {error && (
          <span className="danger-text" data-testid="product-error">
            {error}
          </span>
        )}
      </div>
    </Dialog>
  );
}

function QuickCategory({ close }: { close: (v?: string) => void }) {
  const [v, setV] = useState('');
  return (
    <Dialog
      title="Quick Category"
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={() => close()} />
          <PrimaryButton label="Use" height={48} onClick={() => close(v)} />
        </>
      }
    >
      <TextField label="Category name" value={v} onChange={setV} autoFocus onEnter={() => close(v)} />
    </Dialog>
  );
}

function MovementDialog({ product, type, locations, suppliers, close }: { product: Json; type: string; locations: Json[]; suppliers: Json[]; close: (v?: string) => void }) {
  const label = movementTypes.find((m) => m[0] === type)![1];
  const inbound = type === 'purchase' || type === 'opening';
  const needsReason = ['wastage', 'adjustment', 'count', 'return_to_supplier', 'customer_return'].includes(type);
  const [qty, setQty] = useState('');
  const [unit, setUnit] = useState<string>(['purchase', 'opening', 'return_to_supplier'].includes(type) ? `${product.purchaseUnit}` : `${product.baseUnit}`);
  const [location, setLocation] = useState<string | null>(product.defaultLocationId ?? null);
  const [to, setTo] = useState<string | null>(null);
  const [supplier, setSupplier] = useState<string | null>(product.defaultSupplierId ?? null);
  const [cost, setCost] = useState('');
  const [ref, setRef] = useState('');
  const [batch, setBatch] = useState('');
  const [expiry, setExpiry] = useState('');
  const [reason, setReason] = useState('');
  const [negative, setNegative] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [key] = useState(() => newIdempotencyKey());

  const save = async () => {
    const q = Number(qty.trim());
    if (qty.trim() === '' || !Number.isFinite(q) || (type === 'count' ? q < 0 : q <= 0)) return setError(type === 'count' ? 'Enter the quantity you counted' : 'Enter a quantity above 0');
    if (needsReason && !reason.trim()) return setError('Give a reason');
    if (expiry.trim() && !/^\d{4}-\d{2}-\d{2}$/.test(expiry.trim())) return setError('Expiry date as YYYY-MM-DD');
    if (type === 'transfer' && (to === null || to === location)) return setError('Choose where the stock goes');
    const costPaise = cost.trim() === '' ? null : parseRupees(cost);
    setBusy(true);
    setError(null);
    try {
      const r = await api.invMove({
        type,
        productId: product.id,
        quantity: type === 'adjustment' && negative ? -q : q,
        unit,
        locationId: location,
        ...(type === 'transfer' ? { toLocationId: to } : {}),
        ...(inbound && costPaise != null ? { unitCostPaise: costPaise } : {}),
        ...(supplier != null && (inbound || type === 'return_to_supplier') ? { supplierId: supplier } : {}),
        ...(ref.trim() ? { reference: ref.trim() } : {}),
        ...(batch.trim() ? { batchNumber: batch.trim() } : {}),
        ...(expiry.trim() ? { expiryDate: expiry.trim() } : {}),
        ...(reason.trim() ? { reason: reason.trim() } : {}),
        idempotencyKey: key,
      });
      close((r.movements as unknown[]).length === 0 ? 'Count matches the stock — nothing changed' : `${label} recorded for ${product.name}`);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const units = [...new Set([`${product.baseUnit}`, `${product.purchaseUnit}`, ...stockUnits])];
  const locs: [string | null, string][] = [[null, 'Main store'], ...locations.map((l) => [l.id as string, `${l.name}`] as [string, string])];
  return (
    <Dialog
      title={`${label} · ${product.name}`}
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={busy ? null : () => close()} />
          <PrimaryButton label="Record" busy={busy} height={56} testId="save-movement" onClick={save} />
        </>
      }
    >
      <div className="col gap-12">
        <span className="muted">In stock now: {qtyText(Number(product.stock), `${product.baseUnit}`)}</span>
        <div className="row" style={{ alignItems: 'flex-end' }}>
          <TextField label={type === 'count' ? 'Counted quantity' : 'Quantity'} inputMode="decimal" autoFocus value={qty} onChange={setQty} testId="mv-qty" style={{ flex: 1 }} />
          <Select<string> label="Unit" testId="mv-unit" value={unit} options={units.map((u) => [u, u])} onChange={setUnit} style={{ width: 120 }} />
        </div>
        {type === 'adjustment' && <SwitchRow title={negative ? 'Remove from stock' : 'Add to stock'} checked={negative} onChange={setNegative} testId="mv-negative" />}
        <Select<string | null> label={type === 'transfer' ? 'From' : 'Location'} value={location} options={locs} onChange={setLocation} />
        {type === 'transfer' && <Select<string | null> label="To" testId="mv-to" value={to} options={locs} onChange={setTo} />}
        {(inbound || type === 'return_to_supplier') && (
          <>
            <div className="cols">
              {inbound && <TextField label={`Cost per ${unit}`} prefix="₹" inputMode="decimal" value={cost} onChange={setCost} testId="mv-cost" />}
              <TextField label="Invoice / reference" value={ref} onChange={setRef} />
            </div>
            <Select<string | null> label="Supplier" value={supplier} options={[[null, '—'], ...suppliers.map((s) => [s.id as string, `${s.name}`] as [string, string])]} onChange={setSupplier} />
          </>
        )}
        {inbound && (
          <div className="cols">
            <TextField label="Batch (optional)" value={batch} onChange={setBatch} />
            <TextField label="Expiry (YYYY-MM-DD)" type="date" value={expiry} onChange={setExpiry} testId="mv-expiry" />
          </div>
        )}
        {(needsReason || type === 'consumption') && (
          <>
            {type === 'wastage' && (
              <div className="wrap" style={{ gap: 4 }}>
                {wastageReasons.map((w) => (
                  <Chip key={w} small label={w} onClick={() => setReason(w)} />
                ))}
              </div>
            )}
            <TextField label={needsReason ? 'Reason (required)' : 'Note (optional)'} value={reason} onChange={setReason} testId="mv-reason" />
          </>
        )}
        {error && (
          <span className="danger-text" data-testid="mv-error">
            {error}
          </span>
        )}
      </div>
    </Dialog>
  );
}

type PLine = { key: number; product: string | null; qty: string; cost: string };
let lineKey = 1;

function PurchaseDialog({ products, suppliers, locations, close }: { products: Json[]; suppliers: Json[]; locations: Json[]; close: (v?: boolean) => void }) {
  const [reference, setReference] = useState('');
  const [lines, setLines] = useState<PLine[]>([{ key: lineKey++, product: null, qty: '1', cost: '' }]);
  const [supplier, setSupplier] = useState<string | null>(null);
  const [location, setLocation] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [key] = useState(() => crypto.randomUUID?.() ?? newIdempotencyKey());
  const set = (k: number, p: Partial<PLine>) => setLines((ls) => ls.map((l) => (l.key === k ? { ...l, ...p } : l)));

  const save = async () => {
    if (supplier == null || !reference.trim()) return setError('Choose a supplier and enter the invoice number.');
    const out: Json[] = [];
    for (const l of lines) {
      const q = Number(l.qty), c = parseRupees(l.cost);
      if (l.product == null || !(q > 0) || c == null || c < 0) return setError('Each line needs a product, positive quantity and unit cost.');
      const p = products.find((x) => x.id === l.product)!;
      out.push({ productId: l.product, quantity: q, unit: p.purchaseUnit, unitCostPaise: c });
    }
    setBusy(true);
    setError(null);
    try {
      await api.receivePurchase({ supplierId: supplier, reference: reference.trim(), locationId: location, idempotencyKey: key, lines: out });
      close(true);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Dialog
      title="Receive a purchase"
      size="wide"
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={busy ? null : () => close()} />
          <PrimaryButton label="Receive & update stock" busy={busy} onClick={save} />
        </>
      }
    >
      <div className="col gap-12">
        <span>Record the delivered quantities. Every line updates stock and average cost together.</span>
        <Select<string | null> label="Supplier" disabled={busy} value={supplier} options={suppliers.map((s) => [s.id as string, `${s.name}`] as [string, string])} onChange={setSupplier} />
        <TextField label="Supplier invoice / receipt number" value={reference} onChange={setReference} />
        <Select<string | null> label="Storage location" disabled={busy} value={location} options={[[null, 'Default location'], ...locations.map((l) => [l.id as string, `${l.name}`] as [string, string])]} onChange={setLocation} />
        {lines.map((l, i) => (
          <div key={l.key} className="col gap-8 mt-8">
            <Select<string | null>
              label={`Product ${i + 1}`}
              disabled={busy}
              value={l.product}
              options={products.filter((p) => p.active !== false).map((p) => [p.id as string, `${p.name} · ${p.purchaseUnit}`] as [string, string])}
              onChange={(v) => {
                const p = products.find((x) => x.id === v);
                set(l.key, { product: v, cost: p ? plainRupees(Number(p.unitCostPaise)) : l.cost });
              }}
            />
            <div className="row" style={{ alignItems: 'flex-end' }}>
              <TextField label="Quantity" inputMode="decimal" value={l.qty} onChange={(v) => set(l.key, { qty: v })} style={{ flex: 1 }} />
              <TextField label="Cost per purchase unit" prefix="₹" inputMode="decimal" value={l.cost} onChange={(v) => set(l.key, { cost: v })} style={{ flex: 1 }} />
              <IconButton title="Remove line" icon={X} onClick={busy || lines.length === 1 ? null : () => setLines((ls) => ls.filter((x) => x.key !== l.key))} />
            </div>
          </div>
        ))}
        <div>
          <TextButton label="Add product" icon={Plus} onClick={busy || lines.length >= 100 ? null : () => setLines((ls) => [...ls, { key: lineKey++, product: null, qty: '1', cost: '' }])} />
        </div>
        {error && <span className="danger-text">{error}</span>}
      </div>
    </Dialog>
  );
}

// ---------------------------------------------------------------- tabs

function MovementsTab({ initialType }: { initialType?: string }) {
  const [type, setType] = useState<string | null>(initialType ?? null);
  const { data: rows } = useAsync(() => api.invMovements({ type }), [type]);
  if (rows == null) return <Skeleton h={200} />;
  return (
    <div className="col gap-12">
      <div className="wrap" style={{ gap: 4 }}>
        <Chip label="All" on={type == null} onClick={() => setType(null)} />
        {Object.entries(typeLabels).map(([k, l]) => (
          <Chip key={k} testId={`mvf-${k}`} label={l} on={type === k} onClick={() => setType(k)} />
        ))}
      </div>
      {rows.length === 0 ? (
        <EmptyState icon={History} title="No movements" message="Receipts, kitchen use, wastage, counts and sales appear here." />
      ) : (
        <div className="card list">
          {rows.map((m, i) => (
            <div key={m.id ?? i} className="list-row" style={{ padding: '8px 16px' }}>
              <div className="grow">
                <div className="t-label">
                  {typeLabels[m.type] ?? `${m.type}`} · {`${m.productName}`}
                </div>
                <div className="muted">{[shortDate(m.createdAt), `${m.actorName}`, m.reason != null ? `${m.reason}` : null, m.reference != null ? `ref ${m.reference}` : null, m.batchNumber != null ? `batch ${m.batchNumber}` : null].filter(Boolean).join(' · ')}</div>
              </div>
              <div className="col" style={{ alignItems: 'flex-end', gap: 0 }}>
                <span className={`t-label ${Number(m.quantity) < 0 ? 'danger-text' : 'success-text'}`}>{`${Number(m.quantity) > 0 ? '+' : ''}${qtyText(Number(m.quantity), `${m.baseUnit}`)}`}</span>
                <span className="muted" style={{ fontSize: 12 }}>
                  {rupees(Math.abs(Number(m.valuePaise)))}
                </span>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function AlertsTab({ alerts }: { alerts: Json }) {
  const low = alerts.low as Json[], neg = alerts.negative as Json[], exp = alerts.expiring as Json[];
  if (low.length === 0 && neg.length === 0 && exp.length === 0) return <EmptyState icon={CheckCircle2} title="All good" message="Nothing is low, below zero or about to expire." />;
  return (
    <div className="stack">
      {neg.length > 0 && (
        <SectionCard title="Below zero — sales recorded more than was in stock">
          {neg.map((x, i) => (
            <div key={i} className="danger-text">
              {`${x.name}`} · {qtyText(Number(x.stock), `${x.unit}`)}
            </div>
          ))}
        </SectionCard>
      )}
      {low.length > 0 && (
        <SectionCard title="Low stock">
          {low.map((x, i) => (
            <div key={i} data-testid={`low-${x.sku}`}>
              {`${x.name}`} · {qtyText(Number(x.stock), `${x.unit}`)} (reorder at {qtyText(Number(x.minStock), `${x.unit}`)})
            </div>
          ))}
        </SectionCard>
      )}
      {exp.length > 0 && (
        <SectionCard title="Expiring within 7 days">
          {exp.map((x, i) => (
            <div key={i} className={x.expired === true ? 'danger-text' : ''}>
              {`${x.name}`} · batch {`${x.batchNumber ?? '—'}`} · {x.expired === true ? 'EXPIRED' : 'expires'} {`${x.expiryDate}`} · {qtyText(Number(x.quantity), `${x.unit}`)}
            </div>
          ))}
        </SectionCard>
      )}
    </div>
  );
}

function RequestsTab({ products, canRequest, canHandle }: { products: Json[]; canRequest: boolean; canHandle: boolean }) {
  const [n, setN] = useState(0);
  const { data: rows } = useAsync(() => api.invRequests(), [n]);

  const create = async () => {
    const r = await openDialog<{ product: string; qty: number; note: string }>((close) => <RequestDialog products={products} close={close} />);
    if (!r) return;
    try {
      await api.invRequest({ productId: r.product, quantity: r.qty, unit: products.find((x) => x.id === r.product)!.purchaseUnit, ...(r.note ? { note: r.note } : {}) });
      setN((x) => x + 1);
      showDone('Request sent');
    } catch (e) {
      showError(e);
    }
  };
  const setStatus = async (r: Json, status: string) => {
    try {
      await api.invUpdateRequest(r.id, status);
      setN((x) => x + 1);
    } catch (e) {
      showError(e);
    }
  };

  if (rows == null) return <Skeleton h={160} />;
  return (
    <div className="col gap-12">
      {canRequest && (
        <div>
          <PrimaryButton label="Request stock" icon={ShoppingCart} height={44} testId="new-request" onClick={products.length === 0 ? null : create} />
        </div>
      )}
      {rows.length === 0 ? (
        <EmptyState icon={ShoppingCart} title="No requests" message="The kitchen asks for stock here; the owner or admin orders it." />
      ) : (
        <div className="card list">
          {rows.map((r) => (
            <div key={r.id} className="list-row">
              <div className="grow">
                <div className="t-label">
                  {`${r.product?.name}`} · {qtyText(Number(r.quantity), `${r.unit}`)}
                </div>
                <div className="muted">{[shortDate(r.createdAt), `by ${r.requestedByName}`, r.note != null ? `${r.note}` : null].filter(Boolean).join(' · ')}</div>
              </div>
              <div className="wrap" style={{ gap: 4, justifyContent: 'flex-end' }}>
                <StatusChip label={`${r.status}`} tone={r.status === 'received' ? 'success' : r.status === 'cancelled' ? 'neutral' : 'saffron'} />
                {canHandle && r.status === 'requested' && <TextButton label="Ordered" onClick={() => setStatus(r, 'ordered')} />}
                {canHandle && (r.status === 'requested' || r.status === 'ordered') && <TextButton label="Received" onClick={() => setStatus(r, 'received')} />}
                {canHandle && (r.status === 'requested' || r.status === 'ordered') && <TextButton label="Cancel" onClick={() => setStatus(r, 'cancelled')} />}
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function RequestDialog({ products, close }: { products: Json[]; close: (v?: { product: string; qty: number; note: string }) => void }) {
  const [product, setProduct] = useState<string | null>(products[0]?.id ?? null);
  const [qty, setQty] = useState('');
  const [note, setNote] = useState('');
  const send = () => {
    const q = Number(qty.trim());
    if (product == null || !(q > 0)) return close();
    close({ product, qty: q, note: note.trim() });
  };
  return (
    <Dialog
      title="Request stock"
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={() => close()} />
          <PrimaryButton label="Send" height={56} testId="send-request" onClick={send} />
        </>
      }
    >
      <div className="col gap-12">
        <Select<string | null> label="Product" value={product} options={products.map((x) => [x.id as string, `${x.name}`] as [string, string])} onChange={setProduct} />
        <TextField label={`Quantity (${products.find((x) => x.id === product)?.purchaseUnit ?? ''})`} inputMode="decimal" value={qty} onChange={setQty} testId="request-qty" />
        <TextField label="Note (optional)" value={note} onChange={setNote} />
      </div>
    </Dialog>
  );
}

function PlacesTab({ locations, suppliers, canManage, onChanged }: { locations: Json[]; suppliers: Json[]; canManage: boolean; onChanged: () => Promise<void> }) {
  const add = async (supplier: boolean) => {
    const r = await openDialog<{ name: string; phone: string }>((close) => <PlaceDialog supplier={supplier} close={close} />);
    if (!r || !r.name.trim()) return;
    try {
      if (supplier) await api.createSupplier({ name: r.name.trim(), ...(r.phone.trim() ? { phone: r.phone.trim() } : {}) });
      else await api.createLocation(r.name.trim());
      await onChanged();
    } catch (e) {
      showError(e);
    }
  };
  const list = (title: string, rows: Json[], supplier: boolean) => (
    <SectionCard title={title} actions={canManage && <TextButton label="Add" icon={Plus} testId={supplier ? 'add-supplier' : 'add-location'} onClick={() => add(supplier)} />}>
      {rows.length === 0 ? (
        <span className="muted">None yet.</span>
      ) : (
        rows.map((r) => (
          <div key={r.id} style={{ padding: '4px 0' }}>
            {[r.name, r.phone].filter((x) => x != null).join(' · ')}
          </div>
        ))
      )}
    </SectionCard>
  );
  return (
    <div className="stack">
      {list('Storage locations', locations, false)}
      {list('Suppliers', suppliers, true)}
    </div>
  );
}

function PlaceDialog({ supplier, close }: { supplier: boolean; close: (v?: { name: string; phone: string }) => void }) {
  const [name, setName] = useState('');
  const [phone, setPhone] = useState('');
  return (
    <Dialog
      title={supplier ? 'Add supplier' : 'Add storage location'}
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={() => close()} />
          <PrimaryButton label="Save" height={56} testId="save-place" onClick={() => close({ name, phone })} />
        </>
      }
    >
      <div className="col gap-12">
        <TextField label={supplier ? 'Supplier name' : 'Location, e.g. Walk-in cooler'} value={name} onChange={setName} autoFocus testId="place-name" />
        {supplier && <TextField label="Phone (optional)" type="tel" value={phone} onChange={setPhone} />}
      </div>
    </Dialog>
  );
}

function ValuationTab() {
  const { data: v } = useAsync(() => api.invValuation(), []);
  if (v == null) return <Skeleton h={160} />;
  return (
    <div className="col gap-16">
      <div className="grid-auto" style={{ '--min': '200px', gap: 12 } as CSSProperties}>
        <KpiCard testId="stock-value" label="Stock value" value={rupees(Number(v.totalPaise))} caption={`${v.method}`} icon={Package} />
        {(v.byCategory as Json[]).map((c, i) => (
          <KpiCard key={i} label={`${c.category}`} value={rupees(Number(c.valuePaise))} icon={Tags} />
        ))}
      </div>
      <p className="muted" style={{ margin: 0 }}>
        Stock is valued at the moving weighted-average cost of each product: every receipt with a cost updates the average; what leaves stock is valued at the average at that moment.
      </p>
    </div>
  );
}
