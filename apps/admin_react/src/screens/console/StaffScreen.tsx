import { useCallback, useEffect, useState, type ReactNode } from 'react';
import { ChevronDown, ChevronRight, ChevronUp, Copy, Globe, Hash, Lock, LockOpen, LogIn, MailCheck, UserPlus, UsersRound, Clock, type LucideIcon } from 'lucide-react';
import { api, errorText, type Json } from '../../api/client';
import { copyText } from '../../lib/download';
import { firstChar } from '../../lib/format';
import { digitsOnly, pinProblem } from '../../lib/pin';
import { useSession } from '../../state/auth';
import { LoadError } from '../../ui/async';
import { PageFrame, PrimaryButton, Radio, SecondaryButton, Select, Skeleton, StatusChip, SwitchRow, TextButton, TextField } from '../../ui/kit';
import { Dialog, openDialog, showDone } from '../../ui/overlay';
import { roleInfo, roleLabel } from './roles';

/** O5 Staff: who works here, their role, PIN and web portal access. The hub gets changes on its next pull (about a minute). */
export function StaffScreen() {
  const me = useSession();
  const canEdit = !!me?.can('staff.manage');
  const isOwner = !!me?.roles.includes('owner');
  const [staff, setStaff] = useState<Json[] | null>(null);
  const [limits, setLimits] = useState<Json | null>(null);
  const [customRoles, setCustomRoles] = useState<Json[]>([]);
  const [error, setError] = useState<unknown>(null);
  const [showDisabled, setShowDisabled] = useState(false);

  const load = useCallback(async () => {
    try {
      const [s, l, r] = await Promise.all([api.staff(), api.staffLimits(), api.restaurantRoles()]);
      setStaff(s);
      setLimits(l);
      setCustomRoles((r.custom ?? []) as Json[]);
      setError(null);
    } catch (e) {
      setError(e);
    }
  }, []);
  useEffect(() => void load(), [load]);

  /** Roles this person may hand out (the server checks again): admins never create admins. */
  const roles = () => {
    const extended = limits?.extendedRoles === true;
    return ['cashier', 'waiter', ...(extended ? ['chef'] : []), ...(extended && isOwner ? ['it_admin'] : []), ...(extended ? ['auditor'] : []), ...(limits?.customRoles === true && customRoles.length > 0 ? ['custom'] : [])];
  };

  const edit = async (u?: Json) => {
    const saved = await openDialog<string>((close) => <StaffEditor user={u} roles={roles()} customRoles={customRoles} limits={limits!} close={close} />);
    if (saved != null) {
      await load();
      showDone(saved);
    }
  };

  const setMyPin = async () => {
    if ((await openDialog<boolean>((close) => <MyPinDialog close={close} />)) === true) {
      await load();
      showDone('PIN saved — use it on the POS in about a minute');
    }
  };

  if (error != null) return <LoadError error={error} page="Staff" onRetry={load} />;
  if (staff == null || limits == null)
    return (
      <div className="page" style={{ maxWidth: 600 }}>
        <Skeleton h={72} />
        <Skeleton h={72} style={{ marginTop: 12 }} />
      </div>
    );

  const active = staff.filter((u) => u.status === 'active');
  const disabled = staff.filter((u) => u.status !== 'active');
  const byRole = new Map<string, number>();
  for (const u of active) byRole.set(roleLabel(u), (byRole.get(roleLabel(u)) ?? 0) + 1);
  const myId = me?.me.id;
  const mine = active.find((u) => u.id === myId);
  const limit = limits.employeeLimit as number | null | undefined;
  const used = (limits.activeEmployees as number | undefined) ?? 0;
  const full = limit != null && used >= limit;
  const noPlan = limits.planActive === false;
  const signInLink = `${window.location.origin}${window.location.pathname}#/login?mode=employee`;

  return (
    <PageFrame
      title="Staff"
      subtitle={`${active.length} ${active.length === 1 ? 'person' : 'people'} on the team${limit != null ? ` · ${used} of ${limit} employees in your plan` : ''}`}
      actions={canEdit && <PrimaryButton label="Add person" icon={UserPlus} height={48} testId="add-staff" onClick={full || noPlan ? null : () => edit()} />}
    >
      <div className="wrap">
        {[...byRole.entries()].map(([k, v]) => (
          <StatusChip key={k} label={`${v} · ${k}`} />
        ))}
      </div>
      {noPlan && canEdit && (
        <Notice testId="staff-no-plan" icon={Lock} title="No active plan" text={`People cannot be added or changed until your restaurant has an active plan. ${isOwner ? 'Ask BhojMitra to issue or renew your plan' : 'Ask the owner to renew the plan'}.`} />
      )}
      {full && !noPlan && canEdit && (
        <Notice testId="limit-reached" icon={UsersRound} title="Employee limit reached" text={`Your plan allows ${limit} active employees. Turn someone off, or ${isOwner ? 'ask BhojMitra for a bigger plan' : 'ask the owner about a bigger plan'}.`} />
      )}
      {limits.staffPortal !== true && (
        <Notice
          icon={Lock}
          title="Employee web portal is not in your plan"
          text={`Employees can use the POS with their PIN. For email + PIN web sign-in, ${isOwner ? 'ask the Super Admin to enable "Staff web portal (email + PIN)" in Plans, then sign in again' : 'ask the owner to enable a plan with the staff web portal'}.`}
        />
      )}
      {limits.staffPortal === true && canEdit && (
        <Notice
          testId="staff-portal-ready"
          icon={LogIn}
          title="Employee web sign-in"
          text="Add an email and turn on web access for each employee. They use that email and their PIN to sign in to their role’s web portal."
          action={<SecondaryButton label="Copy sign-in link" icon={Copy} testId="copy-staff-login" onClick={async () => (await copyText(signInLink)) && showDone('Employee sign-in link copied')} />}
        />
      )}
      {mine != null && mine.hasPin !== true && (
        <Notice
          testId="no-pin-banner"
          icon={Hash}
          title="You have no POS PIN yet"
          text="The POS asks everyone, including the owner, for a PIN. Set yours to sign in there."
          action={<PrimaryButton label="Set my PIN" icon={Hash} height={48} testId="set-my-pin" onClick={setMyPin} />}
        />
      )}
      <div className="card list mt-16">
        {active.map((u) => (
          <StaffRow key={u.id} user={u} onClick={u.id === myId ? setMyPin : canEdit && u.role !== 'owner' && (u.role !== 'it_admin' || isOwner) ? () => edit(u) : undefined} />
        ))}
      </div>
      {disabled.length > 0 && (
        <div className="mt-16">
          <TextButton label={`${disabled.length} turned off`} icon={showDisabled ? ChevronUp : ChevronDown} onClick={() => setShowDisabled(!showDisabled)} />
          {showDisabled && (
            <div className="card list mt-8">
              {disabled.map((u) => (
                <StaffRow key={u.id} user={u} onClick={canEdit ? () => edit(u) : undefined} />
              ))}
            </div>
          )}
        </div>
      )}
      <p className="muted mt-16" style={{ fontSize: 12 }}>
        PINs: 6 to 8 digits, not one digit repeated and not a run like 123456. Five wrong tries lock the account for 15 minutes.
      </p>
    </PageFrame>
  );
}

