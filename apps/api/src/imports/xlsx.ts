import ExcelJS from 'exceljs';
import { badRequest } from '../common/errors';

export const MAX_FILE_BYTES = 5 * 1024 * 1024;

export interface CellIssue {
  sheet: string;
  row: number; // 1-based, as Excel shows it (0 = the sheet / file itself)
  column: string; // header name ('' when about the whole row or sheet)
  message: string;
  severity: 'error' | 'warning';
}

/** One data row: cell values by lower-case header, plus its row number. Values are never computed. */
export interface SheetRow {
  row: number;
  cells: Record<string, unknown>;
}

/**
 * Opens an uploaded workbook safely: .xlsx only (a ZIP; macro-enabled .xlsm and old .xls are refused), size-capped.
 * exceljs never runs macros; formula cells are reported as errors instead of trusting their cached results.
 */
export async function openWorkbook(fileName: string, bytes: Buffer): Promise<ExcelJS.Workbook> {
  if (!/\.xlsx$/i.test(fileName)) throw badRequest('bad_file_type', 'Upload an Excel .xlsx file (macro-enabled .xlsm and old .xls files are not accepted)');
  if (bytes.length === 0 || bytes.length > MAX_FILE_BYTES) throw badRequest('bad_file_size', 'The file must be between 1 byte and 5 MB');
  if (bytes[0] !== 0x50 || bytes[1] !== 0x4b) throw badRequest('bad_file_type', 'This is not a real .xlsx file');
  if (bytes.includes(Buffer.from('vbaProject.bin'))) throw badRequest('macros_not_allowed', 'This workbook contains macros. Save it as a plain .xlsx without macros.');
  const wb = new ExcelJS.Workbook();
  try {
    await wb.xlsx.load(bytes as unknown as ArrayBuffer);
  } catch {
    throw badRequest('bad_file', 'The file could not be read as an Excel workbook');
  }
  return wb;
}

/** Plain value of a cell; formulas are flagged (null value + issue), rich text flattened, dates kept as Date. */
function cellValue(c: ExcelJS.Cell): { value: unknown; formula: boolean } {
  const v = c.value as unknown;
  if (v === null || v === undefined) return { value: null, formula: false };
  if (typeof v === 'object' && v !== null) {
    if ('formula' in v || 'sharedFormula' in v) return { value: null, formula: true };
    if ('richText' in v) return { value: (v as ExcelJS.CellRichTextValue).richText.map((t) => t.text).join(''), formula: false };
    if ('text' in v && 'hyperlink' in v) return { value: (v as ExcelJS.CellHyperlinkValue).text, formula: false };
    if ('error' in v) return { value: null, formula: true };
    if (v instanceof Date) return { value: v, formula: false };
  }
  return { value: v, formula: false };
}

/**
 * Reads a sheet into rows keyed by its header names (row 1, case-insensitive). Missing required headers, unknown
 * headers (warning) and formula cells are reported; blank rows are skipped.
 */
export function readSheet(wb: ExcelJS.Workbook, name: string, required: string[], optional: string[], issues: CellIssue[], mustExist = true): SheetRow[] | null {
  const ws = wb.worksheets.find((w) => w.name.trim().toLowerCase() === name.toLowerCase());
  if (!ws) {
    if (mustExist) issues.push({ sheet: name, row: 0, column: '', message: `The "${name}" sheet is missing`, severity: 'error' });
    return null;
  }
  const headers: string[] = [];
  ws.getRow(1).eachCell({ includeEmpty: true }, (c, col) => {
    headers[col] = String(cellValue(c).value ?? '').trim().toLowerCase();
  });
  const known = [...required, ...optional];
  for (const h of required) if (!headers.includes(h)) issues.push({ sheet: name, row: 1, column: h, message: `Required column "${h}" is missing`, severity: 'error' });
  for (const h of headers) if (h && !known.includes(h)) issues.push({ sheet: name, row: 1, column: h, message: `Unknown column "${h}" is ignored`, severity: 'warning' });
  if (required.some((h) => !headers.includes(h))) return [];
  const rows: SheetRow[] = [];
  for (let r = 2; r <= ws.actualRowCount + 1 && r <= 20001; r++) {
    const row = ws.getRow(r);
    const cells: Record<string, unknown> = {};
    let any = false;
    headers.forEach((h, col) => {
      if (!h || !known.includes(h)) return;
      const { value, formula } = cellValue(row.getCell(col));
      if (formula) issues.push({ sheet: name, row: r, column: h, message: 'Formulas are not allowed; paste the value instead', severity: 'error' });
      const clean = typeof value === 'string' ? value.trim() : value;
      if (clean !== null && clean !== '') any = true;
      cells[h] = clean === '' ? null : clean;
    });
    if (any) rows.push({ row: r, cells });
  }
  if (ws.actualRowCount > 20001) issues.push({ sheet: name, row: 0, column: '', message: 'Only the first 20,000 rows are read', severity: 'warning' });
  return rows;
}

