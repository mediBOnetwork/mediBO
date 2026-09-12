// CMD #420 — the exchange renders the backend and judges nothing.
//
// The failure this file exists to prevent is specific and legal, not cosmetic:
// a near-expiry sale between two pharmacies is legitimate BECAUSE the buyer was
// told the batch and expiry. So the tests below are mostly one assertion in
// different places — the disclosure, the batch and the expiry are backend
// strings that reach the screen unchanged, at the moment of browsing AND at the
// moment of committing — plus the privacy rule for borrow (the searching shop
// learns who and how far, never how much the other shop holds).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/pharmacy/px_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _home({List<Map<String, dynamic>>? deals, bool eligible = true}) => {
  'ok': true,
  'eligible': eligible,
  'not_eligible_message':
      'The exchange is open to approved, active pharmacies with a zone set.',
  'shop_name': 'Chandra Medicom',
  'labels': {
    'title': 'Exchange',
    'browse': 'Dead stock nearby',
    'borrow': 'Emergency borrow',
    'deals': 'Movements',
    'retry': 'Retry',
    'load_failed': 'The exchange could not be loaded.',
  },
  'pending_label': null,
  'deals': deals ?? const [],
  'empty_deals': {'title': 'No movements yet'},
};

Map<String, dynamic> _listing(Map<String, dynamic> over) => {
  'listing_id': 'l1',
  'product_name': 'Amoxycillin 500',
  'pack_label': '10 caps',
  'seller_name': 'Beta Chemists',
  'qty_label': '10 available',
  'price_display': '₹70.00',
  'batch_label': 'Batch B420',
  'expiry_label': 'Expiry 03/27',
  'days_label': '75 days to expiry',
  'tone': 'warning',
  'disclosure':
      'Amoxycillin 500 — batch B420, expiry 03/27 (75 days left). '
      'You are buying this batch with that expiry.',
  'distance_hint': 'about 2.8 km away',
  ...over,
};

Map<String, dynamic> _browse({List<Map<String, dynamic>>? rows}) => {
  'ok': true,
  'labels': {
    'buy': 'Buy',
    'qty': 'Quantity',
    'confirm': 'Confirm',
    'cancel': 'Not now',
    'retry': 'Retry',
    'load_failed': 'The exchange could not be loaded.',
  },
  'fee_note': 'No mediBO fee',
  'disclosure_note':
      'Batch and expiry are shown on every listing, and your acceptance of '
      'them is recorded on the invoice.',
  'rows': rows ?? [_listing(const {})],
  'empty': {
    'title': 'Nothing listed in your zone yet',
    'hint': 'When a nearby pharmacy lists slow stock it appears here.',
  },
};

