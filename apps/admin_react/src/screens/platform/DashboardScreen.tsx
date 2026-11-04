import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Archive, Ban, BellRing, ChevronRight, Clock, IndianRupee, MailWarning, PauseCircle, RefreshCw, Store, BadgeIndianRupee, type LucideIcon } from 'lucide-react';
import { api, type Json } from '../../api/client';
import { shortDate, wholeRupees } from '../../lib/format';
import { auditActionLabel, auditActor, type Tone } from '../../lib/labels';
import { AsyncView } from '../../ui/async';
import { Chip, IconButton, PageFrame, SectionCard, TextButton } from '../../ui/kit';

const activityCats: [string | null, string][] = [
  [null, 'All'],
  ['account_lifecycle', 'Account Lifecycle'],
  ['auth_success', 'Auth Success'],
  ['auth_failure', 'Auth Failures'],
  ['restaurant_lifecycle', 'Restaurant Lifecycle'],
];

/**
 * P3 Super Admin dashboard: the platform at a glance (status counts, revenue), what needs attention today
 * (payment overdue / coming due, suspended > 3m, archived > 1y, awaiting verification), and categorised activity.
 */
export function DashboardScreen() {
  const [cat, setCat] = useState<string | null>(null);
  const navigate = useNavigate();
  const load = async () => {
    const [active, suspended, blocked, attention, audit, regs, plans] = await Promise.all([
      api.restaurants({ status: 'active' }),
      api.restaurants({ status: 'suspended' }),
      api.restaurants({ status: 'blocked' }),
      api.attention(),
      api.audit({ category: cat }),
      api.registrations(),
      api.plans(),
    ]);
    return { active: active.total, suspended: suspended.total, blocked: blocked.total, attention, audit: audit.items as Json[], awaiting: regs.counts?.awaiting, awaitingItems: regs.items as Json[], plans };
  };

  return (
    <AsyncView deps={[cat]} load={load}>
      {(d, reload) => {
        // monthly recurring revenue from the plans restaurants are on right now (yearly plans count 1/12 per month)
        const mrr = d.plans.reduce((s, x) => s + Math.trunc((x.pricePaise * (x.activeLicenses ?? 0)) / (x.billingCycle === 'yearly' ? 12 : 1)), 0);
        const att = d.attention as Json;
        const overdue = (att.overdueLicenses ?? []) as Json[];
        const upcoming = (att.upcomingLicenses ?? []) as Json[];
        const suspended3m = (att.suspendedTenants ?? []) as Json[];
        const archived1y = (att.archivedTenants ?? []) as Json[];
        const awaiting = d.awaitingItems;
        const hasAttention = overdue.length + upcoming.length + suspended3m.length + archived1y.length + awaiting.length > 0;
        const go = (p: string) => navigate(p);

        const kpis: [string, unknown, Tone, LucideIcon, string][] = [
          ['Awaiting verification', d.awaiting, 'pending', MailWarning, '/restaurants?status=pending'],
          ['Active', d.active, 'success', Store, '/restaurants?status=active'],
          ['Suspended', d.suspended, 'saffron', PauseCircle, '/restaurants?status=suspended'],
          ['Blocked', d.blocked, 'danger', Ban, '/restaurants?status=blocked'],
          ['Attention needed', overdue.length + upcoming.length + suspended3m.length + archived1y.length, overdue.length || suspended3m.length ? 'danger' : 'pending', BellRing, '/restaurants'],
          ['Monthly revenue', wholeRupees(mrr), 'success', IndianRupee, '/plans'],
        ];

        const attention = (
          <SectionCard title="Needs your attention">
            {!hasAttention && <p className="muted" style={{ margin: '8px 0' }}>All clear — no licenses overdue or expiring, and no restaurants requiring lifecycle review.</p>}
            {overdue.slice(0, 3).map((r) => (
              <AttentionRow key={`o${r.id}`} icon={BadgeIndianRupee} tone="danger" title={`${r.name} (${r.code})`} subtitle={`License overdue by ${r.daysOverdue} days · Plan: ${r.plan}`} onClick={() => go(`/restaurants/${r.id}`)} />
            ))}
            {upcoming.slice(0, 3).map((r) => (
              <AttentionRow key={`u${r.id}`} icon={Clock} tone="saffron" title={`${r.name} (${r.code})`} subtitle={`Payment / license renewal in ${r.daysLeft} days · Plan: ${r.plan}`} onClick={() => go(`/restaurants/${r.id}`)} />
            ))}
            {suspended3m.slice(0, 3).map((r) => (
              <AttentionRow key={`s${r.id}`} icon={PauseCircle} tone="danger" title={`${r.name} (${r.code})`} subtitle={`Suspended > 3 months (${r.daysSuspended}d) · ${r.reason ?? 'No reason recorded'}`} onClick={() => go(`/restaurants/${r.id}`)} />
            ))}
            {archived1y.slice(0, 3).map((r) => (
              <AttentionRow key={`a${r.id}`} icon={Archive} tone="pending" title={`${r.name} (${r.code})`} subtitle={`Archived > 1 year (${r.daysArchived}d) · Eligible for housekeeping removal`} onClick={() => go(`/restaurants/${r.id}`)} />
            ))}
            {awaiting.slice(0, 3).map((r) => (
              <AttentionRow key={`w${r.id}`} icon={MailWarning} tone="pending" title={`${r.restaurantName}`} subtitle={`Owner has not activated yet · ${r.ownerEmail}`} onClick={() => go('/restaurants?status=pending')} />
            ))}
          </SectionCard>
        );

        const planMix = (
          <SectionCard title="Restaurants by plan" actions={<TextButton label="Plans" onClick={() => go('/plans')} />}>
            {d.plans.map((pl) => (
              <div key={pl.id} className="row" style={{ padding: '6px 0' }}>
                <span className="t-label ellipsis grow">{pl.name}</span>
                <span className="t-card">{pl.activeLicenses ?? 0}</span>
                <span className="muted" style={{ width: 120, textAlign: 'right', fontSize: 12 }}>
                  {wholeRupees(pl.pricePaise)}/mo · {wholeRupees(pl.yearlyPricePaise ?? pl.pricePaise * 10)}/yr
                </span>
              </div>
            ))}
          </SectionCard>
        );

        const activity = (
          <SectionCard
            title="Recent activity"
            actions={
              <>
                <span className="pill-box muted" style={{ fontSize: 11 }} title="Audit events are kept for 1.5 years">
                  Kept 1.5 yrs
                </span>
                <TextButton label="Audit log" onClick={() => go('/audit')} />
              </>
            }
          >
            <div className="wrap" style={{ gap: 6 }}>
              {activityCats.map(([c, l]) => (
                <Chip key={l} small label={l} on={cat === c} onClick={() => setCat(c)} />
              ))}
            </div>
            <div className="mt-8">
              {d.audit.length === 0 ? (
                <p className="muted" style={{ margin: '12px 0' }}>No activity recorded in this category yet.</p>
              ) : (
                d.audit.slice(0, 8).map((e, i) => (
                  <div key={i} className="row" style={{ padding: '6px 0' }}>
                    <span className="col gap-4 grow">
                      <span className="t-label">{auditActionLabel(e.action)}</span>
                      <span className="muted ellipsis" style={{ fontSize: 12 }}>
                        {[`by ${auditActor(e)}`, e.tenantName != null ? `${e.tenantName}` : null, e.reason != null ? `“${e.reason}”` : null].filter(Boolean).join(' · ')}
                      </span>
                    </span>
                    <span className="muted" style={{ fontSize: 12 }}>
                      {shortDate(e.at)}
                    </span>
                  </div>
                ))
              )}
            </div>
          </SectionCard>
        );

        return (
          <PageFrame title="Dashboard" subtitle="Your restaurants and platform status at a glance" actions={<IconButton title="Refresh" icon={RefreshCw} onClick={reload} />}>
            <div className="kpis" style={{ '--n': 3, gap: 12 } as React.CSSProperties}>
              {kpis.map(([label, value, tone, Icon, to]) => (
                <div key={label} className="card mini-kpi" data-testid={`kpi-${label}`} role="link" tabIndex={0} onClick={() => go(to)} onKeyDown={(e) => e.key === 'Enter' && go(to)}>
                  <span className={`kpi-icon tone-${tone}`}>
                    <Icon size={18} aria-hidden />
                  </span>
                  <span className="grow" style={{ minWidth: 0 }}>
                    <div className="v ellipsis">{`${value ?? 0}`}</div>
                    <div className="l">{label}</div>
                  </span>
                  <ChevronRight size={16} className="faint" aria-hidden />
                </div>
              ))}
            </div>
            <div className="cols mt-16" style={{ '--cols': '3fr 2fr', alignItems: 'start' } as React.CSSProperties}>
              <div className="stack">
                {attention}
                {activity}
              </div>
              {planMix}
            </div>
          </PageFrame>
        );
      }}
    </AsyncView>
  );
}

function AttentionRow({ icon: Icon, tone, title, subtitle, onClick }: { icon: LucideIcon; tone: Tone; title: string; subtitle: string; onClick: () => void }) {
  return (
    <div className="list-row click" style={{ padding: '8px 4px' }} role="link" tabIndex={0} onClick={onClick} onKeyDown={(e) => e.key === 'Enter' && onClick()}>
      <span className={`kpi-icon tone-${tone}`} style={{ width: 36, height: 36, borderRadius: '50%' }}>
        <Icon size={18} aria-hidden />
      </span>
      <span className="col gap-4 grow">
        <span className="t-label ellipsis">{title}</span>
        <span className="muted">{subtitle}</span>
      </span>
      <ChevronRight size={20} aria-hidden />
    </div>
  );
}
