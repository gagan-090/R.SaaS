import { useEffect, useState, type CSSProperties } from 'react';
import { useNavigate } from 'react-router-dom';
import { ChevronRight, Package, Percent, RefreshCw, Wallet, CreditCard } from 'lucide-react';
import { api, errorText, type Json } from '../../api/client';
import { rupees, todayIso } from '../../lib/format';
import { useSession } from '../../state/auth';
import { restaurantNav } from '../../shell/nav';
import { Chip, EmptyState, IconButton, KpiCard, PageFrame, SectionCard, Skeleton, TextButton } from '../../ui/kit';
import { FloorEditor } from './FloorEditor';
import { RestaurantDashboardScreen } from './RestaurantDashboard';
import { roleInfo } from './roles';

/**
 * Restaurant console home. People who read business reports (owner, restaurant admin, auditor) get the business
 * dashboard. Everyone else gets panels for exactly what their role — or custom role — allows: kitchen orders & stock
 * (chef), today's bills & payments (cashier), live tables & orders (waiter). Taking orders and payments stays on the POS.
 */
export function ConsoleHome() {
  const a = useSession();
  const navigate = useNavigate();
  if (!a) return null;
  if (a.can('reports.read') && a.can('restaurant.profile.read')) return <RestaurantDashboardScreen />;
  const role = (a.me.customRoleName as string | undefined) ?? roleInfo[a.roles[0] ?? '']?.[0] ?? 'Team member';
  const items = restaurantNav.filter((n) => n.path !== '/console' && n.permission != null && a.can(n.permission));
  return (
    <PageFrame title={`Hello, ${`${a.me.name ?? ''}`.split(' ')[0]}`} subtitle={role}>
      <div className="stack">
        {(a.can('order.write') || a.can('payment.take')) && (
          <p className="muted" data-testid="pos-note" style={{ margin: 0 }}>
            Take orders and payments on the POS app (it keeps working when the internet is down). This page shows what is happening.
          </p>
        )}
        {a.can('order.read') && (a.can('kds.read') || a.can('order.write')) && <LiveOrders kitchen={a.can('kds.update') && !a.can('order.write')} />}
        {a.can('payment.take') && a.can('order.read') && <TodaySales />}
        {a.can('inventory.read') && <StockPanel canConsume={a.can('inventory.consume')} canRequest={a.can('inventory.request')} />}
        {a.can('floor.read') && a.can('order.read') && !a.can('kds.update') && <LiveFloor canSetStatus={a.can('order.write')} />}
        {items.length === 0 ? (
          <EmptyState title="Your work is on the POS" message="Your role uses the POS app. Ask the owner if you need more here." />
        ) : (
          <div className="grid-auto" style={{ '--min': '240px' } as CSSProperties}>
            {items.map((n) => (
              <div key={n.path} className="card clickable row" style={{ padding: 16, gap: 12 }} data-testid={`home-${n.label}`} role="link" tabIndex={0} onClick={() => navigate(n.path)} onKeyDown={(e) => e.key === 'Enter' && navigate(n.path)}>
                <n.icon size={22} className="accent-text" aria-hidden />
                <span className="t-label grow">{n.label}</span>
                <ChevronRight size={20} className="muted" aria-hidden />
              </div>
            ))}
          </div>
        )}
      </div>
    </PageFrame>
  );
}

/** Open orders with their lines and kitchen status (from what the hub synced, a few seconds behind the POS). */
function LiveOrders({ kitchen }: { kitchen: boolean }) {
  const [orders, setOrders] = useState<Json[] | null>(null);
  const [error, setError] = useState<unknown>(null);
  const load = () =>
    api.liveOrders().then(
      (r) => (setOrders(r), setError(null)),
      (e) => setError(e),
    );
  useEffect(() => void load(), []);
  return (
    <SectionCard title={kitchen ? 'Kitchen orders' : 'Open orders'} actions={<IconButton title="Refresh" icon={RefreshCw} onClick={load} />}>
      {error != null ? (
        <span className="danger-text">{errorText(error)}</span>
      ) : orders == null ? (
        <Skeleton h={80} />
      ) : orders.length === 0 ? (
        <span className="muted" data-testid="no-orders">
          No open orders right now.
        </span>
      ) : (
        <div className="grid-auto" style={{ '--min': '240px', gap: 12 } as CSSProperties}>
          {orders.map((o) => (
            <div key={o.id} className="card raised pad-12" data-testid={`live-${o.id}`}>
              <div className="t-label">{o.table != null ? `Table ${o.table}` : 'Takeaway'}</div>
              <div className="muted" style={{ fontSize: 12 }}>
                {[o.waiter != null ? `${o.waiter}` : null, o.status === 'billed' ? 'bill printed' : null, ...((o.kitchen as Json[]) ?? []).map((k) => `KOT ${k.kotNo} ${k.status}`)].filter(Boolean).join(' · ')}
              </div>
              <div className="mt-4">
                {(o.lines as Json[])
                  .filter((l) => l.status !== 'reversed')
                  .map((l, i) => (
                    <div key={i}>{`${l.qty} × ${l.name}${l.status === 'pending' ? ' (not sent)' : ''}${l.notes != null ? ` — ${l.notes}` : ''}`}</div>
                  ))}
              </div>
            </div>
          ))}
        </div>
      )}
    </SectionCard>
  );
}

