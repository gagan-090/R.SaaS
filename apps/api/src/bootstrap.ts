import { INestApplication } from '@nestjs/common';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import { loadEnv } from './config/env';

/** Shared app configuration for main.ts, tests and OpenAPI generation. */
export function configureApp(app: INestApplication) {
  const env = loadEnv();
  app.setGlobalPrefix('api/v1', { exclude: ['health'] });
  app.enableCors({ origin: env.CORS_ORIGINS.split(',').map((s) => s.trim()).filter(Boolean), credentials: false });
  const http = app.getHttpAdapter().getInstance();
  http.set('trust proxy', 1);
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
