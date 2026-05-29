import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'product.dart';

class CartItem {
  final Product medicine;
  int quantity;

  CartItem({required this.medicine, required this.quantity});

  double get total => medicine.b2bPrice * quantity;
}

class CartProvider extends ChangeNotifier {
  final Map<String, CartItem> _items = {};
  bool _isLoggedIn = false;
  static const String _guestKey = 'medibo_guest_cart_v3';

  Map<String, CartItem> get items => Map.unmodifiable(_items);
  int get itemCount => _items.length;
  int get totalQuantity => _items.values.fold(0, (s, i) => s + i.quantity);
  double get subtotal => _items.values.fold(0.0, (s, i) => s + i.total);
  double get gst => subtotal * 0.12;
  double get grandTotal => subtotal + gst;
  bool isInCart(String id) => _items.containsKey(id);
  int getQuantity(String id) => _items[id]?.quantity ?? 0;

  CartProvider() {
    _init();
  }

  Future<void> _init() async {
    Supabase.instance.client.auth.onAuthStateChange.listen((data) async {
      if (data.event == AuthChangeEvent.signedIn) {
        _isLoggedIn = true;
        await _mergeGuestThenLoadSupabase();
      } else if (data.event == AuthChangeEvent.signedOut) {
        _isLoggedIn = false;
        _items.clear();
        notifyListeners();
      }
    });
    final session = Supabase.instance.client.auth.currentSession;
    if (session != null) {
      _isLoggedIn = true;
      await _loadFromSupabase();
    } else {
      await _loadFromLocal();
    }
  }

  Future<void> _mergeGuestThenLoadSupabase() async {
    final guestItems = await _readLocal();
    await _loadFromSupabase();
    for (final item in guestItems.values) {
      final existing = _items[item.medicine.id];
      final qty = (existing?.quantity ?? 0) + item.quantity;
      _items[item.medicine.id] = CartItem(medicine: item.medicine, quantity: qty);
      await _upsertSupabase(item.medicine, qty);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_guestKey);
    notifyListeners();
  }

  Future<void> _loadFromSupabase() async {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      final rows = await Supabase.instance.client
          .from('cart_items')
          .select()
          .eq('user_id', uid);
      _items.clear();
      for (final row in rows as List) {
        final med = Product.fromCartData(
          id: row['product_id'] as String,
          name: row['product_name'] as String,
          b2bPrice: (row['price'] as num).toDouble(),
          mrp: (row['mrp'] as num? ?? 0).toDouble(),
          imageUrl: (row['image_url'] as String?) ?? '',
        );
        _items[med.id] = CartItem(medicine: med, quantity: row['quantity'] as int);
      }
      notifyListeners();
    } catch (e) {
      debugPrint('loadSupabase error: $e');
    }
  }

  Future<void> _loadFromLocal() async {
    _items.addAll(await _readLocal());
    notifyListeners();
  }

  Future<Map<String, CartItem>> _readLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final str = prefs.getString(_guestKey);
      if (str == null) return {};
      final List decoded = jsonDecode(str);
      return {
        for (final e in decoded)
          (e['id'] as String): CartItem(
            medicine: Product.fromJson(e['medicine'] as Map<String, dynamic>),
            quantity: e['qty'] as int,
          )
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _items.entries
          .map((e) => {
                'id': e.key,
                'medicine': e.value.medicine.toJson(),
                'qty': e.value.quantity,
              })
          .toList();
      await prefs.setString(_guestKey, jsonEncode(list));
    } catch (e) {
      debugPrint('saveLocal error: $e');
    }
  }

  Future<void> _upsertSupabase(Product m, int qty) async {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      await Supabase.instance.client.from('cart_items').upsert(
        {
          'user_id': uid,
          'product_id': m.id,
          'product_name': m.name,
          'price': m.b2bPrice,
          'mrp': m.mrp,
          'image_url': m.imageUrl,
          'quantity': qty,
          'updated_at': DateTime.now().toIso8601String(),
        },
        onConflict: 'user_id,product_id',
      );
    } catch (e) {
      debugPrint('upsert error: $e');
    }
  }

  Future<void> _deleteSupabase(String productId) async {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      await Supabase.instance.client
          .from('cart_items')
          .delete()
          .eq('user_id', uid)
          .eq('product_id', productId);
    } catch (e) {
      debugPrint('delete error: $e');
    }
  }

  Future<void> addItem(Product medicine, int quantity) async {
    final qty = (_items[medicine.id]?.quantity ?? 0) + quantity;
    _items[medicine.id] = CartItem(medicine: medicine, quantity: qty);
    notifyListeners();
    _isLoggedIn
        ? await _upsertSupabase(medicine, qty)
        : await _saveLocal();
  }

  Future<void> updateQuantity(String id, int qty) async {
    if (!_items.containsKey(id)) return;
    if (qty <= 0) {
      await removeItem(id);
      return;
    }
    _items[id]!.quantity = qty;
    notifyListeners();
    _isLoggedIn
        ? await _upsertSupabase(_items[id]!.medicine, qty)
        : await _saveLocal();
  }

  Future<void> removeItem(String id) async {
    _items.remove(id);
    notifyListeners();
    _isLoggedIn ? await _deleteSupabase(id) : await _saveLocal();
  }

  Future<void> clearCart() async {
    _items.clear();
    notifyListeners();
    if (_isLoggedIn) {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid != null) {
        await Supabase.instance.client
            .from('cart_items')
            .delete()
            .eq('user_id', uid);
      }
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_guestKey);
    }
  }
}
