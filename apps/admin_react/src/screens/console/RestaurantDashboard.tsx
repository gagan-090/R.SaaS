import { useState, type CSSProperties, type ReactNode } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  Armchair, BadgeCheck, BarChart3, Check, ChevronRight, CreditCard, Flame, HandCoins, Hourglass, IndianRupee, Lock, QrCode, ReceiptText, RefreshCw, Router, ShoppingBag, UtensilsCrossed, Wallet, type LucideIcon,
} from 'lucide-react';
import { api, type Json } from '../../api/client';
import { clock, hourLabel, rupees, shortDate } from '../../lib/format';
import { useSession } from '../../state/auth';
import { AsyncView } from '../../ui/async';
import { IconButton, KpiCard, PageFrame, Progress, SecondaryButton, SectionCard, Segmented, StatusChip } from '../../ui/kit';
import { Dialog, openDialog } from '../../ui/overlay';

const partOfDay = () => {
  const h = new Date().getHours();
  return h < 12 ? 'morning' : h < 17 ? 'afternoon' : 'evening';
};
const hubLabel = (hub: Json | null) => (hub == null ? 'No hub yet' : hub.online === true ? 'Hub online' : 'Hub offline');
const hubTone = (hub: Json | null) => (hub == null ? 'neutral' : hub.online === true ? 'success' : 'danger') as 'neutral' | 'success' | 'danger';

/**
 * O1 Restaurant dashboard: setup checklist, what is happening right now, sales for the chosen range against the
 * previous one, when and how guests pay, what sells, who sells, what was reversed, and every recent bill.
 */
export function RestaurantDashboardScreen() {
  const me = useSession();
  const canReports = !!me?.can('reports.read');
  const [range, setRange] = useState('today');
  const [n, setN] = useState(0);
  const rangeWord = range === 'today' ? 'today' : range === '30d' ? '30 days' : '7 days';
  const prevWord = range === 'today' ? 'yesterday' : range === '30d' ? 'previous 30 days' : 'previous 7 days';

  return (
    <AsyncView deps={[range, n]} load={async () => [await api.overview(), canReports ? await api.dashboard(range) : null] as const}>
      {([o, d]) => {
        const r = o.restaurant as Json;
        const lic = o.license as Json;
        return (
          <PageFrame
            title={`${r.name}`}
            subtitle={`Good ${partOfDay()} · ${lic.planName == null ? 'No active plan' : `${lic.planName} plan${lic.endsAt == null ? '' : ` until ${shortDate(lic.endsAt)}`}`}`}
            actions={
              <>
                <StatusChip label={hubLabel(o.hub)} tone={hubTone(o.hub)} icon={Router} />
                {canReports && (
                  <Segmented<string>
                    testId="range"
                    value={range}
                    options={[
                      ['today', 'Today'],
                      ['7d', '7 days'],
                      ['30d', '30 days'],
                    ]}
                    onChange={setRange}
                  />
                )}
                <IconButton title="Refresh" icon={RefreshCw} onClick={() => setN((x) => x + 1)} />
              </>
            }
          >
            <div className="stack">
              {lic.state === 'none' && (
                <div className="card notice pad-16 row gap-12" data-testid="dashboard-no-plan">
                  <Lock size={22} aria-hidden />
                  <div>
                    <div className="t-label">Your restaurant has no active plan</div>
                    <div className="muted">Menu, floors & tables, staff and the POS are locked until BhojMitra issues or renews your plan.</div>
                  </div>
                </div>
              )}
              <Checklist counts={o.counts} hub={o.hub ?? null} />
              {d && <Report d={d} rangeWord={rangeWord} prevWord={prevWord} range={range} />}
            </div>
          </PageFrame>
        );
      }}
    </AsyncView>
  );
}

const delta = (pct: unknown, prevWord: string, prevPaise: number) => {
  if (pct == null) return prevPaise === 0 ? `nothing ${prevWord} to compare` : '';
  const v = Number(pct);
  return `${v >= 0 ? '▲' : '▼'} ${Math.abs(v)}% vs ${prevWord} (${rupees(prevPaise)})`;
};
const deltaCount = (pct: unknown, prevWord: string) => {
  if (pct == null) return `vs ${prevWord}: —`;
  const v = Number(pct);
  return `${v >= 0 ? '▲' : '▼'} ${Math.abs(v)}% vs ${prevWord}`;
};

