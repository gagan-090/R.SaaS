import ExcelJS from 'exceljs';

export interface ColumnSpec {
  name: string;
  required: 'yes' | 'create' | 'no'; // "create" = required when creating, optional when updating
  meaning: string;
  example: string;
}
export interface SheetSpec {
  sheet: string;
  purpose: string;
  columns: ColumnSpec[];
  rows: (string | number | boolean | Date | null)[][];
}

/** Menu workbook: items, their sizes / portions (variants) with prices, and what each size uses from stock. */
export const MENU_SHEETS: SheetSpec[] = [
  {
    sheet: 'Items',
    purpose: 'One row per dish or drink. item_code is the stable key: updates match on it, never on the name.',
    columns: [
      { name: 'item_code', required: 'yes', meaning: 'Stable code you choose (letters, digits, - _ .). Never reuse it for another dish.', example: 'BIRYANI' },
      { name: 'item_name', required: 'create', meaning: 'Name shown on the POS, kitchen tickets and bills.', example: 'Chicken Biryani' },
      { name: 'category', required: 'create', meaning: 'Menu category. A category that does not exist yet is created.', example: 'Main Course' },
      { name: 'description', required: 'no', meaning: 'Optional text. In update mode write CLEAR to remove it.', example: 'Dum-cooked, served with raita' },
      { name: 'active', required: 'no', meaning: 'TRUE to show on the POS, FALSE to hide. Blank = TRUE when creating.', example: 'TRUE' },
    ],
    rows: [
      ['COLA', 'Cola', 'Soft Drinks', 'Chilled', true],
      ['WATER', 'Mineral Water', 'Soft Drinks', null, true],
      ['BIRYANI', 'Chicken Biryani', 'Main Course', 'Dum-cooked, served with raita', true],
      ['PANEER-TIKKA', 'Paneer Tikka', 'Starters', null, true],
      ['JEERA-RICE', 'Jeera Rice', 'Rice', null, true],
      ['BUTTER-NAAN', 'Butter Naan', 'Breads', null, true],
      ['GULAB-JAMUN', 'Gulab Jamun', 'Desserts', '2 pieces', true],
    ],
  },
  {
    sheet: 'Variants',
    purpose: 'One row per size or portion of an item. Every item needs at least one. Each has its own selling price — a half plate is not assumed to cost half.',
    columns: [
      { name: 'item_code', required: 'yes', meaning: 'The item this size belongs to (from the Items sheet or already on your menu).', example: 'BIRYANI' },
      { name: 'variant_code', required: 'yes', meaning: 'Stable code / SKU of this size, unique in your restaurant.', example: 'BIRYANI-HALF' },
      { name: 'variant_name', required: 'create', meaning: 'What staff and guests see for this size.', example: 'Half plate' },
      { name: 'portion_label', required: 'no', meaning: 'quarter, half, full, or your own word. For information only.', example: 'half' },
      { name: 'serving_quantity', required: 'no', meaning: 'How much is served (a number), together with serving_unit. Example 500 + ml.', example: '1' },
      { name: 'serving_unit', required: 'no', meaning: 'ml, l, g, kg, piece, plate, bowl, glass, cup, portion, bottle, can, packet.', example: 'plate' },
      { name: 'portion_ratio', required: 'no', meaning: 'Size compared with the full portion (full = 1, half = 0.5). Used ONLY to scale a recipe when this size has none of its own — never for prices.', example: '0.55' },
      { name: 'selling_price', required: 'create', meaning: 'Selling price in rupees before GST, up to 2 decimals.', example: '220' },
      { name: 'tax_code', required: 'create', meaning: 'Your GST rule, by name (GST 5%) or rate (5). It must already exist in Settings.', example: 'GST 5%' },
      { name: 'available', required: 'no', meaning: 'TRUE to sell, FALSE for sold out. Blank = TRUE when creating.', example: 'TRUE' },
    ],
    rows: [
      ['COLA', 'COLA-250', '250 ml', null, 250, 'ml', 0.25, 30, 'GST 18%', true],
      ['COLA', 'COLA-500', '500 ml', null, 500, 'ml', 0.5, 50, 'GST 18%', true],
      ['COLA', 'COLA-1L', '1 litre', null, 1, 'l', 1, 90, 'GST 18%', true],
      ['WATER', 'WATER-500', '500 ml bottle', null, 500, 'ml', 0.5, 20, 'GST 18%', true],
      ['WATER', 'WATER-1L', '1 litre bottle', null, 1, 'l', 1, 35, 'GST 18%', true],
      ['BIRYANI', 'BIRYANI-QTR', 'Quarter plate', 'quarter', 1, 'plate', 0.3, 120, 'GST 5%', true],
      ['BIRYANI', 'BIRYANI-HALF', 'Half plate', 'half', 1, 'plate', 0.55, 220, 'GST 5%', true],
      ['BIRYANI', 'BIRYANI-FULL', 'Full plate', 'full', 1, 'plate', 1, 400, 'GST 5%', true],
      ['PANEER-TIKKA', 'PANEER-TIKKA-6', '6 pieces', null, 6, 'piece', 1, 260, 'GST 5%', true],
      ['JEERA-RICE', 'JEERA-RICE-BOWL', 'Bowl', null, 1, 'bowl', 1, 160, 'GST 5%', true],
      ['BUTTER-NAAN', 'BUTTER-NAAN-1', '1 piece', null, 1, 'piece', 1, 60, 'GST 5%', true],
      ['GULAB-JAMUN', 'GULAB-JAMUN-2', '2 pieces', null, 2, 'piece', 1, 90, 'GST 18%', true],
    ],
  },
  {
    sheet: 'Recipes',
    purpose: 'Optional (needs inventory in your plan). What ONE sold unit of a size takes from stock. Sizes without rows here use the full portion\'s recipe × their portion_ratio.',
    columns: [
      { name: 'variant_code', required: 'yes', meaning: 'The size this ingredient line belongs to.', example: 'BIRYANI-FULL' },
      { name: 'ingredient_sku', required: 'yes', meaning: 'SKU of a product already in Inventory (import inventory first).', example: 'RICE-BAS' },
      { name: 'consumption_quantity', required: 'yes', meaning: 'How much one sold unit uses (a number above 0).', example: '300' },
      { name: 'consumption_unit', required: 'yes', meaning: 'Unit of that quantity; must convert to the product\'s base unit (g ↔ kg, ml ↔ l) or be its purchase unit.', example: 'g' },
    ],
    rows: [
      ['BIRYANI-FULL', 'RICE-BAS', 300, 'g'],
      ['BIRYANI-FULL', 'CHK-CURRY', 250, 'g'],
      ['BIRYANI-FULL', 'OIL-SUN', 30, 'ml'],
      ['BIRYANI-HALF', 'RICE-BAS', 170, 'g'],
      ['BIRYANI-HALF', 'CHK-CURRY', 140, 'g'],
      ['COLA-500', 'COLA-500ML-BTL', 1, 'bottle'],
      ['WATER-500', 'WATER-500ML-BTL', 1, 'bottle'],
      ['WATER-1L', 'WATER-1L-BTL', 1, 'bottle'],
    ],
  },
];

