import { Injectable } from '@nestjs/common';
import * as jwt from 'jsonwebtoken';
import { loadEnv } from '../config/env';
import { unauthorized } from '../common/errors';

export type Audience = 'access' | 'mfa-challenge' | 'mfa-enroll' | 'step-up';
export interface TokenClaims {
  sub: string;
  typ: 'admin' | 'user';
  tid?: string;
  sid?: string;
  aud: Audience;
}

const TTL: Record<Audience, number> = {
  access: 15 * 60,
  'mfa-challenge': 5 * 60,
  'mfa-enroll': 10 * 60,
  'step-up': 5 * 60,
};

/** Access tokens use JWT_ACCESS_SECRET; every other short-lived token uses JWT_REFRESH_SECRET. Algorithm pinned to HS256. */
@Injectable()
export class TokensService {
  private secret(aud: Audience) {
    const env = loadEnv();
    return aud === 'access' ? env.JWT_ACCESS_SECRET : env.JWT_REFRESH_SECRET;
  }

  sign(claims: Omit<TokenClaims, 'aud'>, aud: Audience): string {
    return jwt.sign({ ...claims }, this.secret(aud), {
      algorithm: 'HS256',
      audience: aud,
      expiresIn: TTL[aud],
      issuer: 'rsaas-api',
    });
  }

  verify(token: string, aud: Audience): TokenClaims {
    try {
      const c = jwt.verify(token, this.secret(aud), { algorithms: ['HS256'], audience: aud, issuer: 'rsaas-api' });
      return { ...(c as object), aud } as TokenClaims;
    } catch {
      throw unauthorized('invalid_token', 'Invalid or expired token');
    }
  }
}
