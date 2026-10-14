import { SetMetadata } from '@nestjs/common';
import { loadEnv } from '../config/env';
import type { FeatureFlag, PermissionKey } from './permissions';

export const IS_PUBLIC = 'isPublic';
export const PERMISSIONS = 'permissions';
export const AUTHENTICATED_ONLY = 'authenticatedOnly';
export const ALLOW_ENROLL_TOKEN = 'allowEnrollToken';
export const FEATURE = 'feature';
export const AUDIT_ACTION = 'auditAction';
export const ANY_PERMISSION = 'anyPermission';

/** No authentication required. */
export const Public = () => SetMetadata(IS_PUBLIC, true);
/** Requires ALL listed permissions. Every non-public route must declare permissions or @AuthenticatedOnly. */
export const RequirePermissions = (...p: PermissionKey[]) => SetMetadata(PERMISSIONS, p);
/** Additionally requires at least ONE of the listed permissions (checked before the request body is read). */
export const RequireAnyPermission = (...p: PermissionKey[]) => SetMetadata(ANY_PERMISSION, p);
/** Any signed-in principal (used for /me routes). */
export const AuthenticatedOnly = () => SetMetadata(AUTHENTICATED_ONLY, true);
/** Route also accepts the short-lived MFA enrolment token (first-login MFA setup). */
export const AllowEnrollmentToken = () => SetMetadata(ALLOW_ENROLL_TOKEN, true);
/** Tenant route gated by a license feature flag; writes are refused when the license is read-only. */
export const RequiresFeature = (flag: FeatureFlag) => SetMetadata(FEATURE, flag);
/** Write route: AuditInterceptor records this action on success. */
export const Audited = (action: string) => SetMetadata(AUDIT_ACTION, action);

/** @Throttle() options for credential/token endpoints: AUTH_RATE_LIMIT_PER_MIN (default 10) per IP, resolved per request. */
export const authLimit = () => ({ default: { limit: () => loadEnv().AUTH_RATE_LIMIT_PER_MIN, ttl: 60_000 } });
