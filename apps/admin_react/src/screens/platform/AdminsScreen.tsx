import { useEffect, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { Eye, EyeOff, MoreVertical, RefreshCw, UserCog, UserPlus } from 'lucide-react';
import { api, ApiException, type Json } from '../../api/client';
import { permissionLabel, statusWord, titleCase, toneForStatus } from '../../lib/labels';
import { auth, useSession } from '../../state/auth';
import { adminRoles } from '../../state/app';
import { AsyncView } from '../../ui/async';
import { Chip, EmptyState, IconButton, MenuButton, PrimaryButton, SearchField, SecondaryButton, StatusChip, TextField } from '../../ui/kit';
import { askReason, askStepUp, Dialog, openDialog, showDone, showError } from '../../ui/overlay';

const statuses: [string | null, string][] = [
  [null, 'All'],
  ['active', 'Active'],
  ['invited', 'Invited'],
  ['disabled', 'Deactivated'],
];

/**
 * P9 Platform admins (direct creation, pending invite activation, roles, deactivate, remove) and P10 MFA reset.
 * ?role= (from the sidebar's Admins sub-menu) shows only that admin type; the status filter sits on top.
 */
export function AdminsScreen() {
  const [params] = useSearchParams();
  const role = params.get('role');
  const me = useSession();
  const can = (p: string) => !!me?.can(p);
  const myId = me?.me.id;
  const isSuperAdmin = !!me?.roles.includes('Super Admin');
  const [status, setStatus] = useState<string | null>(null);
  const [q, setQ] = useState('');
  const [n, setN] = useState(0);

  const reload = () => {
    adminRoles.invalidate();
    setN((x) => x + 1);
  };
  // statuses change when an invited admin accepts: refresh every 30 s
  useEffect(() => {
    const t = setInterval(() => setN((x) => x + 1), 30000);
    return () => clearInterval(t);
  }, []);

  const add = async (pending?: Json) => {
    const ok = await openDialog<boolean>((close) => <AdminCredentialsDialog pending={pending} close={close} />);
    if (ok !== true) return;
    reload();
    showDone(`Admin ${pending == null ? 'created' : 'activated'} — sign in with email and password`);
  };

  /** Turn MFA on/off: warning → reason → step-up (own password + TOTP) → change; the server audits. */
  const setMfa = async (admin: Json) => {
    const enabled = admin.mfaEnabled === false;
    const reason = await askReason({
      title: `${enabled ? 'Turn on' : 'Turn off'} MFA for ${admin.name}?`,
      confirmLabel: 'Continue',
      message: enabled
        ? 'This account will need an authenticator at sign-in. If one is already set up, it will be used. Existing sessions will end.'
        : 'This account will sign in with email and password without an authenticator code. Existing sessions will end.',
    });
    if (reason == null) return;
    const step = await askStepUp(me?.me.mfaEnabled !== false);
    if (!step) return;
    try {
      const token = await api.stepUp(step[0], step[1]);
      await api.setAdminMfa(admin.id, enabled, reason, token);
      if (admin.id === myId) await auth.logout();
      else {
        reload();
        showDone(`MFA ${enabled ? 'on' : 'off'} for ${admin.name} — they must sign in again`);
      }
    } catch (e) {
      showError(e);
    }
  };

  /** P10: warning → reason → step-up → reset; the server audits and notifies. */
  const resetMfa = async (a: Json) => {
    const reason = await askReason({
      title: `Reset MFA for ${a.name}`,
      confirmLabel: 'Continue',
      message: `${a.email} will be signed out everywhere and must enrol a new authenticator at next sign-in. They will be notified. Only do this after verifying their identity.`,
    });
    if (reason == null) return;
    const step = await askStepUp(me?.me.mfaEnabled !== false);
    if (!step) return;
    try {
      const token = await api.stepUp(step[0], step[1]);
      const r = await api.resetMfa(a.id, reason, token);
      showDone(`MFA reset — notification sent to ${r.notified}`);
      reload();
    } catch (e) {
      showError(e);
    }
  };

  const editRoles = async (a: Json, roles: Json[]) => {
    const picked = await openDialog<string[]>((close) => <RolePicker roles={roles} initial={(a.roles as Json[]).map((r) => r.id as string)} title={`Roles for ${a.name}`} close={close} />);
    if (!picked) return;
    try {
      await api.setRoles(a.id, picked);
      reload();
    } catch (e) {
      showError(e);
    }
  };

  const deactivate = async (a: Json) => {
    const reason = await askReason({ title: `Deactivate ${a.name}`, confirmLabel: 'Deactivate' });
    if (reason == null) return;
    try {
      await api.deactivate(a.id, reason);
      reload();
    } catch (e) {
      showError(e);
    }
  };

  const remove = async (a: Json) => {
    const reason = await askReason({
      title: `Remove admin ${a.name}?`,
      confirmLabel: 'Remove admin',
      message: 'This platform admin will be removed from the platform and their active sessions revoked. A full audit log is recorded.',
    });
    if (reason == null) return;
    try {
      await api.deleteAdmin(a.id, reason);
      reload();
      showDone(`Admin ${a.name} removed`);
    } catch (e) {
      showError(e);
    }
  };

  return (
    <AsyncView deps={[n]} load={() => Promise.all([api.admins(), api.roles()])}>
      {([all, roles]) => {
        const ofRole = all.filter((a) => role == null || (a.roles as Json[]).some((r) => r.name === role));
        const needle = q.trim().toLowerCase();
        const admins = ofRole.filter((a) => (status == null || a.status === status) && (needle === '' || `${a.name} ${a.email}`.toLowerCase().includes(needle)));
        const count = (s: string | null) => ofRole.filter((a) => s == null || a.status === s).length;
        return (
          <div className="page page-enter">
            <div className="between">
              <h1 className="t-screen" data-testid="admins-title">
                {role ?? 'Platform admins'}
              </h1>
              {/* actions grouped on the right: refresh sits beside Add admin */}
              <div className="wrap">
                <SecondaryButton label="Refresh" icon={RefreshCw} height={52} onClick={reload} testId="refresh-admins" />
                {can('platform.admin.invite') && <PrimaryButton label="Add admin" icon={UserPlus} height={52} onClick={() => add()} testId="add-platform-admin" />}
              </div>
            </div>
            <div className="wrap mt-16" style={{ gap: 12 }}>
              <div style={{ width: 320, maxWidth: '100%' }}>
                <SearchField hint="Search name or email" onChange={setQ} testId="admin-search" />
              </div>
            </div>
            <div className="wrap mt-12" data-testid="admin-status-filter">
              {statuses.map(([v, l]) => (
                <Chip key={l} testId={`admin-status-${v ?? 'all'}`} label={`${l} (${count(v)})`} on={status === v} onClick={() => setStatus(v)} />
              ))}
            </div>
            <p className="muted mt-12">
              {role == null
                ? 'Add an admin with a name, email and password. For an Invited account, open its Actions menu and choose Set password & activate.'
                : `Showing admins with the ${role} role. Choose All under Admins in the sidebar to see everyone.`}
            </p>
            <div className="mt-16">
              {admins.length === 0 ? (
                <EmptyState
                  testId="admins-empty"
                  icon={UserCog}
                  title="No admins here"
                  message={needle !== '' ? `Nobody matches “${q.trim()}”.` : status == null ? `Nobody has the ${role} role yet.` : `No ${statusWord(status)} admins${role == null ? '' : ` with the ${role} role`}.`}
                />
              ) : (
                <div className="card list">
                  {admins.map((a) => (
                    <div key={a.id} className="list-row" data-testid={`admin-${a.email}`}>
                      <div className="grow">
                        <div className="t-label">{`${a.name}`}</div>
                        <div className="muted ellipsis">
                          {`${a.email}`} · {(a.roles as Json[]).map((r) => r.name).join(', ')}
                        </div>
                        <div className="wrap mt-8" style={{ gap: '4px 8px' }}>
                          <StatusChip label={titleCase(statusWord(a.status))} tone={toneForStatus(a.status)} />
                          <StatusChip
                            label={a.mfaEnabled === false ? 'MFA off' : a.mfaEnrolled === true ? 'MFA on' : 'MFA on · Setup needed'}
                            tone={a.mfaEnabled !== false && a.mfaEnrolled === true ? 'success' : 'saffron'}
                          />
                        </div>
                      </div>
                      {(a.id !== myId || isSuperAdmin) && (
                        <MenuButton
                          title="Actions"
                          icon={MoreVertical}
                          testId={`admin-actions-${a.email}`}
                          items={[
                            isSuperAdmin && { label: a.mfaEnabled === false ? 'Turn MFA on' : 'Turn MFA off', onClick: () => setMfa(a) },
                            can('platform.admin.invite') && a.status === 'invited' && { label: 'Set password & activate', onClick: () => add(a) },
                            a.id !== myId && can('platform.admin.roles') && { label: 'Edit roles', onClick: () => editRoles(a, roles) },
                            a.id !== myId && can('platform.mfa.reset') && a.mfaEnrolled === true && { label: 'Reset MFA…', onClick: () => resetMfa(a) },
                            a.id !== myId && can('platform.admin.deactivate') && a.status === 'active' && { label: 'Deactivate…', onClick: () => deactivate(a) },
                            a.id !== myId && (can('platform.admin.deactivate') || isSuperAdmin) && a.status !== 'deleted' && { label: 'Remove admin (Delete)…', danger: true, onClick: () => remove(a) },
                          ]}
                        />
                      )}
                    </div>
                  ))}
                </div>
              )}
            </div>
          </div>
        );
      }}
    </AsyncView>
  );
}

function AdminCredentialsDialog({ pending, close }: { pending?: Json; close: (v?: boolean) => void }) {
  const activating = pending != null;
  const [name, setName] = useState<string>(pending?.name ?? '');
  const [email, setEmail] = useState<string>(pending?.email ?? '');
  const [password, setPassword] = useState('');
  const [show, setShow] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [errs, setErrs] = useState<Record<string, string>>({});

  const save = async () => {
    if (busy) return;
    const e: Record<string, string> = {};
    if (!name.trim()) e.name = 'Enter the admin’s name';
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())) e.email = 'Enter a valid email';
    if (password.length < 12) e.password = 'Use at least 12 characters';
    setErrs(e);
    if (Object.keys(e).length) return;
    setBusy(true);
    setError(null);
    try {
      if (activating) await api.activateAdmin(pending!.id, password);
      else await api.createAdmin(email.trim(), name.trim(), password);
      close(true);
    } catch (err) {
      setError(err instanceof ApiException ? err.message : 'Cannot reach the server. Check your connection and try again.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <Dialog
      title={activating ? 'Activate platform admin' : 'Add platform admin'}
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={busy ? null : () => close()} />
          <PrimaryButton label={activating ? 'Activate admin' : 'Create admin'} height={56} busy={busy} onClick={save} testId="save-platform-admin" />
        </>
      }
    >
      <div className="col gap-12">
        <span className="muted">
          {activating ? 'Set a password to activate this existing account. Its assigned roles are kept.' : 'The account is active immediately with the Onboarding Admin role. You can change roles from its Actions menu.'}
        </span>
        <TextField label="Name" value={name} onChange={setName} readOnly={activating} disabled={busy} maxLength={120} error={errs.name} testId="new-admin-name" />
        <TextField label="Email" type="email" value={email} onChange={setEmail} readOnly={activating} disabled={busy} error={errs.email} testId="new-admin-email" />
        <TextField
          label="Password"
          type={show ? 'text' : 'password'}
          value={password}
          onChange={setPassword}
          disabled={busy}
          maxLength={256}
          help="At least 12 characters"
          error={errs.password}
          onEnter={save}
          testId="new-admin-password"
          suffix={<IconButton title={show ? 'Hide password' : 'Show password'} icon={show ? EyeOff : Eye} sm onClick={() => setShow(!show)} />}
        />
        <span className="muted">Share the password with the admin securely. When MFA is on, their first sign-in includes authenticator setup.</span>
        {error && (
          <span className="danger-text" data-testid="admin-create-error">
            {error}
          </span>
        )}
      </div>
    </Dialog>
  );
}

