// PROTECTED — COUNT MODE.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the unified Count-mode behaviour.
//
// Drives the real BarcodeCountLogic against fabricated payloads, plus
// CountVoiceBar against fabricated CountVoiceStatus. No camera, no mic, no
// network, no Supabase.
//
// The properties that must never regress:
//   1. p_raw is the scanned string EXACTLY as detected — both RPC families
//      (gs1_parse in the backend owns ALL decoding)
//   2. a skipped commit (duplicate_serial | duplicate_scan | voice_merged)
//      renders the backend message verbatim, updates counted_qty, keeps the
//      previous progress_label, and never sets anyCommitted
//   3. gs1 batch / expiry_label / expiry_warning render verbatim from the
//      lookup payload; the commit response's expiry_warning is kept verbatim
//   4. teach: unknown_barcode + can_teach → medicine_set_barcode with the
//      backend's own teach_barcode → the SAME raw code is looked up again;
//      barcode_taken renders its message verbatim and keeps the teach open
//   5. no_active_bag renders the backend's title + message verbatim
//   6. CountVoiceBar renders every status string verbatim, nothing when
//      unsupported, and error wins over hint

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/fulfill/barcode_count_logic.dart';
import 'package:pharma_b2b/fulfill/count_voice_bar.dart';
import 'package:pharma_b2b/fulfill/count_voice_hooks.dart';

class _Call {
  final String fn;
  final Map<String, dynamic> params;
  _Call(this.fn, this.params);
  @override
  String toString() => '$fn($params)';
}

Map<String, dynamic> _lookupOk({
  required int productId,
  required String name,
  Map<String, dynamic>? gs1,
  Map<String, dynamic>? expiryWarning,
}) =>
    {
      'ok': true,
      'product_id': productId,
      'product_name': name,
      'image_url': '',
      'pack_label': '10 tablets',
      'company': 'Micro Labs',
      'progress_label': '3 of 10 counted',
      'bag_label': '',
      'bag_warning': false,
      'counted_qty': 3,
      if (gs1 != null) 'gs1': gs1,
      if (expiryWarning != null) 'expiry_warning': expiryWarning,
    };

({BarcodeCountLogic logic, List<_Call> calls}) _harness({
  required Map<String, dynamic> Function(String fn, Map<String, dynamic> p)
      respond,
  bool isPack = false,
}) {
  final calls = <_Call>[];
  final logic = BarcodeCountLogic(
    isPack: isPack,
    supplierName: 'Acme Pharma',
    stage: 'warehouse',
    orderId: isPack ? 'order-1' : null,
    sessionKey: 'k',
    dateYmd: () => '2026-08-09',
    rpc: (fn, params) async {
      calls.add(_Call(fn, params));
      return respond(fn, params);
    },
    errorText: (e) => 'LOCAL_ERROR_TEXT',
    messageForCode: (code) => 'LOCAL_MESSAGE_FOR_$code',
  );
  return (logic: logic, calls: calls);
}

