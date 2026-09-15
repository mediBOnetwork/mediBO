// PROTECTED — CMD #1947.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the staff header chip's behaviour.
//
// The staff header's date·zone chip replaced a full-width second row of
// pickers. What this holds down:
//
//   1. The chip PRINTS the backend's string. `label` ("12 Sep · Raipur") is
//      rendered verbatim — the date is never formatted in Dart and the zone is
//      never joined to it here.
//
//   2. show:false renders NOTHING. No placeholder chip, no "—".
//
//   3. compact (the web's narrow form) prints `compact_label` — the zone code —
//      and nothing else. It is the payload's own field, not a substring.
//
//   4. The chip TRUNCATES rather than growing: one line, ellipsis, capped at
//      the maxWidth the header hands it. That cap is what keeps the centred
//      logo centred at 360 px.
//
//   5. The sheet's headings are payload strings (sheet.title / date_title /
//      zone_title / done_label), and the zone section is skipped entirely when
//      the payload carries no zone control.
//
//   6. The zone list renders options in PAYLOAD ORDER and reports the chosen
//      option's zone_id VERBATIM — including null for All zones, which is a
//      real value. can_change:false (a zone-locked partner) renders the label
//      as static text with no tap target.
//
// No network, no Supabase, no goldens — an inline admin_scope_chip() payload.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/widgets/scope_chip_view.dart';

Map<String, dynamic> _payload({
  bool show = true,
  String label = '12 Sep · Raipur',
  String compact = 'RAI',
  Map<String, dynamic>? zone,
}) =>
    {
      'show': show,
      'label': label,
      'date_label': '12 Sep',
      'zone_label': 'Raipur',
      'zone_code': compact,
      'compact_label': compact,
      'tooltip': 'Change date or zone',
      'sheet': {
        'title': 'Date & zone',
        'date_title': 'Date',
        'zone_title': 'Zone',
        'done_label': 'Done',
      },
      'zone': zone ??
          {
            'show': true,
            'can_change': true,
            'title': 'Zone',
            'selected_label': 'Raipur',
            'options': [
              {'zone_id': null, 'code': 'all', 'label': 'All zones', 'selected': false},
              {'zone_id': 3, 'code': 'rai', 'label': 'Raipur', 'selected': true},
              {'zone_id': 4, 'code': 'bsp', 'label': 'Bilaspur', 'selected': false},
            ],
          },
    };

// The header gives the chip LOOSE constraints (it sits in a Row beside a
// Spacer), so the host does too — a tight SizedBox would override the chip's
// own cap and prove nothing.
Widget _host(Widget child, {double width = 360}) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          child: Align(alignment: Alignment.centerRight, child: child),
        ),
      ),
    );

void main() {
  testWidgets('1 — the chip prints the backend label verbatim', (t) async {
    await t.pumpWidget(_host(ScopeChipView(payload: _payload())));
    expect(find.text('12 Sep · Raipur'), findsOneWidget);
    // Nothing assembled here: the parts are not printed separately.
    expect(find.text('Raipur'), findsNothing);
  });

  testWidgets('2 — show:false renders nothing at all', (t) async {
    await t.pumpWidget(_host(ScopeChipView(payload: _payload(show: false))));
    expect(find.byType(InkWell), findsNothing);
    expect(find.text('12 Sep · Raipur'), findsNothing);
  });

  testWidgets('3 — compact prints compact_label only', (t) async {
    await t.pumpWidget(
        _host(ScopeChipView(payload: _payload(), compact: true)));
    expect(find.text('RAI'), findsOneWidget);
    expect(find.text('12 Sep · Raipur'), findsNothing);
  });

  testWidgets('4 — the chip truncates inside its cap, one line', (t) async {
    await t.pumpWidget(_host(
      ScopeChipView(
        payload: _payload(label: '12 Sep · A very long zone name indeed'),
        maxWidth: 120,
      ),
    ));
    final text = t.widget<Text>(
        find.text('12 Sep · A very long zone name indeed'));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    // The cap holds: the chip never widens past what the header allowed.
    expect(t.getSize(find.byType(ScopeChipView)).width, lessThanOrEqualTo(120));
  });

  testWidgets('5 — a tap reports, the widget decides nothing', (t) async {
    var taps = 0;
    await t.pumpWidget(
        _host(ScopeChipView(payload: _payload(), onTap: () => taps++)));
    await t.tap(find.byType(InkWell));
    await t.pump();
    expect(taps, 1);
  });

  testWidgets('6 — the sheet prints its headings from the payload', (t) async {
    await t.pumpWidget(_host(
      SingleChildScrollView(
        child: ScopeSheetView(
          payload: _payload(),
          dateChild: const SizedBox(key: Key('cal'), height: 20),
          zoneChild: const SizedBox(key: Key('zones'), height: 20),
        ),
      ),
    ));
    expect(find.text('Date & zone'), findsOneWidget);
    expect(find.text('Date'), findsOneWidget);
    expect(find.text('Zone'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(find.byKey(const Key('cal')), findsOneWidget);
    expect(find.byKey(const Key('zones')), findsOneWidget);
  });

  testWidgets('6b — no zone control in the payload, no zone section', (t) async {
    await t.pumpWidget(_host(
      SingleChildScrollView(
        child: ScopeSheetView(
          payload: _payload(zone: {
            'show': false,
            'can_change': false,
            'selected_label': '',
            'options': [],
          }),
          dateChild: const SizedBox(key: Key('cal'), height: 20),
          zoneChild: const SizedBox(key: Key('zones'), height: 20),
        ),
      ),
    ));
    expect(find.text('Zone'), findsNothing);
    expect(find.byKey(const Key('zones')), findsNothing);
    expect(find.byKey(const Key('cal')), findsOneWidget);
  });

  testWidgets('7 — zone rows keep payload order and report zone_id verbatim',
      (t) async {
    final picked = <Object?>[];
    final zone = _payload()['zone'] as Map<String, dynamic>;
    await t.pumpWidget(_host(
      ScopeZoneList(zone: zone, onSelect: (id) => picked.add(id)),
    ));

    final labels = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data)
        .whereType<String>()
        .toList();
    expect(labels, ['All zones', 'Raipur', 'Bilaspur']);

    // null is a real value — the All-zones entry, not a dismissal.
    await t.tap(find.text('All zones'));
    await t.pump();
    expect(picked, [null]);

    await t.tap(find.text('Bilaspur'));
    await t.pump();
    expect(picked, [null, 4]);
  });

  testWidgets('8 — can_change:false is static text, never a tap target',
      (t) async {
    await t.pumpWidget(_host(
      ScopeZoneList(
        zone: const {
          'show': true,
          'can_change': false,
          'selected_label': 'Raipur',
          'options': [],
        },
        onSelect: (_) => fail('a locked zone must not be selectable'),
      ),
    ));
    expect(find.text('Raipur'), findsOneWidget);
    expect(find.byType(InkWell), findsNothing);
  });
}