function TodaySales() {
  const [s, setS] = useState<Json | null>(null);
  useEffect(() => {
    api.salesRecords({ from: todayIso() }).then(setS, () => undefined);
  }, []);
  const sum = s?.summary as Json | undefined;
  return (
    <SectionCard title="Today's bills & payments">
      {!sum ? (
        <Skeleton h={80} />
      ) : (
        <div className="grid-auto" style={{ '--min': '160px', gap: 12 } as CSSProperties}>
          <KpiCard testId="today-sales" label="Collected" value={rupees(sum.salesPaise)} caption={`${sum.paidBills} paid bills`} icon={Wallet} />
          {Object.entries(sum.paymentsByMode as Json).map(([m, v]) => (
            <KpiCard key={m} label={m.toUpperCase()} value={rupees(Number(v))} icon={CreditCard} />
          ))}
          <KpiCard label="Discounts" value={rupees(sum.discountsPaise)} icon={Percent} />
        </div>
      )}
    </SectionCard>
  );
}

function StockPanel({ canConsume, canRequest }: { canConsume: boolean; canRequest: boolean }) {
  const navigate = useNavigate();
  const [alerts, setAlerts] = useState<Json | null>(null);
  useEffect(() => {
    api.invAlerts().then(setAlerts, () => undefined);
  }, []);
  const low = (alerts?.low ?? []) as Json[], exp = (alerts?.expiring ?? []) as Json[];
  return (
    <SectionCard
      title="Stock"
      actions={(canConsume || canRequest) && <TextButton label={canConsume ? 'Record use / wastage' : 'Open inventory'} icon={Package} testId="go-inventory" onClick={() => navigate('/console/inventory')} />}
    >
      {alerts == null ? (
        <Skeleton h={60} />
      ) : low.length === 0 && exp.length === 0 ? (
        <span className="muted">Nothing low or about to expire.</span>
      ) : (
        <div>
          {low.map((x) => (
            <div key={`l${x.sku}`} data-testid={`home-low-${x.sku}`}>
              Low: {`${x.name}`} ({`${x.stock}`} {`${x.unit}`})
            </div>
          ))}
          {exp.map((x, i) => (
            <div key={`e${i}`} className="danger-text">
              Expiring {`${x.expiryDate}`}: {`${x.name}`}
            </div>
          ))}
        </div>
      )}
    </SectionCard>
  );
}

/** The live floor for waiters: the owner's layout coloured by table state. */
function LiveFloor({ canSetStatus }: { canSetStatus: boolean }) {
  const [floors, setFloors] = useState<Json[] | null>(null);
  const [floor, setFloor] = useState<string | null>(null);
  useEffect(() => {
    api.floors().then(
      (f) => (setFloors(f), setFloor(f[0]?.id ?? null)),
      () => undefined,
    );
  }, []);
  if (floors == null) return <Skeleton h={120} />;
  if (floor == null) return null;
  return (
    <SectionCard title="Tables">
      {floors.length > 1 && (
        <div className="wrap" style={{ marginBottom: 12 }}>
          {floors.map((f) => (
            <Chip key={f.id} label={`${f.name}`} on={f.id === floor} onClick={() => setFloor(f.id)} />
          ))}
        </div>
      )}
      <FloorEditor key={`home-floor-${floor}`} floorId={floor} canEdit={false} canSetStatus={canSetStatus} editorInPlan={false} />
    </SectionCard>
  );
}