/** Inventory workbook: products with units and costs, and opening stock (which becomes ledger movements). */
export const INVENTORY_SHEETS: SheetSpec[] = [
  {
    sheet: 'Products',
    purpose: 'One row per stock item. sku is the stable key: updates match on it. Current stock is NOT a column — it comes only from movements.',
    columns: [
      { name: 'sku', required: 'yes', meaning: 'Stable product code (letters, digits, - _ .).', example: 'RICE-BAS' },
      { name: 'product_name', required: 'create', meaning: 'Name staff see.', example: 'Basmati rice' },
      { name: 'category', required: 'no', meaning: 'Free text for grouping and valuation.', example: 'Grains' },
      { name: 'base_unit', required: 'create', meaning: 'Unit stock is counted in (g, kg, ml, l, piece, bottle, can, packet, box). Cannot change once stock has moved.', example: 'g' },
      { name: 'purchase_unit', required: 'create', meaning: 'Unit you buy in, e.g. kg, l, case.', example: 'kg' },
      { name: 'conversion_factor', required: 'create', meaning: 'How many base units are in ONE purchase unit. kg → g = 1000; case of 24 bottles → 24.', example: '1000' },
      { name: 'unit_cost', required: 'no', meaning: 'Cost in rupees of ONE purchase unit (e.g. ₹ per kg).', example: '60' },
      { name: 'minimum_stock', required: 'no', meaning: 'Reorder level in BASE units; at or below it the product shows as Low.', example: '5000' },
      { name: 'supplier', required: 'no', meaning: 'Usual supplier by name (created if new).', example: 'Sharma Traders' },
      { name: 'storage_location', required: 'no', meaning: 'Where it is kept by default (created if new).', example: 'Dry store' },
      { name: 'active', required: 'no', meaning: 'TRUE or FALSE. Blank = TRUE when creating.', example: 'TRUE' },
    ],
    rows: [
      ['RICE-BAS', 'Basmati rice', 'Grains', 'g', 'kg', 1000, 60, 5000, 'Sharma Traders', 'Dry store', true],
      ['CHK-CURRY', 'Chicken (curry cut)', 'Meat', 'g', 'kg', 1000, 240, 3000, 'Fresh Farms', 'Walk-in cooler', true],
      ['OIL-SUN', 'Sunflower oil', 'Oils', 'ml', 'l', 1000, 140, 2000, 'Sharma Traders', 'Dry store', true],
      ['PANEER', 'Paneer', 'Dairy', 'g', 'kg', 1000, 380, 2000, 'Fresh Farms', 'Walk-in cooler', true],
      ['COLA-500ML-BTL', 'Cola 500 ml bottle', 'Packaged drinks', 'bottle', 'case', 24, 720, 24, 'City Beverages', 'Bar', true],
      ['WATER-500ML-BTL', 'Water 500 ml bottle', 'Packaged drinks', 'bottle', 'case', 24, 240, 24, 'City Beverages', 'Bar', true],
      ['WATER-1L-BTL', 'Water 1 litre bottle', 'Packaged drinks', 'bottle', 'case', 12, 216, 12, 'City Beverages', 'Bar', true],
    ],
  },
  {
    sheet: 'OpeningStock',
    purpose: 'Optional. Stock you already have when you start. Each row becomes an "opening stock" movement in the ledger — once: a product that already has opening stock at that location is refused, and re-importing the same file adds nothing.',
    columns: [
      { name: 'sku', required: 'yes', meaning: 'Product (from the Products sheet or already in Inventory).', example: 'RICE-BAS' },
      { name: 'quantity', required: 'yes', meaning: 'How much you have (a number above 0) in "unit".', example: '25' },
      { name: 'unit', required: 'yes', meaning: 'The product\'s base or purchase unit, or one that converts (kg ↔ g, l ↔ ml).', example: 'kg' },
      { name: 'unit_cost', required: 'no', meaning: 'Rupees for ONE "unit" of this stock. Blank = the product\'s unit_cost.', example: '60' },
      { name: 'storage_location', required: 'no', meaning: 'Where it is (created if new). Blank = the product\'s default.', example: 'Dry store' },
      { name: 'batch_number', required: 'no', meaning: 'Supplier batch / lot, for expiry tracking.', example: 'B-0912' },
      { name: 'expiry_date', required: 'no', meaning: 'YYYY-MM-DD. Shows in expiry alerts 7 days before.', example: '2027-03-31' },
    ],
    rows: [
      ['RICE-BAS', 25, 'kg', 60, 'Dry store', 'B-0912', '2027-03-31'],
      ['CHK-CURRY', 8000, 'g', 0.24, 'Walk-in cooler', 'CH-1410', '2026-10-17'],
      ['OIL-SUN', 15, 'l', 140, 'Dry store', null, null],
      ['PANEER', 3, 'kg', 380, 'Walk-in cooler', 'PN-77', '2026-10-20'],
      ['COLA-500ML-BTL', 2, 'case', 720, 'Bar', null, '2027-01-15'],
      ['WATER-500ML-BTL', 48, 'bottle', 10, 'Bar', null, null],
      ['WATER-1L-BTL', 1, 'case', 216, 'Bar', null, null],
    ],
  },
];

