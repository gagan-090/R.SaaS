import { useEffect, useState, type ReactNode } from 'react';
import { CheckCircle2, AlertCircle } from 'lucide-react';
import { errorText } from '../api/client';
import { Store, useStore } from '../state/store';
import { DangerButton, PrimaryButton, SecondaryButton, TextField } from './kit';

// ---------------------------------------------------------------- dialogs

type Entry = { id: number; node: ReactNode };
const dialogs = new Store<Entry[]>([]);
let nextId = 1;

/**
 * Opens a dialog and resolves with what it closes with (undefined = cancelled), like Flutter's showDialog.
 * The render function gets `close`; dialogs stack.
 */
export function openDialog<T = unknown>(render: (close: (v?: T) => void) => ReactNode): Promise<T | undefined> {
  return new Promise((resolve) => {
    const id = nextId++;
    const close = (v?: T) => {
      dialogs.update((list) => list.filter((d) => d.id !== id));
      resolve(v);
    };
    dialogs.update((list) => [...list, { id, node: <DialogCloser key={id} id={id} close={close}>{render(close)}</DialogCloser> }]);
  });
}

/** Esc closes the top-most dialog (= Cancel). */
function DialogCloser({ id, close, children }: { id: number; close: () => void; children: ReactNode }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const list = dialogs.get();
      if (e.key === 'Escape' && list[list.length - 1]?.id === id) close();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [id, close]);
  return <>{children}</>;
}

export function DialogHost() {
  const list = useStore(dialogs);
  return <>{list.map((d) => d.node)}</>;
}

/** Rounded dialog with a title, body and actions (HPDialog). The barrier does not dismiss it. */
export function Dialog({ title, children, actions, size, testId }: { title: string; children: ReactNode; actions?: ReactNode; size?: 'wide' | 'xwide'; testId?: string }) {
  return (
    <div className="dlg-backdrop">
      <div className={`dlg${size ? ` ${size}` : ''}`} role="dialog" aria-modal="true" aria-label={title} data-testid={testId}>
        <h2 className="dlg-title">{title}</h2>
        <div className="dlg-body">{children}</div>
        {actions && <div className="dlg-actions">{actions}</div>}
      </div>
    </div>
  );
}

/** Every destructive action asks for a reason (≥ 3 characters) before it can be confirmed. Resolves with the trimmed reason. */
export function askReason(o: { title: string; confirmLabel: string; message?: string; destructive?: boolean }): Promise<string | undefined> {
  return openDialog<string>((close) => <ReasonDialog {...o} close={close} />);
}

function ReasonDialog({ title, confirmLabel, message, destructive = true, close }: { title: string; confirmLabel: string; message?: string; destructive?: boolean; close: (v?: string) => void }) {
  const [v, setV] = useState('');
  const ok = v.trim().length >= 3 ? () => close(v.trim()) : null;
  return (
    <Dialog
      title={title}
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={() => close()} />
          {destructive ? <DangerButton label={confirmLabel} onClick={ok} testId="reason-confirm" /> : <PrimaryButton label={confirmLabel} height={56} onClick={ok} testId="reason-confirm" />}
        </>
      }
    >
      {message && <p style={{ marginTop: 0, marginBottom: 16 }}>{message}</p>}
      <TextField label="Reason (required)" value={v} onChange={setV} autoFocus multiline={3} maxLength={500} help="Recorded in the audit log" testId="reason-field" />
    </Dialog>
  );
}

/** Yes / no confirmation without a reason; destructive (red) by default. */
export async function confirm(o: { title: string; message: string; confirmLabel?: string; destructive?: boolean }): Promise<boolean> {
  const { title, message, confirmLabel = 'Delete', destructive = true } = o;
  const r = await openDialog<boolean>((close) => (
    <Dialog
      title={title}
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={() => close(false)} />
          {destructive ? <DangerButton label={confirmLabel} onClick={() => close(true)} testId="confirm-ok" /> : <PrimaryButton label={confirmLabel} height={48} onClick={() => close(true)} testId="confirm-ok" />}
        </>
      }
    >
      <p style={{ margin: 0 }}>{message}</p>
    </Dialog>
  ));
  return r === true;
}

/** Step-up prompt: password + the admin's own current TOTP code. Resolves [password, code] or undefined. */
export function askStepUp(mfaRequired = true): Promise<[string, string] | undefined> {
  return openDialog<[string, string]>((close) => <StepUpDialog mfaRequired={mfaRequired} close={close} />);
}

function StepUpDialog({ mfaRequired, close }: { mfaRequired: boolean; close: (v?: [string, string]) => void }) {
  const [pw, setPw] = useState('');
  const [code, setCode] = useState('');
  return (
    <Dialog
      title="Confirm it is you"
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={() => close()} />
          <PrimaryButton label="Verify" height={56} onClick={() => close([pw, code.trim()])} testId="stepup-verify" />
        </>
      }
    >
      <p style={{ marginTop: 0 }}>{mfaRequired ? 'This action needs fresh verification: enter your password and the current code from your authenticator app.' : 'Confirm this action with your current password.'}</p>
      <div className="stack-12">
        <TextField label="Password" type="password" value={pw} onChange={setPw} testId="stepup-password" autoFocus />
        {mfaRequired && <TextField label="6-digit code" value={code} onChange={(v) => setCode(v.replace(/\D/g, '').slice(0, 6))} inputMode="numeric" testId="stepup-code" />}
      </div>
    </Dialog>
  );
}

// ---------------------------------------------------------------- toasts

type Toast = { id: number; msg: string; error: boolean };
const toasts = new Store<Toast[]>([]);

function push(msg: string, error: boolean, ms: number) {
  const id = nextId++;
  // one at a time, like ScaffoldMessenger.hideCurrentSnackBar()
  toasts.set([{ id, msg, error }]);
  setTimeout(() => toasts.update((l) => l.filter((t) => t.id !== id)), ms);
}

export const showDone = (msg: string) => push(msg, false, 2600);
/** Shows an API error (or any error, or a message) as a red snackbar. */
export const showError = (e: unknown) => push(typeof e === 'string' ? e : errorText(e), true, 4500);

export function ToastHost() {
  const list = useStore(toasts);
  return (
    <div className="toasts" aria-live="polite">
      {list.map((t) => (
        <div key={t.id} className={`toast${t.error ? ' error' : ''}`} role={t.error ? 'alert' : 'status'}>
          {t.error ? <AlertCircle size={20} aria-hidden /> : <CheckCircle2 size={20} aria-hidden />}
          <span>{t.msg}</span>
        </div>
      ))}
    </div>
  );
}
