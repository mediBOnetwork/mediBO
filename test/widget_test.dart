import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/product.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/util.dart';

/// Network-free unit tests. The catalog now loads from Supabase at runtime,
/// so these exercise the model mapping and cart/pricing logic directly.
void main() {
  Product sample({double price = 100, double mrp = 150, int moq = 5}) =>
      Product.fromMap({
        'id': '11111111-1111-1111-1111-111111111111',
        'name': 'Test Med',
        'composition': 'Testosterone 10mg',
        'manufacturer': 'Cipla',
        'category': 'Cardiac',
        'unit': 'Strip of 10 tablets',
        'mrp': mrp,
        'price_per_unit': price,
        'min_order_qty': moq,
        'stock_available': 100,
        'requires_prescription': true,
        'discount': 30,
        'schedule_type': 'Schedule H',
      });

  test('Product.fromMap maps Supabase columns onto domain fields', () {
    final p = sample();
    expect(p.genericName, 'Testosterone 10mg'); // composition
    expect(p.b2bPrice, 100); // price_per_unit
    expect(p.packSize, 'Strip of 10 tablets'); // unit
    expect(p.moq, 5); // min_order_qty
    expect(p.requiresPrescription, isTrue);
    expect(p.marginPercent.round(), 33); // (150-100)/150
  });

  test('First add jumps to MOQ and decrement below MOQ removes the line', () {
    final cart = CartModel();
    final p = sample(moq: 5);

    cart.add(p);
    expect(cart.quantityOf(p.id), 5);

    cart.increment(p);
    expect(cart.quantityOf(p.id), 6);

    cart.decrement(p); // back to 5 (MOQ)
    expect(cart.quantityOf(p.id), 5);

    cart.decrement(p); // below MOQ -> removed
    expect(cart.quantityOf(p.id), 0);
    expect(cart.lines, isEmpty);
  });

  test('Totals include 12% GST and checkout empties the cart', () {
    final cart = CartModel();
    cart.add(sample(price: 100, moq: 1)); // qty 1, subtotal 100

    expect(cart.subtotal, 100);
    expect(cart.totalGst, closeTo(12, 0.001));
    expect(cart.grandTotal, closeTo(112, 0.001));

    final order = cart.checkout();
    expect(order.lines, hasLength(1));
    expect(cart.lines, isEmpty);
  });

  test('rupees() formats with Indian digit grouping', () {
    expect(rupees(1234567.5), '₹12,34,567.50');
    expect(rupees(150), '₹150.00');
  });
}
