import { useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { ChevronLeft, ChevronRight, Filter, MailWarning, Plus, Search, Store } from 'lucide-react';
import { api, type Json } from '../../api/client';
import { shortDate } from '../../lib/format';
import { restaurantStatusLabel, restaurantStatusTone, statusLabel, titleCase } from '../../lib/labels';
import { useSession } from '../../state/auth';
import { activePlans, useCached } from '../../state/app';
import { AsyncView } from '../../ui/async';
import { IconButton, PrimaryButton, SecondaryButton, Segmented, Select, StatusChip, TextField } from '../../ui/kit';
import { openDialog } from '../../ui/overlay';
import { PendingRegistrations, RegisterRestaurantDialog } from './registration';

/** P4 Restaurants list with search, filters and pagination; P5 register from here. */
export function RestaurantsScreen() {
  const [params] = useSearchParams();
  const initialStatus = params.get('status');
  const me = useSession();
  const canCreate = !!me?.can('platform.restaurant.create');
  const navigate = useNavigate();
  const plans = useCached(activePlans) ?? [];

  const [q, setQ] = useState('');
  const [owner, setOwner] = useState('');
  const [status, setStatus] = useState<string | null>(initialStatus === 'pending' ? null : initialStatus);
  const [plan, setPlan] = useState<string | null>(null);
  const [page, setPage] = useState(1);
  const [applied, setApplied] = useState({ q: '', owner: '', status, plan, page: 1, n: 0 });
  /** "pending" restaurants are registrations awaiting the owner's email: they live in their own tab. */
  const [awaitingTab, setAwaitingTab] = useState(initialStatus === 'pending');
  const [awaitingReload, setAwaitingReload] = useState(0);

  const apply = (over: Partial<typeof applied> = {}, resetPage = true) => {
    const next = { q, owner, status, plan, page: resetPage ? 1 : page, n: applied.n + 1, ...over };
    if (resetPage) setPage(1);
    setApplied(next);
  };
  const goPage = (p: number) => {
    setPage(p);
    setApplied({ ...applied, page: p, n: applied.n + 1 });
  };

  const register = async () => {
    if ((await openDialog<boolean>((close) => <RegisterRestaurantDialog close={close} />)) === true) {
      // a new registration waits for the owner's email: show it there
      setAwaitingTab(true);
      setAwaitingReload((n) => n + 1);
    }
  };

  return (
    <div className="page page-enter">
      <div className="between">
        <h1 className="t-screen">Restaurants</h1>
        {canCreate && (
          <div style={{ width: 240 }}>
            <PrimaryButton label="Register restaurant" icon={Plus} height={52} block onClick={register} testId="register-restaurant" />
          </div>
        )}
      </div>
      <div className="mt-16">
        <Segmented<boolean>
          testId="restaurants-tabs"
          value={awaitingTab}
          options={[
            [false, 'Restaurants', Store],
            [true, 'Awaiting verification', MailWarning],
          ]}
          onChange={setAwaitingTab}
        />
      </div>
      <div className="mt-16">
        {awaitingTab ? (
          <PendingRegistrations canAct={canCreate} reloadKey={awaitingReload} />
        ) : (
          <>
            <div className="wrap-end" style={{ gap: 12 }}>
              <TextField label="Search name or code" value={q} onChange={setQ} onEnter={() => apply()} prefix={<Search size={18} />} testId="search" style={{ width: 260, maxWidth: '100%' }} />
              <TextField label="Owner email" value={owner} onChange={setOwner} onEnter={() => apply()} style={{ width: 220, maxWidth: '100%' }} />
              <Select<string | null>
                label="Status"
                testId="filter-Status"
                style={{ width: 200 }}
                value={status}
                options={[[null, 'Any'], ...(['active', 'suspended', 'blocked', 'archived'].map((s) => [s, statusLabel(s)]) as [string, string][])]}
                onChange={(v) => (setStatus(v), apply({ status: v }))}
              />
              <Select<string | null>
                label="Plan"
                testId="filter-Plan"
                style={{ width: 200 }}
                value={plan}
                options={[[null, 'Any'], ...(plans.map((p) => [p.code, statusLabel(p.code)]) as [string, string][])]}
                onChange={(v) => (setPlan(v), apply({ plan: v }))}
              />
              <SecondaryButton label="Apply" icon={Filter} height={52} onClick={() => apply()} />
            </div>
            <div className="mt-16">
              <AsyncView
                deps={[applied]}
                load={() => api.restaurants({ q: applied.q, owner: applied.owner, status: applied.status, plan: applied.plan, page: applied.page })}
                isEmpty={(d) => (d.items as Json[]).length === 0}
                emptyTitle="No restaurants match these filters"
              >
                {(d) => {
                  const items = d.items as Json[];
                  const total = d.total as number;
                  const pager = (
                    <div className="row" style={{ justifyContent: 'flex-end', padding: 8 }}>
                      <span>
                        {total} restaurants · page {applied.page}
                      </span>
                      <IconButton title="Previous page" icon={ChevronLeft} onClick={applied.page > 1 ? () => goPage(applied.page - 1) : null} />
                      <IconButton title="Next page" icon={ChevronRight} onClick={applied.page * 25 < total ? () => goPage(applied.page + 1) : null} />
                    </div>
                  );
                  return (
                    <>
                      {/* phones: one card per restaurant instead of a sideways-scrolling table */}
                      <div className="only-narrow col gap-8">
                        {items.map((r) => (
                          <div key={r.id} className="card pad-16 clickable" data-testid={`row-${r.code}`} onClick={() => navigate(`/restaurants/${r.id}`)}>
                            <div className="row">
                              <div className="grow">
                                <div className="t-label">{`${r.name}`}</div>
                                <div className="muted">
                                  {r.code} · {titleCase(`${r.plan ?? 'no plan'}`)}
                                  {r.licenseEndsAt == null ? '' : ` · ends ${shortDate(r.licenseEndsAt)}`}
                                </div>
                              </div>
                              <StatusChip label={restaurantStatusLabel(r.status, r.plan != null)} tone={restaurantStatusTone(r.status, r.plan != null)} />
                            </div>
                          </div>
                        ))}
                        {pager}
                      </div>
                      <div className="only-wide card">
                        <div className="table-scroll">
                          <table className="data">
                            <thead>
                              <tr>
                                <th>Name</th>
                                <th>Code</th>
                                <th>Owner</th>
                                <th>Plan</th>
                                <th>Status</th>
                                <th>License ends</th>
                                <th className="num">Branches</th>
                              </tr>
                            </thead>
                            <tbody>
                              {items.map((r) => (
                                <tr key={r.id} className="click" data-testid={`row-${r.code}`} onClick={() => navigate(`/restaurants/${r.id}`)}>
                                  <td className="t-label">{`${r.name}`}</td>
                                  <td className="t-mono muted">{`${r.code}`}</td>
                                  <td>{`${r.ownerEmail}`}</td>
                                  <td>{titleCase(`${r.plan ?? '—'}`)}</td>
                                  <td>
                                    <StatusChip label={restaurantStatusLabel(r.status, r.plan != null)} tone={restaurantStatusTone(r.status, r.plan != null)} />
                                  </td>
                                  <td>{shortDate(r.licenseEndsAt)}</td>
                                  <td className="num">{`${r.branches}`}</td>
                                </tr>
                              ))}
                            </tbody>
                          </table>
                        </div>
                        <hr className="divider" />
                        {pager}
                      </div>
                    </>
                  );
                }}
              </AsyncView>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
