# House Plating console — React

The web console (Super Admin portal **and** restaurant console) rebuilt in React + TypeScript (Vite). It is a
screen-for-screen port of the Flutter app in `apps/admin_web`: same API (`packages/contracts/openapi.json`), same
hash routes, same sign-in flows, same permission gating and the same House Plating look (`packages/ui_kit/STYLE.md`).

## Run

```bash
pnpm install                      # from the repo root
cd apps/admin_react
cp .env.example .env.local        # optional: VITE_API_BASE_URL, VITE_APK_URL
pnpm dev                          # http://localhost:8080 (matches the API's default CORS_ORIGINS / CONSOLE_URL)
pnpm test                         # unit + whole-app flow tests against the recorded API fixtures
pnpm build                        # static site in dist/ (vercel.json rewrites to index.html)
```

| Variable | Default | Same as Flutter |
| --- | --- | --- |
| `VITE_API_BASE_URL` | `http://localhost:3000/api/v1` | `--dart-define=API_BASE_URL` |
| `VITE_APK_URL` | the Drive link | `--dart-define=APK_URL` |

## What is the same as `apps/admin_web`

- **Routes** (hash URLs, so the links the API emails keep working): `#/login` (`?mode=employee` for email + PIN),
  `#/mfa`, `#/verify-email?token=…`, `#/set-pin?token=…`; platform `#/`, `#/restaurants`, `#/restaurants/:id`,
  `#/plans`, `#/admins?role=…`, `#/audit`; restaurant `#/console`, `/menu`, `/tables`, `/inventory`, `/expenses`,
  `/audit`, `/staff`, `/roles`, `/devices`, `/settings`. Redirect rules are in `src/shell/nav.ts` (`redirectFor`).
- **Sign-in**: password → MFA code / recovery code, or first-time MFA enrolment (QR + 10 recovery codes); employee
  email + PIN with "Forgot PIN?". Refresh token in `sessionStorage` (`house-plating.session.v1`), access token in memory,
  one shared refresh on 401.
- **Every login type**: platform admins (Super Admin, Onboarding Admin, Platform Auditor, custom roles), restaurant
  owner, restaurant admin (IT admin), cashier, waiter, chef, auditor and custom restaurant roles. Navigation, buttons
  and home panels follow `/me` permissions exactly as in Flutter; the API still enforces them.
- **Money** stays integer paise: every rupee box is parsed with `parseRupees` (no floats).
- **Step-up** for MFA changes, **reasons** for every destructive action, **idempotency keys** for stock movements and purchases.

## Layout

```
src/api/client.ts        ApiClient (port of api_client.dart)
src/state/               auth state machine, theme, restaurant branding, cached plans / admin roles
src/lib/                 money, dates, labels, PIN policy, menu rules, floor model, image prep, downloads
src/ui/                  House Plating components, dialogs (openDialog / askReason / askStepUp / confirm), toasts
src/shell/               sidebar / drawer shell and navigation
src/screens/auth|platform|console
src/test/                Vitest: lib, session and whole-app flows on packages/contracts/fixtures
```
