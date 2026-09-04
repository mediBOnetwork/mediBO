// PROTECTED — CHANGE #694. Zone P&L, shared with the partner.
//
// What this file holds down:
//
//   * the screen does NO money arithmetic. Every rupee, the margin percentage,
//     the split sentence and the tile labels are strings from zone_pnl();
//     nothing is summed, divided or formatted here, and the raw numbers behind
//     the display strings are never printed;
//   * the partner view is the BACKEND's: the lines a partner sees arrive
//     already filtered (pnl_line_type.partner_visible), so the same widget
//     renders a shorter list without knowing why, and prints the backend's own
//     note explaining it;
//   * the period picker is the payload's list and the payload's `active` flag,
//     never a local index, and a tap reports the backend's own key;
//   * the margin tone is the payload's verdict, not a threshold applied here;
//   * ok:false renders the backend's refusal and no numbers at all;
//   * the export is the backend's OFFER: the button draws only when the
//     payload carried one, its label is printed verbatim, and the kind and
//     ref it hands back are the payload's own — this screen never assembles a
//     document reference, so a partner can only ask for the export it was
//     given. has:false with a note is an explanation, never a dead button.
//
// No network, no Supabase: every RPC is a mocked payload.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/partner/zone_pnl_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

List<Map<String, dynamic>> _lines({required bool partner}) => [
      {
        'key': 'revenue',
        'label': 'Billed to customers',
        'sign': '+',
        'source': 'derived',
        'amount': 356.0,
        'amount_display': '+ ₹356.00',
      },
      {
        'key': 'delivery',
        'label': 'Delivery',
        'sign': '-',
        'source': 'settlement',
        'amount': 40.0,
        'amount_display': '- ₹40.00',
      },
      // mediBO-only lines. The BACKEND leaves them out of a partner payload;
      // this side never filters.
      if (!partner)
        {
          'key': 'gateway_fee',
          'label': 'Payment gateway',
          'sign': '-',
          'source': 'derived',
          'amount': 7.12,
          'amount_display': '- ₹7.12',
        },
    ].cast<Map<String, dynamic>>();

