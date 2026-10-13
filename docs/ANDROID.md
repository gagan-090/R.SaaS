# Running the POS on an Android phone

One APK serves every restaurant role. The phone can **be the branch hub** (signs in to the cloud once, then works offline) or
**pair with a hub** on the same Wi-Fi.

## 1. Start the backend on your PC

```bash
/Library/PostgreSQL/18/bin/pg_ctl -D .localdb/pg -o "-p 5433 -k /tmp" start   # or: docker compose … up -d db
pnpm --filter @rsaas/api db:migrate:deploy && pnpm --filter @rsaas/api db:seed   # demo restaurant, Premium, one user per role
pnpm --filter @rsaas/api exec nest build && node apps/api/dist/main.js          # listens on 0.0.0.0:3000
```

The phone and the PC must be on the **same Wi-Fi**. If macOS asks whether `node` may accept incoming connections, click **Allow**.
Check from the phone's browser: `http://<PC-IP>:3000/api/docs` should open Swagger.

## 2. Build and install the APK

```bash
cd apps/pos_app
flutter build apk --release --target-platform android-arm,android-arm64 \
  --dart-define=API_BASE_URL=http://<PC-IP>:3000/api/v1
adb install -r build/app/outputs/flutter-apk/app-release.apk     # or copy the APK to the phone and open it
```

The `API_BASE_URL` given at build time is only the default in the setup screen; you can change it on the phone.

Release signing uses `android/key.properties` + `android/keystore/upload.jks` (both gitignored, created locally).
**Back up the keystore and key.properties somewhere safe.** Without them Play Store updates are impossible.
If they are missing, the build falls back to the debug key, which is fine for testing.

## 3. First start on the phone ("This device is the hub")

1. Open **House Plating POS** → "This device is the hub".
2. Cloud API URL: `http://<PC-IP>:3000/api/v1`. Sign in as the **owner**: `owner@demo-dhaba.example` and the password printed by
   the first `db:seed` (or set `DEMO_OWNER_PASSWORD` before seeding a fresh database).
3. The phone registers as the branch hub, pulls menu, tables, staff and the license, and shows **Who is working?**

## 4. Try every role (all demo PINs are **1234**)

| Staff | Role | Lands on | Can do |
|---|---|---|---|
| Demo Owner | owner | Tables | everything below + discounts, approvals, adjustments, printers |
| Ravi | cashier | Tables | open tables / takeaway, KOT, bill, tip, split payments, reprint, adjust with owner PIN |
| Anita, Sohan | waiter | Tables | open tables as themselves, add dishes, send KOT, see READY from the kitchen, own tips; cannot bill |
| Kunal | chef | Kitchen display | Start → Ready → Served on each KOT; sees notes and cancelled items |
| Imran | IT admin | Setup | printers (IP, 80/58 mm, test print), hub QR to pair more devices, sync health |
| Asha | auditor | Tables (read-only) | look at tables, orders and bills; every write is refused by the hub |

Switch user with the sign-out icon at the top right. The ☰ menu lists only what the signed-in role may open.

**Second device** (optional, Premium/Professional): on the hub phone open Menu → Hub & devices; on the other phone choose
"Pair with a hub" and paste the QR text, or type IP, port 8443, the 6-digit code and the fingerprint.

## 5. Printing

A thermal printer on the same Wi-Fi (raw TCP 9100) is set in Menu → **Printers**. With no printer, "Print bill" says so; the hub
can also return the PDF (`POST /bills/:id/print`).

## Known limits

- Hub mode keeps running while the app is open. Android may stop it if the app is swiped away or the phone sleeps for long.
  Keep the hub phone on the charger with the app open, or use a Windows PC as the hub.
- Camera QR scanning is not built yet; paste the QR text or type the IP and code.
- Plain `http://` to the API is allowed for LAN testing only; production must use `https://`.
