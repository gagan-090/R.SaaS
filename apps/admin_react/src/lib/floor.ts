/** Floor-plan model ported from packages/ui_kit/lib/src/floor.dart. Layout units ≈ cm; a table's x/y is its centre. */

export type Chair = { x: number; y: number; rotation: number };

export type FloorTable = {
  key: number; // stable React key for this editing session
  id: string | null;
  name: string;
  seats: number;
  shape: 'round' | 'square' | 'rect' | string;
  x: number;
  y: number;
  width: number;
  height: number;
  rotation: number;
  chairs: Chair[] | null; // null = arranged from the seat count
  status: string; // free | occupied | bill_printed | reserved | unavailable
};

let nextKey = 1;
export const newKey = () => nextKey++;

/** Chairs spread evenly: around a circle, or along the long sides of a rectangle (ends when needed). */
export function arrangeChairs(shape: string, w: number, h: number, seats: number): Chair[] {
  const gap = 18;
  if (seats <= 0) return [];
  if (shape === 'round') {
    const r = Math.max(w, h) / 2 + gap;
    return Array.from({ length: seats }, (_, i) => ({
      x: r * Math.cos((2 * Math.PI * i) / seats - Math.PI / 2),
      y: r * Math.sin((2 * Math.PI * i) / seats - Math.PI / 2),
      rotation: (Math.trunc((360 * i) / seats) + 180) % 360,
    }));
  }
  const out: Chair[] = [];
  const ends = seats > 4 && seats % 2 === 1 ? 1 : seats > 6 ? 2 : 0;
  const sides = seats - ends;
  const top = Math.ceil(sides / 2), bottom = sides - top;
  const row = (n: number, y: number, rot: number) => {
    for (let i = 0; i < n; i++) out.push({ x: -w / 2 + (w * (i + 1)) / (n + 1), y, rotation: rot });
  };
  row(top, -h / 2 - gap, 180);
  row(bottom, h / 2 + gap, 0);
  if (ends >= 1) out.push({ x: -w / 2 - gap, y: 0, rotation: 90 });
  if (ends >= 2) out.push({ x: w / 2 + gap, y: 0, rotation: 270 });
  return out;
}

export const effectiveChairs = (t: FloorTable) => t.chairs ?? arrangeChairs(t.shape, t.width, t.height, t.seats);

/** Axis-aligned bounds of the rotated table (no chairs) — used for overlap warnings. */
export function bounds(t: FloorTable) {
  if (t.shape === 'round') {
    const r = Math.max(t.width, t.height) / 2;
    return { l: t.x - r, t: t.y - r, r: t.x + r, b: t.y + r };
  }
  const a = (t.rotation * Math.PI) / 180;
  const hw = (t.width * Math.abs(Math.cos(a)) + t.height * Math.abs(Math.sin(a))) / 2;
  const hh = (t.width * Math.abs(Math.sin(a)) + t.height * Math.abs(Math.cos(a))) / 2;
  return { l: t.x - hw, t: t.y - hh, r: t.x + hw, b: t.y + hh };
}

type Rect = { l: number; t: number; r: number; b: number };
export const overlaps = (a: Rect, b: Rect) => a.l < b.r && b.l < a.r && a.t < b.b && b.t < a.b;

/** Side of the square box that holds the table, its chairs and any rotation. */
export const box = (t: FloorTable) => Math.max(t.width, t.height) + 2 * 46;

/** Overlapping pairs (by name) — a warning, not an error. */
export function floorOverlaps(ts: FloorTable[]): [string, string][] {
  const out: [string, string][] = [];
  for (let i = 0; i < ts.length; i++) for (let j = i + 1; j < ts.length; j++) if (overlaps(bounds(ts[i]), bounds(ts[j]))) out.push([ts[i].name, ts[j].name]);
  return out;
}

export function tableToJson(t: FloorTable) {
  return {
    ...(t.id != null ? { id: t.id } : {}),
    name: t.name, seats: t.seats, shape: t.shape, x: Math.round(t.x), y: Math.round(t.y),
    width: Math.round(t.width), height: Math.round(t.height), rotation: t.rotation,
    chairs: t.chairs?.map((c) => ({ x: Math.round(c.x), y: Math.round(c.y), rotation: c.rotation })) ?? null,
  };
}

/** From the cloud API (`x`, `y`) or the hub (`pos_x`, `pos_y`); [status] is the live state. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function tableFromJson(j: any, status?: string): FloorTable {
  return {
    key: newKey(),
    id: j.id ?? null,
    name: `${j.name}`,
    seats: Number(j.seats ?? 4),
    shape: `${j.shape ?? 'square'}`,
    x: Number(j.x ?? j.pos_x ?? 120),
    y: Number(j.y ?? j.pos_y ?? 120),
    width: Number(j.width ?? 80),
    height: Number(j.height ?? 80),
    rotation: Number(j.rotation ?? 0),
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    chairs: Array.isArray(j.chairs) ? j.chairs.map((c: any) => ({ x: Number(c.x), y: Number(c.y), rotation: Number(c.rotation ?? 0) })) : null,
    status: status ?? `${j.status ?? 'free'}`,
  };
}

/** Colour role and label of a table state on the plan. Colour is always paired with a word in the legend. */
export function floorStateStyle(status: string): { cls: string; label: string } {
  switch (status) {
    case 'occupied': return { cls: 'occupied', label: 'Occupied' };
    case 'bill_printed': case 'billing': return { cls: 'billed', label: 'Bill printed' };
    case 'reserved': return { cls: 'reserved', label: 'Reserved' };
    case 'unavailable': return { cls: 'unavailable', label: 'Out of use' };
    default: return { cls: 'free', label: 'Available' };
  }
}
