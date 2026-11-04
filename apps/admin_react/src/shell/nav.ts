import {
  Award, BadgeCheck, ClipboardCheck, LayoutDashboard, Package, ReceiptText, Receipt, Router, ShieldCheck, SlidersHorizontal, Store, UtensilsCrossed, Armchair,
  type LucideIcon,
} from 'lucide-react';

export type NavItem = { path: string; label: string; icon: LucideIcon; permission: string | null };

/** The Android POS app (cashier / waiter / kitchen). Override per deployment with VITE_APK_URL. */
export const apkUrl: string = import.meta.env.VITE_APK_URL ?? 'https://drive.google.com/file/d/1v8AgxWVezOqZ8yGYYs9iDQBt-8Bw9-fT/view?usp=sharing';

export const platformNav: NavItem[] = [
  { path: '/', label: 'Dashboard', icon: LayoutDashboard, permission: null },
  { path: '/restaurants', label: 'Restaurants', icon: Store, permission: 'platform.restaurant.read' },
  { path: '/plans', label: 'Plans', icon: Award, permission: 'platform.restaurant.read' },
  { path: '/admins', label: 'Admins', icon: ShieldCheck, permission: 'platform.admin.read' },
  { path: '/audit', label: 'Audit log', icon: ReceiptText, permission: 'platform.audit.read' },
];

export const restaurantNav: NavItem[] = [
  { path: '/console', label: 'Dashboard', icon: LayoutDashboard, permission: null },
  { path: '/console/menu', label: 'Menu', icon: UtensilsCrossed, permission: 'menu.read' },
  { path: '/console/tables', label: 'Floors & tables', icon: Armchair, permission: 'floor.read' },
  { path: '/console/inventory', label: 'Inventory', icon: Package, permission: 'inventory.read' },
  { path: '/console/expenses', label: 'Expenses', icon: Receipt, permission: 'expense.read' },
  { path: '/console/audit', label: 'Audit & records', icon: ClipboardCheck, permission: 'audit.read' },
  { path: '/console/staff', label: 'Staff', icon: BadgeCheck, permission: 'staff.read' },
  { path: '/console/roles', label: 'Roles', icon: ShieldCheck, permission: 'staff.read' },
  { path: '/console/devices', label: 'Hubs & devices', icon: Router, permission: 'device.manage' },
  { path: '/console/settings', label: 'Settings', icon: SlidersHorizontal, permission: 'restaurant.profile.read' },
];

/** Where the router sends someone, given their sign-in state (port of the GoRouter redirect in app.dart). */
export function redirectFor(state: { kind: string; isRestaurant?: boolean }, path: string): string | null {
  if (path === '/verify-email' || path === '/set-pin') return null; // emailed links work whether or not someone is signed in
  switch (state.kind) {
    case 'restoring':
      return null;
    case 'signedOut':
      return path === '/login' ? null : '/login';
    case 'mfaChallenge':
    case 'mfaEnrollment':
      return path === '/mfa' ? null : '/mfa';
    default:
      if (state.isRestaurant) return path.startsWith('/console') ? null : '/console';
      return path === '/restoring' || path === '/login' || path === '/mfa' || path.startsWith('/console') ? '/' : null;
  }
}
