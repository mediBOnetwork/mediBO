import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'product.dart';
import '../data/medicine_repository.dart';
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

  /// Product ids with a `cart_set_item()` call in flight. Their steppers are
  /// disabled until the server answers (CHANGE #559 rule 5).
  final Set<String> _pending = {};

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
          callback: (_) => refresh(),
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

  /// Adopts a `cart_state()` payload as the displayed cart.
  ///
  /// `cart_state()` deliberately returns only what the cart screen renders, so
  /// two server-side lookups top it up — neither of which can invent a line:
  ///   * the auxiliary cart read supplies each row's `id` (stable add-order,
  ///     CHANGE #375), `added_by`, `category` and `gst_percent`, plus the
  ///     removed-by-admin section, which `cart_state()` filters out;
  ///   * MEDICINE supplies current `buyable` (CHANGE #401).
  /// Lines themselves are built from `cart_state().items` and nothing else.
  Future<void> _hydrateAndAdopt(Map<String, dynamic> cart, int gen) async {
    final items = (cart['items'] as List?) ?? const [];
    final ids = [
      for (final r in items) (r as Map)['product_id'].toString(),
    ];

    final aux = await _readAuxRows();
    final buyable = rpcTransport == null
        ? await MedicineRepository().fetchBuyableFlags(ids)
        : const <String, bool>{};
    if (gen != _loadGen) return;

    RenderLog.write('c401_cart_uses_buyable', 'true');
    _auxById = aux;
    _buyableById = buyable;
    _adoptCart(cart);
    _rebuildAdminRemoved(aux, buyable);
    RenderLog.write(kC559ServerCart,
        'items:${_serverLines.length};units:$totalUnits;total:$total');
  }

  Map<String, Map<String, dynamic>> _auxById = const {};
  Map<String, bool> _buyableById = const {};

  /// Reads the raw cart rows for metadata `cart_state()` does not return.
  /// Read-only — every WRITE goes through cart_set_item/cart_clear.
  Future<Map<String, Map<String, dynamic>>> _readAuxRows() async {
    try {
      final List rows = _viewAsUserId != null
          ? await _rpc('admin_preview_customer_cart',
              {'p_user_id': _viewAsUserId!}) as List
          : await _rpc('get_my_cart') as List;
      return {
        for (final r in rows)
          (r as Map)['product_id'].toString(): Map<String, dynamic>.from(r),
      };
    } catch (_) {
      return const {};
    }
  }

  /// Rebuilds `_serverLines` from the payload. Pure — no network, no mutation
  /// of the payload, and no line that is not in `cart['items']`.
  void _adoptCart(Map<String, dynamic> cart) {
    _cart = cart;
    final items = (cart['items'] as List?) ?? const [];
    final lines = <CartLine>[];
    for (final raw in items) {
      final row = raw as Map;
      final pid = row['product_id'].toString();
      final aux = _auxById[pid];
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
          category: (aux?['category'] as String?) ?? 'Other',
          // CHANGE #559: gst_percent is returned per line by cart_state().
          gstPercent: (row['gst_percent'] as num?)?.toDouble() ?? 12.0,
          buyable: _buyableById[pid],
        ),
        (row['quantity'] as num?)?.toInt() ?? 0,
        addedByAdmin: (aux?['added_by'] as String?) == 'admin',
        cartItemId: (aux?['id'] as num?)?.toInt(),
        display: disp,
      ));
    }
    // CHANGE #375: cart_state() orders by (updated_at, id), which moves a line
    // to the bottom on every qty edit. Re-sort by cart_items.id — stable
    // add-order — exactly as before. Lines with no aux row keep server order.
    final indexed = <int, CartLine>{};
    var maxId = 0;
    for (final l in lines) {
      if (l.cartItemId != null) maxId = maxId > l.cartItemId! ? maxId : l.cartItemId!;
    }
    var synthetic = maxId + 1;
    for (final l in lines) {
      indexed[l.cartItemId ?? synthetic++] = l;
    }
    final keys = indexed.keys.toList()..sort();
    _serverLines = [for (final k in keys) indexed[k]!];
    notifyListeners();
  }

  void _rebuildAdminRemoved(
      Map<String, Map<String, dynamic>> aux, Map<String, bool> buyable) {
    _adminRemovedLines.clear();
    for (final row in aux.values) {
      if ((row['removed_by_admin'] as bool?) != true) continue;
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
          buyable: buyable[pid],
        ),
        (row['quantity'] as num?)?.toInt() ?? 0,
        addedByAdmin: (row['added_by'] as String?) == 'admin',
        cartItemId: (row['id'] as num?)?.toInt(),
      ));
    }
    notifyListeners();
  }

  /// Loads this user's order history from public.orders and replaces _orders.
  Future<void> fetchOrders() async {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      final rows = await Supabase.instance.client
          .from('orders')
          .select()
          .eq('user_id', uid)
          .order('created_at', ascending: true);
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

  /// The single write path. Calls `cart_set_item` and renders the cart it
  /// returns. No optimistic update: nothing changes on screen until the
  /// server has answered.
  Future<void> _setItem(String productId, int quantity) async {
    if (_pending.contains(productId)) return;
    _pending.add(productId);
    notifyListeners();
    if (isViewAs) {
      RenderLog.write('c407_actingas_cart_write', 'customer_uid:$_viewAsUserId:not_admin');
      RenderLog.write(_c408ActingAsCart, 'write:set:customer_uid:$_viewAsUserId');
    }
    try {
      // A logged-out add needs a guest id to file the row under; mint one on
      // first write rather than for every idle visitor.
      final guest = _isSignedIn ? null : await _ensureGuestUid();
      final res = await _rpc('cart_set_item', {
        'p_product_id': productId,
        'p_quantity': quantity,
        'p_guest_uid': guest,
      });
      await _applyWriteResult(res);
    } catch (e) {
      cartError.value = 'Could not update the cart. Please try again.';
    } finally {
      _pending.remove(productId);
      notifyListeners();
    }
  }

  /// Adopts the `cart` a write RPC returned. On `ok:false` the server's own
  /// message is surfaced verbatim and the displayed quantity is left exactly
  /// as the server reports it.
  Future<void> _applyWriteResult(dynamic res) async {
    if (res is! Map) return;
    final m = Map<String, dynamic>.from(res);
    if (m['ok'] != true) {
      cartError.value = m['message']?.toString();
      RenderLog.write('c559_cart_write_rejected', '${m['message']}');
      // No cart came back — re-read so the display still matches the server.
      await refresh();
      return;
    }
    final cart = m['cart'];
    if (cart is Map) {
      await _hydrateAndAdopt(Map<String, dynamic>.from(cart), ++_loadGen);
    } else {
      await refresh();
    }
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

  /// True while this product has a cart write in flight — its stepper is
  /// disabled until the server answers (CHANGE #559 rule 5).
  bool isPending(String productId) => _pending.contains(productId);

  /// The quantity the SERVER last reported. There is no local quantity map.
  int quantityOf(String productId) {
    for (final l in _serverLines) {
      if (l.product.id == productId) return l.quantity;
    }
    return _sampleLines[productId]?.quantity ?? 0;
  }

  // ── Public API ────────────────────────────────────────────────────────────

  void add(Product product) {
    final current = quantityOf(product.id);
    _setItem(product.id, current > 0 ? current + 1 : 1);
  }

  void setQuantity(Product product, int qty) => _setItem(product.id, qty);

  /// Bulk-upload add. Awaits its write so cart_items.id assignment order
  /// matches the bulk-upload list order (CHANGE #413) rather than racing.
  Future<void> setBulkQuantity(Product product, int qty, int bulkOrder) async {
    RenderLog.write(kC413CartInsertionOrder,
        'insert:bulkOrder:$bulkOrder;product:${product.id}');
    await _setItem(product.id, qty);
  }

  void increment(Product product) =>
      _setItem(product.id, quantityOf(product.id) + 1);

  /// Decrement. Quantity 0 removes the line server-side.
  void decrement(Product product) =>
      _setItem(product.id, quantityOf(product.id) - 1);

  void remove(Product product) => _setItem(product.id, 0);

  void removeById(String productId) => _setItem(productId, 0);

  /// Hard-removes a row the admin had marked removed. Goes through
  /// cart_set_item like every other write — never a direct table delete.
  Future<void> hardDeleteRemovedItem(String productId) =>
      _setItem(productId, 0);

  Future<void> clear() async {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _sampleCountdown = 15;
    _sampleLines.clear();
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
    cartError.dispose();
    super.dispose();
  }
}
