/** PIN rules, shown before saving; the server enforces the same (apps/api/src/staff/pin-policy.ts). */
export function pinProblem(p: string): string | null {
  if (!/^\d{6,8}$/.test(p)) return 'PIN must be 6 to 8 digits';
  if (/^(\d)\1+$/.test(p)) return 'PIN cannot be the same digit repeated';
  const d = p.split('').map(Number);
  const run = (step: number) => d.slice(1).every((x, i) => x === (d[i] + step + 10) % 10);
  if (run(1) || run(-1)) return 'PIN cannot be a run of digits like 123456';
  return null;
}

/** Keeps only digits, at most [max]. */
export const digitsOnly = (v: string, max = 8) => v.replace(/\D/g, '').slice(0, max);
