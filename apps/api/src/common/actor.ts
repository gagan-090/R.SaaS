import { createParamDecorator, ExecutionContext } from '@nestjs/common';
import type { Request } from 'express';

export interface Actor {
  type: 'admin' | 'user';
  id: string;
  tenantId?: string; // users only
  permissions: Set<string>;
  roles: string[];
  branchIds: string[]; // users only; empty = all branches
  sessionId?: string;
  tokenAudience: 'access' | 'mfa-enroll';
}

export interface AuditDetails {
  action?: string;
  tenantId?: string | null;
  branchId?: string | null;
  objectType?: string;
  objectId?: string;
  before?: unknown;
  after?: unknown;
  reason?: string;
}

export type AppRequest = Request & { actor?: Actor; audit?: AuditDetails; deviceId?: string };

export const CurrentActor = createParamDecorator((_: unknown, ctx: ExecutionContext): Actor => {
  const req = ctx.switchToHttp().getRequest<AppRequest>();
  return req.actor as Actor;
});

/** Lets a handler/service attach audit details that the AuditInterceptor writes after success. */
export const AuditCtx = createParamDecorator((_: unknown, ctx: ExecutionContext) => {
  const req = ctx.switchToHttp().getRequest<AppRequest>();
  req.audit ??= {};
  return req.audit;
});
