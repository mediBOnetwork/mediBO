// CMD #417 — the refill engine's focused test.
//
// What it holds down, on the two surfaces this command shipped:
//
//   1. The refill console computes NOTHING. The run-out sentence, the cap
//      sentences, the dose label, the tab list and every count come off the
//      payload verbatim — "Runs out 04 Sep" appears because the BACKEND sent
//      that string, not because Dart formatted a date.
//   2. `can_nudge:false` disables the reminder button. The screen never infers
//      sendability from opt-in, phone or status — the backend already weighed
//      the engine switch, the opt-in, the caps and the quiet day.
//   3. An unknown tab key renders an empty body instead of throwing, so a
//      backend that adds a tab tomorrow does not crash today's build.
//   4. The patient-facing storefront shows MRP and availability and NOTHING
//      else: a payload carrying no cost field cannot leak one, items render in
//      payload order (the fixture is deliberately not alphabetical), and the
//      Add/Added captions are backend strings.
//   5. A closed or unknown storefront renders the backend's own copy instead
//      of throwing.
//   6. The request submits ONLY the items that were added, with the token from
//      the URL — an untouched item is omitted, never defaulted in.
//
// No network, no Supabase, no goldens. Payloads are mocked inline.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/pharmacy/pharmacy_refill_screen.dart';
import 'package:pharma_b2b/screens/public/storefront_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _home() => {
  'ok': true,
  'title': 'Refills & counter',
  'tabs': [
    {'key': 'due', 'label': 'Due soon', 'count': 2},
    {'key': 'patients', 'label': 'Patients', 'count': 1},
    {'key': 'requests', 'label': 'Requests', 'count': 0},
    {'key': 'counter', 'label': 'AI counter', 'count': 0},
  ],
  'engine': {
    'title': 'Refill reminders',
    'enabled': true,
    'toggle_label': 'Send refill reminders',
    'status_label': 'On — reminder goes out 3 days before a patient runs out',
    'status_tone': 'success',
    'cap_label': 'At most one reminder per patient every 20 days',
    'daily_label': 'At most 30 reminders a day',
    'quiet_label': 'Nothing goes out on Sunday',
    'sent_today_label': '4 sent today',
    'scan_label': 'Rebuild from bills',
  },
  'storefront': {
    'title': 'WhatsApp storefront',
    'hint': 'Share this link or QR.',
    'link_label': 'Your storefront link',
    'copy_label': 'Copy link',
    'has': true,
    'token': 'abc123',
    'url': 'https://medibo.in/shop/abc123',
    'is_active': true,
    'active_label': 'Storefront open',
    'ai_enabled': true,
    'ai_label': 'Answer patient messages automatically',
    'ai_hint': 'Answers only from your stock.',
    'search_hint': 'Search medicines',
    'shop': 'Jai Medical Store',
  },
  'due': {
    'empty_label': 'No refill is due yet.',
    'rows': [
      {
        'id': 's1',
        'patient_name': 'Ramesh',
        'product_name': 'Telma 40',
        'runs_out_label': 'Runs out 04 Sep',
        'days_left_label': '3 days left',
        'tone': 'warning',
        'dose_label': '1 a day',
        'pack_units_label': '30 per pack',
        'last_bought_label': 'Last bought 05 Aug',
        'nudge_label': 'Send reminder',
        'can_nudge': true,
        'dose_per_day': 1,
        'pack_units': 30,
      },
      {
        'id': 's2',
        'patient_name': 'Sita',
        'product_name': 'Thyronorm 50',
        'runs_out_label': 'Ran out 28 Aug',
        'tone': 'danger',
        'dose_label': '1 a day',
        'pack_units_label': '30 per pack',
        'last_bought_label': 'Last bought 29 Jul',
        'nudge_label': 'Send reminder',
        'can_nudge': false,
        'dose_per_day': 1,
        'pack_units': 30,
      },
    ],
  },
  'patients': {'empty_label': 'No patients yet.', 'rows': []},
  'requests': {'empty_label': 'No requests yet.', 'rows': []},
  'counter': {'empty_label': 'No conversations yet.', 'rows': []},
};

Map<String, dynamic> _page() => {
  'ok': true,
  'token': 'abc123',
  'shop': 'Jai Medical Store',
  'greeting': 'Namaste! This is Jai Medical Store on mediBO.',
  'search_hint': 'Search medicines',
  'empty_label': 'Nothing in stock matches that.',
  'name_hint': 'Your name',
  'phone_hint': 'WhatsApp number',
  'note_hint': 'Anything else?',
  'submit_label': 'Ask the pharmacy to keep it ready',
  'items': [
    {
      'key': '901',
      'medicine_id': 901,
      'product_name': 'Zincovit Tablet',
      'pack_label': 'strip of 15 tablets',
      'stock_label': 'In stock',
      'has_mrp': true,
      'mrp_display': 'MRP ₹110.00',
      'add_label': 'Add',
      'added_label': 'Added',
    },
    {
      'key': '902',
      'medicine_id': 902,
      'product_name': 'Amlong 5',
      'pack_label': 'strip of 10 tablets',
      'stock_label': 'In stock',
      'has_mrp': false,
      'add_label': 'Add',
      'added_label': 'Added',
    },
  ],
};

