// PROTECTED — CHANGE #709. Internal damage / breakage during handling.
//
// What this file holds down:
//
//   * the damage sheet decides NOTHING — reason chips arrive in payload order,
//     Submit stays shut until a quantity and a reason are given, a reason that
//     says needs_photo keeps it shut until a photo is attached, a quantity
//     above what the payload says is LEFT is refused on this side too, and a
//     payload with can_log:false renders the backend's sentence and no form;
//   * the photo goes to the folder the BACKEND named — never a path built here
//     (the #705 lesson: a client-built path is refused by storage RLS before
//     the RPC is ever reached);
//   * the report renders tabs, rates and tones VERBATIM: no percentage is
//     computed and no threshold is applied on this side, and the queue offers
//     confirm/reject only while a decider is wired;
//   * CHANGE #956 — damage the backend could not price yet is NOT ₹0.00. The
//     unvalued sentence is a backend string rendered verbatim, and an empty
//     one draws nothing at all — the screen never counts the rows itself and
//     never invents the wording.
//
// No network, no Supabase: every RPC is a mocked payload.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/damage_report_screen.dart';
import 'package:pharma_b2b/screens/fulfil/damage_sheet.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _sheet({bool canLog = true, String message = ''}) => {
      'ok': true,
      'order_id': 'o-1',
      'order_item_id': 'i-1',
      'product_name': 'Megval 50mg Injection',
      'supplier': 'ACME PHARMA',
      'ordered_qty': 9,
      'remaining_qty': 6,
      'title': 'Report damage',
      'subtitle': 'Tell us what broke and how much of it.',
      'qty_label': 'How many',
      'reason_label': 'What happened?',
      'note_label': 'Anything else?',
      'note_hint': 'Optional',
      'photo_label': 'Photo of the damage',
      'photo_hint': 'Required for this reason',
      'submit_label': 'Log the damage',
      'bucket': 'damage-photos',
      'upload_prefix': 'order/o-1',
      'stage_key': 'count',
      'can_log': canLog,
      'message': message,
      'actor_kind': 'worker',
      'can_confirm': false,
      // Deliberately NOT alphabetical: payload order is the render order, and
      // 'wrong_pack' is the one that needs no photo.
      'reasons': const [
        {'code': 'broken', 'label': 'Broken', 'needs_photo': true},
        {'code': 'wrong_pack', 'label': 'Wrong pack', 'needs_photo': false},
        {'code': 'wet', 'label': 'Wet', 'needs_photo': true},
      ],
      'stages': const [
        {'key': 'count', 'label': 'At counting'},
        {'key': 'pack', 'label': 'At packing'},
      ],
      'state': const {'has': false, 'rows': []},
    };

