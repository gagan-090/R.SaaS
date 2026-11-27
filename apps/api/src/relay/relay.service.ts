import { HttpStatus, Injectable, OnModuleDestroy } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { sha256 } from '../common/crypto';
import { AppError, unauthorized } from '../common/errors';
import { DbService } from '../db/db.service';
import { SyncService } from '../sync/sync.service';

/** A device request waiting for the branch's main device to answer it through the relay. */
export interface RelayRequest {
  id: string;
  method: string;
  path: string; // after /hub/v1/, with the query string
  headers: Record<string, string>;
  body?: string;
}
export interface RelayResponse {
  id: string;
  status: number;
  headers?: Record<string, string>;
  bodyB64?: string;
}
interface HubCtx { deviceId: string; tenantId: string; branchId: string }

const HUB_POLL_MS = 25_000; // a hub long-poll is answered after this even with nothing to do
const HUB_GONE_MS = 40_000; // no poll for this long → the main device is offline (or has no internet)
const LISTENER_MS = 120_000; // a relay device was active this recently → the hub forwards its live events
const MAX_QUEUE = 100;
const MAX_EVENTS = 300;
const AUTH_CACHE_MS = 60_000;

const offline = () => new AppError(HttpStatus.SERVICE_UNAVAILABLE, 'hub_offline', 'The main device is offline or has no internet');

class Branch {
  lastPollAt = 0;
  lastClientAt = 0;
  queue: RelayRequest[] = [];
  pollers: Array<(r: RelayRequest[]) => void> = [];
  seq = 0;
  events: Array<{ seq: number; event: unknown }> = [];
  eventWaiters: Array<() => void> = [];
}

/**
 * Cloud relay for devices that cannot reach their main device on the restaurant network (another floor on another
 * router / ISP). The main device keeps a long-poll open here; device requests are queued, answered by the hub and
 * returned. The hub stays the single writer: the cloud only forwards, and the hub checks every device token itself.
 * State lives in memory (one API instance); a restart drops in-flight requests and devices retry.
 */
@Injectable()
export class RelayService implements OnModuleDestroy {
  constructor(private db: DbService, private sync: SyncService) {}

  private branches = new Map<string, Branch>();
  private pending = new Map<string, { branchId: string; resolve: (r: RelayResponse) => void }>();
  private hubAuth = new Map<string, { ctx: HubCtx; exp: number }>();
  private deviceAuth = new Map<string, number>(); // `${branchId}|${sha256(token)}` → expiry

  /** A relay device is active: when the hub did not know yet, wake its poll so it starts forwarding live events. */
  private touch(b: Branch, wake: boolean) {
    const wasListening = Date.now() - b.lastClientAt < LISTENER_MS;
    b.lastClientAt = Date.now();
    if (wake && !wasListening) b.pollers.shift()?.([]);
  }

  private branch(id: string) {
    let b = this.branches.get(id);
    if (!b) this.branches.set(id, (b = new Branch()));
    return b;
  }

  onModuleDestroy() {
    for (const b of this.branches.values()) {
      for (const p of b.pollers.splice(0)) p([]);
      for (const w of b.eventWaiters.splice(0)) w();
    }
  }

  /** The main device's cloud token (only a current hub device, cached a minute to spare the database). */
  async authenticateHub(token: string | undefined): Promise<HubCtx> {
    const key = sha256(token ?? '');
    const hit = this.hubAuth.get(key);
    if (hit && hit.exp > Date.now()) return hit.ctx;
    const dev = await this.sync.authenticateDevice(token);
    const d = await this.db.platform((tx) => tx.device.findUnique({ where: { id: dev.deviceId }, select: { isHub: true } }));
    if (!d?.isHub || !dev.branchId) throw unauthorized('not_main_device', 'Only the main device can serve the relay');
    const ctx = { deviceId: dev.deviceId, tenantId: dev.tenantId, branchId: dev.branchId };
    this.hubAuth.set(key, { ctx, exp: Date.now() + AUTH_CACHE_MS });
    return ctx;
  }

