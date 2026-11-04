import { useCallback, useEffect, useState, type CSSProperties } from 'react';
import { Armchair, Layers, LayoutGrid, Map as MapIcon, Pencil, Plus, Trash2 } from 'lucide-react';
import { api, type Json } from '../../api/client';
import { useSession } from '../../state/auth';
import { LoadError } from '../../ui/async';
import { CategoryChip, Chip, EmptyState, IconButton, PageFrame, PrimaryButton, SecondaryButton, Segmented, SkeletonGrid, DangerButton, TextField } from '../../ui/kit';
import { confirm, Dialog, openDialog, showDone, showError } from '../../ui/overlay';
import { FloorEditor } from './FloorEditor';

/** Asks for one line of text (floor name). */
function askText(title: string, label: string, initial = '') {
  return openDialog<string>((close) => <AskDialog title={title} label={label} initial={initial} close={close} />);
}
function AskDialog({ title, label, initial, close }: { title: string; label: string; initial: string; close: (v?: string) => void }) {
  const [v, setV] = useState(initial);
  return (
    <Dialog
      title={title}
      actions={
        <>
          <SecondaryButton label="Cancel" onClick={() => close()} />
          <PrimaryButton label="Save" height={56} onClick={() => close(v.trim())} testId="ask-save" />
        </>
      }
    >
      <TextField label={label} value={v} onChange={setV} autoFocus onEnter={() => close(v.trim())} testId="ask-field" />
    </Dialog>
  );
}

