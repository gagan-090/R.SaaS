/** A restaurant's own look (plan feature "branding"): highlight colour, text size, heading weight and case, logo. Port of HPBrand. */

export type Brand = {
  color: string; // #RRGGBB
  textSize: 'compact' | 'standard' | 'large' | string;
  headingWeight: 'regular' | 'bold' | 'heavy' | string;
  headingCase: 'normal' | 'upper' | string;
  logoImageId: string | null;
};

export function brandFromJson(j: unknown): Brand | null {
  if (!j || typeof j !== 'object') return null;
  const m = j as Record<string, unknown>;
  const hex = `${m.color ?? ''}`.replace('#', '');
  if (!/^[0-9A-Fa-f]{6}$/.test(hex)) return null;
  return {
    color: `#${hex.toUpperCase()}`,
    textSize: `${m.textSize ?? 'standard'}`,
    headingWeight: `${m.headingWeight ?? 'bold'}`,
    headingCase: `${m.headingCase ?? 'normal'}`,
    logoImageId: (m.logoImageId as string | null) ?? null,
  };
}

export const textScale = (b: Brand | null) => (b?.textSize === 'compact' ? 0.92 : b?.textSize === 'large' ? 1.12 : 1);
export const weightOf = (b: Brand | null) => (b?.headingWeight === 'regular' ? 400 : b?.headingWeight === 'heavy' ? 900 : 700);

// ---- colour maths (sRGB relative luminance, HSL lightness steps — same as Flutter's computeLuminance / HSLColor)
type RGB = [number, number, number];
const toRgb = (hex: string): RGB => {
  const h = hex.replace('#', '');
  return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
};
const toHex = ([r, g, b]: RGB) => `#${[r, g, b].map((v) => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, '0')).join('').toUpperCase()}`;
const lin = (c: number) => {
  const s = c / 255;
  return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
};
export const luminance = (hex: string) => {
  const [r, g, b] = toRgb(hex);
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
};

function rgbToHsl([r, g, b]: RGB): [number, number, number] {
  r /= 255; g /= 255; b /= 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b);
  const l = (max + min) / 2;
  if (max === min) return [0, 0, l];
  const d = max - min;
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  let h = max === r ? (g - b) / d + (g < b ? 6 : 0) : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
  h *= 60;
  return [h, s, l];
}
function hslToRgb([h, s, l]: [number, number, number]): RGB {
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = l - c / 2;
  const [r, g, b] = h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x] : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x];
  return [(r + m) * 255, (g + m) * 255, (b + m) * 255];
}

/** Text on a fill of [hex]: dark on light colours, white on dark ones. */
export const onColor = (hex: string) => (luminance(hex) > 0.45 ? '#16181D' : '#FFFFFF');

/** The brand colour adjusted so text in it stays readable (≥ 4.5:1) on the page: darker on white, lighter on dark. */
export function inkOn(hex: string, dark: boolean): string {
  const ground = dark ? '#140D0C' : '#FFFFFF';
  const lg = luminance(ground);
  const contrast = (c: string) => {
    const la = luminance(c);
    return la > lg ? (la + 0.05) / (lg + 0.05) : (lg + 0.05) / (la + 0.05);
  };
  let hsl = rgbToHsl(toRgb(hex));
  let c = hex;
  for (let i = 0; i < 40 && contrast(c) < 4.5; i++) {
    hsl = [hsl[0], hsl[1], Math.max(0, Math.min(1, hsl[2] + (dark ? 0.025 : -0.025)))];
    c = toHex(hslToRgb(hsl));
  }
  return c;
}

/** CSS custom properties that put the brand on the House Plating palette (null = House Plating look). */
export function brandVars(b: Brand | null, dark: boolean): Record<string, string> {
  if (!b) return {};
  const fill = dark ? inkOn(b.color, true) : b.color;
  return {
    '--accent': fill,
    '--on-accent': onColor(fill),
    '--accent-ink': inkOn(b.color, dark),
    '--brand': fill,
    '--on-brand': onColor(fill),
    '--highlight': b.color,
    '--on-highlight': onColor(b.color),
    '--nav-accent': b.color,
    '--on-nav-accent': onColor(b.color),
    '--heading-weight': `${weightOf(b)}`,
    '--heading-transform': b.headingCase === 'upper' ? 'uppercase' : 'none',
    '--text-scale': `${textScale(b)}`,
  };
}
