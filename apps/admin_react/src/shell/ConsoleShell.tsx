import { useEffect, useState, type ReactNode } from 'react';
import { useLocation, useNavigate, useSearchParams } from 'react-router-dom';
import { ChevronDown, ChevronUp, ExternalLink, LogOut, Menu, Smartphone } from 'lucide-react';
import { api } from '../api/client';
import { firstChar } from '../lib/format';
import { openLink } from '../lib/download';
import { auth, useSession } from '../state/auth';
import { adminRoles, useCached, useRestaurantLook } from '../state/app';
import { IconButton, ThemeSwitch } from '../ui/kit';
import { apkUrl, type NavItem } from './nav';

/**
 * Sidebar on wide screens, app bar + drawer on phones. Items the signed-in role cannot use are hidden
 * (the API refuses them anyway).
 */
export function ConsoleShell({ nav, brand, children }: { nav: NavItem[]; brand: string; children: ReactNode }) {
  const me = useSession();
  const loc = useLocation();
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const [drawer, setDrawer] = useState(false);
  const look = useRestaurantLook();
  const items = nav.filter((n) => n.permission == null || me?.can(n.permission));
  const root = items[0]?.path ?? '/';
  const path = loc.pathname;
  let idx = -1;
  items.forEach((n, i) => {
    if (n.path === root ? path === root : path.startsWith(n.path)) idx = i;
  });
  useEffect(() => setDrawer(false), [loc.pathname, loc.search]);

  const go = (p: string) => {
    setDrawer(false);
    navigate(p);
  };
  const logoId = look?.brand?.logoImageId;

  const sidebar = (
    <aside className="sidebar">
      <div className="sidebar-head">
        {logoId && <img className="brand-logo" data-testid="brand-logo" src={api.mediaUrl(logoId)} alt="" onError={(e) => ((e.target as HTMLImageElement).style.display = 'none')} />}
        {look?.brand && look.name ? (
          <div className="brand-title" data-testid="brand-name" style={{ fontSize: '1.375rem', lineHeight: 1.1 }}>
            {look.name}
          </div>
        ) : (
          <div className="brand-title">{'House\nPlating'}</div>
        )}
        <div className="brand-sub">{brand} console</div>
      </div>
      <nav className="nav" aria-label="Main">
        {items.map((n, i) =>
          n.path === '/admins' ? (
            <AdminsNavGroup key={n.path} item={n} selected={i === idx} role={params.get('role')} onGo={go} />
          ) : (
            <button key={n.path} type="button" data-testid={`nav-${n.label}`} className={`nav-item${i === idx ? ' on' : ''}`} aria-current={i === idx ? 'page' : undefined} onClick={() => go(n.path)}>
              <n.icon size={20} aria-hidden />
              <span className="grow">{n.label}</span>
            </button>
          ),
        )}
      </nav>
      <div className="sidebar-foot">
        <button type="button" className="nav-item" data-testid="download-apk" onClick={() => openLink(apkUrl)}>
          <Smartphone size={20} aria-hidden />
          <span className="grow" title="Download the Android POS app (APK)">Android POS app</span>
          <ExternalLink size={16} style={{ opacity: 0.6 }} aria-hidden />
        </button>
      </div>
      <div style={{ padding: '0 16px' }}>
        <ThemeSwitch onSidebar />
      </div>
      {me && (
        <div className="sidebar-user">
          <span className="avatar">{firstChar(me.me.name)}</span>
          <div className="grow">
            <div className="t-label ellipsis">{`${me.me.name ?? ''}`}</div>
            <div className="ellipsis" style={{ fontSize: 12, opacity: 0.7 }}>
              {`${me.me.email ?? ''}`}
            </div>
          </div>
          <IconButton title="Sign out" icon={LogOut} testId="sign-out" onClick={() => void auth.logout()} />
        </div>
      )}
    </aside>
  );

  return (
    <div className="shell">
      {sidebar}
      <header className="topbar">
        <IconButton title="Menu" icon={Menu} testId="open-nav" onClick={() => setDrawer(true)} />
        <span className="t-card ellipsis">{look?.brand && look.name ? look.name : 'House Plating'}</span>
        <span className="muted ellipsis" style={{ marginLeft: 'auto', paddingRight: 8, fontSize: 13 }}>
          {idx >= 0 ? items[idx].label : ''}
        </span>
      </header>
      {drawer && (
        <>
          <div className="drawer-backdrop" onClick={() => setDrawer(false)} />
          <div className="drawer">{sidebar}</div>
        </>
      )}
      <main className="main" key={loc.pathname + loc.search}>
        {children}
      </main>
    </div>
  );
}

/** "Admins" with an arrow: opens the admin types (All, Super Admin, Onboarding Admin …); each shows only that kind. */
function AdminsNavGroup({ item, selected, role, onGo }: { item: NavItem; selected: boolean; role: string | null; onGo: (p: string) => void }) {
  const [open, setOpen] = useState(selected);
  useEffect(() => {
    if (selected) setOpen(true);
  }, [selected]);
  const roles = useCached(adminRoles, open);
  const sub = (label: string, r: string | null) => (
    <button key={label} type="button" data-testid={`nav-admins-${r ?? 'all'}`} className={`nav-sub${selected && role === r ? ' on' : ''}`} onClick={() => onGo(r == null ? '/admins' : `/admins?role=${encodeURIComponent(r)}`)}>
      {label}
    </button>
  );
  return (
    <div>
      <div className={`nav-item${selected ? ' on' : ''}`} style={{ paddingRight: 6 }}>
        <button
          type="button"
          data-testid={`nav-${item.label}`}
          style={{ all: 'unset', display: 'flex', alignItems: 'center', gap: 14, flex: 1, cursor: 'pointer', minWidth: 0 }}
          onClick={() => {
            setOpen(true);
            onGo('/admins');
          }}
        >
          <item.icon size={20} aria-hidden />
          <span className="grow">{item.label}</span>
        </button>
        <button type="button" className="nav-toggle" data-testid="nav-admins-toggle" title={open ? 'Hide admin types' : 'Show admin types'} aria-label={open ? 'Hide admin types' : 'Show admin types'} onClick={() => setOpen(!open)}>
          {open ? <ChevronUp size={20} /> : <ChevronDown size={20} />}
        </button>
      </div>
      {open && (
        <>
          {sub('All', null)}
          {(roles ?? []).map((r) => sub(`${r.name}`, `${r.name}`))}
        </>
      )}
    </div>
  );
}
