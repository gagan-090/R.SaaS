# UI STYLE PROMPT: "House Plating · Midnight Masala"

> Use this in three places:
> 1. Save it as `packages/ui_kit/STYLE.md` and add the line "Follow packages/ui_kit/STYLE.md for every screen" to `CLAUDE.md`.
> 2. Paste it before any request to Claude to design or build a screen ("Using the style below, build the Payment screen…").
> 3. Give it to Aditya as the design brief for `packages/ui_kit`.

---

You are designing and building screens for a restaurant billing and POS product used on Windows PCs, Android tablets, Android phones and a web admin portal. Every screen must follow the "House Plating" design system below exactly. Its service theme is called **Midnight Masala**. The goal is an interface that feels like a good restaurant at night: warm, calm and appetising. It should be fast enough for a cashier on a Friday rush and readable for a chef across a hot kitchen.

## 1. Personality

- **Warm, not loud.** A dark espresso ground, warm off-white text, and one confident saffron action per screen.
- **Food-first.** Dishes are drawn as illustrated plates (section 6), never stock photos, so every menu looks appetising on day one, even with no images uploaded.
- **Calm under pressure.** Big targets, few choices per screen, and status shown by colour plus words, never colour alone.
- **Editorial type.** A soft serif (Fraunces) for anything a person reads at a glance: totals, table numbers, dish names, screen titles. A clean sans (DM Sans) for everything they act on.

## 2. Two themes, one system

| Theme | Where it is used | Ground | Text |
| --- | --- | --- | --- |
| Service (dark) | Cashier POS, table map, payment, waiter app, kitchen display, hub screen | Espresso `#140D0C` | Ghee `#F6EBDD` |
| Back office (light) | Super Admin portal, owner reports, settings on the web | Paper `#FBF6EC` | Ink `#2A211C` |

The kitchen display uses an even darker ground, `#0C0807`, for glare in bright kitchens.

## 3. Colour tokens

Use these names in code (`HPColors.saffron`, etc.). Never hard-code hex values in a screen.

| Token | Hex | Role |
| --- | --- | --- |
| `espresso` | `#140D0C` | Service ground |
| `ember` | `#1F1615` | Cards, panels, inputs on dark |
| `emberRaised` | `#2A1E1C` | Chips, steppers, keypad keys, hover |
| `clayLine` | `#3A2B28` | Borders, dividers, inactive outlines |
| `ghee` | `#F6EBDD` | Primary text on dark |
| `husk` | `#B8A595` | Secondary text on dark (the minimum for readable text) |
| `smoke` | `#8F7D6E` | Disabled text and placeholders only, never information |
| `saffron` | `#F0A93B` | Primary action, focus ring, "ordering", the amount to pay |
| `chili` | `#E2553E` | Errors, destructive actions, "bill printed", tickets over 20 min, non-veg mark |
| `cardamom` | `#7FB685` | Success, "served", "ready", hub online, tickets under 10 min |
| `jamun` | `#B48BD6` | Reserved tables, pending states |
| `wine` | `#6B1F2A` | Back-office brand colour, primary button on light |
| `wineDeep` | `#3A1119` | Back-office sidebar |
| `paper` | `#FBF6EC` | Back-office ground |
| `paperCard` | `#FFFDF8` | Cards on light |
| `paperLine` | `#E4D8C2` | Borders on light |
| `ink` | `#2A211C` | Text on light |
| `inkMuted` | `#6F6155` | Secondary text on light |
| `vegGreen` | `#4CAF50` | Veg mark only |

Text that sits on a filled colour uses a dark text colour: `#1A0F0C` on saffron, `#10210F` on cardamom, `#1E1028` on jamun, and `#FFF1EA` on chili.

**Rules**
- Use one saffron primary action per screen region. Everything else is an outline or a quiet button.
- Status is always colour plus a word or icon ("Hub online", "Bill printed"), never colour alone.
- Tinted status pills use the colour at 14% opacity as the fill and a lighter tint of it for the text (e.g. cardamom pill: fill `rgba(127,182,133,0.14)`, text `#A6D6AB`).
- Text contrast must be at least 4.5:1. On dark grounds, nothing important goes below `husk`.

## 4. Typography

Use the Flutter `google_fonts` package (Fraunces, DM Sans, DM Mono). All numbers use tabular figures (`FontFeature.tabularFigures()`) so prices line up.

