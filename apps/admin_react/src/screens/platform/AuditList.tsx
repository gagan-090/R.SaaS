import { Armchair, BadgeCheck, Award, History, LogIn, Router, Store, UtensilsCrossed, type LucideIcon } from 'lucide-react';
import { api, type Json } from '../../api/client';
import { dateTime12 } from '../../lib/format';
import { auditActionLabel, auditActor, auditChanges } from '../../lib/labels';
import { AsyncView } from '../../ui/async';
import { Expandable } from '../../ui/kit';

function iconFor(action: string): LucideIcon {
  switch (action.split('.')[0]) {
    case 'auth': case 'mfa': return LogIn;
    case 'restaurant': case 'tenant': return Store;
    case 'license': case 'plan': case 'payment': return Award;
    case 'menu': case 'tax_rule': return UtensilsCrossed;
    case 'staff': return BadgeCheck;
    case 'device': return Router;
    case 'floor': case 'table': return Armchair;
    default: return History;
  }
}

/** One event: what happened, who, when, why — expand to see exactly what changed. */
export function AuditEventRow({ e, showTenant }: { e: Json; showTenant: boolean }) {
  const changes = auditChanges(e);
  const Icon = iconFor(`${e.action}`);
  return (
    <Expandable
      head={
        <>
          <span className="icon-circle">
            <Icon size={18} aria-hidden />
          </span>
          <span className="col gap-4 grow">
            <span className="t-label">{auditActionLabel(e.action)}</span>
            <span className="muted">
              {[`by ${auditActor(e)}`, showTenant && e.tenantName != null ? `${e.tenantName}` : null, dateTime12(e.at), e.reason != null ? `“${e.reason}”` : null].filter(Boolean).join(' · ')}
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
      {changes.length === 0 && <span className="faint">No field changes recorded.</span>}
      {e.ip != null && (
        <div className="faint" style={{ fontSize: 12 }}>
          From {`${e.ip}`}
        </div>
      )}
    </Expandable>
  );
}

/** P11 audit list (shared by the audit viewer and the restaurant detail page). */
export function AuditList({ tenantId, action, category, q, embedded, limit }: { tenantId?: string | null; action?: string | null; category?: string | null; q?: string | null; embedded?: boolean; limit?: number }) {
  return (
    <AsyncView
      deps={[tenantId, action, category, q]}
      load={() => api.audit({ tenantId, action, category, q })}
      isEmpty={(d) => (d.items as Json[]).length === 0}
      emptyTitle="No history yet"
    >
      {(d) => {
        const items = (d.items as Json[]).filter((x) => x && typeof x === 'object').slice(0, limit ?? (embedded ? 12 : 1000));
        return (
          <div>
            {items.map((e, i) => (
              <AuditEventRow key={`${e.id ?? i}`} e={e} showTenant={tenantId == null} />
            ))}
          </div>
        );
      }}
    </AsyncView>
  );
}
