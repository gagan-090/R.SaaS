import { useCallback, useEffect, useState, type CSSProperties } from 'react';
import { Download, Globe, History, Monitor, MinusCircle, Percent, Undo2, Upload, Wallet, CreditCard } from 'lucide-react';
import { api, type Json } from '../../api/client';
import { isoMinute, rupees, todayIso } from '../../lib/format';
import { saveFile } from '../../lib/download';
import { auditActionLabel, auditChanges, roleWord, titleCase } from '../../lib/labels';
import { useSession } from '../../state/auth';
import { LoadError } from '../../ui/async';
import { CategoryChip, EmptyState, Expandable, KpiCard, PageFrame, SecondaryButton, SectionCard, Select, Skeleton, StatusChip, TextField } from '../../ui/kit';
import { showError } from '../../ui/overlay';

/**
 * Auditor portal (also for owners and admins with audit access): the restaurant's activity log with filters and
 * export, sales records (bills, payments, discounts, refunds, voids) and import history. Read-only by design.
 */
export function RestaurantAuditScreen() {
  const me = useSession();
  const canExport = !!me?.can('audit.export');
  const [tab, setTab] = useState(0);
  const tabs: [string, JSX.Element][] = [
    ['Activity log', <LogTab key="log" canExport={canExport} />],
    ...(me?.can('order.read') ? ([['Sales & payments', <SalesTab key="sales" canExport={canExport} />]] as [string, JSX.Element][]) : []),
    ['Imports', <ImportsTab key="imports" />],
  ];
  const cur = Math.min(tab, tabs.length - 1);
  return (
    <PageFrame title="Audit & records" subtitle="Read-only history of this restaurant. Entries cannot be edited or deleted.">
      <div className="chip-scroll">
        {tabs.map(([l], i) => (
          <CategoryChip key={l} testId={`audit-tab-${i}`} label={l} on={cur === i} onClick={() => setTab(i)} />
        ))}
      </div>
      <div className="mt-16">{tabs[cur][1]}</div>
    </PageFrame>
  );
}

