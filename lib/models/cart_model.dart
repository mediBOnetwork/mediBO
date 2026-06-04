import 'dart:async';
import 'dart:convert';
import 'dart:math';

// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'product.dart';
import '../util.dart';

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
      _loadFromSupabase();
      final uid = client.auth.currentUser?.id;
      if (uid != null) _subscribeToCartRealtime(uid);
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

  Future<void> _loadFromSupabase([String? overrideUid]) async {
    try {
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

      final rows = await Supabase.instance.client
          .from('cart_items')
          .select()
          .eq('user_id', uid);
      _lines.clear();
      _adminRemovedLines.clear();
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
        );
        final removedByAdmin = (row['removed_by_admin'] as bool?) ?? false;
        final addedByAdmin = (row['added_by'] as String?) == 'admin';
        final cartItemId = (row['id'] as num?)?.toInt();
        if (removedByAdmin) {
          _adminRemovedLines.add(CartLine(product, row['quantity'] as int,
              addedByAdmin: addedByAdmin, cartItemId: cartItemId));
        } else {
          _lines[product.id] = CartLine(product, row['quantity'] as int,
              addedByAdmin: addedByAdmin, cartItemId: cartItemId);
        }
      }
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
          number: (row['payment_id'] as String?) ?? (row['id'] as String),
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
      final Map<String, Map<String, dynamic>> toUpsert = {};
      if (guestUid != null) {
        final rows = await Supabase.instance.client
            .from('cart_items')
            .select()
            .eq('user_id', guestUid);
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
              .from('cart_items').delete().eq('user_id', guestUid);
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
      for (final item in toUpsert.values) {
        final pid = item['product_id'] as String;
        final mergedQty = (existing[pid] ?? 0) + (item['quantity'] as int);
        await Supabase.instance.client.from('cart_items').upsert(
          {
            ...item,
            'user_id': uid,
            'quantity': mergedQty,
            'updated_at': DateTime.now().toIso8601String(),
          },
          onConflict: 'user_id,product_id',
        );
      }

      // 5. Delete old guest rows and clean up localStorage.
      if (guestUid != null) {
        await Supabase.instance.client
            .from('cart_items').delete().eq('user_id', guestUid);
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

  List<CartLine> get lines {
    final bulk = <CartLine>[];
    final others = <CartLine>[];
    for (final l in _lines.values) {
      if (l.bulkOrder != null) bulk.add(l); else others.add(l);
    }
    bulk.sort((a, b) => a.bulkOrder!.compareTo(b.bulkOrder!));
    return [...bulk, ...others];
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
    _persist(product, qty);
  }

  void setQuantity(Product product, int qty) {
    if (qty <= 0) {
      _lines.remove(product.id);
      _recomputeTotals();
      notifyListeners();
      _persistDelete(product.id);
    } else {
      final line = _lines[product.id];
      if (line == null) {
        _lines[product.id] = CartLine(product, qty);
      } else {
        line.quantity = qty;
      }
      _recomputeTotals();
      notifyListeners();
      _persist(product, qty);
    }
  }

  /// Add or replace a bulk-upload item, stamping it with [bulkOrder] (its row
  /// index in the preview). Always overwrites any existing entry for this
  /// product so the bulkOrder is set correctly on re-sync.
  void setBulkQuantity(Product product, int qty, int bulkOrder) {
    _lines[product.id] = CartLine(product, qty, bulkOrder: bulkOrder);
    _recomputeTotals();
    notifyListeners();
    _persist(product, qty);
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
    if (!hasSampleItems) {
      _sampleTimer?.cancel();
      _sampleTimer = null;
    }
    _recomputeTotals();
    notifyListeners();
    _persistDelete(product.id);
  }

  void removeById(String productId) {
    final line = _lines[productId];
    if (line != null) remove(line.product);
  }

  void clear() {
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
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _sampleCountdown = 15;
    final orderLines =
        _lines.values.map((l) => CartLine(l.product, l.quantity)).toList();
    final order = Order(
      number: 'PO-${_orderSeq++}',
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
