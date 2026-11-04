/* eslint-disable @typescript-eslint/no-explicit-any */
/** Build-time API base URL (VITE_API_BASE_URL), same default as the Flutter build. */
export const apiBaseUrl: string = import.meta.env.VITE_API_BASE_URL ?? 'http://localhost:3000/api/v1';

export type Json = Record<string, any>;

export class ApiException extends Error {
  constructor(public status: number, public code: string, message: string) {
    super(message);
  }
}

/** Error text for a snackbar or an inline message. */
export const errorText = (e: unknown): string =>
  e instanceof ApiException ? e.message : e instanceof Error ? e.message : `Unexpected error: ${e}`;

const sessionKey = 'house-plating.session.v1';
export function readSession(): string | null {
  try {
    return window.sessionStorage.getItem(sessionKey);
  } catch {
    return null;
  }
}
export function writeSession(v: string | null) {
  try {
    if (v == null) window.sessionStorage.removeItem(sessionKey);
    else window.sessionStorage.setItem(sessionKey, v);
  } catch {
    /* storage unavailable: the session lasts until reload */
  }
}

type Query = Record<string, string | number | boolean | null | undefined>;

function qs(q?: Query): string {
  if (!q) return '';
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(q)) if (v !== undefined && v !== null && v !== '') p.set(k, String(v));
  const s = p.toString();
  return s ? `?${s}` : '';
}

/**
 * Thin client for the cloud API (contract: packages/contracts/openapi.json), a port of the Flutter ApiClient.
 * The refresh token survives reloads in this tab only (sessionStorage); access tokens stay in memory.
 */
export class ApiClient {
  accessToken: string | null = null;
  refreshToken: string | null = null;
  onSessionExpired?: () => void;
  private refreshing: Promise<boolean> | null = null;

  constructor(
    readonly baseUrl: string = apiBaseUrl,
    private fetchImpl: typeof fetch = (...a) => fetch(...a),
    private readSess: () => string | null = readSession,
    private writeSess: (v: string | null) => void = writeSession,
  ) {}

  private async send(method: string, path: string, opts: { body?: unknown; query?: Query; headers?: Record<string, string>; bearer?: string; retry?: boolean } = {}): Promise<any> {
    const { body, query, headers, bearer, retry = true } = opts;
    const h: Record<string, string> = { 'content-type': 'application/json', ...(headers ?? {}) };
    const tok = bearer ?? this.accessToken;
    if (tok) h.authorization = `Bearer ${tok}`;
    const res = await this.fetchImpl(`${this.baseUrl}${path}${qs(query)}`, { method, headers: h, body: body === undefined ? undefined : JSON.stringify(body) });
    if (res.status === 401 && retry && !bearer && this.refreshToken && !path.startsWith('/auth/')) {
      if (await this.refresh()) return this.send(method, path, { ...opts, retry: false });
      this.onSessionExpired?.();
    }
    const text = await res.text();
    let decoded: any = null;
    if (text) {
      try {
        decoded = JSON.parse(text);
      } catch {
        decoded = null;
      }
    }
    if (res.status >= 400) {
      const m = decoded && typeof decoded === 'object' ? decoded : {};
      throw new ApiException(res.status, `${m.code ?? `http_${res.status}`}`, `${m.message ?? `Request failed (${res.status})`}`);
    }
    return decoded;
  }

  /** A file from the API (templates, reports), with the same sign-in and refresh as JSON calls. */
  async getBytes(path: string, retry = true): Promise<Blob> {
    const h: Record<string, string> = {};
    if (this.accessToken) h.authorization = `Bearer ${this.accessToken}`;
    const res = await this.fetchImpl(`${this.baseUrl}${path}`, { headers: h });
    if (res.status === 401 && retry && this.refreshToken && (await this.refresh())) return this.getBytes(path, false);
    if (res.status >= 400) {
      let m: any = {};
      try {
        m = JSON.parse(await res.text());
      } catch {
        /* not JSON */
      }
      throw new ApiException(res.status, `${m.code ?? `http_${res.status}`}`, `${m.message ?? `Download failed (${res.status})`}`);
    }
    return res.blob();
  }

  async restoreSession(): Promise<boolean> {
    this.refreshToken = this.readSess();
    return this.refreshToken != null && (await this.refresh());
  }

  private refresh(): Promise<boolean> {
    if (!this.refreshing) this.refreshing = this.rotate().finally(() => (this.refreshing = null));
    return this.refreshing;
  }