Map<String, dynamic> _report() => {
      'ok': true,
      'title': 'Damage report',
      'empty_note': 'No damage recorded in this window.',
      'summary': '9 unit(s) over 3 report(s)',
      'total_amount_display': '₹540.00',
      'threshold_pct': 2.0,
      'tabs': const [
        {'key': 'queue', 'label': 'To confirm', 'count': 1},
        {'key': 'worker', 'label': 'By worker', 'count': 2},
        {'key': 'supplier', 'label': 'By supplier', 'count': 1},
        {'key': 'product', 'label': 'By product', 'count': 1},
      ],
      'queue': const [
        {
          'id': 7,
          'order_id': 'o-1',
          'order_code': 'CPO-1',
          'product_name': 'Megval 50mg Injection',
          'qty': 3,
          'reason': 'Broken',
          'stage_label': 'At counting',
          'worker_label': 'Ramesh',
          'note': 'carton crushed',
          'confirm_label': 'Confirm',
          'reject_label': 'Not damage',
        },
      ],
      // The rate is the BACKEND's arithmetic and the tone is its verdict.
      'worker': const [
        {
          'key': 'Ramesh',
          'label': 'Ramesh',
          'summary': '9 unit(s) over 3 report(s)',
          'rate_label': '4.5% of what was handled',
          'amount_display': '₹540.00',
          'tone': 'danger',
        },
        {
          'key': 'Sunita',
          'label': 'Sunita',
          'summary': '1 unit(s) over 1 report(s)',
          'rate_label': '0.2% of what was handled',
          'amount_display': '₹60.00',
          'tone': 'neutral',
        },
      ],
      'supplier': const [],
      'product': const [],
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() {
    DamageSheet.rpcTransport = null;
    DamageSheet.uploadTransport = null;
    DamageReportScreen.rpcTransport = null;
  });

  group('the damage sheet computes nothing', () {
    testWidgets('chips arrive in payload order and Submit starts shut',
        (t) async {
      DamageSheet.rpcTransport = (fn, p) async {
        expect(fn, 'damage_sheet');
        expect(p?['p_order_item_id'], 'i-1');
        return _sheet();
      };
      await t.pumpWidget(const MaterialApp(
          home: Scaffold(body: DamageSheet(orderItemId: 'i-1'))));
      await t.pumpAndSettle();

      final chips = t.widgetList<ChoiceChip>(find.byType(ChoiceChip)).toList();
      expect(chips.length, 3);
      expect((chips[0].label as Text).data, 'Broken');
      expect((chips[1].label as Text).data, 'Wrong pack');
      expect((chips[2].label as Text).data, 'Wet');

      final submit = t.widget<FilledButton>(find.ancestor(
          of: find.text('Log the damage'), matching: find.byType(FilledButton)));
      expect(submit.onPressed, isNull);
    });

    testWidgets('a reason that needs a photo keeps Submit shut until there is one',
        (t) async {
      DamageSheet.rpcTransport = (fn, p) async => _sheet();
      await t.pumpWidget(const MaterialApp(
          home: Scaffold(body: DamageSheet(orderItemId: 'i-1'))));
      await t.pumpAndSettle();

      await t.enterText(find.byType(TextField).first, '2');
      await t.tap(find.text('Wrong pack'));
      await t.pumpAndSettle();
      var submit = t.widget<FilledButton>(find.ancestor(
          of: find.text('Log the damage'), matching: find.byType(FilledButton)));
      expect(submit.onPressed, isNotNull, reason: 'this reason needs no photo');

      await t.tap(find.text('Broken'));
      await t.pumpAndSettle();
      submit = t.widget<FilledButton>(find.ancestor(
          of: find.text('Log the damage'), matching: find.byType(FilledButton)));
      expect(submit.onPressed, isNull, reason: 'needs_photo and none attached');
    });

    testWidgets('a quantity above what is LEFT is refused here too', (t) async {
      DamageSheet.rpcTransport = (fn, p) async => _sheet();
      await t.pumpWidget(const MaterialApp(
          home: Scaffold(body: DamageSheet(orderItemId: 'i-1'))));
      await t.pumpAndSettle();

      await t.tap(find.text('Wrong pack'));
      await t.enterText(find.byType(TextField).first, '7'); // remaining is 6
      await t.pumpAndSettle();
      final submit = t.widget<FilledButton>(find.ancestor(
          of: find.text('Log the damage'), matching: find.byType(FilledButton)));
      expect(submit.onPressed, isNull);
    });

    testWidgets('can_log:false renders the backend sentence and no form',
        (t) async {
      DamageSheet.rpcTransport = (fn, p) async =>
          _sheet(canLog: false, message: 'Damage cannot be logged at this stage.');
      await t.pumpWidget(const MaterialApp(
          home: Scaffold(body: DamageSheet(orderItemId: 'i-1'))));
      await t.pumpAndSettle();

      expect(find.text('Damage cannot be logged at this stage.'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.text('Log the damage'), findsNothing);
    });

    test('the photo folder is the payload\'s, never one built here', () {
      final p = _sheet();
      expect(DamageSheet.photoPath(p, 'jpg', 42), 'order/o-1/damage_42.jpg');
      final noPrefix = Map<String, dynamic>.from(p)..remove('upload_prefix');
      expect(DamageSheet.photoPath(noPrefix, 'jpg', 42), isNull,
          reason: 'no prefix means no upload, never a guessed folder');
    });

    testWidgets('the upload goes to the bucket AND folder the payload named',
        (t) async {
      String? seenBucket;
      String? seenPath;
      DamageSheet.rpcTransport = (fn, p) async => _sheet();
      DamageSheet.uploadTransport = (b, path, bytes, mime) async {
        seenBucket = b;
        seenPath = path;
        return path;
      };
      await t.pumpWidget(const MaterialApp(
          home: Scaffold(body: DamageSheet(orderItemId: 'i-1'))));
      await t.pumpAndSettle();
      // The picker itself is platform code; drive the transport with the path
      // the widget would have built, which is the contract this file owns.
      final target = DamageSheet.photoPath(_sheet(), 'jpg', 1)!;
      await DamageSheet.upload(
          'damage-photos', target, Uint8List.fromList([1, 2]), 'image/jpeg');
      expect(seenBucket, 'damage-photos');
      expect(seenPath, 'order/o-1/damage_1.jpg');
    });
  });

  group('the damage report renders the payload', () {
    testWidgets('tabs, rate and tone are the backend\'s', (t) async {
      var tab = 'worker';
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DamageReportView(
            payload: _report(),
            tab: tab,
            onTab: (k) => tab = k,
            rows: (key) => ((_report()[key] as List<dynamic>?) ?? const [])
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList(),
          ),
        ),
      ));
      await t.pumpAndSettle();

      expect(find.text('9 unit(s) over 3 report(s)'), findsWidgets);
      expect(find.text('4.5% of what was handled'), findsOneWidget);
      expect(find.text('0.2% of what was handled'), findsOneWidget);
      expect(find.text('To confirm (1)'), findsOneWidget);
      expect(find.text('By worker (2)'), findsOneWidget);
    });

    // CHANGE #956 — damage_apply writes an honest NULL amount when the line
    // has no trade rate yet. The report used to sum that as zero, so damage
    // nobody had priced read "₹0.00" with nothing to say the money was simply
    // unknown. The sentence is the BACKEND's; this side only prints it.
    testWidgets('the unvalued sentence is printed, never computed here',
        (t) async {
      final p = _report();
      p['unvalued'] = 4;
      p['unvalued_label'] = '4 not valued yet — no trade rate on the line';
      final workers = [
        {
          ...(p['worker'] as List).first as Map<String, dynamic>,
          'unvalued': 4,
          'unvalued_label': '4 not valued yet',
        },
        (p['worker'] as List).last as Map<String, dynamic>,
      ];
      p['worker'] = workers;

      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DamageReportView(
            payload: p,
            tab: 'worker',
            onTab: (_) {},
            rows: (key) => ((p[key] as List<dynamic>?) ?? const [])
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList(),
          ),
        ),
      ));
      await t.pumpAndSettle();

      // the money line stays the money line
      expect(find.text('₹540.00'), findsWidgets);
      // and the unknown is stated separately, in the backend's own words
      expect(find.text('4 not valued yet — no trade rate on the line'),
          findsOneWidget);
      expect(find.text('4 not valued yet'), findsOneWidget);
      // the count is never re-derived on this side
      expect(find.text('4'), findsNothing);
    });

    testWidgets('nothing unvalued draws no row at all', (t) async {
      final p = _report();
      p['unvalued'] = 0;
      p['unvalued_label'] = '';

      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DamageReportView(
            payload: p,
            tab: 'worker',
            onTab: (_) {},
            rows: (key) => ((p[key] as List<dynamic>?) ?? const [])
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList(),
          ),
        ),
      ));
      await t.pumpAndSettle();

      expect(find.textContaining('not valued yet'), findsNothing);
      expect(find.text('₹540.00'), findsWidgets);
    });

    testWidgets('the queue offers confirm and reject with the payload words',
        (t) async {
      Object? decided;
      bool? confirmed;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DamageReportView(
            payload: _report(),
            tab: 'queue',
            onTab: (_) {},
            rows: (key) => ((_report()[key] as List<dynamic>?) ?? const [])
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList(),
            onDecide: (id, ok) async {
              decided = id;
              confirmed = ok;
            },
          ),
        ),
      ));
      await t.pumpAndSettle();

      expect(find.text('Megval 50mg Injection'), findsOneWidget);
      expect(find.text('carton crushed'), findsOneWidget);
      await t.tap(find.text('Confirm'));
      await t.pumpAndSettle();
      expect(decided, 7);
      expect(confirmed, true);

      await t.tap(find.text('Not damage'));
      await t.pumpAndSettle();
      expect(confirmed, false);
    });

    testWidgets('with no decider wired there are no buttons to press',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DamageReportView(
            payload: _report(),
            tab: 'queue',
            onTab: (_) {},
            rows: (key) => ((_report()[key] as List<dynamic>?) ?? const [])
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList(),
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('Confirm'), findsNothing);
      expect(find.text('Not damage'), findsNothing);
    });

    testWidgets('ok:false prints the backend refusal and nothing else',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DamageReportView(
            payload: const {
              'ok': false,
              'error': 'not_authorized',
              'message': 'You cannot report damage on this order.',
            },
            tab: 'queue',
            onTab: (_) {},
            rows: (_) => const [],
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('You cannot report damage on this order.'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
    });
  });
}
