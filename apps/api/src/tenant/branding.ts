import { z } from 'zod';
import { badRequest } from '../common/errors';

/** Text style choices that work on every platform with the bundled fonts (no extra font files). */
export const BrandingBody = z.object({
  color: z.string().regex(/^#[0-9A-Fa-f]{6}$/, 'Colour must look like #1A73E8'),
  textSize: z.enum(['compact', 'standard', 'large']),
  headingWeight: z.enum(['regular', 'bold', 'heavy']),
  headingCase: z.enum(['normal', 'upper']),
});
export type Branding = z.infer<typeof BrandingBody> & { logoImageId: string | null };

export const DEFAULT_BRANDING: Branding = { color: '#6B1F2A', textSize: 'standard', headingWeight: 'bold', headingCase: 'normal', logoImageId: null };

/** Stored branding merged over the defaults; null when the plan does not include it (apps use the House Plating look). */
export function effectiveBranding(stored: unknown, features: string[]): Branding | null {
  if (!features.includes('branding') || !stored || typeof stored !== 'object') return null;
  const parsed = BrandingBody.partial().extend({ logoImageId: z.string().uuid().nullable().optional() }).safeParse(stored);
  return parsed.success ? { ...DEFAULT_BRANDING, ...parsed.data } : null;
}

export const ImageBody = z.object({
  contentType: z.enum(['image/jpeg', 'image/png', 'image/webp']),
  // the console resizes before upload; 1.5 MB of base64 ≈ 1.1 MB image
  dataBase64: z.string().min(16).max(1_600_000),
});

/** Decodes and checks an uploaded image (size and file signature must match the declared type). */
export function decodeImage(b: z.infer<typeof ImageBody>): Buffer {
  const bytes = Buffer.from(b.dataBase64, 'base64');
  if (bytes.length < 64 || bytes.length > 1_200_000) throw badRequest('bad_image', 'Image must be between 64 bytes and 1.2 MB');
  const magic: Record<string, (x: Buffer) => boolean> = {
    'image/jpeg': (x) => x[0] === 0xff && x[1] === 0xd8,
    'image/png': (x) => x.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])),
    'image/webp': (x) => x.subarray(0, 4).toString('ascii') === 'RIFF' && x.subarray(8, 12).toString('ascii') === 'WEBP',
  };
  if (!magic[b.contentType](bytes)) throw badRequest('bad_image', `File is not a valid ${b.contentType}`);
  return bytes;
}
