// PROTECTED — CHANGE #465, supplier register rows 64 and 65.
//
// Row 64: SPN is a GENERATED column on supplier_profiles and
// inquiry_engine_ranked_suppliers() orders the whole waterfall by it, yet every
// SPN RPC was admin-side. The number that decides whether a supplier is asked
// first or never was invisible to the supplier it describes.
//
// Row 65: notification_log had 35 rows for audience='supplier' and every single
// one was channel='whatsapp'. A supplier who opened the app was told nothing
// about a new inquiry, a new PO or a dispute waiting on them.
//
// What this file holds down is that BOTH surfaces are renderers. A scorecard
// that formats its own number, or an inbox that counts its own unread, is the
// same class of bug as the screens these two replaced — so every number here
// arrives already formatted (value_label, points_label, when_label) and every
// word arrives in the payload.
//
// No network, no Supabase: the views are pure and the payloads are literals.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/supplier/supplier_scorecard_inbox.dart';

Map<String, dynamic> _score({
  bool ok = true,
  bool active = true,
  bool hasRank = true,
}) =>
    {
      'ok': ok,
      'title': 'Your supplier number',
      'subtitle': 'This is the number that decides who mediBO asks first.',
      'spn': {'label': 'SPN', 'value': 535000, 'value_label': '535,000'},
      'status': {
        'is_active': active,
        'label': active ? 'Active' : 'Inactive',
        'tone': active ? 'success' : 'warning',
        'note': active
            ? 'Your account is active.'
            : 'Your account is not active, so your SPN counts as zero and you are not asked.',
      },
      'rank': {
        'has': hasRank,
        'label': 'Rank in your zone',
        'value': hasRank ? 9 : 0,
        'value_label': hasRank ? '#9' : '',
        'of_label': hasRank
            ? 'of 34 suppliers'
            : 'You are not in a zone yet, so there is no rank to show.',
      },
      'components_label': 'What makes it up',
      'components': [
        {
          'key': 'margin',
          'label': 'Margin',
          'points': 500000,
          'points_label': '500,000',
          'choice_label': '5'
        },
        {
          'key': 'ordered_medicine',
          'label': 'Ordered medicines',
          'points': 0,
          'points_label': '0',
          'choice_label': ''
        },
      ],
    };

Map<String, dynamic> _inbox({List<Map<String, dynamic>>? items, int unread = 1}) =>
    {
      'ok': true,
      'title': 'Notifications',
      'empty': 'Nothing new right now.',
      'empty_note': 'New inquiries, orders and disputes appear here.',
      'mark_all': 'Mark all read',
      'unread': unread,
      'badges': {'inquiry': 2, 'orders': 3, 'disputes': 0},
      'items': items ??
          [
            {
              'id': 2,
              'kind': 'dispute',
              'title': 'A dispute needs your answer',
              'body': 'A short or wrong item was reported.',
              'is_read': false,
              'when_label': '02 Sep 2026, 09:12 PM',
            },
            {
              'id': 1,
              'kind': 'order',
              'title': 'New purchase order',
              'body': 'An order has been raised on you.',
              'is_read': true,
              'when_label': '09 Aug 2026, 10:50 AM',
            },
          ],
    };

Future<void> _pump(WidgetTester t, Widget w) =>
    t.pumpWidget(MaterialApp(home: Scaffold(body: w)));

