import { useEffect, useState } from 'react';
import { api, type Json } from '../api/client';
import { auth, useAuth, useSession } from './auth';
import { brandFromJson, type Brand } from './brand';
import { Store, useStore } from './store';

// ---------------------------------------------------------------- appearance

export type ThemeMode = 'light' | 'dark' | 'system';
// v2: the white (Light) theme became the default on 13 Oct 2026, so earlier "Auto" choices start over
const themeKey = 'appearance.v2';

function loadTheme(): ThemeMode {
  try {
    const v = window.localStorage.getItem(themeKey);
    if (v === 'light' || v === 'dark' || v === 'system') return v;
  } catch {
    /* storage unavailable (private window): stay on the white theme */
  }
  return 'light';
}

export const themeMode = new Store<ThemeMode>(loadTheme());
export function setThemeMode(m: ThemeMode) {
  themeMode.set(m);
  try {
    window.localStorage.setItem(themeKey, m);
  } catch {
    /* not remembered on this device */
  }
}
export const useThemeMode = () => useStore(themeMode);

/** Whether the dark palette is showing now. */
export function useIsDark() {
  const mode = useThemeMode();
  const [sysDark, setSysDark] = useState(() => window.matchMedia?.('(prefers-color-scheme: dark)').matches ?? false);
  useEffect(() => {
    const mq = window.matchMedia?.('(prefers-color-scheme: dark)');
    if (!mq) return;
    const on = () => setSysDark(mq.matches);
    mq.addEventListener('change', on);
    return () => mq.removeEventListener('change', on);
  }, []);
  return mode === 'dark' || (mode === 'system' && sysDark);
}

// ---------------------------------------------------------------- restaurant look

/** The signed-in restaurant's name and look. `brand` is null unless its plan includes "branding" and the owner set one. */
export type RestaurantLook = { name: string; brand: Brand | null };
export const brandRefresh = new Store(0);
export const restaurantLook = new Store<RestaurantLook | null>(null);
export const bumpBrand = () => brandRefresh.update((n) => n + 1);

/** Loads the restaurant look whenever the account or a branding save changes it. Super Admins always see BhojMitra. */
export function useRestaurantLookLoader() {
  const s = useSession();
  const refresh = useStore(brandRefresh);
  const meKey = s?.me;
  useEffect(() => {
    let live = true;
    if (!s || !s.isRestaurant || !s.can('restaurant.profile.read')) {
      restaurantLook.set(null);
      return;
    }
    api
      .overview()
      .then((o) => {
        if (live) restaurantLook.set({ name: `${o.restaurant?.name ?? ''}`, brand: brandFromJson(o.branding) });
      })
      .catch(() => {
        if (live) restaurantLook.set(null);
      });
    return () => {
      live = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [meKey, refresh]);
}
export const useRestaurantLook = () => useStore(restaurantLook);

// ---------------------------------------------------------------- shared lists

/** A cached list that can be invalidated after edits (plans, admin roles). */
class Cached<T> {
  readonly value = new Store<T | null>(null);
  private inflight: Promise<T> | null = null;
  constructor(private load: () => Promise<T>) {}
  get(): Promise<T> {
    const v = this.value.get();
    if (v != null) return Promise.resolve(v);
    if (!this.inflight) {
      this.inflight = this.load()
        .then((x) => {
          this.value.set(x);
          return x;
        })
        .finally(() => (this.inflight = null));
    }
    return this.inflight;
  }
  invalidate() {
    this.value.set(null);
    void this.get().catch(() => undefined);
  }
  clear() {
    this.value.set(null);
  }
}

/** Plans that can be sold right now (not archived) — used by registration, license changes and filters. */
export const activePlans = new Cached<Json[]>(() => api.plans());
/** Admin types (platform roles) for the sidebar's Admins sub-menu. */
export const adminRoles = new Cached<Json[]>(() => api.roles());

export function useCached<T>(c: Cached<T>, enabled = true): T | null {
  const v = useStore(c.value);
  useEffect(() => {
    if (enabled && v == null) void c.get().catch(() => undefined);
  }, [c, v, enabled]);
  return v;
}

// a new account must never see the previous one's cached lists
auth.state.subscribe(() => {
  if (auth.state.get().kind !== 'signedIn') {
    activePlans.clear();
    adminRoles.clear();
  }
});

export { useAuth };
