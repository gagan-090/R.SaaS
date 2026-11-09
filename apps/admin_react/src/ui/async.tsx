import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';
import { Lock } from 'lucide-react';
import { ApiException, errorText } from '../api/client';
import { EmptyState, ErrorState, LoadingState, PageFrame } from './kit';

/** Loads data and keeps loading / error / data apart. `reload()` keeps the old data visible while refreshing. */
export function useAsync<T>(load: () => Promise<T>, deps: unknown[]) {
  const [state, setState] = useState<{ data: T | null; error: unknown; loading: boolean }>({ data: null, error: null, loading: true });
  const seq = useRef(0);
  const run = useCallback(() => {
    const n = ++seq.current;
    setState((s) => ({ ...s, loading: true }));
    load().then(
      (data) => n === seq.current && setState({ data, error: null, loading: false }),
      (error) => n === seq.current && setState({ data: null, error, loading: false }),
    );
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  // like FutureBuilder, the last data stays on screen while new data loads (no spinner flash on refresh or filter change)
  useEffect(() => run(), [run]);
  return { ...state, reload: run };
}

/** Error codes the API uses when the restaurant's plan (or the lack of one) blocks a page. */
export const planErrorCodes = new Set(['feature_not_in_plan', 'no_active_plan', 'license_read_only']);
export const isPlanError = (e: unknown) => e instanceof ApiException && planErrorCodes.has(e.code);

/** A page that failed to load: a plan refusal gets a plain "not in your plan" page; anything else the error + retry. */
export function LoadError({ error, page, onRetry }: { error: unknown; page: string; onRetry?: () => void }) {
  if (!isPlanError(error)) return <ErrorState message={errorText(error)} onRetry={onRetry} />;
  return (
    <PageFrame title={page}>
      <EmptyState
        testId="plan-locked"
        icon={Lock}
        title="Not in your plan"
        message={`${page} is not included in your restaurant's current plan, or the plan is no longer active.\nAsk BhojMitra to activate or upgrade your plan, then open this page again.`}
      />
    </PageFrame>
  );
}

/** Loads a future and renders loading / error / empty / data states consistently (Flutter AsyncView). */
export function AsyncView<T>({ load, deps, children, isEmpty, emptyTitle = 'Nothing here yet', page = 'This page' }: {
  load: () => Promise<T>;
  deps: unknown[];
  children: (data: T, reload: () => void) => ReactNode;
  isEmpty?: (d: T) => boolean;
  emptyTitle?: string;
  page?: string;
}) {
  const { data, error, reload } = useAsync(load, deps);
  if (data == null && error == null) return <LoadingState />;
  if (error != null) return <LoadError error={error} page={page} onRetry={reload} />;
  if (isEmpty?.(data as T)) return <EmptyState title={emptyTitle} />;
  return <>{children(data as T, reload)}</>;
}
