import { useState } from 'react';
import { AlertCircle, Download, FileUp, Info } from 'lucide-react';
import { api, errorText, type Json } from '../../api/client';
import { rupees } from '../../lib/format';
import { fileToBase64, pickFile, saveFile } from '../../lib/download';
import { Check, PrimaryButton, Radio, SecondaryButton, TextButton } from '../../ui/kit';
import { Dialog } from '../../ui/overlay';

/** Picks an .xlsx file. Replaceable in tests. */
export const xlsxPicker = { pick: () => pickFile('.xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet') };

/**
 * Excel import for the menu or inventory: Download template → Upload → Validate → Preview → Confirm → Results.
 * Nothing is saved until the person confirms; with errors they can only import the valid rows on purpose.
 */
export function ImportDialog({ kind, close }: { kind: 'menu' | 'inventory'; close: (done?: boolean) => void }) {
  const menu = kind === 'menu';
  const [mode, setMode] = useState('create');
  const [job, setJob] = useState<Json | null>(null); // validated (or committed) import
  const [busy, setBusy] = useState(false);
  const [partial, setPartial] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const issues = (job?.issues ?? []) as Json[];
  const errors = issues.filter((i) => i.severity === 'error').length;
  const done = job?.status === 'committed' || job?.status === 'partially_committed';

  const run = async (f: () => Promise<void>) => {
    setBusy(true);
    setError(null);
    try {
      await f();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const template = () => run(async () => saveFile(`bhojmitra-${kind}-import-template.xlsx`, await api.importTemplate(kind), 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'));
  const upload = async () => {
    const f = await xlsxPicker.pick();
    if (!f) return;
    await run(async () => {
      setJob(await api.validateImport(kind, f.name, await fileToBase64(f), mode));
      setPartial(false);
    });
  };
  const commit = () => run(async () => setJob(await api.commitImport(job!.id, errors > 0 && partial)));
  const report = () => run(async () => saveFile(`import-${kind}-errors.csv`, await api.importErrorReport(job!.id), 'text/csv'));

  const summary = () => {
    const c = job!.counts as Json;
    const parts = menu
      ? [`${c.itemsCreate} new items`, `${c.itemsUpdate} items updated`, `${c.variantsCreate} new sizes`, `${c.variantsUpdate} sizes updated`, `${c.categoriesCreate} new categories`, `${c.recipes} recipes`]
      : [`${c.productsCreate} new products`, `${c.productsUpdate} updated`, `${c.openingMovements} opening stock entries (${rupees(c.openingValuePaise)})`, `${c.suppliersCreate} new suppliers`, `${c.locationsCreate} new locations`];
    return (
      <div>
        <div className="t-label">
          {`${job!.fileName}`} · {job!.mode === 'create' ? 'Create only' : 'Update existing'}
        </div>
        <div className="muted mt-4" data-testid="import-summary">
          {parts.join(' · ')}
        </div>
      </div>
    );
  };

  const preview = () => {
    const pv = job!.preview as Json;
    const price = (p: unknown) => (p == null ? '' : rupees(Number(p)));
    const rows: JSX.Element[] = [];
    if (menu) {
      for (const it of ((pv.items ?? []) as Json[]).slice(0, 50)) {
        const d = it.data as Json;
        rows.push(<div key={`i${rows.length}`}>{`${it.op === 'create' ? 'New' : 'Update'} item ${it.code}${d.name != null ? ` · ${d.name}` : ''}${d.category != null ? ` · ${d.category}` : ''}`}</div>);
      }
      for (const v of ((pv.variants ?? []) as Json[]).slice(0, 80)) {
        const d = v.data as Json, b = v.before as Json | null;
        const change = b != null && d.pricePaise != null ? `${price(b.pricePaise)} → ${price(d.pricePaise)}` : price(d.pricePaise);
        rows.push(<div key={`v${rows.length}`} className="muted" style={{ paddingLeft: 12 }}>{`${v.op === 'create' ? 'New' : 'Update'} size ${v.code}${d.name != null ? ` · ${d.name}` : ''} ${change}`}</div>);
      }
    } else {
      for (const x of ((pv.products ?? []) as Json[]).slice(0, 50)) rows.push(<div key={`p${rows.length}`}>{`${x.op === 'create' ? 'New' : 'Update'} product ${x.sku}${x.data?.name != null ? ` · ${x.data.name}` : ''}`}</div>);
      for (const o of ((pv.opening ?? []) as Json[]).slice(0, 80))
        rows.push(<div key={`o${rows.length}`} className="muted" style={{ paddingLeft: 12 }}>{`Opening stock ${o.sku}: +${o.baseQty} ${o.baseUnit} (${rupees(o.valuePaise)})${o.location != null ? ` in ${o.location}` : ''}`}</div>);
    }
    return (
      <div>
        <div className="t-overline">Preview</div>
        <div data-testid="import-preview" className="mt-4" style={{ maxHeight: 220, overflowY: 'auto' }}>
          {rows.length === 0 ? <span className="muted">Nothing to import.</span> : rows}
        </div>
      </div>
    );
  };

  const results = () => {
    const r = (job!.result ?? {}) as Json;
    const skipped = (r.skipped ?? []) as Json[];
    return (
      <div className="mt-12">
        <div className="t-card success-text" data-testid="import-done">
          {job!.status === 'committed' ? 'Imported' : 'Imported the valid rows'}
        </div>
        <div className="mt-4">
          {Object.entries(r)
            .filter(([k, v]) => k !== 'skipped' && typeof v === 'number' && v !== 0)
            .map(([k, v]) => `${k.replace(/[A-Z]/g, (m) => ` ${m.toLowerCase()}`)}: ${v}`)
            .join(' · ')}
        </div>
        {skipped.length > 0 && (
          <div className="danger-text mt-8" data-testid="import-skipped">
            Skipped {skipped.length} rows: {skipped.slice(0, 20).map((s) => `${s.sheet} row ${s.row} (${s.code})`).join(', ')}
          </div>
        )}
      </div>
    );
  };

  return (
    <Dialog
      title={menu ? 'Import menu from Excel' : 'Import inventory from Excel'}
      size="wide"
      actions={
        <>
          <SecondaryButton label={done ? 'Close' : 'Cancel'} onClick={busy ? null : () => close(done)} />
          {job != null && !done && <PrimaryButton label={errors > 0 ? 'Import valid rows only' : 'Confirm import'} busy={busy} height={56} testId="confirm-import" onClick={errors === 0 || partial ? commit : null} />}
        </>
      }
    >
      <div className="col gap-12">
        {job == null ? (
          <>
            <span>1. Download the template — it explains every column and has example rows.</span>
            <div>
              <SecondaryButton label="Download template" icon={Download} testId="download-template" onClick={busy ? null : template} />
            </div>
            <span className="mt-8">2. Choose what the file should do:</span>
            <div>
              <Radio name="import-mode" testId="mode-create" value="create" current={mode} onChange={setMode} label="Create only" sub={menu ? 'Adds new items and sizes. Codes that already exist are errors.' : 'Adds new products and opening stock. SKUs that already exist are errors.'} />
              <Radio name="import-mode" testId="mode-update" value="update" current={mode} onChange={setMode} label="Update existing" sub="Changes rows whose code already exists. Blank cells keep the current value. Unknown codes are errors." />
            </div>
            <span>3. Upload the filled .xlsx. We check every row and show exactly what will change — nothing is saved yet.</span>
            <div>
              <PrimaryButton label="Upload and check" icon={FileUp} busy={busy} height={48} testId="upload-xlsx" onClick={upload} />
            </div>
          </>
        ) : (
          <>
            {summary()}
            {issues.length > 0 && (
              <div>
                <div className="row">
                  <span className={`t-card grow${errors > 0 ? ' danger-text' : ''}`}>{errors > 0 ? `${errors} error${errors === 1 ? '' : 's'} to fix` : 'Warnings'}</span>
                  <TextButton label="Error report" icon={Download} testId="error-report" onClick={busy ? null : report} />
                </div>
                <div style={{ maxHeight: 220, overflowY: 'auto' }}>
                  {issues.slice(0, 200).map((i, n) => (
                    <div key={n} className="row-top" style={{ padding: '6px 0' }}>
                      {i.severity === 'error' ? <AlertCircle size={18} color="var(--danger)" aria-hidden /> : <Info size={18} className="muted" aria-hidden />}
                      <span className="col" style={{ gap: 0 }}>
                        <span>{`${i.message}`}</span>
                        <span className="muted" style={{ fontSize: 12 }}>
                          {[`${i.sheet ?? ''}` !== '' ? `Sheet ${i.sheet}` : null, i.row !== 0 && i.row != null ? `row ${i.row}` : null, `${i.column ?? ''}` !== '' ? `column ${i.column}` : null].filter(Boolean).join(' · ')}
                        </span>
                      </span>
                    </div>
                  ))}
                </div>
              </div>
            )}
            {!done ? (
              <>
                {preview()}
                {errors > 0 && (
                  <Check
                    testId="partial"
                    checked={partial}
                    onChange={setPartial}
                    label="Import only the rows without errors"
                    sub="Rows with errors, and anything that depends on them, are skipped and listed afterwards. Better: fix the file and upload again."
                  />
                )}
                <div>
                  <TextButton label="Upload a different file" onClick={busy ? null : () => setJob(null)} />
                </div>
              </>
            ) : (
              results()
            )}
          </>
        )}
        {error && (
          <span className="danger-text" data-testid="import-error">
            {error}
          </span>
        )}
      </div>
    </Dialog>
  );
}
