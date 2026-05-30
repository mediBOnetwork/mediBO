import 'dart:async';
import 'dart:convert';

// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'product.dart';

/// A single line in the cart: a product plus the ordered quantity (packs).
class CartLine {
  final Product product;
  int quantity;
  final bool isSample;

  CartLine(this.product, this.quantity, {this.isSample = false});

  double get lineTotal => product.b2bPrice * quantity;
  double get lineGst => lineTotal * product.gstPercent / 100;
}

/// A placed purchase order, kept in memory for the Orders screen.
class Order {
  final String number;
  final DateTime placedAt;
  final List<CartLine> lines;
  final double grandTotal;
  String status;

  Order({
    required this.number,
    required this.placedAt,
    required this.lines,
    required this.grandTotal,
    this.status = 'Pending',
  });

  int get itemCount => lines.fold(0, (sum, l) => sum + l.quantity);
}

/// Holds cart + order state. Persists to Supabase for logged-in users,
/// localStorage for guests. Merges guest cart into Supabase on login.
class CartModel extends ChangeNotifier {
  final Map<String, CartLine> _lines = {};
  final List<Order> _orders = [];
  int _orderSeq = 1042;

  Timer? _sampleTimer;
  int _sampleCountdown = 15;

  double _cachedSubtotal = 0;
  double _cachedTotalGst = 0;

  static const _guestKey = 'medibo_guest_cart';
  StreamSubscription<AuthState>? _authSub;
  bool _isLoggedIn = false;

  CartModel() {
    _initPersistence();
  }

  void _initPersistence() {
    final client = Supabase.instance.client;
    _isLoggedIn = client.auth.currentUser != null;
    _authSub = client.auth.onAuthStateChange.listen(_onAuthState);
    if (_isLoggedIn) {
      _loadFromSupabase();
    } else {
      _loadFromLocalStorage();
    }
  }

  Future<void> _onAuthState(AuthState state) async {
    final event = state.event;
    if (event == AuthChangeEvent.signedIn) {
      _isLoggedIn = true;
      await _mergeGuestCartToSupabase();
      await _loadFromSupabase();
    } else if (event == AuthChangeEvent.signedOut) {
      _isLoggedIn = false;
      _clearLocalStorage();
      _lines.clear();
      _recomputeTotals();
      notifyListeners();
    }
  }

  // ── Supabase ──────────────────────────────────────────────────────────────

  Future<void> _loadFromSupabase() async {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      final rows = await Supabase.instance.client
          .from('cart_items')
          .select()
          .eq('user_id', uid);
      _lines.clear();
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
        _lines[product.id] = CartLine(product, row['quantity'] as int);
      }
      _recomputeTotals();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _upsertToSupabase(Product product, int quantity) async {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
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

  Future<void> _deleteFromSupabase(String productId) async {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      await Supabase.instance.client
          .from('cart_items')
          .delete()
          .eq('user_id', uid)
          .eq('product_id', productId);
    } catch (_) {}
  }

  Future<void> _clearSupabase() async {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      await Supabase.instance.client
          .from('cart_items')
          .delete()
          .eq('user_id', uid);
    } catch (_) {}
  }

  // ── localStorage (guest) ──────────────────────────────────────────────────

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
        _lines[product.id] = CartLine(product, map['quantity'] as int);
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
    if (_lines.isEmpty) return;
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      final rows = await Supabase.instance.client
          .from('cart_items')
          .select('product_id, quantity')
          .eq('user_id', uid);
      final existing = <String, int>{
        for (final r in rows) r['product_id'] as String: r['quantity'] as int,
      };
      for (final line in _lines.values.where((l) => !l.isSample)) {
        final merged = (existing[line.product.id] ?? 0) + line.quantity;
        await _upsertToSupabase(line.product, merged);
      }
      _clearLocalStorage();
    } catch (_) {}
  }

  // ── Persist helpers ───────────────────────────────────────────────────────

  void _persist(Product product, int quantity) {
    if (_isLoggedIn) {
      _upsertToSupabase(product, quantity);
    } else {
      _saveToLocalStorage();
    }
  }

  void _persistDelete(String productId) {
    if (_isLoggedIn) {
      _deleteFromSupabase(productId);
    } else {
      _saveToLocalStorage();
    }
  }

  // ── Computed getters ──────────────────────────────────────────────────────

  void _recomputeTotals() {
    _cachedSubtotal = _lines.values.fold(0.0, (s, l) => s + l.lineTotal);
    _cachedTotalGst = _lines.values.fold(0.0, (s, l) => s + l.lineGst);
  }

  List<CartLine> get lines => _lines.values.toList();
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
    final order = Order(
      number: 'PO-${_orderSeq++}',
      placedAt: DateTime.now(),
      lines: _lines.values.map((l) => CartLine(l.product, l.quantity)).toList(),
      grandTotal: grandTotal,
    );
    _orders.add(order);
    _lines.clear();
    _recomputeTotals();
    notifyListeners();
    if (_isLoggedIn) {
      _clearSupabase();
    } else {
      _clearLocalStorage();
    }
    return order;
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _sampleTimer?.cancel();
    super.dispose();
  }
}
