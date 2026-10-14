/** Writes the sample import workbooks to docs/templates (the API serves the same files from buildTemplate). */
import { mkdirSync, writeFileSync } from 'fs';
import { resolve } from 'path';
import { buildTemplate } from '../src/imports/templates';

(async () => {
  const dir = resolve(__dirname, '../../../docs/templates');
  mkdirSync(dir, { recursive: true });
  for (const kind of ['menu', 'inventory'] as const) {
    const file = resolve(dir, `house-plating-${kind}-import-template.xlsx`);
    writeFileSync(file, await buildTemplate(kind));
    console.log(`wrote ${file}`);
  }
})();
