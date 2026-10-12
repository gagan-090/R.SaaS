/**
 * TypeScript port of packages/core billing rules — used ONLY by the cloud for reconciliation
 * (recomputing hub bills from synced lines). The hub (Dart) is authoritative for live bills.
 * Both are tested against the same golden vectors (packages/core/test/golden/*.json).
 * All values are integer paise; inputs are validated to be safe integers.
 */
export const GST_RATES_BP = new Set([0, 500, 1200, 1800, 2800]);

export class BillingError extends Error {
  constructor(public readonly code: string, message: string) {
    super(message);
  }
}

export interface LineInput { pricePaise: number; qty: number; taxRateBp: number; reversed?: boolean }
export type Discount = null | { type: 'percent'; bp: number } | { type: 'flat'; paise: number };
export interface LineTotals { amountPaise: number; discountPaise: number; taxablePaise: number; cgstPaise: number; sgstPaise: number }
export interface BillTotals {
  lines: LineTotals[]; subtotalPaise: number; discountPaise: number; taxablePaise: number; cgstPaise: number;
  sgstPaise: number; tipPaise: number; roundOffPaise: number; totalPaise: number;
}

const int = (n: number, what: string) => {
  if (!Number.isSafeInteger(n)) throw new BillingError('not_integer', `${what} must be an integer number of paise`);
  return n;
};

/** round(a × num / den), halves away from zero; BigInt keeps intermediate products exact. */
export function mulDivHalfUp(a: number, num: number, den: number): number {
  const n = BigInt(a) * BigInt(num);
  const d = BigInt(den);
  const neg = n < 0n;
  const abs = neg ? -n : n;
  const q = abs / d;
  const r = abs % d;
  const res = r * 2n >= d ? q + 1n : q;
  return Number(neg ? -res : res);
}

const mulDivFloor = (a: number, num: number, den: number) => Number((BigInt(a) * BigInt(num)) / BigInt(den));

export function allocateDiscount(amounts: number[], total: number): number[] {
  const sum = amounts.reduce((x, y) => x + y, 0);
  if (total === 0 || sum === 0) return amounts.map(() => 0);
  const shares = amounts.map((a, i) => (i === amounts.length - 1 ? 0 : mulDivFloor(total, a, sum)));
  shares[shares.length - 1] = total - shares.reduce((x, y) => x + y, 0);
  let excess = shares[shares.length - 1] - amounts[amounts.length - 1];
  if (excess > 0) {
    shares[shares.length - 1] = amounts[amounts.length - 1];
    for (let i = amounts.length - 2; i >= 0 && excess > 0; i--) {
      const take = Math.min(amounts[i] - shares[i], excess);
      shares[i] += take;
      excess -= take;
    }
  }
  return shares;
}

export function gstSplit(taxablePaise: number, rateBp: number) {
  const tax = mulDivHalfUp(taxablePaise, rateBp, 10000);
  const cgst = Math.floor((tax + 1) / 2);
  return { cgst, sgst: tax - cgst };
}

export function roundOffToRupee(paise: number): number {
  if (paise < 0) throw new BillingError('negative_total', 'bill total cannot be negative');
  const r = paise % 100;
  return r >= 50 ? 100 - r : 0 - r || 0; // never -0
}

export function computeBill(lines: LineInput[], discount: Discount = null, tipPaise = 0): BillTotals {
  for (const l of lines) {
    int(l.pricePaise, 'price');
    int(l.qty, 'qty');
    if (l.qty <= 0) throw new BillingError('bad_qty', 'quantity must be positive');
    if (l.pricePaise < 0) throw new BillingError('bad_price', 'price cannot be negative');
    if (!GST_RATES_BP.has(l.taxRateBp)) throw new BillingError('bad_tax_rate', `unsupported GST rate ${l.taxRateBp}bp`);
  }
  if (int(tipPaise, 'tip') < 0) throw new BillingError('bad_tip', 'tip cannot be negative');
  const amounts = lines.map((l) => (l.reversed ? 0 : l.pricePaise * l.qty));
  const subtotal = amounts.reduce((x, y) => x + y, 0);
  let d = 0;
  if (discount?.type === 'percent') {
    if (discount.bp < 0 || discount.bp > 10000) throw new BillingError('bad_discount', 'percent must be 0–100');
    d = mulDivHalfUp(subtotal, discount.bp, 10000);
  } else if (discount?.type === 'flat') {
    if (int(discount.paise, 'discount') < 0) throw new BillingError('bad_discount', 'flat discount cannot be negative');
    if (discount.paise > subtotal) throw new BillingError('discount_exceeds_subtotal', 'discount is larger than the subtotal');
    d = discount.paise;
  }
  const shares = allocateDiscount(amounts, d);
  let cgst = 0;
  let sgst = 0;
  const out = lines.map((l, i) => {
    const taxable = amounts[i] - shares[i];
    const g = gstSplit(taxable, l.taxRateBp);
    cgst += g.cgst;
    sgst += g.sgst;
    return { amountPaise: amounts[i], discountPaise: shares[i], taxablePaise: taxable, cgstPaise: g.cgst, sgstPaise: g.sgst };
  });
  const before = subtotal - d + cgst + sgst + tipPaise;
  const roundOff = roundOffToRupee(before);
  return { lines: out, subtotalPaise: subtotal, discountPaise: d, taxablePaise: subtotal - d, cgstPaise: cgst, sgstPaise: sgst, tipPaise, roundOffPaise: roundOff, totalPaise: before + roundOff };
}

export type PaymentInput = { mode: 'cash'; tenderedPaise: number } | { mode: 'upi' | 'card'; amountPaise: number };

export function applyPayments(totalPaise: number, payments: PaymentInput[]) {
  let remaining = totalPaise;
  let change = 0;
  for (const p of payments) {
    if (remaining === 0) throw new BillingError('already_settled', 'bill is already fully paid');
    if (p.mode === 'cash') {
      if (int(p.tenderedPaise, 'tendered') <= 0) throw new BillingError('bad_amount', 'tendered amount must be positive');
      const use = Math.min(p.tenderedPaise, remaining);
      change += p.tenderedPaise - use;
      remaining -= use;
    } else {
      if (int(p.amountPaise, 'amount') <= 0) throw new BillingError('bad_amount', 'amount must be positive');
      if (p.amountPaise > remaining) throw new BillingError('overpayment', `${p.mode} amount exceeds the amount due`);
      remaining -= p.amountPaise;
    }
  }
  return { paidPaise: totalPaise - remaining, changePaise: change, remainingPaise: remaining, settled: remaining === 0 };
}
