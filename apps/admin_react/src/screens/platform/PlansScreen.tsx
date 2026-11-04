import { useState, type CSSProperties } from 'react';
import { Archive, ArchiveRestore, Award, Check, Info, Pencil, Plus, Tag, MoreVertical } from 'lucide-react';
import { api, ApiException, type Json } from '../../api/client';
import { wholeRupees } from '../../lib/format';
import { featureGroups, featureLabel, limitKeys } from '../../lib/labels';
import { parseRupees, plainRupees } from '../../lib/money';
import { useSession } from '../../state/auth';
import { activePlans } from '../../state/app';
import { AsyncView } from '../../ui/async';
import { Chip, EmptyState, MenuButton, PageFrame, PrimaryButton, SecondaryButton, Segmented, StatusChip, TextField } from '../../ui/kit';
import { confirm, Dialog, openDialog, showDone, showError } from '../../ui/overlay';

/**
 * P8 Plans: what each plan costs and includes. Super Admins add plans, change prices and features, and archive
 * plans they no longer sell (licenses on an archived plan keep working until changed).
 */
export function PlansScreen() {
  const me = useSession();
  const edit = !!me?.can('platform.plan.manage');
  const [archived, setArchived] = useState(false);
  const [cycle, setCycle] = useState<'monthly' | 'yearly'>('monthly'); // which price the cards lead with
  const [n, setN] = useState(0);

  const editPlan = async (plan?: Json) => {
    const saved = await openDialog<string>((close) => <PlanEditor plan={plan} close={close} />);
    if (saved == null) return;
    activePlans.invalidate();
    setN((x) => x + 1);
    showDone(saved);
  };

  const archive = async (p: Json, value: boolean) => {
    const count = p.activeLicenses ?? 0;
    if (
      value &&
      !(await confirm({
        title: `Archive ${p.name}?`,
        message: count === 0 ? 'It will no longer be offered to new restaurants.' : `${count} restaurant(s) are on this plan. They keep it until you change their license; new restaurants cannot choose it.`,
        confirmLabel: 'Archive',
      }))
    )
      return;
    try {
      await api.updatePlan(p.id, { archived: value });
      activePlans.invalidate();
      setN((x) => x + 1);
      showDone(value ? `${p.name} archived` : `${p.name} is on sale again`);
    } catch (e) {
      showError(e);
    }
  };

  return (
    <AsyncView deps={[n, archived]} load={() => api.plans(archived)}>
      {(data) => {
        // "Show archived" lists only the archived plans; otherwise only the plans on sale
        const plans = data.filter((p) => (p.archived === true) === archived);
        // strict ordering: Standard (tier 1) → Professional (tier 2) → Premium (tier 3)
        plans.sort((a, b) => (a.tier ?? 999) - (b.tier ?? 999) || (a.pricePaise ?? 0) - (b.pricePaise ?? 0));
        return (
          <PageFrame
            title="Plans"
            subtitle="Standard, Professional, and Premium subscription plans. Customers can purchase monthly or yearly."
            actions={
              <>
                <Segmented<'monthly' | 'yearly'>
                  testId="plans-cycle"
                  value={cycle}
                  options={[
                    ['monthly', 'Monthly'],
                    ['yearly', 'Yearly'],
                  ]}
                  onChange={setCycle}
                />
                <Chip testId="plans-archived" label="Show archived" icon={archived ? Check : undefined} on={archived} onClick={() => setArchived(!archived)} />
                {edit && <PrimaryButton label="Add plan" icon={Plus} height={48} onClick={() => editPlan()} testId="add-plan" />}
              </>
            }
          >
            {plans.length === 0 ? (
              <EmptyState title={archived ? 'No archived plans' : 'No plans'} icon={Award} />
            ) : (
              // all plans side by side, cards in a row the same height
              <div className="grid-auto" style={{ '--min': '280px', alignItems: 'stretch' } as CSSProperties}>
                {plans.map((p, i) => (
                  <PlanCard key={p.id} plan={p} base={i > 0 ? plans[i - 1] : null} cycle={cycle} canEdit={edit} onEdit={() => editPlan(p)} onArchive={(v) => archive(p, v)} />
                ))}
              </div>
            )}
          </PageFrame>
        );
      }}
    </AsyncView>
  );
}

