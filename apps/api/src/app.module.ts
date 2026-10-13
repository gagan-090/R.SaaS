import { Module } from '@nestjs/common';
import { APP_GUARD, APP_INTERCEPTOR } from '@nestjs/core';
import { ThrottlerGuard, ThrottlerModule } from '@nestjs/throttler';
import { AuthController } from './auth/auth.controller';
import { AuthService } from './auth/auth.service';
import { TokensService } from './auth/tokens.service';
import { loadEnv } from './config/env';
import { AuditInterceptor } from './common/audit.interceptor';
import { AuditService } from './common/audit.service';
import { AuthGuard, FeatureGuard, PermissionGuard } from './common/guards';
import { DbService } from './db/db.service';
import { HealthController } from './health.controller';
import { LicenseService } from './licensing/license.service';
import { mailerProvider } from './mail/mail.service';
import { PlatformController } from './platform/platform.controller';
import { PlansController } from './restaurants/plans.controller';
import { RestaurantsController } from './restaurants/restaurants.controller';
import { SyncController } from './sync/sync.controller';
import { SyncService } from './sync/sync.service';
import { ConsoleController } from './tenant/console.controller';
import { TenantController } from './tenant/tenant.controller';

@Module({
  imports: [ThrottlerModule.forRoot([{ name: 'default', ttl: 60_000, limit: loadEnv().API_RATE_LIMIT_PER_MIN }])],
  controllers: [HealthController, AuthController, PlatformController, RestaurantsController, PlansController, TenantController, ConsoleController, SyncController],
  providers: [
    DbService, TokensService, AuthService, AuditService, LicenseService, SyncService, mailerProvider,
    // Order matters: rate limit → authenticate → authorise → plan/license gate.
    { provide: APP_GUARD, useClass: ThrottlerGuard },
    { provide: APP_GUARD, useClass: AuthGuard },
    { provide: APP_GUARD, useClass: PermissionGuard },
    { provide: APP_GUARD, useClass: FeatureGuard },
    { provide: APP_INTERCEPTOR, useClass: AuditInterceptor },
  ],
})
export class AppModule {}