function Notice({ icon: Icon, title, text, action, testId }: { icon: LucideIcon; title: string; text: string; action?: ReactNode; testId?: string }) {
  return (
    <div className="card notice pad-16 mt-16 wrap gap-16" data-testid={testId}>
      <Icon size={22} className="accent-text" aria-hidden />
      <div style={{ maxWidth: 560, flex: '1 1 280px' }}>
        <div className="t-card">{title}</div>
        <div className="muted mt-4">{text}</div>
      </div>
      {action}
    </div>
  );
}

function StaffRow({ user, onClick }: { user: Json; onClick?: () => void }) {
  const off = user.status !== 'active';
  return (
    <div
      className={`list-row row-chips${onClick ? ' click' : ''}`}
      data-testid={`staff-${user.name}`}
      role={onClick ? 'button' : undefined}
      tabIndex={onClick ? 0 : undefined}
      onClick={onClick}
      onKeyDown={(e) => onClick && e.key === 'Enter' && onClick()}
      style={{ borderRadius: 0 }}
    >
      <span className="avatar" style={{ width: 44, height: 44, fontSize: 18, background: off ? 'var(--raised)' : 'color-mix(in srgb, var(--highlight) 20%, transparent)', color: off ? 'var(--faint)' : 'var(--accent-ink)' }}>
        {firstChar(user.name)}
      </span>
      <div className="grow">
        <div className={`t-label${off ? ' faint' : ''}`}>{`${user.name}`}</div>
        <div className="muted ellipsis">{[roleLabel(user), user.email != null ? `${user.email}` : null, user.canDiscount === true ? 'can give discounts' : null].filter(Boolean).join(' · ')}</div>
      </div>
      <div className="wrap chips" style={{ gap: 4, justifyContent: 'flex-end' }}>
        {user.locked === true && <StatusChip label="Locked" tone="danger" icon={Clock} />}
        {!off && user.webAccess === true && <StatusChip label="Web" icon={Globe} />}
        {off ? <StatusChip label="Off" tone="danger" /> : user.hasPin === true ? <StatusChip label="PIN set" tone="success" /> : <StatusChip label="No PIN" tone="saffron" />}
      </div>
      {onClick && <ChevronRight size={20} aria-hidden />}
    </div>
  );
}

