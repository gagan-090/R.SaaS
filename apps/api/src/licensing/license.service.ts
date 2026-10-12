import { Injectable } from '@nestjs/common';
import { License, SubscriptionPlan, TenantStatus } from '@prisma/client';
import { loadEnv } from '../config/env';
import { Tx } from '../db/db.service';
import { LicensePayload, LicenseState, licenseState, signLicense, verifyLicense } from './license-token';

export interface Entitlement {
  tenantStatus: TenantStatus;
  state: LicenseState | 'none' | 'tenant_blocked';
  /** true when writes must be refused (expired past grace, suspended/blocked, revoked, no license). */
  readOnly: boolean;
  features: string[];
  limits: Record<string, number | null>;
  token: string | null;
  license: License | null;
}

@Injectable()
export class LicenseService {
  buildToken(license: Pick<License, 'id' | 'tenantId' | 'startsAt' | 'endsAt' | 'graceDays'>, plan: SubscriptionPlan): string {
    const payload: LicensePayload = {
      v: 1,
      lic: license.id,
      tid: license.tenantId,
      plan: plan.code,
      features: plan.featureFlags,
      limits: plan.limits as Record<string, number | null>,
      nbf: Math.floor(license.startsAt.getTime() / 1000),
      exp: Math.floor(license.endsAt.getTime() / 1000),
      grace_days: license.graceDays,
      iat: Math.floor(Date.now() / 1000),
    };
    return signLicense(payload, loadEnv().LICENSE_SIGNING_PRIVATE_KEY);
  }

  /** Entitlement for a tenant, computed from the signed token (never from a bare DB flag). Runs inside the caller's tx. */
  async entitlement(tx: Tx, tenantId: string, now = new Date()): Promise<Entitlement> {
    const tenant = await tx.restaurantTenant.findUnique({ where: { id: tenantId } });
    const license = await tx.license.findFirst({
      where: { tenantId, status: 'active' },
      orderBy: { createdAt: 'desc' },
    });
    const base = { tenantStatus: tenant?.status ?? 'blocked', license, token: license?.signedToken ?? null };
    if (!tenant || !license) return { ...base, state: 'none', readOnly: true, features: [], limits: {} } as Entitlement;
    const payload = verifyLicense(license.signedToken, loadEnv().LICENSE_PUBLIC_KEY);
    if (!payload || payload.tid !== tenantId) {
      return { ...base, state: 'none', readOnly: true, features: [], limits: {} } as Entitlement;
    }
    const state = licenseState(payload, now);
    const blocked = tenant.status !== 'active';
    return {
      ...base,
      state: blocked ? 'tenant_blocked' : state,
      readOnly: blocked || state === 'read_only' || state === 'not_started',
      features: payload.features,
      limits: payload.limits,
    } as Entitlement;
  }
}
