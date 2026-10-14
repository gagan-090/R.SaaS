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
  requestId?: string;
}

@Injectable()
export class AuditService {
  constructor(private readonly db: DbService) {}

  /** Who the actor is right now (name, role, restaurant), stored with the event so history never changes. */
  private async who(actor: Pick<Actor, 'type' | 'id'> & { roles?: string[] }, tx?: Tx) {
    const run = <T>(f: (t: Tx) => Promise<T>) => (tx ? f(tx) : this.db.platform(f));
    if (actor.type === 'admin') {
      const a = await run((t) => t.platformAdmin.findUnique({ where: { id: actor.id }, select: { name: true } }));
      return { name: a?.name ?? null, role: actor.roles?.join(',') ?? 'platform admin', tenantId: null };
    }
    const u = await run((t) => t.user.findUnique({ where: { id: actor.id }, select: { name: true, tenantId: true, roles: { select: { role: true, customRole: { select: { name: true } } } } } }));
    const roles = u?.roles.map((r) => (r.role === 'custom' ? `custom:${r.customRole?.name ?? ''}` : r.role)) ?? actor.roles ?? [];
    return { name: u?.name ?? null, role: roles.join(',') || null, tenantId: u?.tenantId ?? null };
  }

  async record(d: AuditDetails & { action: string }, actor: (Pick<Actor, 'type' | 'id'> & { roles?: string[] }) | null, meta: AuditMeta = {}, tx?: Tx) {
    const who = actor && (actor.type === 'user' || actor.type === 'admin') ? await this.who(actor, tx).catch(() => null) : null;
    const data: Prisma.AuditEventUncheckedCreateInput = {
      tenantId: d.tenantId ?? who?.tenantId ?? null,
      branchId: d.branchId ?? null,
      actorId: actor?.id ?? null,
      actorType: actor?.type ?? 'system',
      actorRole: who?.role ?? null,
      actorName: who?.name ?? null,
      requestId: meta.requestId ?? null,
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
