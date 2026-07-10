import 'dart:async';
import 'dart:convert';
import 'dart:math';

// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'product.dart';
import '../data/medicine_repository.dart';
import '../util.dart';
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

  CartLine(this.product, this.quantity, {this.isSample = false, this.bulkOrder, this.addedByAdmin = false, this.cartItemId});

  double get lineTotal => product.b2bPrice * quantity;
  double get lineGst => lineTotal * product.gstPercent / 100;
}

/// A placed purchase order, kept in memory for the Orders screen.
class Order {
  final String number;
  final DateTime placedAt;
  final List<CartLine> lines;
  final double grandTotal;
  final double netPayable;
  String status;

  Order({
    required this.number,
    required this.placedAt,
    required this.lines,
    required this.grandTotal,
    required this.netPayable,
    this.status = 'Pending',
  });

  int get itemCount => lines.fold(0, (sum, l) => sum + l.quantity);
}

/// Holds cart + order state. Persists to Supabase for all users — logged-in
/// users use their auth UID; guests use a stable UUID stored in localStorage
/// so the admin dashboard can see their carts in real time. On login, the guest
/// cart is merged into the real account and the guest Supabase rows are deleted.
class CartModel extends ChangeNotifier {
  final Map<String, CartLine> _lines = {};
  final List<CartLine> _adminRemovedLines = [];
  final List<Order> _orders = [];
  int _orderSeq = 1042;

  Timer? _sampleTimer;
  int _sampleCountdown = 15;

  double _cachedSubtotal = 0;
  double _cachedTotalGst = 0;

  static const _guestKey    = 'medibo_guest_cart';
  static const _guestUidKey = 'medibo_guest_uid';
  StreamSubscription<AuthState>? _authSub;
  RealtimeChannel? _cartChannel;
  bool _isLoggedIn = false;

  // ── View As mode ──────────────────────────────────────────────────────────
  // When set, CartModel shows the impersonated customer's cart (read-only).
  String? _viewAsUserId;
  bool get isViewAs => _viewAsUserId != null;

  // c410_impersonation_persist: generation counter so an in-flight
  // _loadFromSupabase() call (e.g. the admin's own cart, kicked off at boot
  // before ViewAs restoration from SharedPreferences completes) can never
  // overwrite a NEWER load's result — e.g. the impersonated customer's cart
  // — just because its (longer) request chain happens to resolve later.
  // Every call captures the generation at its start and is dropped if a
  // newer call has since begun by the time it's ready to mutate state.
  int _loadGen = 0;

  Future<void> enterViewAs(String userId) async {
    _viewAsUserId = userId;
    _lines.clear();
    _adminRemovedLines.clear();
    _recomputeTotals();
    _cartChannel?.unsubscribe();
    _cartChannel = null;
    RenderLog.write('view_as_cart', 'enter:$userId');
    await _loadFromSupabase();
  }

  Future<void> exitViewAs() async {
    _viewAsUserId = null;
    _lines.clear();
    _adminRemovedLines.clear();
    _recomputeTotals();
    notifyListeners();
    RenderLog.write('view_as_cart', 'exit');
    await _loadFromSupabase();
  }

  Future<void> _viewAsUpsert(Product product, int quantity) async {
    try {
      await Supabase.instance.client.rpc('admin_writeas_cart_upsert', params: {
        'p_user_id':      _viewAsUserId!,
        'p_product_id':   product.id,
        'p_product_name': product.name,
        'p_price':        product.b2bPrice,
        'p_mrp':          product.mrp,
        'p_quantity':     quantity,
        'p_image_url':    product.imageUrl,
        'p_manufacturer': product.manufacturer,
        'p_pack_size':    product.packSize,
        'p_category':     product.category,
        'p_gst_percent':  product.gstPercent.toInt(),
      });
      RenderLog.write('view_as_cart_write', 'upsert:${product.id}:qty:$quantity');
    } catch (e) {
      RenderLog.write('view_as_cart_write_error', '$e');
    }
    await _loadFromSupabase();
  }