function PlanCard({ plan, base, cycle, canEdit, onEdit, onArchive }: { plan: Json; base: Json | null; cycle: string; canEdit: boolean; onEdit: () => void; onArchive: (v: boolean) => void }) {
  const archived = plan.archived === true;
  const all = (plan.featureFlags ?? []) as string[];
  const baseFeatures = new Set<string>((base?.featureFlags ?? []) as string[]);
  // each plan lists only what it adds to the plan below it, but only when it really contains all of it
  const inherits = base != null && baseFeatures.size > 0 && [...baseFeatures].every((f) => all.includes(f));
  const features = inherits ? all.filter((f) => !baseFeatures.has(f)) : all;
  const limits = (plan.limits ?? {}) as Json;
  const monthly = plan.pricePaise ?? 0;
  const yearly = plan.yearlyPricePaise ?? monthly * 10;
  const tier = plan.tier as number | undefined;
  const tierName = tier === 1 ? 'Bottom Tier' : tier === 2 ? 'Mid Tier' : tier === 3 ? 'Top Tier' : 'Custom Tier';
  return (
    <div className="card pad col" data-testid={`plan-${plan.code}`} style={{ opacity: archived ? 0.6 : 1, gap: 0 }}>
      <div className="row-top">
        <div className="grow">
          <div className="t-card ellipsis" style={{ fontSize: 24 }}>
            {`${plan.name}`}
          </div>
          <div className="wrap mt-4" style={{ gap: 8 }}>
            <span className="t-mono faint">{`${plan.code}`}</span>
            {tier != null && (
              <span className="t-mono muted pill-box" style={{ fontSize: 11, padding: '2px 6px' }}>
                {tierName} (Tier {tier})
              </span>
            )}
          </div>
        </div>
        {archived && <StatusChip label="Archived" tone="danger" />}
        {canEdit && (
          <MenuButton
            title="Plan actions"
            icon={MoreVertical}
            testId={`plan-menu-${plan.code}`}
            items={[
              { label: 'Edit price & features', icon: Pencil, onClick: onEdit },
              { label: archived ? 'Put back on sale' : 'Archive', icon: archived ? ArchiveRestore : Archive, onClick: () => onArchive(!archived) },
            ]}
          />
        )}
      </div>
      <div className="mt-12 t-display accent-text" style={{ fontSize: 28 }} data-testid={`plan-price-${plan.code}`}>
        {cycle === 'yearly' ? `${wholeRupees(yearly)} / year` : `${wholeRupees(monthly)} / month`}
      </div>
      <div className="muted t-label" style={{ fontSize: 13 }}>
        {cycle === 'yearly'
          ? `Works out to ${wholeRupees(Math.trunc(yearly / 12))} / month${monthly * 12 > yearly ? ` · saves ${wholeRupees(monthly * 12 - yearly)}` : ''}`
          : `or ${wholeRupees(yearly)} / year if paid yearly`}
      </div>
      <div className="muted mt-4">{plan.activeLicenses ?? 0} restaurant(s) on this plan</div>
      <div className="t-overline mt-16">Includes</div>
      <div className="mt-4">
        {inherits && (
          <div className="t-label" style={{ fontSize: 13, marginBottom: 4 }} data-testid={`plan-inherits-${plan.code}`}>
            Everything in {`${base!.name}`}
            {features.length === 0 ? '' : ', plus:'}
          </div>
        )}
        {features.map((f) => (
          <div key={f} className="row-top" style={{ padding: '1.5px 0', gap: 6 }}>
            <Check size={15} color="var(--success)" style={{ marginTop: 2, flex: 'none' }} aria-hidden />
            <span style={{ fontSize: 13 }}>{featureLabel(f)}</span>
          </div>
        ))}
      </div>
      <div className="t-overline mt-12">Limits</div>
      <div className="muted mt-4" style={{ fontSize: 12.5 }}>
        {limitKeys
          .filter(([k]) => k in limits)
          .map(([k, label]) => `${label}: ${limits[k] ?? 'Unlimited'}`)
          .join(' · ')}
      </div>
      {canEdit && (
        <div style={{ marginTop: 'auto', paddingTop: 16 }}>
          <SecondaryButton label="Edit" icon={Pencil} height={44} onClick={onEdit} />
        </div>
      )}
    </div>
  );
}

