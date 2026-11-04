import { useState, type ReactNode } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import {
  Archive, ArrowLeft, ArrowRight, ArrowLeftRight, Ban, CalendarDays, Check, CheckCircle2, CircleDot, Circle, CreditCard, Download, PauseCircle, PlayCircle, Plus, RefreshCcw,
  Router, Smartphone, Store, TrendingDown, TrendingUp, Trash2, Award, Wallet, XCircle, History, ArchiveRestore, type LucideIcon,
} from 'lucide-react';
import { api, type Json } from '../../api/client';
import { daysUntil, formatPaise, shortDate, wholeRupees } from '../../lib/format';
import { saveFile } from '../../lib/download';
import { featureLabel, restaurantStatusLabel, restaurantStatusTone, statusLabel, titleCase, toneForStatus, type Tone } from '../../lib/labels';
import { useSession } from '../../state/auth';
import { activePlans, useCached } from '../../state/app';
import { AsyncView } from '../../ui/async';
import { DangerButton, IconButton, KpiCard, PrimaryButton, SecondaryButton, SectionCard, Select, StatusChip, TextButton, TextField } from '../../ui/kit';
import { askReason, Dialog, openDialog, showDone, showError } from '../../ui/overlay';
import { AuditList } from './AuditList';

const cap = (s: string) => s[0].toUpperCase() + s.substring(1);

