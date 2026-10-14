import { Body, Controller, Get, HttpCode, Param, ParseUUIDPipe, Post, Res } from '@nestjs/common';
import { ApiBearerAuth, ApiBody, ApiTags } from '@nestjs/swagger';
import { Prisma } from '@prisma/client';
import type { Response } from 'express';
import { z } from 'zod';
import type { Actor, AuditDetails } from '../common/actor';
import { AuditCtx, CurrentActor } from '../common/actor';
import { sha256 } from '../common/crypto';
import { Audited, RequirePermissions, RequiresFeature } from '../common/decorators';
import { conflict, forbidden, notFound } from '../common/errors';
import { apiBody, zbody } from '../common/validation';
import { DbService, Tx } from '../db/db.service';
import { InventoryService } from '../inventory/inventory.service';
import { LicenseService } from '../licensing/license.service';
import { commitInventory, InventoryPlan, inventorySkips, validateInventory } from './inventory-import';
import { commitMenu, MenuPlan, menuSkips, validateMenu } from './menu-import';
import { buildTemplate } from './templates';
import { CellIssue, MAX_FILE_BYTES, openWorkbook } from './xlsx';

const Kind = z.enum(['menu', 'inventory']);
const ValidateBody = z.object({
  fileName: z.string().trim().min(1).max(200),
  dataBase64: z.string().min(8).max(Math.ceil((MAX_FILE_BYTES * 4) / 3) + 8),
  mode: z.enum(['create', 'update']),
});
const CommitBody = z.object({ partial: z.boolean().default(false) });

/** What each import needs besides "import.run": the permissions of the records it writes. */
const KIND_PERMISSIONS: Record<'menu' | 'inventory', string[]> = { menu: ['menu.publish'], inventory: ['inventory.manage', 'inventory.write'] };

const cap = <T>(xs: T[], n = 500) => xs.slice(0, n);

/**
 * Excel import (plan feature "import.excel"): Download template → Upload → Validate → Preview → Confirm → Results.
 * Validation stores the parsed plan on an import job; confirming writes it in one transaction. A job commits once —
 * a retried confirm returns the first result — and opening stock is keyed per file row, so the same file never adds
 * stock twice. Workbooks are read as data only: macros are refused and formula cells are errors.
 */
@ApiTags('imports')
@ApiBearerAuth()
@Controller('imports')
export class ImportsController {
  constructor(private db: DbService, private inv: InventoryService, private licenses: LicenseService) {}

  private t<T>(a: Actor, fn: (tx: Tx) => Promise<T>) {
    if (!a.tenantId) throw forbidden('tenant_only', 'Restaurant account required');
    return this.db.tenant(a.tenantId, fn);
  }

  private assertKind(a: Actor, kind: 'menu' | 'inventory') {
    const missing = KIND_PERMISSIONS[kind].filter((p) => !a.permissions.has(p));
    if (missing.length) throw forbidden('missing_permission', `Importing the ${kind} needs: ${missing.join(', ')}`);
  }

