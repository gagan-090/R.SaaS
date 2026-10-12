/** M4 — the TS reconciliation port must reproduce every golden vector the Dart core passes. */
import * as fs from 'fs';
import * as path from 'path';
import { applyPayments, BillingError, computeBill, Discount, LineInput, PaymentInput } from '../src/money/billing';

const dir = path.resolve(__dirname, '../../../packages/core/test/golden');
const files = fs.readdirSync(dir).filter((f) => f.endsWith('.json')).sort();

interface Vector {
  id: string; description: string; lines: LineInput[]; discount: Discount; tipPaise: number;
  payments?: PaymentInput[]; expected: Record<string, unknown> & { error?: string; payments?: Record<string, unknown> };
}

const codeOf = (fn: () => unknown) => {
  try {
    fn();
  } catch (e) {
    return e instanceof BillingError ? e.code : String(e);
  }
  return 'no error';
};

let count = 0;
describe.each(files)('golden %s', (file) => {
  const vectors: Vector[] = JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'));
  count += vectors.length;
  it.each(vectors.map((v) => [v.id, v] as const))('%s', (_id, v) => {
    if (v.expected.error) {
      expect(codeOf(() => computeBill(v.lines, v.discount, v.tipPaise))).toBe(v.expected.error);
      return;
    }
    const bill = computeBill(v.lines, v.discount, v.tipPaise);
    const { payments: expPay, ...expBill } = v.expected;
    expect(bill).toEqual(expBill);
    if (v.payments) {
      if (expPay?.error) expect(codeOf(() => applyPayments(bill.totalPaise, v.payments!))).toBe(expPay.error);
      else expect(applyPayments(bill.totalPaise, v.payments)).toEqual(expPay);
    }
  });
});

afterAll(() => expect(count).toBeGreaterThanOrEqual(30));