  private async rotate(): Promise<boolean> {
    try {
      const r = await this.send('POST', '/auth/refresh', { body: { refreshToken: this.refreshToken }, retry: false });
      this.setTokens(r);
      return true;
    } catch {
      this.accessToken = this.refreshToken = null;
      this.writeSess(null);
      return false;
    }
  }

  private setTokens(t: Json) {
    this.accessToken = t.accessToken as string;
    this.refreshToken = t.refreshToken as string;
    this.writeSess(this.refreshToken);
  }

  // ---- auth
  async login(email: string, password: string): Promise<Json> {
    const r = await this.send('POST', '/auth/login', { body: { email, password } });
    if (r.status === 'ok') this.setTokens(r);
    return r;
  }
  /** Employee web portal: email + PIN (plan feature "staff_portal"). */
  async pinLogin(email: string, pin: string): Promise<Json> {
    const r = await this.send('POST', '/auth/pin-login', { body: { email, pin } });
    if (r.status === 'ok') this.setTokens(r);
    return r;
  }
  pinResetRequest = (email: string): Promise<Json> => this.send('POST', '/auth/pin-reset-request', { body: { email } });
  pinLinkCheck = (token: string): Promise<Json> => this.send('POST', '/auth/pin-link/check', { body: { token } });
  pinLinkComplete = (token: string, pin: string): Promise<Json> => this.send('POST', '/auth/pin-link/complete', { body: { token, pin } });

  async verifyMfa(challengeToken: string, opts: { code?: string; recoveryCode?: string }) {
    const body: Json = { challengeToken };
    if (opts.code != null) body.code = opts.code;
    if (opts.recoveryCode != null) body.recoveryCode = opts.recoveryCode;
    this.setTokens(await this.send('POST', '/auth/mfa/verify', { body }));
  }
  enrollStart = (enrollmentToken: string): Promise<Json> => this.send('POST', '/me/mfa/enroll', { bearer: enrollmentToken });
  async enrollConfirm(enrollmentToken: string, code: string): Promise<string[]> {
    const r = await this.send('POST', '/me/mfa/confirm', { body: { code }, bearer: enrollmentToken });
    if (r.tokens) this.setTokens(r.tokens);
    return r.recoveryCodes as string[];
  }
  async stepUp(password: string, code: string): Promise<string> {
    const r = await this.send('POST', '/auth/step-up', { body: { password, ...(code ? { code } : {}) } });
    return r.stepUpToken as string;
  }
  setAdminMfa = (id: string, enabled: boolean, reason: string, stepUpToken: string): Promise<Json> =>
    this.send('POST', `/platform/admins/${id}/mfa/policy`, { body: { enabled, reason }, headers: { 'x-step-up-token': stepUpToken } });

  async logout() {
    if (this.refreshToken) {
      try {
        await this.send('POST', '/auth/logout', { body: { refreshToken: this.refreshToken } });
      } catch {
        /* signed out locally anyway */
      }
    }
    this.accessToken = this.refreshToken = null;
    this.writeSess(null);
  }

  reserveTable = (id: string, body: Json): Promise<Json> => this.send('POST', `/tables/${id}/reservations`, { body });
  cancelReservation = (id: string): Promise<Json> => this.send('POST', `/reservations/${id}/cancel`);
  quickMenu = (body: Json): Promise<Json> => this.send('POST', '/menu/quick-create', { body });
  receivePurchase = (body: Json): Promise<Json> => this.send('POST', '/inventory/purchases', { body });

  me = (): Promise<Json> => this.send('GET', '/me');

  /** Owner opens the emailed link: confirms the email, sets the password, and the restaurant is created. */
  verifyEmail = (token: string, password: string): Promise<Json> => this.send('POST', '/restaurants/verify-email', { body: { token, password } });