/** P6 Restaurant detail + P7 license actions + payments. */
export function RestaurantDetailScreen() {
  const { id = '' } = useParams();
  const me = useSession();
  const can = (p: string) => !!me?.can(p);
  const plans = useCached(activePlans) ?? [];
  const navigate = useNavigate();
  const [n, setN] = useState(0);
  const reload = () => setN((x) => x + 1);

  const run = async (f: () => Promise<unknown>, done: string) => {
    try {
      await f();
      showDone(done);
      reload();
    } catch (e) {
      showError(e);
    }
  };

  const status = async (action: string) => {
    const reason = await askReason({
      title: `${cap(action)} restaurant`,
      confirmLabel: cap(action),
      message:
        action === 'suspend'
          ? 'In suspend, all restaurant logs and data remain on the system. The owner and staff become read-only.'
          : 'The owner and staff are affected immediately. Suspended and blocked restaurants become read-only.',
      destructive: action === 'suspend' || action === 'block',
    });
    if (reason == null) return;
    await run(() => api.setStatus(id, action, reason), `Restaurant ${action}d`);
  };

  const archive = async () => {
    const reason = await askReason({
      title: 'Archive restaurant to cold storage?',
      confirmLabel: 'Archive to Cold Storage',
      message: 'All restaurant logs, menu, orders, staff, licenses and tenant data will be bundled into a compressed archive (.json.gz) with SHA-256 integrity verification. The restaurant status transitions to Archived.',
    });
    if (reason == null) return;
    await run(() => api.archiveRestaurant(id, reason), 'Restaurant archived to cold storage');
  };

  const downloadArchive = async (code: string) => {
    try {
      saveFile(`restaurant-${code}-archive.json.gz`, await api.downloadArchive(id), 'application/gzip');
      showDone('Cold storage archive downloaded (.json.gz)');
    } catch (e) {
      showError(e);
    }
  };

  const restore = async () => {
    const reason = await askReason({
      title: 'Restore restaurant from cold storage?',
      confirmLabel: 'Restore to Suspended',
      message: 'Integrity checksums will be verified, cold storage logs restored, and the restaurant moved to Suspended status (Archived -> Suspend -> Active). From Suspended you can review and reactivate.',
    });
    if (reason == null) return;
    await run(() => api.restoreRestaurant(id, reason), 'Restaurant restored to Suspended status');
  };

  const deleteRestaurant = async () => {
    const reason = await askReason({
      title: 'Permanently delete restaurant?',
      confirmLabel: 'Delete Restaurant',
      message: 'Housekeeping deletion is only permitted for archived restaurants. The restaurant tenant will be marked deleted and all credentials revoked, with a permanent audit record preserved.',
    });
    if (reason == null) return;
    try {
      await api.deleteRestaurant(id, reason);
      showDone('Restaurant deleted');
      navigate('/restaurants');
    } catch (e) {
      showError(e);
    }
  };

  const license = async (action: string, currentPlan: string | null) => {
    let plan: string | null | undefined = currentPlan;
    if (action === 'upgrade' || action === 'downgrade' || action === 'issue') {
      const list = await activePlans.get();
      plan = await openDialog<string>((close) => (
        <Dialog title={`Choose plan to ${action}`} actions={<SecondaryButton label="Cancel" onClick={() => close()} />}>
          <div className="col gap-4">
            {list.map((p) => (
              <button key={p.code} type="button" className="list-row click" style={{ border: 0, background: p.code === currentPlan ? 'var(--raised)' : 'transparent', textAlign: 'left', color: 'inherit', padding: '12px' }} onClick={() => close(p.code)}>
                <span className={`t-label grow${p.code === currentPlan ? ' accent-text' : ''}`}>{`${p.name}`}</span>
                <span className="muted">
                  {wholeRupees(p.pricePaise)}/mo · {wholeRupees(p.yearlyPricePaise ?? p.pricePaise * 10)}/yr
                </span>
              </button>
            ))}
          </div>
        </Dialog>
      ));
      if (plan == null) return;
    }
    const reason = await askReason({ title: `License: ${action}`, confirmLabel: cap(action), destructive: action === 'revoke' });
    if (reason == null) return;
    await run(() => api.licenseAction(id, action, reason, action === 'renew' || action === 'revoke' ? null : plan), `License ${action === 'issue' ? 'issued' : `${action}d`}`);
  };

  const payment = async () => {
    const r = await openDialog<{ rupees: number; method: string; reference: string }>((close) => <PaymentDialog close={close} />);
    if (!r) return;
    await run(() => api.recordPayment(id, { amountPaise: r.rupees * 100, method: r.method, reference: r.reference, paidAt: new Date().toISOString() }), 'Payment recorded');
  };

  return (
    <AsyncView deps={[id, n]} load={() => api.restaurant(id)}>
      {(r) => {
        const st = r.status as string;
        const ent = (r.entitlement ?? {}) as Json;
        const lic = (r.currentLicense ?? null) as Json | null;
        const plan = plans.find((x) => x.code === lic?.planCode);
        const planName = `${plan?.name ?? lic?.planName ?? titleCase(`${lic?.planCode ?? 'No plan'}`)}`;
        // what this restaurant actually pays: the license's own cycle and amount, not the plan's default cycle
        const yearly = (lic?.billingCycle ?? plan?.billingCycle) === 'yearly';
        const paid: number | null = lic?.amountPaise ?? (plan == null ? null : yearly ? plan.yearlyPricePaise ?? plan.pricePaise * 10 : plan.pricePaise);
        const priceText = paid == null ? null : `${wholeRupees(paid)} / ${yearly ? 'year' : 'month'}`;
        const daysLeft = daysUntil(lic?.endsAt);
        const devices = r.devices as Json[];
        const hub = devices.find((d) => d.isHub === true && d.revokedAt == null);
        const features = (ent.features ?? []) as string[];
        const archives = (r.archives ?? []) as Json[];
        // a revoked / never-issued license leaves the account open but everything inside it locked
        const hasPlan = ent.state !== 'none';
        const showCold = archives.length > 0 || st === 'suspended' || st === 'archived';
        const btn = (node: ReactNode) => node;

        const profile = (
          <SectionCard title="Profile">
            <div className="kv">
              <span>Code</span>
              <span>{`${r.code}`}</span>
              <span>Owner</span>
              <span>{`${r.ownerEmail ?? '—'}`}</span>
              <span>GSTIN</span>
              <span>{r.gstin ? `${r.gstin}` : '—'}</span>
              <span>Address</span>
              <span>{r.address ? `${r.address}` : '—'}</span>
              {r.statusReason != null && (
                <>
                  <span>Status reason</span>
                  <span>{`${r.statusReason}`}</span>
                </>
              )}
              <span>Created</span>
              <span>{shortDate(r.createdAt)}</span>
            </div>
            {can('platform.restaurant.status') && (
              <div className="wrap mt-16">
                {st === 'pending' && btn(<SecondaryButton label="Activate" icon={CheckCircle2} height={44} onClick={() => status('activate')} />)}
                {st === 'active' && btn(<SecondaryButton label="Suspend" icon={PauseCircle} height={44} onClick={() => status('suspend')} />)}
                {(st === 'suspended' || st === 'blocked') && btn(<SecondaryButton label="Reactivate" icon={PlayCircle} height={44} onClick={() => status('reactivate')} />)}
                {st === 'suspended' && btn(<SecondaryButton label="Archive to cold storage" icon={Archive} height={44} onClick={archive} />)}
                {st === 'archived' && btn(<SecondaryButton label="Download cold storage (.json.gz)" icon={Download} height={44} onClick={() => downloadArchive(`${r.code}`)} />)}
                {st === 'archived' && btn(<SecondaryButton label="Restore to Suspended" icon={ArchiveRestore} height={44} onClick={restore} />)}
                {st === 'archived' && btn(<DangerButton label="Delete (Housekeeping)" icon={Trash2} height={44} onClick={deleteRestaurant} />)}
                {(st === 'active' || st === 'suspended') && btn(<DangerButton label="Block" icon={Ban} height={44} onClick={() => status('block')} />)}
              </div>
            )}
          </SectionCard>
        );

        const licenseCard = (
          <SectionCard title="License">
            {lic == null ? (
              <p className="muted" style={{ margin: 0 }}>No active license — the restaurant is read-only until one is issued.</p>
            ) : (
              <>
                <div className="kv">
                  <span>Plan</span>
                  <span>{`${planName}${priceText == null ? '' : ` · ${priceText}`}`}</span>
                  <span>Started</span>
                  <span>{shortDate(lic.startsAt)}</span>
                  <span>Ends</span>
                  <span>{`${shortDate(lic.endsAt)}${daysLeft == null ? '' : daysLeft >= 0 ? ` · ${daysLeft} days left` : ` · ended ${-daysLeft} days ago`}`}</span>
                  <span>Grace period</span>
                  <span>{`${lic.graceDays} days after the end date`}</span>
                </div>
                <div className="t-overline mt-12">Includes</div>
                <div className="wrap mt-8" style={{ gap: 6 }}>
                  {features.map((f) => (
                    <span key={f} className="feature-chip">
                      <Check size={16} color="var(--success)" aria-hidden />
                      {featureLabel(f)}
                    </span>
                  ))}
                </div>
              </>
            )}
            {can('platform.license.manage') && (
              <div className="wrap mt-16">
                {(lic == null
                  ? ([['issue', CreditCard]] as [string, LucideIcon][])
                  : ([
                      ['renew', RefreshCcw],
                      ['upgrade', TrendingUp],
                      ['downgrade', TrendingDown],
                    ] as [string, LucideIcon][])
                ).map(([a, Icon]) => (
                  <SecondaryButton key={a} label={cap(a)} icon={Icon} height={44} onClick={() => license(a, lic?.planCode ?? null)} />
                ))}
                {lic != null && <DangerButton label="Revoke" icon={XCircle} height={44} onClick={() => license('revoke', null)} />}
              </div>
            )}
          </SectionCard>
        );

        const payments = (
          <SectionCard title="Subscription payments" actions={can('platform.payment.record') ? <TextButton label="Record" icon={Plus} onClick={payment} /> : undefined}>
            {(r.payments as Json[]).length === 0 ? (
              <p className="muted" style={{ margin: 0 }}>No payments recorded yet.</p>
            ) : (
              (r.payments as Json[]).map((pay, i) => (
                <div key={i} className="list-row dense">
                  <Wallet size={20} color="var(--success)" aria-hidden />
                  <span className="col gap-4 grow">
                    <span className="t-label">{formatPaise(pay.amountPaise)}</span>
                    <span className="muted">{`${titleCase(`${pay.method}`)}${(pay.reference ?? '') === '' ? '' : ` · ${pay.reference}`}`}</span>
                  </span>
                  <span className="muted">{shortDate(pay.paidAt)}</span>
                </div>
              ))
            )}
          </SectionCard>
        );

        const cold = (
          <SectionCard title="Cold Storage & Archives">
            {archives.length === 0 ? (
              <p className="muted" style={{ margin: 0 }}>No cold storage archives created yet. When suspended, archiving bundles logs to S3 cold storage format.</p>
            ) : (
              archives.map((arc, i) => (
                <div key={i} className="list-row dense" style={{ alignItems: 'flex-start' }}>
                  <Archive size={20} color="var(--pending)" aria-hidden />
                  <span className="col gap-4 grow">
                    <span className="t-label">Archive · {((arc.sizeBytes ?? 0) / 1024).toFixed(1)} KB</span>
                    <span className="t-mono muted" style={{ fontSize: 12 }}>
                      SHA-256: {`${arc.sha256 ?? ''}`.substring(0, 16)}… · Created {shortDate(arc.createdAt)}
                    </span>
                    {arc.counts != null && (
                      <span className="muted" style={{ fontSize: 12 }}>
                        {arc.counts.users ?? 0} users · {arc.counts.auditEvents ?? 0} audit logs · {arc.counts.branches ?? 0} branches
                      </span>
                    )}
                    {arc.restoredAt != null && (
                      <span className="t-mono success-text" style={{ fontSize: 11 }}>
                        Restored on {shortDate(arc.restoredAt)}
                      </span>
                    )}
                  </span>
                  <IconButton title="Download .json.gz for S3 Archive" icon={Download} onClick={() => downloadArchive(`${r.code}`)} />
                  {st === 'archived' && <TextButton label="Restore" icon={ArchiveRestore} small onClick={restore} />}
                </div>
              ))
            )}
          </SectionCard>
        );

        const branches = (
          <SectionCard title="Branches & devices">
            {(r.branches as Json[]).map((b) => (
              <div key={b.id ?? b.code} className="list-row dense">
                <Store size={20} className="muted" aria-hidden />
                <span className="col gap-4">
                  <span className="t-label">{`${b.name}`}</span>
                  <span className="muted">Branch {`${b.code}`}</span>
                </span>
              </div>
            ))}
            {devices.map((d, i) => {
              const off = d.revokedAt != null;
              const Icon = d.isHub === true ? Router : Smartphone;
              return (
                <div key={d.id ?? i} className="list-row dense">
                  <Icon size={20} color={off ? 'var(--faint)' : 'var(--text)'} aria-hidden />
                  <span className="col gap-4">
                    <span className={`t-label${off ? ' faint' : ''}`}>{`${d.name}${d.isHub === true ? ' · Hub' : ''}`}</span>
                    <span className="muted">{`${titleCase(`${d.platform}`)} · ${off ? 'revoked' : `last seen ${shortDate(d.lastSeenAt)}`}`}</span>
                  </span>
                </div>
              );
            })}
            {devices.length === 0 && <p className="muted" style={{ margin: 0 }}>No devices yet. The owner sets up the hub from the POS app.</p>}
          </SectionCard>
        );

        return (
          <div className="page page-enter">
            <div className="wrap gap-12">
              <IconButton title="Back to restaurants" icon={ArrowLeft} onClick={() => navigate('/restaurants')} />
              <div style={{ minWidth: 0 }}>
                <h1 className="t-page" style={{ fontSize: '2.125rem' }}>
                  {`${r.name}`}
                </h1>
                <div className="muted">
                  {`${r.code}`} · {`${r.ownerEmail}`}
                </div>
              </div>
              <StatusChip testId="restaurant-status" label={restaurantStatusLabel(st, hasPlan)} tone={restaurantStatusTone(st, hasPlan)} />
              <StatusChip label={hasPlan ? `License: ${statusLabel(ent.state)}` : 'License: none · console locked'} tone={hasPlan ? toneForStatus(`${ent.state}`) : 'danger'} />
            </div>
            <div className="mt-12">
              <LifecyclePipeline status={st} hasPlan={hasPlan} />
            </div>
            <div className="kpis mt-16">
              <KpiCard label="Plan" value={planName} caption={priceText} icon={Award} tone="saffron" />
              <KpiCard label="License ends" value={lic?.endsAt == null ? '—' : shortDate(lic.endsAt)} caption={daysLeft == null ? null : daysLeft >= 0 ? `${daysLeft} days left` : 'ended'} icon={CalendarDays} tone={daysLeft != null && daysLeft < 7 ? 'danger' : 'success'} />
              <KpiCard label="Branches" value={`${(r.branches as Json[]).length}`} icon={Store} />
              <KpiCard label="Devices" value={`${devices.filter((d) => d.revokedAt == null).length}`} caption={hub == null ? 'No hub yet' : `Hub: ${hub.name}`} icon={Router} tone={hub == null ? 'neutral' : 'success'} />
            </div>
            {/* paired cards share a row and a height, so a new restaurant's short cards leave no ragged gaps */}
            <div className="cols mt-16">
              {profile}
              {licenseCard}
            </div>
            <div className="cols mt-16">
              {payments}
              {branches}
            </div>
            {showCold && <div className="mt-16">{cold}</div>}
            <div className="mt-16">
              <SectionCard title="History" actions={<TextButton label="Open audit log" icon={History} onClick={() => navigate('/audit')} />}>
                <AuditList tenantId={id} embedded />
              </SectionCard>
            </div>
          </div>
        );
      }}
    </AsyncView>
  );
}

