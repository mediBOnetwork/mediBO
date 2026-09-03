// PROTECTED — the admin supplier console (CHANGE #753).
//
// What this holds down is one sentence: the Suppliers list and the supplier
// page COMPUTE NOTHING. Both were rebuilt around a single backend payload, and
// the failure mode being fenced off is the one this repo keeps re-learning —
// a Dart `switch`, a `.toStringAsFixed(2)`, a pluralisation or a colour rule
// growing back beside the server's answer and quietly disagreeing with it.
//
// So every assertion here feeds a deliberately ODD payload — a rupee string
// with the wrong number of decimals, a rank that is not the row's position, a
// waiting count of 1 labelled in the plural — and demands it appears on screen
// verbatim. If a future edit starts computing any of these, these tests go red
// exactly where the computation was introduced.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_supplier_page.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/supplier_console_row.dart';

Map<String, dynamic> _row({
  String name = 'Sagar Medicals',
  bool hasWaiting = true,
  bool hasDues = true,
  Object? kycChip,
  List<Map<String, dynamic>>? menu,
}) =>
    <String, dynamic>{
      'id': 'sup-1',
      'name': name,
      'zone_label': 'Raipur Zone',
      'rank_label': '#7',
      'spn_label': 'SPN 845,104',
      'waiting_label': '1 waiting',
      'has_waiting': hasWaiting,
      'dues_label': '₹38,591.2',
      'has_dues': hasDues,
      if (kycChip != null) 'kyc_chip': kycChip,
      'menu': menu ??
          <Map<String, dynamic>>[
            {'key': 'edit', 'label': 'Edit', 'tone': 'neutral'},
            {'key': 'spn', 'label': 'SPN', 'tone': 'neutral'},
            {
              'key': 'delete',
              'label': 'Delete',
              'tone': 'danger',
              'confirm': {
                'title': 'Delete this supplier?',
                'body': 'Give a reason.',
                'ok': 'Delete supplier',
                'cancel': 'Keep supplier',
                'needs_reason': true,
                'reason_hint': 'Reason for deleting',
                'reason_error': 'A reason is required.',
              },
            },
          ],
    };

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  setUpAll(() {
    // RenderLog's 800 ms debounce is a real Timer that would outlive the test
    // and try to reach Supabase.
    RenderLog.flushEnabled = false;
  });

  group('the compact supplier row prints, never computes', () {
    testWidgets('every cell is the payload string, verbatim', (t) async {
      await t.pumpWidget(_host(SupplierConsoleRow(row: _row())));

      expect(find.text('Sagar Medicals'), findsOneWidget);
      // The rank is the BACKEND's rank. '#7' for a row rendered on its own
      // proves the widget never counted its own position.
      expect(find.text('Raipur Zone  ·  #7  SPN 845,104'), findsOneWidget);
      // One waiting, and the backend still said "1 waiting" — no Dart plural.
      expect(find.text('1 waiting'), findsOneWidget);
      // One decimal place, because that is what the server sent. A Dart money
      // formatter would have printed ₹38,591.20.
      expect(find.text('₹38,591.2'), findsOneWidget);
    });

    testWidgets('an absent KYC chip renders nothing at all', (t) async {
      await t.pumpWidget(_host(SupplierConsoleRow(row: _row())));
      expect(find.text('KYC missing'), findsNothing);

      await t.pumpWidget(_host(SupplierConsoleRow(
        row: _row(kycChip: {
          'show': true,
          'label': 'KYC missing',
          'bg': '#FEE2E2',
          'fg': '#991B1B',
          'border': '#FECACA',
        }),
      )));
      expect(find.text('KYC missing'), findsOneWidget);
    });

    testWidgets('show:false is not rendered either', (t) async {
      await t.pumpWidget(_host(SupplierConsoleRow(
        row: _row(kycChip: {'show': false, 'label': 'KYC complete'}),
      )));
      expect(find.text('KYC complete'), findsNothing);
    });

    testWidgets('the ⋮ menu is the payload list, in payload order', (t) async {
      Map<String, dynamic>? picked;
      await t.pumpWidget(_host(SupplierConsoleRow(
        row: _row(),
        onMenu: (item) => picked = item,
      )));

      await t.tap(find.byIcon(Icons.more_vert));
      await t.pumpAndSettle();

      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('SPN'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);

      // Order is the payload's, read off the rendered menu.
      final labels = t
          .widgetList<Text>(find.descendant(
              of: find.byType(PopupMenuItem<int>), matching: find.byType(Text)))
          .map((w) => w.data)
          .toList();
      expect(labels, ['Edit', 'SPN', 'Delete']);

      await t.tap(find.text('Delete'));
      await t.pumpAndSettle();

      // The chosen entry is handed back untouched — including the confirm
      // block, so the screen cannot invent its own delete copy.
      expect(picked?['key'], 'delete');
      expect((picked?['confirm'] as Map)['needs_reason'], true);
      expect((picked?['confirm'] as Map)['ok'], 'Delete supplier');
    });

    testWidgets('a row with no menu shows no ⋮ button', (t) async {
      await t.pumpWidget(_host(SupplierConsoleRow(row: _row(menu: []))));
      expect(find.byIcon(Icons.more_vert), findsNothing);
    });
  });

  group('the supplier page renders blocks, and only blocks', () {
    tearDown(() => AdminSupplierPage.rpcOverride = null);

    void serve(Map<String, Object?> byRpc) {
      AdminSupplierPage.rpcOverride = (rpc, params) async => byRpc[rpc];
    }

    Map<String, dynamic> page(List<Map<String, dynamic>> tabs) => {
          'ok': true,
          'supplier_id': 'sup-1',
          'title': 'Sagar Medicals',
          'subtitle': 'SAG100  ·  9000000024  ·  RAIPUR',
          'back_label': 'Suppliers',
          'chips': <Map<String, dynamic>>[],
          'spn_label': 'SPN 845,104',
          'zone_label': 'Raipur Zone',
          'tabs': tabs,
          'default_tab': tabs.isEmpty ? '' : tabs.first['key'],
          'empty_label': 'Nothing here yet.',
        };

    testWidgets('the tab list is the registry payload, not a Dart list',
        (t) async {
      serve({
        'admin_supplier_page': page([
          {'key': 'profile', 'label': 'Profile', 'rpc': 'tab_profile'},
          {'key': 'history', 'label': 'History', 'rpc': 'tab_history'},
        ]),
        'tab_profile': {
          'ok': true,
          'blocks': [
            {
              'kind': 'kv',
              'title': 'Business',
              'rows': [
                {'label': 'Supplier', 'value': 'Sagar Medicals'},
              ],
            },
          ],
        },
      });

      await t.pumpWidget(const MaterialApp(
          home: AdminSupplierPage(supplierId: 'sup-1')));
      await t.pumpAndSettle();

      // Two tabs, because the payload had two — a partner whose matrix hides
      // Orders simply never receives that entry.
      expect(find.text('Profile'), findsOneWidget);
      expect(find.text('History'), findsOneWidget);
      expect(find.text('Payments'), findsNothing);
      expect(find.text('Business'), findsOneWidget);
      expect(find.text('Sagar Medicals'), findsWidgets);
    });

    testWidgets('an unknown block kind is skipped in silence', (t) async {
      serve({
        'admin_supplier_page': page([
          {'key': 'profile', 'label': 'Profile', 'rpc': 'tab_profile'},
        ]),
        'tab_profile': {
          'ok': true,
          'blocks': [
            {'kind': 'sunburst_chart', 'title': 'From the future'},
            {'kind': 'note', 'text': 'Still rendered.'},
          ],
        },
      });

      await t.pumpWidget(const MaterialApp(
          home: AdminSupplierPage(supplierId: 'sup-1')));
      await t.pumpAndSettle();

      expect(_hasErrorWidget(t), isFalse);
      expect(find.text('From the future'), findsNothing);
      expect(find.text('Still rendered.'), findsOneWidget);
    });

    testWidgets('tiles and tables print their strings verbatim', (t) async {
      serve({
        'admin_supplier_page': page([
          {'key': 'performance', 'label': 'Performance', 'rpc': 'tab_perf'},
        ]),
        'tab_perf': {
          'ok': true,
          'blocks': [
            {
              'kind': 'tiles',
              'title': 'This month',
              'tiles': [
                {'label': 'Response rate', 'value': '—', 'tone': 'info'},
                {'label': 'Fill rate', 'value': '66.7%', 'tone': 'success'},
              ],
            },
            {
              'kind': 'table',
              'title': 'Last 12 months',
              'columns': [
                {'label': 'Month', 'align': 'left'},
                {'label': 'Fill rate', 'align': 'right'},
              ],
              'rows': [
                [
                  {'text': 'Sep 26'},
                  {'text': '-18.4%'},
                ],
              ],
            },
          ],
        },
      });

      await t.pumpWidget(const MaterialApp(
          home: AdminSupplierPage(supplierId: 'sup-1')));
      await t.pumpAndSettle();

      // An em dash is a legitimate value: "not measurable this month" is the
      // backend's answer, not a null the screen turns into '0%'.
      expect(find.text('—'), findsOneWidget);
      expect(find.text('66.7%'), findsOneWidget);
      // A negative percentage survives untouched — nothing here re-derives it.
      expect(find.text('-18.4%'), findsOneWidget);
    });

    testWidgets('a chip sends the value the backend named, not its key',
        (t) async {
      final calls = <MapEntry<String, Map<String, dynamic>>>[];
      AdminSupplierPage.rpcOverride = (rpc, params) async {
        calls.add(MapEntry(rpc, params));
        if (rpc == 'admin_supplier_page') {
          return page([
            {'key': 'availability', 'label': 'Availability', 'rpc': 'tab_avail'},
          ]);
        }
        return {
          'ok': true,
          'blocks': [
            {
              'kind': 'chips',
              'key': 'zone',
              'arg': 'p_zone_id',
              'title': 'Zone',
              'chips': [
                {'key': '1', 'value': 1, 'label': '① Raipur Zone', 'count': 24,
                 'active': true},
                {'key': '2', 'value': 2, 'label': '② Bilaspur Zone', 'count': 3,
                 'active': false},
              ],
            },
          ],
        };
      };

      await t.pumpWidget(const MaterialApp(
          home: AdminSupplierPage(supplierId: 'sup-1')));
      await t.pumpAndSettle();

      // The circled numeral is the backend's label, printed as sent.
      expect(find.text('② Bilaspur Zone  3'), findsOneWidget);

      await t.tap(find.text('② Bilaspur Zone  3'));
      await t.pumpAndSettle();

      final last = calls.last;
      expect(last.key, 'tab_avail');
      // The NUMBER, because the payload carried one — sending the string key
      // would be the screen choosing a type the RPC never asked for.
      expect(last.value['p_zone_id'], 2);
      expect(last.value['p_supplier_id'], 'sup-1');
    });

    testWidgets('ok:false renders the backend message, never a throw',
        (t) async {
      serve({
        'admin_supplier_page': {
          'ok': false,
          'blocks': [],
          'message': 'That supplier no longer exists.',
        },
      });

      await t.pumpWidget(const MaterialApp(
          home: AdminSupplierPage(supplierId: 'gone')));
      await t.pumpAndSettle();

      expect(find.text('That supplier no longer exists.'), findsOneWidget);
    });
  });
}

/// True when the widget tree is currently showing a framework error box.
bool _hasErrorWidget(WidgetTester t) => t.any(find.byType(ErrorWidget));
