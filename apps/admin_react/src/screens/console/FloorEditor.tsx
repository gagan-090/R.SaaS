import { useCallback, useEffect, useLayoutEffect, useRef, useState, type CSSProperties, type PointerEvent as RPointerEvent } from 'react';
import {
  Check,
  Armchair, CalendarDays, CalendarX, ChevronDown, Circle, Copy, ImagePlus, Image as ImageIcon, Lock, Maximize, Minus, Pencil, Plus, RectangleHorizontal, RefreshCw, RotateCcw, RotateCw, Square, Trash2, Undo2, ZoomIn, ZoomOut,
} from 'lucide-react';
import { api, ApiException, errorText, type Json } from '../../api/client';
import { dateTime12 } from '../../lib/format';
import { pickFile } from '../../lib/download';
import { box, effectiveChairs, floorOverlaps, floorStateStyle, newKey, tableFromJson, tableToJson, type FloorTable } from '../../lib/floor';
import { prepareFloorPhoto } from '../../lib/image';
import { LoadError } from '../../ui/async';
import { Chip, IconButton, MenuButton, PrimaryButton, SecondaryButton, Segmented, Select, Skeleton, TextButton, TextField } from '../../ui/kit';
import { confirm, Dialog, openDialog, showDone, showError } from '../../ui/overlay';

const grid = 10;
type View = { k: number; tx: number; ty: number };

/**
 * Visual floor editor (plan feature "floor.editor"): drag tables and chairs, rotate, resize, change shape, add,
 * duplicate and delete; grid snapping, zoom and pan; save / cancel / reload. Without edit rights (or without the
 * feature) it is the live floor view: tables coloured by state, and staff who take orders can mark a table
 * reserved or out of use, or book a reservation.
 */
