import { useCallback, useEffect, useState } from 'react';
import { Lock, Plus } from 'lucide-react';
import { api, errorText, type Json } from '../../api/client';
import { useSession } from '../../state/auth';
import { LoadError } from '../../ui/async';
import { Check, Expandable, LoadingState, PageFrame, PrimaryButton, SecondaryButton, SectionCard, TextButton, TextField } from '../../ui/kit';
import { confirm, Dialog, openDialog, showDone, showError } from '../../ui/overlay';
import { roleInfo } from './roles';

/** Areas for grouping permissions in the role editor (key prefix → heading). */
const areas: [string, string][] = [
  ['restaurant', 'Restaurant & plan'], ['license', 'Restaurant & plan'], ['staff', 'Employees'], ['roles', 'Employees'],
  ['device', 'Devices'], ['floor', 'Floors & tables'], ['menu', 'Menu'], ['recipe', 'Menu'], ['order', 'Orders'],
  ['discount', 'Billing'], ['payment', 'Billing'], ['bill', 'Billing'], ['kds', 'Kitchen'], ['inventory', 'Inventory'],
  ['expense', 'Expenses'], ['import', 'Imports'], ['shift', 'Shifts'], ['clock', 'Shifts'], ['reports', 'Reports & logs'], ['audit', 'Reports & logs'],
];
const areaOf = (key: string) => areas.find(([p]) => key.startsWith(p))?.[1] ?? 'Other';

/** Roles: what each built-in role can do, and the owner's custom roles (plan feature "roles.custom"). */
export function RolesScreen() {
  const me = useSession();
  const canManage = !!me?.can('roles.manage');
  const [data, setData] = useState<Json | null>(null);
  const [error, setError] = useState<unknown>(null);

  const load = useCallback(async () => {
    try {
      setData(await api.restaurantRoles());
      setError(null);
    } catch (e) {
      setError(e);
    }
  }, []);
  useEffect(() => void load(), [load]);

  const edit = async (role?: Json) => {
    const saved = await openDialog<string>((close) => <RoleEditor role={role} catalog={data!.catalog as Json[]} close={close} />);
    if (saved != null) {
      await load();
      showDone(saved);
    }
  };

  const remove = async (role: Json) => {
    if (!(await confirm({ title: `Delete ${role.name}?`, message: 'Employees must be moved to another role first.' }))) return;
    try {
      await api.deleteRole(role.id);
      await load();
      showDone(`${role.name} deleted`);
    } catch (e) {
      showError(e);
    }
  };

  if (error != null) return <LoadError error={error} page="Roles" onRetry={load} />;
  if (data == null) return <LoadingState />;
  const inPlan = data.customRolesInPlan === true;
  const custom = data.custom as Json[];
  const describe = Object.fromEntries((data.catalog as Json[]).map((c) => [`${c.key}`, `${c.description}`]));
  const perms = (list: string[]) => (
    <div className="wrap" style={{ gap: 4 }}>
      {list.map((k) => (
        <span key={k} className="feature-chip" style={{ fontSize: 12 }}>
          {describe[k] ?? k}
        </span>
      ))}
    </div>
  );

  return (
    <PageFrame title="Roles" subtitle="What each role can do. Plan features limit every role." actions={canManage && inPlan && <PrimaryButton label="New custom role" icon={Plus} height={48} testId="add-role" onClick={() => edit()} />}>
      <div className="stack">
        <SectionCard title="Custom roles">
          {!inPlan ? (
            <div className="row" data-testid="roles-locked">
              <Lock size={22} className="muted" aria-hidden />
              <span className="muted">Custom roles are not in your plan. Ask House Plating to switch on "Custom roles" for your plan.</span>
            </div>
          ) : custom.length === 0 ? (
            <span className="muted">None yet. A custom role is a name plus the exact permissions you choose — for example a "Floor manager" who arranges tables but cannot take payments.</span>
          ) : (
            custom.map((r) => (
              <Expandable
                key={r.id}
                flush
                testId={`custom-${r.name}`}
                head={
                  <span className="col" style={{ gap: 0 }}>
                    <span className="t-label">{`${r.name}`}</span>
                    <span className="muted">
                      {(r.permissions as string[]).length} permissions · {r.members} {r.members === 1 ? 'person' : 'people'}
                    </span>
                  </span>
                }
              >
                <div>
                  {perms(r.permissions as string[])}
                  {canManage && (
                    <div className="row mt-8" style={{ justifyContent: 'flex-end' }}>
                      <TextButton label="Edit" onClick={() => edit(r)} />
                      <TextButton label="Delete" danger onClick={() => remove(r)} />
                    </div>
                  )}
                </div>
              </Expandable>
            ))
          )}
        </SectionCard>
        <SectionCard title="Built-in roles">
          {(data.builtIn as Json[]).map((r) => {
            const info = roleInfo[`${r.role}`];
            const Icon = info?.[1];
            return (
              <Expandable
                key={r.role}
                flush
                head={
                  <>
                    {Icon && <Icon size={22} className="muted" aria-hidden />}
                    <span className="col" style={{ gap: 0 }}>
                      <span className="t-label">{info?.[0] ?? `${r.role}`}</span>
                      <span className="muted">{info?.[2] ?? ''}</span>
                    </span>
                  </>
                }
              >
                {perms(r.permissions as string[])}
              </Expandable>
            );
          })}
        </SectionCard>
      </div>
    </PageFrame>
  );
}

