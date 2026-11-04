/** ₹ formatting for integer paise with Indian digit grouping (₹1,23,456.78). Display only. Port of ui_kit formatPaise. */
export function formatPaise(paise: number, symbol = true): string {
  const neg = paise < 0;
  const abs = Math.abs(Math.trunc(paise));
  const r = Math.floor(abs / 100).toString();
  const p = (abs % 100).toString().padStart(2, '0');
  let g: string;
  if (r.length <= 3) {
    g = r;
  } else {
    const head = r.substring(0, r.length - 3);
    const parts: string[] = [];
    for (let i = head.length; i > 0; i -= 2) parts.unshift(head.substring(Math.max(0, i - 2), i));
    g = `${parts.join(',')},${r.substring(r.length - 3)}`;
  }
  return `${neg ? '−' : ''}${symbol ? '₹' : ''}${g}.${p}`;
}

/** "₹1,670" — whole rupees drop the ".00". */
export function rupees(paise: number): string {
  const s = formatPaise(paise);
  return s.endsWith('.00') ? s.substring(0, s.length - 3) : s;
}

/** Same as rupees(); kept as its own name where the Flutter code used formatPaise(..).replaceAll('.00', ''). */
export const wholeRupees = (paise: number) => formatPaise(paise).replace('.00', '');

const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export function parseDate(iso: unknown): Date | null {
  if (iso == null || iso === '') return null;
  const d = new Date(String(iso));
  return isNaN(d.getTime()) ? null : d;
}

export function shortDate(iso: unknown): string {
  const d = parseDate(iso);
  if (!d) return '—';
  return `${d.getDate()} ${months[d.getMonth()]} ${d.getFullYear()}`;
}

const two = (n: number) => n.toString().padStart(2, '0');

/** "12 Oct 2026, 7:42 PM" */
export function dateTime12(iso: unknown): string {
  const t = parseDate(iso);
  if (!t) return '';
  const h = t.getHours() % 12 === 0 ? 12 : t.getHours() % 12;
  return `${shortDate(iso)}, ${h}:${two(t.getMinutes())} ${t.getHours() < 12 ? 'AM' : 'PM'}`;
}

/** "2026-10-12 19:42" */
export function isoMinute(iso: unknown): string {
  const d = parseDate(iso);
  if (!d) return '';
  return `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())} ${two(d.getHours())}:${two(d.getMinutes())}`;
}

/** "12/10 7:42 PM" */
export function clock(iso: unknown): string {
  const t = parseDate(iso);
  if (!t) return '—';
  const h = t.getHours() % 12 === 0 ? 12 : t.getHours() % 12;
  return `${t.getDate()}/${t.getMonth() + 1} ${h}:${two(t.getMinutes())} ${t.getHours() < 12 ? 'AM' : 'PM'}`;
}

export const hourLabel = (h: number) => `${h % 12 === 0 ? 12 : h % 12} ${h < 12 ? 'AM' : 'PM'}`;

/** "just now", "5 min ago", "3 h ago", "2 d ago" */
export function agoShort(iso: unknown): string {
  const d = parseDate(iso);
  if (!d) return '—';
  const m = Math.floor((Date.now() - d.getTime()) / 60000);
  if (m < 1) return 'just now';
  if (m < 60) return `${m} min ago`;
  if (m < 1440) return `${Math.floor(m / 60)} h ago`;
  return `${Math.floor(m / 1440)} d ago`;
}

/** Devices: "never" when unseen; a date after a day. */
export function ago(iso: unknown): string {
  const d = parseDate(iso);
  if (!d) return 'never';
  const m = Math.floor((Date.now() - d.getTime()) / 60000);
  if (m < 1) return 'just now';
  if (m < 60) return `${m} min ago`;
  if (m < 60 * 24) return `${Math.floor(m / 60)} h ago`;
  return shortDate(iso);
}

export function expiresIn(iso: unknown): string {
  const d = parseDate(iso);
  if (!d) return '—';
  const m = Math.floor((d.getTime() - Date.now()) / 60000);
  if (m <= 0) return `expired ${agoShort(iso)}`;
  if (m < 60) return `expires in ${m} min`;
  return `expires in ${Math.floor(m / 60)} h`;
}

/** Whole days between now and a date (negative once it has passed), like Dart's Duration.inDays. */
export function daysUntil(iso: unknown): number | null {
  const d = parseDate(iso);
  if (!d) return null;
  return Math.trunc((d.getTime() - Date.now()) / 86400000);
}

/** Local date as YYYY-MM-DD. */
export function todayIso(offsetDays = 0): string {
  const d = new Date(Date.now() + offsetDays * 86400000);
  return `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())}`;
}

/** "2 kg", "0.25 l" */
export function qtyText(q: number, unit: string): string {
  const n = Number(q);
  const text = n % 1 === 0 ? Math.trunc(n).toLocaleString('en-IN') : Number(n.toFixed(3)).toLocaleString('en-IN', { maximumFractionDigits: 3 });
  return `${text} ${unit}`;
}

export const firstChar = (s: unknown) => (`${s ?? ''}`.trim()[0] ?? '?').toUpperCase();