function Report({ d, rangeWord, prevWord, range }: { d: Json; rangeWord: string; prevWord: string; range: string }) {
  const k = d.kpis as Json;
  const change = d.change as Json;
  return (
    <>
      <LiveStrip live={d.live} />
      <div className="kpis">
        <KpiCard testId="kpi-sales" label={`Sales · ${rangeWord}`} value={rupees(k.salesPaise)} caption={delta(change.salesPct, prevWord, d.previous.salesPaise)} icon={IndianRupee} tone="saffron" />
        <KpiCard label="Bills" value={`${k.bills}`} caption={deltaCount(change.billsPct, prevWord)} icon={ReceiptText} />
        <KpiCard label="Average bill" value={rupees(k.avgBillPaise)} caption={`${k.orders} orders opened`} icon={BarChart3} tone="success" />
        <KpiCard label="Tips" value={rupees(k.tipsPaise)} caption={`GST collected ${rupees(k.taxesPaise)}`} icon={HandCoins} tone="pending" />
      </div>
      <div className="cols" style={{ '--cols': '3fr 2fr' } as CSSProperties}>
        <SectionCard
          title={range === 'today' ? 'Sales by hour · today' : `Sales by day · ${rangeWord}`}
          actions={d.busiestHour != null ? <StatusChip label={`Busiest ${hourLabel(d.busiestHour)}`} icon={Flame} tone="saffron" /> : undefined}
        >
          <Bars points={range === 'today' ? hourly(d.hourly) : daily(d.series)} />
        </SectionCard>
        <SectionCard title="How guests paid">
          <Modes byMode={d.byMode} />
        </SectionCard>
      </div>
      <div className="cols" style={{ '--cols': '1fr 1fr 1fr' } as CSSProperties}>
        <SectionCard title="Dine-in vs takeaway">
          <Split k={k} />
        </SectionCard>
        <SectionCard title="Sales by category">
          <Categories cats={d.byCategory} />
        </SectionCard>
        <SectionCard title="Discounts, reversals, corrections">
          <Leakage k={k} reasons={d.reversals?.reasons ?? []} />
        </SectionCard>
      </div>
      <div className="cols" style={{ '--cols': '3fr 2fr' } as CSSProperties}>
        <SectionCard title={`Top dishes · ${rangeWord}`}>
          <TopDishes items={d.topItems} />
        </SectionCard>
        <SectionCard title="Staff performance">
          <Staff rows={d.byWaiter} />
        </SectionCard>
      </div>
      <SectionCard title="Recent bills">
        <RecentBills bills={d.recentBills} />
      </SectionCard>
    </>
  );
}

/** What is happening in the restaurant right now (from the hub's latest sync). */
function LiveStrip({ live }: { live: Json }) {
  const fact = (Icon: LucideIcon, value: string, label: string, color: string) => (
    <span className="row" style={{ padding: '8px 12px', gap: 8 }}>
      <Icon size={22} color={color} aria-hidden />
      <span className="t-card" style={{ fontSize: 22 }}>
        {value}
      </span>
      <span className="muted ellipsis">{label}</span>
    </span>
  );
  return (
    <div className="card wrap" data-testid="live-strip" style={{ padding: 8, gap: 0 }}>
      <span className="row" style={{ padding: '0 12px', gap: 6 }}>
        <span style={{ width: 8, height: 8, borderRadius: '50%', background: 'var(--success)' }} />
        <span className="t-overline">Right now</span>
      </span>
      {fact(Armchair, `${live.openTables}`, 'tables seated', 'var(--highlight)')}
      {fact(ShoppingBag, `${live.takeaways}`, 'takeaways open', 'var(--pending)')}
      {fact(Hourglass, `${live.unpaidBills}`, `bills unpaid · ${rupees(live.unpaidPaise)}`, 'var(--danger)')}
    </div>
  );
}

