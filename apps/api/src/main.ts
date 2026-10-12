import 'reflect-metadata';
import { Logger } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { SwaggerModule } from '@nestjs/swagger';
import { AppModule } from './app.module';
import { buildOpenApi, configureApp } from './bootstrap';
import { loadEnv } from './config/env';

async function main() {
  const env = loadEnv(); // fail fast before anything else starts
  const app = configureApp(await NestFactory.create(AppModule, { logger: ['log', 'warn', 'error'] }));
  if (env.NODE_ENV !== 'production') SwaggerModule.setup('api/docs', app, buildOpenApi(app));
  await app.listen(env.PORT);
  new Logger('Bootstrap').log(`API listening on :${env.PORT} (/api/v1, docs at /api/docs)`);
}

main().catch((e: Error) => {
  console.error(e.message);
  process.exit(1);
});
