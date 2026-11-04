import { useState, type CSSProperties } from 'react';
import { Ban, CheckCircle2, Copy, Eye, EyeOff, Forward, MailWarning, Send, Timer, Award, AlertCircle, type LucideIcon } from 'lucide-react';
import { api, ApiException, type Json } from '../../api/client';
import { agoShort, expiresIn, wholeRupees } from '../../lib/format';
import { copyText } from '../../lib/download';
import { activePlans, useCached } from '../../state/app';
import { useAsync } from '../../ui/async';
import { Chip, EmptyState, ErrorState, IconButton, LoadingState, PrimaryButton, SearchField, SecondaryButton, Segmented, Select, StatusChip, TextButton, TextField } from '../../ui/kit';
import { askReason, Dialog, openDialog, showDone, showError } from '../../ui/overlay';

/** Shown when the email provider refused the message: the Super Admin passes the link on another way. */
export function showActivationLinkDialog(r: Json) {
  return openDialog<void>((close) => (
    <Dialog title="Email not delivered" actions={<PrimaryButton label="Done" height={52} onClick={() => close()} />}>
      <div className="col gap-12">
        <span>The email provider said: {`${r.emailError}`}</span>
        <span className="muted">Send the owner this activation link yourself (valid 72 hours):</span>
        <div className="t-mono" data-testid="verify-link" style={{ padding: 12, borderRadius: 12, background: 'var(--raised)', userSelect: 'all', overflowWrap: 'anywhere' }}>
          {`${r.verifyUrl}`}
        </div>
        <div>
          <TextButton label="Copy link" icon={Copy} onClick={async () => (await copyText(`${r.verifyUrl}`)) && showDone('Link copied')} />
        </div>
      </div>
    </Dialog>
  ));
}

const gstinRe = /^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/;

/** P5 Register restaurant → sends the owner a verification email; the tenant exists only after verification. */
export function RegisterRestaurantDialog({ close }: { close: (v?: boolean) => void }) {
  const [f, setF] = useState({ ownerEmail: '', ownerName: '', restaurantName: '', gstin: '', address: '', password: '' });
  const [errs, setErrs] = useState<Record<string, string>>({});
  const [cycle, setCycle] = useState<'monthly' | 'yearly'>('monthly'); // every plan is priced in this cycle
  const [plan, setPlan] = useState('standard');
  const [busy, setBusy] = useState(false);
  const [show, setShow] = useState(false);
  const plans = [...(useCached(activePlans) ?? [])].sort((a, b) => (a.tier ?? 999) - (b.tier ?? 999));
  const codes = plans.map((p) => p.code as string);
  const chosen = codes.includes(plan) ? plan : codes[0] ?? plan;
  const set = (k: keyof typeof f) => (v: string) => setF({ ...f, [k]: v });
  const hasPassword = f.password.trim().length > 0;
  // every option in the same cycle so the prices compare like for like
  const price = (p: Json) => `${wholeRupees(cycle === 'yearly' ? p.yearlyPricePaise ?? p.pricePaise * 10 : p.pricePaise)} / ${cycle === 'yearly' ? 'year' : 'month'}`;

  const submit = async () => {
    const e: Record<string, string> = {};
    if (!f.ownerEmail.includes('@')) e.ownerEmail = 'Valid email required';
    if (!f.ownerName.trim()) e.ownerName = 'Required';
    if (!f.restaurantName.trim()) e.restaurantName = 'Required';
    if (f.password && f.password.length < 8) e.password = 'Minimum 8 characters';
    if (f.gstin.trim() && !gstinRe.test(f.gstin.trim().toUpperCase())) e.gstin = 'Not a valid GSTIN';
    setErrs(e);
    if (Object.keys(e).length) return;
    setBusy(true);
    try {
      const pwd = f.password.trim();
      const r = await api.registerRestaurant({
        ownerEmail: f.ownerEmail.trim(),
        ownerName: f.ownerName.trim(),
        restaurantName: f.restaurantName.trim(),
        ...(f.gstin.trim() ? { gstin: f.gstin.trim().toUpperCase() } : {}),
        ...(f.address.trim() ? { address: f.address.trim() } : {}),
        planCode: chosen,
        billingCycle: cycle,
        ...(pwd ? { password: pwd } : {}),
      });
      if (r.status === 'active') {
        showDone(`Restaurant ${r.restaurantCode ?? ''} created & activated! Owner can sign in immediately.`);
        return close(true);
      }
      if (r.emailSent === false) {
        // e.g. Resend sandbox: only the account's own address receives mail until a domain is verified
        await showActivationLinkDialog(r);
        return close(true);
      }
      showDone(`Verification email sent to ${f.ownerEmail.trim()}`);
      close(true);
    } catch (err) {
      if (err instanceof ApiException) showError(err);
      else showError(err);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Dialog
      title="Register restaurant"
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={() => close()} />
          <PrimaryButton label={hasPassword ? 'Create & activate' : 'Send verification'} height={56} busy={busy} onClick={submit} testId="register-submit" />
        </>
      }
    >
      <div className="col gap-12">
        <TextField label="Owner email" type="email" value={f.ownerEmail} onChange={set('ownerEmail')} error={errs.ownerEmail} testId="register-email" />
        <TextField label="Owner name" value={f.ownerName} onChange={set('ownerName')} error={errs.ownerName} testId="register-owner" />
        <TextField label="Restaurant name" value={f.restaurantName} onChange={set('restaurantName')} error={errs.restaurantName} testId="register-name" />
        <TextField
          label="Owner password (optional)"
          type={show ? 'text' : 'password'}
          value={f.password}
          onChange={set('password')}
          error={errs.password}
          help="Set now to activate immediately without email verification"
          testId="register-password"
          suffix={<IconButton title={show ? 'Hide password' : 'Show password'} icon={show ? EyeOff : Eye} sm testId="register-show-password" onClick={() => setShow(!show)} />}
        />
        <TextField label="GSTIN (optional)" value={f.gstin} onChange={set('gstin')} error={errs.gstin} upper />
        <TextField label="Address (optional)" value={f.address} onChange={set('address')} />
        <div>
          <Segmented<'monthly' | 'yearly'>
            testId="register-cycle"
            value={cycle}
            options={[
              ['monthly', 'Pay monthly'],
              ['yearly', 'Pay yearly'],
            ]}
            onChange={setCycle}
          />
        </div>
        <Select label="Plan" testId="register-plan" value={codes.length ? chosen : null} options={plans.map((p) => [p.code as string, `${p.name} · ${price(p)}`])} onChange={(v) => v && setPlan(v)} />
      </div>
    </Dialog>
  );
}