type Point = { label: string; value: number; tip: string; highlight: boolean };
const weekdays = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
function daily(days: Json[]): Point[] {
  const many = days.length > 10;
  return days.map((d, i) => {
    const dt = new Date(`${d.day}T00:00:00`);
    return {
      label: many ? (i % 5 === 0 || i === days.length - 1 ? `${isNaN(dt.getTime()) ? '' : dt.getDate()}` : '') : isNaN(dt.getTime()) ? '' : weekdays[dt.getDay()],
      value: d.salesPaise,
      tip: `${d.day}: ${rupees(d.salesPaise)} · ${d.bills} bills`,
      highlight: i === days.length - 1,
    };
  });
}
function hourly(hours: Json[]): Point[] {
  // show the service day (8 AM – midnight) plus any hour that actually had sales
  const now = new Date().getHours();
  return hours
    .filter((h) => h.hour >= 8 || h.salesPaise > 0)
    .map((h) => ({ label: h.hour % 3 === 0 ? hourLabel(h.hour).replace(' ', '') : '', value: h.salesPaise, tip: `${hourLabel(h.hour)}: ${rupees(h.salesPaise)} · ${h.bills} bills`, highlight: h.hour === now }));
}

function Bars({ points }: { points: Point[] }) {
  const max = points.reduce((m, x) => Math.max(m, x.value), 0);
  if (max === 0) return <div className="center muted" style={{ height: 190 }}>No paid bills in this period yet</div>;
  return (
    <div className="bar-chart" role="img" aria-label="Sales chart">
      {points.map((x, i) => (
        <div key={i} className="bar-col" title={x.tip} style={{ padding: `0 ${points.length > 14 ? 1.5 : 4}px` }}>
          {x.value > 0 && points.length <= 10 && (
            <span className="muted" style={{ fontSize: 11, whiteSpace: 'nowrap' }}>
              {rupees(x.value)}
            </span>
          )}
          <div style={{ height: 4 }} />
          <div
            className="bar"
            style={{
              height: 3 + 140 * (x.value / max),
              background: x.highlight ? 'var(--highlight)' : `color-mix(in srgb, var(--accent) ${x.value === 0 ? 15 : 55}%, transparent)`,
            }}
          />
          <span className="bar-label" style={{ color: x.highlight ? 'var(--text)' : undefined }}>
            {x.label}
          </span>
        </div>
      ))}
    </div>
  );
}

function Modes({ byMode }: { byMode: Json }) {
  const total = Object.values(byMode).reduce((s: number, v) => s + Number(v), 0);
  if (total === 0) return <span className="muted">No payments in this period yet.</span>;
  const colors: Record<string, string> = { cash: 'var(--success)', upi: 'var(--highlight)', card: 'var(--pending)' };
  const icons: Record<string, LucideIcon> = { cash: Wallet, upi: QrCode, card: CreditCard };
  const entries = Object.entries(byMode).sort((a, b) => Number(b[1]) - Number(a[1]));
  return (
    <div>
      <div className="stack-bar">
        {entries.map(([m, v]) => (
          <div key={m} style={{ flex: Math.max(1, Math.trunc((Number(v) * 1000) / total)), background: colors[m] ?? 'var(--muted)' }} />
        ))}
      </div>
      <div className="mt-16">
        {entries.map(([m, v]) => {
          const Icon = icons[m] ?? Wallet;
          return (
            <div key={m} className="row" style={{ padding: '6px 0' }}>
              <Icon size={18} color={colors[m] ?? 'var(--muted)'} aria-hidden />
              <span className="t-label grow">{m.toUpperCase()}</span>
              <span className="muted">{Math.round((Number(v) * 100) / total)}%</span>
              <span className="t-label" style={{ width: 84, textAlign: 'right' }}>
                {rupees(Number(v))}
              </span>
            </div>
          );
        })}
      </div>
      <hr className="divider" style={{ margin: '8px 0' }} />
      <div className="row">
        <span className="muted grow">Total collected</span>
        <span className="t-label">{rupees(total)}</span>
      </div>
    </div>
  );
}

