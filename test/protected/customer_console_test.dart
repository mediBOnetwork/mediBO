// CHANGE #810 — the Customers console and the customer page, pinned.
//
// What this holds down is the same thing #753 pinned for suppliers: these two
// widgets COMPUTE NOTHING. The row's name, subtitle, status and churn flag are
// payload fields; the page's tab list, block order, rupees, percentages and
// confirm copy are payload fields. A regression that starts formatting money,
// pluralising, or deciding "no order in 30 days" in Dart fails here.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/admin_customer_page.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/customer_console_row.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// The page payload, deliberately NOT in alphabetical or "obvious" order, with
/// a churn label whose day count disagrees with any clock this test could
/// consult — so a client-side calculation cannot accidentally pass.
Map<String, dynamic> _page() => {
      'ok': true,
      'customer_id': 'c-1',
      'title': 'Chandra Medicom',
      'subtitle': 'Rakesh Chandra  ·  CHA101  ·  Raigarh',
      'code_label': 'CHA101',
      'city_label': 'Raigarh',
      'zone_label': 'Bilaspur Zone',
      'term_label': 'Payment term 21 days',
      'back_label': 'Customers',
      'empty_label': 'Nothing here yet.',
      'chips': [
        {'show': true, 'label': 'KYC missing', 'bg': '#FEF3C7', 'fg': '#92400E'}
      ],
      'contacts': [
        {'key': 'call', 'label': 'Call', 'url': 'tel:9888800000'},
        {'key': 'whatsapp', 'label': 'WhatsApp', 'url': 'https://wa.me/919888800000'},
      ],
      'status': {
        'label': 'Approval',
        'value': 'approved',
        'rpc': 'admin_customer_action_reason',
        'args': {'p_customer_id': 'c-1'},
        'arg': 'p_action',
        'reason_arg': 'p_reason',
        'options': [
          {'value': 'approve', 'label': 'Approve', 'needs_reason': false},
          {'value': 'block', 'label': 'Block', 'needs_reason': true},
        ],
        'reason_prompt': {
          'title': 'Give a reason',
          'hint': 'Reason',
          'ok': 'Save',
          'cancel': 'Cancel',
        },
      },
      'churn': {
        'has': true,
        'label': 'No order in 47 days',
        'nudge': {
          'has': true,
          'label': 'Send reorder nudge',
          'rpc': 'admin_customer_churn_nudge',
          'args': {'p_customer_id': 'c-1'},
        },
      },
      'menu': [
        {'key': 'edit', 'label': 'Edit profile', 'tone': 'neutral'},
        {'key': 'merge', 'label': 'Merge duplicates', 'tone': 'neutral'},
      ],
      'tabs': [
        {'key': 'info', 'label': 'Info', 'rpc': 'admin_customer_tab_info'},
        {'key': 'performance', 'label': 'Performance', 'rpc': 'admin_customer_tab_performance'},
      ],
      'default_tab': 'info',
    };

