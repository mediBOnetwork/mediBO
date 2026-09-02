// PROTECTED — CHANGE #686.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how copy placeholders resolve.
//
// WHY THIS FILE EXISTS. On Aug 9 a "100% backend copy" sweep lifted Dart
// EXPRESSIONS into ui_copy instead of the strings they produce, and truncated
// each at the first quote. Fifteen rows became fragments of source code, and
// users saw them verbatim — Om photographed one: an admin order header reading
// `Ordered by: ${row.pharmacy.isNotEmpty ?`.
//
// The stored values are guarded in SQL (a CHECK constraint plus rg behaviour
// c686_ui_copy_is_copy). What SQL cannot see is the other half of the same
// bug, and it is the half that survived the first fix: a template whose
// placeholder names do not match the parameters its call site passes. The
// value looked repaired — "Ordered by: {name}" — while the screen passed {a}
// and {b}, so cf() stripped the unresolved placeholder, then stripped the
// dangling colon, and the customer's name silently vanished from the header.
// A row can be perfectly good copy and still render nothing.
//
// So this file pins the RESOLVER's contract, which is what makes a mismatch
// visible instead of silent:
//   1. cf() substitutes every parameter it is given, by name.
//   2. A placeholder with no matching parameter is REMOVED, and the orphaned
//      punctuation before it goes too — that is why the failure was invisible.
//   3. A parameter the template does not mention changes nothing.
//   4. Copy with no placeholders is returned untouched.
//   5. The two shapes of the header Om reported both render in full.

import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/services/ui_copy.dart';

void main() {
  setUp(() {
    UiCopy.debugSet({
      'admin_customer.ordered_by': 'Ordered by: {name}',
      'admin_customer.ordered_by_with_pharmacy':
          'Ordered by: {name} · {pharmacy}',
      'orders.invoice_dl': 'DL: {value}',
      'cart.removed_line_summary': '×{qty}  ·  ₹{amount}',
      'plain.no_placeholder': 'Pending approval',
    });
  });

  group('cf resolves every parameter it is given', () {
    test('the header Om reported renders the name, both shapes', () {
      expect(cf('admin_customer.ordered_by', {'name': 'Ramesh'}),
          'Ordered by: Ramesh');
      expect(
          cf('admin_customer.ordered_by_with_pharmacy',
              {'name': 'Ramesh', 'pharmacy': 'Chandra Medicom'}),
          'Ordered by: Ramesh · Chandra Medicom');
    });

    test('two placeholders in one template both resolve', () {
      expect(cf('cart.removed_line_summary', {'qty': '3', 'amount': '450'}),
          '×3  ·  ₹450');
    });

    test('copy with no placeholder is returned untouched', () {
      expect(cf('plain.no_placeholder', const {}), 'Pending approval');
    });

    test('an unknown parameter changes nothing', () {
      expect(cf('orders.invoice_dl', {'value': 'CG-1234', 'stray': 'x'}),
          'DL: CG-1234');
    });
  });

  group('the silent failure this change was reported for', () {
    test('a parameter name the template does not use loses the value', () {
      // THE BUG, pinned. The screen passed {a}/{b} at a {name} template, and
      // this is what the user saw: no name, and no colon to hint at the gap.
      // The assertion is here so the behaviour is a documented contract rather
      // than a surprise — the FIX is that call sites pass matching names, and
      // a mismatch must never again look like ordinary copy to a reviewer.
      expect(cf('admin_customer.ordered_by', {'a': 'Ramesh', 'b': ''}),
          'Ordered by');
    });

    test('a half-supplied template drops only the missing half', () {
      expect(
          cf('admin_customer.ordered_by_with_pharmacy', {'name': 'Ramesh'}),
          'Ordered by: Ramesh ·');
    });
  });
}
