import { useEffect, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { api, ApiException, type Json } from '../../api/client';
import { digitsOnly, pinProblem } from '../../lib/pin';
import { PrimaryButton, Progress, TextField } from '../../ui/kit';
import { AuthFrame } from './AuthFrame';

/** Opened from an emailed invite / reset link: the employee chooses their own PIN (never sent by email). */
export function SetPinScreen() {
  const [params] = useSearchParams();
  const token = params.get('token');
  const navigate = useNavigate();
  const [info, setInfo] = useState<Json | null>(null);
  const [pin, setPin] = useState('');
  const [again, setAgain] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!token) {
      setError('This link is incomplete. Open it again from your email.');
      return;
    }
    let live = true;
    api.pinLinkCheck(token).then(
      (r) => live && setInfo(r),
      (e) => live && setError(e instanceof ApiException ? e.message : 'Cannot reach the server. Check your connection.'),
    );
    return () => {
      live = false;
    };
  }, [token]);

  const save = async () => {
    const p = pin.trim();
    const problem = pinProblem(p) ?? (p !== again.trim() ? 'The two PINs do not match' : null);
    if (problem) return setError(problem);
    setBusy(true);
    setError(null);
    try {
      const r = await api.pinLinkComplete(token!, p);
      setDone(r.webAccess === true ? 'Your PIN is set. Sign in with your email and PIN.' : 'Your PIN is set. Use it on the POS.');
    } catch (e) {
      if (e instanceof ApiException) setError(e.message);
    } finally {
      setBusy(false);
    }
  };

  if (done) {
    return (
      <AuthFrame title="All set" subtitle={done}>
        <PrimaryButton label="Go to sign in" block testId="to-login" onClick={() => navigate('/login')} />
      </AuthFrame>
    );
  }
  if (!info) {
    return (
      <AuthFrame title="Choose your PIN" subtitle={error ?? 'Checking your link…'}>
        {!error && <Progress indeterminate />}
      </AuthFrame>
    );
  }
  return (
    <AuthFrame title={info.purpose === 'reset' ? 'Choose a new PIN' : 'Choose your PIN'} subtitle={`${info.name} · ${info.restaurantName}`}>
      <div className="col gap-12">
        <span className="muted">6 to 8 digits. Not all the same digit and not a run like 123456. Never share it.</span>
        <TextField label="New PIN" type="password" inputMode="numeric" maxLength={8} value={pin} onChange={(v) => setPin(digitsOnly(v))} testId="new-pin" />
        <TextField label="Type it again" type="password" inputMode="numeric" maxLength={8} value={again} onChange={(v) => setAgain(digitsOnly(v))} onEnter={save} testId="new-pin-again" />
        {error && (
          <span className="danger-text" data-testid="set-pin-error">
            {error}
          </span>
        )}
        <div className="mt-8">
          <PrimaryButton label="Save PIN" busy={busy} block onClick={save} testId="save-pin" />
        </div>
      </div>
    </AuthFrame>
  );
}