  Future<void> _viewAsRemove(String productId) async {
    try {
      await Supabase.instance.client.rpc('admin_writeas_cart_remove', params: {
        'p_user_id':    _viewAsUserId!,
        'p_product_id': productId,
      });
      RenderLog.write('view_as_cart_write', 'remove:$productId');
    } catch (e) {
      RenderLog.write('view_as_cart_write_error', '$e');
    }
    await _loadFromSupabase();
  }

  Future<void> _viewAsClear() async {
    try {
      await Supabase.instance.client.rpc('admin_writeas_cart_clear', params: {
        'p_user_id': _viewAsUserId!,
      });
      RenderLog.write('view_as_cart_write', 'clear');
    } catch (e) {
      RenderLog.write('view_as_cart_write_error', '$e');
    }
    await _loadFromSupabase();
  }

  CartModel() {
    _initPersistence();
  }

  // ── Guest UUID helpers ────────────────────────────────────────────────────

  String? _getGuestUid() {
    try {
      final v = html.window.localStorage[_guestUidKey];
      return (v != null && v.isNotEmpty) ? v : null;
    } catch (_) {
      return null;
    }
  }

  String _getOrCreateGuestUid() {
    var uid = _getGuestUid();
    if (uid == null) {
      uid = _generateUuid();
      try {
        html.window.localStorage[_guestUidKey] = uid;
      } catch (_) {}
    }
    return uid;
  }

  static String _generateUuid() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final h = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  void _initPersistence() {
    final client = Supabase.instance.client;
    _isLoggedIn = client.auth.currentUser != null;
    _authSub = client.auth.onAuthStateChange.listen(_onAuthState);
    if (_isLoggedIn) {
      final uid = client.auth.currentUser?.id;
      if (uid != null) _subscribeToCartRealtime(uid);
      // If a guest UID is still in localStorage (e.g. a previous merge failed),
      // run merge now before loading so the cart lands under the real auth UID.
      if (_getGuestUid() != null) {
        _mergeGuestCartToSupabase().then((_) => _loadFromSupabase());
      } else {
        _loadFromSupabase();
      }
    } else {
      // Guest: check for a pre-existing stable guest UUID and load from Supabase
      final guestUid = _getGuestUid();
      if (guestUid != null) {
        _loadFromSupabase(guestUid);
        _subscribeToCartRealtime(guestUid);
      } else {
        // First-ever visit: try localStorage (pre-existing carts from before this fix)
        _loadFromLocalStorage();
      }
    }
  }