void main() {
  /// A tall viewport so a lazy ListView BUILDS every block — the second block
  /// on the Performance tab is below the fold at the default 800x600.
  Future<void> tall(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1200, 2400));
    addTearDown(() => t.binding.setSurfaceSize(null));
  }

  setUpAll(() {
    // RenderLog's 800 ms debounce is a real Timer that would outlive the test
    // and try to reach Supabase.
    RenderLog.flushEnabled = false;
  });

  tearDown(() {
    AdminCustomerPage.rpcOverride = null;
    AdminCustomerPage.open360 = null;
  });

  group('CustomerConsoleRow', () {
    testWidgets('prints name, subtitle and status verbatim', (t) async {
      await t.pumpWidget(_host(CustomerConsoleRow(row: const {
        'id': 'c-1',
        'name': 'Shraddha Medical & General Stores',
        'subtitle': 'Raipur  ·  SHR142',
        'status_label': 'approved',
        'status_tone': 'success',
        'churn': {'has': false, 'label': ''},
      })));
      expect(find.text('Shraddha Medical & General Stores'), findsOneWidget);
      expect(find.text('Raipur  ·  SHR142'), findsOneWidget);
      expect(find.text('approved'), findsOneWidget);
    });

    testWidgets('the churn flag appears ONLY when the payload says has:true',
        (t) async {
      await t.pumpWidget(_host(CustomerConsoleRow(row: const {
        'name': 'Ot Medical',
        'subtitle': 'Raipur  ·  OTM101',
        'status_label': 'approved',
        'status_tone': 'success',
        // A label is present but the flag is off: absence is the FLAG, not the
        // emptiness of the string, so nothing may be drawn.
        'churn': {'has': false, 'label': 'No order in 31 days'},
      })));
      expect(find.text('No order in 31 days'), findsNothing);

      await t.pumpWidget(_host(CustomerConsoleRow(row: const {
        'name': 'Ot Medical',
        'subtitle': 'Raipur  ·  OTM101',
        'status_label': 'approved',
        'status_tone': 'success',
        'churn': {'has': true, 'label': 'No order in 31 days'},
      })));
      expect(find.text('No order in 31 days'), findsOneWidget);
    });

    testWidgets('a row with no churn key at all still renders', (t) async {
      await t.pumpWidget(_host(CustomerConsoleRow(row: const {
        'name': 'New Pharmacy',
        'subtitle': '',
        'status_label': '',
        'status_tone': '',
      })));
      expect(find.text('New Pharmacy'), findsOneWidget);
    });
  });

  group('AdminCustomerPage', () {
    testWidgets('renders the header, the churn strip and the backend tab list',
        (t) async {
      AdminCustomerPage.rpcOverride = (rpc, params) async {
        if (rpc == 'admin_customer_page') return _page();
        if (rpc == 'admin_customer_tab_info') {
          return {
            'ok': true,
            'blocks': [
              {
                'kind': 'kv',
                'title': 'Identity',
                'rows': [
                  {'label': 'Pharmacy', 'value': 'Chandra Medicom'},
                  {'label': 'Customer code', 'value': 'CHA101'},
                ],
              },
            ],
          };
        }
        return {'ok': true, 'blocks': const []};
      };
      await t.pumpWidget(MaterialApp(
          home: const AdminCustomerPage(customerId: 'c-1')));
      await t.pumpAndSettle();

      expect(find.text('Chandra Medicom'), findsWidgets);
      expect(find.text('Rakesh Chandra  ·  CHA101  ·  Raigarh'), findsOneWidget);
      // Header chips are the payload's, including the ones the backend worded.
      expect(find.text('KYC missing'), findsOneWidget);
      expect(find.text('Bilaspur Zone'), findsOneWidget);
      expect(find.text('Payment term 21 days'), findsOneWidget);
      // The churn sentence is printed, never recomputed.
      expect(find.text('No order in 47 days'), findsOneWidget);
      expect(find.text('Send reorder nudge'), findsOneWidget);
      // Tab list is the registry's, in payload order.
      expect(find.text('Info'), findsOneWidget);
      expect(find.text('Performance'), findsOneWidget);
      // And the first tab's blocks rendered.
      expect(find.text('Identity'), findsOneWidget);
      expect(find.text('CHA101'), findsWidgets);
    });

    testWidgets('a block kind this build has never heard of renders nothing',
        (t) async {
      AdminCustomerPage.rpcOverride = (rpc, params) async {
        if (rpc == 'admin_customer_page') return _page();
        return {
          'ok': true,
          'blocks': [
            {'kind': 'hologram', 'title': 'From the future'},
            {'kind': 'note', 'text': 'Still rendered.'},
          ],
        };
      };
      await t.pumpWidget(MaterialApp(
          home: const AdminCustomerPage(customerId: 'c-1')));
      await t.pumpAndSettle();
      expect(find.text('From the future'), findsNothing);
      expect(find.text('Still rendered.'), findsOneWidget);
    });

    testWidgets('Performance prints the backend numbers — no Dart arithmetic',
        (t) async {
      AdminCustomerPage.rpcOverride = (rpc, params) async {
        if (rpc == 'admin_customer_page') {
          return _page()..['default_tab'] = 'performance';
        }
        return {
          'ok': true,
          'blocks': [
            {
              'kind': 'tiles',
              'title': 'Performance',
              'tiles': [
                {'label': 'Lifetime value', 'value': '₹64901.26', 'tone': 'brand'},
                {'label': 'On-time payment', 'value': '82.4%', 'tone': 'success'},
                // Deliberately a value no client could derive from the tiles
                // around it.
                {'label': 'NPS', 'value': '8.5', 'tone': 'warning'},
              ],
            },
            {
              'kind': 'table',
              'title': 'Top 10 products',
              'columns': [
                {'label': 'Product', 'align': 'left'},
                {'label': 'Qty', 'align': 'right'},
                {'label': 'Value', 'align': 'right'},
              ],
              'rows': [
                [
                  {'text': 'Dolo 650'},
                  {'text': '120'},
                  {'text': '₹2,400.00'},
                ],
              ],
              'empty': 'No delivered line yet.',
            },
          ],
        };
      };
      await tall(t);
      await t.pumpWidget(MaterialApp(
          home: const AdminCustomerPage(customerId: 'c-1')));
      await t.pumpAndSettle();
      expect(find.text('₹64901.26'), findsOneWidget);
      expect(find.text('82.4%'), findsOneWidget);
      expect(find.text('8.5'), findsOneWidget);
      expect(find.text('Dolo 650'), findsOneWidget);
      expect(find.text('₹2,400.00'), findsOneWidget);
    });

    testWidgets('an empty list block prints the backend empty state', (t) async {
      AdminCustomerPage.rpcOverride = (rpc, params) async {
        if (rpc == 'admin_customer_page') return _page();
        return {
          'ok': true,
          'blocks': [
            {
              'kind': 'list',
              'title': 'Delivery addresses',
              'empty': 'No address saved yet.',
              'items': const [],
            },
          ],
        };
      };
      await t.pumpWidget(MaterialApp(
          home: const AdminCustomerPage(customerId: 'c-1')));
      await t.pumpAndSettle();
      expect(find.text('No address saved yet.'), findsOneWidget);
    });

    testWidgets('ok:false renders the backend refusal instead of throwing',
        (t) async {
      AdminCustomerPage.rpcOverride = (rpc, params) async => {
            'ok': false,
            'message': 'You do not have access to this customer.',
          };
      await t.pumpWidget(MaterialApp(
          home: const AdminCustomerPage(customerId: 'c-1')));
      await t.pumpAndSettle();
      expect(find.text('You do not have access to this customer.'),
          findsOneWidget);
    });

    testWidgets('Block collects a reason and sends it on the payload\'s own arg',
        (t) async {
      Map<String, dynamic>? sent;
      AdminCustomerPage.rpcOverride = (rpc, params) async {
        if (rpc == 'admin_customer_page') return _page();
        if (rpc == 'admin_customer_action_reason') {
          sent = params;
          return {'ok': true, 'message': 'Customer status updated.'};
        }
        return {'ok': true, 'blocks': const []};
      };
      await t.pumpWidget(MaterialApp(
          home: const AdminCustomerPage(customerId: 'c-1')));
      await t.pumpAndSettle();

      await t.tap(find.byIcon(Icons.arrow_drop_down_circle_outlined));
      await t.pumpAndSettle();
      await t.tap(find.text('Block').last);
      await t.pumpAndSettle();

      // The reason dialog is the backend's copy.
      expect(find.text('Give a reason'), findsOneWidget);
      await t.enterText(find.byType(TextField), 'Repeated cheque bounce');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();

      // The success toast is a real Timer; let it expire inside the test.
      await t.pump(const Duration(seconds: 6));
      await t.pumpAndSettle();

      expect(sent, isNotNull);
      expect(sent!['p_action'], 'block');
      expect(sent!['p_reason'], 'Repeated cheque bounce');
      expect(sent!['p_customer_id'], 'c-1');
    });

    testWidgets('Approve carries NO reason, because the payload said none',
        (t) async {
      Map<String, dynamic>? sent;
      AdminCustomerPage.rpcOverride = (rpc, params) async {
        if (rpc == 'admin_customer_page') return _page();
        if (rpc == 'admin_customer_action_reason') {
          sent = params;
          return {'ok': true, 'message': 'Customer status updated.'};
        }
        return {'ok': true, 'blocks': const []};
      };
      await t.pumpWidget(MaterialApp(
          home: const AdminCustomerPage(customerId: 'c-1')));
      await t.pumpAndSettle();

      await t.tap(find.byIcon(Icons.arrow_drop_down_circle_outlined));
      await t.pumpAndSettle();
      await t.tap(find.text('Approve').last);
      await t.pumpAndSettle();

      await t.pump(const Duration(seconds: 6));
      await t.pumpAndSettle();

      expect(sent, isNotNull);
      expect(sent!['p_action'], 'approve');
      expect(sent!.containsKey('p_reason'), isFalse);
    });

    testWidgets('a chips block sends the backend\'s own arg and value back',
        (t) async {
      final calls = <Map<String, dynamic>>[];
      AdminCustomerPage.rpcOverride = (rpc, params) async {
        if (rpc == 'admin_customer_page') {
          return _page()..['default_tab'] = 'info';
        }
        calls.add(params);
        return {
          'ok': true,
          'blocks': [
            {
              'kind': 'chips',
              'title': 'Status',
              'arg': 'p_status',
              'chips': [
                {'key': '', 'value': '', 'label': 'All', 'count': 9, 'active': true},
                {'key': 'delivered', 'value': 'delivered', 'label': 'Delivered', 'count': 4},
              ],
            },
          ],
        };
      };
      await t.pumpWidget(MaterialApp(
          home: const AdminCustomerPage(customerId: 'c-1')));
      await t.pumpAndSettle();

      // The chip prints label + count exactly as sent.
      expect(find.text('Delivered  4'), findsOneWidget);
      await t.tap(find.text('Delivered  4'));
      await t.pumpAndSettle();
      expect(calls.last['p_status'], 'delivered');
    });
  });
}
