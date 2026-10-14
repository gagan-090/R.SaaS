import { INestApplication } from '@nestjs/common';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import { uuidv7 } from './common/uuid';
import { loadEnv } from './config/env';

/** Shared app configuration for main.ts, tests and OpenAPI generation. */
export function configureApp(app: INestApplication) {
  const env = loadEnv();
  app.setGlobalPrefix('api/v1', { exclude: ['health'] });
  // JSON bodies up to 8 MB: an Excel import (≤ 5 MB file, base64) or a menu photo; routes cap their own sizes further
  (app as NestExpressApplication).useBodyParser('json', { limit: '8mb' });
  app.enableCors({ origin: env.CORS_ORIGINS.split(',').map((s) => s.trim()).filter(Boolean), credentials: false });
  const http = app.getHttpAdapter().getInstance();
  http.set('trust proxy', 1);
  // every request gets an id (the caller's X-Request-Id when it is sensible); audit events carry it
  http.use((req: { headers: Record<string, string | string[] | undefined>; requestId?: string }, res: { setHeader(k: string, v: string): void }, next: () => void) => {
    const given = req.headers['x-request-id'];
    req.requestId = typeof given === 'string' && /^[A-Za-z0-9._:-]{8,64}$/.test(given) ? given : uuidv7();
    res.setHeader('x-request-id', req.requestId);
    next();
  });
  http.disable('x-powered-by');
  // Config rows carry a bigint sync cursor (seq); serialise it as a string.
  http.set('json replacer', (_k: string, v: unknown) => (typeof v === 'bigint' ? v.toString() : v));
  return app;
}

export function buildOpenApi(app: INestApplication) {
  const config = new DocumentBuilder()
    .setTitle('Restaurant SaaS Cloud API')
    .setVersion('1.0.0')
    .addBearerAuth()
    .addServer('/')
    .build();
  return SwaggerModule.createDocument(app, config);
}
