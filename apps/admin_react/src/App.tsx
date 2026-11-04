import { useEffect, useLayoutEffect, type ReactNode } from 'react';
import { HashRouter, Navigate, Route, Routes, useLocation } from 'react-router-dom';
import { auth, useAuth, useSession } from './state/auth';
import { useIsDark, useRestaurantLook, useRestaurantLookLoader } from './state/app';
import { brandVars } from './state/brand';
import { ConsoleShell } from './shell/ConsoleShell';
import { platformNav, redirectFor, restaurantNav } from './shell/nav';
import { DialogHost, ToastHost } from './ui/overlay';
import { LoginScreen } from './screens/auth/LoginScreen';
import { MfaScreen } from './screens/auth/MfaScreen';
import { SetPinScreen } from './screens/auth/SetPinScreen';
import { VerifyEmailScreen } from './screens/auth/VerifyEmailScreen';
import { DashboardScreen } from './screens/platform/DashboardScreen';
import { RestaurantsScreen } from './screens/platform/RestaurantsScreen';
import { RestaurantDetailScreen } from './screens/platform/RestaurantDetailScreen';
import { PlansScreen } from './screens/platform/PlansScreen';
import { AdminsScreen } from './screens/platform/AdminsScreen';
import { AuditScreen } from './screens/platform/AuditScreen';
import { ConsoleHome } from './screens/console/HomeScreen';
import { MenuScreen } from './screens/console/MenuScreen';
import { TablesScreen } from './screens/console/TablesScreen';
import { StaffScreen } from './screens/console/StaffScreen';
import { RolesScreen } from './screens/console/RolesScreen';
import { InventoryScreen } from './screens/console/InventoryScreen';
import { ExpensesScreen } from './screens/console/ExpensesScreen';
import { RestaurantAuditScreen } from './screens/console/RestaurantAuditScreen';
import { DevicesScreen } from './screens/console/DevicesScreen';
import { SettingsScreen } from './screens/console/SettingsScreen';

/** Light / dark palette plus the restaurant's own look on the document root. */
function Appearance() {
  const dark = useIsDark();
  const look = useRestaurantLook();
  useLayoutEffect(() => {
    const root = document.documentElement;
    root.dataset.theme = dark ? 'dark' : 'light';
    const vars = brandVars(look?.brand ?? null, dark);
    const names = ['--accent', '--on-accent', '--accent-ink', '--brand', '--on-brand', '--highlight', '--on-highlight', '--nav-accent', '--on-nav-accent', '--heading-weight', '--heading-transform', '--text-scale'];
    for (const n of names) root.style.removeProperty(n);
    for (const [k, v] of Object.entries(vars)) root.style.setProperty(k, v);
  }, [dark, look]);
  return null;
}

/** Sends people where their sign-in state allows (the API enforces it again). */
function Guard({ children }: { children: ReactNode }) {
  const state = useAuth();
  const me = useSession();
  const loc = useLocation();
  if (state.kind === 'restoring') {
    return (
      <div className="center" style={{ height: '100%' }} role="status" aria-label="Restoring your session">
        <span className="spinner" style={{ width: 36, height: 36, borderWidth: 3 }} />
      </div>
    );
  }
  const to = redirectFor({ kind: state.kind, isRestaurant: me?.isRestaurant }, loc.pathname);
  if (to != null && to !== loc.pathname) return <Navigate to={to} replace />;
  return <>{children}</>;
}

function Platform({ children }: { children: ReactNode }) {
  return (
    <ConsoleShell nav={platformNav} brand="Platform">
      {children}
    </ConsoleShell>
  );
}

function Restaurant({ children }: { children: ReactNode }) {
  return (
    <ConsoleShell nav={restaurantNav} brand="Restaurant">
      {children}
    </ConsoleShell>
  );
}

function Routed() {
  useRestaurantLookLoader();
  return (
    <Guard>
      <Routes>
        <Route path="/login" element={<LoginScreen />} />
        <Route path="/mfa" element={<MfaScreen />} />
        <Route path="/verify-email" element={<VerifyEmailScreen />} />
        <Route path="/set-pin" element={<SetPinScreen />} />
        <Route path="/" element={<Platform><DashboardScreen /></Platform>} />
        <Route path="/restaurants" element={<Platform><RestaurantsScreen /></Platform>} />
        <Route path="/restaurants/:id" element={<Platform><RestaurantDetailScreen /></Platform>} />
        <Route path="/plans" element={<Platform><PlansScreen /></Platform>} />
        <Route path="/admins" element={<Platform><AdminsScreen /></Platform>} />
        <Route path="/audit" element={<Platform><AuditScreen /></Platform>} />
        <Route path="/console" element={<Restaurant><ConsoleHome /></Restaurant>} />
        <Route path="/console/menu" element={<Restaurant><MenuScreen /></Restaurant>} />
        <Route path="/console/tables" element={<Restaurant><TablesScreen /></Restaurant>} />
        <Route path="/console/staff" element={<Restaurant><StaffScreen /></Restaurant>} />
        <Route path="/console/roles" element={<Restaurant><RolesScreen /></Restaurant>} />
        <Route path="/console/inventory" element={<Restaurant><InventoryScreen /></Restaurant>} />
        <Route path="/console/expenses" element={<Restaurant><ExpensesScreen /></Restaurant>} />
        <Route path="/console/audit" element={<Restaurant><RestaurantAuditScreen /></Restaurant>} />
        <Route path="/console/devices" element={<Restaurant><DevicesScreen /></Restaurant>} />
        <Route path="/console/settings" element={<Restaurant><SettingsScreen /></Restaurant>} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
      <DialogHost />
    </Guard>
  );
}

/** One web app, two consoles: platform admins get the Super Admin console, restaurant users the Restaurant console. */
export default function App() {
  useEffect(() => auth.start(), []);
  return (
    <HashRouter>
      <Appearance />
      <Routed />
      <ToastHost />
    </HashRouter>
  );
}