function Split({ k }: { k: Json }) {
  const dine = k.dineInPaise as number, take = k.takeawayPaise as number;
  const line = (Icon: LucideIcon, label: string, paise: number, bills: number, c: string) => (
    <div className="row" style={{ padding: '6px 0' }}>
      <Icon size={20} color={c} aria-hidden />
      <span className="t-label grow">{label}</span>
      <span className="muted">{bills} bills</span>
      <span className="t-label" style={{ marginLeft: 12 }}>
        {rupees(paise)}
      </span>
    </div>
  );
  return (
    <div>
      {dine + take > 0 && (
        <div className="stack-bar">
          {dine > 0 && <div style={{ flex: dine, background: 'var(--highlight)' }} />}
          {take > 0 && <div style={{ flex: take, background: 'var(--pending)' }} />}
        </div>
      )}
      <div className="mt-12">
        {line(Armchair, 'Dine-in', dine, k.dineInBills, 'var(--highlight)')}
        {line(ShoppingBag, 'Takeaway', take, k.takeawayBills, 'var(--pending)')}
      </div>
    </div>
  );
}

function Categories({ cats }: { cats: Json[] }) {
  if (cats.length === 0) return <span className="muted">No dishes sold in this period yet.</span>;
  const max = cats.reduce((m, c) => Math.max(m, c.amountPaise), 0);
  return (
    <div>
      {cats.slice(0, 6).map((c, i) => (
        <div key={i} style={{ padding: '5px 0' }}>
          <div className="row">
            <span className="t-label ellipsis grow">{`${c.name}`}</span>
            <span className="muted">
              {c.qty} · {rupees(c.amountPaise)}
            </span>
          </div>
          <div className="progress mt-4">
            <div style={{ width: `${max === 0 ? 0 : (c.amountPaise / max) * 100}%`, background: 'var(--highlight)' }} />
          </div>
        </div>
      ))}
    </div>
  );
}

function Leakage({ k, reasons }: { k: Json; reasons: Json[] }) {
  const rev = k.reversals as Json, adj = k.adjustments as Json;
  const line = (label: string, value: string, sub: string, c: string) => (
    <div className="row" style={{ padding: '5px 0' }}>
      <span style={{ width: 8, height: 8, borderRadius: '50%', background: c, flex: 'none' }} />
      <span className="t-label grow">{label}</span>
      <span className="col" style={{ alignItems: 'flex-end', gap: 0 }}>
        <span className="t-label">{value}</span>
        <span className="muted" style={{ fontSize: 12 }}>
          {sub}
        </span>
      </span>
    </div>
  );
  return (
    <div>
      {line('Discounts given', rupees(k.discountsPaise), 'on paid bills', 'var(--highlight)')}
      {line('Items reversed', rupees(rev.amountPaise), `${rev.count} lines`, 'var(--danger)')}
      {line('Bill corrections', rupees(adj.amountPaise), `${adj.count} adjustments`, 'var(--pending)')}
      {reasons.length > 0 && (
        <>
          <div className="t-overline mt-8" style={{ fontSize: 10 }}>
            Top reversal reasons
          </div>
          {reasons.slice(0, 3).map((r, i) => (
            <div key={i} className="ellipsis">
              {r.count}× {`${r.reason}`}
            </div>
          ))}
        </>
      )}
    </div>
  );
}

function TopDishes({ items }: { items: Json[] }) {
  if (items.length === 0) return <span className="muted">Dishes appear here once bills sync from the hub.</span>;
  const total = items.reduce((s, i) => s + i.amountPaise, 0);
  return (
    <div>
      {items.map((it, i) => (
        <div key={i} className="row" style={{ padding: '4px 0' }}>
          <span className="t-card faint" style={{ width: 28, fontSize: 16 }}>
            {i + 1}
          </span>
          <span className="col grow" style={{ gap: 0 }}>
            <span className="t-label ellipsis">{`${it.name}`}</span>
            <span className="muted" style={{ fontSize: 12 }}>
              {`${it.category ?? ''}`}
            </span>
          </span>
          <span className="muted">{it.qty} sold</span>
          <span className="faint" style={{ width: 48, textAlign: 'right' }}>
            {total === 0 ? '' : `${Math.round((it.amountPaise * 100) / total)}%`}
          </span>
          <span className="t-label" style={{ width: 90, textAlign: 'right' }}>
            {rupees(it.amountPaise)}
          </span>
        </div>
      ))}
    </div>
  );
}

