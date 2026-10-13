import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { PrismaClient } from '@prisma/client';
import * as argon2 from 'argon2';
import { authenticator } from 'otplib';
import request from 'supertest';
import { randomBytes } from 'crypto';
import { AppModule } from '../src/app.module';
import { configureApp } from '../src/bootstrap';
import { encrypt } from '../src/common/crypto';
import { loadEnv } from '../src/config/env';
import { MailError, Mailer, MailMessage } from '../src/mail/mail.service';

export class CaptureMailer extends Mailer {
  sent: MailMessage[] = [];
  /** Simulate the provider refusing the next message (e.g. Resend sandbox recipient not allowed). */
  failNext = false;
  async send(m: MailMessage) {
    if (this.failNext) {
      this.failNext = false;
      throw new MailError('You can only send testing emails to your own email address');
    }
    this.sent.push(m);
  }
  lastTokenFor(to: string): string {
    const m = [...this.sent].reverse().find((x) => x.to === to);
    const t = m?.text.match(/token=([A-Za-z0-9_-]+)/)?.[1];
    if (!t) throw new Error(`no token mailed to ${to}`);
    return t;
  }
}

export interface TestApp {
  app: INestApplication;
  http: () => ReturnType<typeof request>;
  mailer: CaptureMailer;
  owner: PrismaClient; // owner-role client for arranging fixtures (bypasses RLS)
  close: () => Promise<void>;
}

export async function createTestApp(): Promise<TestApp> {
  const mailer = new CaptureMailer();
  const mod = await Test.createTestingModule({ imports: [AppModule] }).overrideProvider(Mailer).useValue(mailer).compile();
  const app = configureApp(mod.createNestApplication({ logger: process.env.TEST_LOG ? ['error', 'warn'] : false }));
  await app.init();
  const owner = new PrismaClient({ datasources: { db: { url: process.env.MIGRATION_DATABASE_URL } } });
  return {
    app, mailer, owner,
    http: () => request(app.getHttpServer()),
    close: async () => {
      await owner.$disconnect();
      await app.close();
    },
  };
}

export const uniq = (p = 't') => `${p}-${Date.now().toString(36)}-${randomBytes(3).toString('hex')}`;
export const api = (p: string) => `/api/v1${p}`;

/** TOTP for the current step + offset (offset lets a test use a fresh step after the replay guard consumed one). */
export function totp(secret: string, offsetSteps = 0) {
  const step = Math.floor(Date.now() / 1000 / 30) + offsetSteps;
  return authenticator.clone({ epoch: step * 30 * 1000, window: 0 }).generate(secret);
}

export interface TestAdmin {
  id: string;
  email: string;
  password: string;
  secret: string;
}

/** Inserts an active platform admin with the named roles and a confirmed TOTP enrolment. */
export async function createAdmin(t: TestApp, roleNames: string[], opts: { mfa?: boolean } = { mfa: true }): Promise<TestAdmin> {
  const email = `${uniq('admin')}@example.test`;
  const password = 'Correct-Horse-' + randomBytes(4).toString('hex');
  const secret = authenticator.generateSecret(20);
  const roles = await t.owner.platformRole.findMany({ where: { name: { in: roleNames } } });
  const a = await t.owner.platformAdmin.create({
    data: {
      email, name: email, status: 'active', passwordHash: await argon2.hash(password, { type: argon2.argon2id }),
      roles: { create: roles.map((r) => ({ roleId: r.id })) },
      mfa: opts.mfa === false ? undefined : {
        create: { totpSecretEncrypted: encrypt(secret, loadEnv().MFA_ENCRYPTION_KEY), recoveryCodeHashes: [], enrolledAt: new Date() },
      },
    },
  });
  return { id: a.id, email, password, secret };
}

/** Full login: password → MFA challenge → TOTP. Returns the token pair. */
export async function loginAdmin(t: TestApp, a: TestAdmin, offset = 0) {
  const r1 = await t.http().post(api('/auth/login')).send({ email: a.email, password: a.password }).expect(200);
  if (r1.body.status !== 'mfa_required') throw new Error(`expected mfa_required, got ${JSON.stringify(r1.body)}`);
  const r2 = await t.http().post(api('/auth/mfa/verify')).send({ challengeToken: r1.body.challengeToken, code: totp(a.secret, offset) }).expect(200);
  return r2.body as { accessToken: string; refreshToken: string };
}

