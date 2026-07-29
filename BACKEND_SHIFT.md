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

### CHANGE #574 — supplier Inquiry tab

**What it decided in Dart, and no longer does:**

- made **two** calls (`supplier_inquiry_buckets` + one of two receipt RPCs,
  chosen by which identity was in hand) and reconciled them here.
- grouped rows itself: three × `list.where((r) => r['state'] == '...')`.
- picked the auto-open group with a Pending > Inquired > Expired ladder.
- inferred status as `list.isEmpty ? 'draft' : 'pending'` — the old code
  comment said outright that this was *"inferred client-side"*.

**Now:** `supplier_inquiry_screen(p_supplier_id, p_preview)` returns
`pending` / `inquired` / `expired` / `receipt`, plus `counts`, `badge`,
`auto_open`, `status` and `has_items` — one payload that cannot disagree with
itself. The identity guard inside `supplier_inquiry_buckets` still applies:
passing `p_supplier_id` requires admin, and the wrapper is
`SECURITY DEFINER` but the guard reads `get_my_role()` from the real caller,
so it cannot be bypassed.

**`inquiry_item_flags()` — one rule, one place.** "Does this line have a
supplier?" was written three times in Dart from two raw fields, and the three
copies had **already drifted**: `inquiry_v11`/`inquiry_v12` used `slot == 0`
while `admin_supplier_screen` used `slot <= 0`. `<= 0` is correct (a missing
slot parses to `-1` in the widgets' own default), so that is the rule kept.
The helper also returns `is_locked`, `answerable`, and the role badge
(label + both colours) that Dart derived from `role == 'current'`.

**Verified with data** (rolled-back probe: the one draft inquiry form flipped
to pending, then rolled back):

- supplier **BHARAT SALES**, total 1, `status=pending`, `auto_open=pending`,
  `badge=1`, `counts={pending:1, inquired:0, expired:0}`
- row flags: `no_supplier=false`, `badge_label=Current`, `answerable=true`
- empty supplier + admin View As paths: 0 nulls, `status=draft`, `auto_open=''`
- `inquiry_item_flags` across 6 cases incl. slot 0, slot -1, role none, answered
- **`has_mrp`** added after the probe showed a null MRP rendering as `₹0.00` —
  the same false-zero the storefront had. Absence is now explicit.
- Production untouched: form back to `draft`, 0 pending forms, all probe
  functions dropped (`NONE LEFT`).

**Deliberately NOT done in this change:** `inquiry_v12` is shared by three
surfaces (public inquiry form, supplier tab, admin), and only the supplier
tab's data source now emits `flags`. Converting the shared widget's
`_noSupplier` before `inquiry_buckets_today`, `get_supplier_inquiry_items` and
`get_inquiry_form` also emit flags would break the other two surfaces, so the
widget still derives. That is the next step, listed below.

### CHANGE #575 — the inquiry no-supplier rule, everywhere

`inquiry_v12` is shared by **three** surfaces (public inquiry form, supplier
tab, admin), which is why #574 stopped short of converting it. All three
sources now emit the `flags` block, so the widget reads instead of derives:

| Source | Change |
|---|---|
| `supplier_inquiry_screen()` | emitted `flags` in #574 |
| `get_inquiry_form(token)` | now emits `flags` (+ `slot_index` alias) |
| `get_supplier_inquiry_items_v2(name)` | new jsonb wrapper carrying `flags` + `has_mrp` |

The public form emitted `slot` (not `slot_index`) and no `role` at all, so
`_noSupplier` read `slot_index` → absent → `-1` → `false`. It had been getting
the right answer **by accident**.

Converted: `inquiry_v12._noSupplier` / `._isLocked` now read `flags`;
`admin_supplier_screen` reads `flags.is_current` / `flags.no_supplier` and
fetches from the v2 wrapper. Three now-dead locals removed (`role` ×2,
`slotIndex`), one of which was already dead before this change.

**`lib/widgets/inquiry_v11.dart` deleted** — nothing imported it and
`InquiryV11List` had zero references. It carried its own stale copy of the
no-supplier rule, so leaving it would have left a fourth version to drift.

**Verified:** both `get_inquiry_form` and `get_supplier_inquiry_items_v2`
return *identical* flags for the same real row (BHARAT SALES):
`no_supplier=false`, `is_current=true`, `badge_label=Current`,
`answerable=true`, `is_locked=false`. Rolled-back probe; production left with
the form back at `draft`, 0 pending, no probe functions.

### Role branches: 39 → 4, and none of the 4 is a session-role branch

```
main.dart:280                  if (role == null || identity == null)   // ViewAs null-check
view_as_state.dart:29          isActive => _role != null              // dev-tool state
inquiry_v12.dart:212,214       if (surf == 'admin') RenderLog.write(…) // diagnostics only
business_details_screen.dart   _role == r                             // local form selector
```

None of these branches on `my_session().role` to decide what the user may see
or do. The registration form's `_role` is the applicant's own radio selection
— user input, not an account fact.

### CHANGE #576 — supplier lifecycle (approve / reject / delete / restore)

Four admin actions wrote **straight into `supplier_profiles`** from Dart. Each
carried its own bug class:

| Problem | Detail |
|---|---|
| Status words in Dart | `'Active'`, `'Suspended'`, `'rejected'` spelled client-side |
| **Device clock** | `approved_at`/`deleted_at` came from `DateTime.now()` — a skewed laptop stamps a wrong time nothing can correct afterwards |
| **Identity** | `approved_by: 'admin'` was a hardcoded *literal*, not a person; `deleted_by` used `auth.currentUser.email` — a CREDENTIAL, not an account — with a Dart fallback of `'admin'` |
| **Authorization** | left entirely to RLS: "only an admin may approve a supplier" was stated nowhere in the database |
| Client snapshot | `deleted_snapshot: row.rawData` — whatever the client happened to hold |

**Now:** `admin_supplier_action(p_supplier_id, p_action)` — server clock, server
identity, an explicit `get_my_role()` check, and the snapshot taken from the
row itself. Status words moved to `app_settings.supplier_status_values`.

Three dead methods removed (`_suspendSupplier`, `_reactivateSupplier`,
`_updateOrderStatus`) — each still contained a direct table write, waiting to
be wired up again.

**Verified** (rolled-back probe, every action):

- **a customer calling `approve` is refused: `forbidden`** — the check now
  lives in the database, not in RLS alone
- suspend → `Suspended`; reactivate → `Active`; delete → `is_deleted=true`;
  restore → `is_deleted=false`; approve → `approved=true`
- `approved_at` = **2026-07-29 10:44:37+00**, within 1 minute of server `now()`
- `approved_by` = **test.admin@medibo.in** — the real admin, not `'admin'`
- `deleted_snapshot` taken server-side
- production untouched: `approved_by` back to NULL, `is_deleted` false

Direct table writes: **47 → 41** repo-wide (this file 24 → 18).

### CHANGE #577 — admin cart writes (the violation CLAUDE.md names by name)

`.from('cart_items')` is called out explicitly in CLAUDE.md. Two admin paths
still did it:

**Add item** — SELECTed then INSERTed/UPDATEd `cart_items` directly:

| Problem | Detail |
|---|---|
| **Login keying** | `.eq('user_id', widget.userId)` — the cart-vanishing bug |
| **App merges quantity** | `newQty = wasRemoved ? qty : existing.quantity + qty` |
| **App sets the PRICE** | `'price': mrp, 'mrp': mrp` — the client decided what to charge |
| Invented defaults | `gst_percent ?? 12`, `category ?? 'Other'` |
| Device clock | `updated_at: DateTime.now()` |
| Identity | `added_by: 'admin'` — a literal, not a person |

`admin_writeas_cart_upsert()` already existed but still took `price`, `mrp`,
`category` and `gst` **from the client** — the same violation moved into a
function signature. `admin_cart_add(customer_id, product_id, qty)` takes only
WHO / WHAT / HOW MANY; everything else is read from `MEDICINE` server-side.
It accepts either an account id or an auth user id and resolves one to the
other, because that is a backend question, not the caller's.

**Soft-remove** — `removed_at` from the device clock, admin check nowhere but
RLS. Now `admin_cart_remove_item(item_id)`.

**Verified** (rolled-back probes):

- **a customer calling either RPC is refused: `forbidden`**
- add 2, then add 3 → quantity **5** (merge decided server-side)
- price **131.25** read from the catalogue, GST 12 from `MEDICINE`
- `added_by` = **test.admin@medibo.in**, `customer_id` stamped, server clock
- passing an **auth user id** resolves to the right account
  (`customer_id_matches: true`)
- production untouched: 0 test rows, 44 cart rows unchanged

**Zero `.from('cart_items')` writes remain.** Direct table writes: **47 → 39**.

---

## Remaining — with the decision each still makes

Counts are `grep` over `lib/**.dart` at the time of writing.

| # | Area | Decision still in Dart | Count |
|---|---|---|---|
| 1 | Orders — **admin side** | `admin_customer_screen` order views still read tables directly | — |
| 2 | Storefront / catalogue | client-side filtering + `rupees()` formatting | — |
| 3 | Inquiry | ~~shared widget derives no_supplier~~ **done in #575** | 0 |
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
