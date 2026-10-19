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

export const MENU_UNITS = ['ml', 'l', 'g', 'kg', 'piece', 'plate', 'bowl', 'glass', 'cup', 'portion', 'bottle', 'can', 'packet'];
export const STOCK_UNITS = ['g', 'kg', 'ml', 'l', 'piece', 'bottle', 'can', 'packet', 'box', 'case'];

/**
 * Menu workbook: dishes, their sizes with prices, and (optionally) what each size uses from stock. The wording is for
 * restaurant owners, not developers: a short note per column and a few sample rows to copy.
 */
export const MENU_SHEETS: SheetSpec[] = [
  {
    sheet: 'Items',
    purpose: 'One row per dish or drink.',
    columns: [
      { name: 'item_code', required: 'yes', meaning: 'A short code for the dish, e.g. BIRYANI. Letters, numbers and - only. Every dish gets its own code.', example: 'BIRYANI' },
      { name: 'item_name', required: 'create', meaning: 'The dish name as it should appear on the bill.', example: 'Chicken Biryani' },
      { name: 'category', required: 'create', meaning: 'Menu section, e.g. Starters or Main Course. New sections are created for you.', example: 'Main Course' },
      { name: 'description', required: 'no', meaning: 'Optional short line about the dish.', example: 'Served with raita' },
      { name: 'active', required: 'no', meaning: 'TRUE to show it on the POS, FALSE to hide it. Leave blank for TRUE.', example: 'TRUE' },
    ],
    rows: [
      ['PANEER-TIKKA', 'Paneer Tikka', 'Starters', null, true],
      ['COLA', 'Cola', 'Soft Drinks', 'Chilled', true],
      ['BIRYANI', 'Chicken Biryani', 'Main Course', 'Served with raita', true],
      ['GULAB-JAMUN', 'Gulab Jamun', 'Desserts', '2 pieces', true],
    ],
  },
  {
    sheet: 'Variants',
    purpose: 'Sizes and prices: one row per size of a dish (a dish with one size gets one row). Each size has its own price.',
    columns: [
      { name: 'item_code', required: 'yes', meaning: 'The dish code from the Items sheet.', example: 'BIRYANI' },
      { name: 'variant_code', required: 'yes', meaning: 'A code for this size, e.g. BIRYANI-HALF. No two sizes may share a code.', example: 'BIRYANI-HALF' },
      { name: 'variant_name', required: 'create', meaning: 'Size name staff see, e.g. Half plate or 500 ml. Write Regular if the dish has only one size.', example: 'Half plate' },
      { name: 'portion_label', required: 'no', meaning: 'Optional: half or full.', example: 'half' },
      { name: 'serving_quantity', required: 'no', meaning: 'Optional: how much is served, e.g. 500 (together with serving_unit ml).', example: '1' },
      { name: 'serving_unit', required: 'no', meaning: `Optional: ${MENU_UNITS.join(', ')}.`, example: 'plate' },
      { name: 'portion_ratio', required: 'no', meaning: 'Optional, only used for stock recipes: full = 1, half = 0.5. Leave blank if unsure.', example: '0.5' },
      { name: 'selling_price', required: 'create', meaning: 'Price in rupees before GST, e.g. 220 or 99.50.', example: '220' },
      { name: 'tax_code', required: 'create', meaning: 'GST rate, e.g. GST 5% or just 5. The rate must already exist in Settings.', example: 'GST 5%' },
      { name: 'available', required: 'no', meaning: 'TRUE if it can be sold now, FALSE if sold out. Leave blank for TRUE.', example: 'TRUE' },
    ],
    rows: [
      ['PANEER-TIKKA', 'PANEER-TIKKA-6', '6 pieces', null, 6, 'piece', 1, 260, 'GST 5%', true],
      ['COLA', 'COLA-250', '250 ml', null, 250, 'ml', 0.5, 30, 'GST 18%', true],
      ['COLA', 'COLA-500', '500 ml', null, 500, 'ml', 1, 50, 'GST 18%', true],
      ['BIRYANI', 'BIRYANI-HALF', 'Half plate', 'half', 1, 'plate', 0.5, 220, 'GST 5%', true],
      ['BIRYANI', 'BIRYANI-FULL', 'Full plate', 'full', 1, 'plate', 1, 400, 'GST 5%', true],
      ['GULAB-JAMUN', 'GULAB-JAMUN-2', '2 pieces', null, 2, 'piece', 1, 90, 'GST 18%', true],
    ],
  },
  {
    sheet: 'Recipes',
    purpose: 'Optional — fill only if you track stock in Inventory. What ONE sold plate / glass of a size uses. Sizes without rows use the full size × portion_ratio.',
    columns: [
      { name: 'variant_code', required: 'yes', meaning: 'The size code from the Variants sheet.', example: 'BIRYANI-FULL' },
      { name: 'ingredient_sku', required: 'yes', meaning: 'Code of a product already in Inventory (import inventory first).', example: 'RICE-BAS' },
      { name: 'consumption_quantity', required: 'yes', meaning: 'How much one serving uses, e.g. 300.', example: '300' },
      { name: 'consumption_unit', required: 'yes', meaning: 'Unit of that amount, e.g. g, kg, ml, l, bottle.', example: 'g' },
    ],
    rows: [
      ['BIRYANI-FULL', 'RICE-BAS', 300, 'g'],
      ['BIRYANI-FULL', 'CHK-CURRY', 250, 'g'],
      ['BIRYANI-FULL', 'OIL-SUN', 30, 'ml'],
      ['COLA-500', 'COLA-500ML-BTL', 1, 'bottle'],
    ],
  },
];

