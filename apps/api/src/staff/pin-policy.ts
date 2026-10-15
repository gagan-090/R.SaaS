/**
 * PIN policy (docs/STAFF_PORTAL.md):
 *  - 6 to 8 digits. A 6-digit PIN has 1,000,000 combinations; with 5 tries per 15-minute lockout per account plus
 *    per-IP throttling, guessing one takes years.
 *  - Not all the same digit, not a straight run up or down (123456, 987654), not a well-known PIN.
 *  - Stored only as an Argon2id hash; never logged, audited, emailed or returned.
 * PINs set before this policy (4–5 digits) keep working on the POS, but the web portal refuses them until the
 * employee chooses a new PIN through a reset link.
 */
const COMMON = new Set(['123123', '112233', '121212', '000000', '111111', '123321', '159753', '147258', '102030', '696969', '520520', '12341234']);

export function pinProblem(pin: string): string | null {
  if (!/^\d{6,8}$/.test(pin)) return 'PIN must be 6 to 8 digits';
  if (/^(\d)\1+$/.test(pin)) return 'PIN cannot be the same digit repeated';
  const d = [...pin].map(Number);
  const run = (step: number) => d.every((x, i) => i === 0 || x === (d[i - 1] + step + 10) % 10);
  if (run(1) || run(-1)) return 'PIN cannot be a run of digits like 123456';
  if (COMMON.has(pin)) return 'That PIN is too common; choose another';
  return null;
}

export const LEGACY_PIN = /^\d{4,8}$/;