const regStates: [string, string][] = [
  ['awaiting', 'Awaiting'],
  ['expired', 'Link expired'],
  ['cancelled', 'Cancelled'],
  ['all', 'All'],
];

/** Registrations waiting for the owner to confirm their email: resend a fresh link, activate without email, or cancel. */
export function PendingRegistrations({ canAct, reloadKey }: { canAct: boolean; reloadKey: number }) {
  const [state, setState] = useState('awaiting');
  const [q, setQ] = useState('');
  const [n, setN] = useState(0);
  const [busy, setBusy] = useState<Set<string>>(new Set());
  const { data, error, reload } = useAsync(() => api.registrations(state, q), [state, q, n, reloadKey]);

  const activate = async (r: Json) => {
    const pw = await openDialog<string>((close) => <ActivateDialog name={`${r.restaurantName}`} close={close} />);
    if (pw == null) return;
    try {
      await api.activateRegistration(r.id, pw);
      setN((x) => x + 1);
      showDone('Restaurant active. Owner can sign in with email and password.');
    } catch (e) {
      showError(e);
    }
  };

  const resend = async (r: Json) => {
    setBusy((s) => new Set(s).add(r.id));
    try {
      const res = await api.resendVerification(r.id);
      setBusy((s) => (s.delete(r.id), new Set(s))); // stop the spinner before any dialog opens
      if (res.emailSent === false) await showActivationLinkDialog(res);
      else showDone(`New link sent to ${r.ownerEmail}`);
      setN((x) => x + 1);
    } catch (e) {
      showError(e);
    } finally {
      setBusy((s) => (s.delete(r.id), new Set(s)));
    }
  };

  const cancel = async (r: Json) => {
    const reason = await askReason({ title: `Cancel ${r.restaurantName}?`, confirmLabel: 'Cancel registration', message: 'The activation link stops working. You can register the restaurant again later.' });
    if (reason == null) return;
    try {
      await api.cancelRegistration(r.id, reason);
      showDone('Registration cancelled');
      setN((x) => x + 1);
    } catch (e) {
      showError(e);
    }
  };

  const items = (data?.items ?? []) as Json[];
  return (
    <div className="col gap-16">
      <div className="wrap">
        {regStates.map(([k, l]) => (
          <Chip key={k} testId={`reg-${k}`} label={l} on={state === k} onClick={() => setState(k)} />
        ))}
        <div style={{ width: 260, maxWidth: '100%' }}>
          <SearchField hint="Restaurant or owner email" onChange={(v) => setQ(v.trim())} />
        </div>
      </div>
      {error ? (
        <ErrorState message={`${(error as Error).message ?? error}`} onRetry={reload} />
      ) : !data ? (
        <LoadingState />
      ) : items.length === 0 ? (
        <EmptyState title={state === 'awaiting' ? 'Nobody is waiting to verify' : 'Nothing here'} />
      ) : (
        <div className="col gap-12">
          {items.map((r) => (
            <div key={r.id} className="card pad-16" data-testid={`registration-${r.restaurantName}`}>
              <div className="row-top gap-12">
                <span className="icon-tile tone-pending" style={{ background: 'color-mix(in srgb, var(--pending) 14%, transparent)', color: 'var(--pending)' }}>
                  <MailWarning size={22} aria-hidden />
                </span>
                <div className="grow">
                  <div className="t-card">{`${r.restaurantName}`}</div>
                  <div className="muted ellipsis">
                    {`${r.ownerName}`} · {`${r.ownerEmail}`}
                  </div>
                </div>
                <StatusChip label={r.state === 'expired' ? 'Link expired' : r.state === 'cancelled' ? 'Cancelled' : 'Awaiting owner'} tone={r.state === 'expired' ? 'saffron' : r.state === 'cancelled' ? 'danger' : 'pending'} />
              </div>
              <div className="wrap mt-12" style={{ gap: '4px 16px' }}>
                <Fact icon={Award} text={`${r.planName}`} />
                <Fact icon={Send} text={`Sent ${agoShort(r.lastSentAt ?? r.createdAt)}${(r.sendCount ?? 1) > 1 ? ` · ${r.sendCount}×` : ''}`} />
                {r.state !== 'cancelled' && <Fact icon={Timer} text={expiresIn(r.expiresAt)} />}
                {r.cancelReason != null && <Fact icon={Ban} text={`Cancelled: ${r.cancelReason}`} />}
              </div>
              {r.lastEmailError != null && r.state !== 'cancelled' && (
                <div className="callout mt-12">
                  <AlertCircle size={18} color="var(--danger)" aria-hidden />
                  <span style={{ fontSize: 13 }}>Last email not delivered: {`${r.lastEmailError}`}</span>
                </div>
              )}
              {canAct && r.state !== 'cancelled' && (
                <div className="wrap mt-12">
                  <div style={{ width: 200 } as CSSProperties}>
                    <PrimaryButton label={r.state === 'expired' ? 'Send a new link' : 'Resend email'} icon={Forward} height={44} block busy={busy.has(r.id)} onClick={() => resend(r)} testId={`resend-${r.restaurantName}`} />
                  </div>
                  <TextButton label="Activate without email" icon={CheckCircle2} onClick={() => activate(r)} />
                  <SecondaryButton label="Cancel" height={44} onClick={() => cancel(r)} testId={`cancel-${r.restaurantName}`} />
                </div>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function ActivateDialog({ name, close }: { name: string; close: (v?: string) => void }) {
  const [pw, setPw] = useState('');
  return (
    <Dialog
      title={`Activate ${name}`}
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={() => close()} />
          <PrimaryButton label="Activate" onClick={() => pw.length >= 12 && close(pw)} />
        </>
      }
    >
      <TextField label="Owner password" type="password" value={pw} onChange={setPw} autoFocus help="At least 12 characters. No email required." />
    </Dialog>
  );
}

function Fact({ icon: Icon, text }: { icon: LucideIcon; text: string }) {
  return (
    <span className="row muted gap-4" style={{ gap: 6 }}>
      <Icon size={16} aria-hidden />
      {text}
    </span>
  );
}
