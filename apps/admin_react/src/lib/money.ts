/** Parses rupees ("1,249.5") into integer paise without binary floating-point arithmetic. Null when not a valid amount. */
export function parseRupees(input: string): number | null {
  const value = input.trim().replace(/,/g, '');
  if (!/^\d+(\.\d{1,2})?$/.test(value)) return null;
  const [w, f] = value.split('.');
  const whole = parseInt(w, 10);
  if (!Number.isFinite(whole) || whole > 10000000) return null;
  return whole * 100 + (f == null ? 0 : parseInt(f.padEnd(2, '0'), 10));
}

/** "249" for 24900 paise, "249.50" for 24950 — what a price box shows when editing. */
export const plainRupees = (paise: number) => (paise % 100 === 0 ? `${paise / 100}` : (paise / 100).toFixed(2));