| Token | Font | Size / weight | Use |
| --- | --- | --- | --- |
| `displayTotal` | Fraunces | 40–56 / 700, letter-spacing −1 | Amount to pay, KPI numbers |
| `titleScreen` | Fraunces | 30–34 / 600, letter-spacing −0.5 | Screen titles ("Table 12") |
| `titleCard` | Fraunces | 19–26 / 600–700 | Dish names, ticket headers, table numbers |
| `note` | Fraunces italic | 14–22 / 500, saffron tint `#F5C779` | Kitchen notes ("less spicy") |
| `label` | DM Sans | 15–17 / 600–700 | Buttons, chips, list items |
| `body` | DM Sans | 14–15 / 400–500 | Secondary info |
| `overline` | DM Sans | 12 / 700, uppercase, letter-spacing 2 | Section labels ("In the kitchen · KOT #14") |
| `mono` | DM Mono | 13–14 / 400 | Invoice numbers, receipts |

## 5. Shape, spacing, depth

- **Spacing** on an 8-point scale: 4, 8, 12, 16, 20, 24, 28, 32, 40. Screen padding is 24–32 on desktop and 16 on phones.
- **Radius**: keys and small buttons 12; buttons and inputs 14–16; cards 20–22; big panels 24–28; pills 999.
- **Touch targets**: at least 44×44 on desktop and 48×48 dp on Android. Primary buttons are 56–68 tall.
- **Depth**: no grey drop shadows. A primary button gets a soft glow in its own colour (`0 10px 30px -10px saffron`). Cards are separated by tone (ember on espresso), not shadows. Keypad keys get a 3 px darker bottom inset so they read as pressable.
- **Lines**: 1 px `clayLine` dividers; a dashed divider separates "sent to kitchen" from "new" items.
- **Texture**: the table map floor uses a faint 22 px dot grid. A receipt preview is a paper card with scalloped top and bottom edges.

## 6. The plate illustration (signature element)

Every dish shows a plate drawn as layered circles. This replaces product photos and must be used for menu items everywhere.

- Outer rim: circle at radius 44 in `#F3E9DC`, with a soft dark shadow circle offset 3 px down at 35% opacity.
- Inner well: radius 36 in `#E6D8C4`.
- Food: radius 29 in the dish's **base** colour.
- Topping: radius 13, offset up and left, in the dish's **sauce** colour at 90% opacity.
- Garnish: 2–3 small dots (radius 3–5) in the dish's **garnish** colour.
- Shine: a white ellipse at 28% opacity, top left.

Each menu item stores three colours: `base`, `sauce`, `garnish`. Examples:

| Dish | Base | Sauce | Garnish |
| --- | --- | --- | --- |
| Butter Chicken | `#D9622B` | `#F2C27B` | `#4F8A3B` |
| Paneer Tikka | `#8A3B1F` | `#F5E3C3` | `#6FA14A` |
| Dal Makhani | `#6B2E1E` | `#E8D2A8` | `#3F7D3A` |
| Garlic Naan | `#E7C27D` | `#B9823A` | `#5E8F3E` |
| Biryani | `#D99A2B` | `#8B4A2B` | `#F2E4C2` |
| Mango Lassi | `#F2B33D` | `#F7D27A` | `#E07A2E` |
| Masala Chaas | `#EFE8D6` | `#CFE3C2` | `#6E9B4E` |
| Gulab Jamun | `#6E2A12` | `#9C4520` | `#E9C46A` |

For a new dish, pick the base colour from the dish itself, a contrasting sauce, and a green or contrasting garnish. Build it as one reusable `PlateIcon(base, sauce, garnish, size)` widget using `CustomPaint`. If the owner uploads a real photo, show it cropped into the same circle.

## 7. Components (build each once in `ui_kit`)

- **PrimaryButton**: saffron fill, dark text, 56–64 tall, radius 16, glow, optional trailing arrow icon.
- **SecondaryButton**: transparent with a 1.5 px `#4A3733` border, ghee text.
- **Success / Danger buttons**: cardamom and chili fills, for "Mark ready" and "Reverse item".
- **CategoryChip**: 44 tall pill. Selected: saffron fill. Unselected: ember fill with a clayLine border. Shows a count in a lighter weight.
- **DishCard**: ember gradient card, radius 22, with the plate at top left, veg/non-veg mark at top right, name in Fraunces, a one-line description in husk, price in bold, and an add button bottom right. Once added, the button turns saffron and shows the quantity.
- **VegMark**: a 16 px square with a 2 px border and a centred dot, green for veg and chili for non-veg (Indian convention). Always shown next to the dish name.
- **QtyStepper**: an emberRaised pill with − and + buttons (36–44 px) and a bold quantity between them.
- **TableTile**: rounded square (2–4 seats), long rectangle (6+ seats) or circle (2-tops); the table number in Fraunces 24/700. States:
  - Free: dashed clayLine outline and "N seats".
  - Ordering: saffron fill.
  - Served: cardamom fill.
  - Bill printed: chili fill.
  - Reserved: jamun fill with the time.
  - Occupied tiles also show the running total and minutes seated, and get a glow in their own colour.
