import { useEffect, useId, useLayoutEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { AlertCircle, ChevronDown, Moon, RefreshCw, Search, Sun, UtensilsCrossed, X, type LucideIcon } from 'lucide-react';
import type { Tone } from '../lib/labels';
import { setThemeMode, useIsDark } from '../state/app';

// ---------------------------------------------------------------- buttons

type BtnProps = {
  label: string;
  onClick?: (() => void) | null;
  icon?: LucideIcon;
  busy?: boolean;
  height?: number;
  block?: boolean;
  testId?: string;
  type?: 'button' | 'submit';
  title?: string;
};

function Btn({ kind, label, onClick, icon: Icon, busy, height, block, testId, type = 'button', title }: BtnProps & { kind: string }) {
  const disabled = !onClick || busy;
  return (
    <button
      type={type}
      data-testid={testId}
      title={title}
      className={`btn ${kind}${block ? ' block' : ''}${busy ? ' busy' : ''}`}
      style={{ '--h': `${height ?? (kind === 'primary' ? 60 : 56)}px` } as CSSProperties}
      disabled={type === 'submit' ? !!busy : disabled}
      aria-busy={busy || undefined}
      onClick={type === 'submit' ? undefined : () => onClick?.()}
    >
      {busy ? <span className="spinner" aria-hidden /> : Icon ? <Icon size={20} aria-hidden /> : null}
      <span className="ellipsis">{label}</span>
    </button>
  );
}

/** One confident action per screen region: wine on light, saffron on dark, with a soft glow. */
export const PrimaryButton = (p: BtnProps) => <Btn kind="primary" {...p} />;
export const SecondaryButton = (p: BtnProps) => <Btn kind="secondary" {...p} />;
export const DangerButton = (p: BtnProps) => <Btn kind="danger" {...p} />;

export function TextButton({ label, onClick, icon: Icon, danger, small, testId, title }: { label: string; onClick?: (() => void) | null; icon?: LucideIcon; danger?: boolean; small?: boolean; testId?: string; title?: string }) {
  return (
    <button type="button" data-testid={testId} title={title} className={`text-btn${danger ? ' danger' : ''}${small ? ' small' : ''}`} disabled={!onClick} onClick={() => onClick?.()}>
      {Icon && <Icon size={small ? 16 : 18} aria-hidden />}
      {label}
    </button>
  );
}

export function IconButton({ title, onClick, icon: Icon, size = 20, sm, testId, style }: { title: string; onClick?: (() => void) | null; icon: LucideIcon; size?: number; sm?: boolean; testId?: string; style?: CSSProperties }) {
  return (
    <button type="button" className={`icon-btn${sm ? ' sm' : ''}`} title={title} aria-label={title} data-testid={testId} disabled={!onClick} onClick={() => onClick?.()} style={style}>
      <Icon size={size} aria-hidden />
    </button>
  );
}

// ---------------------------------------------------------------- chips

/** Tinted pill with a dot and words (hub online, sync counts, restaurant status…). Status is never colour alone. */
export function StatusChip({ label, tone = 'neutral', icon: Icon, testId }: { label: string; tone?: Tone; icon?: LucideIcon; testId?: string }) {
  return (
    <span className={`status tone-${tone}`} data-testid={testId}>
      {Icon ? <Icon size={14} aria-hidden /> : <span className="dot" aria-hidden />}
      <span>{label}</span>
    </span>
  );
}

export function Chip({ label, on, onClick, small, testId, icon: Icon, disabled }: { label: ReactNode; on?: boolean; onClick?: () => void; small?: boolean; testId?: string; icon?: LucideIcon; disabled?: boolean }) {
  return (
    <button type="button" data-testid={testId} aria-pressed={on} disabled={disabled} className={`chip${on ? ' on' : ''}${small ? ' sm' : ''}${onClick ? '' : ' static'}`} onClick={onClick}>
      {Icon && <Icon size={small ? 14 : 16} aria-hidden />}
      {label}
    </button>
  );
}

export function CategoryChip({ label, count, on, onClick, testId }: { label: string; count?: number; on: boolean; onClick: () => void; testId?: string }) {
  return (
    <button type="button" data-testid={testId} aria-pressed={on} className={`cat-chip${on ? ' on' : ''}`} onClick={onClick}>
      {label}
      {count != null && <span className="count">{count}</span>}
    </button>
  );
}

export function Segmented<T extends string | boolean>({ value, options, onChange, compact, testId, disabled, onSidebar, block }: {
  value: T;
  options: [T, string, LucideIcon?][];
  onChange: (v: T) => void;
  compact?: boolean;
  testId?: string;
  disabled?: boolean;
  onSidebar?: boolean;
  /** Full width, every segment the same size. */
  block?: boolean;
}) {
  return (
    <div className={`seg${compact ? ' compact' : ''}${onSidebar ? ' on-sidebar' : ''}${block ? ' block' : ''}`} role="group" data-testid={testId}>
      {options.map(([v, l, Icon]) => (
        <button key={String(v)} type="button" className={value === v ? 'on' : ''} aria-pressed={value === v} disabled={disabled} onClick={() => onChange(v)} title={l || undefined} aria-label={l || undefined}>
          {Icon && <Icon size={18} aria-hidden />}
          {l && !(compact && Icon) && <span>{l}</span>}
        </button>
      ))}
    </div>
  );
}

/** Light / dark (no Auto, like the Flutter console). */
export function ThemeSwitch({ compact, onSidebar }: { compact?: boolean; onSidebar?: boolean }) {
  const dark = useIsDark();
  return (
    <Segmented<string>
      testId="theme-mode"
      compact={compact}
      onSidebar={onSidebar}
      value={dark ? 'dark' : 'light'}
      options={[
        ['light', compact ? '' : 'Light', Sun],
        ['dark', compact ? '' : 'Dark', Moon],
      ]}
      onChange={(v) => setThemeMode(v as 'light' | 'dark')}
    />
  );
}

// ---------------------------------------------------------------- fields

type FieldProps = {
  label?: string;
  value: string;
  onChange?: (v: string) => void;
  type?: string;
  placeholder?: string;
  help?: ReactNode;
  error?: string | null;
  prefix?: ReactNode;
  suffix?: ReactNode;
  disabled?: boolean;
  readOnly?: boolean;
  autoFocus?: boolean;
  testId?: string;
  inputMode?: 'text' | 'numeric' | 'decimal' | 'email' | 'tel' | 'search';
  maxLength?: number;
  autoComplete?: string;
  onEnter?: () => void;
  dense?: boolean;
  multiline?: number;
  className?: string;
  style?: CSSProperties;
  upper?: boolean;
  name?: string;
};

export function TextField({ label, value, onChange, type = 'text', placeholder, help, error, prefix, suffix, disabled, readOnly, autoFocus, testId, inputMode, maxLength, autoComplete, onEnter, dense, multiline, className, style, upper, name }: FieldProps) {
  const id = useId();
  const common = {
    id,
    name,
    'data-testid': testId,
    value,
    placeholder,
    disabled,
    readOnly,
    autoFocus,
    maxLength,
    autoComplete,
    'aria-invalid': error ? true : undefined,
    onChange: (e: { target: { value: string } }) => onChange?.(upper ? e.target.value.toUpperCase() : e.target.value),
  };
  return (
    <div className={`field${prefix ? ' has-prefix' : ''}${suffix ? ' has-suffix' : ''}${className ? ` ${className}` : ''}`} style={style}>
      {label && <label htmlFor={id}>{label}</label>}
      <div className="control">
        {prefix && <span className="prefix">{prefix}</span>}
        {multiline ? (
          <textarea className="textarea" rows={multiline} {...common} />
        ) : (
          <input
            className={`input${dense ? ' dense' : ''}`}
            type={type}
            inputMode={inputMode}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && onEnter) {
                e.preventDefault();
                onEnter();
              }
            }}
            {...common}
          />
        )}
        {suffix && <span className="suffix">{suffix}</span>}
      </div>
      {error ? <span className="err">{error}</span> : help ? <span className="help">{help}</span> : null}
    </div>
  );
}

