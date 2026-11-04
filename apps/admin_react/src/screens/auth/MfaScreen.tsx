import { useState, type FormEvent } from 'react';
import { QRCodeSVG } from 'qrcode.react';
import { api, errorText, type Json } from '../../api/client';
import { auth, useAuth } from '../../state/auth';
import { PrimaryButton, TextButton, TextField } from '../../ui/kit';
import { AuthFrame } from './AuthFrame';

/** P2 MFA: verify a code (or recovery code), or first-time enrolment with QR + 10 recovery codes. */
export function MfaScreen() {
  const s = useAuth();
  if (s.kind === 'mfaEnrollment') return <Enrollment token={s.enrollmentToken} />;
  return <Challenge />;
}

function Challenge() {
  const [code, setCode] = useState('');
  const [recovery, setRecovery] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const verify = async (e?: FormEvent) => {
    e?.preventDefault();
    if (busy) return;
    const text = code.trim();
    if (!text) return;
    setBusy(true);
    setError(null);
    try {
      await auth.verify(recovery ? { recoveryCode: text } : { code: text });
    } catch (err) {
      setError(errorText(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <AuthFrame title="Two-step verification" subtitle={recovery ? 'Enter one of your saved recovery codes.' : 'Enter the 6-digit code from your authenticator app.'}>
      <form onSubmit={verify} className="col gap-16">
        <TextField
          label={recovery ? 'Recovery code' : 'Code'}
          value={code}
          onChange={(v) => setCode(recovery ? v.slice(0, 12) : v.replace(/\D/g, '').slice(0, 6))}
          inputMode={recovery ? 'text' : 'numeric'}
          autoComplete="one-time-code"
          autoFocus
          className="code-input"
          testId="mfa-code"
        />
        {error && <span className="danger-text">{error}</span>}
        <PrimaryButton label="Verify" type="submit" busy={busy} block testId="mfa-verify" />
        <div className="center">
          <TextButton label={recovery ? 'Use authenticator code' : 'Use a recovery code'} onClick={() => (setRecovery(!recovery), setCode(''))} />
        </div>
      </form>
    </AuthFrame>
  );
}

function Enrollment({ token }: { token: string }) {
  const [enroll, setEnroll] = useState<Json | null>(null); // {secret, otpauthUrl}
  const [codes, setCodes] = useState<string[] | null>(null);
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const run = async (f: () => Promise<void>) => {
    setBusy(true);
    setError(null);
    try {
      await f();
    } catch (err) {
      setError(errorText(err));
    } finally {
      setBusy(false);
    }
  };

  if (codes) {
    return (
      <AuthFrame title="Save your recovery codes" subtitle="Each code works once if you lose your phone. They will not be shown again.">
        <div className="codes-box t-mono" data-testid="recovery-codes">
          {codes.map((c) => (
            <span key={c}>{c}</span>
          ))}
        </div>
        {error && <p className="danger-text">{error}</p>}
        <div className="mt-24">
          <PrimaryButton label="I have saved them" busy={busy} block onClick={() => run(() => auth.finishEnrollment())} />
        </div>
      </AuthFrame>
    );
  }

  const confirmCode = () =>
    run(async () => {
      setCodes(await api.enrollConfirm(token, code.trim()));
    });

  return (
    <AuthFrame title="Set up two-step verification" subtitle="Required for every platform administrator.">
      {enroll == null ? (
        <>
          {error && <p className="danger-text">{error}</p>}
          <PrimaryButton label="Start" busy={busy} block onClick={() => run(async () => setEnroll(await api.enrollStart(token)))} testId="mfa-start" />
        </>
      ) : (
        <div className="col gap-12">
          <div className="center">
            <div style={{ background: '#fff', padding: 8, borderRadius: 8 }}>
              <QRCodeSVG value={`${enroll.otpauthUrl}`} size={200} />
            </div>
          </div>
          <div className="t-mono muted" style={{ textAlign: 'center', userSelect: 'all', overflowWrap: 'anywhere' }}>
            Key: {`${enroll.secret}`}
          </div>
          <TextField label="Code from the app" value={code} onChange={(v) => setCode(v.replace(/\D/g, '').slice(0, 6))} inputMode="numeric" autoComplete="one-time-code" onEnter={confirmCode} testId="mfa-enroll-code" />
          {error && <span className="danger-text">{error}</span>}
          <PrimaryButton label="Confirm" busy={busy} block onClick={confirmCode} testId="mfa-confirm" />
        </div>
      )}
    </AuthFrame>
  );
}
