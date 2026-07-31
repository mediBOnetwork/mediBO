import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'product.dart';
import '../utils/order_code.dart';
import '../utils/render_log.dart';

/// A single line in the cart: a product plus the ordered quantity (packs).
class CartLine {
  final Product product;
  int quantity;
  final bool isSample;
  // Row index from the bulk-upload preview; null for manually browsed items.
  // Used to sort bulk items in upload order and restore position on re-sync.
  final int? bulkOrder;
  final bool addedByAdmin;
  final int? cartItemId;

  /// CHANGE #582 — display strings for this line, formatted by cart_render().
  /// Empty for sample/transient lines, which are never billed and never shown
  /// with a server price.
  final Map<String, dynamic> display;

  CartLine(this.product, this.quantity, {this.isSample = false, this.bulkOrder,
      this.addedByAdmin = false, this.cartItemId, this.display = const {}});

  /// One backend-formatted string for this line ('' when absent — never a
  /// locally formatted fallback).
  String ds(String key) => (display[key] ?? '').toString();

  double get lineTotal => product.b2bPrice * quantity;
  double get lineGst => lineTotal * product.gstPercent / 100;
}

/// A placed purchase order, kept in memory for the Orders screen.
class Order {
  final String number;
  /// CHANGE #548: RAW backend timestamp, or null until the server has
  /// stamped it. The client never guesses a placed-at time.
  final String? placedAt;
  final List<CartLine> lines;
  final double grandTotal;
  final double netPayable;
  String status;

  Order({
    required this.number,
    this.placedAt,
    required this.lines,
    required this.grandTotal,
    required this.netPayable,
    this.status = 'Pending',
  });

  int get itemCount => lines.fold(0, (sum, l) => sum + l.quantity);
}

/// CHANGE #559 — the cart lives in the backend. This class owns NO cart of its
/// own: it is a view over the last `cart_state()` payload plus the transient
/// sample-item overlay.
///
/// A DB audit trigger proved the old model never reached the database — items
/// were added to an in-memory map, the badge and delivery bar were computed in
/// Dart, and nothing was written. That is why the cart vanished on logout.
///
/// The rules now:
///   * `cart_state()` is the ONLY source of cart lines, quantities and totals.
///   * Every mutation goes through `cart_set_item()` / `cart_clear()`, which
///     each return the new cart; that response is adopted verbatim.
///   * There is no optimistic update and no local quantity map — the displayed
///     quantity is always the quantity the server last reported.
///   * No cart is persisted client-side. The ONLY thing stored locally is the
///     guest UUID — an identity token, not a cart — so a logged-out visitor's
///     server-side cart can be found again and claimed on login.
class CartModel extends ChangeNotifier {
  /// Test seam: the RPC transport. Production goes straight to Supabase; a
  /// widget test can substitute a recorder to assert which RPC was called with
  /// which arguments, and to feed back a cart payload.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> _rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  /// Stable per-browser guest id, passed as `p_guest_uid` to all three cart
  /// RPCs while `auth.uid()` is null. Not a cart — just who the server should
  /// file this anonymous cart under. Persisted with shared_preferences (never
  /// dart:html: DEFENSIVE IMPORT RULE).
  static const _guestUidKey = 'medibo_guest_uid';
  String? _guestUid;

  /// True when a real Supabase session exists. Safe before Supabase.initialize
  /// (and under the test transport), where it reports logged-out.
  bool get _isSignedIn {
    try {
      return Supabase.instance.client.auth.currentUser != null;
    } catch (_) {
      return false;
    }
  }

  /// Non-null only while logged out — the value to send as `p_guest_uid`.
  String? get _guestParam => _isSignedIn ? null : _guestUid;

  Future<String> _ensureGuestUid() async {
    final existing = _guestUid;
    if (existing != null) return existing;
    final prefs = await SharedPreferences.getInstance();
    var uid = prefs.getString(_guestUidKey);
    if (uid == null || uid.isEmpty) {
      uid = _generateUuid();
      await prefs.setString(_guestUidKey, uid);
    }
    _guestUid = uid;
    return uid;
  }