const discountPresets: [number, string][] = [
  [17, '17% (2 mo free)'],
  [20, '20% off'],
  [10, '10% off'],
  [0, 'No discount (12x)'],
];
const defaultFeatures = ['tables', 'orders.dinein', 'orders.takeaway', 'menu', 'billing', 'offline.single'];

/** Add / edit a plan: name, monthly and yearly price in rupees, tier, billing cycle, features and limits. */
function PlanEditor({ plan, close }: { plan?: Json; close: (v?: string) => void }) {
  const isNew = plan == null;
  const [name, setName] = useState<string>(plan?.name ?? '');
  const [code, setCode] = useState<string>(plan?.code ?? '');
  const [price, setPrice] = useState(plan ? plainRupees(plan.pricePaise) : '');
  const [yearlyPrice, setYearlyPrice] = useState(plan ? plainRupees(plan.yearlyPricePaise ?? plan.pricePaise * 10) : '');
  const [tier, setTier] = useState<number>(plan?.tier ?? (plan?.code === 'standard' ? 1 : plan?.code === 'professional' ? 2 : plan?.code === 'premium' ? 3 : 1));
  const [cycle, setCycle] = useState<string>(plan?.billingCycle ?? 'monthly');
  const [features, setFeatures] = useState<Set<string>>(new Set((plan?.featureFlags as string[] | undefined) ?? defaultFeatures));
  const [limits, setLimits] = useState<Record<string, string>>(() => {
    const src = (plan?.limits as Json | undefined) ?? { branches: 1 };
    return Object.fromEntries(limitKeys.map(([k]) => [k, src[k] == null ? '' : `${src[k]}`]));
  });
  const [preset, setPreset] = useState(17); // 17% ≈ 10 months / 2 months free
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const autoCode = (n: string) => {
    if (!isNew) return;
    const c = n.trim().toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '');
    setCode(c === '' || !/^[a-z]/.test(c) ? '' : c.length > 30 ? c.substring(0, 30) : c);
    if (c.includes('standard')) setTier(1);
    if (c.includes('prof')) setTier(2);
    if (c.includes('prem')) setTier(3);
  };

  // the suggested yearly figure is shown in whole rupees; what is saved goes through parseRupees (integer paise)
  const suggestYearly = (monthlyText: string, pct: number) => {
    const m = parseRupees(monthlyText);
    if (m == null || m <= 0) return;
    const yearlyPaise = pct === 17 ? m * 10 : Math.round((m * 12 * (100 - pct)) / 100);
    setYearlyPrice(`${Math.round(yearlyPaise / 100)}`);
  };

  const discount = (() => {
    const m = parseRupees(price), y = parseRupees(yearlyPrice);
    if (m == null || y == null || m <= 0 || y <= 0) return null;
    const full = m * 12;
    const savings = full - y;
    return { savings, pct: (savings / full) * 100, effMo: y / 12 };
  })();

  const save = async () => {
    const rupees = parseRupees(price), annual = parseRupees(yearlyPrice);
    if (annual == null || annual < 0) return setError('Enter the annual price');
    if (!name.trim()) return setError('Give the plan a name');
    if (rupees == null || rupees < 0) return setError('Enter the price in rupees, e.g. 999');
    if (isNew && !/^[a-z][a-z0-9_]{2,30}$/.test(code.trim())) return setError('Code: 3–31 lowercase letters, digits or _, starting with a letter');
    const lim: Record<string, number | null> = {};
    for (const [k, label] of limitKeys) {
      const t = limits[k].trim();
      if (t === '') lim[k] = null; // unlimited
      else if (!/^\d+$/.test(t)) return setError(`${label} must be a whole number (blank = unlimited)`);
      else lim[k] = parseInt(t, 10);
    }
    setBusy(true);
    setError(null);
    const body = { name: name.trim(), pricePaise: rupees, yearlyPricePaise: annual, tier, billingCycle: cycle, featureFlags: [...features], limits: lim };
    try {
      let updated = 0;
      if (isNew) await api.createPlan({ ...body, code: code.trim() });
      else updated = (await api.updatePlan(plan!.id, body)).licensesUpdated ?? 0;
      close(isNew ? `${body.name} added` : `${body.name} saved${updated > 0 ? ` — ${updated} restaurant${updated === 1 ? '' : 's'} on this plan updated now` : ''}`);
    } catch (e) {
      setError(e instanceof ApiException ? e.message : `${e}`);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Dialog
      title={isNew ? 'Add a plan' : `Edit ${plan!.name}`}
      size="wide"
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={busy ? null : () => close()} />
          <PrimaryButton label="Save" busy={busy} height={56} onClick={save} testId="save-plan" />
        </>
      }
    >
      <div className="col gap-12">
        <TextField label="Plan name" placeholder="e.g. Standard, Professional, Premium" value={name} onChange={(v) => (setName(v), autoCode(v))} onEnter={save} testId="plan-name" />
        {isNew && <TextField label="Code (cannot change later)" help="Used in licenses, e.g. standard" value={code} onChange={setCode} testId="plan-code" />}
        <div className="cols">
          <TextField
            label="Monthly amount (₹)"
            prefix="₹"
            inputMode="decimal"
            help="Per month before GST"
            value={price}
            onChange={(v) => {
              const clean = v.replace(/[^0-9.,]/g, '');
              setPrice(clean);
              suggestYearly(clean, preset < 0 ? 17 : preset);
              if (preset < 0) setPreset(17);
            }}
            testId="plan-price"
          />
          <TextField label="Annual amount (₹)" prefix="₹" inputMode="decimal" help="Full year total with discount" value={yearlyPrice} onChange={(v) => (setYearlyPrice(v.replace(/[^0-9.,]/g, '')), setPreset(-1))} testId="plan-yearly-price" />
        </div>
        <div className="wrap" style={{ gap: 6 }}>
          <span className="muted" style={{ fontSize: 12 }}>
            Yearly discount:
          </span>
          {discountPresets.map(([pct, label]) => (
            <Chip key={pct} small label={label} on={preset === pct} onClick={() => (setPreset(pct), suggestYearly(price, pct))} />
          ))}
        </div>
        {discount && (
          <div className={`callout ${discount.savings > 0 ? 'ok' : 'warn'}`} style={{ padding: '6px 10px' }}>
            {discount.savings > 0 ? <Tag size={16} color="var(--success)" aria-hidden /> : <Info size={16} className="muted" aria-hidden />}
            <span className="t-label" style={{ fontSize: 12, color: discount.savings > 0 ? 'var(--success)' : undefined }}>
              {discount.savings > 0
                ? `${discount.pct.toFixed(1)}% annual discount · Saves ₹${Math.round(discount.savings / 100)}/yr · Effective ₹${(discount.effMo / 100).toFixed(1)}/mo`
                : `Effective ₹${(discount.effMo / 100).toFixed(1)}/month`}
            </span>
          </div>
        )}
        <div>
          <Segmented<string>
            value={cycle}
            options={[
              ['monthly', 'Monthly'],
              ['yearly', 'Yearly'],
            ]}
            onChange={setCycle}
          />
        </div>
        <p className="muted" style={{ margin: '8px 0 0' }}>
          Feature changes apply to restaurants already on this plan. Restaurant users should sign in again to refresh their available actions.
        </p>
        {featureGroups.map(([group, items]) => (
          <div key={group}>
            <div className="t-overline">{group}</div>
            <div className="wrap mt-4" style={{ gap: 4 }}>
              {items.map(([k, label]) => (
                <Chip
                  key={k}
                  testId={`feature-${k}`}
                  label={label}
                  icon={features.has(k) ? Check : undefined}
                  on={features.has(k)}
                  onClick={() =>
                    setFeatures((s) => {
                      const next = new Set(s);
                      if (next.has(k)) next.delete(k);
                      else next.add(k);
                      return next;
                    })
                  }
                />
              ))}
            </div>
          </div>
        ))}
        <div className="t-overline">Limits · blank = unlimited</div>
        <div className="wrap">
          {limitKeys.map(([k, label]) => (
            <TextField key={k} label={label} dense inputMode="numeric" value={limits[k]} onChange={(v) => setLimits({ ...limits, [k]: v.replace(/\D/g, '') })} style={{ width: 180 }} />
          ))}
        </div>
        {error && (
          <span className="danger-text" data-testid="plan-error">
            {error}
          </span>
        )}
      </div>
    </Dialog>
  );
}