export function Select<T extends string | number | null>({ label, value, onChange, options, testId, disabled, help, dense, style }: {
  label?: string;
  value: T;
  onChange: (v: T) => void;
  options: [T, string][];
  testId?: string;
  disabled?: boolean;
  help?: ReactNode;
  dense?: boolean;
  style?: CSSProperties;
}) {
  const id = useId();
  const idx = options.findIndex(([v]) => v === value);
  return (
    <div className="field" style={style}>
      {label && <label htmlFor={id}>{label}</label>}
      <select
        id={id}
        data-testid={testId}
        className={`select${dense ? ' dense' : ''}`}
        disabled={disabled}
        value={idx < 0 ? '' : String(idx)}
        onChange={(e) => onChange(options[Number(e.target.value)][0])}
      >
        {idx < 0 && <option value="" disabled />}
        {options.map(([, l], i) => (
          <option key={i} value={String(i)}>
            {l}
          </option>
        ))}
      </select>
      {help && <span className="help">{help}</span>}
    </div>
  );
}

export function Switch({ checked, onChange, disabled, testId, label }: { checked: boolean; onChange?: (v: boolean) => void; disabled?: boolean; testId?: string; label?: string }) {
  return (
    <label className="switch" title={label}>
      <input type="checkbox" role="switch" aria-label={label} data-testid={testId} checked={checked} disabled={disabled || !onChange} onChange={(e) => onChange?.(e.target.checked)} />
      <span className="track" />
    </label>
  );
}

