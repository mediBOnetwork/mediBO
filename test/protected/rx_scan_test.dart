// CMD #418 — the prescription counter decides nothing, and OCR never bills.
//
// What this holds down, permanently:
//   * a line is on the bill because the BACKEND said default_on, and default_on
//     is true only for a line the shop can actually fill — an unreadable line,
//     an unmatched line and a substitute line all start unticked, so the human
//     has to make each of those decisions on purpose;
//   * the paper's own words are on screen next to whatever was matched, always,
//     because that is the only way the counter can check one against the other;
//   * a read FAILURE shows the backend's sentence — never the technical error.
//     The first live failure put a 900-character Google billing JSON on the
//     till screen; this test is why it cannot come back;
//   * the confirm sends only TICKED lines with a positive quantity, and sends
//     the substitute's medicine_id when the human swapped one in;
//   * every rupee, state word, tone and "Oldest batch first" is printed
//     verbatim — the fixture carries a margin that no arithmetic here could
//     produce;
//   * a refusal renders the backend copy with no Retry: it is an answer.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/screens/pharmacy/rx_scan_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _draft({bool reading = false, String failed = ''}) => {
  'ok': true,
  'scan_id': 'scan-1',
  'status': reading ? 'reading' : 'draft',
  'is_draft': !reading && failed.isEmpty,
  'is_reading': reading,
  'title': 'Prescription',
  'photo_title': 'The prescription',
  'draft_title': 'Draft bill',
  'check_note': 'Check every line against the photo before you confirm.',
  'legal_note': 'The photo is kept against this bill as the prescription record.',
  'reading': 'Reading the prescription…',
  'reading_hint': 'This takes a few seconds.',
  'confirm_button': 'Confirm and bill',
  'confirming': 'Billing…',
  'empty': 'Nothing could be read from this photo.',
  'empty_hint': 'Take the photo again in better light.',
  'failed_message': failed.isEmpty ? null : failed,
  'has_lines': !reading && failed.isEmpty,
  'image': {'has': false, 'bucket': 'rx-scans', 'path': null},
  'poll_ms': 2000,
  'confirmed': false,
  'lines': reading || failed.isNotEmpty
      ? const []
      : [
          {
            'line_id': 'l1',
            'seen_label': 'Written as',
            'seen_text': 'Tab. Isojol',
            'seen_detail': '1-0-1 · 5 days',
            'readable': true,
            'match_kind': 'in_stock',
            'state_label': 'On your shelf',
            'tone': 'success',
            'product_name': 'Isojol Tablet',
            'batch_label': 'Batch C418B',
            'batch_no': 'C418B',
            'expiry_label': 'Expiry 01/2027',
            'fefo_note': 'Oldest batch first',
            'on_hand_label': 'In stock 15',
            'qty': 10,
            'qty_label': 'Qty',
            'qty_basis': 'From the prescription: 1-0-1 x 5 days = 10',
            'default_on': true,
            'medicine_id': 473032,
            'confidence': 'high',
            'substitutes': const [],
          },
          {
            'line_id': 'l2',
            'seen_label': 'Written as',
            'seen_text': 'Tab. Molmat 650',
            'readable': true,
            'match_kind': 'substitute',
            'state_label': 'Not in stock',
            'tone': 'warning',
            'product_name': 'Molmat 650 Tablet',
            'qty': 9,
            'qty_label': 'Qty',
            'default_on': false,
            'medicine_id': 177280,
            'confidence': 'high',
            'substitutes_title': 'In stock, same salt',
            'substitutes': [
              {
                'stock_id': 'st-9',
                'medicine_id': 255470,
                'product_name': 'Paracad 150mg Injection',
                'on_hand_label': '60',
                'mrp_display': '₹16.00',
                'margin_display': '₹5.00',
                'pick_label': 'Use this instead',
              },
            ],
          },
          {
            'line_id': 'l3',
            'seen_label': 'Written as',
            'seen_text': 'Rmnptqllne 40',
            'readable': false,
            'match_kind': 'unmatched',
            'state_label': 'Could not be read',
            'state_hint': 'The handwriting could not be read. '
                'It has not been guessed.',
            'tone': 'danger',
            'qty_label': 'Qty',
            'default_on': false,
            'confidence': 'low',
            'confidence_note': 'Low confidence — check this line',
            'substitutes': const [],
          },
        ],
};

