import { useSyncExternalStore } from 'react';

/** A tiny observable value usable from React (useStore) and from plain code (get/set). */
export class Store<T> {
  private listeners = new Set<() => void>();
  constructor(private value: T) {}
  get = () => this.value;
  set = (v: T) => {
    this.value = v;
    this.listeners.forEach((l) => l());
  };
  update = (f: (v: T) => T) => this.set(f(this.value));
  subscribe = (l: () => void) => {
    this.listeners.add(l);
    return () => this.listeners.delete(l);
  };
}

export function useStore<T>(s: Store<T>): T {
  return useSyncExternalStore(s.subscribe, s.get, s.get);
}
