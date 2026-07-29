# THE APP RENDERS. IT NEVER DECIDES. — conversion tracker

One file, kept current. Every screen either reads a backend RPC and renders it,
or it is on the remaining list below with the decision it still makes named
explicitly.

Rule: **if a value could have come from the backend, it MUST come from the
backend.** An existing file that violates this is a bug, not a precedent.

---

## Converted

### CHANGE #571 — session, routing, order gate, checkout

**The disagreement this removed.** `AuthNotifier` asked the backend the same
question three different ways on every sign-in, then answered it a fourth time
in Dart:

| Call | What Dart then re-derived |
|---|---|
| `get_my_role()` | `isAdmin = role == 'super_admin' \|\| role == 'admin'` |
| `claim_supplier_profile(email)` | `isSupplier`, `supplierStatus == 'pending_approval'` |
| direct `pharmacy_profiles` select **keyed on `user_id`** | `isRegistered`, `canOrder`, suspension |

Three sources, three chances to disagree. Meanwhile `my_session()` — which
already shipped `is_admin`, `is_supplier`, `surface` and
`is_registered_customer` — was consulted only by the Profile and Login screens.
That split is the direct cause of the admin-session-opens-customer-screen class
of bug, and of a registered customer reading as "Not Registered" after a Google
login (the profile row's `user_id` pointed at a different credential).

**Now:** one `my_session()` call. Every getter is a straight read.

Backend fields added to `my_session()`:

| Field | Replaces in Dart |
|---|---|
| `has_customer_account` | `role == 'customer' && ownerId.isNotEmpty` |
| `can_place_order` | `isRegistered && isApproved && status != 'suspended'` |
| `is_suspended` | `profile?.status == 'suspended'` |
| `is_pending_supplier`, `supplier_status` | the whole `claim_supplier_profile` round-trip |
| `needs_profile` | — |
| `surface` (+ `pending_supplier`) | `!isAdmin && isSupplier` ladder in `home_shell` |
| `order_gate{...}` | a 4-step gate ladder with **7 hardcoded strings**, duplicated in 3 files |
| `bulk_wa_gate{...}` | bulk-upload's own 4 hardcoded button labels |
| `pending_supplier_screen{...}` | `'Welcome, $name'`, approval message, `'Sign Out'` |
| `acting_as`, `acting_as_name` | 3 × `viewAs.identity?.name ?? 'Account'` branches |
| `status_label` via config | a 6-arm CASE, and a suspended account that read "Approved" |

New RPCs:

- **`place_order_v2()`** — takes **nothing**. The old path INSERTed straight
  into `orders` with the client supplying `price`, `mrp` and `line_total` per
  item, a client-computed net payable, an address joined from profile fields in
  Dart, and `user_id` (the *login*). A buyer could name their own price; orders
  keyed to a credential vanished when someone signed in another way. The RPC now
  reads the server-owned cart, prices and totals it, resolves the account's
  address, stamps `customer_id`, empties the cart, and returns a render-ready
  confirmation.
- **`save_customer_profile(jsonb)`** — registration no longer writes to
  `pharmacy_profiles` from Dart. Keys to the ACCOUNT (`my_customer_id()`);
  `auth.uid()` stamps only the very first row. Refuses client-supplied
  `approved`/`status`. Returns the fresh session.
- **`inr_money(numeric)`** — Indian lakh grouping, byte-identical to
  `util.dart rupees()`. Money is formatted server-side.
- **`my_session_status_label(...)`** — labels from `app_settings`.

Config rows (wording changes are now an UPDATE, never a deploy):
`order_gate_copy`, `bulk_wa_gate_copy`, `session_status_labels`,
`pending_supplier_screen`, `order_placed_copy`.

Files converted: `user_state.dart`, `models/app_session.dart`,
`models/account_registration.dart`, `screens/home_shell.dart`,
`screens/cart_screen.dart` (gate + checkout), `screens/bulk_upload_screen.dart`
(gate), `screens/admin/admin_shell.dart` (header),
`screens/auth/business_details_screen.dart` (save path).

**Verified with data, not assertion** — all via MCP against real accounts:

- 188 payload keys across 4 account states: **0 nulls**.
- admin → `surface=admin`, `/dashboard`, gate `staff_account`
- customer → `surface=customer`, `can_place_order=true`, gate `none`
- supplier → `surface=supplier`, `/supplier`, gate `supplier_account`
- signed out → `surface=public`, `/login`, gate `signed_out`
- suspended customer (rolled-back probe) → `can_place_order=false`, gate
  `suspended`, label `Suspended`
- pending supplier (rolled-back probe) → `surface=pending_supplier`,
  `supplier_status=pending_approval`
- View As (rolled-back probe) → `surface=customer`, name = impersonated
  account, `can_place_order` judged on the impersonated customer
- `place_order_v2` (rolled-back probe) → cart 200 + 49 fee = **249**; stored
  total **249.00**; `amount_display` `₹249.00`; `customer_id` stamped; cart
  emptied by the server; production left at 6 orders, `order_hours.is_open`
  still false.

Three defects were found **by running these probes**, not by reading the code:
a supplier told `needs_profile=true`; admin/supplier both given gate reason
`not_registered` (which would have told an admin to "Complete your pharmacy
registration"); and the gate judging the admin's own account under View As.

### CHANGE #572 — customer Orders screen

**What it decided in Dart, and no longer does:**

- fetched with `.eq('user_id', currentUser.id)` — the **LOGIN**. An account
  reachable by two login methods saw only the orders placed under one
  credential. This is the "orders vanished" report. (Confirmed live: one real
  email maps to two customer accounts in this database.)
- realtime subscribed on `user_id` too, so a change to the *other* login's
  order never triggered a refresh.
- capitalised status with `rawStatus[0].toUpperCase() + substring(1)`.
- `_StatusChip` switch-cased status into **both** a label and a colour.
- folded quantities for `itemCount`; measured `lines.length` for the avatar.
- fell back to `price * qty` when a stored `line_total` was missing.
- empty state written in Dart.

**Now:** `my_orders_screen(p_view_as_user)` — keyed to `customer_id`, rows
returned already sorted, counted, coloured and money-formatted.
`order_status_config` and `orders_screen_copy` make labels, chip colours and
empty-state copy data. `placed_at` stays a RAW timestamp so DateLabels/ist_fmt
keeps owning date strings (#548).

`p_view_as_user` is honoured **only for an admin caller**, so a customer cannot
read another account's orders by passing an id.

**Verified with data:**

- Migration safety checked first: all 6 orders already carry `customer_id`
  (`would_vanish = 0`), and a `BEFORE INSERT/UPDATE` trigger
  (`trg_stamp_customer_orders`) keeps it that way — structural, not luck.
- Real customer (Nitesh Pharmacy): 2 orders, `CPO260726NIT123O1`,
  `accepted` → label **Accepted**, colour **#22C55E**, total **₹11,497.29**,
  13 unique items / 47 units, first line **₹912.64**.
- Empty account: `count=0`, `has_orders=false`, empty copy present, 0 nulls.
- Copy relocated **verbatim** ("No purchase orders yet" / "Placed orders will
  appear here.") — no rewording smuggled in with the move.

---

## Remaining — with the decision each still makes

Counts are `grep` over `lib/**.dart` at the time of writing.

| # | Area | Decision still in Dart | Count |
|---|---|---|---|
| 1 | Orders — **admin side** | `admin_customer_screen` order views still read tables directly | — |
| 2 | Storefront / catalogue | client-side filtering + `rupees()` formatting | — |
| 3 | Inquiry + supplier orders | slot/role words (`role == 'none' \| 'no_supplier'`) in `inquiry_v11/v12.dart`, `admin_supplier_screen.dart` | 9 role branches |
| 4 | Fulfilment (collect/arrivals/warehouse/pack) | mostly backend already (`fw_*`); check stub fields | — |
| 5 | Suppliers / customers / payments / dashboard | 47 direct table **writes** still bypass an RPC | 47 |
| 6 | Everywhere | money/date formatted in Dart | 38 × `rupees()`, 60 × `toStringAsFixed`/`DateFormat` |
| 7 | Everywhere | direct table **reads** | 139 × `.from('...')` |

### Progress against baseline

| Metric | Before #571 | After #571 |
|---|---|---|
| Role branches on session role | 39 | **9** |
| Order-gate ladders in Dart | 3 (duplicated) | **0** |
| Hardcoded gate strings | 16 | **0** |
| Client-supplied order prices | yes | **no** |
| Order keyed to login (`user_id`) | yes | **no — `customer_id`** |
| RPC calls to resolve a session | 3 | **1** |
| Direct `.from()` | 143 | 139 |

`currentUser` went 29 → 30 deliberately: the one added use is the RULE 4
mismatch guard, which *must* compare the live credential against the
`auth_user_id` the backend resolved. Identifying a credential is what
`currentUser` is for; identifying an ACCOUNT is what it is never for.

### Not yet done — stated plainly

Items 1–7 above are untouched by #571. The 139 direct table reads and 47 direct
writes are real violations that still need an RPC each; they are listed rather
than quietly dropped.
