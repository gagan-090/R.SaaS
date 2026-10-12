import { Injectable } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { DbService, Tx } from '../db/db.service';
import type { Actor, AuditDetails } from './actor';

const SENSITIVE = /pass(word)?|token|secret|totp|recovery|pin|card|cvv|otp|code_hash|hash$/i;

/** Recursively replaces sensitive values so audit rows never hold credentials or card data. */
export function redact(value: unknown, depth = 0): unknown {
  if (value === null || value === undefined || depth > 8) return value;
  if (Array.isArray(value)) return value.map((v) => redact(v, depth + 1));
  if (value instanceof Date) return value.toISOString();
  if (typeof value === 'bigint') return value.toString();
  if (typeof value === 'object') {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      out[k] = SENSITIVE.test(k) ? '[REDACTED]' : redact(v, depth + 1);
    }
    return out;
  }
  return value;
}

export interface AuditMeta {
  ip?: string;
  sessionId?: string;
  deviceId?: string;
}

@Injectable()
export class AuditService {
  constructor(private readonly db: DbService) {}

  async record(d: AuditDetails & { action: string }, actor: Pick<Actor, 'type' | 'id'> | null, meta: AuditMeta = {}, tx?: Tx) {
    const data: Prisma.AuditEventUncheckedCreateInput = {
      tenantId: d.tenantId ?? null,
      branchId: d.branchId ?? null,
      actorId: actor?.id ?? null,
      actorType: actor?.type ?? 'system',
      action: d.action,
      objectType: d.objectType ?? null,
      objectId: d.objectId ?? null,
      before: d.before === undefined ? Prisma.JsonNull : (redact(d.before) as Prisma.InputJsonValue),
      after: d.after === undefined ? Prisma.JsonNull : (redact(d.after) as Prisma.InputJsonValue),
      reason: d.reason ?? null,
      sessionId: meta.sessionId ?? null,
      deviceId: meta.deviceId ?? null,
      ip: meta.ip ?? null,
    };
    if (tx) return tx.auditEvent.create({ data });
    return this.db.platform((t) => t.auditEvent.create({ data }));
  }
}
