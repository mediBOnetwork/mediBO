// PROTECTED — CMD #464 (feature_gaps 45, 46, 47).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how the supplier surface renders backend money or the
// inquiry answer badge.
//
// What this holds down:
//
//   1. The supplier order total is a BACKEND STRING. `po_pricing_block` sends
//      `payable_display` (rupee-formatted by inr_money) and `show_payable`;
//      the card prints the first and obeys the second. gap 45 was
//      supplier_orders_screen.dart building
//      '₹${totalAmount % 1 == 0 ? .toInt() : .toStringAsFixed(2)}' itself —
//      the rounding rule for a supplier's money living in Flutter.
//
//   2. `show_payable` is the ONLY reason a total appears. A payload carrying a
//      non-zero amount with show_payable:false still renders nothing, because
//      the decision is not Dart's to re-derive from the number.
//
//   3. The inquiry answer badge is `inquiry_answer_badge()`'s, verbatim. gap 46
//      was a Dart `switch` on the answer string whose default branch labelled
//      anything unrecognised as a refusal — which is exactly how gap 47's new
//      'Short supplied' state would have been mislabelled as something the
//      supplier never said.
//
//   4. No badge on the payload = no badge on the card. Dart never invents one.
//
//   5. The removed literals stay removed. A source guard, so a future edit
//      cannot quietly re-introduce a Dart-side ₹ string, the hardcoded
//      expired/invalid page copy, or the badge switch.
//
// No network, no Supabase, no goldens.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/screens/public/inquiry_form_screen.dart';
import 'package:pharma_b2b/screens/supplier/supplier_orders_screen.dart';

void main() {
  group('gap 45 — the supplier order total is the backend\'s string', () {
    test('payable_display prints verbatim, exactly as sent', () {
      final t = SupplierOrderTotal.from(const {
        'payable_display': '₹1,234.50',
        'show_payable': true,
        'payable_total': 1234.5,
      });
      expect(t.show, isTrue);
      // Not '₹1234.5', not '₹1234.50' — the backend's own grouping survives.
      expect(t.display, '₹1,234.50');
    });

    test('a whole-rupee total is NOT re-rounded in Dart', () {
      final t = SupplierOrderTotal.from(const {
        'payable_display': '₹900',
        'show_payable': true,
        'payable_total': 900,
      });
      expect(t.display, '₹900');
    });

    test('show_payable:false hides the total even when the amount is non-zero',
        () {
      final t = SupplierOrderTotal.from(const {
        'payable_display': '₹4,000.00',
        'show_payable': false,
        'payable_total': 4000,
      });
      expect(t.show, isFalse);
    });

    test('an absent pricing block shows nothing and throws nothing', () {
      expect(SupplierOrderTotal.from(null).show, isFalse);
      expect(SupplierOrderTotal.from(const {}).show, isFalse);
      expect(SupplierOrderTotal.from(const {'has': false}).show, isFalse);
      expect(SupplierOrderTotal.from(null).display, '');
    });

    test('a display string with no show_payable flag is still not shown', () {
      // Forward compatibility runs one way only: the flag must arrive.
      final t = SupplierOrderTotal.from(const {'payable_display': '₹10'});
      expect(t.show, isFalse);
    });
  });

  group('gap 46 — the inquiry answer badge is the backend\'s', () {
    test('label, bg and fg are the payload\'s, not derived from the answer',
        () {
      final b = InquiryBadge.from(const {
        'answer': 'Out of Stock',
        'badge': {'label': 'Out of Stock', 'bg': '#FEE2E2', 'fg': '#991B1B'},
      });
      expect(b.has, isTrue);
      expect(b.label, 'Out of Stock');
      expect(b.bg, const Color(0xFFFEE2E2));
      expect(b.fg, const Color(0xFF991B1B));
    });

    test(
        'gap 47 — a Short supplied answer renders its OWN badge, never '
        "\"Don't stock\"", () {
      // The old Dart switch had no case for this state and fell through to the
      // default, printing a refusal the supplier never gave.
      final b = InquiryBadge.from(const {
        'answer': 'Short supplied',
        'badge': {'label': 'Short supplied', 'bg': '#FEF3C7', 'fg': '#92400E'},
      });
      expect(b.label, 'Short supplied');
      expect(b.bg, const Color(0xFFFEF3C7));
      expect(b.fg, const Color(0xFF92400E));
    });

    test('an answer the app has never heard of prints the backend\'s badge',
        () {
      final b = InquiryBadge.from(const {
        'answer': 'Some future state',
        'badge': {'label': 'Some future state', 'bg': '#EFF6FF', 'fg': '#1E40AF'},
      });
      expect(b.label, 'Some future state');
      expect(b.bg, const Color(0xFFEFF6FF));
    });

    test('no badge on the payload means no badge on the card', () {
      expect(InquiryBadge.from(const {'answer': 'Available'}).has, isFalse);
      expect(InquiryBadge.from(const {'badge': {}}).has, isFalse);
      expect(InquiryBadge.from(const {'badge': {'bg': '#FFFFFF'}}).has, isFalse);
    });

    // CHANGE #671 (gap 51): the fallback used to be two hex literals written in
    // this screen. It is the TOKEN layer now — Ds.c.bg / Ds.c.textSecondary —
    // so the assertion names the tokens rather than the hexes they currently
    // resolve to. That is the point of the change: ui_design_set() moves this
    // fallback with the rest of the app, and re-hardcoding a hex here would
    // fail this test again.
    test('a malformed colour falls back to the tokens, instead of throwing',
        () {
      final b = InquiryBadge.from(const {
        'badge': {'label': 'Available', 'bg': 'not-a-colour', 'fg': ''},
      });
      expect(b.has, isTrue);
      expect(b.bg, Ds.c.bg);
      expect(b.fg, Ds.c.textSecondary);
      // ...and it is a REAL fallback, not the unparsed string leaking through.
      expect(b.bg, isNot(equals(b.fg)));
    });
  });

  group('the removed literals stay removed', () {
    test('supplier_orders_screen builds no rupee string of its own', () {
      final src =
          File('lib/screens/supplier/supplier_orders_screen.dart').readAsStringSync();
      expect(src.contains(r"'₹$"), isFalse,
          reason: 'a ₹ interpolation is back in Dart — use the backend display '
              'string (po_pricing_block.payable_display)');
      expect(src.contains('toStringAsFixed'), isFalse,
          reason: 'money is formatted by inr_money in the backend, never here');
    });

    test('inquiry_form_screen hardcodes no page copy and no badge switch', () {
      final src =
          File('lib/screens/public/inquiry_form_screen.dart').readAsStringSync();
      for (final gone in const [
        'This inquiry link has expired',
        'This link is no longer valid',
        'Please contact mediBO for a new link.',
        'Please contact mediBO for assistance.',
        "Don't stock",
      ]) {
        expect(src.contains(gone), isFalse,
            reason: '"$gone" belongs in ui_copy / inquiry_answer_badge(), '
                'not in Dart');
      }
    });
  });
}