  Future<void> _onAuthState(AuthState state) async {
    final event = state.event;
    if (event == AuthChangeEvent.signedIn) {
      _isLoggedIn = true;
      await _mergeGuestCartToSupabase();
      await _loadFromSupabase();
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid != null) _subscribeToCartRealtime(uid);
    } else if (event == AuthChangeEvent.signedOut) {
      _isLoggedIn = false;
      _cartChannel?.unsubscribe();
      _cartChannel = null;
      _clearLocalStorage();
      try { html.window.localStorage.remove(_guestUidKey); } catch (_) {}
      _lines.clear();
      _adminRemovedLines.clear();
      _recomputeTotals();
      notifyListeners();
    }
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
          // For guests pass the captured uid; for logged-in users pass null
          // so _loadFromSupabase picks up the current auth UID.
          callback: (_) => _loadFromSupabase(_isLoggedIn ? null : uid),
        )
        .subscribe();
  }

  // ── Supabase ──────────────────────────────────────────────────────────────

  static const kC410ImpersonationPersist = 'c410_impersonation_persist';

  Future<void> _loadFromSupabase([String? overrideUid]) async {
    final gen = ++_loadGen;
    RenderLog.write(kC410ImpersonationPersist, 'gen:$gen;viewAs:$_viewAsUserId');
    try {
      // ViewAs mode: load the impersonated customer's cart via super-admin RPC.
      if (_viewAsUserId != null) {
        final rows = await Supabase.instance.client
            .rpc('admin_preview_customer_cart', params: {'p_user_id': _viewAsUserId!}) as List;
        // #401: cart_items has no buyable column — re-fetch current buyability
        // by id so a snapshot line reflects the product's real availability.
        final buyableIds = rows.map((r) => r['product_id'] as String).toList();
        final buyableFlags = await MedicineRepository().fetchBuyableFlags(buyableIds);
        if (gen != _loadGen) return; // a newer load superseded this one
        _lines.clear();
        _adminRemovedLines.clear();
        RenderLog.write('c401_cart_uses_buyable', 'true');
        for (final row in rows) {
          final product = Product.fromCartData(
            id: row['product_id'] as String,
            name: row['product_name'] as String,
            b2bPrice: (row['price'] as num).toDouble(),
            mrp: (row['mrp'] as num).toDouble(),
            imageUrl: (row['image_url'] as String?) ?? '',
            manufacturer: (row['manufacturer'] as String?) ?? '',
            packSize: (row['pack_size'] as String?) ?? '',
            category: (row['category'] as String?) ?? 'Other',
            gstPercent: (row['gst_percent'] as num?)?.toDouble() ?? 12.0,
            buyable: buyableFlags[row['product_id'] as String],
          );
          final addedByAdmin = (row['added_by'] as String?) == 'admin';
          final cartItemId = (row['id'] as num?)?.toInt();
          _lines[product.id] = CartLine(product, row['quantity'] as int,
              addedByAdmin: addedByAdmin, cartItemId: cartItemId);
        }
        _recomputeTotals();
        notifyListeners();
        RenderLog.write('view_as_cart', 'items:${_lines.length}:netPayable:${netPayable.toStringAsFixed(0)}');
        RenderLog.write('c326_cart_server_src', 'items:${_lines.length}:user:$_viewAsUserId');
        RenderLog.write(_c408ActingAsCart, 'read:items:${_lines.length}:customer_uid:$_viewAsUserId');
        return;
      }

      final uid = overrideUid ?? Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;

      // Hard-delete expired removed-by-admin rows: date boundary in IST
      try {
        final nowUtc = DateTime.now().toUtc();
        final nowIst = nowUtc.add(const Duration(hours: 5, minutes: 30));
        final midnightIst = DateTime(nowIst.year, nowIst.month, nowIst.day);
        final cutoffUtc = midnightIst.subtract(const Duration(hours: 5, minutes: 30));
        await Supabase.instance.client
            .from('cart_items')
            .delete()
            .eq('user_id', uid)
            .eq('removed_by_admin', true)
            .not('removed_at', 'is', null)
            .lt('removed_at', cutoffUtc.toIso8601String());
      } catch (_) {}

      // Authenticated customer reading their own cart: server-sorted RPC
      // (get_my_cart() is SECURITY INVOKER, scoped to auth.uid()). Guests
      // aren't authenticated — auth.uid() is null for them, so the RPC would
      // return nothing — they keep the direct table read, unchanged.
      final List rows;
      if (overrideUid == null) {
        rows = await Supabase.instance.client.rpc('get_my_cart') as List;
      } else {
        rows = await Supabase.instance.client
            .from('cart_items')
            .select()
            .eq('user_id', uid)
            .order('id', ascending: true);
      }
      // #401: cart_items has no buyable column — re-fetch current buyability
      // by id so a snapshot line reflects the product's real availability.
      final buyableIds = rows.map((r) => r['product_id'] as String).toList();
      final buyableFlags = await MedicineRepository().fetchBuyableFlags(buyableIds);
      if (gen != _loadGen) return; // a newer load (e.g. ViewAs) superseded this one
      RenderLog.write('c401_cart_uses_buyable', 'true');
      final newLines = <String, CartLine>{};
      final newAdminRemoved = <CartLine>[];
      for (final row in rows) {
        final product = Product.fromCartData(
          id: row['product_id'] as String,
          name: row['product_name'] as String,
          b2bPrice: (row['price'] as num).toDouble(),
          mrp: (row['mrp'] as num).toDouble(),
          imageUrl: (row['image_url'] as String?) ?? '',
          manufacturer: (row['manufacturer'] as String?) ?? '',
          packSize: (row['pack_size'] as String?) ?? '',
          category: (row['category'] as String?) ?? 'Other',
          gstPercent: (row['gst_percent'] as num?)?.toDouble() ?? 12.0,
          buyable: buyableFlags[row['product_id'] as String],
        );
        final removedByAdmin = (row['removed_by_admin'] as bool?) ?? false;
        final addedByAdmin = (row['added_by'] as String?) == 'admin';
        final cartItemId = (row['id'] as num?)?.toInt();
        if (removedByAdmin) {
          newAdminRemoved.add(CartLine(product, row['quantity'] as int,
              addedByAdmin: addedByAdmin, cartItemId: cartItemId));
        } else {
          newLines[product.id] = CartLine(product, row['quantity'] as int,
              addedByAdmin: addedByAdmin, cartItemId: cartItemId);
        }
      }
      _lines
        ..clear()
        ..addAll(newLines);
      _adminRemovedLines
        ..clear()
        ..addAll(newAdminRemoved);
      _recomputeTotals();
      notifyListeners();

      // Load order history from DB for authenticated users (no guest overrideUid).
      if (overrideUid == null) await fetchOrders();
    } catch (_) {}
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
          placedAt: DateTime.parse(row['created_at'] as String),
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

  Future<void> hardDeleteRemovedItem(int itemId) async {
    try {
      await Supabase.instance.client
          .from('cart_items')
          .delete()
          .eq('id', itemId);
      _adminRemovedLines.removeWhere((l) => l.cartItemId == itemId);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _upsertToSupabase(Product product, int quantity, [String? overrideUid]) async {
    try {
      final uid = overrideUid ?? Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      await Supabase.instance.client.from('cart_items').upsert(
        {
          'user_id': uid,
          'product_id': product.id,
          'product_name': product.name,
          'price': product.b2bPrice,
          'mrp': product.mrp,
          'quantity': quantity,
          'image_url': product.imageUrl,
          'manufacturer': product.manufacturer,
          'pack_size': product.packSize,
          'category': product.category,
          'gst_percent': product.gstPercent.toInt(),
          'updated_at': DateTime.now().toIso8601String(),
          'removed_by_admin': false,
        },
        onConflict: 'user_id,product_id',
      );
    } catch (_) {}
  }

  Future<void> _deleteFromSupabase(String productId, [String? overrideUid]) async {
    try {
      final uid = overrideUid ?? Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      await Supabase.instance.client
          .from('cart_items')
          .delete()
          .eq('user_id', uid)
          .eq('product_id', productId);
    } catch (_) {}
  }

  Future<void> _clearSupabase([String? overrideUid]) async {
    try {
      final uid = overrideUid ?? Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      await Supabase.instance.client
          .from('cart_items')
          .delete()
          .eq('user_id', uid);
    } catch (_) {}
  }

  // ── localStorage (guest offline fallback) ─────────────────────────────────

  void _loadFromLocalStorage() {
    try {
      final raw = html.window.localStorage[_guestKey];
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw) as List<dynamic>;
      for (final item in list) {
        final map = item as Map<String, dynamic>;
        final product = Product.fromCartData(
          id: map['product_id'] as String,
          name: map['product_name'] as String,
          b2bPrice: (map['price'] as num).toDouble(),
          mrp: (map['mrp'] as num? ?? 0).toDouble(),
          imageUrl: (map['image_url'] as String?) ?? '',
          manufacturer: (map['manufacturer'] as String?) ?? '',
          packSize: (map['pack_size'] as String?) ?? '',
          category: (map['category'] as String?) ?? 'Other',
          gstPercent: (map['gst_percent'] as num?)?.toDouble() ?? 12.0,
        );
        _lines[product.id] = CartLine(product, map['quantity'] as int,
            bulkOrder: map['bulk_order'] as int?);
      }
      _recomputeTotals();
      notifyListeners();
    } catch (_) {}
  }

  void _saveToLocalStorage() {
    try {
      final list = _lines.values
          .where((l) => !l.isSample)
          .map((l) => {
                'product_id': l.product.id,
                'product_name': l.product.name,
                'price': l.product.b2bPrice,
                'mrp': l.product.mrp,
                'quantity': l.quantity,
                'image_url': l.product.imageUrl,
                'manufacturer': l.product.manufacturer,
                'pack_size': l.product.packSize,
                'category': l.product.category,
                'gst_percent': l.product.gstPercent,
                'bulk_order': l.bulkOrder,
              })
          .toList();
      html.window.localStorage[_guestKey] = jsonEncode(list);
    } catch (_) {}
  }

  void _clearLocalStorage() {
    try {
      html.window.localStorage.remove(_guestKey);
    } catch (_) {}
  }

  // ── Guest → Supabase merge on login ───────────────────────────────────────

  Future<void> _mergeGuestCartToSupabase() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    final guestUid = _getGuestUid();

    try {
      // 1. Load guest rows from Supabase by guestUid.
      //    This handles OAuth/Google redirect logins where the page reloads before
      //    _mergeGuestCartToSupabase fires, clearing _lines before we can read them.
      //    Skip rows that were removed by admin — they should not pollute the real cart.
      final Map<String, Map<String, dynamic>> toUpsert = {};
      if (guestUid != null) {
        final rows = await Supabase.instance.client
            .from('cart_items')
            .select()
            .eq('user_id', guestUid)
            .eq('removed_by_admin', false);
        for (final r in rows as List) {
          final pid = r['product_id'] as String;
          toUpsert[pid] = Map<String, dynamic>.from(r as Map);
        }
      }

      // 2. Supplement with any in-memory lines not yet in the DB guest rows
      //    (same-page OTP login: guest uid may not have been assigned yet).
      for (final line in _lines.values.where((l) => !l.isSample)) {
        if (!toUpsert.containsKey(line.product.id)) {
          toUpsert[line.product.id] = {
            'product_id': line.product.id,
            'product_name': line.product.name,
            'price': line.product.b2bPrice,
            'mrp': line.product.mrp,
            'image_url': line.product.imageUrl,
            'manufacturer': line.product.manufacturer,
            'pack_size': line.product.packSize,
            'category': line.product.category,
            'gst_percent': line.product.gstPercent.toInt(),
            'quantity': line.quantity,
          };
        }
      }

      if (toUpsert.isEmpty) {
        // Nothing to merge — still clean up guest artifacts if present.
        if (guestUid != null) {
          await Supabase.instance.client
              .rpc('delete_guest_cart', params: {'p_guest_uid': guestUid});
          try { html.window.localStorage.remove(_guestUidKey); } catch (_) {}
        }
        _clearLocalStorage();
        return;
      }

      // 3. Fetch existing auth-uid rows to merge quantities (no doubling).
      final existingRows = await Supabase.instance.client
          .from('cart_items')
          .select('product_id, quantity')
          .eq('user_id', uid);
      final existing = <String, int>{
        for (final r in existingRows as List)
          r['product_id'] as String: r['quantity'] as int,
      };

      // 4. Upsert each guest item under the real auth uid.
      //    Explicitly enumerate fields — NEVER spread the full guest row because
      //    it includes 'id' (bigint PK) which causes a silent PK violation when
      //    there is no (user_id, product_id) conflict to trigger onConflict.
      for (final item in toUpsert.values) {
        final pid = item['product_id'] as String;
        final mergedQty = (existing[pid] ?? 0) + (item['quantity'] as int);
        final payload = <String, dynamic>{
          'user_id':      uid,
          'product_id':   pid,
          'product_name': item['product_name'],
          'price':        item['price'],
          'mrp':          item['mrp'] ?? 0,
          'quantity':     mergedQty,
          'image_url':    item['image_url'],
          'manufacturer': item['manufacturer'],
          'pack_size':    item['pack_size'],
          'category':     item['category'],
          'gst_percent':  item['gst_percent'],
          'added_by':     item['added_by'] ?? 'customer',
          'updated_at':   DateTime.now().toIso8601String(),
        };
        // Remove null values so the DB default applies (avoids NOT NULL errors
        // on optional columns).
        payload.removeWhere((_, v) => v == null);
        await Supabase.instance.client.from('cart_items').upsert(
          payload,
          onConflict: 'user_id,product_id',
        );
      }

      // 5. Delete old guest rows and clean up localStorage.
      // Uses a security-definer RPC because the authenticated DELETE policy
      // only covers rows owned by auth.uid(); guest rows have a foreign UUID.
      if (guestUid != null) {
        await Supabase.instance.client
            .rpc('delete_guest_cart', params: {'p_guest_uid': guestUid});
        try { html.window.localStorage.remove(_guestUidKey); } catch (_) {}
      }
      _clearLocalStorage();
    } catch (_) {}
  }

  // ── Persist helpers ───────────────────────────────────────────────────────

  void _persist(Product product, int quantity) {
    if (_isLoggedIn) {
      _upsertToSupabase(product, quantity);
    } else {
      // Guest: write to Supabase via stable guest UUID so the admin dashboard
      // can see this cart in real time without the user being logged in.
      final guestUid = _getOrCreateGuestUid();
      _upsertToSupabase(product, quantity, guestUid);
      if (_cartChannel == null) _subscribeToCartRealtime(guestUid);
      _saveToLocalStorage(); // offline fallback
    }
  }

  void _persistDelete(String productId) {
    if (_isLoggedIn) {
      _deleteFromSupabase(productId);
    } else {
      final guestUid = _getGuestUid();
      if (guestUid != null) _deleteFromSupabase(productId, guestUid);
      _saveToLocalStorage();
    }
  }

  // ── Computed getters ──────────────────────────────────────────────────────

  void _recomputeTotals() {
    _cachedSubtotal = _lines.values.fold(0.0, (s, l) => s + l.lineTotal);
    _cachedTotalGst = _lines.values.fold(0.0, (s, l) => s + l.lineGst);
  }

  // CHANGE #412 (superseded by #413 below): the bulkOrder-first grouping
  // this used to do didn't reliably reproduce the bulk-upload list order,
  // because bulkOrder (the row index at sync time) doesn't always end up
  // written to cart_items.id in that same order (see #413 Part 2 — the
  // bulk-upload writes were fire-and-forget/parallel, so id assignment
  // could race ahead of list order).
  static const kC412CartSortById = 'c411_cart_sort_by_id';

  // CHANGE #413: (superseded below) used to do a single stable client-side
  // sort of ALL cart lines by cart_items id ascending.
  static const kC413CartInsertionOrder = 'c413_cart_insertion_order';

  // CHANGE #422: cart reads are now backend-sorted — get_my_cart() and
  // admin_preview_customer_cart() both ORDER BY updated_at, id server-side —
  // so no client-side re-sort. _lines (a LinkedHashMap) preserves the order
  // rows arrived in from the server, which IS the correct display order.
  static const kC422CartBackendOrder = 'c422_cart_backend_order';

  List<CartLine> get lines {
    final sorted = _lines.values.toList();
    RenderLog.write(kC412CartSortById, 'lines:${sorted.length}');
    RenderLog.write(kC413CartInsertionOrder, 'lines:${sorted.length}');
    RenderLog.write(kC422CartBackendOrder, 'lines:${sorted.length}');
    return sorted;
  }
  List<CartLine> get adminRemovedLines => List.unmodifiable(_adminRemovedLines);
  List<Order> get orders => List.unmodifiable(_orders.reversed);

  int get distinctItems => _lines.length;
  int get totalUnits => _lines.values.fold(0, (s, l) => s + l.quantity);

  double get subtotal => _cachedSubtotal;
  double get totalGst => _cachedTotalGst;
  double get grandTotal => _cachedSubtotal + _cachedTotalGst;

  /// Sum of MRP × qty for all lines. Used as the single source of truth
  /// for discount tier thresholds (₹2999 = 3%, ₹6999 = 5%).
  double get mrpTotal =>
      _lines.values.fold(0.0, (s, l) => s + l.product.mrp * l.quantity);

  /// GST-categorized net payable amount — the single billing source used by
  /// both the cart bar and the View Bill.
  /// Formula per GST group: (MRP × qty) × (1 − discPct/100) × (1 + rate/100)
  double get netPayable => _computeNetPayable(_lines.values.toList());

  static double _computeNetPayable(List<CartLine> lines) {
    if (lines.isEmpty) return 0.0;
    final mrpSum = lines.fold(0.0, (s, l) => s + l.product.mrp * l.quantity);
    final discPct = cartDiscountPercent(mrpSum);
    final Map<int, double> groupMrp = {};
    for (final l in lines) {
      final rate = l.product.gstPercent.toInt();
      groupMrp[rate] = (groupMrp[rate] ?? 0) + l.product.mrp * l.quantity;
    }
    double total = 0.0;
    for (final entry in groupMrp.entries) {
      final taxable = entry.value * (1 - discPct / 100);
      total += taxable * (1 + entry.key / 100);
    }
    return total + cartDeliveryFee(mrpSum);
  }

  bool get hasSampleItems => _lines.values.any((l) => l.isSample);
  int get sampleCountdown => _sampleCountdown;

  int quantityOf(String productId) => _lines[productId]?.quantity ?? 0;

  // ── Public API ────────────────────────────────────────────────────────────

  void add(Product product) {
    final existing = _lines[product.id];
    final int qty;
    if (existing == null) {
      qty = product.moq;
      _lines[product.id] = CartLine(product, qty);
    } else {
      existing.quantity += 1;
      qty = existing.quantity;
    }
    _recomputeTotals();
    notifyListeners();
    _writeUpsert(product, qty);
  }

  void setQuantity(Product product, int qty) {
    if (qty <= 0) {
      _lines.remove(product.id);
      _recomputeTotals();
      notifyListeners();
      _writeRemove(product.id);
    } else {
      final line = _lines[product.id];
      if (line == null) {
        _lines[product.id] = CartLine(product, qty);
      } else {
        line.quantity = qty;
      }
      _recomputeTotals();
      notifyListeners();
      _writeUpsert(product, qty);
    }
  }

  /// Add or replace a bulk-upload item, stamping it with [bulkOrder] (its row
  /// index in the preview). Always overwrites any existing entry for this
  /// product so the bulkOrder is set correctly on re-sync.
  ///
  /// CHANGE #413: unlike every other write call site (which stays
  /// fire-and-forget via the unchanged _writeUpsert/_persist), this AWAITS
  /// its own write. It mirrors _writeUpsert/_persist's exact branching
  /// inline rather than calling them, so their (and every other caller's)
  /// behavior is untouched. This lets BulkUploadScreen._addMatchedToCart
  /// await each row in turn, so cart_items.id assignment order matches the
  /// bulk-upload list order instead of racing over the network.
  Future<void> setBulkQuantity(Product product, int qty, int bulkOrder) async {
    // CHANGE #326: ViewAs must persist via server RPC, not local store.
    _lines[product.id] = CartLine(product, qty,
        bulkOrder: bulkOrder, addedByAdmin: isViewAs);
    _recomputeTotals();
    notifyListeners();
    if (isViewAs) {
      RenderLog.write('c326_bulk_upsert',
          'product:${product.id}:qty:$qty:user:$_viewAsUserId');
    }
    RenderLog.write(kC413CartInsertionOrder,
        'insert:bulkOrder:$bulkOrder;product:${product.id}');
    if (isViewAs) {
      RenderLog.write('c407_actingas_cart_write', 'customer_uid:$_viewAsUserId:not_admin');
      RenderLog.write(_c408ActingAsCart, 'write:upsert:customer_uid:$_viewAsUserId');
      await _viewAsUpsert(product, qty);
    } else if (_isLoggedIn) {
      await _upsertToSupabase(product, qty);
    } else {
      final guestUid = _getOrCreateGuestUid();
      await _upsertToSupabase(product, qty, guestUid);
      if (_cartChannel == null) _subscribeToCartRealtime(guestUid);
      _saveToLocalStorage();
    }
  }

  void increment(Product product) =>
      setQuantity(product, quantityOf(product.id) + 1);

  void decrement(Product product) {
    final next = quantityOf(product.id) - 1;
    if (next < product.moq) {
      remove(product);
    } else {
      setQuantity(product, next);
    }
  }

  void remove(Product product) {
    _lines.remove(product.id);
    if (!isViewAs && !hasSampleItems) {
      _sampleTimer?.cancel();
      _sampleTimer = null;
    }
    _recomputeTotals();
    notifyListeners();
    _writeRemove(product.id);
  }

  void removeById(String productId) {
    final line = _lines[productId];
    if (line != null) remove(line.product);
  }

  // #407/#408: single guard that EVERY cart write funnels through — a future
  // add/update/remove call site can never forget to check ViewAs and
  // silently persist under the admin's own account instead of the
  // impersonated customer's. RenderLog confirms the CUSTOMER uid was used,
  // never the admin's. c408_actingas_cart is the CHANGE #408 sentinel proving
  // this guard is present in the live bundle.
  static const _c408ActingAsCart = 'c408_actingas_cart';

  void _writeUpsert(Product product, int qty) {
    if (isViewAs) {
      RenderLog.write('c407_actingas_cart_write', 'customer_uid:$_viewAsUserId:not_admin');
      RenderLog.write(_c408ActingAsCart, 'write:upsert:customer_uid:$_viewAsUserId');
      _viewAsUpsert(product, qty);
    } else {
      _persist(product, qty);
    }
  }

  void _writeRemove(String productId) {
    if (isViewAs) {
      RenderLog.write('c407_actingas_cart_write', 'customer_uid:$_viewAsUserId:not_admin:remove');
      RenderLog.write(_c408ActingAsCart, 'write:remove:customer_uid:$_viewAsUserId');
      _viewAsRemove(productId);
    } else {
      _persistDelete(productId);
    }
  }

  void clear() {
    if (isViewAs) {
      _lines.clear();
      _recomputeTotals();
      notifyListeners();
      RenderLog.write('c407_actingas_cart_write', 'customer_uid:$_viewAsUserId:not_admin:clear');
      RenderLog.write(_c408ActingAsCart, 'write:clear:customer_uid:$_viewAsUserId');
      _viewAsClear();
      return;
    }
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _sampleCountdown = 15;
    _lines.clear();
    _recomputeTotals();
    notifyListeners();
    if (_isLoggedIn) {
      _clearSupabase();
    } else {
      final guestUid = _getGuestUid();
      if (guestUid != null) {
        _clearSupabase(guestUid);
        try { html.window.localStorage.remove(_guestUidKey); } catch (_) {}
      }
      _clearLocalStorage();
    }
  }

  void addSampleItems(List<MapEntry<Product, int>> items) {
    for (final entry in items) {
      _lines[entry.key.id] = CartLine(entry.key, entry.value, isSample: true);
    }
    _startSampleTimer();
    _recomputeTotals();
    notifyListeners();
    // Sample items are transient — not persisted.
  }

  void clearSampleItems() {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _sampleCountdown = 15;
    _lines.removeWhere((_, l) => l.isSample);
    _recomputeTotals();
    notifyListeners();
    // Sample items were never persisted, so nothing to delete remotely.
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
        _lines.values.map((l) => CartLine(l.product, l.quantity)).toList();
    final order = Order(
      number: orderDisplayId({'id': 'seq${_orderSeq++}', 'created_at': DateTime.now().toIso8601String()}),
      placedAt: DateTime.now(),
      lines: orderLines,
      grandTotal: grandTotal,
      netPayable: _computeNetPayable(orderLines),
    );
    _orders.add(order);
    _lines.clear();
    _recomputeTotals();
    notifyListeners();
    if (_isLoggedIn) {
      _clearSupabase();
    } else {
      final guestUid = _getGuestUid();
      if (guestUid != null) {
        _clearSupabase(guestUid);
        try { html.window.localStorage.remove(_guestUidKey); } catch (_) {}
      }
      _clearLocalStorage();
    }
    return order;
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _cartChannel?.unsubscribe();
    _sampleTimer?.cancel();
    super.dispose();
  }
}