export function SwitchRow({ title, sub, checked, onChange, disabled, testId, leading }: { title: string; sub?: string; checked: boolean; onChange?: (v: boolean) => void; disabled?: boolean; testId?: string; leading?: ReactNode }) {
  const off = disabled || !onChange;
  return (
    <div className={`switch-row${off ? ' disabled' : ''}`} onClick={() => !off && onChange?.(!checked)}>
      {leading}
      <div className="grow">
        <div className="t-label">{title}</div>
        {sub && <div className="muted t-body">{sub}</div>}
      </div>
      <span onClick={(e) => e.stopPropagation()}>
        <Switch checked={checked} onChange={onChange} disabled={disabled} testId={testId} label={title} />
      </span>
    </div>
  );
}

export function Check({ label, sub, checked, onChange, disabled, testId }: { label: ReactNode; sub?: ReactNode; checked: boolean; onChange?: (v: boolean) => void; disabled?: boolean; testId?: string }) {
  return (
    <label className={`check${disabled || !onChange ? ' disabled' : ''}`}>
      <input type="checkbox" data-testid={testId} checked={checked} disabled={disabled || !onChange} onChange={(e) => onChange?.(e.target.checked)} />
      <span className="col gap-4">
        <span>{label}</span>
        {sub && <span className="muted t-small">{sub}</span>}
      </span>
    </label>
  );
}

export function Radio<T extends string | boolean>({ name, value, current, onChange, label, sub, icon: Icon, testId }: { name: string; value: T; current: T; onChange: (v: T) => void; label: ReactNode; sub?: ReactNode; icon?: LucideIcon; testId?: string }) {
  return (
    <label className="radio-tile">
      <input type="radio" name={name} data-testid={testId} checked={current === value} onChange={() => onChange(value)} />
      <span className="grow col gap-4">
        <span className="t-label">{label}</span>
        {sub && <span className="muted t-small">{sub}</span>}
      </span>
      {Icon && <Icon size={20} className="muted" aria-hidden />}
    </label>
  );
}

