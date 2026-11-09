import { promises as fs } from 'fs';
import * as os from 'os';
import * as path from 'path';
import { ColdStorage } from '../src/storage/cold-storage';

/** Regression: archiving on a server whose cold-storage folder is not writable returned a bare 500. */
describe('ColdStorage', () => {
  const prev = process.env.COLD_STORAGE_DIR;
  afterEach(() => {
    if (prev === undefined) delete process.env.COLD_STORAGE_DIR;
    else process.env.COLD_STORAGE_DIR = prev;
  });

  it('round-trips a bundle with BigInt values', async () => {
    process.env.COLD_STORAGE_DIR = await fs.mkdtemp(path.join(os.tmpdir(), 'cold-'));
    const cs = new ColdStorage();
    const put = await cs.put('restaurants/t/1-archive.json.gz', { seq: BigInt(42) });
    expect(await cs.readJson(put.key, put.sha256)).toEqual({ seq: '42' });
  });

  it('a folder the API cannot write to gives a 503 cold_storage_unavailable, not a 500', async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'cold-ro-'));
    await fs.chmod(dir, 0o500);
    process.env.COLD_STORAGE_DIR = dir;
    try {
      await expect(new ColdStorage().put('restaurants/t/2-archive.json.gz', {})).rejects.toMatchObject({
        status: 503,
        response: expect.objectContaining({ code: 'cold_storage_unavailable' }),
      });
    } finally {
      await fs.chmod(dir, 0o700);
    }
  });
});