/// The draft is a tall page — photo, three line cards, substitutes, then the
/// confirm button. The default 800x600 test surface cuts it off, so give the
/// test a counter-sized one; 880 keeps the NARROW (stacked) layout, which is
/// the harder of the two to get right.
Future<void> _pump(WidgetTester t, Widget child) async {
  await t.binding.setSurfaceSize(const Size(880, 2400));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(home: child));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    Ds.apply(const {});
  });

  group('the draft is the payload, and the human owns it', () {
    testWidgets('only a line the shop can fill starts ticked', (t) async {
      await _pump(
        t,
        RxDraftScreen(scanId: 'scan-1', rpc: (fn, p) async => _draft()),
      );
      final boxes = t
          .widgetList<Checkbox>(find.byType(Checkbox))
          .map((c) => c.value)
          .toList();
      expect(boxes.length, 3);
      expect(boxes[0], isTrue);   // in_stock
      expect(boxes[1], isFalse);  // substitute — a deliberate decision
      expect(boxes[2], isFalse);  // unreadable — never pre-ticked
    });

    testWidgets('the paper words sit beside whatever was matched', (t) async {
      await _pump(
        t,
        RxDraftScreen(scanId: 'scan-1', rpc: (fn, p) async => _draft()),
      );
      expect(find.text('Written as: Tab. Isojol'), findsOneWidget);
      expect(find.text('Isojol Tablet'), findsOneWidget);
      // The unreadable line keeps its characters and gains no product name.
      expect(find.text('Written as: Rmnptqllne 40'), findsOneWidget);
      expect(
        find.text('The handwriting could not be read. It has not been guessed.'),
        findsOneWidget,
      );
    });

    testWidgets('backend strings print verbatim, including the margin', (
      t,
    ) async {
      await _pump(
        t,
        RxDraftScreen(scanId: 'scan-1', rpc: (fn, p) async => _draft()),
      );
      expect(find.text('Oldest batch first'), findsOneWidget);
      expect(find.text('On your shelf'), findsOneWidget);
      expect(find.text('Batch C418B · Expiry 01/2027'), findsOneWidget);
      // ₹5.00 is the payload's; nothing on this screen could compute it.
      expect(find.text('₹5.00'), findsOneWidget);
      expect(find.text('Low confidence — check this line'), findsOneWidget);
    });

    testWidgets('a read failure shows the backend sentence, not the error', (
      t,
    ) async {
      await _pump(
        t,
        RxDraftScreen(
          scanId: 'scan-1',
          rpc: (fn, p) async => _draft(
            failed: 'The photo could not be read. '
                'Take it again, or bill it by hand.',
          ),
        ),
      );
      expect(
        find.text(
          'The photo could not be read. Take it again, or bill it by hand.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('BILLING_DISABLED'), findsNothing);
      expect(find.textContaining('403'), findsNothing);
    });

    testWidgets('while it is reading, the backend copy holds the screen', (
      t,
    ) async {
      await _pump(
        t,
        RxDraftScreen(
          scanId: 'scan-1',
          rpc: (fn, p) async => _draft(reading: true),
        ),
      );
      expect(find.text('Reading the prescription…'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
    });
  });

  group('confirming', () {
    testWidgets('sends only ticked lines with a positive quantity', (t) async {
      List<Map<String, dynamic>> sent = const [];
      await _pump(
        t,
        RxDraftScreen(
          scanId: 'scan-1',
          rpc: (fn, p) async {
            if (fn == 'rx_scan_confirm') {
              sent = (p['p_lines'] as List)
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList();
              return {'ok': true, 'rx_toast': 'Bill saved'};
            }
            return _draft();
          },
        ),
      );
      await t.tap(find.text('Confirm and bill'));
      await t.pumpAndSettle();

      // Only the in-stock line was ticked, and only it had a quantity.
      expect(sent.length, 1);
      expect(sent.first['medicine_id'], 473032);
      expect(sent.first['qty'], 10);
      expect(sent.first['batch_no'], 'C418B');
    });

    testWidgets('a chosen substitute is what gets billed', (t) async {
      List<Map<String, dynamic>> sent = const [];
      await _pump(
        t,
        RxDraftScreen(
          scanId: 'scan-1',
          rpc: (fn, p) async {
            if (fn == 'rx_scan_confirm') {
              sent = (p['p_lines'] as List)
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList();
              return {'ok': true, 'rx_toast': 'Bill saved'};
            }
            return _draft();
          },
        ),
      );
      await t.tap(find.text('Paracad 150mg Injection'));
      await t.pumpAndSettle();
      await t.tap(find.text('Confirm and bill'));
      await t.pumpAndSettle();

      // The swapped line carries the SUBSTITUTE's medicine_id, not the one the
      // prescription named — and no batch, because it is a different row.
      expect(sent.any((e) => e['medicine_id'] == 255470), isTrue);
      expect(sent.any((e) => e['medicine_id'] == 177280), isFalse);
    });

    testWidgets('nothing ticked means the button cannot be pressed', (t) async {
      final payload = _draft();
      for (final l in (payload['lines'] as List)) {
        (l as Map)['default_on'] = false;
      }
      await _pump(
        t,
        RxDraftScreen(scanId: 'scan-1', rpc: (fn, p) async => payload),
      );
      final btn = t.widget<FilledButton>(find.byType(FilledButton).last);
      expect(btn.onPressed, isNull);
    });
  });

  testWidgets('a refusal prints the backend copy and offers no Retry', (
    t,
  ) async {
    await _pump(
      t,
      RxScanScreen(
        rpc: (fn, p) async => {
          'ok': false,
          'error': 'not_a_pharmacy',
          'message': 'The prescription scanner is available on a pharmacy account.',
        },
      ),
    );
    expect(
      find.text('The prescription scanner is available on a pharmacy account.'),
      findsOneWidget,
    );
    expect(find.byType(OutlinedButton), findsNothing);
  });
}