function RoleEditor({ role, catalog, close }: { role?: Json; catalog: Json[]; close: (v?: string) => void }) {
  const [name, setName] = useState<string>(role?.name ?? '');
  const [desc, setDesc] = useState<string>(role?.description ?? '');
  const [sel, setSel] = useState<Set<string>>(new Set((role?.permissions as string[] | undefined) ?? []));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const save = async () => {
    if (name.trim().length < 2) return setError('Give the role a name');
    if (sel.size === 0) return setError('Choose at least one permission');
    setBusy(true);
    setError(null);
    try {
      const body: Json = { name: name.trim(), permissions: [...sel], ...(desc.trim() ? { description: desc.trim() } : {}) };
      if (role == null) await api.createRole(body);
      else await api.updateRole(role.id, body);
      close(`${name.trim()} saved`);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const groups = new Map<string, Json[]>();
  for (const c of catalog) {
    const a = areaOf(`${c.key}`);
    groups.set(a, [...(groups.get(a) ?? []), c]);
  }

  return (
    <Dialog
      title={role == null ? 'New custom role' : `Edit ${role.name}`}
      size="wide"
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={busy ? null : () => close()} />
          <PrimaryButton label="Save" busy={busy} height={56} onClick={save} testId="save-role" />
        </>
      }
    >
      <div className="col gap-12">
        <TextField label="Role name" placeholder="Floor manager" value={name} onChange={setName} testId="role-name" />
        <TextField label="What they do (optional)" value={desc} onChange={setDesc} />
        <span className="muted" style={{ fontSize: 12 }}>
          Greyed-out permissions are not in your plan or are beyond your own access.
        </span>
        {[...groups.entries()].map(([g, items]) => (
          <div key={g}>
            <div className="t-overline mt-8">{g}</div>
            {items.map((c) => (
              <Check
                key={c.key}
                testId={`perm-${c.key}`}
                label={<span className={c.grantable === true ? '' : 'faint'}>{`${c.description}`}</span>}
                checked={sel.has(c.key)}
                onChange={
                  c.grantable === true
                    ? (v) =>
                        setSel((s) => {
                          const n = new Set(s);
                          if (v) n.add(c.key);
                          else n.delete(c.key);
                          return n;
                        })
                    : undefined
                }
              />
            ))}
          </div>
        ))}
        {error && (
          <span className="danger-text" data-testid="role-error">
            {error}
          </span>
        )}
      </div>
    </Dialog>
  );
}
