import { createPrivateKey, createPublicKey, sign, verify } from 'crypto';

/**
 * Compact signed license token: base64url(JSON payload) + "." + base64url(Ed25519 signature over the first part).
 * Verified offline by the hub (packages/hub_server) with LICENSE_PUBLIC_KEY.
 */
export interface LicensePayload {
  v: 1;
  lic: string; // license id
  tid: string; // tenant id
  plan: string; // plan code
  features: string[];
  limits: Record<string, number | null>;
  nbf: number; // unix seconds — license start
  exp: number; // unix seconds — license end
  grace_days: number;
  iat: number;
}

const b64u = (b: Buffer) => b.toString('base64url');

export function signLicense(payload: LicensePayload, privateKeyB64: string): string {
  const key = createPrivateKey({ key: Buffer.from(privateKeyB64, 'base64'), format: 'der', type: 'pkcs8' });
  const body = b64u(Buffer.from(JSON.stringify(payload), 'utf8'));
  const sig = sign(null, Buffer.from(body, 'utf8'), key);
  return `${body}.${b64u(sig)}`;
}

/** Returns the payload if the signature is valid, otherwise null. Does not judge expiry (see licenseState). */
export function verifyLicense(token: string, publicKeyB64: string): LicensePayload | null {
  const parts = token.split('.');
  if (parts.length !== 2) return null;
  try {
    const key = createPublicKey({ key: Buffer.from(publicKeyB64, 'base64'), format: 'der', type: 'spki' });
    const ok = verify(null, Buffer.from(parts[0], 'utf8'), key, Buffer.from(parts[1], 'base64url'));
    if (!ok) return null;
    const p = JSON.parse(Buffer.from(parts[0], 'base64url').toString('utf8')) as LicensePayload;
    return p.v === 1 ? p : null;
  } catch {
    return null;
  }
}

export type LicenseState = 'not_started' | 'active' | 'grace' | 'read_only';

export function licenseState(p: Pick<LicensePayload, 'nbf' | 'exp' | 'grace_days'>, now = new Date()): LicenseState {
  const t = Math.floor(now.getTime() / 1000);
  if (t < p.nbf) return 'not_started';
  if (t < p.exp) return 'active';
  if (t < p.exp + p.grace_days * 86400) return 'grace';
  return 'read_only';
}