/** "Roles for …": each role with what it is for and every permission as a readable chip. */
function RolePicker({ roles, initial, title, close }: { roles: Json[]; initial: string[]; title: string; close: (v?: string[]) => void }) {
  const [sel, setSel] = useState<Set<string>>(new Set(initial));
  const toggle = (id: string) =>
    setSel((s) => {
      const n = new Set(s);
      if (n.has(id)) n.delete(id);
      else n.add(id);
      return n;
    });
  return (
    <Dialog
      title={title}
      size="wide"
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={() => close()} />
          <PrimaryButton label="Save" height={56} onClick={sel.size === 0 ? null : () => close([...sel])} testId="save-roles" />
        </>
      }
    >
      <div className="col gap-12">
        {roles.map((r) => {
          const on = sel.has(r.id);
          return (
            <div
              key={r.id}
              data-testid={`role-option-${r.name}`}
              role="checkbox"
              aria-checked={on}
              tabIndex={0}
              onClick={() => toggle(r.id)}
              onKeyDown={(e) => (e.key === ' ' || e.key === 'Enter') && (e.preventDefault(), toggle(r.id))}
              className="row-top"
              style={{
                padding: 12,
                borderRadius: 12,
                cursor: 'pointer',
                border: `${on ? 1.5 : 1}px solid ${on ? 'var(--brand)' : 'var(--line)'}`,
                background: on ? 'color-mix(in srgb, var(--brand) 6%, var(--surface))' : 'var(--surface)',
              }}
            >
              <div className="grow">
                <div className="t-card" style={{ fontSize: 16 }}>
                  {`${r.name}`}
                </div>
                {r.description && (
                  <div className="muted mt-4" style={{ fontSize: 13.5 }}>
                    {`${r.description}`}
                  </div>
                )}
                <div className="t-overline mt-8">Can</div>
                <div className="wrap mt-4" style={{ gap: 6 }}>
                  {(r.permissions as string[]).map((p) => (
                    <span key={p} style={{ padding: '3px 8px', borderRadius: 6, background: 'var(--ground)', border: '1px solid var(--line)', fontSize: 12.5 }}>
                      {permissionLabel(p)}
                    </span>
                  ))}
                </div>
              </div>
              <input type="checkbox" checked={on} readOnly tabIndex={-1} style={{ width: 18, height: 18, accentColor: 'var(--accent)' }} />
            </div>
          );
        })}
      </div>
    </Dialog>
  );
}