  Future<void> _loadGuestUid() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _guestUid = prefs.getString(_guestUidKey);
    } catch (_) {}
  }

  static String _generateUuid() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final h = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  /// The raw `cart_state()` payload — the single source of truth for the cart.
  Map<String, dynamic> _cart = const <String, dynamic>{};

  /// Cart lines, rebuilt from `_cart['items']` only. Never mutated locally.
  List<CartLine> _serverLines = const [];

  /// Transient sample items (bulk-upload demo). Never persisted, never part of
  /// the server cart — kept separate so a sample can never be mistaken for a
  /// real cart line.
  final Map<String, CartLine> _sampleLines = {};

  final List<CartLine> _adminRemovedLines = [];
  final List<Order> _orders = [];
  int _orderSeq = 1042;

  Timer? _sampleTimer;
  int _sampleCountdown = 15;

  /// Product ids with a `cart_set_item()` call in flight.
  final Set<String> _pending = {};

  // ── CHANGE #610 — stepper intent (debounce + last-write-wins) ─────────────
  //
  // What this is NOT: an optimistic cart. No total, badge, item/unit count,
  // tier, discount or delivery fee is ever derived from anything below. Those
  // stay exactly as the last SERVER payload reported until the next payload
  // lands — the app still never answers "what is the data?".
  //
  // What this IS: an echo of the user's own keystroke. `_localQty[p]` is the
  // number the user has tapped the stepper to and the server has not yet
  // acknowledged. It is displayed in that one stepper and nowhere else, and it
  // is dropped the moment the server answers (or the call fails), at which
  // point the server's number is on screen again.
  //
  // Why it exists: rapid taps used to be DISCARDED — `_setItem` returned early
  // while a write was in flight, so tapping + five times landed a quantity of
  // 1 or 2. Holding the user's intent locally is what lets every tap count
  // while still sending exactly one RPC for the burst.
  final Map<String, int> _localQty = {};

  /// Per-product debounce timers. A burst of taps sends ONE cart_set_item.
  final Map<String, Timer> _debounce = {};

  /// Products with a cart_set_item in flight, and the newest quantity that
  /// arrived while it was in flight (last write wins — never interleaved).
  final Set<String> _inFlight = {};
  final Map<String, int> _queued = {};

  static const Duration _kStepperDebounce = Duration(milliseconds: 300);

  /// When this client last committed a cart write. Used only to recognise the
  /// realtime echo of that write, which carries no information we do not
  /// already have — the write response WAS the new cart.
  DateTime? _lastSelfWriteAt;
  static const Duration _kSelfEchoWindow = Duration(seconds: 2);

  bool _isSelfInflicted() {
    if (_inFlight.isNotEmpty) return true;
    final t = _lastSelfWriteAt;
    return t != null && DateTime.now().difference(t) < _kSelfEchoWindow;
  }

  /// Drops every unsent tap. Called wherever account state is cleared: an
  /// intent recorded for the previous account must never be sent for the new
  /// one.
  void _clearLocalIntent() {
    for (final t in _debounce.values) {
      t.cancel();
    }
    _debounce.clear();
    _localQty.clear();
    _queued.clear();
  }

  /// Verbatim `message` from the last `ok:false` response, for the UI to show.
  /// The client never writes its own copy for a server-rejected cart change.
  final ValueNotifier<String?> cartError = ValueNotifier<String?>(null);

  StreamSubscription<AuthState>? _authSub;
  RealtimeChannel? _cartChannel;

  // ── View As mode ──────────────────────────────────────────────────────────
  // CHANGE #559: cart_state()/cart_set_item()/cart_clear() resolve the target
  // account themselves via viewer_cart_user() = coalesce(my_acting_as(),
  // auth.uid()), and cart_mode() is what writes admin_acting_as. So View As
  // needs no separate write path — but refreshCartMode() MUST be awaited
  // before any cart RPC, or the server would still be acting as nobody and
  // would read/write the ADMIN's own cart.
  String? _viewAsUserId;
  bool get isViewAs => _viewAsUserId != null;
  String? get viewAsUserId => _viewAsUserId;

  // ── CHANGE #454 — cart_mode(): the single source of truth for whether the
  // product-card action button is a real cart control or a read-only chip.
  // Fails OPEN (defaults true) so a stray cart button is the worst case, never
  // a missing one — a missing cart control would stop Om taking orders.
  bool showCart = true;
  String? cartModeBanner;

  Future<void> refreshCartMode() async {
    try {
      final res = await _rpc('cart_mode', {'p_acting_as': _viewAsUserId});
      final m = Map<String, dynamic>.from(res as Map);
      showCart = m['show_cart'] == true;
      cartModeBanner = m['banner']?.toString();
      RenderLog.write('c454_show_cart', showCart);
      RenderLog.write('c454_acting_as', _viewAsUserId != null ? 1 : 0);
      notifyListeners();
    } catch (_) {
      // FAIL OPEN — never default to false.
      showCart = true;
      notifyListeners();
    }
  }

  // c410_impersonation_persist: generation counter so an in-flight refresh
  // (e.g. the admin's own cart, kicked off at boot before ViewAs restoration
  // completes) can never overwrite a NEWER read's result just because its
  // (longer) request chain happens to resolve later.
  int _loadGen = 0;

  Future<void> enterViewAs(String userId) async {
    _viewAsUserId = userId;
    _adoptCart(const <String, dynamic>{}); // #556 rule 3 — clear before refetch
    _adminRemovedLines.clear();
    _clearLocalIntent();
    _cartChannel?.unsubscribe();
    _cartChannel = null;
    RenderLog.write('view_as_cart', 'enter:$userId');
    // MUST await: cart_mode() is what writes admin_acting_as server-side.
    await refreshCartMode();
    await refresh();
  }

  Future<void> exitViewAs() async {
    _viewAsUserId = null;
    _adoptCart(const <String, dynamic>{});
    _adminRemovedLines.clear();
    _clearLocalIntent();
    RenderLog.write('view_as_cart', 'exit');
    await refreshCartMode();
    await refresh();
  }

  CartModel() {
    _init();
  }

  /// Test-only constructor: skips the Supabase auth/realtime wiring so a widget
  /// test can drive the cart entirely through [rpcTransport].
  @visibleForTesting
  CartModel.forTest();

  void _init() {
    final client = Supabase.instance.client;
    _authSub = client.auth.onAuthStateChange.listen(_onAuthState);
    final uid = client.auth.currentUser?.id;
    if (uid != null) {
      // CHANGE #566 — a session recovered by Supabase.initialize is already the
      // account this boot's cart_state() will read, so the initialSession event
      // must not be mistaken for a fresh login and re-clear the cart.
      _authedUid = uid;
      _subscribeToCartRealtime(uid);
    }
    // Guest id must be known BEFORE the first cart_state(), or a logged-out
    // visitor's existing server cart would read back empty.
    _loadGuestUid().then((_) => refresh());
    // CHANGE #454 B1 — once per app/storefront boot (CartModel is the shared
    // singleton behind AppState, so this covers every screen).
    refreshCartMode();
  }

  /// CHANGE #566 — the account the displayed cart belongs to, and the in-flight
  /// adoption of it. Together they make the sign-in refetch idempotent, so the
  /// auth event and [syncSignedInCart] can race without fetching twice.
  String? _authedUid;
  Future<void>? _signInAdoption;

  Future<void> _onAuthState(AuthState state) async {
    final event = state.event;
    if (event == AuthChangeEvent.signedOut) {
      _authedUid = null;
      _signInAdoption = null;
      _cartChannel?.unsubscribe();
      _cartChannel = null;
      _viewAsUserId = null;
      _adoptCart(const <String, dynamic>{});
      _adminRemovedLines.clear();
      _clearLocalIntent();
      _orders.clear();
      notifyListeners();
      // Back to browsing as a guest — show whatever that guest cart holds.
      await _loadGuestUid();
      await refresh();
      return;
    }

    // CHANGE #566 — a sign-in is "the session's account is not the one on
    // screen", NOT the signedIn constant alone. `setSession(refreshToken)` —
    // the WhatsApp OTP path — resolves through the token-refresh branch of
    // gotrue and emits tokenRefreshed, so a signedIn-only test left the cart,
    // the badge, the "N items" pill and the delivery bar empty after a number
    // login until the cart screen was opened by hand. Testing the account
    // instead covers every login method, current and future, whichever event
    // constant the SDK happens to pick for it.
    final uid = Supabase.instance.client.auth.currentUser?.id;
    final isSignIn = event == AuthChangeEvent.signedIn || (uid != null && uid != _authedUid);
    if (!isSignIn) return;
    // An explicit signedIn always re-runs: signing in again as the same account
    // still has a guest cart to claim.
    await _syncSignedIn(uid, force: event == AuthChangeEvent.signedIn);
  }

  /// Runs — or joins — the one sign-in adoption for [uid].
  Future<void> _syncSignedIn(String? uid, {required bool force}) {
    final pending = _signInAdoption;
    if (!force && pending != null && uid == _authedUid) return pending;
    _authedUid = uid;
    final run = _adoptSignedInAccount(uid);
    _signInAdoption = run;
    return run;
  }

  Future<void> _adoptSignedInAccount(String? uid) async {
    // CHANGE #556 rule 3 + #559 rule 4 — clear the cart VIEW before refetch,
    // so no line from the previous account can survive an account switch.
    _adoptCart(const <String, dynamic>{});
    _adminRemovedLines.clear();
    _clearLocalIntent();
    if (uid != null) _subscribeToCartRealtime(uid);
    // CHANGE #559 + #556: hand the guest cart to the account BEFORE anything
    // reads it, so what the customer built while logged out survives login.
    await _claimGuestCart();
    await refreshCartMode(); // role may have just changed (e.g. admin login)
    await refresh();
  }

  /// CHANGE #566 — completes once `cart_state()` for the CURRENT session has
  /// been fetched and adopted, so the badge, the "N items" pill and the
  /// delivery bar are already right the moment the caller navigates. The login
  /// screen awaits this before pushing home_route. It is ordering, not a second
  /// source of truth: [_onAuthState] runs the very same work unprompted, and
  /// whichever gets there first is the one that runs.
  Future<void> syncSignedInCart() {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    // No session yet — never run the sign-in adoption (it would claim the guest
    // cart onto nobody). A plain re-read is the most that is correct here.
    if (uid == null) return refresh();
    return _syncSignedIn(uid, force: false);
  }

  void _subscribeToCartRealtime(String uid) {
    _cartChannel?.unsubscribe();
    final ts = DateTime.now().millisecondsSinceEpoch;
    _cartChannel = Supabase.instance.client
        .channel('customer_cart_${uid}_$ts')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'cart_items',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: uid,
          ),
          callback: (_) {
            // CHANGE #610 — our OWN cart_set_item already returned the new
            // cart, and adopting it is what put it on screen. The realtime
            // echo of that same write must not kick off a second full read:
            // that was a whole extra cart_render round trip per tap, arriving
            // after the tap had already been rendered.
            //
            // Only self-inflicted writes are skipped. A change made anywhere
            // else — another device, an admin edit — still refreshes, which is
            // the entire point of the subscription.
            if (_isSelfInflicted()) return;
            refresh();
          },
        )
        .subscribe();
  }

  // ── Reading the server cart ───────────────────────────────────────────────

  static const kC410ImpersonationPersist = 'c410_impersonation_persist';
  static const kC559ServerCart = 'c559_server_cart';

  /// CHANGE #553 — public re-read of the server cart, e.g. after
  /// `cart_strip_unavailable()` has deleted rows server-side.
  Future<void> reloadFromServer() => refresh();

  /// Re-reads `cart_state()`. This is the ONLY way cart lines ever appear.
  Future<void> refresh() async {
    final gen = ++_loadGen;
    RenderLog.write(kC410ImpersonationPersist, 'gen:$gen;viewAs:$_viewAsUserId');
    try {
      // CHANGE #582 — cart_render() is cart_state() plus a `render` block of
      // display strings and the per-GST-rate breakdown. Same keys as before,
      // so nothing that already read cart_state() changes behaviour; the
      // screen just stops formatting and computing tax itself.
      final res = await _rpc('cart_render', {'p_guest_uid': _guestParam});
      if (gen != _loadGen) return; // a newer read superseded this one
      if (res is! Map) return;
      await _hydrateAndAdopt(Map<String, dynamic>.from(res), gen);
      if (!isViewAs && rpcTransport == null) await fetchOrders();
    } catch (_) {}
  }

  /// Adopts a cart payload as the displayed cart. No network — the payload is
  /// already everything.
  ///
  /// CHANGE #610: this used to fire TWO more round trips before it could show
  /// anything — `get_my_cart` for each row's `id`/`added_by`/`category`, and
  /// `medicine_buyable_flags` for `buyable` — then merge the three results in
  /// Dart. Three sequential round trips for one tap, and a client-side merge
  /// of server data, which is exactly what the rule forbids. `cart_state()`
  /// now returns those fields itself, so there is one payload, and one payload
  /// cannot disagree with itself.
  Future<void> _hydrateAndAdopt(Map<String, dynamic> cart, int gen) async {
    if (gen != _loadGen) return;
    RenderLog.write('c401_cart_uses_buyable', 'true');
    RenderLog.write(kC610OnePayload, 'roundtrips:1');
    _adoptCart(cart);
    _rebuildAdminRemoved(cart);
    RenderLog.write(kC559ServerCart,
        'items:${_serverLines.length};units:$totalUnits;total:$total');
  }

  static const kC610OnePayload = 'c610_cart_one_payload';

  /// Rebuilds `_serverLines` from the payload. Pure — no network, no mutation
  /// of the payload, and no line that is not in `cart['items']`.
  void _adoptCart(Map<String, dynamic> cart) {
    _cart = cart;
    final items = (cart['items'] as List?) ?? const [];
    final lines = <CartLine>[];
    for (final raw in items) {
      final row = raw as Map;
      final pid = row['product_id'].toString();
      // #582 — carry the render strings cart_render() attached to this item.
      final disp = row.cast<String, dynamic>();
      lines.add(CartLine(
        Product.fromCartData(
          id: pid,
          name: (row['product_name'] as String?) ?? '',
          b2bPrice: (row['price'] as num?)?.toDouble() ?? 0.0,
          mrp: (row['mrp'] as num?)?.toDouble() ?? 0.0,
          imageUrl: (row['image_url'] as String?) ?? '',
          manufacturer: (row['manufacturer'] as String?) ?? '',
          packSize: (row['pack_size'] as String?) ?? '',
          // CHANGE #610: category, buyable, added_by and the row id all come
          // from the one payload now — no second read to merge them in.
          category: (row['category'] as String?) ?? 'Other',
          // CHANGE #559: gst_percent is returned per line by cart_state().
          gstPercent: (row['gst_percent'] as num?)?.toDouble() ?? 12.0,
          buyable: row['buyable'] as bool?,
        ),
        (row['quantity'] as num?)?.toInt() ?? 0,
        addedByAdmin: row['added_by_admin'] == true,
        cartItemId: (row['id'] as num?)?.toInt(),
        display: disp,
      ));
    }
    // CHANGE #375 / #610: stable add-order. cart_state() used to order by
    // (updated_at, id) — which moved a line to the bottom on every qty edit —
    // so the client re-sorted by cart_items.id in Dart. cart_state() now
    // orders by ci.id itself, so the order arrives correct and the client
    // stops sorting server data. Same visible order as before, decided once,
    // on the server.
    _serverLines = lines;
    notifyListeners();
  }

  /// CHANGE #610 — the removed-by-admin section comes from the payload's own
  /// `admin_removed` array. The client no longer decides which rows belong in
  /// it by filtering an auxiliary read.
  void _rebuildAdminRemoved(Map<String, dynamic> cart) {
    _adminRemovedLines.clear();
    for (final raw in (cart['admin_removed'] as List?) ?? const []) {
      final row = raw as Map;
      final pid = row['product_id'].toString();
      _adminRemovedLines.add(CartLine(
        Product.fromCartData(
          id: pid,
          name: (row['product_name'] as String?) ?? '',
          b2bPrice: (row['price'] as num?)?.toDouble() ?? 0.0,
          mrp: (row['mrp'] as num?)?.toDouble() ?? 0.0,
          imageUrl: (row['image_url'] as String?) ?? '',
          manufacturer: (row['manufacturer'] as String?) ?? '',
          packSize: (row['pack_size'] as String?) ?? '',
          category: (row['category'] as String?) ?? 'Other',
          gstPercent: (row['gst_percent'] as num?)?.toDouble() ?? 12.0,
          buyable: row['buyable'] as bool?,
        ),
        (row['quantity'] as num?)?.toInt() ?? 0,
        addedByAdmin: row['added_by_admin'] == true,
        cartItemId: (row['id'] as num?)?.toInt(),
      ));
    }
    notifyListeners();
  }

  /// Loads this user's order history from public.orders and replaces _orders.
  Future<void> fetchOrders() async {
    try {
      // CHANGE #595 — keyed to the ACCOUNT, not the login. Reading orders by
      // user_id is the "orders vanished" bug: a second login saw none of them.
      final raw = await Supabase.instance.client.rpc('my_orders_raw');
      final rows = (((raw is List ? raw.first : raw) as Map)['rows']
          as List<dynamic>? ?? const []);
      final loaded = <Order>[];
      for (final row in rows) {
        final items = (row['items'] as List<dynamic>?) ?? [];
        final lines = <CartLine>[];
        for (int i = 0; i < items.length; i++) {
          final item = items[i] as Map<String, dynamic>;
          final product = Product.fromCartData(
            id: 'order_item_$i',
            name: (item['product_name'] as String?) ?? '',
            b2bPrice: (item['price'] as num?)?.toDouble() ?? 0.0,
            mrp: (item['mrp'] as num?)?.toDouble() ?? 0.0,
            gstPercent: (item['gst_percent'] as num?)?.toDouble() ?? 12.0,
          );
          lines.add(CartLine(product, (item['quantity'] as num?)?.toInt() ?? 1));
        }
        final total = (row['total_amount'] as num?)?.toDouble() ?? 0.0;
        final rawStatus = (row['status'] as String?) ?? 'pending';
        final status = rawStatus[0].toUpperCase() + rawStatus.substring(1);
        loaded.add(Order(
          number: orderDisplayId(row),
          placedAt: row['created_at']?.toString(),
          lines: lines,
          grandTotal: total,
          netPayable: total,
          status: status,
        ));
      }
      _orders
        ..clear()
        ..addAll(loaded);
      notifyListeners();
    } catch (_) {}
  }

  // ── Mutations — cart_set_item / cart_clear only ───────────────────────────

  // #407/#408: every cart write funnels through _setItem. It cannot write to
  // the wrong account: cart_set_item resolves the target itself from
  // admin_acting_as, which cart_mode() set when View As was entered.
  static const _c408ActingAsCart = 'c408_actingas_cart';

  /// CHANGE #610 — the STEPPER write path: record the tap, show it in that
  /// stepper, and send one `cart_set_item` once the taps stop.
  ///
  /// The old path returned early while a write was in flight, so every tap
  /// after the first in a burst was silently thrown away. Now each tap updates
  /// the user's own intent immediately and restarts a 300ms timer; the burst
  /// costs exactly one RPC carrying the final quantity.
  void _requestQty(String productId, int quantity) {
    final q = quantity < 0 ? 0 : quantity;
    _localQty[productId] = q;
    notifyListeners(); // the tap is on screen in this frame
    _debounce.remove(productId)?.cancel();
    _debounce[productId] = Timer(_kStepperDebounce, () => _flush(productId));
  }

  /// Sends the settled quantity — or parks it behind the call already running.
  void _flush(String productId) {
    _debounce.remove(productId)?.cancel();
    final q = _localQty[productId];
    if (q == null) return;
    if (_inFlight.contains(productId)) {
      // Last write wins. Never two cart_set_item calls for one product in
      // flight at once — that is how a stale response overwrites a fresh one.
      _queued[productId] = q;
      return;
    }
    unawaited(_setItem(productId, q));
  }

  /// The single write path. Calls `cart_set_item` and renders the cart it
  /// returns — the response IS the new cart, so nothing is re-read afterwards.
  ///
  /// On failure the local echo is dropped, which puts the server's own number
  /// back on screen. That is the whole rollback: `_serverLines`, the totals,
  /// the badge and the tier were never touched, so there is nothing to undo.
  Future<void> _setItem(String productId, int quantity) async {
    _inFlight.add(productId);
    _pending.add(productId);
    notifyListeners();
    if (isViewAs) {
      RenderLog.write('c407_actingas_cart_write', 'customer_uid:$_viewAsUserId:not_admin');
      RenderLog.write(_c408ActingAsCart, 'write:set:customer_uid:$_viewAsUserId');
    }
    var accepted = false;
    try {
      // A logged-out add needs a guest id to file the row under; mint one on
      // first write rather than for every idle visitor.
      final guest = _isSignedIn ? null : await _ensureGuestUid();
      final res = await _rpc('cart_set_item', {
        'p_product_id': productId,
        'p_quantity': quantity,
        'p_guest_uid': guest,
      });
      _lastSelfWriteAt = DateTime.now();
      accepted = await _applyWriteResult(res);
    } catch (e) {
      // Network threw — the server may never have seen this at all.
      cartError.value = 'Could not update the cart. Please try again.';
    } finally {
      _inFlight.remove(productId);
      _pending.remove(productId);
      final next = _queued.remove(productId);
      if (next != null && next != quantity) {
        // More taps landed while this was in flight — send only the latest.
        unawaited(_setItem(productId, next));
      } else if (!accepted || _localQty[productId] == quantity) {
        // Either the server rejected/never answered (roll back to its number),
        // or it acknowledged exactly what is echoed (the echo is now redundant
        // — the payload already says the same thing). Both mean: stop echoing.
        _localQty.remove(productId);
      }
      notifyListeners();
    }
  }

  /// Adopts the `cart` a write RPC returned. On `ok:false` the server's own
  /// message is surfaced verbatim and the displayed quantity is left exactly
  /// as the server reports it.
  /// Returns true when the server accepted the write and its cart is now on
  /// screen; false when it rejected the write or sent no cart, in which case
  /// the caller drops its local echo.
  Future<bool> _applyWriteResult(dynamic res) async {
    if (res is! Map) return false;
    final m = Map<String, dynamic>.from(res);
    if (m['ok'] != true) {
      cartError.value = m['message']?.toString();
      RenderLog.write('c559_cart_write_rejected', '${m['message']}');
      // No cart came back — re-read so the display still matches the server.
      await refresh();
      return false;
    }
    final cart = m['cart'];
    if (cart is Map) {
      // CHANGE #610 — this response is the complete, render-ready cart
      // (cart_render output: items with their display strings, badge, counts,
      // totals, tier). Adopting it is the last thing that happens on a tap;
      // there is no follow-up read.
      await _hydrateAndAdopt(Map<String, dynamic>.from(cart), ++_loadGen);
      return true;
    }
    await refresh();
    return false;
  }

  /// CHANGE #559 rule 2 / #556: move the logged-out cart onto the account that
  /// just signed in. Runs before my_session()-driven navigation reads the cart.
  Future<void> _claimGuestCart() async {
    final guest = _guestUid;
    if (guest == null) return;
    try {
      final res = await _rpc('claim_guest_cart', {'p_guest_uid': guest});
      final moved = (res is Map) ? (res['moved'] as num?)?.toInt() ?? 0 : 0;
      RenderLog.write('c559_guest_cart_claimed', 'moved:$moved');
    } catch (_) {}
    // The guest id has served its purpose; a stale one must never be sent
    // again or a later logout would resurrect an already-claimed cart.
    _guestUid = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_guestUidKey);
    } catch (_) {}
  }

  // ── Computed getters ──────────────────────────────────────────────────────

  // CHANGE #559: the cart list is exactly what cart_state() returned, plus the
  // transient sample overlay. Nothing is added, removed or reordered locally
  // beyond the CHANGE #375 add-order sort applied in _adoptCart.
  static const kC412CartSortById = 'c411_cart_sort_by_id';
  static const kC413CartInsertionOrder = 'c413_cart_insertion_order';
  static const kC422CartBackendOrder = 'c422_cart_backend_order';

  List<CartLine> get lines {
    final out = [..._serverLines, ..._sampleLines.values];
    RenderLog.write(kC412CartSortById, 'lines:${out.length}');
    RenderLog.write(kC413CartInsertionOrder, 'lines:${out.length}');
    RenderLog.write(kC422CartBackendOrder, 'lines:${out.length}');
    return out;
  }

  List<CartLine> get adminRemovedLines => List.unmodifiable(_adminRemovedLines);
  List<Order> get orders => List.unmodifiable(_orders.reversed);

  // ── Server-rendered display strings (CHANGE #559 rule 3) ──────────────────
  // Never computed or formatted in Dart.
  String? get badge => _cart['badge']?.toString();
  String? get header => _cart['header']?.toString();
  String? get ctaLabel => _cart['cta_label']?.toString();
  String get emptyTitle => _cart['empty_title']?.toString() ?? '';
  String get emptyNote => _cart['empty_note']?.toString() ?? '';
  // ── Discount-tier ladder (CHANGE #559) ────────────────────────────────────
  // The five tiers, which tier is current, which is next, how far away it is
  // and the progress toward it are ALL decided by cart_state() from
  // app_settings.cart_tiers. No threshold or percentage is hardcoded in Dart.

  /// The tier reached, or null below the first one. Keys: label, min_mrp,
  /// discount_pct, free_delivery.
  Map<String, dynamic>? get tierCurrent => _asMap(_cart['tier_current']);

  /// The next tier up, or null once the top tier is reached.
  Map<String, dynamic>? get tierNext => _asMap(_cart['tier_next']);

  /// Label of the tier reached, e.g. "FREE delivery", "3% off".
  String? get tierLabel => _cart['tier_label']?.toString();

  /// Label of the next tier up, e.g. "3% off".
  String? get tierNextLabel => tierNext?['label']?.toString();

  /// Discount percent the next tier unlocks.
  int get tierNextPct => (tierNext?['discount_pct'] as num?)?.toInt() ?? 0;

  /// Rupees of MRP still needed to reach the next tier.
  double get tierGap => (_cart['tier_gap'] as num?)?.toDouble() ?? 0.0;

  /// Progress across the CURRENT tier band, 0..1. Already 1 at the top tier.
  double get tierProgress =>
      (_cart['tier_progress'] as num?)?.toDouble() ?? 0.0;

  /// One-line tier sentence, e.g. "Add ₹727.24 more for 3% off".
  String? get tierNote => _cart['tier_note']?.toString();

  /// True once the top tier is reached — nothing further to unlock.
  bool get tierMaxed => tierNext == null && tierCurrent != null;

  // ── Money, all computed server-side ───────────────────────────────────────
  double get discountPct => (_cart['discount_pct'] as num?)?.toDouble() ?? 0.0;
  double get discountAmount =>
      (_cart['discount_amount'] as num?)?.toDouble() ?? 0.0;
  double get deliveryFee => (_cart['delivery_fee'] as num?)?.toDouble() ?? 0.0;

  static Map<String, dynamic>? _asMap(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : null;

  /// Distinct products, straight from the server. Sample items are transient
  /// and counted alongside so the badge matches what the list shows.
  int get distinctItems =>
      ((_cart['item_count'] as num?)?.toInt() ?? 0) + _sampleLines.length;

  int get totalUnits =>
      ((_cart['unit_count'] as num?)?.toInt() ?? 0) +
      _sampleLines.values.fold(0, (s, l) => s + l.quantity);

  /// Cart value as the server computed it.
  double get total => (_cart['total'] as num?)?.toDouble() ?? 0.0;

  double get subtotal =>
      total + _sampleLines.values.fold(0.0, (s, l) => s + l.lineTotal);

  /// CHANGE #582 — the `render` block from cart_render(): display strings and
  /// the per-GST-rate breakdown, all computed server-side.
  Map<String, dynamic> get render =>
      (_cart['render'] as Map?)?.cast<String, dynamic>() ?? const {};

  /// One display string from the render block. Missing reads as '' — never a
  /// locally formatted fallback, which would be the app deciding again.
  String rs(String key) => (render[key] ?? '').toString();

  /// A label from the backend's own label set (Net Total, Delivery, GST, …).
  String label(String key) =>
      ((render['labels'] as Map?)?[key] ?? '').toString();

  /// The per-rate GST groups the tax panel draws, already totalled and worded.
  List<Map<String, dynamic>> get gstGroups =>
      ((render['gst_groups'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList(growable: false);

  /// #582 — GST and the grand total come from the server. These used to be
  /// folded from the lines in Dart while the tax panel derived GST a SECOND
  /// way (netPayable − deliveryFee − mrpTotal × (1 − disc)); two calculations
  /// of one number in a single screen.
  double get totalGst => (render['gst_total'] as num?)?.toDouble() ?? 0.0;
  double get grandTotal => (render['grand_total'] as num?)?.toDouble() ?? 0.0;

  /// Total MRP as the SERVER computed it. Drives the tier ladder.
  double get mrpTotal =>
      ((_cart['mrp_total'] as num?)?.toDouble() ?? 0.0) +
      _sampleLines.values.fold(0.0, (s, l) => s + l.product.mrp * l.quantity);

  /// Net payable, straight from cart_state() — discount and delivery fee are
  /// applied server-side. Sample items are transient and never billed, so the
  /// server figure stands alone.
  double get netPayable => (_cart['net_payable'] as num?)?.toDouble() ?? 0.0;

  bool get hasSampleItems => _sampleLines.isNotEmpty;
  int get sampleCountdown => _sampleCountdown;

  /// True while this product has a cart write in flight AND the user has no
  /// newer tap of their own waiting.
  ///
  /// CHANGE #610: the steppers disable themselves on this. While a burst of
  /// taps is being debounced the user always has an unsent tap outstanding, so
  /// this reads false and every further tap is accepted — which is the fix for
  /// taps being dropped mid-burst (CHANGE #559 rule 5 disabled the control on
  /// the first tap and ate the rest). A write with no local intent behind it —
  /// a bulk-upload row, a swipe-to-remove — still reports pending exactly as
  /// before.
  bool isPending(String productId) =>
      _pending.contains(productId) && !_localQty.containsKey(productId);

  /// The quantity to display for this product.
  ///
  /// The server's number, unless the user has tapped the stepper since and the
  /// server has not answered yet — then it is the user's own unsent tap
  /// (CHANGE #610). Nothing else is derived from it: every count, total, tier
  /// and label still comes from the last server payload.
  int quantityOf(String productId) {
    final tapped = _localQty[productId];
    if (tapped != null) return tapped;
    for (final l in _serverLines) {
      if (l.product.id == productId) return l.quantity;
    }
    return _sampleLines[productId]?.quantity ?? 0;
  }

  // ── Public API ────────────────────────────────────────────────────────────

  // CHANGE #610 — the four stepper actions are debounced (one RPC per burst);
  // everything else writes straight away, because none of it can burst.

  void add(Product product) {
    final current = quantityOf(product.id);
    _requestQty(product.id, current > 0 ? current + 1 : 1);
  }

  void setQuantity(Product product, int qty) => _requestQty(product.id, qty);

  void increment(Product product) =>
      _requestQty(product.id, quantityOf(product.id) + 1);

  /// Decrement. Quantity 0 removes the line server-side.
  void decrement(Product product) =>
      _requestQty(product.id, quantityOf(product.id) - 1);

  /// Bulk-upload add. Awaits its write so cart_items.id assignment order
  /// matches the bulk-upload list order (CHANGE #413) rather than racing.
  /// Never debounced: the ordering guarantee IS the sequential await.
  Future<void> setBulkQuantity(Product product, int qty, int bulkOrder) async {
    RenderLog.write(kC413CartInsertionOrder,
        'insert:bulkOrder:$bulkOrder;product:${product.id}');
    _dropLocalIntentFor(product.id);
    await _setItem(product.id, qty);
  }

  void remove(Product product) => _removeNow(product.id);

  void removeById(String productId) => _removeNow(productId);

  /// Hard-removes a row the admin had marked removed. Goes through
  /// cart_set_item like every other write — never a direct table delete.
  Future<void> hardDeleteRemovedItem(String productId) {
    _dropLocalIntentFor(productId);
    return _setItem(productId, 0);
  }

  /// A removal cancels any unsent stepper taps for that product — the row is
  /// going away, so the last tap on it is moot — and then goes out through the
  /// same last-write-wins gate, so it can never race a stepper call already in
  /// flight for the same product.
  void _removeNow(String productId) {
    _debounce.remove(productId)?.cancel();
    _localQty[productId] = 0;
    _flush(productId);
    notifyListeners();
  }

  void _dropLocalIntentFor(String productId) {
    _debounce.remove(productId)?.cancel();
    _localQty.remove(productId);
    _queued.remove(productId);
  }

  Future<void> clear() async {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _sampleCountdown = 15;
    _sampleLines.clear();
    _clearLocalIntent(); // #610 — the whole cart is going; unsent taps are moot
    try {
      final res = await _rpc('cart_clear', {'p_guest_uid': _guestParam});
      await _applyWriteResult(res);
    } catch (_) {
      await refresh();
    }
  }

  void addSampleItems(List<MapEntry<Product, int>> items) {
    for (final entry in items) {
      _sampleLines[entry.key.id] =
          CartLine(entry.key, entry.value, isSample: true);
    }
    _startSampleTimer();
    notifyListeners();
    // Sample items are transient — never written to the backend cart.
  }

  void clearSampleItems() {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _sampleCountdown = 15;
    _sampleLines.clear();
    notifyListeners();
  }

  void _startSampleTimer() {
    _sampleTimer?.cancel();
    _sampleCountdown = 15;
    _sampleTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _sampleCountdown--;
      if (_sampleCountdown <= 0) {
        clearSampleItems();
      } else {
        notifyListeners();
      }
    });
  }

  Order checkout() {
    if (isViewAs) throw StateError('checkout blocked in ViewAs mode');
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _sampleCountdown = 15;
    final orderLines =
        lines.map((l) => CartLine(l.product, l.quantity)).toList();
    // Snapshot the SERVER's figures before cart_clear() empties them.
    final order = Order(
      number: orderDisplayId({'id': 'seq${_orderSeq++}'}),
      // CHANGE #548: the SERVER stamps placed-at on echo. No client guess.
      placedAt: null,
      lines: orderLines,
      grandTotal: grandTotal,
      netPayable: netPayable,
    );
    _orders.add(order);
    _sampleLines.clear();
    clear();
    return order;
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _cartChannel?.unsubscribe();
    _sampleTimer?.cancel();
    _clearLocalIntent(); // #610 — no debounce timer outlives the model
    cartError.dispose();
    super.dispose();
  }
}