  // ---- restaurants
  restaurants = (f: { q?: string; status?: string | null; plan?: string | null; owner?: string; expiresBefore?: string; page?: number } = {}): Promise<Json> =>
    this.send('GET', '/restaurants', { query: { q: f.q, status: f.status, plan: f.plan, owner: f.owner, expiresBefore: f.expiresBefore, page: f.page ?? 1, pageSize: 25 } });
  registrations = (state = 'awaiting', q?: string): Promise<Json> => this.send('GET', '/restaurants/registrations', { query: { state, q } });
  resendVerification = (id: string): Promise<Json> => this.send('POST', `/restaurants/registrations/${id}/resend`);
  activateRegistration = (id: string, password: string): Promise<Json> => this.send('POST', `/restaurants/registrations/${id}/activate`, { body: { password } });
  cancelRegistration = (id: string, reason: string): Promise<Json> => this.send('POST', `/restaurants/registrations/${id}/cancel`, { body: { reason } });
  restaurant = (id: string): Promise<Json> => this.send('GET', `/restaurants/${id}`);
  registerRestaurant = (body: Json): Promise<Json> => this.send('POST', '/restaurants', { body });
  setStatus = (id: string, action: string, reason: string): Promise<Json> => this.send('POST', `/restaurants/${id}/status`, { body: { action, reason } });
  licenseAction = (id: string, action: string, reason: string, planCode?: string | null): Promise<Json> =>
    this.send('POST', `/restaurants/${id}/licenses`, { body: { action, reason, ...(planCode != null ? { planCode } : {}) } });
  archiveRestaurant = (id: string, reason: string): Promise<Json> => this.send('POST', `/restaurants/${id}/archive`, { body: { reason } });
  downloadArchive = (id: string): Promise<Blob> => this.getBytes(`/restaurants/${id}/archive/download`);
  restoreRestaurant = (id: string, reason: string): Promise<Json> => this.send('POST', `/restaurants/${id}/restore`, { body: { reason } });
  deleteRestaurant = (id: string, reason: string): Promise<Json> => this.send('POST', `/restaurants/${id}/delete`, { body: { reason } });
  recordPayment = (id: string, body: Json): Promise<Json> => this.send('POST', `/restaurants/${id}/payments`, { body });

  plans = (includeArchived = false): Promise<Json[]> => this.send('GET', '/plans', { query: includeArchived ? { includeArchived: 'true' } : undefined });
  createPlan = (body: Json): Promise<Json> => this.send('POST', '/plans', { body });
  updatePlan = (id: string, body: Json): Promise<Json> => this.send('PATCH', `/plans/${id}`, { body });

  // ---- platform admins
  admins = (): Promise<Json[]> => this.send('GET', '/platform/admins');
  roles = (): Promise<Json[]> => this.send('GET', '/platform/roles');
  invite = (email: string, name: string, roleIds: string[]): Promise<Json> => this.send('POST', '/platform/admins', { body: { email, name, roleIds } });
  createAdmin = (email: string, name: string, password: string): Promise<Json> => this.send('POST', '/platform/admins/create', { body: { email, name, password } });
  activateAdmin = (id: string, password: string): Promise<Json> => this.send('POST', `/platform/admins/${id}/activate`, { body: { password } });
  setRoles = (id: string, roleIds: string[]): Promise<Json> => this.send('PATCH', `/platform/admins/${id}/roles`, { body: { roleIds } });
  deactivate = (id: string, reason: string): Promise<Json> => this.send('POST', `/platform/admins/${id}/deactivate`, { body: { reason } });
  deleteAdmin = (id: string, reason: string): Promise<Json> => this.send('POST', `/platform/admins/${id}/delete`, { body: { reason } });
  resetMfa = (id: string, reason: string, stepUpToken: string): Promise<Json> =>
    this.send('POST', `/platform/admins/${id}/mfa/reset`, { body: { reason }, headers: { 'x-step-up-token': stepUpToken } });

  // ---- platform attention & audit
  attention = (): Promise<Json> => this.send('GET', '/platform/attention');
  audit = (f: { category?: string | null; action?: string | null; tenantId?: string | null; q?: string | null; from?: string; to?: string; page?: number } = {}): Promise<Json> =>
    this.send('GET', '/platform/audit', { query: { category: f.category, action: f.action, tenantId: f.tenantId, q: f.q, from: f.from, to: f.to, page: f.page ?? 1, pageSize: 50 } });

  // ---- restaurant console (owner / IT admin)
  overview = (): Promise<Json> => this.send('GET', '/tenant/overview');
  dashboard = (range = '7d'): Promise<Json> => this.send('GET', '/tenant/dashboard', { query: { range } });
  billDetail = (id: string): Promise<Json> => this.send('GET', `/tenant/bills/${id}`);
  profile = (): Promise<Json> => this.send('GET', '/tenant/profile');
  updateProfile = (body: Json): Promise<Json> => this.send('PATCH', '/tenant/profile', { body });