void main() {
  group('row 64 — the supplier can see their own number', () {
    testWidgets('every value is the backend\'s string, printed verbatim',
        (t) async {
      await _pump(t, SupplierScorecardView(payload: _score()));
      expect(find.text('Your supplier number'), findsOneWidget);
      // 535,000 is grouped SERVER-side. A Dart NumberFormat here would be the
      // bug: money and counts are formatted in one place, and it is not here.
      expect(find.text('535,000'), findsOneWidget);
      expect(find.text('#9'), findsOneWidget);
      expect(find.text('of 34 suppliers'), findsOneWidget);
      expect(find.text('500,000'), findsOneWidget);
    });

    testWidgets('an inactive account is told WHY it scores zero', (t) async {
      // The single most important fact and the least visible one: SPN is
      // multiplied by (status='active'), so an inactive supplier is never asked
      // at all. The sentence is the backend's, not a chip invented here.
      await _pump(t, SupplierScorecardView(payload: _score(active: false)));
      expect(
          find.text(
              'Your account is not active, so your SPN counts as zero and you are not asked.'),
          findsOneWidget);
    });

    testWidgets('an active account does not shout that note', (t) async {
      await _pump(t, SupplierScorecardView(payload: _score()));
      expect(find.textContaining('counts as zero'), findsNothing);
    });

    testWidgets('no rank means no rank block — not a guessed "#1"', (t) async {
      await _pump(t, SupplierScorecardView(payload: _score(hasRank: false)));
      expect(find.text('Rank in your zone'), findsNothing);
      expect(find.textContaining('#'), findsNothing);
    });

    testWidgets('ok:false draws nothing at all', (t) async {
      // The card is dropped on a shared screen, so a login that is not a
      // supplier must get an empty box rather than an error or a blank card.
      await _pump(t, SupplierScorecardView(payload: const {'ok': false}));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('a component with no choice prints its label alone', (t) async {
      await _pump(t, SupplierScorecardView(payload: _score()));
      expect(find.text('Margin · 5'), findsOneWidget);
      // ordered_medicine has no choice_label; it must not render a dangling '·'.
      expect(find.text('Ordered medicines'), findsOneWidget);
      expect(find.text('Ordered medicines · '), findsNothing);
    });
  });

  group('row 65 — the inbox that suppliers never had', () {
    testWidgets('items render in PAYLOAD order, with the backend\'s words',
        (t) async {
      await _pump(t,
          SupplierInboxView(payload: _inbox(), onMarkAll: () {}));
      expect(find.text('A dispute needs your answer'), findsOneWidget);
      expect(find.text('New purchase order'), findsOneWidget);
      expect(find.text('02 Sep 2026, 09:12 PM'), findsOneWidget);

      final dispute = t.getTopLeft(find.text('A dispute needs your answer'));
      final order = t.getTopLeft(find.text('New purchase order'));
      expect(dispute.dy, lessThan(order.dy),
          reason: 'the backend ordered these; the sheet must not re-sort them');
    });

    testWidgets('the empty state is the backend\'s two sentences', (t) async {
      await _pump(
          t,
          SupplierInboxView(
              payload: _inbox(items: const [], unread: 0), onMarkAll: () {}));
      expect(find.text('Nothing new right now.'), findsOneWidget);
      expect(find.text('New inquiries, orders and disputes appear here.'),
          findsOneWidget);
    });

    testWidgets('Mark all read appears only when the BACKEND says unread > 0',
        (t) async {
      await _pump(t,
          SupplierInboxView(payload: _inbox(unread: 0), onMarkAll: () {}));
      expect(find.text('Mark all read'), findsNothing);

      var tapped = 0;
      await _pump(
          t,
          SupplierInboxView(
              payload: _inbox(unread: 2), onMarkAll: () => tapped++));
      expect(find.text('Mark all read'), findsOneWidget);
      await t.tap(find.text('Mark all read'));
      expect(tapped, 1);
    });

    testWidgets('the unread count is never recomputed from the items',
        (t) async {
      // Two items, one of them unread — but the payload says unread:0. The
      // server is the only authority on what has been read (it is the one
      // holding read_at), so the button stays away.
      await _pump(t,
          SupplierInboxView(payload: _inbox(unread: 0), onMarkAll: () {}));
      expect(find.text('Mark all read'), findsNothing);
    });

    testWidgets('a null payload renders the loader, not an empty inbox',
        (t) async {
      // "There is nothing" and "we have not asked yet" are different facts, and
      // printing the first for the second is how a supplier is told they have
      // no work when they do.
      await _pump(t,
          SupplierInboxView(payload: null, loading: true, onMarkAll: () {}));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Nothing new right now.'), findsNothing);
    });
  });
}
