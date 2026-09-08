// PROTECTED — the admin supplier console (CHANGE #753).
//
// What this holds down is one sentence: the Suppliers list and the supplier
// page COMPUTE NOTHING. Both were rebuilt around a single backend payload, and
// the failure mode being fenced off is the one this repo keeps re-learning —
// a Dart `switch`, a `.toStringAsFixed(2)`, a pluralisation or a colour rule
// growing back beside the server's answer and quietly disagreeing with it.
//
// The row's SHAPE is also fenced here, and deliberately. Om rejected the first
// build (3 Sep) because the row carried a waiting count, a rupee amount, a KYC
// badge and an overflow menu and truncated on anything narrower than a desktop:
// "This is a supplier INFO list, not an orders tab." So a test asserts those
// four things are ABSENT from the row — a regression that puts any of them back
// fails here rather than in a screenshot three weeks later.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_supplier_page.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/services/spn_options.dart';
import 'package:pharma_b2b/widgets/spn_factor_editor.dart';
import 'package:pharma_b2b/widgets/supplier_console_row.dart';

Map<String, dynamic> _row({
  String name = 'Sagar Medicals',
  String subtitle = 'RAIPUR  ·  SAG100',
  String statusLabel = 'active',
  String statusTone = 'success',
}) =>
    <String, dynamic>{
      'id': 'sup-1',
      'name': name,
      'subtitle': subtitle,
      'status_label': statusLabel,
      'status_tone': statusTone,
    };

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  setUpAll(() {
    // RenderLog's 800 ms debounce is a real Timer that would outlive the test
    // and try to reach Supabase.
    RenderLog.flushEnabled = false;
  });

  group('the supplier row is a name and one quiet line', () {
    testWidgets('name, subtitle and status all print verbatim', (t) async {
      await t.pumpWidget(_host(SupplierConsoleRow(row: _row())));

      expect(find.text('Sagar Medicals'), findsOneWidget);
      // The separator is the BACKEND's — two spaces around a middle dot. A
      // Dart join would have produced something else.
      expect(find.text('RAIPUR  ·  SAG100'), findsOneWidget);
      // Lower-case because that is the stored status; nothing here title-cases.
      expect(find.text('active'), findsOneWidget);
    });

    testWidgets('the name is allowed to wrap, never ellipsised', (t) async {
      await t.pumpWidget(_host(SizedBox(
        width: 200,
        child: SupplierConsoleRow(
          row: _row(name: 'A Very Long Wholesale Supplier Name Private Limited'),
        ),
      )));

      final name = t.widget<Text>(
          find.text('A Very Long Wholesale Supplier Name Private Limited'));
      expect(name.softWrap, isTrue);
      expect(name.overflow, isNot(TextOverflow.ellipsis));
    });

    testWidgets('the row carries no amount, count, badge or menu', (t) async {
      // The rejected build put all four here. Feeding them in proves the row
      // ignores them rather than that the fixture happens to omit them.
      final noisy = _row()
        ..addAll(<String, dynamic>{
          'waiting_label': '16 waiting',
          'dues_label': '₹38,591.21',
          'kyc_chip': {'show': true, 'label': 'KYC missing'},
          'menu': [
            {'key': 'delete', 'label': 'Delete', 'tone': 'danger'}
          ],
        });
      await t.pumpWidget(_host(SupplierConsoleRow(row: noisy)));

      expect(find.text('16 waiting'), findsNothing);
      expect(find.text('₹38,591.21'), findsNothing);
      expect(find.text('KYC missing'), findsNothing);
      expect(find.byIcon(Icons.more_vert), findsNothing);
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('an empty subtitle and status leave the second line off',
        (t) async {
      await t.pumpWidget(_host(SupplierConsoleRow(
        row: _row(subtitle: '', statusLabel: ''),
      )));
      expect(find.text('Sagar Medicals'), findsOneWidget);
      expect(find.byType(Row), findsNothing);
    });

    testWidgets('tapping the row is the only affordance', (t) async {
      var opened = 0;
      await t.pumpWidget(
          _host(SupplierConsoleRow(row: _row(), onOpen: () => opened++)));
      await t.tap(find.text('Sagar Medicals'));
      await t.pumpAndSettle();
      expect(opened, 1);
    });
  });

  group('the supplier page renders blocks, and only blocks', () {
    tearDown(() => AdminSupplierPage.rpcOverride = null);

    void serve(Map<String, Object?> byRpc) {
      AdminSupplierPage.rpcOverride = (rpc, params) async => byRpc[rpc];
    }

    Map<String, dynamic> page(List<Map<String, dynamic>> tabs,
            {List<Map<String, dynamic>>? menu,
            List<Map<String, dynamic>>? contacts}) =>
        {
          'ok': true,
          'supplier_id': 'sup-1',
          'title': 'Sagar Medicals',
          'subtitle': 'SAG100  ·  RAIPUR',
          'back_label': 'Suppliers',
          'chips': <Map<String, dynamic>>[],
          'spn_label': 'SPN 845,104',
          'rank_label': '#7',
          'zone_label': 'Raipur Zone',
          'contacts': contacts ?? const <Map<String, dynamic>>[],
          'menu': menu ?? const <Map<String, dynamic>>[],
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

    testWidgets('the header carries the identity the row stopped showing',
        (t) async {
      serve({
        'admin_supplier_page': page([
          {'key': 'profile', 'label': 'Info', 'rpc': 'tab_info'},
        ], contacts: [
          {'key': 'call', 'label': 'Call', 'url': 'tel:9000000024'},
          {'key': 'whatsapp', 'label': 'WhatsApp', 'url': 'https://wa.me/91'},
        ]),
        'tab_info': {'ok': true, 'blocks': []},
      });

      await t.pumpWidget(const MaterialApp(
          home: AdminSupplierPage(supplierId: 'sup-1')));
      await t.pumpAndSettle();

      expect(find.text('SAG100  ·  RAIPUR'), findsOneWidget);
      // '#7' is the backend's rank, not this page's position in anything.
      expect(find.text('#7'), findsOneWidget);
      expect(find.text('SPN 845,104'), findsOneWidget);
      expect(find.text('Call'), findsOneWidget);
      expect(find.text('WhatsApp'), findsOneWidget);
    });

    testWidgets('the page runs every action itself — nothing pops back',
        (t) async {
      // Om's parity rule (3 Sep): the old card's actions must all still work,
      // and they now live here. Edit asks the BACKEND for its form rather than
      // handing the job back to the list.
      final calls = <String>[];
      AdminSupplierPage.rpcOverride = (rpc, params) async {
        calls.add(rpc);
        if (rpc == 'admin_supplier_page') {
          return page([
            {'key': 'profile', 'label': 'Info', 'rpc': 'tab_info'},
          ], menu: [
            {'key': 'edit', 'label': 'Edit', 'tone': 'neutral'},
          ])
            ..['edit'] = {
              'label': 'Edit details',
              'form_rpc': 'admin_supplier_edit_form',
              'save_rpc': 'admin_supplier_edit_save',
              'args': {'p_supplier_id': 'sup-1'},
              'arg': 'p_patch',
            };
        }
        if (rpc == 'admin_supplier_edit_form') {
          return {
            'ok': true,
            'supplier_id': 'sup-1',
            'title': 'Edit supplier',
            'save_label': 'Save changes',
            'cancel_label': 'Cancel',
            'fields': [
              {
                'col': 'supplier_name',
                'label': 'Supplier name',
                'kind': 'text',
                'required': true,
                'value': 'Sagar Medicals',
                'options': [],
              },
            ],
          };
        }
        return {'ok': true, 'blocks': []};
      };

      String? popped = 'not-popped';
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  popped = await Navigator.of(ctx).push<String>(
                      MaterialPageRoute(
                          builder: (_) =>
                              const AdminSupplierPage(supplierId: 'sup-1')));
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();

      await t.tap(find.byIcon(Icons.more_vert));
      await t.pumpAndSettle();
      await t.tap(find.text('Edit'));
      await t.pumpAndSettle();

      // The form opened HERE — the field list and every caption are the
      // backend's, so adding a column tomorrow is an INSERT.
      expect(calls, contains('admin_supplier_edit_form'));
      expect(find.text('Edit supplier'), findsOneWidget);
      expect(find.text('Supplier name'), findsOneWidget);
      expect(find.text('Save changes'), findsOneWidget);
      // And the page is still on screen: nothing was handed back to the list.
      expect(popped, 'not-popped');
    });

    testWidgets('the status dropdown is the backend\'s options and RPC',
        (t) async {
      final calls = <MapEntry<String, Map<String, dynamic>>>[];
      AdminSupplierPage.rpcOverride = (rpc, params) async {
        calls.add(MapEntry(rpc, params));
        if (rpc == 'admin_supplier_page') {
          return page([
            {'key': 'profile', 'label': 'Info', 'rpc': 'tab_info'},
          ])
            ..['status'] = {
              'label': 'Status',
              'value': 'Active',
              'rpc': 'admin_set_supplier_status_value',
              'args': {'p_id': 'sup-1'},
              'arg': 'p_status',
              'saved_label': 'Status updated',
              'options': [
                {'value': 'Active', 'label': 'Active'},
                {'value': 'Suspended', 'label': 'Suspended'},
              ],
            };
        }
        return {'ok': true, 'blocks': []};
      };

      await t.pumpWidget(const MaterialApp(
          home: AdminSupplierPage(supplierId: 'sup-1')));
      await t.pumpAndSettle();

      await t.tap(find.byType(DropdownButton<String>));
      await t.pumpAndSettle();
      await t.tap(find.text('Suspended').last);
      await t.pumpAndSettle();
      // The success toast owns a real 4 s timer; let it expire inside the test
      // rather than leaving it pending at teardown.
      await t.pump(const Duration(seconds: 5));

      final write = calls.firstWhere(
          (c) => c.key == 'admin_set_supplier_status_value');
      expect(write.value['p_id'], 'sup-1');
      // The value written is the option's own `value`, not its label and not
      // a lower-cased guess.
      expect(write.value['p_status'], 'Suspended');
    });

    testWidgets('a mapped catalogue company is a chip that comes off alone',
        (t) async {
      final calls = <MapEntry<String, Map<String, dynamic>>>[];
      AdminSupplierPage.rpcOverride = (rpc, params) async {
        calls.add(MapEntry(rpc, params));
        if (rpc == 'admin_supplier_page') {
          return page([
            {'key': 'companies', 'label': 'Companies', 'rpc': 'tab_companies'},
          ]);
        }
        return {
          'ok': true,
          'blocks': [
            {
              'kind': 'list',
              'title': 'Companies stocked',
              'empty': 'none',
              'items': [
                {
                  'id': 'sc-1',
                  'title': 'SUN PHARMA',
                  // One supplier company, two catalogue companies.
                  'chips': [
                    {
                      'label': 'Sun Pharma Laboratories',
                      'remove': {
                        'rpc': 'admin_supplier_company_unmap',
                        'args': {
                          'p_id': 'sc-1',
                          'p_company': 'Sun Pharma Laboratories'
                        },
                      },
                    },
                    {
                      'label': 'Sun Pharmaceutical Industries',
                      'remove': {
                        'rpc': 'admin_supplier_company_unmap',
                        'args': {
                          'p_id': 'sc-1',
                          'p_company': 'Sun Pharmaceutical Industries'
                        },
                      },
                    },
                  ],
                },
              ],
            },
          ],
        };
      };

      await t.pumpWidget(const MaterialApp(
          home: AdminSupplierPage(supplierId: 'sup-1')));
      await t.pumpAndSettle();

      expect(find.text('Sun Pharma Laboratories'), findsOneWidget);
      expect(find.text('Sun Pharmaceutical Industries'), findsOneWidget);

      await t.tap(find.byIcon(Icons.close).first);
      await t.pumpAndSettle();

      final unmap = calls
          .firstWhere((c) => c.key == 'admin_supplier_company_unmap');
      // Exactly the chip that was tapped — the other mapping is untouched.
      expect(unmap.value['p_company'], 'Sun Pharma Laboratories');
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

  _spnTests();
}

/// True when the widget tree is currently showing a framework error box.
bool _hasErrorWidget(WidgetTester t) => t.any(find.byType(ErrorWidget));

/// The four-factor SPN editor (Om, 3 Sep: "Nothing about the SPN formula
/// changes"). What is fenced here is that it writes ONLY what moved — the old
/// panel's whole reason for existing was per-field points, and rewriting an
/// untouched factor re-stamps its points and churns the rank for nothing.
Map<String, dynamic> _spnBlock() => <String, dynamic>{
      'kind': 'spn',
      'title': 'SPN factors',
      'edit_label': 'Edit SPN factors',
      'save_label': 'Save',
      'cancel_label': 'Cancel',
      'saved_label': 'SPN updated',
      'unset_label': 'Not set',
      'points_format': '{n} pts',
      'total_label': 'SPN total',
      'total_value': '845,104',
      'rank_label': 'Rank in zone',
      'rank_value': '#1',
      'supplier_id': 'sup-1',
      'factors': [
        {
          'field': 'margin',
          'label': 'Margin',
          'col': 'margin',
          'points_col': 'margin_points',
          'value': '8',
          'points': 800000,
        },
        {
          'field': 'behaviour',
          'label': 'Behaviour',
          'col': 'behaviour',
          'points_col': 'behaviour_points',
          'value': '10',
          'points': 10000,
        },
      ],
    };

void _spnTests() {
  group('the SPN factor editor writes only what moved', () {
    testWidgets('every caption and both stats are the block\'s', (t) async {
      await t.pumpWidget(_host(SpnFactorEditor(
        block: _spnBlock(),
        rpc: (rpc, params) async => const <Map<String, dynamic>>[],
      )));
      await t.pumpAndSettle();

      expect(find.text('SPN factors'), findsOneWidget);
      // The total is a formatted STRING from the backend, commas and all.
      expect(find.text('845,104'), findsOneWidget);
      expect(find.text('#1'), findsOneWidget);
      expect(find.text('Margin'), findsOneWidget);
      expect(find.text('Behaviour'), findsOneWidget);
      expect(find.text('Edit SPN factors'), findsNothing); // that is the card
      expect(find.text('Save'), findsOneWidget);
    });

    testWidgets('Save is dead until something actually changes', (t) async {
      await t.pumpWidget(_host(SpnFactorEditor(
        block: _spnBlock(),
        rpc: (rpc, params) async => const <Map<String, dynamic>>[],
      )));
      await t.pumpAndSettle();

      final save = t.widget<FilledButton>(find.ancestor(
          of: find.text('Save'), matching: find.byType(FilledButton)));
      expect(save.onPressed, isNull);
    });

    testWidgets('one changed factor writes one admin_set_supplier_spn call',
        (t) async {
      final calls = <Map<String, dynamic>>[];
      await t.pumpWidget(_host(SpnFactorEditor(
        block: _spnBlock(),
        rpc: (rpc, params) async {
          if (rpc == 'spn_options_list') {
            return [
              {'field': 'margin', 'label': '8', 'points': 800000},
              {'field': 'margin', 'label': '12', 'points': 1200000},
              {'field': 'behaviour', 'label': '10', 'points': 10000},
            ];
          }
          calls.add({'rpc': rpc, ...params});
          return {'ok': true};
        },
      )));
      await t.pumpAndSettle();

      await t.tap(find.byType(DropdownButton<SpnOption?>).first);
      await t.pumpAndSettle();
      await t.tap(find.text('12   1200000 pts').last);
      await t.pumpAndSettle();
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();

      // Exactly one write: behaviour was never touched.
      expect(calls.length, 1);
      expect(calls.first['rpc'], 'admin_set_supplier_spn');
      expect(calls.first['p_id'], 'sup-1');
      final field = calls.first['p_field'] as Map;
      // The column names are the BACKEND's, carried through untouched — this
      // widget does not know that payment_term writes to payment_type.
      expect(field['col'], 'margin');
      expect(field['points_col'], 'margin_points');
      expect(field['label'], '12');
      expect(field['points'], '1200000');
    });
  });
}