  taxRules = (): Promise<Json[]> => this.send('GET', '/tax-rules');
  createTaxRule = (name: string, rateBp: number): Promise<Json> => this.send('POST', '/tax-rules', { body: { name, rateBp } });
  categories = (): Promise<Json[]> => this.send('GET', '/menu/categories');
  createCategory = (name: string, sortOrder = 0): Promise<Json> => this.send('POST', '/menu/categories', { body: { name, sortOrder } });
  seedCategories = (): Promise<Json> => this.send('POST', '/menu/seed-categories');
  updateCategory = (id: string, body: Json): Promise<Json> => this.send('PATCH', `/menu/categories/${id}`, { body });
  deleteCategory = (id: string): Promise<void> => this.send('DELETE', `/menu/categories/${id}`);
  items = (): Promise<Json[]> => this.send('GET', '/menu/items');
  createItem = (body: Json): Promise<Json> => this.send('POST', '/menu/items', { body });
  updateItem = (id: string, body: Json): Promise<Json> => this.send('PATCH', `/menu/items/${id}`, { body });
  setVariants = (id: string, variants: Json[]): Promise<Json> => this.send('PUT', `/menu/items/${id}/variants`, { body: { variants } });
  orderCategories = (ids: string[]): Promise<void> => this.send('PUT', '/menu/categories/order', { body: { ids } });
  deleteItem = (id: string): Promise<void> => this.send('DELETE', `/menu/items/${id}`);
  setItemImage = (id: string, contentType: string, dataBase64: string): Promise<Json> => this.send('PUT', `/menu/items/${id}/image`, { body: { contentType, dataBase64 } });
  removeItemImage = (id: string): Promise<void> => this.send('DELETE', `/menu/items/${id}/image`);

  /** Public URL of a menu photo or logo (no auth needed; ids are unguessable). */
  mediaUrl = (id: string): string => `${this.baseUrl}/media/${id}`;

  // ---- inventory (plan feature "inventory")
  invProducts = (includeInactive = false): Promise<Json[]> => this.send('GET', '/inventory/products', { query: includeInactive ? { includeInactive: 'true' } : undefined });
  createInvProduct = (body: Json): Promise<Json> => this.send('POST', '/inventory/products', { body });
  updateInvProduct = (id: string, body: Json): Promise<Json> => this.send('PATCH', `/inventory/products/${id}`, { body });
  invLocations = (): Promise<Json[]> => this.send('GET', '/inventory/locations');
  createLocation = (name: string): Promise<Json> => this.send('POST', '/inventory/locations', { body: { name } });
  invSuppliers = (): Promise<Json[]> => this.send('GET', '/inventory/suppliers');
  createSupplier = (body: Json): Promise<Json> => this.send('POST', '/inventory/suppliers', { body });
  invMove = (body: Json): Promise<Json> => this.send('POST', '/inventory/movements', { body });
  invMovements = (f: { type?: string | null; productId?: string } = {}): Promise<Json[]> => this.send('GET', '/inventory/movements', { query: { type: f.type, productId: f.productId } });
  invAlerts = (): Promise<Json> => this.send('GET', '/inventory/alerts');
  invValuation = (): Promise<Json> => this.send('GET', '/inventory/valuation');
  invRequests = (): Promise<Json[]> => this.send('GET', '/inventory/requests');
  invRequest = (body: Json): Promise<Json> => this.send('POST', '/inventory/requests', { body });
  invUpdateRequest = (id: string, status: string): Promise<Json> => this.send('PATCH', `/inventory/requests/${id}`, { body: { status } });
  recipe = (variantId: string): Promise<Json> => this.send('GET', `/menu/variants/${variantId}/recipe`);
  setRecipe = (variantId: string, lines: Json[]): Promise<Json> => this.send('PUT', `/menu/variants/${variantId}/recipe`, { body: { lines } });

  // ---- Excel import (plan feature "import.excel")
  importTemplate = (kind: string): Promise<Blob> => this.getBytes(`/imports/templates/${kind}`);
  validateImport = (kind: string, fileName: string, dataBase64: string, mode: string): Promise<Json> =>
    this.send('POST', `/imports/${kind}/validate`, { body: { fileName, dataBase64, mode } });
  commitImport = (id: string, partial = false): Promise<Json> => this.send('POST', `/imports/${id}/commit`, { body: { partial } });
  imports = (): Promise<Json[]> => this.send('GET', '/imports');
  importErrorReport = (id: string): Promise<Blob> => this.getBytes(`/imports/${id}/errors.csv`);

