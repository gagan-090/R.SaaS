import { useCallback, useEffect, useState, type CSSProperties } from 'react';
import { Ban, Eye, EyeOff, Lock, Plus, Receipt, Tags, Wallet } from 'lucide-react';
import { api, ApiException, errorText, type Json } from '../../api/client';
import { rupees, todayIso } from '../../lib/format';
import { parseRupees } from '../../lib/money';
import { useSession } from '../../state/auth';
import { Chip, DangerButton, EmptyState, ErrorState, IconButton, KpiCard, LoadingState, PageFrame, PrimaryButton, SecondaryButton, Select, TextButton, TextField } from '../../ui/kit';
import { Dialog, openDialog, showDone, showError } from '../../ui/overlay';

/**
 * Expenses (plan feature "expenses"): rent, utilities, repairs and other non-stock spending, in paise. A mistake is
 * voided with a reason — never deleted — so the auditor sees both.
 */
export function ExpensesScreen() {
  const me = useSession();
  const canWrite = !!me?.can('expense.write');
  const [data, setData] = useState<Json | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [showVoided, setShowVoided] = useState(false);

  const load = useCallback(async () => {
    try {
      setData(await api.expenses(showVoided));
      setError(null);
    } catch (e) {
      setError(e);
    }
  }, [showVoided]);
  useEffect(() => void load(), [load]);

  const add = async () => {
    if ((await openDialog<boolean>((close) => <ExpenseEditor categories={data!.categories as string[]} close={close} />)) === true) {
      await load();
      showDone('Expense recorded');
    }
  };

  const voidExpense = async (e: Json) => {
    const reason = await openDialog<string>((close) => <VoidDialog e={e} close={close} />);
    if (reason == null) return;
    try {
      await api.voidExpense(e.id, reason.trim());
      await load();
      showDone('Expense voided');
    } catch (err) {
      showError(err);
    }
  };

  if (error instanceof ApiException && error.code === 'feature_not_in_plan')
    return (
      <PageFrame title="Expenses">
        <EmptyState testId="expenses-locked" icon={Lock} title="Expenses are not in your plan" message="Ask House Plating to add expense tracking to your plan." />
      </PageFrame>
    );
  if (error != null) return <ErrorState message={errorText(error)} onRetry={load} />;
  if (data == null) return <LoadingState />;
  const items = data.items as Json[];

  return (
    <PageFrame title="Expenses" subtitle="Rent, utilities, repairs and other spending" actions={canWrite && <PrimaryButton label="Add expense" icon={Plus} height={48} onClick={add} testId="add-expense" />}>
      <div className="grid-auto" style={{ '--min': '200px', gap: 12 } as CSSProperties}>
        <KpiCard testId="expense-total" label="Total" value={rupees(data.totalPaise)} icon={Wallet} />
        {(data.byCategory as Json[]).map((c) => (
          <KpiCard key={c.category} label={`${c.category}`} value={rupees(c.amountPaise)} icon={Tags} />
        ))}
      </div>
      <div className="mt-8">
        <TextButton label={showVoided ? 'Hide voided' : 'Show voided'} icon={showVoided ? EyeOff : Eye} testId="show-voided" onClick={() => setShowVoided(!showVoided)} />
      </div>
      {items.length === 0 ? (
        <EmptyState icon={Receipt} title="No expenses yet" message="Record spending here to see it in reports." />
      ) : (
        <div className="card list mt-8">
          {items.map((e) => {
            const voided = e.voidedAt != null;
            return (
              <div key={e.id} className="list-row" data-testid={`expense-${e.description}`}>
                <div className="grow">
                  <div className={`t-label${voided ? ' faint strike' : ''}`}>{`${e.description}`}</div>
                  <div className="muted">
                    {[`${e.category}`, `${e.paidOn}`, `${e.paymentMode}`, `by ${e.createdByName}`, e.reference != null ? `ref ${e.reference}` : null, e.voidReason != null ? `void: ${e.voidReason}` : null].filter(Boolean).join(' · ')}
                  </div>
                </div>
                <span className="t-label">{rupees(e.amountPaise)}</span>
                {canWrite && !voided && <IconButton title="Void" icon={Ban} testId={`void-${e.description}`} onClick={() => voidExpense(e)} />}
              </div>
            );
          })}
        </div>
      )}
    </PageFrame>
  );
}

function VoidDialog({ e, close }: { e: Json; close: (v?: string) => void }) {
  const [reason, setReason] = useState('');
  return (
    <Dialog
      title="Void this expense?"
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={() => close()} />
          <DangerButton label="Void" testId="confirm-void" onClick={() => close(reason)} />
        </>
      }
    >
      <div className="col gap-12">
        <span className="muted">
          {`${e.description}`} · {rupees(e.amountPaise)}. It stays in the records, marked void.
        </span>
        <TextField label="Reason (required)" value={reason} onChange={setReason} autoFocus testId="void-reason" />
      </div>
    </Dialog>
  );
}

function ExpenseEditor({ categories, close }: { categories: string[]; close: (v?: boolean) => void }) {
  const [cat, setCat] = useState(categories[0] ?? '');
  const [desc, setDesc] = useState('');
  const [amount, setAmount] = useState('');
  const [date, setDate] = useState(todayIso());
  const [mode, setMode] = useState('upi');
  const [ref, setRef] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const save = async () => {
    const paise = parseRupees(amount);
    if (!desc.trim()) return setError('Describe the expense');
    if (paise == null || paise <= 0) return setError('Enter an amount in rupees');
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date.trim())) return setError('Date as YYYY-MM-DD');
    setBusy(true);
    setError(null);
    try {
      await api.createExpense({ category: cat, description: desc.trim(), amountPaise: paise, paidOn: date.trim(), paymentMode: mode, ...(ref.trim() ? { reference: ref.trim() } : {}) });
      close(true);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Dialog
      title="Add an expense"
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={busy ? null : () => close()} />
          <PrimaryButton label="Save" busy={busy} height={56} onClick={save} testId="save-expense" />
        </>
      }
    >
      <div className="col gap-12">
        <Select label="Category" value={cat} options={categories.map((c) => [c, c])} onChange={setCat} />
        <TextField label="What for" value={desc} onChange={setDesc} testId="expense-desc" />
        <div className="cols">
          <TextField label="Amount" prefix="₹" inputMode="decimal" value={amount} onChange={setAmount} testId="expense-amount" />
          <TextField label="Paid on (YYYY-MM-DD)" type="date" value={date} onChange={setDate} />
        </div>
        <div className="wrap" style={{ gap: 4 }}>
          {['cash', 'upi', 'card', 'bank', 'other'].map((m) => (
            <Chip key={m} label={m.toUpperCase()} on={mode === m} onClick={() => setMode(m)} />
          ))}
        </div>
        <TextField label="Bill / reference (optional)" value={ref} onChange={setRef} />
        {error && (
          <span className="danger-text" data-testid="expense-error">
            {error}
          </span>
        )}
      </div>
    </Dialog>
  );
}