- **StatusPill**: 36 tall, tinted fill, a dot and text. Used for hub online / offline / unreachable and sync counts. Always visible in the top bar.
- **OrderPanel**: a right-hand panel with these parts, top to bottom:
  - A header with "Table 12" in Fraunces 34, the guest count, and Transfer.
  - Meta chips for waiter, seated time and order number.
  - A "sent" group with a lock feel and muted text, then a dashed divider, then a "new" group with steppers.
  - A totals block with subtotal, CGST, SGST and round-off in husk, and "To pay" in saffron Fraunces 40.
  - Two buttons at the bottom: Send KOT (secondary) and Bill & pay (primary).
- **Keypad**: a 3×4 grid of 58 px keys in emberRaised with Fraunces digits, plus quick-amount chips ("Exact ₹770", "₹1,000", "₹2,000").
- **KitchenTicket**: a 6 px age bar on top (cardamom under 10 min, saffron 10–20, chili over 20), the table or takeaway name in Fraunces 26, and minutes as a large number in the age colour. Items show a ghee quantity badge, the name at 19 px, and notes in saffron italic. A full-width action button moves the ticket to the next column.
- **ReceiptPreview**: paper-coloured card in DM Mono, the restaurant name in wine Fraunces, dashed separators, the total in wine Fraunces 30, and scalloped edges.

## 8. Screen layouts

- **Cashier (Windows, 1366×768 and up)**: a left icon rail (88 px), the menu in the centre (category chips plus an auto-fill grid of DishCards at least 200 px wide), and the OrderPanel on the right (380–440 px). The top bar has a screen overline + title, search, a hub StatusPill and the user chip.
- **Table map**: a floor-tab segmented control, a legend, and the floor canvas with positioned TableTiles. A right panel shows "Needs you now" alerts and the takeaway queue.
- **Payment**: the receipt preview on the left. On the right:
  - "Still to collect" in big saffron, and the payments already made.
  - Mode tabs (Cash / UPI / Card).
  - The keypad or a UPI QR code.
  - Tip-to-waiter chips, change due in cardamom, and one large "Complete payment" button.
- **Waiter (Android phone)**: a sticky header (table, guests, waiter, minutes, hub pill), a "ready at the pass" banner, horizontally scrolling category pills, a list of dish rows with 52 px add buttons, and a fixed bottom bar "Send to kitchen · N items · ₹X" that glows when there is something to send.
- **Kitchen display**: three columns (New, Preparing, Ready to serve), a large clock, and an age legend. It must be readable from 2 metres: names at 19 px or more, quantities in solid badges.
- **Admin portal (light)**: a wineDeep sidebar with a saffron active item, a Fraunces 38 page title, KPI cards, filter chips, and a data table in a white card that scrolls sideways on small screens. Status and plan are shown as tinted chips.

## 9. Motion and feedback

- Durations are 120–180 ms with an ease-out curve. Nothing bounces.
- Adding a dish: the add button fills saffron, and the new line slides into the order panel with a brief saffron highlight that fades over 600 ms.
- Sending a KOT: the "new" group collapses into the "sent" group with a cardamom tick.
- A payment saved: a cardamom check draws in and the total counts down to ₹0.
- An offline change: the StatusPill turns saffron and shows "Offline · N changes waiting". Never block the cashier with a modal for this.
- Every async action shows its state on the button that started it (spinner, then tick). The button disables while pending, so double taps cannot double-charge.

## 10. Copy tone

- Short and human: "Tonight's menu", "The floor, right now", "Needs you now", "Still to collect", "Thank you. Come hungry again."
- Use ₹ with Indian digit grouping (₹1,670; ₹1,00,000). Show paise only on bills.
- Times use the 12-hour clock ("7:42 PM"). Durations are in minutes ("27 min").
- Error messages say what happened and what to do: "Table 4 is taken. Pick another table."

## 11. Accessibility checklist (every screen)

- Real buttons and inputs with labels; icon-only buttons have tooltips or semantic labels.
- Contrast is at least 4.5:1 for text and 3:1 for large numbers and UI borders.
- Status never relies on colour alone.
- Windows: full keyboard use (`/` for search, number keys on the keypad, Enter to confirm payment, Esc to close dialogs).
- Every screen has loading, empty and error states drawn in this style.

## 12. Don'ts

- No stock food photos, emoji, gradient washes across whole screens, or neon.
- No Inter or Roboto, and no pure black (`#000`) or pure white (`#FFF`) grounds.
- No more than one saffron primary per region, and no red-versus-green-only status.
- No tiny text on the kitchen display.
- No modal spinners that block service.

When you build a screen, first list which tokens and components from this file you will use, then build it. If something you need is missing, add it to `ui_kit` in this style rather than styling it inline.