export function FloorEditor({ floorId, canEdit, canSetStatus, editorInPlan }: { floorId: string; canEdit: boolean; canSetStatus: boolean; editorInPlan: boolean }) {
  const [server, setServer] = useState<Json | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [tables, setTables] = useState<FloorTable[]>([]);
  const [w, setW] = useState(1200);
  const [h, setH] = useState(800);
  const [version, setVersion] = useState(1);
  const [background, setBackground] = useState<string | null>(null);
  const [sel, setSel] = useState<number | null>(null);
  const [dirty, setDirty] = useState(false);
  const [snap, setSnap] = useState(true);
  const [busy, setBusy] = useState(false);
  const [editing, setEditing] = useState(false);
  const [chairMode, setChairMode] = useState(false);
  const [search, setSearch] = useState('');
  const [view, setView] = useState<View>({ k: 1, tx: 0, ty: 0 });
  const [narrow, setNarrow] = useState(() => window.innerWidth < 900);
  const [availW, setAvailW] = useState(0);
  const fitted = useRef(false);
  const wrapRef = useRef<HTMLDivElement>(null);
  const editable = canEdit && editorInPlan && editing;

  const load = useCallback(async () => {
    try {
      const l = await api.floorLayout(floorId);
      const f = l.floor as Json;
      setServer(l);
      setW(Number(f.width));
      setH(Number(f.height));
      setVersion(f.version);
      setBackground(f.backgroundImage ?? null);
      setTables((l.tables as Json[]).map((t) => tableFromJson(t, `${t.live}` === 'available' ? 'free' : `${t.live}`)));
      setSel(null);
      setDirty(false);
      setError(null);
    } catch (e) {
      setError(e);
    }
  }, [floorId]);

  useEffect(() => {
    setEditing(false);
    fitted.current = false;
    setServer(null);
    void load();
  }, [load]);

  useEffect(() => {
    const on = () => setNarrow(window.innerWidth < 900);
    window.addEventListener('resize', on);
    return () => window.removeEventListener('resize', on);
  }, []);

  const targetH = availW > 0 ? Math.max(narrow ? 240 : 380, Math.min(narrow ? 480 : 620, availW * (h / w))) : 420;

  const fit = useCallback(() => {
    const vw = wrapRef.current?.clientWidth ?? 0;
    if (vw <= 0 || w <= 0 || h <= 0) return;
    const vh = Math.max(window.innerWidth < 900 ? 240 : 380, Math.min(window.innerWidth < 900 ? 480 : 620, vw * (h / w)));
    const k = Math.min(vw / w, vh / h);
    setView({ k, tx: Math.max(0, (vw - w * k) / 2), ty: Math.max(0, (vh - h * k) / 2) });
  }, [w, h]);

  // measure the canvas and fit the whole floor the first time it is laid out
  useLayoutEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    setAvailW(el.clientWidth);
    if (typeof ResizeObserver === 'undefined') return;
    const ro = new ResizeObserver(() => setAvailW(el.clientWidth));
    ro.observe(el);
    return () => ro.disconnect();
  }, [server]);
  useLayoutEffect(() => {
    if (!fitted.current && availW > 0 && server) {
      fit();
      fitted.current = true;
    }
  }, [availW, server, fit]);

  // mouse wheel zooms around the pointer (non-passive so the page does not scroll)
  useEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      const r = el.getBoundingClientRect();
      const px = e.clientX - r.left, py = e.clientY - r.top;
      setView((v) => {
        const k = Math.max(0.2, Math.min(3, v.k * Math.exp(-e.deltaY * 0.0015)));
        return { k, tx: px - ((px - v.tx) * k) / v.k, ty: py - ((py - v.ty) * k) / v.k };
      });
    };
    el.addEventListener('wheel', onWheel, { passive: false });
    return () => el.removeEventListener('wheel', onWheel);
  }, [server]);

  const change = (f: (ts: FloorTable[]) => FloorTable[]) => {
    setTables(f);
    setDirty(true);
  };
  const patch = (i: number, p: Partial<FloorTable>) => change((ts) => ts.map((t, j) => (j === i ? { ...t, ...p } : t)));
  const snapTo = (v: number) => (snap ? Math.round(v / grid) * grid : v);
  const nextName = () => `${tables.reduce((m, t) => Math.max(m, parseInt(t.name, 10) || 0), 0) + 1}`;

  /** First unoccupied spot for a new table, so tables do not stack or overlap. */
  const vacantSpot = (width: number, height: number) => {
    if (tables.length === 0) return { x: snapTo(120), y: snapTo(120) };
    const margin = 80, step = 60;
    for (let y = margin; y <= Math.max(margin, h - margin - height); y += step) {
      for (let x = margin; x <= Math.max(margin, w - margin - width); x += step) {
        const cx = x + width / 2, cy = y + height / 2;
        const a = { l: cx - (width + 50) / 2, r: cx + (width + 50) / 2, t: cy - (height + 50) / 2, b: cy + (height + 50) / 2 };
        const hit = tables.some((t) => {
          const b = { l: t.x - (t.width + 40) / 2, r: t.x + (t.width + 40) / 2, t: t.y - (t.height + 40) / 2, b: t.y + (t.height + 40) / 2 };
          return a.l < b.r && b.l < a.r && a.t < b.b && b.t < a.b;
        });
        if (!hit) return { x: snapTo(cx), y: snapTo(cy) };
      }
    }
    // fallback: staggered position when the canvas is full
    const off = (tables.length * 40) % 240;
    return { x: snapTo(Math.max(60, Math.min(w - 60, 100 + off))), y: snapTo(Math.max(60, Math.min(h - 60, 100 + off))) };
  };

  const add = (shape: string) => {
    const seats = shape === 'rect' ? 6 : shape === 'round' ? 2 : 4;
    const width = shape === 'rect' ? 140 : 80;
    const spot = vacantSpot(width, 80);
    change((ts) => [...ts, { key: newKey(), id: null, name: nextName(), seats, shape, x: spot.x, y: spot.y, width, height: 80, rotation: 0, chairs: null, status: 'free' }]);
    setSel(tables.length);
  };

  const duplicate = () => {
    if (sel == null) return;
    const s = tables[sel];
    change((ts) => [...ts, { ...s, key: newKey(), id: null, name: nextName(), x: Math.min(w - 40, s.x + 40), y: Math.min(h - 40, s.y + 40), chairs: s.chairs ? [...s.chairs] : null }]);
    setSel(tables.length);
  };

  const remove = () => {
    if (sel == null) return;
    const t = tables[sel];
    if (t.status === 'occupied' || t.status === 'bill_printed') return showError(`Table ${t.name} has an open order. Close it before removing the table.`);
    change((ts) => ts.filter((_, i) => i !== sel));
    setSel(null);
  };

  const overlaps = floorOverlaps(tables);
  const warnNames = new Set(overlaps.flat());
  const problem = (() => {
    const names = tables.map((t) => t.name.trim().toLowerCase());
    const dup = names.find((n) => names.filter((x) => x === n).length > 1);
    if (dup != null) return `Two tables are called "${dup}". Table names must be unique.`;
    if (names.some((n) => n === '')) return 'Every table needs a name or number.';
    return null;
  })();

  const save = async () => {
    if (problem) return showError(problem);
    setBusy(true);
    try {
      const r = await api.saveFloorLayout(floorId, { version, backgroundImage: background, width: Math.round(w), height: Math.round(h), tables: tables.map(tableToJson) });
      const warn = (r.warnings as unknown[]).length;
      await load();
      setEditing(false);
      showDone(warn === 0 ? 'Floor plan saved' : `Saved — ${warn} pair${warn === 1 ? '' : 's'} of tables overlap`);
    } catch (e) {
      if (e instanceof ApiException) showError(e);
      else showError(e);
    } finally {
      setBusy(false);
    }
  };

  const cancel = async () => {
    if (dirty && !(await confirm({ title: 'Discard changes?', message: 'The floor goes back to the last saved plan.', confirmLabel: 'Discard' }))) return;
    setEditing(false);
    await load();
  };

  const reserve = async (t: FloorTable) => {
    await openDialog<void>((close) => <ReserveDialog table={t} close={close} onDone={load} />);
  };

  const setStatus = async (t: FloorTable) => {
    const s = await openDialog<string>((close) => (
      <Dialog title={`Table ${t.name}`} actions={<SecondaryButton label="Close" onClick={() => close()} />}>
        <div className="col gap-8">
          <span className="muted">
            {t.seats} seats · {floorStateStyle(t.status).label}
          </span>
          {canSetStatus && (
            <div>
              <TextButton label="Book a reservation" icon={CalendarDays} onClick={() => close('booking')} />
            </div>
          )}
          {canSetStatus && t.status !== 'occupied' && t.status !== 'bill_printed' && (
            <div className="mt-8">
              {(
                [
                  ['available', 'Available'],
                  ['reserved', 'Reserved'],
                  ['unavailable', 'Out of use'],
                ] as [string, string][]
              ).map(([v, l]) => (
                <button key={v} type="button" className="list-row click" data-testid={`status-${v}`} style={{ width: '100%', border: 0, background: 'transparent', color: 'inherit', textAlign: 'left' }} onClick={() => close(v)}>
                  <Circle size={16} aria-hidden />
                  {l}
                </button>
              ))}
            </div>
          )}
        </div>
      </Dialog>
    ));
    if (s == null) return;
    if (s === 'booking') return reserve(t);
    try {
      await api.setTableStatus(t.id!, s);
      await load();
    } catch (e) {
      showError(e);
    }
  };

  const uploadBackground = async () => {
    try {
      const f = await pickFile('image/*');
      if (!f) return;
      const p = await prepareFloorPhoto(f);
      setBackground(p.dataUrl);
      setDirty(true);
    } catch (e) {
      showError(e);
    }
  };

  const zoom = (by: number) => setView((v) => ({ ...v, k: Math.max(0.2, Math.min(3, v.k * by)) }));

  // ---------------------------------------------------------------- pointer handling
  const gesture = useRef<{ kind: 'pan' | 'table' | 'chair'; id: number; sx: number; sy: number; v: View; i?: number; ci?: number; lx?: number; ly?: number; moved?: boolean } | null>(null);

  const onBgDown = (e: RPointerEvent) => {
    if (e.button !== 0) return;
    (e.currentTarget as Element).setPointerCapture(e.pointerId);
    gesture.current = { kind: 'pan', id: e.pointerId, sx: e.clientX, sy: e.clientY, v: view };
  };
  const onMove = (e: RPointerEvent) => {
    const g = gesture.current;
    if (!g || g.id !== e.pointerId) return;
    if (Math.abs(e.clientX - g.sx) + Math.abs(e.clientY - g.sy) > 3) g.moved = true;
    if (g.kind === 'pan') {
      setView({ ...g.v, tx: g.v.tx + e.clientX - g.sx, ty: g.v.ty + e.clientY - g.sy });
    } else if (g.kind === 'table' && g.i != null) {
      const dx = (e.clientX - g.lx!) / view.k, dy = (e.clientY - g.ly!) / view.k;
      g.lx = e.clientX;
      g.ly = e.clientY;
      const i = g.i;
      change((ts) => ts.map((t, j) => (j === i ? { ...t, x: Math.max(0, Math.min(w, t.x + dx)), y: Math.max(0, Math.min(h, t.y + dy)) } : t)));
    } else if (g.kind === 'chair' && g.i != null && g.ci != null) {
      const t = tables[g.i];
      const a = (-t.rotation * Math.PI) / 180;
      const sx = (e.clientX - g.lx!) / view.k, sy = (e.clientY - g.ly!) / view.k;
      g.lx = e.clientX;
      g.ly = e.clientY;
      // the drag arrives in screen space: turn it into the table's own (unrotated) frame
      const dx = sx * Math.cos(a) - sy * Math.sin(a), dy = sx * Math.sin(a) + sy * Math.cos(a);
      const i = g.i, ci = g.ci;
      change((ts) => ts.map((x, j) => (j === i ? { ...x, chairs: effectiveChairs(x).map((c, k) => (k === ci ? { ...c, x: c.x + dx, y: c.y + dy } : c)) } : x)));
    }
  };
  const onUp = (e: RPointerEvent) => {
    const g = gesture.current;
    if (!g || g.id !== e.pointerId) return;
    gesture.current = null;
    if (g.kind === 'pan' && !g.moved) setSel(null);
    if (g.kind === 'table' && g.i != null) {
      const i = g.i;
      if (g.moved) change((ts) => ts.map((t, j) => (j === i ? { ...t, x: snapTo(t.x), y: snapTo(t.y) } : t)));
    }
  };

  const onTableDown = (e: RPointerEvent, i: number) => {
    e.stopPropagation();
    if (!editable) return;
    (e.currentTarget as Element).setPointerCapture(e.pointerId);
    setSel(i);
    gesture.current = { kind: 'table', id: e.pointerId, sx: e.clientX, sy: e.clientY, v: view, i, lx: e.clientX, ly: e.clientY };
  };
  const onChairDown = (e: RPointerEvent, i: number, ci: number) => {
    if (!(editable && chairMode && sel === i)) return;
    e.stopPropagation();
    (e.currentTarget as Element).setPointerCapture(e.pointerId);
    gesture.current = { kind: 'chair', id: e.pointerId, sx: e.clientX, sy: e.clientY, v: view, i, ci, lx: e.clientX, ly: e.clientY };
  };

  const findTable = (v: string) => {
    setSearch(v);
    const i = tables.findIndex((t) => t.name.toLowerCase() === v.toLowerCase());
    if (i >= 0) {
      setSel(i);
      const t = tables[i];
      setView({ k: 1, tx: 200 - t.x, ty: 200 - t.y });
    }
  };

  if (error != null) return <LoadError error={error} page="Floor plan" onRetry={load} />;
  if (server == null) return <Skeleton h={420} r={20} />;

  const canvas = (
    <div
      ref={wrapRef}
      className="floor-canvas-wrap"
      data-testid="floor-canvas"
      style={{ height: targetH }}
      onPointerDown={onBgDown}
      onPointerMove={onMove}
      onPointerUp={onUp}
      onPointerCancel={onUp}
    >
      <div className="floor-world" style={{ width: w, height: h, transform: `translate(${view.tx}px, ${view.ty}px) scale(${view.k})` }}>
        <div className="floor-bg">
          <div className="img" style={{ backgroundImage: `url(${background ?? '/classic-floor.jpg'})` }} />
          <div className="floor-grid" />
        </div>
        {tables.map((t, i) => {
          const b = box(t);
          const st = floorStateStyle(t.status);
          const chairs = effectiveChairs(t);
          const selected = sel === i || (search !== '' && t.name.toLowerCase().includes(search.toLowerCase()));
          const warn = warnNames.has(t.name);
          const hl = editable && chairMode && sel === i;
          return (
            <div
              key={t.key}
              data-testid={`table-${t.name}`}
              className={`ftable fs-${st.cls}${editable ? ' drag' : ''}`}
              style={{ left: t.x - b / 2, top: t.y - b / 2, width: b, height: b, cursor: editable ? 'move' : 'pointer' }}
              onPointerDown={(e) => onTableDown(e, i)}
              onClick={(e) => {
                e.stopPropagation();
                if (!editable) void setStatus(t);
              }}
            >
              <div className="ftable-rot" style={{ transform: `rotate(${t.rotation}deg)` }}>
                {chairs.map((c, ci) => (
                  <div key={ci} data-testid={`chair-${t.name}-${ci}`} className={`fchair${hl ? ' hl' : ''}`} style={{ left: b / 2 + c.x - 11, top: b / 2 + c.y - 11 }} onPointerDown={(e) => onChairDown(e, i, ci)}>
                    <Armchair size={16} aria-hidden />
                  </div>
                ))}
                <div
                  className={`fbody${t.shape === 'round' ? ' round' : ''}${warn ? ' warn' : selected ? ' sel' : ''}`}
                  style={{ left: (b - t.width) / 2, top: (b - t.height) / 2, width: t.width, height: t.height }}
                >
                  {/* the label stays upright whatever the table's rotation */}
                  <div className="flabel" style={{ transform: `rotate(${-t.rotation}deg)` }}>
                    <span className="n">{t.name}</span>
                    <span className="s">{t.seats} seats</span>
                  </div>
                </div>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );

  const reservations = (server.reservations ?? []) as Json[];
  const liveInfo = (
    <div className="col gap-8">
      <div className="t-overline">Live floor</div>
      <FloorLegend />
      <div className="t-overline mt-8">Upcoming reservations</div>
      {reservations.map((r) => (
        <div key={r.id} className="row" style={{ padding: '4px 0' }}>
          <span className="col grow" style={{ gap: 0 }}>
            <span>
              {`${r.guestName}`} · {r.guests} guests
            </span>
            <span className="muted" style={{ fontSize: 13 }}>
              Table {tables.find((t) => t.id === r.tableId)?.name ?? ''} · {dateTime12(r.startsAt)}
            </span>
          </span>
          {canSetStatus && (
            <IconButton
              title="Cancel reservation"
              icon={CalendarX}
              onClick={async () => {
                try {
                  await api.cancelReservation(`${r.id}`);
                  await load();
                } catch (e) {
                  showError(e);
                }
              }}
            />
          )}
        </div>
      ))}
      <p className="muted mt-8" style={{ margin: 0 }}>
        {canSetStatus ? 'Tap a table to mark it reserved or out of use.' : 'Tables show their state from the POS (synced every few seconds).'}
      </p>
    </div>
  );

  const t = sel == null ? null : tables[sel];
  const props =
    t == null ? (
      <div className="col gap-8">
        <div className="t-overline">Floor</div>
        <span className="muted">Drag tables to place them. Tap one to edit it. Use the mouse wheel or the buttons to zoom; drag the background to pan.</span>
        <div className="t-overline mt-8">Floor size (cm)</div>
        <div className="row">
          <NumField k={`floor-w-${server.floor?.id}`} label="Width" value={w} min={300} max={10000} on={(v) => (setW(v), setDirty(true))} />
          <NumField k={`floor-h-${server.floor?.id}`} label="Depth" value={h} min={300} max={10000} on={(v) => (setH(v), setDirty(true))} />
        </div>
        {overlaps.length > 0 && (
          <>
            <div className="t-overline mt-8">Warnings</div>
            {overlaps.map(([a, b]) => (
              <span key={`${a}-${b}`} className="danger-text" data-testid={`overlap-${a}-${b}`}>
                Tables {a} and {b} overlap
              </span>
            ))}
          </>
        )}
        {problem && <span className="danger-text">{problem}</span>}
      </div>
    ) : (
      <div className="col gap-8">
        <div className="row">
          <span className="t-overline grow">Table</span>
          <IconButton title="Duplicate" icon={Copy} testId="duplicate-table" onClick={duplicate} />
          <IconButton title="Remove" icon={Trash2} testId="delete-table" onClick={remove} style={{ color: 'var(--danger)' }} />
        </div>
        <TextField key={`name-${t.key}`} label="Name or number" value={t.name} onChange={(v) => patch(sel!, { name: v.trim() })} testId="table-name-field" />
        <div className="t-overline mt-8">Shape</div>
        <Segmented<string>
          testId="shape"
          value={t.shape}
          options={[
            ['round', 'Round'],
            ['square', 'Square'],
            ['rect', 'Long'],
          ]}
          onChange={(s) => patch(sel!, { shape: s, height: s !== 'rect' ? t.width : t.height, chairs: null })}
        />
        <div className="t-overline mt-8">Seats</div>
        <div className="row">
          <IconButton title="Fewer seats" icon={Minus} testId="seats-minus" onClick={t.seats > 1 ? () => patch(sel!, { seats: t.seats - 1, chairs: null }) : null} />
          <span className="t-card" data-testid="seats">
            {t.seats}
          </span>
          <IconButton title="More seats" icon={Plus} testId="seats-plus" onClick={t.seats < 40 ? () => patch(sel!, { seats: t.seats + 1, chairs: null }) : null} />
        </div>
        <div className="t-overline mt-8">Size (cm)</div>
        <div className="row">
          <NumField k={`tw-${t.key}-${t.shape}`} label={t.shape === 'round' ? 'Diameter' : 'Width'} value={t.width} min={30} max={800} on={(v) => patch(sel!, t.shape !== 'rect' ? { width: v, height: v } : { width: v })} />
          {t.shape === 'rect' && <NumField k={`th-${t.key}`} label="Depth" value={t.height} min={30} max={800} on={(v) => patch(sel!, { height: v })} />}
        </div>
        <div className="t-overline mt-8">Rotation {t.rotation}°</div>
        <div className="row">
          <IconButton title="Rotate 15° left" icon={RotateCcw} testId="rotate-left" onClick={() => patch(sel!, { rotation: (((t.rotation - 15) % 360) + 360) % 360 })} />
          <input type="range" min={0} max={345} step={15} value={t.rotation} onChange={(e) => patch(sel!, { rotation: Number(e.target.value) })} aria-label="Rotation" />
          <IconButton title="Rotate 15° right" icon={RotateCw} testId="rotate-right" onClick={() => patch(sel!, { rotation: (t.rotation + 15) % 360 })} />
        </div>
        <div className="t-overline mt-8">Chairs</div>
        <div className="wrap">
          <TextButton label="Arrange from seats" testId="arrange-chairs" onClick={() => patch(sel!, { chairs: null })} />
          <TextButton label="Add chair" testId="add-chair" onClick={() => patch(sel!, { chairs: [...effectiveChairs(t), { x: 0, y: t.height / 2 + 30, rotation: 0 }] })} />
          <TextButton label="Remove chair" onClick={effectiveChairs(t).length === 0 ? null : () => patch(sel!, { chairs: effectiveChairs(t).slice(0, -1) })} />
        </div>
        <span className="muted" style={{ fontSize: 12 }}>
          {effectiveChairs(t).length} chairs. Turn on "Move chairs" to drag them one by one.
        </span>
      </div>
    );

  const panel = editable ? props : liveInfo;

  return (
    <div className="col gap-8">
      {canEdit && !editorInPlan && (
        <div className="callout warn" data-testid="editor-locked" style={{ marginBottom: 4 }}>
          <Lock size={20} className="accent-text" aria-hidden />
          <div>
            <div className="t-label">Moving tables is locked: the visual floor editor is not in your plan</div>
            <div className="muted">Ask House Plating to switch on "Visual floor editor" for your plan. Until then you can add tables in the List and see the live floor here.</div>
          </div>
        </div>
      )}
      <div className="between" style={{ gap: 8 }}>
        <div className="wrap">
          <div style={{ width: 220 }}>
            <TextField dense value={search} onChange={findTable} placeholder="Find table..." />
          </div>
          {editable && (
            <>
              <MenuButton
                title="Add table"
                testId="add-plan-table"
                items={[
                  { label: 'Square table (4 seats)', icon: Square, onClick: () => add('square') },
                  { label: 'Round table (2 seats)', icon: Circle, onClick: () => add('round') },
                  { label: 'Long table (6 seats)', icon: RectangleHorizontal, onClick: () => add('rect') },
                ]}
                trigger={(open) => (
                  <button type="button" className="add-table-btn" data-testid="add-plan-table" onClick={open}>
                    <Plus size={18} aria-hidden />
                    Add table
                    <ChevronDown size={18} aria-hidden />
                  </button>
                )}
              />
              <MenuButton
                title="Floor background image"
                items={[
                  { label: 'Upload image', icon: ImagePlus, onClick: uploadBackground },
                  background != null && { label: 'Reset to classic floor', icon: Undo2, onClick: () => (setBackground(null), setDirty(true)) },
                ]}
                trigger={(open) => (
                  <button type="button" className="tool-btn" onClick={open}>
                    <ImageIcon size={18} aria-hidden />
                    Floor image
                    <ChevronDown size={18} aria-hidden />
                  </button>
                )}
              />
              <Chip testId="snap" label="Snap to grid" icon={snap ? Check : undefined} on={snap} onClick={() => setSnap(!snap)} />
              <Chip testId="chair-mode" label="Move chairs" icon={chairMode ? Check : undefined} on={chairMode} onClick={() => setChairMode(!chairMode)} />
            </>
          )}
        </div>
        <div className="wrap">
          <span className="tool-box">
            <IconButton title="Zoom in" icon={ZoomIn} sm onClick={() => zoom(1.25)} />
            <IconButton title="Zoom out" icon={ZoomOut} sm onClick={() => zoom(0.8)} />
            <IconButton title="Reset view" icon={Maximize} sm onClick={fit} />
            <IconButton title="Reload" icon={RefreshCw} sm testId="reload-plan" onClick={dirty ? cancel : load} />
          </span>
          {canEdit && editorInPlan && !editing && <PrimaryButton label="Edit floor plan" icon={Pencil} height={42} testId="edit-plan" onClick={() => setEditing(true)} />}
          {editable && (
            <>
              <SecondaryButton label="Cancel" height={42} testId="cancel-plan" onClick={busy ? null : cancel} />
              <PrimaryButton label="Save plan" busy={busy} height={42} testId="save-plan" onClick={dirty ? save : null} />
            </>
          )}
        </div>
      </div>
      {editable && <span className="muted">Drag a table to move it with all its chairs. Turn on Move chairs to adjust individual chairs on the selected table. Choose Save plan to keep your changes.</span>}
      {narrow ? (
        <>
          {canvas}
          <div className="mt-8">{panel}</div>
        </>
      ) : (
        <div className="row-top gap-16">
          <div className="grow">{canvas}</div>
          <div style={{ width: 300, flex: 'none' }}>{panel}</div>
        </div>
      )}
    </div>
  );
}

/** Legend: colour + word for each state shown on the plan. */
export function FloorLegend() {
  return (
    <div className="wrap" style={{ gap: '4px 12px' }}>
      {['free', 'occupied', 'bill_printed', 'reserved', 'unavailable'].map((s) => {
        const st = floorStateStyle(s);
        return (
          <span key={s} className={`row fs-${st.cls}`} style={{ gap: 4 }}>
            <span className="legend-sw" />
            <span className="muted" style={{ fontSize: 12 }}>
              {st.label}
            </span>
          </span>
        );
      })}
    </div>
  );
}

/** A size box that only applies values within range (like the Flutter editor's _num). */
function NumField({ k, label, value, min, max, on }: { k: string; label: string; value: number; min: number; max: number; on: (v: number) => void }) {
  const [text, setText] = useState(`${Math.round(value)}`);
  useEffect(() => setText(`${Math.round(value)}`), [k]); // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <TextField
      key={k}
      label={label}
      inputMode="numeric"
      value={text}
      testId={k.split('-').slice(0, 2).join('-')}
      onChange={(s) => {
        const d = s.replace(/\D/g, '');
        setText(d);
        const v = Number(d);
        if (d !== '' && v >= min && v <= max) on(v);
      }}
      style={{ flex: 1 } as CSSProperties}
    />
  );
}

function ReserveDialog({ table, close, onDone }: { table: FloorTable; close: () => void; onDone: () => Promise<void> }) {
  const pad = (n: number) => `${n}`.padStart(2, '0');
  const local = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
  const [name, setName] = useState('');
  const [phone, setPhone] = useState('');
  const [guests, setGuests] = useState(`${table.seats}`);
  const [start, setStart] = useState(local(new Date(Date.now() + 3600000)));
  const [duration, setDuration] = useState(90);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const submit = async () => {
    const count = parseInt(guests, 10);
    if (!name.trim() || !Number.isFinite(count) || count < 1 || count > table.seats) return setError(`Enter a guest name and 1–${table.seats} guests.`);
    const s = new Date(start);
    if (isNaN(s.getTime())) return setError('Choose the date and time');
    setBusy(true);
    setError(null);
    try {
      await api.reserveTable(table.id!, { guestName: name.trim(), phone: phone.trim(), guests: count, startsAt: s.toISOString(), endsAt: new Date(s.getTime() + duration * 60000).toISOString() });
      close();
      await onDone();
    } catch (e) {
      setBusy(false);
      setError(errorText(e));
    }
  };
  return (
    <Dialog
      title={`Reserve table ${table.name}`}
      actions={
        <>
          <SecondaryButton label="Close" onClick={close} />
          <PrimaryButton label="Reserve" busy={busy} onClick={busy ? null : submit} />
        </>
      }
    >
      <div className="col gap-12">
        <TextField label="Guest name" value={name} onChange={setName} autoFocus />
        <TextField label="Phone (optional)" type="tel" value={phone} onChange={setPhone} />
        <TextField label="Guests" inputMode="numeric" value={guests} onChange={(v) => setGuests(v.replace(/\D/g, ''))} />
        <TextField label="Date & time" type="datetime-local" value={start} onChange={setStart} />
        <Select<number> label="Duration" value={duration} options={[30, 60, 90, 120, 180].map((m) => [m, `${m} minutes`])} onChange={setDuration} />
        {error && <span className="danger-text">{error}</span>}
      </div>
    </Dialog>
  );
}
