/** A photo ready for upload: prepared in the browser so uploads stay small (port of util/image_prep.dart). */
export type PreparedImage = { contentType: string; base64: string; dataUrl: string; bytes: number };

class ImageFormatError extends Error {}
export { ImageFormatError };

async function decode(file: Blob, message: string): Promise<HTMLImageElement> {
  const url = URL.createObjectURL(file);
  try {
    const img = new Image();
    img.src = url;
    await img.decode();
    return img;
  } catch {
    throw new ImageFormatError(message);
  } finally {
    setTimeout(() => URL.revokeObjectURL(url), 0);
  }
}

function out(canvas: HTMLCanvasElement, contentType: string, quality?: number): PreparedImage {
  const dataUrl = canvas.toDataURL(contentType, quality);
  const base64 = dataUrl.split(',')[1] ?? '';
  return { contentType, base64, dataUrl, bytes: Math.floor((base64.length * 3) / 4) };
}

/** Dish photo for `PUT /menu/items/:id/image`: square-cropped to 640 px and JPEG-compressed. */
export async function prepareDishPhoto(file: Blob, size = 640, quality = 0.82): Promise<PreparedImage> {
  const img = await decode(file, 'That file is not a photo we can read (use JPG, PNG or WebP).');
  const side = Math.min(img.naturalWidth, img.naturalHeight);
  const target = img.naturalWidth < size || img.naturalHeight < size ? side : size;
  const c = document.createElement('canvas');
  c.width = c.height = target;
  c.getContext('2d')!.drawImage(img, (img.naturalWidth - side) / 2, (img.naturalHeight - side) / 2, side, side, 0, 0, target, target);
  return out(c, 'image/jpeg', quality);
}

/** Restaurant logo for `PUT /tenant/branding/logo`: longest side at most 512 px, PNG so transparency survives. */
export async function prepareLogo(file: Blob, maxSide = 512): Promise<PreparedImage> {
  const img = await decode(file, 'That file is not an image we can read (use JPG, PNG or WebP).');
  const k = Math.min(1, maxSide / Math.max(img.naturalWidth, img.naturalHeight));
  const c = document.createElement('canvas');
  c.width = Math.round(img.naturalWidth * k);
  c.height = Math.round(img.naturalHeight * k);
  c.getContext('2d')!.drawImage(img, 0, 0, c.width, c.height);
  return out(c, 'image/png');
}

/** Floor plans keep their aspect ratio (longest side 1200 px), with a bounded upload size. */
export async function prepareFloorPhoto(file: Blob): Promise<PreparedImage> {
  if (file.size > 15 * 1024 * 1024) throw new ImageFormatError('Choose an image smaller than 15 MB.');
  const img = await decode(file, 'Choose a JPG, PNG or WebP floor image.');
  const k = 1200 / Math.max(img.naturalWidth, img.naturalHeight);
  const c = document.createElement('canvas');
  c.width = Math.round(img.naturalWidth * k);
  c.height = Math.round(img.naturalHeight * k);
  c.getContext('2d')!.drawImage(img, 0, 0, c.width, c.height);
  const r = out(c, 'image/jpeg', 0.72);
  if (r.bytes > 650000) throw new ImageFormatError('This image is too detailed. Choose a smaller floor plan.');
  return r;
}
