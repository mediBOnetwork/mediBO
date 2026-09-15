// PROTECTED — CHANGE #238.
//
// The bug this file exists to prevent: a customer order of 18 items produced
// supplier purchase orders totalling 9. Items were lost in two ways, and both
// were INVISIBLE on screen.
//
//  1. Backend: the inquiry waterfall named the PREVIOUS supplier as the
//     responder, so an item whose current supplier had itself answered
//     "Available" carried the previous supplier's "Out of Stock". It was never
//     assigned, never reached a purchase order, and was never marked
//     unfulfillable — it simply was not there.
//  2. Frontend: the panel joined the orders.items JSONB to a status RPC by
//     normalised product NAME. A name that did not match lost its status and
//     its supplier and rendered a dash.
//
// So the contract this pins is: the panel renders the BACKEND's list, in the
// BACKEND's order, with the BACKEND's words — and the reconciliation banner is
// the backend's verdict, never a count done in Dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/models/order_item_panel_view.dart';

/// A payload shaped exactly like order_item_status_panel() returns, built from
/// the real 2026-08-17 order: one line already on a purchase order, one still
/// walking the supplier ladder, one that could not be sourced, and one in the
/// state that used to be silent — assigned to nobody, in no inquiry.
Map<String, dynamic> _payload() => <String, dynamic>{
      'ok': true,
      'count': 6,
      'lines': <dynamic>[
        <String, dynamic>{
          'product_name': 'Doberol Capsule',
          'state': 'supplier_assigned',
          'status_label': 'Available',
          'status_colors': <String, dynamic>{'bg': '#E1F5EE', 'fg': '#0F6E56'},
          'supplier_label': 'Accepted by UMA MEDICAL STORES',
          'has_supplier': true,
          'next_supplier_label': '',
          'po_warning': '',
          'qty_label': '8 Strips',
          'price_label': '₹93.75',
          'unfulfillable': false,
        },
        <String, dynamic>{
          'product_name': 'Cyblex S 60XR Tablet SR',
          'state': 'in_inquiry',
          'status_label': 'Confirmation Pending',
          'status_colors': <String, dynamic>{'bg': '#FEF3C7', 'fg': '#92400E'},
          'supplier_label': 'Asking Universal Pharma',
          'has_supplier': true,
          'next_supplier_label': 'Next: PRAKASH MEDICAL STORES',
          'po_warning': '',
          'qty_label': '3 Strips',
          'price_label': '',
          'unfulfillable': false,
        },
        <String, dynamic>{
          'product_name': 'Emessa E-Oil',
          'state': 'unfulfillable',
          'status_label': 'No supplier had stock',
          'status_colors': <String, dynamic>{'bg': '#FBE9E7', 'fg': '#B42318'},
          'supplier_label': 'No supplier yet',
          'has_supplier': false,
          'next_supplier_label': '',
          'po_warning': '',
          'qty_label': '5 Bottles',
          'price_label': '₹120.00',
          'unfulfillable': true,
        },
        <String, dynamic>{
          'product_name': 'Xtor 5 Tablet',
          'state': 'unaccounted',
          'status_label': 'Not accounted for',
          'status_colors': <String, dynamic>{'bg': '#FBE9E7', 'fg': '#B42318'},
          'supplier_label': '',
          'has_supplier': false,
          'next_supplier_label': '',
          'po_warning': '',
          'qty_label': '5 Strips',
          'price_label': '',
          'unfulfillable': false,
        },
        // Assigned, but the units never reached the supplier's purchase order —
        // the units-level form of "18 items, 9 on supplier orders". Only this
        // state carries po_warning; the backend emits it for nothing else.
        <String, dynamic>{
          'product_name': 'Olmy 40 Tablet',
          'state': 'supplier_assigned',
          'status_label': 'Available',
          'status_colors': <String, dynamic>{'bg': '#E1F5EE', 'fg': '#0F6E56'},
          'supplier_label': 'Accepted by BHARAT SALES',
          'has_supplier': true,
          'next_supplier_label': '',
          'po_warning': 'Not on the purchase order',
          'in_po': false,
          'qty_label': '3 Strips',
          'price_label': '₹42.00',
          'unfulfillable': false,
        },
        // Cancelled: no supplier badge, no "Asking X", no next supplier — the
        // ladder's live status must not leak onto a line nobody is working.
        <String, dynamic>{
          'product_name': 'Zanocin 100 Liquid',
          'state': 'cancelled',
          'status_label': 'Cancelled',
          'status_colors': <String, dynamic>{'bg': '#EFEEE9', 'fg': '#5A5A57'},
          'supplier_label': 'Cancelled',
          'has_supplier': false,
          'next_supplier_label': '',
          'po_warning': '',
          'qty_label': '2 Bottles',
          'price_label': '',
          'unfulfillable': false,
        },
      ],
      'reconcile': <String, dynamic>{
        'balanced': false,
        'show': true,
        'total': 5,
        'assigned': 2,
        'on_po': 1,
        'unfulfillable': 1,
        'in_inquiry': 1,
        'unaccounted': 1,
        'missing_po': 1,
        'label': '5 items — 1 on purchase orders, 1 assigned but not ordered, '
            '1 unfulfillable, 1 under inquiry, 1 unaccounted',
        'detail': '1 item(s) have no supplier, no inquiry and no unfulfillable '
            'reason. 1 assigned item(s) have not reached their supplier\'s '
            'purchase order.',
        'bg': '#FBE9E7',
        'fg': '#B42318',
        'border': '#B42318',
      },
    };

