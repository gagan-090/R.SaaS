import '@testing-library/jest-dom/vitest';
import { afterEach, vi } from 'vitest';
import { cleanup } from '@testing-library/react';

afterEach(() => {
  cleanup();
  window.sessionStorage.clear();
  window.localStorage.clear();
  window.location.hash = '';
});

// jsdom lacks these browser APIs
if (!window.matchMedia) {
  Object.defineProperty(window, 'matchMedia', {
    value: (q: string) => ({ matches: false, media: q, addEventListener: () => undefined, removeEventListener: () => undefined, addListener: () => undefined, removeListener: () => undefined, onchange: null, dispatchEvent: () => false }),
  });
}
if (!URL.createObjectURL) URL.createObjectURL = vi.fn(() => 'blob:test');
if (!URL.revokeObjectURL) URL.revokeObjectURL = vi.fn();
window.open = vi.fn() as unknown as typeof window.open;
