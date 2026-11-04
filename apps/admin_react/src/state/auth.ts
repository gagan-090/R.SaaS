import { api, type ApiClient, type Json } from '../api/client';
import { restaurantShortPrefix } from '../lib/menuRules';
import { Store, useStore } from './store';

/** Sign-in progress: password → (MFA challenge | first-time enrolment) → signed in. Port of providers.dart AuthNotifier. */
export type AuthState =
  | { kind: 'restoring' }
  | { kind: 'signedOut' }
  | { kind: 'mfaChallenge'; challengeToken: string }
  | { kind: 'mfaEnrollment'; enrollmentToken: string }
  | { kind: 'signedIn'; me: Json };

/** What the signed-in account may do (the API enforces the same; the UI only hides what would be refused). */
export class Session {
  readonly permissions: Set<string>;
  constructor(readonly me: Json) {
    this.permissions = new Set<string>((me.permissions as string[] | undefined) ?? []);
  }
  can = (p: string) => this.permissions.has(p);
  /** Restaurant user (owner / IT admin …) rather than a platform administrator. */
  get isRestaurant() {
    return this.me.type === 'user';
  }
  get roles(): string[] {
    return (this.me.roles as string[] | undefined) ?? [];
  }
  get restaurantName(): string | undefined {
    return this.me.tenant?.name;
  }
  get restaurantCode(): string | undefined {
    return this.me.tenant?.code;
  }
  get restaurantPrefix() {
    return restaurantShortPrefix(this.restaurantName, this.restaurantCode);
  }
}

export class AuthController {
  readonly state = new Store<AuthState>({ kind: 'restoring' });
  private started = false;
  constructor(private client: ApiClient) {}

  /** Restores the tab's session once (refresh token in sessionStorage). */
  start() {
    if (this.started) return;
    this.started = true;
    this.client.onSessionExpired = () => this.state.set({ kind: 'signedOut' });
    void this.restore();
  }

  private async restore() {
    try {
      if (await this.client.restoreSession()) await this.loadMe();
      else this.state.set({ kind: 'signedOut' });
    } catch {
      this.state.set({ kind: 'signedOut' });
    }
  }

  async login(email: string, password: string) {
    const r = await this.client.login(email, password);
    switch (r.status) {
      case 'mfa_required':
        this.state.set({ kind: 'mfaChallenge', challengeToken: r.challengeToken });
        break;
      case 'mfa_enrollment_required':
        this.state.set({ kind: 'mfaEnrollment', enrollmentToken: r.enrollmentToken });
        break;
      default:
        await this.loadMe();
    }
  }

  async pinLogin(email: string, pin: string) {
    await this.client.pinLogin(email, pin);
    await this.loadMe();
  }

  async verify(opts: { code?: string; recoveryCode?: string }) {
    const s = this.state.get();
    if (s.kind !== 'mfaChallenge') return;
    await this.client.verifyMfa(s.challengeToken, opts);
    await this.loadMe();
  }

  /** Called once the admin has saved their recovery codes. */
  finishEnrollment = () => this.loadMe();

  private async loadMe() {
    this.state.set({ kind: 'signedIn', me: await this.client.me() });
  }

  async logout() {
    await this.client.logout();
    this.state.set({ kind: 'signedOut' });
  }
}

export const auth = new AuthController(api);

export const useAuth = () => useStore(auth.state);

/** The signed-in session, or null. */
export function useSession(): Session | null {
  const s = useAuth();
  return s.kind === 'signedIn' ? sessionFor(s.me) : null;
}

const cache = new WeakMap<Json, Session>();
function sessionFor(me: Json) {
  let s = cache.get(me);
  if (!s) cache.set(me, (s = new Session(me)));
  return s;
}