void main() {
  group('the panel renders the backend list, not one it builds', () {
    test('every line arrives, in payload order — nothing is dropped or sorted',
        () {
      final v = OrderItemPanelView.fromPayload(_payload());
      expect(v.loaded, isTrue);
      expect(v.lines.length, 6,
          reason: 'a dropped line is exactly the 18-vs-9 bug');
      // Deliberately NOT alphabetical: a client-side sort would reorder these.
      expect(v.lines.map((l) => l.productName).toList(), <String>[
        'Doberol Capsule',
        'Cyblex S 60XR Tablet SR',
        'Emessa E-Oil',
        'Xtor 5 Tablet',
        'Olmy 40 Tablet',
        'Zanocin 100 Liquid',
      ]);
    });

    test('a list payload (PostgREST single-row form) parses the same', () {
      final v = OrderItemPanelView.fromPayload(<dynamic>[_payload()]);
      expect(v.lines.length, 6);
      expect(v.loaded, isTrue);
    });
  });

  group('status and supplier are backend strings, printed verbatim', () {
    test('status_label is not re-worded and carries its own colours', () {
      final v = OrderItemPanelView.fromPayload(_payload());
      expect(v.lines[1].statusLabel, 'Confirmation Pending');
      expect(v.lines[1].statusColors['bg'], '#FEF3C7');
      expect(v.lines[1].statusColors['fg'], '#92400E');
    });

    test('the supplier phrase distinguishes accepted from being-asked, and the '
        'app assembles neither', () {
      final v = OrderItemPanelView.fromPayload(_payload());
      expect(v.lines[0].supplierLabel, 'Accepted by UMA MEDICAL STORES');
      expect(v.lines[1].supplierLabel, 'Asking Universal Pharma');
      expect(v.lines[0].hasSupplier, isTrue);
      expect(v.lines[1].hasSupplier, isTrue);
    });

    test('a line the backend gave no supplier for shows no supplier badge', () {
      final v = OrderItemPanelView.fromPayload(_payload());
      expect(v.lines[2].hasSupplier, isFalse,
          reason: 'has_supplier false must hide the badge');
      expect(v.lines[3].hasSupplier, isFalse,
          reason: 'an empty supplier_label must hide the badge, not print ""');
    });

    test('the next supplier and the missing-PO warning are backend strings and '
        'are absent when the backend withheld them', () {
      final v = OrderItemPanelView.fromPayload(_payload());
      expect(v.lines[1].nextSupplierLabel, 'Next: PRAKASH MEDICAL STORES');
      expect(v.lines[0].nextSupplierLabel, isEmpty);
      expect(v.lines[4].poWarning, 'Not on the purchase order',
          reason: 'assigned but the units never reached the PO');
      expect(v.lines[0].poWarning, isEmpty);
      expect(v.lines[3].poWarning, isEmpty,
          reason: 'unaccounted carries no PO warning — it was never assigned');
    });

    test('a field the backend omitted renders nothing — never "null"', () {
      final v = OrderItemPanelView.fromPayload(<String, dynamic>{
        'lines': <dynamic>[<String, dynamic>{'product_name': 'Bare Line'}],
        'reconcile': <String, dynamic>{},
      });
      final l = v.lines.single;
      expect(l.statusLabel, isEmpty);
      expect(l.supplierLabel, isEmpty);
      expect(l.priceLabel, isEmpty);
      expect(l.imageUrl, isEmpty);
      expect(l.hasSupplier, isFalse);
      expect(l.isFlagged, isFalse);
    });
  });

  group('nothing disappears silently', () {
    test('an unaccounted line is flagged red, exactly like an unfulfillable one',
        () {
      final v = OrderItemPanelView.fromPayload(_payload());
      expect(v.lines[2].isFlagged, isTrue, reason: 'unfulfillable');
      expect(v.lines[3].isFlagged, isTrue,
          reason: 'state=unaccounted is the item that used to vanish');
      expect(v.lines[0].isFlagged, isFalse);
      expect(v.lines[1].isFlagged, isFalse);
    });

    test('a cancelled line shows no supplier and no next supplier', () {
      final v = OrderItemPanelView.fromPayload(_payload());
      final cancelled = v.lines[5];
      expect(cancelled.state, 'cancelled');
      expect(cancelled.hasSupplier, isFalse,
          reason: 'nobody is being asked for a cancelled line');
      expect(cancelled.nextSupplierLabel, isEmpty);
      expect(cancelled.statusLabel, 'Cancelled',
          reason: 'the inquiry ladder status must not leak onto a dead line');
    });

    test('the banner is the backend verdict — the app counts nothing', () {
      final r = OrderItemPanelView.fromPayload(_payload()).reconcile;
      expect(r.show, isTrue);
      expect(r.balanced, isFalse);
      expect(
          r.label,
          '5 items — 1 on purchase orders, 1 assigned but not ordered, '
          '1 unfulfillable, 1 under inquiry, 1 unaccounted');
      expect(r.detail, contains('have no supplier'));
      expect(r.detail, contains('not reached their supplier'));
    });

    test('the banner names every bucket — its own numbers sum to its own total',
        () {
      // The first cut printed assigned + unfulfillable + in_inquiry and left
      // `unaccounted` out, so the sentence said "4 items — 1, 1, 1" while one
      // item was missing from its own summary. That is the same silence in
      // words that the pipeline had in data.
      final r = OrderItemPanelView.fromPayload(_payload()).reconcile.raw;
      final total = r['total'] as int;
      // The five buckets a non-cancelled item can be in. `assigned` is NOT one
      // of them — it is on_po + missing_po, and printing it instead of both hid
      // the items that were assigned and still never ordered.
      final parts = <String>[
        'on_po', 'missing_po', 'unfulfillable', 'in_inquiry', 'unaccounted'
      ];
      final sum = parts.fold<int>(0, (a, k) => a + (r[k] as int));
      expect(sum, total,
          reason: 'the banner buckets must partition the order, not sample it');
      for (final k in parts) {
        expect(r['label'].toString(), contains('${r[k]}'),
            reason: '$k is missing from the sentence');
      }
    });

    test('assigned counts the assignment; on_po counts what actually shipped to '
        'the supplier — they are not the same number', () {
      final r = OrderItemPanelView.fromPayload(_payload()).reconcile.raw;
      expect(r['assigned'], 2);
      expect(r['on_po'], 1);
      expect(r['missing_po'], 1);
      expect(OrderItemPanelView.fromPayload(_payload()).reconcile.balanced,
          isFalse,
          reason: 'an assigned item missing from its PO must break the balance');
    });

    test('a balanced order still shows the banner, with the backend\'s words',
        () {
      final p = _payload();
      p['reconcile'] = <String, dynamic>{
        'balanced': true,
        'show': true,
        'label': 'All 11 items accounted for',
        'detail': '',
      };
      final r = OrderItemPanelView.fromPayload(p).reconcile;
      expect(r.show, isTrue);
      expect(r.balanced, isTrue);
      expect(r.label, 'All 11 items accounted for');
      expect(r.detail, isEmpty);
    });

    test('show:false, or a banner with no words, draws nothing', () {
      expect(
          const OrderItemPanelReconcile(<String, dynamic>{
            'show': false,
            'label': 'ignored',
          }).show,
          isFalse);
      expect(
          const OrderItemPanelReconcile(<String, dynamic>{
            'show': true,
            'label': '   ',
          }).show,
          isFalse);
    });
  });

  group('a failure is not an empty order', () {
    test('an {error} reply is an error state, never "no items recorded"', () {
      final v = OrderItemPanelView.fromPayload(
          <String, dynamic>{'error': 'not_authorized'},
          errorFallback: 'Could not load this order\'s items.');
      expect(v.hasError, isTrue);
      expect(v.isEmpty, isFalse,
          reason: 'printing an empty order over a full one is the same lie '
              'this change exists to stop');
      expect(v.errorMessage, 'Could not load this order\'s items.');
      expect(v.loaded, isTrue, reason: 'answered — so stop the skeleton');
    });

    test('a thrown RPC lands a message and stops the skeleton', () {
      final v = OrderItemPanelView.failed('Could not load this order.');
      expect(v.hasError, isTrue);
      expect(v.loaded, isTrue);
      expect(v.isEmpty, isFalse);
      expect(v.lines, isEmpty);
      expect(v.reconcile.show, isFalse);
    });

    test('with no fallback copy, the backend error code is surfaced rather than '
        'swallowed', () {
      final v = OrderItemPanelView.fromPayload(
          <String, dynamic>{'error': 'not_authorized'});
      expect(v.errorMessage, 'not_authorized');
    });
  });

  group('loading is not emptiness', () {
    test('before the RPC answers, the panel is not loaded and not empty', () {
      const v = OrderItemPanelView.loading;
      expect(v.loaded, isFalse);
      expect(v.isEmpty, isFalse,
          reason: 'an expanding row must skeleton, not claim "no items"');
      expect(v.reconcile.show, isFalse);
    });

    test('a non-map reply is treated as still loading, never as an empty order',
        () {
      expect(OrderItemPanelView.fromPayload(null).loaded, isFalse);
      expect(OrderItemPanelView.fromPayload(<dynamic>[]).loaded, isFalse);
    });

    test('an order that really has no items reports empty once loaded', () {
      final v = OrderItemPanelView.fromPayload(
          <String, dynamic>{'lines': <dynamic>[], 'reconcile': <String, dynamic>{}});
      expect(v.loaded, isTrue);
      expect(v.isEmpty, isTrue);
    });
  });
}
