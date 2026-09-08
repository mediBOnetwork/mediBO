// CHANGE #529 — the eight approved medium/admin feature_gaps rows, pinned at
// the layer where each of them actually went wrong: the frontend computing, or
// failing to print, something the backend owns.
//
// Payloads are the REAL shapes the RPCs return, with the live numbers from the
// evidence on each row, so a regression here reads as the original bug.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/models/c529_admin_gaps.dart';

void main() {
  group('gap 16 — a bag prints the backend projection, never a Dart status', () {
    // bags_list() after the fix: the same bag that read status='empty' for 500
    // rows now projects 'filling' because order_items carry its bag_no.
    final filling = {
      'bag_no': 12,
      'bag_code': 'BAG012',
      'status': 'filling',
      'status_label': 'Filling',
      'status_bg': '#FEF3C7',
      'status_fg': '#92400E',
      'item_count': 9,
      'alloc_count': 0,
      'count_label': '9 items',
    };

    test('label, count and tone are the payload, not a computation', () {
      final v = BagRowView.from(filling);
      expect(v.statusLabel, 'Filling');
      expect(v.countLabel, '9 items');
      expect(c529Hex(v.statusBg, Colors.black), const Color(0xFFFEF3C7));
      expect(c529Hex(v.statusFg, Colors.black), const Color(0xFF92400E));
      expect(v.hasChip, isTrue);
    });

    test('a bag with items is NOT empty just because the column said so', () {
      // The gap exactly: 293 order_items sat in bags whose column read 'empty'.
      final v = BagRowView.from({...filling, 'status': 'filling', 'item_count': 9});
      expect(v.status, isNot('empty'));
      expect(v.itemCount, 9);
    });

    test('no label from the backend means no chip — never a default word', () {
      final v = BagRowView.from({'bag_no': 1, 'bag_code': 'BAG001'});
      expect(v.hasChip, isFalse);
      expect(v.statusLabel, isEmpty);
      expect(v.countLabel, isEmpty);
    });

    test('a malformed tone falls back instead of inventing a colour', () {
      expect(c529Hex('not-a-colour', const Color(0xFF123456)),
          const Color(0xFF123456));
      expect(c529Hex(null, const Color(0xFF123456)), const Color(0xFF123456));
    });
  });

  group('gap 38 — the supplier bucket is its own, with its own backend copy', () {
    // admin_missing_locations(): 8 of 35 approved suppliers had no lat/lng.
    final payload = {
      'allowed': true,
      'missing_count': 0,
      'title': '0 of 41 customers have no map location',
      'note': 'Deliveries cannot be mapped or routed until these have a pin.',
      'rows': const [],
      'supplier_missing_count': 8,
      'supplier_title': '8 of 35 suppliers have no map location',
      'supplier_note': 'A collect run cannot route to a shop with no pin.',
      'supplier_rows': [
        {'supplier_id': 'aaa', 'supplier_name': 'SAI GANESH PHARMA', 'address': 'Raipur'},
      ],
    };

    test('the banner opens on the supplier bucket alone', () {
      final v = MissingLocationsView.from(payload);
      expect(v.rows, isEmpty);
      expect(v.hasSupplierBucket, isTrue);
      expect(v.hasAnything, isTrue, reason: 'a supplier with no pin is as unroutable as a customer');
    });

    test('both titles print verbatim and are never merged in Dart', () {
      final v = MissingLocationsView.from(payload);
      expect(v.supplierTitle, '8 of 35 suppliers have no map location');
      expect(v.supplierNote, 'A collect run cannot route to a shop with no pin.');
      expect(v.title, isNot(v.supplierTitle));
    });

    test('a supplier row saves through the supplier RPC and its own id key', () {
      expect(MissingLocationsView.rpcFor(isSupplier: true), 'admin_supplier_set_location');
      expect(MissingLocationsView.rpcFor(isSupplier: false), 'pharmacy_set_location');
      expect(MissingLocationsView.idKeyFor(isSupplier: true), 'p_supplier_id');
      expect(MissingLocationsView.idKeyFor(isSupplier: false), 'p_pharmacy_id');
    });

    test('no supplier rows is an absence, not an empty section', () {
      final v = MissingLocationsView.from({'title': 't', 'rows': const []});
      expect(v.hasSupplierBucket, isFalse);
      expect(v.hasAnything, isFalse);
      expect(v.supplierMissingCount, 0);
    });
  });

  group('gap 21 — bills that resolve to no supplier are their own bucket', () {
    test('the tile shows with the BACKEND label, never a Dart string', () {
      final v = UnresolvedBillsTile.from({
        'unresolved_bills': 1,
        'unresolved_bills_label': 'Bills with no supplier',
      });
      expect(v.show, isTrue);
      expect(v.label, 'Bills with no supplier');
      expect(v.count, 1);
    });

    test('a count with no backend label renders nothing', () {
      // Writing the word here would be the bug this row exists for.
      expect(UnresolvedBillsTile.from({'unresolved_bills': 3}).show, isFalse);
    });

    test('zero unresolved bills hides the tile', () {
      expect(UnresolvedBillsTile.from({
        'unresolved_bills': 0,
        'unresolved_bills_label': 'Bills with no supplier',
      }).show, isFalse);
    });
  });

  group('gap 13 — a zone-scoped list reports what it hid', () {
    test('the hidden note is the backend sentence, with the count in it', () {
      final v = ScopeHiddenNote.from({
        'hidden_by_scope': 20,
        'hidden_note': '20 hidden by your zone scope (Raipur).',
      });
      expect(v.show, isTrue);
      expect(v.note, '20 hidden by your zone scope (Raipur).');
    });

    test('an unscoped admin hides nothing and shows no note', () {
      final v = ScopeHiddenNote.from({'hidden_by_scope': 0, 'hidden_note': null});
      expect(v.show, isFalse);
      expect(v.hidden, 0);
    });
  });

  group('gap 36/37 — a dispute ages, and its reminder is a backend action', () {
    // The one dispute ever raised: created 2026-07-24, never reminded.
    final aged = {
      'dispute_id': '96bc7e44-140d-4626-8704-d52b7954f74b',
      'is_active': true,
      'waited_hours': 931,
      'waited_label': 'waiting 38d · overdue',
      'breached': true,
      'escalate': true,
      'reminder_label': 'Not reminded yet',
      'age_chip': {'label': 'waiting 38d · overdue', 'bg': '#FEE2E2', 'fg': '#991B1B'},
      'admin_actions': [
        {'code': 'resolve', 'label': 'Resolve', 'note_required': true, 'primary': true},
        {'code': 'short_reminder', 'label': 'Send short-supply reminder',
         'note_required': false, 'primary': true},
      ],
    };

    test('the waited label and its tone print verbatim', () {
      final v = DisputeAgeView.from(aged);
      expect(v.waitedLabel, 'waiting 38d · overdue');
      expect(v.breached, isTrue);
      expect(v.escalate, isTrue);
      expect(c529Hex(v.ageChip!['bg'], Colors.black), const Color(0xFFFEE2E2));
    });

    test('"Not reminded yet" is the backend sentence, not an if on null', () {
      expect(DisputeAgeView.from(aged).reminderLabel, 'Not reminded yet');
    });

    test('the reminder button exists because the payload carries the action', () {
      final v = DisputeAgeView.from(aged);
      expect(v.hasShortReminder, isTrue);
      expect(v.shortReminderLabel, 'Send short-supply reminder');
    });

    test('an active dispute with no such action offers no button', () {
      // Before this change fw_send_supplier_short_reminder had ZERO callers;
      // the button must never be synthesised from is_active in Dart.
      final v = DisputeAgeView.from({
        ...aged,
        'admin_actions': [
          {'code': 'resolve', 'label': 'Resolve', 'note_required': true},
        ],
      });
      expect(v.hasShortReminder, isFalse);
      expect(v.shortReminderLabel, isEmpty);
    });

    test('a fresh dispute is neither breached nor escalated', () {
      final v = DisputeAgeView.from({
        'waited_hours': 2,
        'waited_label': 'waiting 2h',
        'breached': false,
        'escalate': false,
        'reminder_label': 'Not reminded yet',
        'age_chip': {'label': 'waiting 2h', 'bg': '#EFF6FF', 'fg': '#1E40AF'},
        'admin_actions': const [],
      });
      expect(v.breached, isFalse);
      expect(v.escalate, isFalse);
      expect(v.waitedLabel, 'waiting 2h');
    });
  });
}
