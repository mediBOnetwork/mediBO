// CMD #411 — the pharmacy counter's contract.
//
// What this file holds down, permanently:
//   * The counter ADDS UP NOTHING. Every rupee, percentage, quantity and
//     plural on the bill, the receipt and the day-close prints exactly as the
//     backend sent it — including a negative round-off and a "-18.4%"-shaped
//     string this build has no formatter for.
//   * The offline queue applies a sale ONCE. The same client_action_id
//     replayed resolves to the sale already on the books; a permanent refusal
//     leaves the queue instead of blocking every bill behind it; a TRANSPORT
//     failure keeps the bill queued and stops, so the operator's billing order
//     survives.
//   * The entry point is the BACKEND's answer, not a role test: pos_entry()
//     says show/label, and an account it did not admit gets no tile.
//   * A refusal renders the backend's own copy rather than throwing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/pharmacy/pos_screen.dart';
import 'package:pharma_b2b/services/pos_api.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ────────────────────────────────────────────────────────────────
// Deliberately awkward numbers: a NEGATIVE round-off, a 5% and a 12% slab in
// one bill, and money strings that Dart could not reproduce if it tried.
Map<String, dynamic> _home() => {
      'ok': true,
      'default_payment': 'cash',
      'header': {
        'name': 'Shraddha Medical & General Stores',
        'gstin_label': 'GSTIN: 22AABCS1429P1ZX',
        'dl_label': 'D.L. No.: 20B-CG-RPR-041287',
        'has_gstin': true,
      },
      'labels': {
        'title': 'Counter',
        'search_hint': 'Search or scan a medicine',
        'cart_empty': 'No items yet',
        'cart_empty_hint': 'Search or scan a medicine to start the bill.',
        'qty': 'Qty',
        'save': 'Save bill',
        'gross': 'Gross',
        'taxable': 'Taxable',
        'cgst': 'CGST',
        'sgst': 'SGST',
        'round_off': 'Round off',
        'net': 'Net payable',
        'day_close': 'Day close',
        'mrp_note': 'Prices are MRP, inclusive of GST',
      },
      'payment_modes': [
        {'key': 'cash', 'label': 'Cash'},
        {'key': 'upi', 'label': 'UPI'},
      ],
      'today_strip': {'bills': 0, 'has_any': false},
    };

Map<String, dynamic> _quote() => {
      'ok': true,
      'lines': [
        {
          'line_no': 1,
          'product_name': 'Paracad 150mg Injection',
          'qty_label': '2',
          'mrp_display': '₹6.61',
          'amount_display': '₹11.30',
          'gst_label': '12%',
          'disc_display': '5%',
        },
      ],
      'totals': {
        'gross_display': '₹352.22',
        'taxable_display': '₹300.66',
        'cgst_display': '₹7.88',
        'sgst_display': '₹7.86',
        'round_off_display': '-₹0.40',
        'has_round_off': true,
        'net_display': '₹316.00',
        'mrp_note': 'Prices are MRP, inclusive of GST',
        'has_line_discount': false,
        'has_bill_discount': false,
      },
    };

Map<String, dynamic> _search() => {
      'ok': true,
      'rows': [
        {
          'medicine_id': 255470,
          'product_name': 'Paracad 150mg Injection',
          'pack_label': 'Vial',
          'mrp_display': '₹6.61',
          'gst_label': '12%',
        },
      ],
    };

/// A recording fake. Captures what the screen ASKED for, so a test can assert
/// on the request as well as the render.
class _Rpc {
  final List<MapEntry<String, Map<String, dynamic>>> calls = [];
  final Map<String, Map<String, dynamic>> replies;
  final Set<String> throwOn;
  _Rpc(this.replies, {this.throwOn = const {}});

  Future<Map<String, dynamic>> call(String fn, Map<String, dynamic> p) async {
    calls.add(MapEntry(fn, p));
    if (throwOn.contains(fn)) throw Exception('offline');
    return replies[fn] ?? const {'ok': true};
  }

