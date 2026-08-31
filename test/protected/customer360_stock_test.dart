// CHANGE #396 — the two screens that must never start computing.
//
// Customer 360 and Stock on hand are pure renderers: every label, tone, age
// string, percentage and ₹ figure arrives already made from `customer_360`
// and `stock_on_hand`. These tests hold that down — feed a payload whose
// strings could not possibly be produced in Dart, and assert the screen prints
// exactly those.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/admin_customer_360_screen.dart';
import 'package:pharma_b2b/screens/admin/admin_stock_on_hand_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _c360Payload() => {
      'ok': true,
      'customer_id': 'cust-1',
      'title': 'CUSTOMER-360-TITLE',
      'retry_label': 'RETRY-LABEL',
      'months_label': 'MONTHS-HEADING',
      'header': {
        'name': 'PHARMACY-NAME',
        'status_label': 'STATUS-LABEL',
        'status_tone': 'success',
        'fields': [
          {'label': 'FIELD-ONE', 'value': 'VALUE-ONE'},
          {'label': 'FIELD-TWO', 'value': 'VALUE-TWO'},
        ],
      },
      'credit': {
        'has': true,
        'limit_label': 'CREDIT-LABEL',
        'limit_display': '₹1234.00',
        'prepaid_only': true,
        'prepaid_label': 'PREPAID-LABEL',
      },
      'tiles': [
        {'key': 'lifetime', 'label': 'TILE-LABEL', 'value': '₹99.00', 'tone': 'info'},
      ],
      'slab': {
        'has': true,
        'pct_display': 'SLAB-PCT',
        'basis_label': 'SLAB-BASIS',
        'ladder': [
          {'label': '5%', 'from_display': '₹5999.00', 'active': true},
        ],
      },
      'months': [
        {'label': 'MONTH-LABEL', 'orders': 3, 'value_display': '₹31361.31'},
      ],
      'orders': {
        'label': 'ORDERS-HEADING',
        'empty': 'ORDERS-EMPTY',
        'rows': [
          {
            'order_id': 'o1',
            'order_code': 'ORDER-CODE',
            'date_label': 'DATE-LABEL',
            'items_label': 'ITEMS-LABEL',
            'status_label': 'ORDER-STATUS',
            'status_tone': 'danger',
            'value_display': '₹500.00',
            'outstanding_display': '₹123.00',
            'is_settled': false,
          },
        ],
      },
      'payments': {
        'label': 'PAYMENTS-HEADING',
        'empty': 'PAYMENTS-EMPTY',
        'billed_label': 'BILLED-LABEL',
        'paid_label': 'PAID-LABEL',
        'outstanding_label': 'OUTSTANDING-LABEL',
        'note': 'PAYMENTS-NOTE',
        'billed_display': '₹64901.26',
        'paid_display': '₹4556.00',
        'outstanding_display': '₹60345.26',
        'rows': [],
      },
      'disputes': {'label': 'DISPUTES-HEADING', 'empty': 'DISPUTES-EMPTY', 'count': 0, 'rows': []},
      'margin': {
        'label': 'MARGIN-HEADING',
        'has': false,
        'empty': 'MARGIN-EMPTY',
      },
      'delivery': {
        'label': 'DELIVERY-HEADING',
        'has': true,
        'attempts_label': 'ATTEMPTS-LABEL',
        'delivered_label': 'DELIVERED-LABEL',
        'failed_label': 'FAILED-LABEL',
        'attempts': 10,
        'delivered': 9,
        'failed': 1,
        'success_display': 'SUCCESS-PCT',
        'success_tone': 'success',
      },
      'whatsapp': {'label': 'WA-HEADING', 'empty': 'WA-EMPTY', 'count': 0, 'rows': []},
      'section_labels': {'identity': 'IDENTITY', 'money': 'MONEY', 'slab': 'SLAB-HEADING'},
    };

Map<String, dynamic> _stockPayload() => {
      'ok': true,
      'title': 'STOCK-TITLE',
      'subtitle': 'STOCK-SUBTITLE',
      'empty_label': 'STOCK-EMPTY',
      'refresh_label': 'RESCAN-LABEL',
      'writeoff_label': 'WRITEOFF-LABEL',
      'retry_label': 'RETRY-LABEL',
      'aged_days': 30,
      'tiles': [
        {'key': 'value', 'label': 'VALUE-TILE', 'value': '₹10777.26', 'tone': 'info'},
      ],
      'kinds': [
        {
          'key': 'stalled',
          'label': 'KIND-LABEL',
          'chip_label': 'CHIP-LABEL',
          'lots': 9,
          'units': 33,
          'value_display': '₹10777.26'
        },
      ],
      'columns': ['C1', 'C2'],
      'rows': [
        {
          'lot_id': 7,
          'product_name': 'PRODUCT-NAME',
          'batch_label': 'BATCH-LABEL',
          'expiry_label': 'EXPIRY-LABEL',
          'supplier_name': 'SUPPLIER-NAME',
          'source_label': 'SOURCE-LABEL',
          'order_code': 'ORDER-CODE',
          'qty_label': '2',
          'qty_rate_display': '2 × ₹47.31',
          'source_order_label': 'ORDER-CODE · SUPPLIER-NAME',
          'age_label': 'AGE-LABEL',
          'age_tone': 'danger',
          'rate_display': '₹47.31',
          'value_display': '₹94.62',
        },
      ],
      'has_more': false,
    };

