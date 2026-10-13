# Web consoles: Restaurant console & Super Admin

One web app (`apps/admin_web`), two consoles. The account that signs in decides which one opens; the API enforces
every permission either way. Light or dark follows the browser / device setting.

| Who signs in | Console | What they do there |
|---|---|---|
| Platform admin (Super Admin, Onboarding Admin, Platform Auditor) — MFA required | **Super Admin** | Register restaurants, plans & licenses, payments, suspend / reactivate, platform admins, audit |
| Restaurant owner / IT admin (email + password) | **Restaurant console** | Dashboard, menu & photos, floors & tables, staff & PINs, hubs & devices, settings |

## Run it

```bash
# API (once): migrate + seed, then start on 0.0.0.0:3000
pnpm --filter @rsaas/api db:migrate:deploy && pnpm --filter @rsaas/api db:seed
pnpm --filter @rsaas/api exec nest build && node apps/api/dist/main.js

# Web console: build for the API address your browser / phone can reach, then serve it on :8080
cd apps/admin_web
flutter build web --release --dart-define=API_BASE_URL=http://<PC-IP>:3000/api/v1
python3 -m http.server 8080 --bind 0.0.0.0 --directory build/web
```

Open `http://<PC-IP>:8080` (or `http://localhost:8080` on the PC). The page origin must be listed in `CORS_ORIGINS` in
`.env.local` (e.g. `http://localhost:8080,http://<PC-IP>:8080`) — restart the API after changing it.
During development `flutter run -d chrome --web-port 8080 --dart-define=API_BASE_URL=…` works too.

## The flow, in order

1. **Super Admin registers the restaurant** (Restaurants → Register). The owner gets a verification email
   (in dev the link is printed by the API), sets a password, and the restaurant is active on its plan.
2. **Owner signs in to the Restaurant console.** The dashboard shows a "Get ready for service" checklist:
   1. **Menu** — add categories, then dishes: price (₹, before GST), GST rate, veg / non-veg, available / sold out,
      optional photo (cropped square and compressed in the browser; every dish has an illustrated plate otherwise).
   2. **Floors & tables** — one floor at least, then tables with seats. The POS table map shows exactly this.
   3. **Staff** — each person gets a role and a 4–8 digit PIN for the POS. Cashiers can be allowed to give discounts.
      Chef, IT admin and auditor need Premium; IT admins and auditors can also get console sign-in.
   4. **Hubs & devices** — install the POS on the main cashier device, choose "Main device", enter the server
      address shown on this page, sign in as owner / IT admin. The device registers as the branch hub.
3. **Staff use the POS with their PIN.** Menu, tables, staff and photos reach the hub within a minute (config pull)
   and keep working offline. Bills, payments, tips and KOTs flow back to the cloud and appear on the dashboard.
4. **Day to day:** mark dishes sold out, change prices, add people or turn them off, revoke a lost device
   (with a reason; it stops syncing immediately), see today's sales, payment split and top dishes.

## Demo accounts (local seed)

| Account | Where | Login |
|---|---|---|
| Super Admin | web, Super Admin console | `admin@example.com` / password printed by `gen-dev-secrets` (MFA set-up on first sign-in) |
| Demo Dhaba owner | web Restaurant console, POS "Main device" | `owner@demo.com` / `12345678` (changed locally from the seed's random password) |
| Staff | POS | Demo Owner, Ravi (cashier), Anita & Sohan (waiters), Kunal (chef), Imran (IT admin), Asha (auditor) — PIN `1234` |