// ---------------------------------------------------------------- typed getters (they record issues and return null)

export class RowReader {
  constructor(private sheet: string, private r: SheetRow, private issues: CellIssue[]) {}
  private err(column: string, message: string) {
    this.issues.push({ sheet: this.sheet, row: this.r.row, column, message, severity: 'error' });
    return null;
  }
  blank(col: string) {
    const v = this.r.cells[col];
    return v === null || v === undefined;
  }
  text(col: string, { required = false, max = 200 } = {}): string | null {
    const v = this.r.cells[col];
    if (v === null || v === undefined) return required ? this.err(col, 'Required') : null;
    const s = (v instanceof Date ? v.toISOString().slice(0, 10) : String(v)).trim();
    if (s.length > max) return this.err(col, `Longer than ${max} characters`);
    return s;
  }
  code(col: string, required = true): string | null {
    const s = this.text(col, { required, max: 40 });
    if (s === null) return null;
    if (!/^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$/.test(s)) return this.err(col, 'Use letters, digits, - _ . (no spaces)');
    return s.toUpperCase();
  }
  number(col: string, { required = false, min = 0, positive = false, max = 1_000_000_000 } = {}): number | null {
    const v = this.r.cells[col];
    if (v === null || v === undefined) return required ? this.err(col, 'Required') : null;
    const n = typeof v === 'number' ? v : Number(String(v).replace(/,/g, ''));
    if (!Number.isFinite(n)) return this.err(col, `"${String(v)}" is not a number`);
    if (positive ? n <= 0 : n < min) return this.err(col, positive ? 'Must be more than 0' : `Must be ${min} or more`);
    if (n > max) return this.err(col, `Must be at most ${max}`);
    return n;
  }
  /** Rupees with up to 2 decimals → integer paise (never a float in the money path). */
  paise(col: string, required = false): number | null {
    const v = this.r.cells[col];
    if (v === null || v === undefined) return required ? this.err(col, 'Required') : null;
    const s = typeof v === 'number' ? v.toFixed(6) : String(v).replace(/[,₹\s]/g, '');
    const m = /^(\d{1,9})(?:\.(\d{1,6}))?$/.exec(s);
    if (!m) return this.err(col, `"${String(v)}" is not an amount in rupees (e.g. 249 or 249.50)`);
    const frac = (m[2] ?? '').padEnd(6, '0');
    if (/[1-9]/.test(frac.slice(2))) return this.err(col, 'Use at most 2 decimals (paise)');
    return Number(m[1]) * 100 + Number(frac.slice(0, 2));
  }
  bool(col: string): boolean | null {
    const v = this.r.cells[col];
    if (v === null || v === undefined) return null;
    if (typeof v === 'boolean') return v;
    const s = String(v).trim().toLowerCase();
    if (['true', 'yes', 'y', '1'].includes(s)) return true;
    if (['false', 'no', 'n', '0'].includes(s)) return false;
    return this.err(col, 'Use TRUE or FALSE');
  }
  date(col: string): string | null {
    const v = this.r.cells[col];
    if (v === null || v === undefined) return null;
    if (v instanceof Date) return v.toISOString().slice(0, 10);
    const s = String(v).trim();
    if (!/^\d{4}-\d{2}-\d{2}$/.test(s) || Number.isNaN(Date.parse(s))) return this.err(col, 'Use a date (YYYY-MM-DD)');
    return s;
  }
  enumOf<T extends string>(col: string, values: readonly T[], required = false): T | null {
    const s = this.text(col, { required });
    if (s === null) return null;
    const hit = values.find((x) => x.toLowerCase() === s.toLowerCase());
    return hit ?? this.err(col, `Use one of: ${values.join(', ')}`);
  }
  error(col: string, message: string) {
    this.err(col, message);
  }
}