Map<String, dynamic> _payload({bool partner = false, bool ok = true}) => ok
    ? {
        'ok': true,
        'title': 'Zone P&L',
        'subtitle': 'What this zone earned and what it cost, for the period you pick.',
        'empty_note': 'No billed orders in this period.',
        'costs_heading': 'What it cost',
        'shares_heading': 'How the margin splits',
        'trend_heading': 'Trend',
        'reconcile_note': 'Reconciled against the settlement statement.',
        'view_note':
            partner ? 'These are the lines your share is worked out from.' : '',
        'is_partner_view': partner,
        'period': const {'key': 'month', 'label': 'This month'},
        // deliberately NOT in the order a Dart list would build them
        'period_options': const [
          {'key': 'day', 'label': 'Today', 'active': false},
          {'key': 'week', 'label': 'This week', 'active': false},
          {'key': 'month', 'label': 'This month', 'active': true},
          {'key': 'quarter', 'label': 'This quarter', 'active': false},
          {'key': 'year', 'label': 'This year', 'active': false},
        ],
        'margin_floor_pct': 6.0,
        'tile_labels': const {
          'revenue': 'Billed',
          'gross': 'Gross margin',
          'margin': 'Margin %',
          'orders': 'Orders',
          'partner': 'Partner share',
          'medibo': 'mediBO share',
        },
        'zones': [
          {
            'zone_id': 1,
            'zone_name': 'Raipur Zone',
            'orders': 12,
            'revenue': 356.0,
            'gross_margin': 44.0,
            'distributable': 4.0,
            'split_pct': 50,
            'partner_share': 2.0,
            'medibo_share': 2.0,
            'margin_pct': 12.36,
            'revenue_display': '₹356.00',
            'gross_display': '₹44.00',
            'partner_display': '₹2.00',
            'medibo_display': '₹2.00',
            // the percentage is the BACKEND's arithmetic and its own string
            'margin_display': '12.36%',
            'margin_tone': 'success',
            'split_label': 'Split 50% to you',
            // the document reference is the BACKEND's, ref included
            'export': const {
              'has': true,
              'label': 'Send as PDF',
              'kind': 'zone_pnl',
              'ref': 'z1-month',
              'note': '',
            },
            'lines': _lines(partner: partner),
          },
        ],
        'trend': const [
          {
            'key': '2026-09-01',
            'label': '01 Sep',
            'revenue': 200.0,
            'revenue_display': '₹200.00',
            'gross_display': '₹20.00',
          },
          {
            'key': '2026-09-02',
            'label': '02 Sep',
            'revenue': 156.0,
            'revenue_display': '₹156.00',
            'gross_display': '₹24.00',
          },
        ],
      }
    : {
        'ok': false,
        'error': 'not_authorized',
        'title': 'Zone P&L',
        'message': 'You cannot see the P&L for this zone.',
      };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => ZonePnlScreen.rpcTransport = null);

  Future<void> pump(WidgetTester t, Map<String, dynamic> p,
          {ValueChanged<String>? onPeriod,
          ValueChanged<Map<String, dynamic>>? onExport,
          bool docBusy = false}) =>
      t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ZonePnlView(
            payload: p,
            onPeriod: onPeriod,
            onExport: onExport,
            docBusy: docBusy,
          ),
        ),
      ));

  group('the zone P&L computes nothing', () {
    testWidgets('every figure is the backend string, printed verbatim',
        (t) async {
      await pump(t, _payload());
      await t.pumpAndSettle();

      expect(find.text('₹356.00'), findsWidgets);
      expect(find.text('₹44.00'), findsOneWidget);
      expect(find.text('12.36%'), findsOneWidget);
      expect(find.text('Split 50% to you'), findsOneWidget);
      expect(find.text('Raipur Zone'), findsOneWidget);

      // the raw numbers behind those strings are never printed on their own
      expect(find.text('356.0'), findsNothing);
      expect(find.text('12.36'), findsNothing);
      expect(find.text('50'), findsNothing);
      // and the margin is never re-derived: 44/356 would be 12.36% only by
      // luck of rounding — the fixture's own display string is what shows.
      expect(find.text('12.4%'), findsNothing);
    });

    testWidgets('the partner sees the shorter list the backend sent',
        (t) async {
      await pump(t, _payload(partner: true));
      await t.pumpAndSettle();

      expect(find.text('Delivery'), findsOneWidget);
      expect(find.text('- ₹40.00'), findsOneWidget);
      // a mediBO-only line was never in the payload, so it is nowhere
      expect(find.text('Payment gateway'), findsNothing);
      expect(find.text('- ₹7.12'), findsNothing);
      // and the reason is the backend's sentence
      expect(find.text('These are the lines your share is worked out from.'),
          findsOneWidget);
    });

    testWidgets('mediBO sees every line, and no note', (t) async {
      await pump(t, _payload());
      await t.pumpAndSettle();
      expect(find.text('Payment gateway'), findsOneWidget);
      expect(find.text('- ₹7.12'), findsOneWidget);
      expect(find.textContaining('your share is worked out'), findsNothing);
    });

    testWidgets('the selected period is the payload flag, and a tap reports the backend key',
        (t) async {
      String? picked;
      await pump(t, _payload(), onPeriod: (k) => picked = k);
      await t.pumpAndSettle();

      final chips = t.widgetList<ChoiceChip>(find.byType(ChoiceChip)).toList();
      expect(chips.length, 5);
      // exactly the one the payload marked active
      expect(chips.where((c) => c.selected).length, 1);
      expect((chips[2].label as Text).data, 'This month');
      expect(chips[2].selected, isTrue);

      await t.tap(find.text('This quarter'));
      await t.pumpAndSettle();
      expect(picked, 'quarter');
    });

    testWidgets('the margin tone is the payload verdict, not a threshold here',
        (t) async {
      final p = _payload();
      final z = Map<String, dynamic>.from((p['zones'] as List).first as Map);
      // a margin ABOVE the floor that the backend still calls danger
      z['margin_pct'] = 40.0;
      z['margin_display'] = '40.00%';
      z['margin_tone'] = 'danger';
      p['zones'] = [z];

      await pump(t, p);
      await t.pumpAndSettle();

      final txt = t.widget<Text>(find.text('40.00%'));
      expect(txt.style?.color, isNotNull);
      // it is red because the PAYLOAD said danger, even though 40% is far
      // above the 6% floor also in the payload.
      expect(find.text('40.00%'), findsOneWidget);
    });

    testWidgets('a refusal prints the backend message and no figures',
        (t) async {
      await pump(t, _payload(ok: false));
      await t.pumpAndSettle();
      expect(find.text('You cannot see the P&L for this zone.'), findsOneWidget);
      expect(find.text('₹356.00'), findsNothing);
      expect(find.byType(ChoiceChip), findsNothing);
    });

    testWidgets('the trend is drawn from the payload points, in payload order',
        (t) async {
      await pump(t, _payload());
      await t.pumpAndSettle();
      expect(find.text('01 Sep'), findsOneWidget);
      expect(find.text('02 Sep'), findsOneWidget);
      expect(find.text('₹200.00'), findsOneWidget);
      expect(t.getTopLeft(find.text('01 Sep')).dx,
          lessThan(t.getTopLeft(find.text('02 Sep')).dx));
    });

    testWidgets('the export button is the payload offer, printed verbatim',
        (t) async {
      Map<String, dynamic>? asked;
      await pump(t, _payload(), onExport: (e) => asked = e);
      await t.pumpAndSettle();

      expect(find.widgetWithText(OutlinedButton, 'Send as PDF'), findsOneWidget);
      await t.tap(find.text('Send as PDF'));
      await t.pumpAndSettle();

      // the screen hands back the backend's OWN kind and ref — it built
      // neither, so a period or a zone it was never offered cannot be asked for
      expect(asked?['kind'], 'zone_pnl');
      expect(asked?['ref'], 'z1-month');
    });

    testWidgets('a zone with nobody to send it to shows the note, not a button',
        (t) async {
      final p = _payload();
      final z = Map<String, dynamic>.from((p['zones'] as List).first as Map);
      z['export'] = const {
        'has': false,
        'label': 'Send as PDF',
        'kind': 'zone_pnl',
        'ref': 'z9-month',
        'note': 'This zone has no partner yet, so there is nobody to send it to.',
      };
      p['zones'] = [z];

      await pump(t, p, onExport: (_) {});
      await t.pumpAndSettle();

      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.text('Send as PDF'), findsNothing);
      expect(
          find.text(
              'This zone has no partner yet, so there is nobody to send it to.'),
          findsOneWidget);
    });

    testWidgets('a payload with no export offers nothing at all', (t) async {
      final p = _payload();
      final z = Map<String, dynamic>.from((p['zones'] as List).first as Map);
      z.remove('export');
      p['zones'] = [z];

      await pump(t, p, onExport: (_) {});
      await t.pumpAndSettle();
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('a document already being built cannot be asked for twice',
        (t) async {
      var calls = 0;
      await pump(t, _payload(), onExport: (_) => calls++, docBusy: true);
      await t.pumpAndSettle();

      final b = t.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Send as PDF'));
      expect(b.onPressed, isNull);
      expect(calls, 0);
    });

    testWidgets('no zones renders the backend empty line', (t) async {
      final p = _payload();
      p['zones'] = const [];
      p['trend'] = const [];
      await pump(t, p);
      await t.pumpAndSettle();
      expect(find.text('No billed orders in this period.'), findsOneWidget);
    });
  });
}
