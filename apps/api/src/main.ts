import 'reflect-metadata';
import { Logger } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { SwaggerModule } from '@nestjs/swagger';
import { AppModule } from './app.module';
import { buildOpenApi, configureApp } from './bootstrap';
import { loadEnv } from './config/env';
import { DbService } from './db/db.service';
import { LicenseService } from './licensing/license.service';

async function main() {
  const env = loadEnv(); // fail fast before anything else starts
  const app = configureApp(await NestFactory.create(AppModule, { logger: ['log', 'warn', 'error'] }));
  if (env.NODE_ENV !== 'production') SwaggerModule.setup('api/docs', app, buildOpenApi(app));
  // licenses follow their plan: a plan changed by a migration reaches restaurants already on it
  try {
    const n = await app.get(DbService).platform((tx) => app.get(LicenseService).resyncWithPlans(tx));
    if (n) new Logger('Bootstrap').log(`Re-signed ${n} license(s) to match their plan`);
  } catch (e) {
    new Logger('Bootstrap').warn(`License re-sync skipped: ${(e as Error).message}`);
  }
  await app.listen(env.PORT);
  new Logger('Bootstrap').log(`API listening on :${env.PORT} (/api/v1, docs at /api/docs)`);
}

main().catch((e: Error) => {
  console.error(e.message);
  process.exit(1);
});
