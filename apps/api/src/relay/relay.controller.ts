import { All, Body, Controller, Get, Headers, HttpCode, Param, ParseUUIDPipe, Post, Query, Req, Res } from '@nestjs/common';
import { ApiBody, ApiExcludeEndpoint, ApiTags } from '@nestjs/swagger';
import { SkipThrottle } from '@nestjs/throttler';
import type { Request, Response } from 'express';
import { z } from 'zod';
import { Public } from '../common/decorators';
import { badRequest, forbidden } from '../common/errors';
import { apiBody, zbody, ZodPipe } from '../common/validation';
import { RelayService } from './relay.service';

const ReplyBody = z.object({
  responses: z
    .array(z.object({
      id: z.string().uuid(),
      status: z.number().int().min(100).max(599),
      headers: z.record(z.string(), z.string().max(200)).optional(),
      bodyB64: z.string().max(6_000_000).optional(),
    }))
    .max(100)
    .default([]),
  events: z.array(z.record(z.string(), z.unknown())).max(200).default([]),
});
const EventsQuery = z.object({ after: z.string().regex(/^\d{1,12}$/).optional() });

/** Only these request headers reach the main device; it adds its own relay marker. */
const FORWARD = ['x-device-token', 'authorization', 'idempotency-key', 'content-type'];
/** Answer headers the POS reads (print outcome); everything else stays on the hub. */
const BACK = ['content-type', 'x-print-status', 'x-print-copy', 'x-print-error'];
/**
 * Never relayed: pairing of any kind (a PIN or one-time code must not be guessable from the internet — a device joins
 * once on the main device's Wi-Fi), the unauthenticated health probe, and the WebSocket (relay devices long-poll
 * `events` below instead).
 */
const BLOCKED = /^(pairing|health|events)(\/|$)/;

@ApiTags('relay')
@Controller('relay')
export class RelayController {
  constructor(private relay: RelayService) {}

  /** The main device waits here for requests from devices that cannot reach it on the restaurant network. */
  @Public()
  @SkipThrottle()
  @Post('hub/poll')
  @HttpCode(200)
  async poll(@Headers('x-device-token') token: string | undefined) {
    return this.relay.poll(await this.relay.authenticateHub(token));
  }

  @Public()
  @SkipThrottle()
  @Post('hub/reply')
  @HttpCode(200)
  @ApiBody(apiBody(ReplyBody))
  async reply(@Headers('x-device-token') token: string | undefined, @Body(zbody(ReplyBody)) b: z.infer<typeof ReplyBody>) {
    this.relay.reply(await this.relay.authenticateHub(token), b.responses, b.events);
    return { ok: true };
  }

  /** Live events for a relay device (instead of the hub WebSocket). */
  @Public()
  @Get('b/:branchId/events')
  async events(@Param('branchId', ParseUUIDPipe) branchId: string, @Headers('x-device-token') token: string | undefined, @Query(new ZodPipe(EventsQuery)) q: z.infer<typeof EventsQuery>) {
    await this.relay.checkDevice(branchId, token);
    return this.relay.events(branchId, q.after === undefined ? undefined : Number(q.after));
  }

  /** Is the branch's main device connected to the relay? (no secrets: lets a device pick its route quickly) */
  @Public()
  @Get('b/:branchId/status')
  status(@Param('branchId', ParseUUIDPipe) branchId: string) {
    return { hubOnline: this.relay.hubOnline(branchId) };
  }

  /** Any hub API call, forwarded as-is: `/relay/b/<branchId>/hub/v1/<path>` → the hub's `/hub/v1/<path>`. */
  @Public()
  @ApiExcludeEndpoint()
  @All('b/:branchId/hub/v1/*path')
  async forward(@Param('branchId', ParseUUIDPipe) branchId: string, @Req() req: Request, @Res() res: Response) {
    const m = /\/hub\/v1\/(.*)$/.exec(req.originalUrl);
    const path = m?.[1] ?? '';
    // canonical paths only (plain segments, no %-escapes, dots or empty segments), so the check below cannot be
    // dodged by encoding; the query string is passed on as-is
    const [route] = path.split('?', 1);
    if (!/^[A-Za-z0-9_-]+(\/[A-Za-z0-9_-]+)*$/.test(route)) throw badRequest('bad_path', 'Bad path');
    if (BLOCKED.test(route.toLowerCase())) throw forbidden('not_relayed', 'Join the main device once on its Wi-Fi, then this device can reach it from any floor');
    // only devices the main device knows get through (nothing on the hub is reachable anonymously from the internet)
    await this.relay.checkDevice(branchId, typeof req.headers['x-device-token'] === 'string' ? req.headers['x-device-token'] : undefined);
    const headers: Record<string, string> = {};
    for (const h of FORWARD) {
      const v = req.headers[h];
      if (typeof v === 'string') headers[h] = v;
    }
    const hasBody = !['GET', 'HEAD'].includes(req.method) && Number(req.headers['content-length'] ?? 0) > 0 && req.body !== undefined;
    // the owner-console session waits for the cloud on the hub's side: give it the time the POS gives it
    const wait = Math.min(95, Math.max(5, Number(req.headers['x-relay-timeout']) || 30)) * 1000;
    const r = await this.relay.call(branchId, { method: req.method, path, headers, body: hasBody ? JSON.stringify(req.body) : undefined }, wait);
    res.status(r.status);
    for (const h of BACK) {
      const v = r.headers?.[h];
      if (v) res.setHeader(h, v);
    }
    res.setHeader('cache-control', 'no-store');
    res.end(r.bodyB64 ? Buffer.from(r.bodyB64, 'base64') : undefined);
  }
}