  @RequirePermissions('import.run')
  @RequiresFeature('import.excel')
  @Get('templates/:kind')
  async template(@Param('kind') kindRaw: string, @Res() res: Response) {
    const kind = Kind.parse(kindRaw);
    const buf = await buildTemplate(kind);
    res.setHeader('content-type', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
    res.setHeader('content-disposition', `attachment; filename="house-plating-${kind}-import-template.xlsx"`);
    res.send(buf);
  }

  @RequirePermissions('import.run')
  @RequiresFeature('import.excel')
  @Audited('import.validated')
  @Post(':kind/validate')
  @HttpCode(200)
  @ApiBody(apiBody(ValidateBody))
  async validate(@CurrentActor() a: Actor, @Param('kind') kindRaw: string, @Body(zbody(ValidateBody)) b: z.infer<typeof ValidateBody>, @AuditCtx() audit: AuditDetails) {
    const kind = Kind.safeParse(kindRaw);
    if (!kind.success) throw notFound('Import type');
    this.assertKind(a, kind.data);
    const bytes = Buffer.from(b.dataBase64, 'base64');
    const wb = await openWorkbook(b.fileName, bytes);
    const fileSha256 = sha256(bytes.toString('base64'));
    const issues: CellIssue[] = [];
    const job = await this.t(a, async (tx) => {
      const features = (await this.licenses.entitlement(tx, a.tenantId!)).features;
      const plan: MenuPlan | InventoryPlan = kind.data === 'menu'
        ? await validateMenu(tx, wb, b.mode, features, issues)
        : await validateInventory(tx, this.inv, wb, b.mode, issues);
      const previous = await tx.importJob.findFirst({ where: { fileSha256, kind: kind.data, status: { in: ['committed', 'partially_committed'] } }, orderBy: { createdAt: 'desc' } });
      if (previous) {
        issues.push({ sheet: '', row: 0, column: '', message: `This exact file was already imported on ${previous.committedAt?.toISOString().slice(0, 16).replace('T', ' ')} UTC. Opening stock rows will not be added again.`, severity: 'warning' });
      }
      const errors = issues.filter((i) => i.severity === 'error').length;
      const counts = kind.data === 'menu'
        ? (() => {
            const m = plan as MenuPlan;
            return {
              itemsCreate: m.items.filter((x) => x.op === 'create').length, itemsUpdate: m.items.filter((x) => x.op === 'update').length,
              variantsCreate: m.variants.filter((x) => x.op === 'create').length, variantsUpdate: m.variants.filter((x) => x.op === 'update').length,
              categoriesCreate: m.categoriesToCreate.length, recipes: m.recipes.length, errors, warnings: issues.length - errors,
            };
          })()
        : (() => {
            const p = plan as InventoryPlan;
            return {
              productsCreate: p.products.filter((x) => x.op === 'create').length, productsUpdate: p.products.filter((x) => x.op === 'update').length,
              openingMovements: p.opening.length, openingValuePaise: p.opening.reduce((s, o) => s + o.valuePaise, 0),
              suppliersCreate: p.suppliersToCreate.length, locationsCreate: p.locationsToCreate.length, errors, warnings: issues.length - errors,
            };
          })();
      return tx.importJob.create({
        data: {
          tenantId: a.tenantId!, kind: kind.data, mode: b.mode, fileName: b.fileName, fileSize: bytes.length, fileSha256, status: errors ? 'invalid' : 'validated',
          counts: counts as Prisma.InputJsonValue, errors: issues as unknown as Prisma.InputJsonValue, plan: plan as unknown as Prisma.InputJsonValue,
          actorId: a.id, actorRole: a.roles.join(','),
        },
      });
    });
    Object.assign(audit, { objectType: 'import_job', objectId: job.id, after: { kind: job.kind, mode: job.mode, fileName: job.fileName, fileSize: job.fileSize, counts: job.counts } });
    return this.view(job);
  }

  private view(job: Prisma.ImportJobGetPayload<object>) {
    const plan = job.plan as unknown as MenuPlan & InventoryPlan;
    const errors = job.errors as unknown as CellIssue[];
    return {
      id: job.id, kind: job.kind, mode: job.mode, fileName: job.fileName, fileSize: job.fileSize, status: job.status, counts: job.counts,
      createdAt: job.createdAt, committedAt: job.committedAt, result: job.result,
      issues: cap(errors, 1000),
      canCommit: errors.every((e) => e.severity !== 'error'),
      canCommitPartially: errors.some((e) => e.severity === 'error'),
      preview: job.kind === 'menu'
        ? { categoriesToCreate: plan.categoriesToCreate, items: cap(plan.items), variants: cap(plan.variants), recipes: cap(plan.recipes) }
        : { suppliersToCreate: plan.suppliersToCreate, locationsToCreate: plan.locationsToCreate, products: cap(plan.products), opening: cap(plan.opening) },
    };
  }

  /** Confirms a validated import. With errors present it refuses unless partial=true (then errored rows are skipped and reported). */
  @RequirePermissions('import.run')
  @RequiresFeature('import.excel')
  @Audited('import.committed')
  @Post(':id/commit')
  @HttpCode(200)
  @ApiBody(apiBody(CommitBody))
  async commit(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @Body(zbody(CommitBody)) b: z.infer<typeof CommitBody>, @AuditCtx() audit: AuditDetails) {
    const job = await this.t(a, async (tx) => {
      await tx.$queryRaw`SELECT id FROM import_jobs WHERE id = ${id}::uuid FOR UPDATE`;
      const j = await tx.importJob.findUnique({ where: { id } });
      if (!j) throw notFound('Import');
      this.assertKind(a, j.kind as 'menu' | 'inventory');
      if (j.status === 'committed' || j.status === 'partially_committed') return { j, again: true }; // retry: same result
      const issues = j.errors as unknown as CellIssue[];
      const hasErrors = issues.some((e) => e.severity === 'error');
      if (hasErrors && !b.partial) throw conflict('import_has_errors', 'Fix the errors and upload again, or choose to import only the valid rows');
      let result: Record<string, unknown>;
      if (j.kind === 'menu') {
        const plan = j.plan as unknown as MenuPlan;
        const keep = hasErrors ? menuSkips(plan, issues) : { items: plan.items, variants: plan.variants, recipes: plan.recipes, skipped: [] };
        result = { ...(await commitMenu(tx, a.tenantId!, { ...keep, categoriesToCreate: plan.categoriesToCreate })), skipped: keep.skipped };
      } else {
        const plan = j.plan as unknown as InventoryPlan;
        const keep = hasErrors ? inventorySkips(plan, issues) : { products: plan.products, opening: plan.opening, skipped: [] };
        result = { ...(await commitInventory(tx, this.inv, a, j.id, j.fileSha256, { ...plan, products: keep.products, opening: keep.opening })), skipped: keep.skipped };
      }
      return {
        j: await tx.importJob.update({ where: { id }, data: { status: hasErrors ? 'partially_committed' : 'committed', result: result as Prisma.InputJsonValue, committedAt: new Date() } }),
        again: false,
      };
    });
    Object.assign(audit, {
      action: job.again ? 'import.commit_retry' : job.j.status === 'partially_committed' ? 'import.partially_committed' : 'import.committed',
      objectType: 'import_job', objectId: id, after: { kind: job.j.kind, mode: job.j.mode, fileName: job.j.fileName, result: job.j.result },
    });
    return this.view(job.j);
  }

  @RequirePermissions('import.run')
  @Get()
  list(@CurrentActor() a: Actor) {
    return this.t(a, async (tx) => {
      const jobs = await tx.importJob.findMany({ orderBy: { createdAt: 'desc' }, take: 100, select: { id: true, kind: true, mode: true, fileName: true, fileSize: true, status: true, counts: true, result: true, actorId: true, createdAt: true, committedAt: true } });
      const users = new Map((await tx.user.findMany({ select: { id: true, name: true } })).map((u) => [u.id, u.name]));
      return jobs.map((j) => ({ ...j, actorName: users.get(j.actorId) ?? 'Former staff' }));
    });
  }

  @RequirePermissions('import.run')
  @Get(':id')
  async one(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string) {
    const j = await this.t(a, (tx) => tx.importJob.findUnique({ where: { id } }));
    if (!j) throw notFound('Import');
    return this.view(j);
  }

  /** Error report as CSV (sheet, row, column, problem) — opens in Excel. */
  @RequirePermissions('import.run')
  @Get(':id/errors.csv')
  async errorsCsv(@CurrentActor() a: Actor, @Param('id', ParseUUIDPipe) id: string, @Res() res: Response) {
    const j = await this.t(a, (tx) => tx.importJob.findUnique({ where: { id } }));
    if (!j) throw notFound('Import');
    const esc = (s: unknown) => {
      const v = String(s ?? '');
      // neutralise spreadsheet formula injection in the report itself
      const safe = /^[=+\-@]/.test(v) ? `'${v}` : v;
      return /[",\n]/.test(safe) ? `"${safe.replace(/"/g, '""')}"` : safe;
    };
    const lines = ['severity,sheet,row,column,problem', ...(j.errors as unknown as CellIssue[]).map((e) => [e.severity, e.sheet, e.row || '', e.column, e.message].map(esc).join(','))];
    res.setHeader('content-type', 'text/csv; charset=utf-8');
    res.setHeader('content-disposition', `attachment; filename="import-${j.kind}-errors-${j.id.slice(-8)}.csv"`);
    res.send('﻿' + lines.join('\r\n'));
  }
}