/** Rounded search field with a clear button. */
export function SearchField({ hint = 'Search', onChange, testId, initial = '' }: { hint?: string; onChange: (v: string) => void; testId?: string; initial?: string }) {
  const [v, setV] = useState(initial);
  return (
    <div className="search">
      <span className="s-icon"><Search size={20} aria-hidden /></span>
      <input
        className="input"
        type="search"
        data-testid={testId}
        placeholder={hint}
        aria-label={hint}
        value={v}
        onChange={(e) => {
          setV(e.target.value);
          onChange(e.target.value);
        }}
      />
      {v && (
        <span className="s-clear">
          <IconButton title="Clear search" icon={X} sm onClick={() => (setV(''), onChange(''))} />
        </span>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- layout

/** Page frame used by every console screen: title, subtitle, actions, responsive padding. */
export function PageFrame({ title, subtitle, actions, children, full }: { title: string; subtitle?: ReactNode; actions?: ReactNode; children: ReactNode; full?: boolean }) {
  return (
    <div className={`page page-enter${full ? ' full' : ''}`}>
      <div className="page-head">
        <div style={{ minWidth: 0 }}>
          <h1 className="t-page">{title}</h1>
          {subtitle && <div className="page-sub">{subtitle}</div>}
        </div>
        {actions && <div className="page-actions">{actions}</div>}
      </div>
      {children}
    </div>
  );
}

export function SectionCard({ title, actions, children, testId, style, className }: { title: string; actions?: ReactNode; children: ReactNode; testId?: string; style?: CSSProperties; className?: string }) {
  return (
    <section className={`card pad${className ? ` ${className}` : ''}`} data-testid={testId} style={style}>
      <div className="section-head">
        <span className="t-overline">{title}</span>
        {actions}
      </div>
      {children}
    </section>
  );
}

export function SectionHeader({ title, trailing }: { title: string; trailing?: ReactNode }) {
  return (
    <div className="row" style={{ marginBottom: 8 }}>
      <span className="t-overline grow">{title}</span>
      {trailing}
    </div>
  );
}

export function Overline({ children, style }: { children: ReactNode; style?: CSSProperties }) {
  return (
    <div className="t-overline" style={style}>
      {children}
    </div>
  );
}

/** Collapsible row (Flutter ExpansionTile). */
export function Expandable({ head, children, pad, flush, testId, defaultOpen = false }: { head: ReactNode; children: ReactNode; pad?: boolean; flush?: boolean; testId?: string; defaultOpen?: boolean }) {
  const [open, setOpen] = useState(defaultOpen);
  return (
    <div data-testid={testId}>
      <button type="button" className={`exp-head${pad ? ' pad' : ''}`} aria-expanded={open} onClick={() => setOpen(!open)}>
        <div className="grow row">{head}</div>
        <ChevronDown className="chev" size={20} aria-hidden />
      </button>
      {open && <div className={`exp-body${pad ? ' pad' : ''}${flush ? ' flush' : ''}`}>{children}</div>}
    </div>
  );
}

// ---------------------------------------------------------------- states

/** Page-shaped skeleton while data loads (no blocking spinner). */
export function LoadingState({ label = 'Loading…' }: { label?: string }) {
  return (
    <div className="page skel-page" role="status" aria-label={label}>
      <Skeleton h={36} w="38%" />
      <Skeleton h={16} w="55%" />
      <div className="kpis" style={{ marginTop: 8 }}>
        {[0, 1, 2, 3].map((i) => (
          <Skeleton key={i} h={104} r={20} />
        ))}
      </div>
      <Skeleton h={220} r={20} />
    </div>
  );
}

export function EmptyState({ title, message, icon: Icon = UtensilsCrossed, action, testId }: { title: string; message?: string; icon?: LucideIcon; action?: ReactNode; testId?: string }) {
  return (
    <div className="state" data-testid={testId}>
      <div className="state-icon">
        <Icon size={34} aria-hidden />
      </div>
      <h3>{title}</h3>
      {message && <p>{message}</p>}
      {action && <div style={{ marginTop: 4 }}>{action}</div>}
    </div>
  );
}

export function ErrorState({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return <EmptyState icon={AlertCircle} title="Something went wrong" message={message} action={onRetry && <SecondaryButton label="Try again" icon={RefreshCw} onClick={onRetry} />} />;
}

export function Skeleton({ h = 16, w, r = 10, style }: { h?: number | string; w?: number | string; r?: number; style?: CSSProperties }) {
  return <div className="skeleton" style={{ height: h, width: w, borderRadius: r, ...style }} aria-hidden />;
}

export function SkeletonGrid({ count = 8, min = 200, h = 160 }: { count?: number; min?: number; h?: number }) {
  return (
    <div className="page">
      <div className="grid-auto" style={{ '--min': `${min}px` } as CSSProperties}>
        {Array.from({ length: count }, (_, i) => (
          <Skeleton key={i} h={h} r={20} />
        ))}
      </div>
    </div>
  );
}

export function Progress({ value, indeterminate }: { value?: number; indeterminate?: boolean }) {
  return (
    <div className={`progress${indeterminate ? ' indeterminate' : ''}`} role="progressbar" aria-valuenow={value == null ? undefined : Math.round(value * 100)}>
      <div style={indeterminate ? undefined : { width: `${Math.max(0, Math.min(1, value ?? 0)) * 100}%` }} />
    </div>
  );
}

// ---------------------------------------------------------------- data display

/** KPI card for dashboards: label, big value, optional caption and icon. */
export function KpiCard({ label, value, caption, icon: Icon, tone = 'neutral', testId }: { label: string; value: string; caption?: string | null; icon?: LucideIcon; tone?: Tone; testId?: string }) {
  return (
    <div className="card kpi" data-testid={testId}>
      <div className="kpi-top">
        <span className="t-overline">{label}</span>
        {Icon && (
          <span className={`kpi-icon tone-${tone}`}>
            <Icon size={18} aria-hidden />
          </span>
        )}
      </div>
      <div className="kpi-value" title={value}>
        {value}
      </div>
      {caption ? <div className="kpi-cap">{caption}</div> : null}
    </div>
  );
}

/** Indian veg / non-veg mark: square outline with a centred dot. */
export function VegMark({ isVeg, size = 16 }: { isVeg: boolean; size?: number }) {
  return <span className={`veg${isVeg ? '' : ' non'}`} style={{ width: size, height: size }} role="img" aria-label={isVeg ? 'Vegetarian' : 'Non-vegetarian'} />;
}

/** The plate illustration (STYLE.md §6): rim, well, food, topping, garnish dots and shine — drawn on a 96 grid. */
export function PlateIcon({ base, sauce, garnish, size = 64 }: { base: string; sauce: string; garnish: string; size?: number }) {
  return (
    <svg className="plate" width={size} height={size} viewBox="0 0 96 96" aria-hidden>
      <circle cx="48" cy="51" r="44" fill="#000" opacity=".35" />
      <circle cx="48" cy="48" r="44" fill="#F3E9DC" />
      <circle cx="48" cy="48" r="36" fill="#E6D8C4" />
      <circle cx="48" cy="48" r="29" fill={base} />
      <circle cx="42" cy="42" r="13" fill={sauce} opacity=".9" />
      <circle cx="58" cy="56" r="4" fill={garnish} />
      <circle cx="36" cy="60" r="3" fill={garnish} />
      <circle cx="62" cy="38" r="3.5" fill={garnish} />
      <ellipse cx="26" cy="24" rx="11" ry="4.5" fill="#fff" opacity=".28" transform="rotate(-36 26 24)" />
    </svg>
  );
}

const hexOr = (v: unknown, fallback: string) => {
  const s = `${v ?? ''}`.replace('#', '');
  return s.length === 6 ? `#${s}` : fallback;
};

/** Dish photo cropped into the plate circle, or the illustrated plate when there is no photo (or it fails to load). */
export function DishImage({ src, plate, size = 64, dim }: { src?: string | null; plate?: Record<string, unknown> | null; size?: number; dim?: boolean }) {
  const [failed, setFailed] = useState(false);
  useEffect(() => setFailed(false), [src]);
  const style = { opacity: dim ? 0.45 : 1, transition: 'opacity 150ms ease-out' };
  if (src && !failed) return <img className="dish-photo" src={src} width={size} height={size} alt="" style={style} onError={() => setFailed(true)} />;
  return (
    <span style={style}>
      <PlateIcon base={hexOr(plate?.base, '#F0A93B')} sauce={hexOr(plate?.sauce, '#F6EBDD')} garnish={hexOr(plate?.garnish, '#7FB685')} size={size} />
    </span>
  );
}

// ---------------------------------------------------------------- popup menu

export type MenuItem = { label: string; icon?: LucideIcon; onClick: () => void; danger?: boolean; testId?: string } | null | false | undefined;

/** A button that opens a small menu (Flutter PopupMenuButton). */
export function MenuButton({ items, title, icon, trigger, testId }: { items: MenuItem[]; title: string; icon?: LucideIcon; trigger?: (open: () => void) => ReactNode; testId?: string }) {
  const [anchor, setAnchor] = useState<DOMRect | null>(null);
  const btn = useRef<HTMLSpanElement>(null);
  const list = items.filter(Boolean) as Exclude<MenuItem, null | false | undefined>[];
  const open = () => setAnchor(btn.current?.getBoundingClientRect() ?? null);
  if (list.length === 0) return null;
  return (
    <>
      <span ref={btn} style={{ display: 'inline-flex' }}>
        {trigger ? trigger(open) : <IconButton title={title} icon={icon!} onClick={open} testId={testId} />}
      </span>
      {anchor && <MenuPopup anchor={anchor} items={list} onClose={() => setAnchor(null)} />}
    </>
  );
}

function MenuPopup({ anchor, items, onClose }: { anchor: DOMRect; items: Exclude<MenuItem, null | false | undefined>[]; onClose: () => void }) {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState<{ left: number; top: number }>({ left: anchor.left, top: anchor.bottom + 4 });
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const w = el.offsetWidth, h = el.offsetHeight;
    let left = anchor.right - w;
    if (left < 8) left = Math.min(anchor.left, window.innerWidth - w - 8);
    let top = anchor.bottom + 4;
    if (top + h > window.innerHeight - 8) top = Math.max(8, anchor.top - h - 4);
    setPos({ left: Math.max(8, left), top });
  }, [anchor]);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose();
    const onDown = (e: MouseEvent) => !ref.current?.contains(e.target as Node) && onClose();
    window.addEventListener('keydown', onKey);
    window.addEventListener('mousedown', onDown);
    window.addEventListener('scroll', onClose, true);
    window.addEventListener('resize', onClose);
    return () => {
      window.removeEventListener('keydown', onKey);
      window.removeEventListener('mousedown', onDown);
      window.removeEventListener('scroll', onClose, true);
      window.removeEventListener('resize', onClose);
    };
  }, [onClose]);
  return createPortal(
    <div className="menu-pop" ref={ref} style={pos} role="menu">
      {items.map((it, i) => (
        <button
          key={i}
          type="button"
          role="menuitem"
          data-testid={it.testId}
          className={it.danger ? 'danger' : ''}
          onClick={() => {
            onClose();
            it.onClick();
          }}
        >
          {it.icon && <it.icon size={18} aria-hidden />}
          {it.label}
        </button>
      ))}
    </div>,
    document.body,
  );
}

export function Avatar({ text, style }: { text: string; style?: CSSProperties }) {
  return (
    <span className="avatar" style={style} aria-hidden>
      {text}
    </span>
  );
}
