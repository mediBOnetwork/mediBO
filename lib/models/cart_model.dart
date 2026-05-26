import 'dart:async';

import 'package:flutter/foundation.dart';

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

/// Holds cart + order state and notifies listeners on change.
class CartModel extends ChangeNotifier {
  final Map<String, CartLine> _lines = {};
  final List<Order> _orders = [];
  int _orderSeq = 1042;

  Timer? _sampleTimer;
  int _sampleCountdown = 15;

  List<CartLine> get lines => _lines.values.toList();
  List<Order> get orders => List.unmodifiable(_orders.reversed);

  int get distinctItems => _lines.length;
  int get totalUnits => _lines.values.fold(0, (s, l) => s + l.quantity);

  double get subtotal =>
      _lines.values.fold(0.0, (s, l) => s + l.lineTotal);
  double get totalGst =>
      _lines.values.fold(0.0, (s, l) => s + l.lineGst);
  double get grandTotal => subtotal + totalGst;

  bool get hasSampleItems => _lines.values.any((l) => l.isSample);
  int get sampleCountdown => _sampleCountdown;

  int quantityOf(String productId) => _lines[productId]?.quantity ?? 0;

  /// Adds [product] to the cart. The first add jumps straight to the MOQ.
  void add(Product product) {
    final existing = _lines[product.id];
    if (existing == null) {
      _lines[product.id] = CartLine(product, product.moq);
    } else {
      existing.quantity += 1;
    }
    notifyListeners();
  }

  void setQuantity(Product product, int qty) {
    if (qty <= 0) {
      _lines.remove(product.id);
    } else {
      final line = _lines[product.id];
      if (line == null) {
        _lines[product.id] = CartLine(product, qty);
      } else {
        line.quantity = qty;
      }
    }
    notifyListeners();
  }

  void increment(Product product) => setQuantity(product, quantityOf(product.id) + 1);

  /// Decrements but never below the product's MOQ; going under removes it.
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
    notifyListeners();
  }

  void clear() {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _sampleCountdown = 15;
    _lines.clear();
    notifyListeners();
  }

  void addSampleItems(List<MapEntry<Product, int>> items) {
    for (final entry in items) {
      _lines[entry.key.id] = CartLine(entry.key, entry.value, isSample: true);
    }
    _startSampleTimer();
    notifyListeners();
  }

  void clearSampleItems() {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _sampleCountdown = 15;
    _lines.removeWhere((_, l) => l.isSample);
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

  /// Converts the current cart into a placed order and empties the cart.
  Order checkout() {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _sampleCountdown = 15;
    final order = Order(
      number: 'PO-${_orderSeq++}',
      placedAt: DateTime.now(),
      lines: _lines.values
          .map((l) => CartLine(l.product, l.quantity))
          .toList(),
      grandTotal: grandTotal,
    );
    _orders.add(order);
    _lines.clear();
    notifyListeners();
    return order;
  }
}