/// A tall viewport so the whole page is BUILT — a lazy ListView would
/// otherwise never construct the sections below the fold and the test would
/// pass or fail on scroll position rather than on the payload.
Future<void> _pump(WidgetTester t, Widget child) async {
  t.view.physicalSize = const Size(1200, 5000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(MaterialApp(home: child));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  tearDown(() {
    AdminCustomer360Screen.rpcOverride = null;
    AdminStockOnHandScreen.rpcOverride = null;
  });

  group('Customer 360 renders the backend payload verbatim', () {
    testWidgets('every label, tone word and ₹ figure comes from the payload',
        (t) async {
      AdminCustomer360Screen.rpcOverride = (fn, params) async {
        expect(fn, 'customer_360');
        expect(params?['p_customer_id'], 'cust-1');
        return _c360Payload();
      };
      await _pump(t, const AdminCustomer360Screen(customerId: 'cust-1'));

      // identity — the field list is the BACKEND's, not a Dart key list
      expect(find.text('PHARMACY-NAME'), findsWidgets);
      expect(find.text('STATUS-LABEL'), findsOneWidget);
      expect(find.text('FIELD-ONE'), findsOneWidget);
      expect(find.text('VALUE-ONE'), findsOneWidget);
      expect(find.text('FIELD-TWO'), findsOneWidget);
      expect(find.text('CREDIT-LABEL'), findsOneWidget);
      expect(find.text('PREPAID-LABEL'), findsOneWidget);

      // money — never recomputed, never re-formatted
      expect(find.text('₹64901.26'), findsOneWidget);
      expect(find.text('₹4556.00'), findsOneWidget);
      expect(find.text('₹60345.26'), findsOneWidget);
      expect(find.text('BILLED-LABEL'), findsOneWidget);
      expect(find.text('PAID-LABEL'), findsOneWidget);
      expect(find.text('OUTSTANDING-LABEL'), findsOneWidget);
      expect(find.text('PAYMENTS-NOTE'), findsOneWidget);

      // the slab, the months, the orders and the delivery rate
      expect(find.text('SLAB-PCT'), findsOneWidget);
      expect(find.text('SLAB-BASIS'), findsOneWidget);
      expect(find.text('MONTHS-HEADING'), findsOneWidget);
      expect(find.text('MONTH-LABEL'), findsOneWidget);
      expect(find.text('ORDER-CODE'), findsOneWidget);
      expect(find.text('ORDER-STATUS'), findsOneWidget);
      expect(find.text('SUCCESS-PCT'), findsOneWidget);
      expect(find.text('ATTEMPTS-LABEL'), findsOneWidget);
    });

    testWidgets('absence is the backend saying so, never an exception',
        (t) async {
      AdminCustomer360Screen.rpcOverride = (fn, params) async => _c360Payload();
      await _pump(t, const AdminCustomer360Screen(customerId: 'cust-1'));
      // margin has:false → the backend's sentence, not a zero row
      expect(find.text('MARGIN-EMPTY'), findsOneWidget);
      expect(find.text('DISPUTES-EMPTY'), findsOneWidget);
      expect(find.text('WA-EMPTY'), findsOneWidget);
    });

    testWidgets('ok:false prints the backend refusal instead of a screen',
        (t) async {
      AdminCustomer360Screen.rpcOverride = (fn, params) async =>
          {'ok': false, 'message': 'REFUSAL-COPY', 'title': 'T'};
      await _pump(t, const AdminCustomer360Screen(customerId: 'cust-1'));
      expect(find.text('REFUSAL-COPY'), findsOneWidget);
      expect(find.text('PHARMACY-NAME'), findsNothing);
    });
  });

  group('Stock on hand renders the backend payload verbatim', () {
    testWidgets('age, source, batch, rate and value are all backend strings',
        (t) async {
      AdminStockOnHandScreen.rpcOverride = (fn, params) async {
        expect(fn, 'stock_on_hand');
        return _stockPayload();
      };
      await _pump(t, const AdminStockOnHandScreen());

      expect(find.text('STOCK-SUBTITLE'), findsOneWidget);
      expect(find.text('VALUE-TILE'), findsOneWidget);
      expect(find.text('₹10777.26'), findsOneWidget);
      expect(find.text('PRODUCT-NAME'), findsOneWidget);
      expect(find.text('AGE-LABEL'), findsOneWidget);
      expect(find.text('SOURCE-LABEL'), findsOneWidget);
      expect(find.text('BATCH-LABEL'), findsOneWidget);
      expect(find.text('EXPIRY-LABEL'), findsOneWidget);
      expect(find.text('₹94.62'), findsOneWidget);
      // the qty × rate line is ONE backend string — Dart does not join it
      expect(find.text('2 × ₹47.31'), findsOneWidget);
      expect(find.text('ORDER-CODE · SUPPLIER-NAME'), findsOneWidget);
      expect(find.text('CHIP-LABEL'), findsOneWidget);
      expect(find.text('WRITEOFF-LABEL'), findsOneWidget);
    });

    testWidgets('an empty warehouse shows the backend sentence', (t) async {
      AdminStockOnHandScreen.rpcOverride = (fn, params) async {
        final p = _stockPayload();
        p['rows'] = [];
        p['kinds'] = [];
        return p;
      };
      await _pump(t, const AdminStockOnHandScreen());
      expect(find.text('STOCK-EMPTY'), findsOneWidget);
      expect(find.text('PRODUCT-NAME'), findsNothing);
    });

    testWidgets('ok:false prints the backend refusal', (t) async {
      AdminStockOnHandScreen.rpcOverride = (fn, params) async =>
          {'ok': false, 'message': 'STOCK-REFUSAL', 'title': 'T'};
      await _pump(t, const AdminStockOnHandScreen());
      expect(find.text('STOCK-REFUSAL'), findsOneWidget);
    });
  });
}