function Staff({ rows }: { rows: Json[] }) {
  if (rows.length === 0) return <span className="muted">Sales per waiter show here once bills are paid.</span>;
  const h = (s: string, w?: number) => (
    <span className="t-overline" style={{ fontSize: 10, width: w, textAlign: w ? 'right' : undefined, flex: w ? 'none' : 1 }}>
      {s}
    </span>
  );
  return (
    <div>
      <div className="row">
        {h('Waiter')}
        {h('Bills', 48)}
        {h('Sales', 84)}
        {h('Tips', 64)}
      </div>
      <hr className="divider" style={{ margin: '8px 0' }} />
      {rows.map((r, i) => (
        <div key={i} className="row" style={{ padding: '6px 0' }}>
          <span className="avatar" style={{ width: 28, height: 28, fontSize: 12, background: 'color-mix(in srgb, var(--success) 18%, transparent)', color: 'var(--text)' }}>
            {`${r.name}`[0]}
          </span>
          <span className="t-label ellipsis grow">{`${r.name}`}</span>
          <span style={{ width: 48, textAlign: 'right' }}>{r.bills}</span>
          <span className="t-label" style={{ width: 84, textAlign: 'right' }}>
            {rupees(r.salesPaise)}
          </span>
          <span className="accent-text" style={{ width: 64, textAlign: 'right' }}>
            {rupees(r.tipsPaise)}
          </span>
        </div>
      ))}
    </div>
  );
}

function RecentBills({ bills }: { bills: Json[] }) {
  if (bills.length === 0) return <span className="muted">Bills appear here as the hub syncs them.</span>;
  return (
    <div>
      {bills.map((b) => (
        <div
          key={b.id}
          className="list-row click"
          style={{ padding: '8px 4px' }}
          data-testid={`recent-${b.invoiceNo}`}
          role="button"
          tabIndex={0}
          onClick={() => openDialog((close) => <BillDetail id={`${b.id}`} close={close} />)}
          onKeyDown={(e) => e.key === 'Enter' && openDialog((close) => <BillDetail id={`${b.id}`} close={close} />)}
        >
          <span className="col grow" style={{ gap: 0 }}>
            <span className="t-mono">{`${b.invoiceNo}`}</span>
            <span className="muted ellipsis" style={{ fontSize: 12 }}>
              {[b.where, b.waiter, clock(b.closedAt ?? b.createdAt)].filter((x) => x != null).join(' · ')}
            </span>
          </span>
          <StatusChip label={b.status === 'paid' ? 'Paid' : 'Open'} tone={b.status === 'paid' ? 'success' : 'saffron'} />
          <span className="t-label" style={{ width: 90, textAlign: 'right' }}>
            {rupees(b.totalPaise)}
          </span>
          <ChevronRight size={20} className="faint" aria-hidden />
        </div>
      ))}
    </div>
  );
}

