import { badRequest } from './errors';

/**
 * Measurement units for menu servings, inventory stock and recipes. Quantities convert only within one dimension
 * (mass, volume, or one counted thing); "kg → g" works, "kg → ml" or "bottle → plate" is refused.
 * Inventory stores every quantity in the product's base unit; purchase units convert with the product's own factor.
 */
export const UNITS: Record<string, { dim: string; toBase: number; label: string }> = {
  mg: { dim: 'mass', toBase: 0.001, label: 'milligram' },
  g: { dim: 'mass', toBase: 1, label: 'gram' },
  kg: { dim: 'mass', toBase: 1000, label: 'kilogram' },
  ml: { dim: 'volume', toBase: 1, label: 'millilitre' },
  l: { dim: 'volume', toBase: 1000, label: 'litre' },
  piece: { dim: 'piece', toBase: 1, label: 'piece' },
  dozen: { dim: 'piece', toBase: 12, label: 'dozen' },
  plate: { dim: 'plate', toBase: 1, label: 'plate' },
  bowl: { dim: 'bowl', toBase: 1, label: 'bowl' },
  glass: { dim: 'glass', toBase: 1, label: 'glass' },
  cup: { dim: 'cup', toBase: 1, label: 'cup' },
  portion: { dim: 'portion', toBase: 1, label: 'portion' },
  bottle: { dim: 'bottle', toBase: 1, label: 'bottle' },
  can: { dim: 'can', toBase: 1, label: 'can' },
  packet: { dim: 'packet', toBase: 1, label: 'packet' },
  box: { dim: 'box', toBase: 1, label: 'box' },
  case: { dim: 'case', toBase: 1, label: 'case' },
};
export const UNIT_KEYS = Object.keys(UNITS) as [string, ...string[]];

export const compatible = (a: string, b: string) => !!UNITS[a] && !!UNITS[b] && UNITS[a].dim === UNITS[b].dim;

/** qty in `from` expressed in `to`; throws 400 "incompatible_units" across dimensions. Rounded to 3 decimals. */
export function convert(qty: number, from: string, to: string): number {
  if (!UNITS[from] || !UNITS[to]) throw badRequest('unknown_unit', `Unknown unit "${!UNITS[from] ? from : to}"`);
  if (!compatible(from, to)) throw badRequest('incompatible_units', `Cannot convert ${from} to ${to}`);
  return Math.round(((qty * UNITS[from].toBase) / UNITS[to].toBase) * 1000) / 1000;
}
