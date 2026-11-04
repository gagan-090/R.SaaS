import { useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { Check, Circle, Eye, EyeOff, Link2Off, LogIn } from 'lucide-react';
import { api, ApiException, type Json } from '../../api/client';
import { EmptyState, IconButton, PrimaryButton, TextField } from '../../ui/kit';
import { AuthFrame } from './AuthFrame';

const minLength = 8;

/**
 * Opened from the verification email: the owner confirms their email by choosing a password; the API then
 * creates the restaurant (tenant, main branch, owner account, license) and they can sign in.
 */
export function VerifyEmailScreen() {
  const [params] = useSearchParams();
  const token = params.get('token');
  const navigate = useNavigate();
  const [pw, setPw] = useState('');
  const [pw2, setPw2] = useState('');
  const [show, setShow] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<Json | null>(null);

  const longEnough = pw.length >= minLength;
  const mixed = /[A-Za-z]/.test(pw) && /[0-9]/.test(pw);
  const matches = pw.length > 0 && pw === pw2;
  const met = [longEnough, mixed, pw.length >= 12].filter(Boolean).length;
  const strength = pw.length === 0 ? 0 : Math.max(1, Math.min(3, met));
  const strengthColor = ['var(--muted)', 'var(--danger)', 'var(--amber)', 'var(--success)'][strength];

  const check = () => {
    if (!longEnough) return `Use at least ${minLength} characters (you have ${pw.length})`;
    if (!mixed) return 'Use both letters and numbers';
    if (!matches) return 'The two passwords do not match';
    return null;
  };

  const submit = async () => {
    const err = check();
    if (err) return setError(err);
    setBusy(true);
    setError(null);
    try {
      setDone(await api.verifyEmail(token!, pw));
    } catch (e) {
      setError(e instanceof ApiException ? e.message : 'Cannot reach the server. Check your connection and try again.');
    } finally {
      setBusy(false);
    }
  };

  let body;
  if (!token) {
    body = <EmptyState icon={Link2Off} title="This link is incomplete" message="Open the link from your email again, or ask for a new one." />;
  } else if (done) {
    body = (
      <div className="col gap-16" style={{ alignItems: 'stretch', textAlign: 'center' }}>
        <div className="center">
          <div className="center" style={{ width: 72, height: 72, borderRadius: '50%', background: 'color-mix(in srgb, var(--success) 16%, transparent)', color: 'var(--success)' }}>
            <Check size={40} aria-hidden />
          </div>
        </div>
        <h1 className="t-screen">Your restaurant is ready</h1>
        <p className="muted" style={{ margin: 0 }}>
          Restaurant code {`${done.code}`}. Sign in with your email and the password you just set, then add your menu, tables and staff.
        </p>
        <PrimaryButton label="Sign in" icon={LogIn} block testId="verify-signin" onClick={() => navigate('/login')} />
      </div>
    );
  } else {
    body = (
      <div className="col gap-12">
        <h1 className="t-screen">Set your password</h1>
        <span className="muted">This confirms your email and activates your restaurant.</span>
        <div style={{ height: 8 }} />
        <TextField
          label="New password"
          type={show ? 'text' : 'password'}
          autoComplete="new-password"
          value={pw}
          onChange={(v) => (setPw(v), setError(null))}
          testId="verify-password"
          suffix={<IconButton title={show ? 'Hide' : 'Show'} icon={show ? EyeOff : Eye} sm onClick={() => setShow(!show)} />}
        />
        <div className="progress" style={{ height: 4 }}>
          <div style={{ width: `${(strength / 3) * 100}%`, background: strengthColor }} />
        </div>
        <div className="row">
          <span className="t-label" style={{ fontSize: 12, color: strengthColor }}>
            {['', 'Weak', 'Good', 'Strong'][strength]}
          </span>
          <span className="right muted" style={{ fontSize: 12 }} data-testid="verify-count">
            {pw.length} characters
          </span>
        </div>
        <TextField label="Repeat password" type={show ? 'text' : 'password'} autoComplete="new-password" value={pw2} onChange={(v) => (setPw2(v), setError(null))} onEnter={submit} testId="verify-password2" />
        {/* live checklist: each rule turns green as soon as it is met */}
        <div className="col gap-4">
          {(
            [
              [longEnough, `At least ${minLength} characters`],
              [mixed, 'Letters and numbers'],
              [matches, 'Both passwords match'],
            ] as [boolean, string][]
          ).map(([ok, text]) => (
            <div key={text} className="row">
              {ok ? <Check size={18} color="var(--success)" aria-hidden /> : <Circle size={18} color="var(--faint)" aria-hidden />}
              <span className={ok ? '' : 'muted'}>{text}</span>
            </div>
          ))}
        </div>
        {error && (
          <span className="danger-text" data-testid="verify-error">
            {error}
          </span>
        )}
        <div className="mt-8">
          <PrimaryButton label="Activate my restaurant" busy={busy} block onClick={submit} testId="verify-submit" />
        </div>
      </div>
    );
  }
  return <AuthFrame plain>{body}</AuthFrame>;
}