function LogTab({ canExport }: { canExport: boolean }) {
  const [facets, setFacets] = useState<Json | null>(null);
  const [rows, setRows] = useState<Json[] | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [module, setModule] = useState<string | null>(null);
  const [actor, setActor] = useState<string | null>(null);
  const [role, setRole] = useState<string | null>(null);
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [q, setQ] = useState('');

  const query = (over: Partial<{ module: string | null; actor: string | null; role: string | null }> = {}) => {
    const m = 'module' in over ? over.module : module;
    const a = 'actor' in over ? over.actor : actor;
    const r = 'role' in over ? over.role : role;
    return { module: m, actorId: a, role: r, from: from.trim() || undefined, to: to.trim() || undefined, q: q.trim() || undefined };
  };

  const load = useCallback(
    async (over: Parameters<typeof query>[0] = {}) => {
      try {
        setRows(await api.auditEvents(query(over)));
        setError(null);
      } catch (e) {
        setError(e);
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [module, actor, role, from, to, q],
  );

  useEffect(() => {
    api.auditFacets().then(setFacets, setError);
    void load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const exportCsv = async () => {
    try {
      saveFile('audit-log.csv', await api.auditCsv(query()), 'text/csv');
    } catch (e) {
      showError(e);
    }
  };

  if (error != null) return <LoadError error={error} page="Audit & records" onRetry={() => load()} />;
  const drop = (testId: string, label: string, value: string | null, items: [string, string][], on: (v: string | null) => void, key: 'module' | 'actor' | 'role') => (
    <Select<string | null>
      label={label}
      testId={testId}
      style={{ width: 210 }}
      value={value}
      options={[[null, 'All'], ...items]}
      onChange={(v) => {
        on(v);
        void load({ [key]: v });
      }}
    />
  );
  return (
    <div className="col gap-16">
      <div className="wrap-end">
        {facets && (
          <>
            {drop('f-module', 'Area', module, ((facets.modules ?? []) as string[]).map((m) => [m, titleCase(m)]), setModule, 'module')}
            {drop('f-actor', 'Employee', actor, ((facets.employees ?? []) as Json[]).map((e) => [e.id as string, `${e.name}`]), setActor, 'actor')}
            {drop('f-role', 'Role', role, ((facets.roles ?? []) as string[]).map((r) => [r, roleWord(r)]), setRole, 'role')}
          </>
        )}
        <TextField label="From" type="date" value={from} onChange={setFrom} onEnter={() => load()} testId="f-from" style={{ width: 160 }} />
        <TextField label="To" type="date" value={to} onChange={setTo} onEnter={() => load()} testId="f-to" style={{ width: 160 }} />
        <TextField label="Record / request id or reason" value={q} onChange={setQ} onEnter={() => load()} testId="f-q" style={{ width: 220 }} />
        <SecondaryButton label="Apply" height={52} testId="f-apply" onClick={() => load()} />
        {canExport && <SecondaryButton label="Export CSV" icon={Download} height={52} testId="export-log" onClick={exportCsv} />}
      </div>
      {rows == null ? (
        <Skeleton h={240} />
      ) : rows.length === 0 ? (
        <EmptyState icon={History} title="Nothing found" message="Try a wider date range or fewer filters." />
      ) : (
        <div className="card list">
          {rows.map((e) => {
            const changes = auditChanges(e);
            const pos = e.source === 'pos';
            return (
              <Expandable
                key={e.id}
                pad
                testId={`log-${e.id}`}
                head={
                  <>
                    <span title={pos ? 'Done on the POS' : 'Done online (console or app)'} className="muted" style={{ display: 'flex' }}>
                      {pos ? <Monitor size={22} aria-hidden /> : <Globe size={22} aria-hidden />}
                    </span>
                    <span className="col grow" style={{ gap: 0 }}>
                      <span className="t-label">{auditActionLabel(e.action)}</span>
                      <span className="muted">
                        {[isoMinute(e.at), `by ${e.actorName ?? 'System'}${e.actorRole != null ? ` (${roleWord(e.actorRole)})` : ''}`, e.module != null ? titleCase(`${e.module}`) : null, e.reason != null ? `“${e.reason}”` : null]
                          .filter(Boolean)
                          .join(' · ')}
                      </span>
                    </span>
                  </>
                }
              >
                {changes.map(([k, v], i) => (
                  <div key={i} className="change-row">
                    <span className="muted">{k}</span>
                    <span style={{ userSelect: 'text', overflowWrap: 'anywhere' }}>{v}</span>
                  </div>
                ))}
                {changes.length === 0 && <span className="faint">No details recorded.</span>}
                {/* ids stay available (the filter searches them) but small and out of the way */}
                {(e.objectId != null || e.requestId != null) && (
                  <div className="faint mt-8" style={{ fontSize: 11.5, userSelect: 'text' }}>
                    {[e.objectId != null ? `Record id ${e.objectId}` : null, e.requestId != null ? `Request id ${e.requestId}` : null].filter(Boolean).join(' · ')}
                  </div>
                )}
              </Expandable>
            );
          })}
        </div>
      )}
    </div>
  );
}

function SalesTab({ canExport }: { canExport: boolean }) {
  const [s, setS] = useState<Json | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [from, setFrom] = useState(todayIso(-1));
  const [to, setTo] = useState('');
  const q = () => ({ from: from.trim(), ...(to.trim() ? { to: to.trim() } : {}) });
  const load = async () => {
    try {
      setS(await api.salesRecords(q()));
      setError(null);
    } catch (e) {
      setError(e);
    }
  };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => void load(), []);

  if (error != null) return <LoadError error={error} page="Audit & records" onRetry={load} />;
  const sum = s?.summary as Json | undefined;
  return (
    <div className="col gap-16">
      <div className="wrap-end">
        <TextField label="From" type="date" value={from} onChange={setFrom} onEnter={load} style={{ width: 170 }} />
        <TextField label="To (optional)" type="date" value={to} onChange={setTo} onEnter={load} style={{ width: 170 }} />
        <SecondaryButton label="Apply" height={52} onClick={load} />
        {canExport && (
          <SecondaryButton
            label="Export CSV"
            icon={Download}
            height={52}
            testId="export-sales"
            onClick={async () => {
              try {
                saveFile('sales.csv', await api.salesCsv(q()), 'text/csv');
              } catch (e) {
                showError(e);
              }
            }}
          />
        )}
      </div>
      {s == null || !sum ? (
        <Skeleton h={200} />
      ) : (
        <>
          <div className="grid-auto" style={{ '--min': '180px', gap: 12 } as CSSProperties}>
            <KpiCard testId="sales-total" label="Sales (paid)" value={rupees(sum.salesPaise)} caption={`${sum.paidBills} bills`} icon={Wallet} />
            <KpiCard label="Discounts" value={rupees(sum.discountsPaise)} icon={Percent} />
            <KpiCard label="Refunds & corrections" value={rupees(Math.abs(sum.refundsPaise))} icon={Undo2} />
            <KpiCard label="Voided lines" value={`${sum.voids}`} caption={rupees(sum.voidsPaise)} icon={MinusCircle} />
            {Object.entries(sum.paymentsByMode as Json).map(([m, v]) => (
              <KpiCard key={m} label={m.toUpperCase()} value={rupees(Number(v))} icon={CreditCard} />
            ))}
          </div>
          <SectionCard title="Bills">
            {(s.bills as Json[]).length === 0 ? (
              <span className="muted">No bills in this period.</span>
            ) : (
              (s.bills as Json[]).map((b, i) => (
                <div key={b.id ?? i} className="list-row dense">
                  <div className="grow">
                    <div className="t-label">
                      {`${b.invoiceNo ?? 'Draft'}`} · {`${b.status}`}
                    </div>
                    <div className="muted">
                      {[
                        isoMinute(b.closedAt ?? b.createdAt),
                        ...(b.payments as Json[]).map((p) => `${p.mode} ${rupees(p.amountPaise)}`),
                        b.discountPaise > 0 ? `discount ${rupees(b.discountPaise)}${b.discountReason != null ? ` (${b.discountReason})` : ''}` : null,
                        ...(b.adjustments as Json[]).map((a) => `adjustment ${rupees(a.amountPaise)}: ${a.reason}`),
                      ]
                        .filter(Boolean)
                        .join(' · ')}
                    </div>
                  </div>
                  <span className="t-label">{rupees(b.totalPaise)}</span>
                </div>
              ))
            )}
          </SectionCard>
          {(s.voids as Json[]).length > 0 && (
            <SectionCard title="Voided lines">
              {(s.voids as Json[]).map((v, i) => (
                <div key={i} style={{ padding: '2px 0' }}>
                  {`${v.name} × ${v.qty} · ${rupees(v.amountPaise)} · ${v.reason ?? 'no reason'} · by ${v.by ?? '—'}${v.approvedBy != null ? `, approved by ${v.approvedBy}` : ''}`}
                </div>
              ))}
            </SectionCard>
          )}
        </>
      )}
    </div>
  );
}

function ImportsTab() {
  const [rows, setRows] = useState<Json[] | null>(null);
  useEffect(() => {
    api.auditImports().then(setRows, () => setRows([]));
  }, []);
  if (rows == null) return <Skeleton h={160} />;
  if (rows.length === 0) return <EmptyState icon={Upload} title="No imports yet" message="Menu and inventory imports from Excel appear here with their results." />;
  return (
    <div className="card list">
      {rows.map((j, i) => (
        <div key={j.id ?? i} className="list-row">
          <div className="grow">
            <div className="t-label">
              {`${j.kind}`} · {`${j.fileName}`} · {j.mode === 'create' ? 'create only' : 'update existing'}
            </div>
            <div className="muted">{[isoMinute(j.createdAt), `by ${j.actorName}`, `${(Number(j.fileSize) / 1024).toFixed(1)} KB`, j.errors > 0 ? `${j.errors} errors` : null].filter(Boolean).join(' · ')}</div>
          </div>
          <StatusChip label={`${j.status}`.replace(/_/g, ' ')} tone={`${j.status}`.includes('committed') ? 'success' : j.status === 'invalid' ? 'danger' : 'neutral'} />
        </div>
      ))}
    </div>
  );
}
