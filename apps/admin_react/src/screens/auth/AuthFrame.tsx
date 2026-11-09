import type { ReactNode } from 'react';
import { ChefHat } from 'lucide-react';
import { ThemeSwitch } from '../../ui/kit';

/** The sign-in card: BhojMitra mark, title, subtitle and the form. */
export function AuthFrame({ title, subtitle, children, plain }: { title?: string; subtitle?: ReactNode; children: ReactNode; plain?: boolean }) {
  return (
    <div className="auth-wrap page-enter">
      <div className="auth-bar">
        <ThemeSwitch compact />
      </div>
      <div className="auth-center">
        <div className="card auth-card">
          {!plain && (
            <>
              <div className="row">
                <span className="auth-mark">
                  <ChefHat size={20} aria-hidden />
                </span>
                <span className="t-overline accent-text">BhojMitra</span>
              </div>
              <h1 className="t-screen mt-16">{title}</h1>
              <div className="muted mt-4">{subtitle}</div>
              <div style={{ height: 24 }} />
            </>
          )}
          {children}
        </div>
      </div>
    </div>
  );
}
