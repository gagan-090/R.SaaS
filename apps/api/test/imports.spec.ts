/** Excel import: templates, validation with sheet/row/column errors, preview, commit, retry protection, modes. */
import ExcelJS from 'exceljs';
import { buildTemplate } from '../src/imports/templates';
import { TestApp, addStaff, api, createAdmin, createTestApp, loginAdmin, onboardRestaurant } from './helpers';

type Rows = Record<string, (string | number | boolean | null | { formula: string })[][]>;
/** A workbook built in the test: sheet name → rows (first row = headers). */
async function book(sheets: Rows): Promise<string> {
  const wb = new ExcelJS.Workbook();
  for (const [name, rows] of Object.entries(sheets)) {
    const ws = wb.addWorksheet(name);
    for (const r of rows) ws.addRow(r);
  }
  return Buffer.from(await wb.xlsx.writeBuffer()).toString('base64');
}

describe('excel import', () => {
  let t: TestApp;
  let r: Awaited<ReturnType<typeof onboardRestaurant>>;
  let std: Awaited<ReturnType<typeof onboardRestaurant>>;
  const bearer = (tok: string) => ({ Authorization: `Bearer ${tok}` });
  const owner = () => bearer(r.ownerToken);
  const validate = (kind: string, fileName: string, dataBase64: string, mode = 'create', tok = r.ownerToken) =>
    t.http().post(api(`/imports/${kind}/validate`)).set(bearer(tok)).send({ fileName, dataBase64, mode });
  const commit = (id: string, partial = false) => t.http().post(api(`/imports/${id}/commit`)).set(owner()).send({ partial });

  beforeAll(async () => {
    t = await createTestApp();
    const sa = (await loginAdmin(t, await createAdmin(t, ['Super Admin']))).accessToken;
    r = await onboardRestaurant(t, sa, 'premium');
    std = await onboardRestaurant(t, sa, 'standard');
    for (const [name, rateBp] of [['GST 5%', 500], ['GST 18%', 1800]] as const) {
      await t.http().post(api('/tax-rules')).set(owner()).send({ name, rateBp }).expect(201);
    }
  });
  afterAll(() => t.close());

  it('templates download with the data sheets first, friendly headers, a few example rows and a short help sheet', async () => {
    const res = await t.http().get(api('/imports/templates/menu')).set(owner()).buffer(true).parse((resp, cb) => {
      const chunks: Buffer[] = [];
      resp.on('data', (c: Buffer) => chunks.push(c));
      resp.on('end', () => cb(null, Buffer.concat(chunks)));
    }).expect(200);
    expect(res.headers['content-type']).toMatch(/spreadsheetml/);
    const wb = new ExcelJS.Workbook();
    await wb.xlsx.load(res.body as ArrayBuffer);
    expect(wb.worksheets.map((w) => w.name)).toEqual(['Items', 'Variants', 'Recipes', 'How to fill']);
    expect(wb.getWorksheet('Variants')!.actualRowCount).toBeGreaterThan(3);
    expect(wb.getWorksheet('Items')!.getRow(1).getCell(1).value).toBe('Item code *');
    // no quarter plates in the sample any more
    expect(JSON.stringify(wb.getWorksheet('Variants')!.getSheetValues())).not.toMatch(/Quarter/i);
  });

  it('inventory template: validate → preview → commit; opening stock becomes ledger movements exactly once', async () => {
    const file = (await buildTemplate('inventory')).toString('base64');
    const v = (await validate('inventory', 'stock.xlsx', file).expect(200)).body;
    expect(v.issues.filter((i: { severity: string }) => i.severity === 'error')).toEqual([]);
    expect(v.counts).toMatchObject({ productsCreate: 4, openingMovements: 4, suppliersCreate: 3, locationsCreate: 3 });
    const rice = v.preview.opening.find((o: { sku: string }) => o.sku === 'RICE-BAS');
    expect(rice).toMatchObject({ baseQty: 25000, baseUnit: 'g', valuePaise: 150000 });
    expect(v.preview.opening.find((o: { sku: string }) => o.sku === 'COLA-500ML-BTL')).toMatchObject({ baseQty: 48 });
    expect(await t.owner.inventoryProduct.count({ where: { tenantId: r.tenantId } })).toBe(0); // validation writes nothing
    const c = (await commit(v.id).expect(200)).body;
    expect(c.status).toBe('committed');
    expect(c.result).toMatchObject({ productsCreated: 4, openingMovements: 4 });
    const again = (await commit(v.id).expect(200)).body; // a retried confirm
    expect(again.result).toEqual(c.result);
    const prod = (await t.http().get(api('/inventory/products')).set(owner()).expect(200)).body;
    expect(prod.find((p: { sku: string }) => p.sku === 'RICE-BAS')).toMatchObject({ stock: 25000 });
    expect(await t.owner.stockMovement.count({ where: { tenantId: r.tenantId, type: 'opening', sourceType: 'import' } })).toBe(4);
    // the same file again: create mode refuses existing SKUs, and says the file was imported before
    const v2 = (await validate('inventory', 'stock.xlsx', file).expect(200)).body;
    expect(v2.canCommit).toBe(false);
    expect(v2.issues.some((i: { message: string }) => /already imported/.test(i.message))).toBe(true);
    expect(v2.issues).toEqual(expect.arrayContaining([expect.objectContaining({ sheet: 'Products', row: 2, column: 'sku', severity: 'error' })]));
    expect((await commit(v2.id).expect(409)).body.code).toBe('import_has_errors');
    const p2 = (await commit(v2.id, true).expect(200)).body;
    expect(p2.status).toBe('partially_committed');
    expect(p2.result.openingMovements).toBe(0);
    expect(await t.owner.stockMovement.count({ where: { tenantId: r.tenantId, type: 'opening' } })).toBe(4);
    const job = await t.owner.importJob.findUniqueOrThrow({ where: { id: v.id } });
    expect(job).toMatchObject({ fileName: 'stock.xlsx', actorId: r.ownerUserId, status: 'committed' });
    expect(await t.owner.auditEvent.count({ where: { tenantId: r.tenantId, action: 'import.committed' } })).toBeGreaterThanOrEqual(1);
  });

  it('menu template (beverage sizes, half/full plates, recipes) imports and drives the menu', async () => {
    const v = (await validate('menu', 'menu.xlsx', (await buildTemplate('menu')).toString('base64')).expect(200)).body;
    expect(v.issues.filter((i: { severity: string }) => i.severity === 'error')).toEqual([]);
    expect(v.counts).toMatchObject({ itemsCreate: 4, variantsCreate: 6, recipes: 2 });
    expect(v.preview.categoriesToCreate).toEqual(expect.arrayContaining(['Soft Drinks', 'Main Course', 'Desserts', 'Starters']));
    await commit(v.id).expect(200);
    const items = (await t.http().get(api('/menu/items')).set(owner()).expect(200)).body;
    const cola = items.find((i: { code: string }) => i.code === 'COLA');
    expect(cola.variants.map((x: { name: string; pricePaise: number }) => [x.name, x.pricePaise])).toEqual([['250 ml', 3000], ['500 ml', 5000]]);
    const bir = items.find((i: { code: string }) => i.code === 'BIRYANI');
    expect(bir.variants.map((x: { code: string; pricePaise: number }) => [x.code, x.pricePaise])).toEqual([['BIRYANI-HALF', 22000], ['BIRYANI-FULL', 40000]]);
    const full = bir.variants.find((x: { code: string }) => x.code === 'BIRYANI-FULL');
    const rec = (await t.http().get(api(`/menu/variants/${full.id}/recipe`)).set(owner()).expect(200)).body;
    expect(rec.lines.map((l: { sku: string }) => l.sku).sort()).toEqual(['CHK-CURRY', 'OIL-SUN', 'RICE-BAS']);
    // the half plate has no recipe of its own: full × 0.5
    const half = bir.variants.find((x: { code: string }) => x.code === 'BIRYANI-HALF');
    const q = (await t.http().get(api(`/menu/variants/${half.id}/recipe`)).set(owner()).expect(200)).body;
    expect(q.own).toBe(false);
    expect(q.lines.find((l: { sku: string }) => l.sku === 'RICE-BAS').quantity).toBe(150);
  });

  it('update mode matches by code; blank cells keep values; CLEAR empties; the preview shows before and after', async () => {
    const file = await book({
      Items: [['item_code', 'item_name', 'category', 'description', 'active'], ['BIRYANI', null, null, 'CLEAR', null]],
      Variants: [['item_code', 'variant_code', 'variant_name', 'portion_label', 'serving_quantity', 'serving_unit', 'portion_ratio', 'selling_price', 'tax_code', 'available'], ['COLA', 'COLA-500', null, null, null, null, null, '55.50', null, null]],
    });
    const v = (await validate('menu', 'prices.xlsx', file, 'update').expect(200)).body;
    expect(v.canCommit).toBe(true);
    expect(v.preview.variants[0]).toMatchObject({ op: 'update', code: 'COLA-500', data: { pricePaise: 5550 }, before: { pricePaise: 5000, name: '500 ml' } });
    await commit(v.id).expect(200);
    const items = (await t.http().get(api('/menu/items')).set(owner()).expect(200)).body;
    const cola = items.find((i: { code: string }) => i.code === 'COLA');
    expect(cola.variants.find((x: { code: string }) => x.code === 'COLA-500')).toMatchObject({ name: '500 ml', pricePaise: 5550, servingQuantity: 500 });
    expect(items.find((i: { code: string }) => i.code === 'BIRYANI')).toMatchObject({ name: 'Chicken Biryani', description: null });
    // update mode refuses unknown codes
    const bad = await book({ Items: [['item_code'], ['NOPE']] });
    const vb = (await validate('menu', 'x.xlsx', bad, 'update').expect(200)).body;
    expect(vb.issues).toEqual(expect.arrayContaining([expect.objectContaining({ sheet: 'Items', row: 2, column: 'item_code', message: expect.stringMatching(/not on your menu/) })]));
  });

  it('reports every problem by sheet, row and column; formulas are refused; partial import takes only valid rows', async () => {
    const hdr = ['item_code', 'variant_code', 'variant_name', 'portion_label', 'serving_quantity', 'serving_unit', 'portion_ratio', 'selling_price', 'tax_code', 'available'];
    const file = await book({
      Items: [
        ['item_code', 'item_name', 'category', 'description', 'active'],
        ['LASSI', 'Sweet Lassi', 'Beverages', null, true],
        ['LASSI', 'Duplicate', 'Beverages', null, true],
        ['BAD CODE', 'Spaces', 'Beverages', null, true],
        ['CHAAS', 'Chaas', 'Beverages', null, 'maybe'],
        ['KULFI', 'Kulfi', 'Desserts', null, true],
      ],
      Variants: [
        hdr,
        ['LASSI', 'LASSI-300', '300 ml', null, 300, 'ml', 1, 80, 'GST 5%', true],
        ['CHAAS', 'CHAAS-1', 'Glass', null, 1, 'gallon', 1, 40, 'GST 5%', true],
        ['KULFI', 'KULFI-1', 'Stick', null, 1, 'piece', 1, '12.345', 'GST 99%', true],
        ['GHOST', 'GHOST-1', 'x', null, null, null, null, { formula: '10*2' }, 'GST 5%', true],
      ],
    });
    const v = (await validate('menu', 'broken.xlsx', file).expect(200)).body;
    const at = (sheet: string, row: number, column: string) => v.issues.some((i: { sheet: string; row: number; column: string }) => i.sheet === sheet && i.row === row && i.column === column);
    expect(at('Items', 3, 'item_code')).toBe(true); // duplicate
    expect(at('Items', 4, 'item_code')).toBe(true); // bad code
    expect(at('Items', 5, 'active')).toBe(true); // not a boolean
    expect(at('Variants', 3, 'serving_unit')).toBe(true); // unknown unit
    expect(at('Variants', 4, 'selling_price')).toBe(true); // 3 decimals
    expect(at('Variants', 4, 'tax_code')).toBe(true); // unknown tax
    expect(at('Variants', 5, 'selling_price')).toBe(true); // formula
    expect(at('Variants', 5, 'item_code')).toBe(true); // unknown item
    expect(v.canCommit).toBe(false);
    // download the error report
    const csv = (await t.http().get(api(`/imports/${v.id}/errors.csv`)).set(owner()).expect(200)).text;
    expect(csv).toMatch(/severity,sheet,row,column,problem/);
    expect(csv).toMatch(/Variants,5,selling_price,Formulas are not allowed/);
    // only the valid rows: LASSI and its size; the rest is reported as skipped
    const p = (await commit(v.id, true).expect(200)).body;
    expect(p.result).toMatchObject({ itemsCreated: 1, variantsCreated: 1 });
    expect(p.result.skipped.map((s: { code: string }) => s.code)).toEqual(expect.arrayContaining(['CHAAS', 'KULFI', 'CHAAS-1', 'KULFI-1', 'GHOST-1']));
    const items = (await t.http().get(api('/menu/items')).set(owner()).expect(200)).body;
    expect(items.some((i: { code: string }) => i.code === 'LASSI')).toBe(true);
    expect(items.some((i: { code: string }) => i.code === 'KULFI')).toBe(false);
  });

  it('missing sheets and headers are reported; unsafe files are refused before reading', async () => {
    const v = (await validate('menu', 'empty.xlsx', await book({ Items: [['item_code', 'item_name']] })).expect(200)).body;
    expect(v.issues).toEqual(expect.arrayContaining([
      expect.objectContaining({ sheet: 'Items', row: 1, column: 'category', message: 'Required column "category" is missing' }),
      expect.objectContaining({ sheet: 'Variants', row: 0, message: 'The "Variants" sheet is missing' }),
    ]));
    const good = await book({ Products: [['sku']] });
    expect((await validate('inventory', 'menu.xlsm', good).expect(400)).body.code).toBe('bad_file_type');
    expect((await validate('inventory', 'menu.xls', good).expect(400)).body.code).toBe('bad_file_type');
    expect((await validate('inventory', 'fake.xlsx', Buffer.from('<html>not a workbook</html>').toString('base64')).expect(400)).body.code).toBe('bad_file_type');
    const withMacro = Buffer.concat([Buffer.from(good, 'base64'), Buffer.from('xl/vbaProject.bin')]).toString('base64');
    expect((await validate('inventory', 'm.xlsx', withMacro).expect(400)).body.code).toBe('macros_not_allowed');
    await validate('inventory', 'big.xlsx', Buffer.alloc(5 * 1024 * 1024 + 10, 1).toString('base64')).expect(400);
  });

  it('opening stock for a product that already has it is refused; incompatible units are errors', async () => {
    const file = await book({
      OpeningStock: [
        ['sku', 'quantity', 'unit', 'unit_cost', 'storage_location', 'batch_number', 'expiry_date'],
        ['RICE-BAS', 5, 'kg', 60, 'Dry store', null, null],
        ['OIL-SUN', 2, 'kg', null, 'Dry store', null, null],
        ['NEW-THING', 1, 'kg', null, null, null, null],
        ['PANEER', 1, 'kg', null, 'Walk-in cooler', null, 'soon'],
      ],
    });
    const v = (await validate('inventory', 'more-stock.xlsx', file, 'update').expect(200)).body;
    const msg = (row: number) => v.issues.filter((i: { row: number }) => i.row === row).map((i: { message: string }) => i.message).join(' | ');
    expect(msg(2)).toMatch(/already has opening stock/);
    expect(msg(3)).toMatch(/cannot be converted|counted in ml/);
    expect(msg(4)).toMatch(/No product NEW-THING/);
    expect(msg(5)).toMatch(/date/);
  });

  it('permissions and plan: chefs, auditors and plans without import cannot import, even by direct API calls', async () => {
    const file = (await buildTemplate('inventory')).toString('base64');
    const chef = await addStaff(t, r.tenantId, 'chef');
    const auditor = await addStaff(t, r.tenantId, 'auditor');
    await validate('inventory', 'a.xlsx', file, 'create', chef.token).expect(403);
    await validate('menu', 'a.xlsx', file, 'create', auditor.token).expect(403);
    expect((await validate('inventory', 'a.xlsx', file, 'create', std.ownerToken).expect(403)).body.code).toBe('feature_not_in_plan');
    await t.http().get(api('/imports')).set(bearer(std.ownerToken)).expect(403);
    const mine = (await t.http().get(api('/imports')).set(owner()).expect(200)).body;
    expect(mine.length).toBeGreaterThan(3);
    // another restaurant cannot read or commit this restaurant's import
    const other = await onboardRestaurant(t, (await loginAdmin(t, await createAdmin(t, ['Super Admin']))).accessToken, 'premium');
    await t.http().get(api(`/imports/${mine[0].id}`)).set(bearer(other.ownerToken)).expect(404);
    await t.http().post(api(`/imports/${mine[0].id}/commit`)).set(bearer(other.ownerToken)).send({}).expect(404);
  });
});
