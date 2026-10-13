import * as path from 'path';
import { config as loadDotenv } from 'dotenv';
import { z } from 'zod';

const base64Bytes = (name: string, bytes?: number) =>
  z
    .string({ error: `${name} is required` })
    .min(1, `${name} is required`)
    .refine((v) => {
      try {
        const b = Buffer.from(v, 'base64');
        return b.length > 0 && (bytes === undefined || b.length === bytes);
      } catch {
        return false;
      }
    }, `${name} must be base64${bytes ? ` of exactly ${bytes} bytes` : ''}`);

export const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().positive().default(3000),
  DATABASE_URL: z.string().min(1, 'DATABASE_URL is required').startsWith('postgres'),
  JWT_ACCESS_SECRET: z.string().min(32, 'JWT_ACCESS_SECRET must be at least 32 characters'),
  JWT_REFRESH_SECRET: z.string().min(32, 'JWT_REFRESH_SECRET must be at least 32 characters'),
  MFA_ENCRYPTION_KEY: base64Bytes('MFA_ENCRYPTION_KEY', 32),
  LICENSE_SIGNING_PRIVATE_KEY: base64Bytes('LICENSE_SIGNING_PRIVATE_KEY'),
  LICENSE_PUBLIC_KEY: base64Bytes('LICENSE_PUBLIC_KEY'),
  BOOTSTRAP_SUPERADMIN_EMAIL: z.string().email().optional(),
  BOOTSTRAP_SUPERADMIN_PASSWORD: z.string().min(12).optional(),
  CORS_ORIGINS: z.string().default(''),
  PUBLIC_API_URL: z.string().url().default('http://localhost:3000'),
  AUTH_RATE_LIMIT_PER_MIN: z.coerce.number().int().positive().default(10),
  API_RATE_LIMIT_PER_MIN: z.coerce.number().int().positive().default(300),
  SMTP_HOST: z.string().optional(),
  SMTP_PORT: z.coerce.number().int().optional(),
  SMTP_USER: z.string().optional(),
  SMTP_PASS: z.string().optional(),
  MAIL_FROM: z.string().optional(),
  // Resend (https://resend.com) — when set, email goes through Resend instead of SMTP / the console
  RESEND_API_KEY: z.string().startsWith('re_', 'RESEND_API_KEY must start with re_').optional(),
  // Where people open the web console; links in emails (verify, set password) point here
  CONSOLE_URL: z.string().url().default('http://localhost:8080'),
  SENTRY_DSN_API: z.string().optional(),
});

export type Env = z.infer<typeof envSchema>;

let cached: Env | undefined;

/** Loads <repo>/.env.local (dev convenience, never overrides real env) and validates. Fails fast naming each bad var. */
export function loadEnv(): Env {
  if (cached) return cached;
  loadDotenv({ path: path.resolve(__dirname, '../../../../.env.local'), quiet: true });
  const raw = Object.fromEntries(Object.entries(process.env).filter(([, v]) => v !== ''));
  const parsed = envSchema.safeParse(raw);
  if (!parsed.success) {
    const lines = parsed.error.issues.map((i) => `  - ${i.path.join('.')}: ${i.message}`);
    throw new Error(`Invalid environment configuration:\n${lines.join('\n')}\nSee .env.example`);
  }
  cached = parsed.data;
  return cached;
}

export function resetEnvCache() {
  cached = undefined;
}