void main() {
  group('p_raw is the scan, verbatim — the backend owns all decoding', () {
    // A real GS1 DataMatrix raw string, FNC1 group separators included.
    const gs1Raw = '01089012345678901724063010BATCH42\u{1D}21SER001';

    test('supplier commit sends p_raw exactly as detected', () async {
      final h = _harness(
        respond: (fn, p) => fn == 'barcode_lookup'
            ? _lookupOk(productId: 1, name: 'X')
            : {'ok': true, 'counted_qty': 4, 'progress_label': 'x'},
      );

      await h.logic.handleCode(gs1Raw);
      await h.logic.commit();

      final submit = h.calls.last;
      expect(submit.fn, 'barcode_submit_scan');
      expect(submit.params['p_raw'], gs1Raw,
          reason: 'no stripping, no GTIN extraction — gs1_parse owns it');
    });

    test('pack commit sends p_raw exactly as detected', () async {
      final h = _harness(
        isPack: true,
        respond: (fn, p) => fn == 'pack_barcode_lookup'
            ? _lookupOk(productId: 1, name: 'X')
            : {'ok': true, 'counted_qty': 4, 'progress_label': 'x'},
      );

      await h.logic.handleCode(gs1Raw);
      await h.logic.commit();

      final submit = h.calls.last;
      expect(submit.fn, 'pack_barcode_submit_scan');
      expect(submit.params['p_raw'], gs1Raw);
    });
  });

  group('skipped commits render the backend message verbatim', () {
    for (final skip in ['duplicate_serial', 'duplicate_scan', 'voice_merged']) {
      test(skip, () async {
        final h = _harness(
          respond: (fn, p) => fn == 'barcode_lookup'
              ? _lookupOk(productId: 1, name: 'X')
              : {
                  'ok': true,
                  'skipped': skip,
                  'message': 'BACKEND SAYS: $skip happened.',
                  'counted_qty': 7,
                },
        );

        await h.logic.handleCode('CODE');
        final labelBefore = h.logic.progressLabel;
        final seqBefore = h.logic.commitSeq;
        await h.logic.commit();

        expect(h.logic.skipped, skip);
        expect(h.logic.skippedMessage, 'BACKEND SAYS: $skip happened.');
        expect(h.logic.skippedMessage, isNot(contains('LOCAL_')));
        // counted_qty is the payload's; progress_label keeps its last value
        // because a skip carries none.
        expect(h.logic.countedQty, 7);
        expect(h.logic.progressLabel, labelBefore);
        // Nothing was written: the stage clears but anyCommitted stays false.
        expect(h.logic.staged, isNull);
        expect(h.logic.anyCommitted, isFalse);
        expect(h.logic.errMessage, '');
        expect(h.logic.lastCommitEvent, 'skipped');
        expect(h.logic.commitSeq, seqBefore + 1);
      });
    }
  });

  group('gs1 + expiry render verbatim', () {
    test('staged card carries batch, expiry_label and expiry_warning', () async {
      final h = _harness(
        respond: (fn, p) => _lookupOk(
          productId: 1,
          name: 'X',
          gs1: {
            'batch': 'BATCH42',
            'serial': 'SER001',
            'expiry_date': '2024-06-30',
            'expiry_label': 'Exp 06/2024',
          },
          expiryWarning: {
            'show': true,
            'level': 'expired',
            'label': 'EXPIRED 06/2024',
            'colors': {'bg': '#FEE2E2', 'fg': '#B42318', 'border': '#F04438'},
          },
        ),
      );

      await h.logic.handleCode('RAW');

      final s = h.logic.staged!;
      expect(s.batch, 'BATCH42');
      expect(s.expiryLabel, 'Exp 06/2024');
      expect(s.expiryWarning['show'], isTrue);
      expect(s.expiryWarning['label'], 'EXPIRED 06/2024');
      expect((s.expiryWarning['colors'] as Map)['bg'], '#FEE2E2');
    });

    test('a plain EAN stages with explicit empties, never nulls', () async {
      final h = _harness(respond: (fn, p) => _lookupOk(productId: 1, name: 'X'));
      await h.logic.handleCode('8901234567890');
      final s = h.logic.staged!;
      expect(s.batch, '');
      expect(s.expiryLabel, '');
      expect(s.expiryWarning, isEmpty);
    });

    test('the commit response expiry_warning is kept verbatim', () async {
      final h = _harness(
        respond: (fn, p) => fn == 'barcode_lookup'
            ? _lookupOk(productId: 1, name: 'X')
            : {
                'ok': true,
                'counted_qty': 4,
                'progress_label': 'x',
                'expiry_warning': {
                  'show': true,
                  'level': 'short_expiry',
                  'label': 'Short expiry 10/2026',
                  'colors': {'bg': '#FEF0C7', 'fg': '#B54708', 'border': '#F79009'},
                },
              },
      );

      await h.logic.handleCode('CODE');
      await h.logic.commit();

      expect(h.logic.commitExpiry['show'], isTrue);
      expect(h.logic.commitExpiry['label'], 'Short expiry 10/2026');
      expect(h.logic.lastCommitEvent, 'committed');
    });
  });

  group('teach flow', () {
    Map<String, dynamic> unknown() => {
          'ok': false,
          'error': 'unknown_barcode',
          'title': 'Unknown barcode',
          'message': 'This code is not attached to any product yet.',
          'can_teach': true,
          'teach_barcode': '08901234567890',
          'teach_hint': 'Pick the product this code belongs to.',
        };

    test('unknown_barcode + can_teach exposes the backend teach payload',
        () async {
      final h = _harness(respond: (fn, p) => unknown());
      await h.logic.handleCode('RAW-SCAN');

      expect(h.logic.canTeach, isTrue);
      expect(h.logic.teachBarcode, '08901234567890',
          reason: 'the backend-normalised code, not the raw scan');
      expect(h.logic.teachHint, 'Pick the product this code belongs to.');
      expect(h.logic.errTitle, 'Unknown barcode');
    });

    test('teach saves the backend teach_barcode then re-looks up the RAW scan',
        () async {
      var taught = false;
      final h = _harness(respond: (fn, p) {
        if (fn == 'medicine_set_barcode') {
          taught = true;
          return {'ok': true};
        }
        return taught ? _lookupOk(productId: 55, name: 'Taught') : unknown();
      });

      await h.logic.handleCode('RAW-SCAN');
      await h.logic.teach(55);

      expect(h.calls.map((c) => c.fn).toList(),
          ['barcode_lookup', 'medicine_set_barcode', 'barcode_lookup']);
      expect(h.calls[1].params,
          {'p_product_id': 55, 'p_barcode': '08901234567890'});
      expect(h.calls.last.params['p_barcode'], 'RAW-SCAN',
          reason: 'the re-lookup uses the raw scan, so gs1 parses again');
      expect(h.logic.staged!.productId, 55);
      expect(h.logic.canTeach, isFalse, reason: 'teach state cleared on success');
    });

    test('barcode_taken renders its message verbatim and keeps teach open',
        () async {
      final h = _harness(respond: (fn, p) {
        if (fn == 'medicine_set_barcode') {
          return {
            'ok': false,
            'error': 'barcode_taken',
            'message': 'That barcode already belongs to Dolo 650.',
          };
        }
        return unknown();
      });

      await h.logic.handleCode('RAW-SCAN');
      await h.logic.teach(55);

      expect(h.logic.errMessage, 'That barcode already belongs to Dolo 650.');
      expect(h.logic.canTeach, isTrue, reason: 'another pick stays possible');
      expect(h.calls.map((c) => c.fn).toList(),
          ['barcode_lookup', 'medicine_set_barcode'],
          reason: 'no re-lookup after a refusal');
    });

    test('an ordinary refused lookup never opens teach', () async {
      final h = _harness(
        respond: (fn, p) => {
          'ok': false,
          'error': 'not_on_order',
          'title': 'Not on this order',
          'message': 'm',
        },
      );
      await h.logic.handleCode('CODE');
      expect(h.logic.canTeach, isFalse);
      expect(h.logic.teachBarcode, '');
    });
  });

  group('no_active_bag', () {
    test('the refused commit renders the backend title + message verbatim',
        () async {
      final h = _harness(
        respond: (fn, p) => fn == 'barcode_lookup'
            ? _lookupOk(productId: 1, name: 'X')
            : {
                'ok': false,
                'error': 'no_active_bag',
                'title': 'No bag attached',
                'message': 'Attach a bag to this supplier before counting.',
              },
      );

      await h.logic.handleCode('CODE');
      final countBefore = h.logic.countedQty;
      await h.logic.commit();

      expect(h.logic.errTitle, 'No bag attached');
      expect(h.logic.errMessage,
          'Attach a bag to this supplier before counting.');
      expect(h.logic.countedQty, countBefore,
          reason: 'the backend wrote nothing — the count is untouched');
      expect(h.logic.anyCommitted, isFalse);
      expect(h.logic.lastCommitEvent, 'refused');
    });
  });

  group('commit outcome sequencing', () {
    test('every outcome bumps commitSeq exactly once', () async {
      final h = _harness(
        respond: (fn, p) => fn == 'barcode_lookup'
            ? _lookupOk(productId: 1, name: 'X')
            : {'ok': true, 'counted_qty': 4, 'progress_label': 'x'},
      );

      expect(h.logic.commitSeq, 0);
      await h.logic.handleCode('A');
      await h.logic.commit();
      expect(h.logic.commitSeq, 1);
      expect(h.logic.lastCommitEvent, 'committed');

      await h.logic.handleCode('B');
      h.logic.bump(-1); // 0
      await h.logic.commit();
      expect(h.logic.commitSeq, 2);
      expect(h.logic.lastCommitEvent, 'zero');
    });
  });

  group('CountVoiceBar renders status verbatim', () {
    Future<void> pump(WidgetTester t, CountVoiceStatus s) => t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CountVoiceBar(status: s, onToggle: () async {}),
            ),
          ),
        );

    testWidgets('unsupported renders nothing', (t) async {
      await pump(t, const CountVoiceStatus(supported: false, hint: 'H'));
      expect(find.text('H'), findsNothing);
      expect(find.byIcon(Icons.mic_none_rounded), findsNothing);
    });

    testWidgets('hint, caption and bag label are verbatim', (t) async {
      await pump(
          t,
          const CountVoiceStatus(
            supported: true,
            hint: 'Say the counts aloud',
            caption: 'dolo six fifty ten strips',
            bagLabel: 'Bag 3',
          ));
      expect(find.text('Say the counts aloud'), findsOneWidget);
      expect(find.text('dolo six fifty ten strips'), findsOneWidget);
      expect(find.text('Bag 3'), findsOneWidget);
      expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);
    });

    testWidgets('error wins over hint and shows the stop state while listening',
        (t) async {
      await pump(
          t,
          const CountVoiceStatus(
            supported: true,
            listening: true,
            hint: 'HINT',
            error: 'BACKEND ERROR COPY',
          ));
      expect(find.text('BACKEND ERROR COPY'), findsOneWidget);
      expect(find.text('HINT'), findsNothing);
      expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
    });

    testWidgets('the mic button calls the tab toggle, nothing else', (t) async {
      var toggles = 0;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CountVoiceBar(
            status: const CountVoiceStatus(supported: true),
            onToggle: () async => toggles++,
          ),
        ),
      ));
      await t.tap(find.byIcon(Icons.mic_none_rounded));
      expect(toggles, 1);
    });
  });
}