  /** Hub long-poll: the queued requests, or an empty list after [HUB_POLL_MS]. */
  poll(hub: HubCtx, waitMs = HUB_POLL_MS): Promise<{ requests: RelayRequest[]; listeners: boolean }> {
    const b = this.branch(hub.branchId);
    b.lastPollAt = Date.now();
    const listeners = () => Date.now() - b.lastClientAt < LISTENER_MS;
    if (b.queue.length) return Promise.resolve({ requests: b.queue.splice(0), listeners: listeners() });
    return new Promise((resolve) => {
      const done = (requests: RelayRequest[]) => {
        clearTimeout(timer);
        b.pollers = b.pollers.filter((p) => p !== done);
        b.lastPollAt = Date.now();
        resolve({ requests, listeners: listeners() });
      };
      const timer = setTimeout(() => done([]), waitMs);
      b.pollers.push(done);
    });
  }

  /** Answers from the hub, and its live events while relay devices are listening. */
  reply(hub: HubCtx, responses: RelayResponse[], events: unknown[]) {
    for (const r of responses) {
      const p = this.pending.get(r.id);
      if (!p || p.branchId !== hub.branchId) continue; // late (timed out) or not this hub's request
      this.pending.delete(r.id);
      p.resolve(r);
    }
    if (events.length) {
      const b = this.branch(hub.branchId);
      for (const event of events) b.events.push({ seq: ++b.seq, event });
      if (b.events.length > MAX_EVENTS) b.events.splice(0, b.events.length - MAX_EVENTS);
      for (const w of b.eventWaiters.splice(0)) w();
    }
  }

  hubOnline(branchId: string) {
    const b = this.branches.get(branchId);
    return !!b && (b.pollers.length > 0 || Date.now() - b.lastPollAt < HUB_GONE_MS);
  }

  /** Forwards one device request to the branch's main device and waits for its answer. */
  call(branchId: string, req: Omit<RelayRequest, 'id'>, timeoutMs: number): Promise<RelayResponse> {
    if (!this.hubOnline(branchId)) return Promise.reject(offline());
    const b = this.branch(branchId);
    this.touch(b, false); // the request itself reaches the hub, with listeners: true
    if (b.queue.length >= MAX_QUEUE) return Promise.reject(new AppError(HttpStatus.SERVICE_UNAVAILABLE, 'relay_busy', 'Too many requests waiting for the main device'));
    const id = randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        b.queue = b.queue.filter((q) => q.id !== id);
        reject(offline());
      }, timeoutMs);
      this.pending.set(id, { branchId, resolve: (r) => { clearTimeout(timer); resolve(r); } });
      const poller = b.pollers.shift();
      if (poller) poller([{ id, ...req }]);
      else b.queue.push({ id, ...req });
    });
  }

  /** A relay device's own token, checked by the main device itself (cached a minute). */
  async checkDevice(branchId: string, token: string | undefined) {
    if (!token) throw unauthorized('missing_device_token', 'X-Device-Token header required');
    const key = `${branchId}|${sha256(token)}`;
    if ((this.deviceAuth.get(key) ?? 0) > Date.now()) return;
    const r = await this.call(branchId, { method: 'GET', path: 'whoami', headers: { 'x-device-token': token } }, 15_000);
    if (r.status !== 200) throw unauthorized('invalid_device_token', 'Unknown or revoked device');
    this.deviceAuth.set(key, Date.now() + AUTH_CACHE_MS);
  }

  /** Live events after [after] (long-poll). No [after]: just the current position, so the device loads state first. */
  async events(branchId: string, after: number | undefined, waitMs = HUB_POLL_MS): Promise<{ seq: number; events: unknown[]; reset: boolean }> {
    const b = this.branch(branchId);
    this.touch(b, true);
    if (after === undefined || after > b.seq) return { seq: b.seq, events: [], reset: after !== undefined };
    if (b.seq === after) {
      await new Promise<void>((resolve) => {
        const timer = setTimeout(() => { b.eventWaiters = b.eventWaiters.filter((w) => w !== done); resolve(); }, waitMs);
        const done = () => { clearTimeout(timer); resolve(); };
        b.eventWaiters.push(done);
      });
      b.lastClientAt = Date.now();
    }
    const first = b.events[0]?.seq ?? b.seq + 1;
    if (after + 1 < first && after < b.seq) return { seq: b.seq, events: [], reset: true }; // missed some: reload state
    return { seq: b.seq, events: b.events.filter((e) => e.seq > after).map((e) => e.event), reset: false };
  }
}
