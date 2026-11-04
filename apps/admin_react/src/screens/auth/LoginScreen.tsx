import { useEffect, useState, type FormEvent } from 'react';
import { useSearchParams } from 'react-router-dom';
import { Hash, Lock } from 'lucide-react';
import { api, ApiException } from '../../api/client';
import { digitsOnly } from '../../lib/pin';
import { auth } from '../../state/auth';
import { PrimaryButton, SecondaryButton, Segmented, TextButton, TextField } from '../../ui/kit';
import { Dialog, openDialog, showDone } from '../../ui/overlay';
import { AuthFrame } from './AuthFrame';

/** P1 Login: restaurant owners and platform admins with a password; employees with email + PIN (?mode=employee). */
export function LoginScreen() {
  const [params] = useSearchParams();
  const employee = params.get('mode') === 'employee';
  const [usePin, setUsePin] = useState(employee);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [pin, setPin] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [fieldErr, setFieldErr] = useState<{ email?: string; secret?: string }>({});

  useEffect(() => {
    setUsePin(employee);
    setError(null);
  }, [employee]);

  const submit = async (e?: FormEvent) => {
    e?.preventDefault();
    if (busy) return;
    const fe: typeof fieldErr = {};
    if (!email.includes('@')) fe.email = 'Enter your email';
    if (usePin ? pin.length < 4 : password.length === 0) fe.secret = usePin ? 'Enter your PIN' : 'Enter your password';
    setFieldErr(fe);
    if (fe.email || fe.secret) return;
    setBusy(true);
    setError(null);
    try {
      if (usePin) await auth.pinLogin(email.trim(), pin.trim());
      else await auth.login(email.trim(), password);
    } catch (err) {
      setError(err instanceof ApiException ? err.message : 'Cannot reach the server. Check your connection.');
    } finally {
      setBusy(false);
    }
  };

  const forgotPin = async () => {
    const to = await openDialog<string>((close) => <ForgotPinDialog initial={email.trim()} close={close} />);
    if (to == null) return;
    try {
      const r = await api.pinResetRequest(to.trim());
      showDone(`${r.message}`);
    } catch (err) {
      if (err instanceof ApiException) setError(err.message);
    }
  };

  return (
    <AuthFrame title="Sign in" subtitle={usePin ? 'Employees: your work email and PIN' : 'Restaurant owners and platform admins'}>
      <form onSubmit={submit} className="col gap-16" noValidate>
        <Segmented<boolean>
          testId="login-mode"
          block
          value={usePin}
          options={[
            [false, 'Password', Lock],
            [true, 'Employee PIN', Hash],
          ]}
          onChange={(v) => {
            setUsePin(v);
            setError(null);
          }}
        />
        <TextField label="Email" type="email" inputMode="email" autoComplete="email" name="email" value={email} onChange={setEmail} error={fieldErr.email} testId="login-email" />
        {usePin ? (
          <TextField label="PIN" type="password" inputMode="numeric" maxLength={8} value={pin} onChange={(v) => setPin(digitsOnly(v))} error={fieldErr.secret} testId="login-pin" />
        ) : (
          <TextField label="Password" type="password" autoComplete="current-password" name="password" value={password} onChange={setPassword} error={fieldErr.secret} testId="login-password" />
        )}
        {error && (
          <div className="col gap-4">
            <span className="danger-text" data-testid="login-error">
              {error}
            </span>
            {!usePin && (
              // generic on purpose (no hint whether the email exists), but tells new owners what to do
              <span className="muted" style={{ fontSize: 13 }} data-testid="login-hint">
                New restaurant? Activate it first with the link in your email, or ask your platform admin to resend it.
              </span>
            )}
          </div>
        )}
        <div style={{ marginTop: 8 }}>
          <PrimaryButton label="Sign in" type="submit" busy={busy} block testId="login-submit" />
        </div>
        {/* the row is always there (hidden for passwords) so switching modes never changes the card's height */}
        <div className="center" style={{ visibility: usePin ? 'visible' : 'hidden' }} aria-hidden={!usePin}>
          <TextButton label="Forgot PIN?" onClick={usePin ? forgotPin : null} testId="forgot-pin" />
        </div>
      </form>
    </AuthFrame>
  );
}

function ForgotPinDialog({ initial, close }: { initial: string; close: (v?: string) => void }) {
  const [email, setEmail] = useState(initial);
  return (
    <Dialog
      title="Forgot your PIN?"
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={() => close()} />
          <PrimaryButton label="Send link" height={56} onClick={() => close(email)} testId="send-pin-reset" />
        </>
      }
    >
      <p className="muted" style={{ marginTop: 0 }}>
        We email you a link to choose a new PIN. Your current PIN keeps working until then.
      </p>
      <TextField label="Your work email" type="email" value={email} onChange={setEmail} testId="reset-email" autoFocus onEnter={() => close(email)} />
    </Dialog>
  );
}