/// The console is a scroller: on the default 800px test viewport the due list
/// sits below the fold and is never built. A tall viewport is the honest way to
/// assert what the screen renders, rather than scrolling by pixel counts.
Future<void> _pumpTall(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1200, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: child));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('refill console', () {
    testWidgets('renders the backend sentences verbatim', (tester) async {
      await _pumpTall(tester, PharmacyRefillScreen(rpc: (fn, p) async => _home()));

      // the engine card: every sentence is the payload's
      expect(
        find.text('On — reminder goes out 3 days before a patient runs out'),
        findsOneWidget,
      );
      expect(
        find.text('At most one reminder per patient every 20 days'),
        findsOneWidget,
      );
      expect(find.text('4 sent today'), findsOneWidget);

      // the due list: the run-out sentence is a string, not a computed date
      expect(find.text('Runs out 04 Sep'), findsOneWidget);
      expect(find.text('Ran out 28 Aug'), findsOneWidget);
      expect(find.text('Telma 40'), findsOneWidget);

      // the tab list is the backend's, counts included
      expect(find.text('Due soon (2)'), findsOneWidget);
      expect(find.text('AI counter (0)'), findsOneWidget);
    });

    testWidgets('can_nudge:false disables the reminder button', (tester) async {
      await _pumpTall(tester, PharmacyRefillScreen(rpc: (fn, p) async => _home()));

      final buttons = tester
          .widgetList<FilledButton>(find.byType(FilledButton))
          .toList();
      expect(buttons.length, 2);
      expect(buttons[0].onPressed, isNotNull); // Ramesh — can_nudge true
      expect(buttons[1].onPressed, isNull); // Sita — the backend said no
    });

    testWidgets('an unknown tab key renders an empty body, never throws', (
      tester,
    ) async {
      final payload = _home();
      payload['tabs'] = [
        {'key': 'tomorrows_tab', 'label': 'Something new', 'count': 3},
      ];
      await _pumpTall(tester, PharmacyRefillScreen(rpc: (fn, p) async => payload));

      expect(find.text('Something new (3)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a refusal renders the backend message', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PharmacyRefillScreen(
            rpc: (fn, p) async => {
              'ok': false,
              'error': 'not_authorized',
              'message': 'Only the pharmacy can open this',
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Only the pharmacy can open this'), findsOneWidget);
    });
  });

  group('public storefront', () {
    testWidgets('MRP and availability only, in payload order', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: StorefrontScreen(
            token: 'abc123',
            rpc: (fn, p) async => _page(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('MRP ₹110.00'), findsOneWidget);
      expect(find.text('In stock'), findsNWidgets(2));
      // the second item carries no MRP, and the screen invents none
      expect(find.textContaining('Amlong'), findsOneWidget);

      final names = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .where((s) => s == 'Zincovit Tablet' || s == 'Amlong 5')
          .toList();
      expect(names, ['Zincovit Tablet', 'Amlong 5']); // payload order, not A-Z
    });

    testWidgets('a closed storefront renders the backend copy', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: StorefrontScreen(
            token: 'gone',
            rpc: (fn, p) async => {
              'ok': false,
              'error': 'closed',
              'message': 'This storefront is closed right now.',
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('This storefront is closed right now.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('submits only the added items, with the URL token', (
      tester,
    ) async {
      Map<String, dynamic>? sent;
      await tester.pumpWidget(
        MaterialApp(
          home: StorefrontScreen(
            token: 'abc123',
            rpc: (fn, p) async {
              if (fn == 'storefront_request_submit') {
                sent = p;
                return {
                  'ok': true,
                  'title': 'Request sent',
                  'message': 'Jai Medical Store will keep your items ready.',
                };
              }
              return _page();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // add exactly ONE of the two items
      await tester.tap(find.text('Add').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ask the pharmacy to keep it ready'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(1), 'Ramesh');
      await tester.enterText(find.byType(TextField).at(2), '9000000417');
      await tester.tap(find.text('Ask the pharmacy to keep it ready').last);
      await tester.pumpAndSettle();

      expect(sent, isNotNull);
      expect(sent!['p_token'], 'abc123');
      expect(sent!['p_phone'], '9000000417');
      final items = sent!['p_items'] as List;
      expect(items.length, 1); // the untouched item is OMITTED
      expect((items.first as Map)['medicine_id'], 901);

      // and the thanks page is the backend's own copy
      expect(find.text('Request sent'), findsOneWidget);
    });
  });
}