/** T2 Floors & tables: floors as tabs, the floor plan (visual editor) or a simple list of table tiles. */
export function TablesScreen() {
  const me = useSession();
  const edit = !!me?.can('floor.manage');
  const [floors, setFloors] = useState<Json[] | null>(null);
  const [features, setFeatures] = useState<string[]>([]);
  const [plan, setPlan] = useState(true); // floor plan view (else the simple list)
  const [branchId, setBranchId] = useState<string | null>(null);
  const [floor, setFloor] = useState<string | null>(null);
  const [error, setError] = useState<unknown>(null);

  const load = useCallback(async () => {
    try {
      const [fs, o] = await Promise.all([api.floors(), api.overview()]);
      setFloors(fs);
      setBranchId((o.branches as Json[])[0]?.id ?? null);
      setFeatures((o.license?.features ?? []) as string[]);
      setFloor((cur) => (cur != null && fs.some((f) => f.id === cur) ? cur : fs[0]?.id ?? null));
      setError(null);
    } catch (e) {
      setError(e);
    }
  }, []);
  useEffect(() => void load(), [load]);

  const run = async (f: () => Promise<unknown>, done: string) => {
    try {
      await f();
      await load();
      showDone(done);
    } catch (e) {
      showError(e);
    }
  };

  const addFloor = async () => {
    const name = await askText('New floor', 'Name, e.g. Rooftop');
    if (!name || branchId == null) return;
    await run(async () => {
      const f = await api.createFloor(branchId, name, floors?.length ?? 0);
      setFloor(f.id);
    }, 'Floor added');
  };

  const nextNumber = () => {
    const nums = (floors ?? []).flatMap((f) => (f.tables as Json[]).map((t) => parseInt(`${t.name}`, 10) || 0));
    return nums.length === 0 ? 1 : Math.max(...nums) + 1;
  };

  const editTable = async (floorId: string, t?: Json) => {
    const r = await openDialog<{ name: string; seats: number } | 'delete'>((close) => <TableDialog table={t} initialName={t?.name ?? `${nextNumber()}`} close={close} />);
    if (r == null) return;
    if (r === 'delete') {
      if (await confirm({ title: `Delete table ${t!.name}?`, message: 'It disappears from the table map on every terminal.' })) await run(() => api.deleteTable(t!.id), 'Table deleted');
      return;
    }
    if (!r.name.trim()) return;
    await run(() => (t == null ? api.createTable(floorId, r.name.trim(), r.seats) : api.updateTable(t.id, { name: r.name.trim(), seats: r.seats })), t == null ? 'Table added' : 'Table saved');
  };

  if (error != null) return <LoadError error={error} page="Floors & tables" onRetry={load} />;
  if (floors == null) return <SkeletonGrid min={140} h={120} />;
  const f = floors.find((x) => x.id === floor);
  const tables = [...((f?.tables as Json[] | undefined) ?? [])].sort((a, b) => (parseInt(`${a.name}`, 10) || 999) - (parseInt(`${b.name}`, 10) || 999));
  const total = floors.reduce((s, x) => s + (x.tables as Json[]).length, 0);
  const seats = floors.reduce((s, x) => s + (x.tables as Json[]).reduce((y, t) => y + Number(t.seats), 0), 0);

  return (
    <PageFrame
      title="Floors & tables"
      subtitle={`${total} tables · ${seats} seats · the POS table map shows exactly this`}
      actions={edit && <SecondaryButton label="Add floor" icon={Layers} height={48} onClick={addFloor} testId="add-floor" />}
    >
      {floors.length === 0 ? (
        <EmptyState icon={Armchair} title="No floors yet" message={'Start with one floor (e.g. "Ground floor"), then add its tables.'} action={edit && <PrimaryButton label="Add a floor" icon={Plus} onClick={addFloor} />} />
      ) : (
        <div className="col gap-16">
          <div className="chip-scroll">
            {floors.map((x) => (
              <CategoryChip key={x.id} label={`${x.name}`} count={(x.tables as Json[]).length} on={x.id === floor} onClick={() => setFloor(x.id)} />
            ))}
          </div>
          {f && (
            <div className="card pad-16">
              <div className="between" style={{ gap: 8 }}>
                <span className="t-card">{`${f.name}`}</span>
                <div className="wrap">
                  <Segmented<boolean>
                    testId="floor-view"
                    value={plan}
                    options={[
                      [true, 'Floor plan', MapIcon],
                      [false, 'List', LayoutGrid],
                    ]}
                    onChange={setPlan}
                  />
                  {edit && (
                    <>
                      <IconButton
                        title="Rename floor"
                        icon={Pencil}
                        onClick={async () => {
                          const n = await askText('Rename floor', 'Name', `${f.name}`);
                          if (n) await run(() => api.updateFloor(f.id, { name: n }), 'Floor renamed');
                        }}
                      />
                      <IconButton
                        title="Delete floor"
                        icon={Trash2}
                        onClick={async () => {
                          if (await confirm({ title: `Delete ${f.name}?`, message: 'Only floors without tables can be deleted.' })) await run(() => api.deleteFloor(f.id), 'Floor deleted');
                        }}
                      />
                    </>
                  )}
                </div>
              </div>
              <div className="mt-16">
                {plan ? (
                  <FloorEditor key={`plan-${f.id}`} floorId={f.id} canEdit={edit} canSetStatus={!!me?.can('order.write')} editorInPlan={features.includes('floor.editor')} />
                ) : (
                  <div className="grid-auto" style={{ '--min': '120px', gap: 12 } as CSSProperties}>
                    {tables.map((t) =>
                      edit ? (
                        <button key={t.id} type="button" className="table-tile" data-testid={`console-table-${t.name}`} onClick={() => editTable(f.id, t)}>
                          <span className="n">{`${t.name}`}</span>
                          <span className="muted t-label" style={{ fontSize: 13 }}>
                            {t.seats} seats
                          </span>
                        </button>
                      ) : (
                        <div key={t.id} className="table-tile" data-testid={`console-table-${t.name}`}>
                          <span className="n">{`${t.name}`}</span>
                          <span className="muted t-label" style={{ fontSize: 13 }}>
                            {t.seats} seats
                          </span>
                        </div>
                      ),
                    )}
                    {edit && (
                      <button type="button" className="table-tile add-tile" data-testid="add-table" onClick={() => editTable(f.id)}>
                        <Plus size={22} aria-hidden />
                        Add table
                      </button>
                    )}
                  </div>
                )}
              </div>
            </div>
          )}
        </div>
      )}
    </PageFrame>
  );
}

function TableDialog({ table, initialName, close }: { table?: Json; initialName: string; close: (v?: { name: string; seats: number } | 'delete') => void }) {
  const [name, setName] = useState(initialName);
  const [seats, setSeats] = useState<number>(table?.seats ?? 4);
  return (
    <Dialog
      title={table == null ? 'Add a table' : `Table ${table.name}`}
      actions={
        <>
          {table != null && <DangerButton label="Delete" onClick={() => close('delete')} />}
          <SecondaryButton label="Cancel" onClick={() => close()} />
          <PrimaryButton label="Save" height={56} onClick={() => close({ name, seats })} testId="save-table" />
        </>
      }
    >
      <div className="col gap-16">
        <TextField label="Table number or name" value={name} onChange={setName} autoFocus testId="table-name" />
        <div>
          <div className="t-overline">Seats</div>
          <div className="wrap mt-8">
            {[2, 4, 6, 8, 10, 12].map((n) => (
              <Chip key={n} label={`${n}`} on={seats === n} onClick={() => setSeats(n)} />
            ))}
          </div>
        </div>
      </div>
    </Dialog>
  );
}