  // ---- audit & records (read-only)
  auditEvents = (q: Query): Promise<Json[]> => this.send('GET', '/audit/events', { query: q });
  auditCsv = (q: Query): Promise<Blob> => this.getBytes(`/audit/events.csv${qs(q)}`);
  auditFacets = (): Promise<Json> => this.send('GET', '/audit/facets');
  auditImports = (): Promise<Json[]> => this.send('GET', '/audit/imports');
  salesRecords = (q: Query): Promise<Json> => this.send('GET', '/records/sales', { query: q });
  salesCsv = (q: Query): Promise<Blob> => this.getBytes(`/records/sales.csv${qs(q)}`);
  liveOrders = (): Promise<Json[]> => this.send('GET', '/records/live-orders');

  // ---- expenses (plan feature "expenses")
  expenses = (includeVoided = false): Promise<Json> => this.send('GET', '/expenses', { query: includeVoided ? { includeVoided: 'true' } : undefined });
  createExpense = (body: Json): Promise<Json> => this.send('POST', '/expenses', { body });
  voidExpense = (id: string, reason: string): Promise<Json> => this.send('POST', `/expenses/${id}/void`, { body: { reason } });

  // ---- branding (plan feature "branding")
  branding = (): Promise<Json> => this.send('GET', '/tenant/branding');
  setBranding = (body: Json): Promise<Json> => this.send('PUT', '/tenant/branding', { body });
  setLogo = (contentType: string, dataBase64: string): Promise<Json> => this.send('PUT', '/tenant/branding/logo', { body: { contentType, dataBase64 } });
  removeLogo = (): Promise<void> => this.send('DELETE', '/tenant/branding/logo');

  floors = (): Promise<Json[]> => this.send('GET', '/floors');
  floorLayout = (floorId: string): Promise<Json> => this.send('GET', `/floors/${floorId}/layout`);
  saveFloorLayout = (floorId: string, body: Json): Promise<Json> => this.send('PUT', `/floors/${floorId}/layout`, { body });
  setTableStatus = (tableId: string, status: string): Promise<Json> => this.send('POST', `/tables/${tableId}/status`, { body: { status } });
  createFloor = (branchId: string, name: string, sortOrder = 0): Promise<Json> => this.send('POST', '/floors', { body: { branchId, name, sortOrder } });
  updateFloor = (id: string, body: Json): Promise<Json> => this.send('PATCH', `/floors/${id}`, { body });
  deleteFloor = (id: string): Promise<void> => this.send('DELETE', `/floors/${id}`);
  createTable = (floorId: string, name: string, seats: number): Promise<Json> => this.send('POST', '/tables', { body: { floorId, name, seats } });
  updateTable = (id: string, body: Json): Promise<Json> => this.send('PATCH', `/tables/${id}`, { body });
  deleteTable = (id: string): Promise<void> => this.send('DELETE', `/tables/${id}`);

  staff = (): Promise<Json[]> => this.send('GET', '/staff');
  createStaff = (body: Json): Promise<Json> => this.send('POST', '/staff', { body });
  updateStaff = (id: string, body: Json): Promise<Json> => this.send('PATCH', `/staff/${id}`, { body });
  staffLimits = (): Promise<Json> => this.send('GET', '/staff/limits');
  staffPinLink = (id: string): Promise<Json> => this.send('POST', `/staff/${id}/pin-link`);
  staffUnlock = (id: string): Promise<Json> => this.send('POST', `/staff/${id}/unlock`);
  restaurantRoles = (): Promise<Json> => this.send('GET', '/roles');
  createRole = (body: Json): Promise<Json> => this.send('POST', '/roles', { body });
  updateRole = (id: string, body: Json): Promise<Json> => this.send('PATCH', `/roles/${id}`, { body });
  deleteRole = (id: string): Promise<void> => this.send('DELETE', `/roles/${id}`);
  setMyPin = (pin: string): Promise<void> => this.send('PUT', '/me/pin', { body: { pin } });

  devices = (): Promise<Json[]> => this.send('GET', '/devices');
  revokeDevice = (id: string, reason: string): Promise<Json> => this.send('POST', `/devices/${id}/revoke`, { body: { reason } });
}

/** The app's one client (tests build their own). */
export const api = new ApiClient();