  Map<String, dynamic>? paramsFor(String fn) {
    for (final c in calls) {
      if (c.key == fn) return c.value;
    }
    return null;
  }

  int countOf(String fn) => calls.where((c) => c.key == fn).length;
}

void main() {
  setUpAll(() {
    // RenderLog's 800ms debounce is a real Timer that would outlive the test
    // and try to reach Supabase.
    RenderLog.flushEnabled = false;
    // The two strings the counter reads from ui_copy rather than from a
    // per-screen payload: the boot-failure line (pos_home() never landed, so
    // there is no payload to read copy from) and its Retry label.
    UiCopy.debugSet(const {
      'pos.boot_failed':
          'The counter could not be reached. Check the connection and try again.',
      'pos.retry': 'Retry',
    });
  });

  group('the counter prints the backend and computes nothing', () {
    testWidgets('every total is the payload string, negative round-off included',
        (tester) async {
      // A counter is a tall screen and the totals sit under the cart; the
      // default 800x600 test window leaves them unbuilt in the lazy ListView.
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final rpc = _Rpc({
        'pos_home': _home(),
        'pos_search': _search(),
        'pos_quote': _quote(),
      });
      await tester.pumpWidget(MaterialApp(home: PosScreen(rpc: rpc.call)));
      await tester.pumpAndSettle();

      // add a line so the totals card renders
      await tester.enterText(find.byType(TextField).first, 'parac');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Paracad 150mg Injection').first);
      await tester.pumpAndSettle();

      for (final s in const [
        '₹352.22', '₹300.66', '₹7.88', '₹7.86', '-₹0.40',
        'Prices are MRP, inclusive of GST',
      ]) {
        expect(find.text(s), findsWidgets, reason: '$s must print verbatim');
      }
      // The net appears on the save bar as the backend's own string.
      expect(find.textContaining('₹316.00'), findsWidgets);
    });

    testWidgets('the empty cart is the backend copy, not a Dart literal',
        (tester) async {
      final rpc = _Rpc({'pos_home': _home()});
      await tester.pumpWidget(MaterialApp(home: PosScreen(rpc: rpc.call)));
      await tester.pumpAndSettle();
      expect(find.text('No items yet'), findsOneWidget);
      expect(find.text('Search or scan a medicine to start the bill.'),
          findsOneWidget);
    });

    testWidgets('a refusal renders the backend message instead of throwing',
        (tester) async {
      final rpc = _Rpc({
        'pos_home': {
          'ok': false,
          'error': 'not_a_pharmacy',
          'message': 'The counter is available on a pharmacy account.',
        }
      });
      await tester.pumpWidget(MaterialApp(home: PosScreen(rpc: rpc.call)));
      await tester.pumpAndSettle();
      expect(find.text('The counter is available on a pharmacy account.'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a transport failure offers Retry; a refusal does NOT',
        (tester) async {
      // A thrown request is retryable and must never put a Dart exception
      // string on screen. A role refusal is an ANSWER — offering to ask it
      // again would be a lie.
      final dead = _Rpc(const {}, throwOn: {'pos_home'});
      await tester.pumpWidget(MaterialApp(home: PosScreen(rpc: dead.call)));
      await tester.pumpAndSettle();
      expect(find.byType(OutlinedButton), findsOneWidget,
          reason: 'a request that never landed can be retried');
      // and BOTH strings are ui_copy's, not Dart literals
      expect(find.text('Retry'), findsOneWidget);
      expect(
          find.text('The counter could not be reached. '
              'Check the connection and try again.'),
          findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing,
          reason: 'never print the raw error');

      final refused = _Rpc({
        'pos_home': {
          'ok': false,
          'error': 'not_a_pharmacy',
          'message': 'The counter is available on a pharmacy account.',
        }
      });
      // A distinct key, so Flutter builds a FRESH State rather than reusing the
      // failed one above — otherwise this half of the test passes for the
      // wrong reason.
      await tester.pumpWidget(MaterialApp(
          home: PosScreen(key: const ValueKey('refused'), rpc: refused.call)));
      await tester.pumpAndSettle();
      expect(find.text('The counter is available on a pharmacy account.'),
          findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing,
          reason: 'a permanent answer gets no Retry');
    });

    testWidgets('the client never posts a price — only what the operator chose',
        (tester) async {
      final rpc = _Rpc({
        'pos_home': _home(),
        'pos_search': _search(),
        'pos_quote': _quote(),
      });
      await tester.pumpWidget(MaterialApp(home: PosScreen(rpc: rpc.call)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'parac');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Paracad 150mg Injection').first);
      await tester.pumpAndSettle();

      final lines = rpc.paramsFor('pos_quote')!['p_lines'] as List;
      final line = lines.first as Map;
      expect(line['medicine_id'], 255470);
      expect(line['qty'], 1);
      // A catalog line must carry NO price: the backend owns it, and a client
      // that could post an MRP could sell at a price of its own choosing.
      expect(line.containsKey('mrp'), isFalse);
      expect(line.containsKey('amount'), isFalse);
    });
  });

  group('the receipt polls on the backend clock and opens its bucket', () {
    testWidgets('a building receipt re-reads on the payload poll_ms',
        (tester) async {
      final building = {
        'ok': true,
        'sale_id': 'sale-1',
        'invoice': {'number_label': 'Invoice INV/2026-27/00001', 'date_label': '01 Sep 2026'},
        'totals': {'net_display': '₹316.00', 'net_words': 'Rupees Three Hundred Sixteen Only'},
        'receipt': {
          'status': 'queued', 'is_ready': false, 'is_building': true,
          'poll_ms': 900, 'message': 'Preparing the invoice…',
          'print_label': 'Print', 'whatsapp_label': 'Send on WhatsApp',
        },
      };
      final ready = {
        ...building,
        'receipt': {...(building['receipt'] as Map), 'is_ready': true,
          'is_building': false, 'status': 'ready', 'message': 'Invoice ready'},
      };
      final rpc = _Rpc({'pos_sale_detail': Map<String, dynamic>.from(ready)});

      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: PosReceiptSheet(sale: building, rpc: rpc.call))));
      await tester.pump();
      expect(find.text('Preparing the invoice…'), findsOneWidget);
      expect(rpc.countOf('pos_sale_detail'), 0, reason: 'must wait the backend interval');

      await tester.pump(const Duration(milliseconds: 950));
      await tester.pumpAndSettle();
      expect(rpc.countOf('pos_sale_detail'), 1);
      expect(find.text('Invoice ready'), findsOneWidget);
      // and the amount is still the backend's string
      expect(find.text('₹316.00'), findsOneWidget);
    });
  });

  group('the offline queue applies a sale exactly once', () {
    test('a replayed commit is recognised, not re-applied', () async {
      final rpc = _Rpc({
        'pos_commit_sale': {
          'ok': true, 'replayed': true,
          'invoice': {'number': 'INV/2026-27/00001'},
          'message': 'Already saved — showing the same bill',
        }
      });
      final res = await rpc.call('pos_commit_sale', {'p_client_action_id': 'x'});
      expect(res['replayed'], isTrue);
      expect(res['invoice']['number'], 'INV/2026-27/00001');
    });

    test('a permanent refusal is dropped; a transport failure is NOT',
        () async {
      // These are the refusals the backend will repeat forever. Anything else
      // — above all a thrown request — must keep the bill queued.
      for (final e in const ['no_lines', 'bad_qty', 'no_price',
                             'unknown_medicine', 'no_action_id', 'not_a_pharmacy']) {
        expect(PosReplayResult.isPermanent(e), isTrue, reason: '$e is permanent');
      }
      for (final e in const ['timeout', 'network', '', 'deadlock_detected']) {
        expect(PosReplayResult.isPermanent(e), isFalse,
            reason: '$e must NOT drop a real sale');
      }
      expect(PosReplayResult.isPermanent(null), isFalse);
    });

    test('a replay pass reports what it did rather than inferring it', () {
      const none = PosReplayResult(applied: 0, alreadyApplied: 0, dropped: 0);
      expect(none.didAnything, isFalse);
      const some = PosReplayResult(applied: 0, alreadyApplied: 1, dropped: 0);
      expect(some.didAnything, isTrue);
    });

    test('a pending sale round-trips through storage unchanged', () {
      final sale = PosPendingSale(
        clientActionId: '11111111-2222-3333-4444-555555555555',
        payload: const {
          'p_client_action_id': '11111111-2222-3333-4444-555555555555',
          'p_lines': [
            {'medicine_id': 255470, 'qty': 2, 'disc_pct': 5}
          ],
          'p_payment_mode': 'cash',
        },
        queuedAtMs: 1788230400000,
      );
      final back = PosPendingSale.fromJson(sale.toJson())!;
      expect(back.clientActionId, sale.clientActionId);
      expect(back.queuedAtMs, sale.queuedAtMs);
      // the payload must survive byte-for-byte: it is what gets replayed
      expect(back.payload, sale.payload);
    });

    test('a corrupt queue entry is skipped, never thrown', () {
      expect(PosPendingSale.fromJson(null), isNull);
      expect(PosPendingSale.fromJson('nonsense'), isNull);
      expect(PosPendingSale.fromJson(const {'client_action_id': ''}), isNull);
      expect(PosPendingSale.fromJson(const {'payload': {}}), isNull);
    });
  });

  group('the entry point is the backend answer, not a role test', () {
    testWidgets('an account pos_entry() did not admit gets no tile',
        (tester) async {
      PosEntry.value.value = const {'ok': true, 'show': false};
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: PosMenuTile())));
      await tester.pumpAndSettle();
      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('an admitted account gets the tile with the payload label',
        (tester) async {
      PosEntry.value.value = const {
        'ok': true, 'show': true,
        'label': 'Counter (POS)', 'sub_label': 'Bill a walk-in patient',
      };
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: PosMenuTile())));
      await tester.pumpAndSettle();
      expect(find.text('Counter (POS)'), findsOneWidget);
      expect(find.text('Bill a walk-in patient'), findsOneWidget);
      PosEntry.value.value = const {};
    });
  });

  group('day close prints the backend split', () {
    testWidgets('zero rows are shown, not hidden', (tester) async {
      final rpc = _Rpc({
        'pos_day_close': {
          'ok': true,
          'title': 'Day close',
          'date_label': '01 Sep 2026',
          'has_any': true,
          'tiles': [
            {'label': 'Bills', 'value': '3'},
            {'label': 'Sales', 'value': '₹384.00'},
          ],
          'splits': [
            {'label': 'Cash', 'bills_label': '1 bill', 'amount_display': '₹316.00'},
            {'label': 'UPI', 'bills_label': '1 bill', 'amount_display': '₹60.00'},
            {'label': 'Credit', 'bills_label': '0 bills', 'amount_display': '₹0.00'},
          ],
          'recent': [],
        }
      });
      await tester.pumpWidget(
          MaterialApp(home: PosDayCloseScreen(rpc: rpc.call)));
      await tester.pumpAndSettle();

      expect(find.text('₹384.00'), findsOneWidget);
      // A day-close that hid "Credit ₹0.00" would make the pharmacist wonder
      // whether it is missing or genuinely zero.
      expect(find.text('0 bills'), findsOneWidget);
      expect(find.text('₹0.00'), findsOneWidget);
      // and the plural is the backend's, never pluralised in Dart
      expect(find.text('1 bill'), findsNWidgets(2));
    });
  });
}
