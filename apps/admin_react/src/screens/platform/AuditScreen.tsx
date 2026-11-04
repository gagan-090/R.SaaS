import { useEffect, useState } from 'react';
import { Filter, Search, ShieldCheck, X } from 'lucide-react';
import { api, type Json } from '../../api/client';
import { Chip, SecondaryButton, Select, TextButton, TextField } from '../../ui/kit';
import { AuditList } from './AuditList';

const categories: [string | null, string][] = [
  [null, 'All activity'],
  ['account_lifecycle', 'Account lifecycle'],
  ['account_creation', 'Account creation'],
  ['account_deletion', 'Account deletion'],
  ['mfa_reset', 'MFA reset'],
  ['authentication', 'Authentication (all)'],
  ['auth_success', 'Auth success'],
  ['auth_failure', 'Auth failure'],
  ['restaurant_lifecycle', 'Restaurant lifecycle'],
];

/** P11 audit viewer with category filters, restaurant selector, and the 1.5-year retention note. */
export function AuditScreen() {
  const [category, setCategory] = useState<string | null>(null);
  const [actionText, setActionText] = useState('');
  const [searchText, setSearchText] = useState('');
  const [a, setA] = useState<string | null>(null); // applied text filters (Filter button or Enter)
  const [q, setQ] = useState<string | null>(null);
  const [restaurants, setRestaurants] = useState<Json[] | null>(null);
  const [tenant, setTenant] = useState<string | null>(null);

  useEffect(() => {
    api.restaurants().then((r) => setRestaurants((r.items as Json[]) ?? []), () => undefined);
  }, []);

  const applyText = () => {
    setA(actionText.trim());
    setQ(searchText.trim());
  };
  const clear = () => {
    setCategory(null);
    setA(null);
    setQ(null);
    setTenant(null);
    setActionText('');
    setSearchText('');
  };
  const filtered = category != null || tenant != null || !!q || !!a;

  return (
    <div className="page page-enter">
      <div className="between">
        <h1 className="t-screen">Audit log</h1>
        <span className="row pill-box t-mono muted" style={{ fontSize: 12, padding: '5px 10px', border: '1px solid color-mix(in srgb, var(--faint) 30%, transparent)' }}>
          <ShieldCheck size={16} aria-hidden />
          Retention: 1.5 Years (548 days)
        </span>
      </div>
      {/* chips wrap onto a second line instead of scrolling sideways */}
      <div className="wrap mt-12" style={{ gap: 6 }}>
        {categories.map(([c, l]) => (
          // a category narrows what the other filters already show; "All activity" drops only the category
          <Chip key={l} testId={`audit-cat-${c ?? 'all'}`} label={l} on={category === c} onClick={() => setCategory(c)} />
        ))}
      </div>
      <div className="wrap-end mt-16" style={{ gap: 12 }}>
        <TextField label="Search text / reason" value={searchText} onChange={setSearchText} onEnter={applyText} prefix={<Search size={18} />} testId="audit-search" style={{ width: 220, maxWidth: '100%' }} />
        <TextField label="Action contains" value={actionText} onChange={setActionText} onEnter={applyText} testId="audit-action" style={{ width: 180, maxWidth: '100%' }} />
        <Select<string | null>
          label="Restaurant"
          testId="audit-restaurant-filter"
          style={{ width: 260, maxWidth: '100%' }}
          value={tenant}
          options={[[null, 'All restaurants'], ...((restaurants ?? []).map((r) => [r.id, `${r.name} (${r.code})`]) as [string, string][])]}
          onChange={setTenant}
        />
        <SecondaryButton label="Filter" icon={Filter} height={52} onClick={applyText} testId="audit-filter" />
        {filtered && <TextButton label="Clear filters" icon={X} onClick={clear} testId="audit-clear" />}
      </div>
      <div className="card pad-16 mt-16">
        <AuditList category={category} action={a} tenantId={tenant} q={q} />
      </div>
    </div>
  );
}