function StaffEditor({ user, roles, customRoles, limits, close }: { user?: Json; roles: string[]; customRoles: Json[]; limits: Json; close: (v?: string) => void }) {
  const isNew = user == null;
  const portalInPlan = limits.staffPortal === true;
  const [name, setName] = useState<string>(user?.name ?? '');
  const [email, setEmail] = useState<string>(user?.email ?? '');
  const [phone, setPhone] = useState<string>(user?.phone ?? '');
  const [pin, setPin] = useState('');
  const [password, setPassword] = useState('');
  const [role, setRole] = useState<string>(user?.role ?? 'waiter');
  const [customRoleId, setCustomRoleId] = useState<string | null>(user?.customRoleId ?? customRoles[0]?.id ?? null);
  const [canDiscount, setCanDiscount] = useState<boolean>(user?.canDiscount ?? false);
  const [webAccess, setWebAccess] = useState<boolean>(user?.webAccess ?? false);
  const [active, setActive] = useState<boolean>(user == null || user.status === 'active');
  // for now the owner / admin sets the PIN and the person is active at once — no invite email to wait for
  // (the server still supports sendInvite; set OFFER_INVITE to bring the email option back)
  const OFFER_INVITE = false;
  const [invite, setInvite] = useState(false);
  const [consoleLogin, setConsoleLogin] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const save = async () => {
    const p = pin.trim();
    if (!name.trim()) return setError('Enter a name');
    if (!email.trim().includes('@')) return setError('Enter their work email');
    const setPinNow = !isNew || !invite;
    if (setPinNow && (p !== '' || isNew)) {
      const problem = pinProblem(p);
      if (problem) return setError(problem);
    }
    if (consoleLogin && password.length < 8) return setError('Console password needs 8+ characters');
    if (role === 'custom' && customRoleId == null) return setError('Choose the custom role');
    setBusy(true);
    setError(null);
    try {
      let done: string;
      if (isNew) {
        const r = await api.createStaff({
          name: name.trim(),
          email: email.trim(),
          role,
          canDiscount: role === 'cashier' && canDiscount,
          status: active ? 'active' : 'disabled',
          webAccess,
          ...(role === 'custom' ? { customRoleId } : {}),
          ...(phone.trim() ? { phone: phone.trim() } : {}),
          ...(invite ? { sendInvite: true } : { pin: p }),
          ...(consoleLogin ? { password } : {}),
        });
        const inv = r.invite as Json | undefined;
        done = inv == null ? `${name.trim()} added — they can use the POS in about a minute` : inv.emailSent === true ? `Invite sent to ${email.trim()} — they choose their own PIN` : `Added, but the email failed. Send them this link: ${inv.url}`;
      } else {
        await api.updateStaff(user!.id, {
          name: name.trim(),
          email: email.trim(),
          phone: phone.trim() === '' ? null : phone.trim(),
          ...(user!.role !== 'owner' ? { role, canDiscount: role === 'cashier' && canDiscount, webAccess, status: active ? 'active' : 'disabled', ...(role === 'custom' ? { customRoleId } : {}) } : {}),
          ...(p ? { pin: p } : {}),
        });
        done = 'Saved';
      }
      close(done);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const sendLink = async () => {
    setBusy(true);
    try {
      const r = await api.staffPinLink(user!.id);
      close(r.emailSent === true ? `PIN link emailed to ${user!.email}` : `Email failed. Send them this link: ${r.url}`);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const unlock = async () => {
    try {
      await api.staffUnlock(user!.id);
      close(`${user!.name} can sign in again`);
    } catch (e) {
      setError(errorText(e));
    }
  };

  const roleList = [...new Set([...roles, ...(isNew ? [] : [role])])];
  return (
    <Dialog
      title={isNew ? 'Add a person' : `Edit ${user!.name}`}
      size="wide"
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={busy ? null : () => close()} />
          <PrimaryButton label={isNew && invite ? 'Add & send invite' : 'Save'} busy={busy} height={56} onClick={save} testId="save-staff" />
        </>
      }
    >
      <div className="col gap-12">
        <TextField label="Full name" value={name} onChange={setName} autoFocus={isNew} testId="staff-name" />
        <TextField label="Work email" type="email" value={email} onChange={setEmail} testId="staff-email" />
        <TextField label="Phone (optional)" type="tel" value={phone} onChange={setPhone} />
        <div className="t-overline mt-8">Role</div>
        <div>
          {roleList.map((r) => (
            <Radio key={r} name="staff-role" testId={`role-${r}`} value={r} current={role} onChange={setRole} label={roleInfo[r]?.[0] ?? r} sub={roleInfo[r]?.[2] ?? ''} icon={roleInfo[r]?.[1]} />
          ))}
        </div>
        {role === 'custom' && <Select<string | null> label="Which custom role" testId="custom-role" value={customRoleId} options={customRoles.map((r) => [r.id as string, `${r.name}`])} onChange={setCustomRoleId} />}
        {role === 'cashier' && <SwitchRow title="Can give discounts" checked={canDiscount} onChange={setCanDiscount} />}
        <div className="t-overline mt-8">PIN</div>
        {isNew && OFFER_INVITE && (
          <div>
            <Radio name="pin-mode" testId="pin-invite" value={true} current={invite} onChange={setInvite} label="Email an invite — they choose their own PIN (recommended)" />
            <Radio name="pin-mode" testId="pin-now" value={false} current={invite} onChange={setInvite} label="Set a PIN now and tell them in person" />
          </div>
        )}
        {(!isNew || !invite) && (
          <TextField
            label={isNew ? 'PIN (6 to 8 digits, e.g. 246813)' : 'New PIN (leave empty to keep)'}
            type="password"
            inputMode="numeric"
            maxLength={8}
            value={pin}
            onChange={(v) => setPin(digitsOnly(v))}
            prefix={<Hash size={18} />}
            testId="staff-pin"
          />
        )}
        {!isNew && user!.email != null && (
          <div className="wrap">
            <TextButton label="Email a PIN reset link" icon={MailCheck} testId="send-pin-link" onClick={busy ? null : sendLink} />
            {user!.locked === true && <TextButton label="Unlock" icon={LockOpen} testId="unlock" onClick={unlock} />}
          </div>
        )}
        {user?.role !== 'owner' && (
          <>
            <SwitchRow title="Can sign in to the web portal" sub={portalInPlan ? 'With their work email and PIN' : 'Not in your plan'} checked={webAccess && portalInPlan} onChange={portalInPlan ? setWebAccess : undefined} testId="web-access" />
            <SwitchRow title="Active" sub="Turned-off people cannot sign in anywhere" checked={active} onChange={setActive} testId="staff-active" />
          </>
        )}
        {isNew && role === 'it_admin' && (
          <>
            <SwitchRow title="Also a console password" checked={consoleLogin} onChange={setConsoleLogin} />
            {consoleLogin && <TextField label="Password (8+ characters)" type="password" value={password} onChange={setPassword} />}
          </>
        )}
        {error && (
          <span className="danger-text" data-testid="staff-error">
            {error}
          </span>
        )}
      </div>
    </Dialog>
  );
}

function MyPinDialog({ close }: { close: (v?: boolean) => void }) {
  const [pin, setPin] = useState('');
  const [again, setAgain] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const save = async () => {
    const p = pin.trim();
    const problem = pinProblem(p);
    if (problem) return setError(problem);
    if (p !== again.trim()) return setError('The two PINs do not match');
    setBusy(true);
    setError(null);
    try {
      await api.setMyPin(p);
      close(true);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };
  return (
    <Dialog
      title="Your POS PIN"
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={() => close()} />
          <PrimaryButton label="Save PIN" busy={busy} height={56} onClick={save} testId="save-my-pin" />
        </>
      }
    >
      <div className="col gap-12">
        <span className="muted">6 to 8 digits. You enter it on the POS after tapping your name.</span>
        <TextField label="New PIN" type="password" inputMode="numeric" maxLength={8} autoFocus value={pin} onChange={(v) => setPin(digitsOnly(v))} testId="my-pin" />
        <TextField label="Type it again" type="password" inputMode="numeric" maxLength={8} value={again} onChange={(v) => setAgain(digitsOnly(v))} onEnter={save} testId="my-pin-again" />
        {error && <span className="danger-text">{error}</span>}
      </div>
    </Dialog>
  );
}
