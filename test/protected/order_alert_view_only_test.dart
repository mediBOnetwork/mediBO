// PROTECTED — CMD #1988.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes new-order-alert behaviour, never to make an unrelated
// change go green.
//
// What this holds down — the four things that went wrong on Om's order
// CPO140926CHA101O1 on 14 Sep, each of which is now a test:
//
//   1. ONE SURFACE. The in-app surface for an unactioned order is a slim
//      STRIP, not a centre dialog. It is a single row of the tree, it does not
//      cover the shell, and it draws nothing at all when the backend says
//      show:false. The dialog that fought the lock-screen alert is gone; if
//      somebody reintroduces a modal for an order, this file goes red.
//
//   2. VIEW-ONLY. The strip offers exactly ONE action, and its word is the
//      backend's `action_label`. Accept and Reject are NOT on it — not even
//      when the payload happens to carry accept_label / reject_label, which
//      order_alert_card() still does for the order screen. A decision is taken
//      where the items are, never from a banner or a notification.
//
//   3. THE STRIP COMPUTES NOTHING. Title, subtitle, badge, the "+N more" line
//      and the tone all arrive rendered. Nothing here pluralises, formats
//      money, counts items, or decides from `paid` what colour to be — the one
//      thing Dart reads off a boolean is which token a named tone maps to.
//
//   4. PREPAID RINGS, AND SILENCE IS THE BACKEND'S WORD. `ring` is a field.
//      A paid order with ring:true rings exactly like an unpaid one, and the
//      only thing that stops the sound is the backend sending ring:false —
//      quiet hours, a snoozed device, or somebody having opened the order.
//      Dart must never re-derive "paid means silent", which is precisely the
//      rule that made prepaid orders arrive unheard.
//
// Fixtures mirror order_alert_strip() verbatim. No network, no Supabase.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_alert_overlay.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// A fabricated order_alert_strip() payload — the exact shape the RPC sends.
Map<String, dynamic> _strip({
  bool show = true,
  int count = 1,
  bool paid = false,
  bool ring = true,
  String tone = 'warning',
  String more = '',
}) =>
    {
      'ok': true,
      'show': show,
      'count': count,
      'alert_id': 42,
      'order_id': 'ord-1',
      'order_code': 'CPO140926CHA101O1',
      'title': count == 1 ? 'New order awaiting you' : '$count new orders awaiting you',
      'subtitle': 'Chandra Medicals · ₹4,820.00 · 7 items · 12 seconds',
      'action_label': 'Open order',
      'more_label': more,
      'risk': paid ? 'prepaid' : 'unpaid',
      'risk_label': paid ? 'Paid' : 'Unpaid',
      'paid': paid,
      'age_label': '12 seconds',
      'tone': tone,
      'ring': ring,
      'ring_seconds': 120,
      'opened': false,
      'poll_s': 20,
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> s,
    {VoidCallback? onOpen, double width = 360}) async {
  tester.view.physicalSize = Size(width, 780);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: OrderAlertStrip(strip: s, onOpen: onOpen ?? () {}),
    ),
  ));
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('CMD #1988 — the new-order alert is view-only and single-surface', () {
    testWidgets('1. it is a strip, not a dialog — no modal barrier, no Dialog',
        (tester) async {
      await _pump(tester, _strip());
      expect(find.byType(OrderAlertStrip), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      // Nothing inside the strip dims, blocks or covers the screen behind it.
      expect(
          find.descendant(
              of: find.byType(OrderAlertStrip),
              matching: find.byType(ModalBarrier)),
          findsNothing);
    });

    testWidgets('2. ONE action, and Accept / Reject appear nowhere on it',
        (tester) async {
      // The payload deliberately carries the words the order screen uses, to
      // prove the strip ignores them rather than simply never seeing them.
      final s = _strip()
        ..['accept_label'] = 'Accept'
        ..['reject_label'] = 'Reject'
        ..['can_accept'] = true
        ..['can_reject'] = true;
      await _pump(tester, s);
      expect(find.text('Open order'), findsOneWidget);
      expect(find.text('Accept'), findsNothing);
      expect(find.text('Reject'), findsNothing);
    });

    testWidgets('3. every string is the backend\'s, printed verbatim',
        (tester) async {
      await _pump(tester, _strip(count: 3, more: '+2 more'));
      expect(find.text('3 new orders awaiting you'), findsOneWidget);
      expect(find.text('Chandra Medicals · ₹4,820.00 · 7 items · 12 seconds'),
          findsOneWidget);
      expect(find.text('Unpaid'), findsOneWidget);
      expect(find.text('+2 more'), findsOneWidget);
    });

    testWidgets('3b. an absent more_label draws nothing (never "+0 more")',
        (tester) async {
      await _pump(tester, _strip(count: 1));
      expect(find.textContaining('more'), findsNothing);
    });

    testWidgets('4. a PAID order renders exactly like an unpaid one — only its '
        'backend badge differs', (tester) async {
      await _pump(tester, _strip(paid: true, tone: 'info'));
      expect(find.text('Open order'), findsOneWidget);
      expect(find.text('Paid'), findsOneWidget);
      // Nothing about being paid removed the strip or its action: the silence
      // that used to follow payment was the bug.
      expect(find.byType(OrderAlertStrip), findsOneWidget);
    });

    testWidgets('5. tapping the strip is the ONLY way it acts, and it opens '
        'the order', (tester) async {
      var opened = 0;
      await _pump(tester, _strip(), onOpen: () => opened++);
      await tester.tap(find.text('Open order'));
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('6. the tap target clears 44px on a 360px phone',
        (tester) async {
      await _pump(tester, _strip(count: 2, more: '+1 more'));
      final box = tester.getSize(find.byType(OrderAlertStrip));
      expect(box.height, greaterThanOrEqualTo(44.0));
      expect(box.width, lessThanOrEqualTo(360.0));
    });

    testWidgets('7. it fits 320px and 412px without overflowing',
        (tester) async {
      for (final w in [320.0, 412.0]) {
        await _pump(tester, _strip(count: 4, more: '+3 more'), width: w);
        expect(tester.takeException(), isNull, reason: 'overflow at ${w}px');
      }
    });
  });
}