function PaymentDialog({ close }: { close: (v?: { rupees: number; method: string; reference: string }) => void }) {
  const [amount, setAmount] = useState('');
  const [method, setMethod] = useState('upi');
  const [reference, setReference] = useState('');
  const record = () => {
    const rupees = /^\d+$/.test(amount.trim()) ? parseInt(amount.trim(), 10) : NaN;
    if (!Number.isFinite(rupees) || rupees <= 0) return close();
    close({ rupees, method, reference: reference.trim() });
  };
  return (
    <Dialog
      title="Record payment"
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={() => close()} />
          <PrimaryButton label="Record" height={56} onClick={record} testId="record-payment" />
        </>
      }
    >
      <div className="col gap-12">
        <TextField label="Amount (₹, whole rupees)" inputMode="numeric" value={amount} onChange={(v) => setAmount(v.replace(/\D/g, ''))} autoFocus />
        <Select
          label="Method"
          value={method}
          options={[
            ['upi', 'UPI'],
            ['bank', 'Bank transfer'],
            ['cash', 'Cash'],
            ['other', 'Other'],
          ]}
          onChange={setMethod}
        />
        <TextField label="Reference (UTR / cheque no.)" value={reference} onChange={setReference} />
      </div>
    </Dialog>
  );
}

function LifecyclePipeline({ status, hasPlan }: { status: string; hasPlan: boolean }) {
  const steps: [string, string, string][] = [
    ['pending', 'Create', 'Pending owner verification'],
    hasPlan ? ['active', 'Active', 'Operational & licensed'] : ['active', 'Active · no plan', 'Locked until a plan is issued'],
    ['suspended', 'Suspended', 'Paused · Logs remain on system'],
    ['archived', 'Archived', 'Cold storage · Downloadable bundle'],
    ['deleted', 'Delete', 'Housekeeping removal'],
  ];
  const currentIdx = steps.findIndex((s) => s[0] === status);
  const blocked = status === 'blocked';
  const toneOf = (key: string): Tone =>
    status === 'active' && !hasPlan && key === 'active' ? 'saffron' : status === 'suspended' && key === 'suspended' ? 'saffron' : status === 'archived' && key === 'archived' ? 'pending' : status === 'deleted' && key === 'deleted' ? 'danger' : 'success';
  return (
    <div className="card" style={{ padding: '8px 12px' }}>
      <div className="between" style={{ gap: '4px 8px' }}>
        <span className="row" style={{ gap: 6 }}>
          <History size={16} className="muted" aria-hidden />
          <span className="t-overline">Restaurant lifecycle</span>
        </span>
        <span className="t-mono muted" style={{ fontSize: 10.5 }}>
          {blocked ? 'Status: Blocked' : 'Order: Create ➔ Active ⇆ Suspend ⇆ Archived ➔ Delete'}
        </span>
      </div>
      <div className="row mt-8" style={{ overflowX: 'auto', paddingBottom: 2 }}>
        {steps.map(([key, label, caption], i) => {
          const cur = !blocked && (key === status || (status === 'pending' && i === 0));
          const past = !blocked && currentIdx > i;
          const tone = toneOf(key);
          const color = cur ? `var(--c)` : past ? 'var(--success)' : 'var(--faint)';
          const Icon = cur ? CircleDot : past ? CheckCircle2 : Circle;
          return (
            <div key={key} className="row" style={{ flex: '1 0 auto', gap: 6 }}>
              {i > 0 && (i === 2 || i === 3 ? <ArrowLeftRight size={16} color="var(--faint)" aria-hidden /> : <ArrowRight size={16} color="var(--faint)" aria-hidden />)}
              <div className={`step-chip tone-${tone}${cur ? ' cur' : past ? ' past' : ''}`} style={{ flex: 1 }}>
                <div className="row" style={{ gap: 6 }}>
                  <Icon size={14} color={color} aria-hidden />
                  <span className={`ellipsis${cur || past ? '' : ' muted'}`} style={{ fontWeight: cur ? 700 : 400, fontSize: 15 }}>
                    {label}
                  </span>
                </div>
                <div className="t-mono muted ellipsis" style={{ fontSize: 10 }}>
                  {caption}
                </div>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