/** Bill drill-down: lines (incl. reversed with reason), totals, payments, tip and corrections. */
function BillDetail({ id, close }: { id: string; close: () => void }) {
  return (
    <Dialog title="Bill" actions={<SecondaryButton label="Close" height={44} onClick={close} />}>
      <AsyncView deps={[id]} load={() => api.billDetail(id)}>
        {(b) => {
          const t = b.totals as Json;
          const money = (label: ReactNode, v: unknown, strong = false) => (
            <div className="row" style={{ padding: '2px 0' }}>
              <span className={`grow ellipsis${strong ? ' t-label' : ' muted'}`}>{label}</span>
              <span className={strong ? 't-card' : 't-mono muted'}>{rupees(Math.trunc(Number(v ?? 0)))}</span>
            </div>
          );
          return (
            <div>
              <div className="row">
                <span className="t-card grow">{`${b.invoiceNo}`}</span>
                <StatusChip label={b.status === 'paid' ? 'Paid' : 'Open'} tone={b.status === 'paid' ? 'success' : 'saffron'} />
              </div>
              <div className="muted">{[b.where, b.waiter != null ? `Waiter ${b.waiter}` : null, clock(b.closedAt ?? b.createdAt)].filter((x) => x != null).join(' · ')}</div>
              <div className="mt-16">
                {(b.lines as Json[]).map((l, i) => {
                  const rev = l.status === 'reversed';
                  return (
                    <div key={i} className="row-top" style={{ padding: '3px 0' }}>
                      <span className="t-mono muted" style={{ width: 30 }}>
                        {l.qty}×
                      </span>
                      <span className="col grow" style={{ gap: 0 }}>
                        <span className={rev ? 'faint strike' : ''}>{`${l.name}`}</span>
                        {rev && <span className="danger-text" style={{ fontSize: 12 }}>Reversed: {`${l.reversalReason ?? ''}`}</span>}
                        {l.notes != null && <span className="note" style={{ fontSize: 13 }}>{`${l.notes}`}</span>}
                      </span>
                      <span className={`t-mono${rev ? ' faint' : ''}`}>{rupees(Math.trunc(Number(l.amountPaise)))}</span>
                    </div>
                  );
                })}
              </div>
              <hr className="divider" style={{ margin: '8px 0' }} />
              {money('Subtotal', t.subtotalPaise)}
              {Number(t.discountPaise ?? 0) !== 0 && money('Discount', -Number(t.discountPaise))}
              {money('CGST', t.cgstPaise)}
              {money('SGST', t.sgstPaise)}
              {Number(t.tipPaise ?? 0) !== 0 && money('Tip', t.tipPaise)}
              {Number(t.roundOffPaise ?? 0) !== 0 && money('Round-off', t.roundOffPaise)}
              <hr className="divider" style={{ margin: '8px 0' }} />
              {money('Total', t.totalPaise, true)}
              {(b.payments as Json[]).length > 0 && (
                <>
                  <div className="t-overline mt-16">Payments</div>
                  {(b.payments as Json[]).map((p, i) => (
                    <div key={i}>{money(`${`${p.mode}`.toUpperCase()}${Number(p.changePaise ?? 0) > 0 ? ` · change ${rupees(Number(p.changePaise))}` : ''}`, p.amountPaise)}</div>
                  ))}
                </>
              )}
              {(b.tips as Json[]).map((tip, i) => (
                <div key={`t${i}`}>{money(`Tip to ${tip.waiter ?? '—'}`, tip.amountPaise)}</div>
              ))}
              {(b.adjustments as Json[]).length > 0 && (
                <>
                  <div className="t-overline mt-16">Corrections</div>
                  {(b.adjustments as Json[]).map((a, i) => (
                    <div key={i}>{money(`${a.reason}`, a.amountPaise)}</div>
                  ))}
                </>
              )}
            </div>
          );
        }}
      </AsyncView>
    </Dialog>
  );
}

/** "Get ready for service" checklist: what is missing before the first service, each step one click away. */
function Checklist({ counts, hub }: { counts: Json; hub: Json | null }) {
  const navigate = useNavigate();
  const steps: [string, string, boolean, string, LucideIcon][] = [
    ['Add your menu', `${counts.items} dishes in ${counts.categories} categories`, counts.items > 0, '/console/menu', UtensilsCrossed],
    ['Set up floors & tables', `${counts.tables} tables`, counts.tables > 0, '/console/tables', Armchair],
    ['Add your team', `${counts.staff} people with a PIN`, counts.staff > 1, '/console/staff', BadgeCheck],
    ['Connect the hub', hub == null ? 'Install the POS on the cashier device' : hub.online === true ? 'Online' : 'Registered, not seen recently', hub != null, '/console/devices', Router],
  ];
  const done = steps.filter((s) => s[2]).length;
  if (done === steps.length) return null;
  return (
    <SectionCard title={`Get ready for service · ${done} of ${steps.length}`}>
      <Progress value={done / steps.length} />
      <div className="mt-12">
        {steps.map(([title, sub, ok, to, Icon]) => (
          <div key={title} className="list-row click" style={{ padding: '8px 0' }} role="link" tabIndex={0} onClick={() => navigate(to)} onKeyDown={(e) => e.key === 'Enter' && navigate(to)}>
            <span className="icon-circle" style={ok ? { background: 'color-mix(in srgb, var(--success) 16%, transparent)', color: 'var(--success)' } : undefined}>
              {ok ? <Check size={18} aria-hidden /> : <Icon size={18} aria-hidden />}
            </span>
            <span className="col grow" style={{ gap: 0 }}>
              <span className={`t-label${ok ? ' muted strike' : ''}`}>{title}</span>
              <span className="muted">{sub}</span>
            </span>
            {!ok && <ChevronRight size={20} aria-hidden />}
          </div>
        ))}
      </div>
    </SectionCard>
  );
}