export async function login(t: TestApp, email: string, password: string) {
  const r = await t.http().post(api('/auth/login')).send({ email, password }).expect(200);
  if (r.body.status !== 'ok') throw new Error(`expected ok login, got ${JSON.stringify(r.body)}`);
  return r.body as { accessToken: string; refreshToken: string };
}

/** Registers + verifies a restaurant through the real endpoints (AC-01 path). Returns ids and an owner token. */
export async function onboardRestaurant(t: TestApp, adminToken: string, planCode = 'standard') {
  const ownerEmail = `${uniq('owner')}@example.test`;
  const password = 'Owner-Pass-' + randomBytes(4).toString('hex');
  await t.http().post(api('/restaurants')).set('Authorization', `Bearer ${adminToken}`)
    .send({ ownerEmail, ownerName: 'Owner', restaurantName: uniq('Resto'), planCode }).expect(201);
  const token = t.mailer.lastTokenFor(ownerEmail);
  const v = await t.http().post(api('/restaurants/verify-email')).send({ token, password }).expect(201);
  const tokens = await login(t, ownerEmail, password);
  return { ...v.body, ownerEmail, password, ownerToken: tokens.accessToken } as {
    tenantId: string; code: string; branchId: string; ownerUserId: string; ownerEmail: string; password: string; ownerToken: string;
  };
}

/** Adds a staff user with a role directly (fixture) and returns a signed-in access token. */
export async function addStaff(t: TestApp, tenantId: string, role: 'auditor' | 'cashier' | 'waiter' | 'chef' | 'it_admin') {
  const email = `${uniq(role)}@example.test`;
  const password = 'Staff-Pass-' + randomBytes(4).toString('hex');
  const u = await t.owner.user.create({
    data: {
      tenantId, name: role, email, passwordHash: await argon2.hash(password, { type: argon2.argon2id }),
      roles: { create: { tenantId, role, branchIds: [] } },
    },
  });
  return { id: u.id, token: (await login(t, email, password)).accessToken };
}

import { METHOD_METADATA, PATH_METADATA } from '@nestjs/common/constants';
import { RequestMethod } from '@nestjs/common';
import { MetadataScanner, Reflector } from '@nestjs/core';
import { AUTHENTICATED_ONLY, IS_PUBLIC } from '../src/common/decorators';

export interface RouteInfo {
  method: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';
  path: string; // with /api/v1 prefix and :params
  isPublic: boolean;
  authenticatedOnly: boolean;
}

/** Every HTTP route registered in the Nest app, read from controller metadata. */
export function listRoutes(app: INestApplication): RouteInfo[] {
  const reflector = new Reflector();
  const scanner = new MetadataScanner();
  const container = (app as unknown as { container: { getModules(): Map<string, { controllers: Map<unknown, { instance: object; metatype: object }> }> } }).container;
  const out: RouteInfo[] = [];
  for (const mod of container.getModules().values()) {
    for (const wrapper of mod.controllers.values()) {
      const instance = wrapper.instance as Record<string, unknown>;
      const ctrl = wrapper.metatype as object;
      const base = (Reflect.getMetadata(PATH_METADATA, ctrl) as string) ?? '';
      for (const name of scanner.getAllMethodNames(Object.getPrototypeOf(instance))) {
        const handler = instance[name] as object;
        const p = Reflect.getMetadata(PATH_METADATA, handler) as string | undefined;
        const m = Reflect.getMetadata(METHOD_METADATA, handler) as RequestMethod | undefined;
        if (p === undefined || m === undefined) continue;
        const full = '/' + [base, p].map((s) => s.replace(/^\/|\/$/g, '')).filter(Boolean).join('/');
        const prefixed = full.startsWith('/health') ? full : `/api/v1${full}`;
        out.push({
          method: RequestMethod[m] as RouteInfo['method'],
          path: prefixed,
          isPublic: !!reflector.getAllAndOverride(IS_PUBLIC, [handler as never, ctrl as never]),
          authenticatedOnly: !!reflector.getAllAndOverride(AUTHENTICATED_ONLY, [handler as never, ctrl as never]),
        });
      }
    }
  }
  return out;
}

export const fillParams = (path: string, id: string) => path.replace(/:[A-Za-z]+/g, id);
