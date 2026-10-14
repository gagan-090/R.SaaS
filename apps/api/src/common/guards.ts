import { CanActivate, ExecutionContext, Injectable } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { TokensService } from '../auth/tokens.service';
import { DbService } from '../db/db.service';
import { LicenseService } from '../licensing/license.service';
import type { Actor, AppRequest } from './actor';
import {
  ALLOW_ENROLL_TOKEN, ANY_PERMISSION, AUTHENTICATED_ONLY, FEATURE, IS_PUBLIC, PERMISSIONS,
} from './decorators';
import { forbidden, unauthorized } from './errors';
import { limitToPlan, permissionsForRoles, RestaurantRoleName } from './permissions';

const meta = <T>(r: Reflector, key: string, ctx: ExecutionContext) =>
  r.getAllAndOverride<T>(key, [ctx.getHandler(), ctx.getClass()]);

export const isWrite = (method: string) => !['GET', 'HEAD', 'OPTIONS'].includes(method.toUpperCase());

/** Resolves the bearer token into req.actor. Permissions are loaded fresh from the DB on every request. */
@Injectable()
export class AuthGuard implements CanActivate {
  constructor(private reflector: Reflector, private tokens: TokensService, private db: DbService, private licenses: LicenseService) {}

  async canActivate(ctx: ExecutionContext): Promise<boolean> {
    if (meta<boolean>(this.reflector, IS_PUBLIC, ctx)) return true;
    const req = ctx.switchToHttp().getRequest<AppRequest>();
    const header = req.headers.authorization ?? '';
    const token = header.startsWith('Bearer ') ? header.slice(7) : '';
    if (!token) throw unauthorized('missing_token', 'Missing bearer token');

    let claims;
    let audience: Actor['tokenAudience'] = 'access';
    try {
      claims = this.tokens.verify(token, 'access');
    } catch (e) {
      if (!meta<boolean>(this.reflector, ALLOW_ENROLL_TOKEN, ctx)) throw e;
      claims = this.tokens.verify(token, 'mfa-enroll');
      audience = 'mfa-enroll';
    }
    req.actor = await this.loadActor(claims.typ, claims.sub, claims.tid, claims.sid, audience);
    return true;
  }

  async loadActor(typ: 'admin' | 'user', id: string, tid?: string, sid?: string, aud: Actor['tokenAudience'] = 'access'): Promise<Actor> {
    if (typ === 'admin') {
      const admin = await this.db.platform((tx) =>
        tx.platformAdmin.findUnique({ where: { id }, include: { roles: { include: { role: true } } } }),
      );
      if (!admin || admin.status !== 'active') throw unauthorized('inactive_account', 'Account is not active');
      const permissions = new Set<string>(admin.roles.flatMap((r) => r.role.permissions));
      return { type: 'admin', id, permissions, roles: admin.roles.map((r) => r.role.name), branchIds: [], sessionId: sid, tokenAudience: aud };
    }
    if (!tid) throw unauthorized('invalid_token');
    const { user, features } = await this.db.tenant(tid, async (tx) => ({
      user: await tx.user.findUnique({ where: { id }, include: { roles: { include: { customRole: true } } } }),
      features: (await this.licenses.entitlement(tx, tid)).features,
    }));
    // Deactivated employees lose access on their very next request (permissions are loaded per request).
    if (!user || user.status !== 'active') throw unauthorized('inactive_account', 'Account is not active');
    const assignments = user.roles.map((r) => ({
      role: r.role as RestaurantRoleName,
      extraPermissions: r.extraPermissions,
      customPermissions: r.customRole && !r.customRole.deleted && features.includes('roles.custom') ? r.customRole.permissions : [],
    }));
    const branchIds = user.roles.some((r) => r.branchIds.length === 0) ? [] : [...new Set(user.roles.flatMap((r) => r.branchIds))];
    const granted = permissionsForRoles(assignments);
    const permissions = limitToPlan(granted, features);
    return {
      type: 'user', id, tenantId: tid, permissions, planBlocked: new Set([...granted].filter((p) => !permissions.has(p))),
      roles: assignments.map((a) => a.role), branchIds, sessionId: sid, tokenAudience: aud,
    };
  }
}

/** Every non-public route must declare @RequirePermissions(...) or @AuthenticatedOnly(); otherwise it is refused. */
@Injectable()
export class PermissionGuard implements CanActivate {
  constructor(private reflector: Reflector) {}

  canActivate(ctx: ExecutionContext): boolean {
    if (meta<boolean>(this.reflector, IS_PUBLIC, ctx)) return true;
    const req = ctx.switchToHttp().getRequest<AppRequest>();
    const actor = req.actor;
    if (!actor) throw unauthorized();
    const allowEnroll = meta<boolean>(this.reflector, ALLOW_ENROLL_TOKEN, ctx);
    if (actor.tokenAudience !== 'access' && !allowEnroll) throw unauthorized('invalid_token');
    if (meta<boolean>(this.reflector, AUTHENTICATED_ONLY, ctx)) return true;
    const required = meta<string[]>(this.reflector, PERMISSIONS, ctx);
    if (!required || required.length === 0) throw forbidden('no_permission_declared', 'Route has no permission declaration');
    const missing = required.filter((p) => !actor.permissions.has(p));
    if (missing.length && missing.every((p) => actor.planBlocked?.has(p))) {
      throw forbidden('feature_not_in_plan', `Your plan does not include this (${missing.join(', ')}). Ask House Plating to upgrade your plan.`);
    }
    if (missing.length) throw forbidden('missing_permission', `Missing permission: ${missing.join(', ')}`);
    const any = meta<string[]>(this.reflector, ANY_PERMISSION, ctx);
    if (any?.length && !any.some((p) => actor.permissions.has(p))) {
      if (any.every((p) => actor.planBlocked?.has(p))) throw forbidden('feature_not_in_plan', 'Your plan does not include this. Ask House Plating to upgrade your plan.');
      throw forbidden('missing_permission', `Needs one of: ${any.join(', ')}`);
    }
    return true;
  }
}

/** @RequiresFeature(flag): the tenant's signed license must include the flag; writes need a non-read-only license. */
@Injectable()
export class FeatureGuard implements CanActivate {
  constructor(private reflector: Reflector, private db: DbService, private licenses: LicenseService) {}

  async canActivate(ctx: ExecutionContext): Promise<boolean> {
    const flag = meta<string>(this.reflector, FEATURE, ctx);
    if (!flag) return true;
    const req = ctx.switchToHttp().getRequest<AppRequest>();
    const actor = req.actor;
    if (!actor?.tenantId) throw forbidden('tenant_only', 'Restaurant account required');
    const ent = await this.db.tenant(actor.tenantId, (tx) => this.licenses.entitlement(tx, actor.tenantId!));
    if (!ent.features.includes(flag)) throw forbidden('feature_not_in_plan', `Your plan does not include "${flag}"`);
    if (isWrite(req.method) && ent.readOnly) {
      throw forbidden('license_read_only', `Account is read-only (${ent.state}); renew or contact support`);
    }
    return true;
  }
}