const req = (r: ColumnSpec['required']) => (r === 'yes' ? 'Required' : r === 'create' ? 'Required to create (blank keeps the value on update)' : 'Optional');

/** Builds a sample workbook: an Instructions sheet first, then one sheet per data table with example rows. */
export async function buildTemplate(kind: 'menu' | 'inventory'): Promise<Buffer> {
  const sheets = kind === 'menu' ? MENU_SHEETS : INVENTORY_SHEETS;
  const wb = new ExcelJS.Workbook();
  wb.creator = 'House Plating';
  wb.created = new Date('2026-10-14T00:00:00Z');
  const ins = wb.addWorksheet('Instructions');
  ins.columns = [{ width: 22 }, { width: 18 }, { width: 70 }, { width: 22 }];
  ins.addRow([`House Plating — ${kind === 'menu' ? 'menu' : 'inventory'} import template`]).font = { bold: true, size: 14 };
  const general = [
    'How to import: 1) fill the sheets below (keep the sheet names and the header row), 2) Menu or Inventory → Import → upload, 3) fix any errors shown by sheet, row and column, 4) check the preview, 5) confirm.',
    'Modes: "Create only" adds new codes and refuses codes that already exist. "Update existing" changes rows whose code already exists and refuses unknown codes. Rows are always matched by code, never by name.',
    'Blank cells: when creating, a blank optional cell takes the default; when updating, a blank cell keeps the current value. To clear a description write CLEAR.',
    'Amounts are rupees with up to 2 decimals (they are stored as paise). Quantities are plain numbers. Do not use formulas — paste values. Macro-enabled files (.xlsm) are refused.',
    kind === 'menu'
      ? 'Import inventory products first if you fill the Recipes sheet: recipes refer to product SKUs.'
      : 'Opening stock is recorded once per product and location as a ledger movement; it is not a product field and is never overwritten by later imports.',
  ];
  for (const g of general) ins.addRow([g]).alignment = { wrapText: true };
  for (const s of sheets) {
    ins.addRow([]);
    ins.addRow([`Sheet "${s.sheet}"`, '', s.purpose]).font = { bold: true };
    const h = ins.addRow(['Column', 'Required?', 'Meaning', 'Example']);
    h.font = { bold: true };
    for (const c of s.columns) ins.addRow([c.name, req(c.required), c.meaning, c.example]).alignment = { wrapText: true, vertical: 'top' };
  }
  for (const s of sheets) {
    const ws = wb.addWorksheet(s.sheet, { views: [{ state: 'frozen', ySplit: 1 }] });
    ws.columns = s.columns.map((c) => ({ header: c.name, key: c.name, width: Math.max(14, c.name.length + 4) }));
    ws.getRow(1).font = { bold: true };
    for (const r of s.rows) ws.addRow(r);
  }
  return Buffer.from(await wb.xlsx.writeBuffer());
}