/** Inventory workbook: products with units and costs, and the stock you already have. */
export const INVENTORY_SHEETS: SheetSpec[] = [
  {
    sheet: 'Products',
    purpose: 'One row per thing you keep in stock.',
    columns: [
      { name: 'sku', required: 'yes', meaning: 'A short code for the product, e.g. RICE-BAS. Letters, numbers and - only.', example: 'RICE-BAS' },
      { name: 'product_name', required: 'create', meaning: 'Product name staff see.', example: 'Basmati rice' },
      { name: 'category', required: 'no', meaning: 'Optional group, e.g. Grains, Dairy, Packaged drinks.', example: 'Grains' },
      { name: 'base_unit', required: 'create', meaning: `Unit you count and use it in, e.g. g for rice. One of: ${STOCK_UNITS.join(', ')}.`, example: 'g' },
      { name: 'purchase_unit', required: 'create', meaning: 'Unit you buy it in, e.g. kg. Can be the same as base_unit.', example: 'kg' },
      { name: 'conversion_factor', required: 'create', meaning: 'How many base units are in one purchase unit: 1 kg = 1000 g → 1000. Same unit → 1. A case of 24 bottles → 24.', example: '1000' },
      { name: 'unit_cost', required: 'no', meaning: 'Price in rupees of one purchase unit, e.g. 60 per kg.', example: '60' },
      { name: 'minimum_stock', required: 'no', meaning: 'Optional: warn me when stock falls to this many base units.', example: '5000' },
      { name: 'supplier', required: 'no', meaning: 'Optional: who you usually buy from.', example: 'Sharma Traders' },
      { name: 'storage_location', required: 'no', meaning: 'Optional: where it is kept, e.g. Dry store.', example: 'Dry store' },
      { name: 'active', required: 'no', meaning: 'TRUE or FALSE. Leave blank for TRUE.', example: 'TRUE' },
    ],
    rows: [
      ['RICE-BAS', 'Basmati rice', 'Grains', 'g', 'kg', 1000, 60, 5000, 'Sharma Traders', 'Dry store', true],
      ['CHK-CURRY', 'Chicken (curry cut)', 'Meat', 'g', 'kg', 1000, 240, 3000, 'Fresh Farms', 'Walk-in cooler', true],
      ['OIL-SUN', 'Sunflower oil', 'Oils', 'ml', 'l', 1000, 140, 2000, 'Sharma Traders', 'Dry store', true],
      ['COLA-500ML-BTL', 'Cola 500 ml bottle', 'Packaged drinks', 'bottle', 'case', 24, 720, 24, 'City Beverages', 'Bar', true],
    ],
  },
  {
    sheet: 'OpeningStock',
    purpose: 'Optional: the stock you have today. Recorded once — importing the same file again adds nothing.',
    columns: [
      { name: 'sku', required: 'yes', meaning: 'Product code from the Products sheet.', example: 'RICE-BAS' },
      { name: 'quantity', required: 'yes', meaning: 'How much you have now, e.g. 25.', example: '25' },
      { name: 'unit', required: 'yes', meaning: 'Unit of that amount, e.g. kg (or the product\'s base unit).', example: 'kg' },
      { name: 'unit_cost', required: 'no', meaning: 'Optional: rupees for one unit. Blank = the product\'s unit_cost.', example: '60' },
      { name: 'storage_location', required: 'no', meaning: 'Optional: where it is. Blank = the product\'s usual place.', example: 'Dry store' },
      { name: 'batch_number', required: 'no', meaning: 'Optional: supplier batch number.', example: 'B-0912' },
      { name: 'expiry_date', required: 'no', meaning: 'Optional: date as YYYY-MM-DD, e.g. 2027-03-31.', example: '2027-03-31' },
    ],
    rows: [
      ['RICE-BAS', 25, 'kg', 60, 'Dry store', 'B-0912', '2027-03-31'],
      ['CHK-CURRY', 8000, 'g', 0.24, 'Walk-in cooler', 'CH-1410', '2026-10-17'],
      ['OIL-SUN', 15, 'l', 140, 'Dry store', null, null],
      ['COLA-500ML-BTL', 2, 'case', 720, 'Bar', null, '2027-01-15'],
    ],
  },
];

const mustFill = (r: ColumnSpec['required']) => (r === 'no' ? 'Optional' : 'Yes');

