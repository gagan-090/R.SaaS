import { Injectable, NotImplementedException } from '@nestjs/common';
import { createHash } from 'crypto';
import { promises as fs } from 'fs';
import * as path from 'path';
import { gunzipSync, gzipSync } from 'zlib';
import { badRequest } from '../common/errors';

/**
 * Cold storage for restaurant log archives and old audit events. Bundles are gzip-compressed JSON with a SHA-256
 * checksum recorded in the database, so a copy is verified before it is trusted again.
 *
 * Drivers: "file" (default) writes under COLD_STORAGE_DIR — a folder that can be a mounted backup disk or synced to
 * an archive bucket. "s3" (an S3 Glacier / Deep Archive bucket) is not implemented yet: no cloud account is
 * configured for this project.
 */
@Injectable()
export class ColdStorage {
  get driver() {
    return (process.env.COLD_STORAGE ?? 'file') as 'file' | 's3';
  }

  private dir() {
    const d = process.env.COLD_STORAGE_DIR ?? '.localdb/cold-storage';
    return path.isAbsolute(d) ? d : path.resolve(__dirname, '../../../..', d);
  }

  private safe(key: string) {
    if (!/^[A-Za-z0-9/_.-]{3,200}$/.test(key) || key.includes('..')) throw badRequest('bad_key', 'Invalid archive key');
    return path.join(this.dir(), key);
  }

  /** Stores a JSON document compressed; returns its key, size and checksum. */
  async put(key: string, doc: unknown): Promise<{ storage: string; key: string; sha256: string; sizeBytes: number }> {
    if (this.driver !== 'file') throw new NotImplementedException('S3 cold storage is not implemented yet; use COLD_STORAGE=file');
    const bytes = gzipSync(Buffer.from(JSON.stringify(doc)));
    const file = this.safe(key);
    await fs.mkdir(path.dirname(file), { recursive: true });
    await fs.writeFile(file, bytes, { flag: 'wx' }); // never overwrite an existing archive
    return { storage: 'file', key, sha256: createHash('sha256').update(bytes).digest('hex'), sizeBytes: bytes.length };
  }

  /** The stored bytes after checking them against the recorded checksum. */
  async getVerified(key: string, sha256: string): Promise<Buffer> {
    if (this.driver !== 'file') throw new NotImplementedException('S3 cold storage is not implemented yet; use COLD_STORAGE=file');
    const bytes = await fs.readFile(this.safe(key)).catch(() => {
      throw badRequest('archive_missing', 'The archive file is not in cold storage any more');
    });
    if (createHash('sha256').update(bytes).digest('hex') !== sha256) throw badRequest('archive_corrupt', 'The archive does not match its checksum');
    return bytes;
  }

  async readJson<T>(key: string, sha256: string): Promise<T> {
    return JSON.parse(gunzipSync(await this.getVerified(key, sha256)).toString('utf8')) as T;
  }
}
