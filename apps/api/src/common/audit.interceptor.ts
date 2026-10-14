import { CallHandler, ExecutionContext, Injectable, NestInterceptor } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { Observable, mergeMap } from 'rxjs';
import type { AppRequest } from './actor';
import { AuditService } from './audit.service';
import { AUDIT_ACTION } from './decorators';
import { isWrite } from './guards';

/**
 * Records an audit event after every successful write route decorated with @Audited(action).
 * Handlers enrich the event through @AuditCtx() (object, before/after, reason, tenant/branch).
 * Actor, session, device, IP and UTC time come from the request.
 */
@Injectable()
export class AuditInterceptor implements NestInterceptor {
  constructor(private reflector: Reflector, private audit: AuditService) {}

  intercept(ctx: ExecutionContext, next: CallHandler): Observable<unknown> {
    const action = this.reflector.get<string>(AUDIT_ACTION, ctx.getHandler());
    const req = ctx.switchToHttp().getRequest<AppRequest>();
    if (!action || !isWrite(req.method)) return next.handle();
    return next.handle().pipe(
      mergeMap(async (result) => {
        const d = req.audit ?? {};
        if ((d as { skip?: boolean }).skip) return result; // service already wrote it inside its transaction
        await this.audit.record(
          { ...d, action: d.action ?? action, tenantId: d.tenantId ?? req.actor?.tenantId ?? null },
          req.actor ?? null,
          { ip: req.ip, sessionId: req.actor?.sessionId, deviceId: req.headers['x-device-id'] as string | undefined, requestId: req.requestId },
        );
        return result;
      }),
    );
  }
}