Map<String, dynamic> _borrow({List<Map<String, dynamic>>? rows}) => {
  'ok': true,
  'labels': {
    'title': 'Emergency borrow',
    'search_hint': 'Medicine the patient is waiting for',
    'request': 'Request',
    'qty': 'Quantity',
    'retry': 'Retry',
  },
  'privacy_note':
      'You can see who has the item and how far away they are — never how '
      'much of anything they hold.',
  'rows': rows ?? const [],
  'empty': {
    'title': 'No nearby pharmacy has it in stock',
    'hint': 'Try the salt name, or order it on mediBO instead.',
  },
};

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  Future<void> pump(WidgetTester t, Widget w) async {
    await t.pumpWidget(MaterialApp(home: w));
    await t.pumpAndSettle();
  }

  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) rpcOf({
    Map<String, dynamic>? home,
    Map<String, dynamic>? browse,
    Map<String, dynamic>? borrow,
    Map<String, dynamic>? deal,
    void Function(String, Map<String, dynamic>)? onCall,
  }) {
    return (fn, p) async {
      onCall?.call(fn, p);
      switch (fn) {
        case 'px_home':
          return home ?? _home();
        case 'px_browse':
          return browse ?? _browse();
        case 'px_borrow_search':
          return borrow ?? _borrow();
        case 'px_deal_detail':
          return deal ?? const {'ok': true};
        default:
          return const {'ok': true};
      }
    };
  }

  group('the disclosure is not optional', () {
    testWidgets('batch, expiry and days-left are ON the browse row', (t) async {
      await pump(t, PxScreen(rpc: rpcOf()));

      // Not behind a tap, not a colour the reader has to interpret — the words.
      expect(find.text('Batch B420'), findsOneWidget);
      expect(find.text('Expiry 03/27'), findsOneWidget);
      expect(find.text('75 days to expiry'), findsOneWidget);
      expect(find.text('₹70.00'), findsOneWidget);
    });

    testWidgets('the screen never computes "days left" — it prints the payload',
        (t) async {
      await pump(
        t,
        PxScreen(
          rpc: rpcOf(
            browse: _browse(rows: [
              // a deliberately odd pair: the backend says 400 days and calls it
              // info; the screen must not "correct" either
              _listing({'days_label': '400 days to expiry', 'tone': 'info'}),
            ]),
          ),
        ),
      );
      expect(find.text('400 days to expiry'), findsOneWidget);
    });

    testWidgets('the disclosure note is the backend sentence', (t) async {
      await pump(t, PxScreen(rpc: rpcOf()));
      expect(
        find.text(
          'Batch and expiry are shown on every listing, and your acceptance of '
          'them is recorded on the invoice.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('buying repeats the disclosure at the moment of committing',
        (t) async {
      await pump(t, PxScreen(rpc: rpcOf()));
      await t.tap(find.widgetWithText(FilledButton, 'Buy'));
      await t.pumpAndSettle();

      expect(
        find.text(
          'Amoxycillin 500 — batch B420, expiry 03/27 (75 days left). '
          'You are buying this batch with that expiry.',
        ),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Confirm'), findsOneWidget);
    });

    testWidgets('a refused purchase shows the backend message, sheet stays open',
        (t) async {
      await pump(
        t,
        PxScreen(
          rpc: (fn, p) async {
            if (fn == 'px_accept_listing') {
              return {
                'ok': false,
                'error': 'gone',
                'message': 'That listing has just gone.',
              };
            }
            if (fn == 'px_home') return _home();
            if (fn == 'px_browse') return _browse();
            return const {'ok': true};
          },
        ),
      );
      await t.tap(find.widgetWithText(FilledButton, 'Buy'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(FilledButton, 'Confirm'));
      await t.pumpAndSettle();

      expect(find.text('That listing has just gone.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Confirm'), findsOneWidget);
    });

    testWidgets('a purchase carries a client_action_id so a double tap is one deal',
        (t) async {
      Map<String, dynamic>? sent;
      await pump(
        t,
        PxScreen(
          rpc: (fn, p) async {
            if (fn == 'px_accept_listing') {
              sent = p;
              return {'ok': true, 'message': 'Accepted'};
            }
            if (fn == 'px_home') return _home();
            if (fn == 'px_browse') return _browse();
            return const {'ok': true};
          },
        ),
      );
      await t.tap(find.widgetWithText(FilledButton, 'Buy'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(FilledButton, 'Confirm'));
      await t.pumpAndSettle();

      expect(sent, isNotNull);
      expect(sent!['p_listing_id'], 'l1');
      expect(sent!['p_qty'], 1);
      expect((sent!['p_client_action_id'] as String).length, 36);
    });
  });

  group('emergency borrow keeps the other shop private', () {
    testWidgets('the privacy note is shown before any result', (t) async {
      await pump(t, PxScreen(rpc: rpcOf()));
      await t.tap(find.text('Emergency borrow'));
      await t.pumpAndSettle();

      expect(
        find.text(
          'You can see who has the item and how far away they are — never how '
          'much of anything they hold.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a result shows who, how far and how soon — and no quantity',
        (t) async {
      await pump(
        t,
        PxScreen(
          rpc: rpcOf(
            borrow: _borrow(rows: [
              {
                'pharmacy_id': 'p2',
                'stock_id': 's2',
                'seller_name': 'Beta Chemists',
                'product_name': 'Insulin Pen',
                'has_enough': true,
                'price_display': '₹320.00',
                'price_basis': 'at MRP',
                'distance_hint': 'about 2.8 km away',
                'promise_label': 'Rider within 90 minutes',
              },
            ]),
          ),
        ),
      );
      await t.tap(find.text('Emergency borrow'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).first, 'Insulin');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();

      expect(find.text('Beta Chemists'), findsOneWidget);
      expect(find.text('₹320.00'), findsOneWidget);
      expect(
        find.text('about 2.8 km away · Rider within 90 minutes · at MRP'),
        findsOneWidget,
      );
      // the whole point: no stock level anywhere on the row
      expect(find.textContaining('in stock'), findsNothing);
      expect(find.textContaining('available'), findsNothing);
    });

    testWidgets('Request is disabled when the backend says has_enough is false',
        (t) async {
      await pump(
        t,
        PxScreen(
          rpc: rpcOf(
            borrow: _borrow(rows: [
              {
                'pharmacy_id': 'p2',
                'stock_id': 's2',
                'seller_name': 'Beta Chemists',
                'product_name': 'Insulin Pen',
                'has_enough': false,
                'price_display': '₹320.00',
                'price_basis': 'at MRP',
                'distance_hint': 'about 2.8 km away',
                'promise_label': 'Rider within 90 minutes',
              },
            ]),
          ),
        ),
      );
      await t.tap(find.text('Emergency borrow'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).first, 'Insulin');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();

      final btn = t.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Request'),
      );
      expect(btn.onPressed, isNull);
    });
  });

  group('eligibility and refusals are the backend\'s words', () {
    testWidgets('an ineligible pharmacy sees the backend sentence, no tabs body',
        (t) async {
      await pump(t, PxScreen(rpc: rpcOf(home: _home(eligible: false))));
      expect(
        find.text(
          'The exchange is open to approved, active pharmacies with a zone set.',
        ),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Buy'), findsNothing);
    });

    testWidgets('a non-pharmacy sees the refusal and no exchange at all',
        (t) async {
      await pump(
        t,
        PxScreen(
          rpc: (fn, p) async => {
            'ok': false,
            'error': 'not_a_pharmacy',
            'message': 'The exchange is for pharmacy accounts.',
          },
        ),
      );
      expect(find.text('The exchange is for pharmacy accounts.'), findsOneWidget);
    });
  });

  group('one movement', () {
    testWidgets('the deal prints its status, disclosure and both tax lines',
        (t) async {
      await pump(
        t,
        PxDealScreen(
          dealId: 'd1',
          rpc: (fn, p) async => {
            'ok': true,
            'deal_id': 'd1',
            'kind_label': 'Exchange',
            'side_label': 'You bought',
            'counterparty': 'Alpha Medicals',
            'status_label': 'Accepted — rider booked',
            'status_tone': 'info',
            'product_name': 'Amoxycillin 500',
            'qty_label': '4 units',
            'batch_label': 'Batch B420',
            'expiry_label': 'Expiry 03/27',
            'disclosure':
                'Amoxycillin 500 — batch B420, expiry 03/27 (75 days left). '
                'You are buying this batch with that expiry.',
            'disclosure_accepted_label':
                'Batch and expiry accepted 01 Sep 2026 10:12',
            'price_display': '₹70.00',
            'gst_label': 'GST 12%',
            'cgst_display': '₹16.80',
            'sgst_display': '₹16.80',
            'total_display': '₹313.60',
            'fee_display': 'No mediBO fee',
            'invoice_no': 'PX/2026-27/00001',
            'distance_label': '2.8 km by road',
            'eta_label': 'about 9 min',
            'promise_label': 'Promised by 18:28',
            'can_decide': false,
            'labels': {
              'accept': 'Accept',
              'decline': 'Decline',
              'invoice': 'Invoice',
              'retry': 'Retry',
              'load_failed': 'The exchange could not be loaded.',
            },
          },
        ),
      );

      expect(find.text('Accepted — rider booked'), findsOneWidget);
      expect(find.text('₹313.60'), findsOneWidget);
      expect(find.text('₹16.80 + ₹16.80'), findsOneWidget);
      expect(find.text('PX/2026-27/00001'), findsOneWidget);
      expect(
        find.text('Batch and expiry accepted 01 Sep 2026 10:12'),
        findsOneWidget,
      );
      expect(
        find.text('2.8 km by road · about 9 min · Promised by 18:28'),
        findsOneWidget,
      );
      // not deciding: the payload said so, and no buttons are offered
      expect(find.widgetWithText(FilledButton, 'Accept'), findsNothing);
    });

    testWidgets('the holder is offered Accept/Decline only when can_decide',
        (t) async {
      await pump(
        t,
        PxDealScreen(
          dealId: 'd1',
          rpc: (fn, p) async => {
            'ok': true,
            'deal_id': 'd1',
            'kind_label': 'Borrow',
            'side_label': 'You sold',
            'counterparty': 'Alpha Medicals',
            'status_label': 'Waiting for the other shop',
            'status_tone': 'warning',
            'product_name': 'Insulin Pen',
            'qty_label': '1 units',
            'total_display': '₹336.00',
            'fee_display': 'No mediBO fee',
            'can_decide': true,
            'labels': {
              'accept': 'Accept',
              'decline': 'Decline',
              'invoice': 'Invoice',
              'retry': 'Retry',
              'load_failed': 'x',
            },
          },
        ),
      );
      expect(find.widgetWithText(FilledButton, 'Accept'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Decline'), findsOneWidget);
    });
  });
}