/** "item_code" → "Item code *" (required) / "Description" (optional). The importer reads either spelling. */
export const headerLabel = (c: ColumnSpec) => `${c.name[0].toUpperCase()}${c.name.slice(1).replace(/_/g, ' ')}${c.required === 'no' ? '' : ' *'}`;

/** ExcelJS 4 supports range validations at runtime but its typings omit them. */
type RangeValidations = { dataValidations: { add(range: string, v: ExcelJS.DataValidation): void } };

const BOOLEAN_COLUMNS = new Set(['active', 'available']);
const UNIT_LISTS: Record<string, string[]> = {
  serving_unit: MENU_UNITS, base_unit: STOCK_UNITS, purchase_unit: STOCK_UNITS, unit: STOCK_UNITS, consumption_unit: STOCK_UNITS,
};

/**
 * Builds the sample workbook: the data sheets first (so the file opens on the rows to fill), each with a coloured
 * header (* = must fill), a hover note per column, drop-downs for TRUE/FALSE and units, and a few sample rows;
 * a short "How to fill" sheet comes last.
 */
export async function buildTemplate(kind: 'menu' | 'inventory'): Promise<Buffer> {
  const sheets = kind === 'menu' ? MENU_SHEETS : INVENTORY_SHEETS;
  const wb = new ExcelJS.Workbook();
  wb.creator = 'House Plating';
  wb.created = new Date('2026-10-14T00:00:00Z');
  for (const s of sheets) {
    const ws = wb.addWorksheet(s.sheet, { views: [{ state: 'frozen', ySplit: 1 }] });
    ws.columns = s.columns.map((c) => ({ header: headerLabel(c), key: c.name, width: Math.max(16, headerLabel(c).length + 6) }));
    const head = ws.getRow(1);
    head.height = 22;
    s.columns.forEach((c, i) => {
      const cell = head.getCell(i + 1);
      const required = c.required !== 'no';
      cell.font = { bold: true, color: { argb: required ? 'FFFFFFFF' : 'FF3A2E2A' } };
      cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: required ? 'FF6B1E2B' : 'FFF1E6D6' } };
      cell.alignment = { vertical: 'middle' };
      cell.note = `${c.meaning}\nExample: ${c.example}`;
      const col = ws.getColumn(i + 1).letter;
      const list = BOOLEAN_COLUMNS.has(c.name) ? ['TRUE', 'FALSE'] : UNIT_LISTS[c.name];
      if (list) {
        // a drop-down that still accepts other values (warning only), so unusual units are not blocked
        (ws as unknown as RangeValidations).dataValidations.add(`${col}2:${col}1000`, {
          type: 'list', allowBlank: true, formulae: [`"${list.join(',')}"`], showErrorMessage: true, errorStyle: 'warning',
          errorTitle: 'Not in the list', error: `Usually one of: ${list.join(', ')}`,
        });
      }
    });
    for (const r of s.rows) ws.addRow(r);
  }

  const help = wb.addWorksheet('How to fill');
  help.columns = [{ width: 24 }, { width: 12 }, { width: 80 }, { width: 20 }];
  help.addRow([`How to fill the ${kind} template`]).font = { bold: true, size: 14 };
  const steps = kind === 'menu'
    ? [
        '1. Items: one row per dish. Variants: one row per size and price of that dish (one size → one row). Recipes is optional.',
        '2. Keep the first row (the column names). Dark columns marked * must be filled; light columns are optional. Hover over a column name to see what to write.',
        '3. The rows already there are examples. Overwrite them with your menu or add your dishes below them.',
        '4. Prices are in rupees, e.g. 220 or 99.50. Type plain values, not formulas.',
        '5. In the console: Menu → Import Excel → upload this file → check the preview → confirm. Any mistake is shown with its sheet, row and column.',
      ]
    : [
        '1. Products: one row per thing you keep in stock. OpeningStock (optional): how much you have today.',
        '2. Keep the first row (the column names). Dark columns marked * must be filled; light columns are optional. Hover over a column name to see what to write.',
        '3. The rows already there are examples. Overwrite them or add your products below them.',
        '4. Units: count rice in g but buy it in kg → base_unit g, purchase_unit kg, conversion_factor 1000. Same unit both ways → 1.',
        '5. In the console: Inventory → Import Excel → upload this file → check the preview → confirm.',
      ];
  for (const g of steps) help.addRow([g]).alignment = { wrapText: true };
  for (const s of sheets) {
    help.addRow([]);
    help.addRow([`Sheet "${s.sheet}"`, '', s.purpose]).font = { bold: true };
    const h = help.addRow(['Column', 'Must fill?', 'What to write', 'Example']);
    h.font = { bold: true };
    for (const c of s.columns) help.addRow([headerLabel(c).replace(' *', ''), mustFill(c.required), c.meaning, c.example]).alignment = { wrapText: true, vertical: 'top' };
  }
  help.addRow([]);
  help.addRow(['Changing things later: choose "Update existing" when importing. Rows are matched by their code; blank cells keep the current value.']).font = { italic: true, color: { argb: 'FF6B6B6B' } };
  return Buffer.from(await wb.xlsx.writeBuffer());
}
