// Two things this holds down.
//
// A. WhatsApp Ops used to list all 25 automatic messages in one flat run, so Om
// could not tell customer messages from supplier ones. They are now grouped by
// `audience` (ordered by audience_sort, headed by audience_label), with a filter
// row so he can jump to one type. No user-type name is spelled out in Dart — the
// headers and chips are the backend's labels — and nothing is re-sorted here.
//
// B. The notification preview sheet printed raw asterisks. WhatsApp renders
// *bold* / _italic_ / ~strike~; the customer never sees a marker. Both bubbles
// now paint the backend's already-split segments (current.body_segments /
// footer_segments, previous_segments), falling back to body_plain / previous_plain.
//
// Every RPC is stubbed inline: no network, no Supabase, no home_shell import.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/wa_ops_screen.dart';
import 'package:pharma_b2b/widgets/notifications_card.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── Section A fixtures: WhatsApp Ops event routes ────────────────────────────

Map<String, dynamic> _route({
  required String eventKey,
  required String label,
  required String audience,
  required String audienceLabel,
  required int audienceSort,
}) =>
    {
      'event_key': eventKey,
      'label': label,
      'audience': audience,
      'audience_label': audienceLabel,
      'audience_sort': audienceSort,
      'description': 'Sent automatically.',
      'template_name': '${eventKey}_v1',
      'language': 'en',
      'enabled': true,
      'status_label': 'On',
      'status_tone': 'good',
      'window_label': 'Sends any time',
      'sent_30d': 10,
      'updated_label': '05 Aug, 11:20 AM',
      'auto_manage': false,
      'pipeline_note': 'Live and sending.',
      'stage_label': 'Live',
      'stage_tone': 'good',
      'bypass_send_window': false,
      'dedupe_minutes': 45,
    };

/// Rows arrive already ordered by audience_sort — customer, then supplier, then
/// a third type that is neither.
Map<String, dynamic> _routesPayload() => {
      'rows': [
        _route(
            eventKey: 'order_placed',
            label: 'Order placed',
            audience: 'customer',
            audienceLabel: 'Customers',
            audienceSort: 1),
        _route(
            eventKey: 'payout_sent',
            label: 'Payout sent',
            audience: 'supplier',
            audienceLabel: 'Suppliers',
            audienceSort: 2),
        _route(
            eventKey: 'pickup_ready',
            label: 'Pickup ready',
            audience: 'delivery_partner',
            audienceLabel: 'Delivery partners',
            audienceSort: 3),
      ],
      'approved_templates': const [],
      'note': 'Each event sends the approved template you pick here.',
    };

Map<String, dynamic> _wabaPayload() => {
      'waba_name': 'mediBO',
      'review_status': 'APPROVED',
      'templates_label': '105 of 250 templates used',
      'templates_pct': 42,
      'templates_tone': 'good',
      'tier_label': 'Messaging tier: TIER_10K',
      'quality_label': 'Number quality: GREEN',
      'quality_tone': 'good',
      'checked_label': 'Checked 05 Aug, 09:00 AM',
      'error': null,
      'note': 'Meta caps a WhatsApp Business Account at 250 templates.',
    };

Map<String, dynamic> _ledgerPayload() => {
      'contacts': 0,
      'summary': 'No contacts messaged in the last 30 days',
      'rows': const <Map<String, dynamic>>[],
    };

Future<void> _pumpOps(WidgetTester tester) async {
  // The screen is far taller than the default 800px viewport.
  tester.view.physicalSize = const Size(500, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    home: WaOpsScreen(
      routesRpc: () async => _routesPayload(),
      routeSaveRpc: (_) async => {'ok': true},
      wabaStatusRpc: () async => _wabaPayload(),
      wabaRefreshRpc: () async => {'ok': true},
      ledgerRpc: (_, _) async => _ledgerPayload(),
      refreshDelay: Duration.zero,
    ),
  ));
  await tester.pumpAndSettle();
}

// ── Section B fixtures: notification preview sheet ───────────────────────────

Map<String, dynamic> _notifRow() => {
      'audience': 'customer',
      'audience_label': 'Customer',
      'audience_sort': 1,
      'action_key': 'order_shipped',
      'label': 'Order shipped',
      'enabled': true,
      'sort': 1,
      'template_id': 'tpl-1',
      'template_name': 'order_shipped',
      'template_status': 'APPROVED',
      'template_label': 'Live — order_shipped',
      'template_tone': 'good',
      'can_edit': true,
      'can_preview': true,
      'can_generate': false,
      'edit_label': 'Edit template',
      'has_pending_change': false,
      'auto_manage': false,
    };

Map<String, dynamic> _matrix() => {
      'audiences': [
        {'value': 'customer', 'label': 'Customer', 'sort': 1},
      ],
      'rows': [_notifRow()],
      'note': 'These are the messages mediBO can send.',
    };

Future<void> _pumpNotif(WidgetTester tester, Map<String, dynamic> pair) async {
  tester.view.physicalSize = const Size(500, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  NotificationsCard.rpcOverride = (fn, params) async {
    switch (fn) {
      case 'notification_matrix':
        return _matrix();
      case 'get_notification_allowlist':
        return <dynamic>[];
      case 'wa_template_preview_pair':
        return pair;
      default:
        return const <String, dynamic>{};
    }
  };

  await tester.pumpWidget(const MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: NotificationsCard())),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('NOTIFICATIONS'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byIcon(Icons.visibility_outlined));
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.visibility_outlined));
  await tester.pumpAndSettle();
}

/// Flattened styled spans under [scope] (only Text.rich carries a textSpan).
List<TextSpan> _spansIn(WidgetTester tester, Finder scope) {
  final texts = tester
      .widgetList<Text>(find.descendant(of: scope, matching: find.byType(Text)))
      .where((t) => t.textSpan != null);
  final out = <TextSpan>[];
  void walk(InlineSpan? s) {
    if (s is TextSpan) {
      out.add(s);
      for (final c in s.children ?? const <InlineSpan>[]) {
        walk(c);
      }
    }
  }

  for (final t in texts) {
    walk(t.textSpan);
  }
  return out;
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  setUp(NotificationsCard.debugResetCache);
  tearDown(() {
    NotificationsCard.rpcOverride = null;
    NotificationsCard.debugResetCache();
  });

  // ── A: Ops grouped by user type ─────────────────────────────────────────────

  testWidgets('routes render under a header per audience_label, incl. a third type',
      (tester) async {
    await _pumpOps(tester);

    // A header per audience, captioned with the backend's audience_label — one
    // of which is neither customer nor supplier.
    expect(
        find.descendant(
            of: find.byKey(const Key('wa_ops_aud_header:customer')),
            matching: find.text('Customers')),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('wa_ops_aud_header:supplier')),
            matching: find.text('Suppliers')),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('wa_ops_aud_header:delivery_partner')),
            matching: find.text('Delivery partners')),
        findsOneWidget);

    // Each audience's own card is present.
    expect(find.text('Order placed'), findsOneWidget);
    expect(find.text('Payout sent'), findsOneWidget);
    expect(find.text('Pickup ready'), findsOneWidget);
  });

  testWidgets('sections follow audience_sort', (tester) async {
    await _pumpOps(tester);

    final yCustomer =
        tester.getTopLeft(find.byKey(const Key('wa_ops_aud_header:customer'))).dy;
    final ySupplier =
        tester.getTopLeft(find.byKey(const Key('wa_ops_aud_header:supplier'))).dy;
    final yDelivery = tester
        .getTopLeft(find.byKey(const Key('wa_ops_aud_header:delivery_partner')))
        .dy;

    expect(yCustomer < ySupplier, isTrue);
    expect(ySupplier < yDelivery, isTrue);
  });

  testWidgets('picking a filter shows only that audience', (tester) async {
    await _pumpOps(tester);

    await tester.ensureVisible(find.byKey(const Key('wa_ops_aud_chip:supplier')));
    await tester.tap(find.byKey(const Key('wa_ops_aud_chip:supplier')));
    await tester.pumpAndSettle();

    // Only the supplier section remains.
    expect(find.byKey(const Key('wa_ops_aud_header:supplier')), findsOneWidget);
    expect(find.byKey(const Key('wa_ops_aud_header:customer')), findsNothing);
    expect(
        find.byKey(const Key('wa_ops_aud_header:delivery_partner')), findsNothing);
    expect(find.text('Payout sent'), findsOneWidget);
    expect(find.text('Order placed'), findsNothing);
    expect(find.text('Pickup ready'), findsNothing);
  });

  // ── B: styling in the notification preview sheet ────────────────────────────

  testWidgets('a bold body_segment renders FontWeight.bold with no asterisks',
      (tester) async {
    await _pumpNotif(tester, {
      'current': {
        'header': null,
        'body_rendered': '*Payment received — mediBO* thanks',
        'body_plain': 'Payment received — mediBO thanks',
        'body_segments': [
          {'text': 'Payment received — mediBO', 'bold': true},
          {'text': ' thanks', 'bold': false},
        ],
        'footer_segments': [
          {'text': 'Reply STOP', 'italic': true},
        ],
        'footer': 'Reply STOP',
        'buttons': const [],
      },
      'current_label': 'Live now',
      'current_tone': 'good',
      'has_previous': false,
    });

    final firstBubble = find.byKey(const Key('notif_preview_bubble')).first;
    final spans = _spansIn(tester, firstBubble);
    final bold = spans.firstWhere(
      (s) => s.style?.fontWeight == FontWeight.bold,
      orElse: () => const TextSpan(),
    );
    expect(bold.text, 'Payment received — mediBO');

    // The customer never sees the raw markers.
    expect(spans.map((s) => s.text ?? '').join().contains('*'), isFalse);
    expect(find.textContaining('*'), findsNothing);
  });

  testWidgets('previous_segments renders styled in the second bubble',
      (tester) async {
    await _pumpNotif(tester, {
      'current': {
        'body_segments': [
          {'text': 'New wording', 'bold': false},
        ],
        'body_plain': 'New wording',
        'body_rendered': 'New wording',
        'buttons': const [],
      },
      'current_label': 'Live now',
      'current_tone': 'good',
      'has_previous': true,
      'previous_label': 'Still being sent until Meta approves',
      'previous_at': '04 Aug, 11:20 AM',
      'previous_body': '*Old bold wording*',
      'previous_plain': 'Old bold wording',
      'previous_segments': [
        {'text': 'Old bold wording', 'bold': true},
      ],
    });

    expect(find.byKey(const Key('notif_preview_bubble')), findsNWidgets(2));

    final secondBubble = find.byKey(const Key('notif_preview_bubble')).at(1);
    final spans = _spansIn(tester, secondBubble);
    final bold = spans.firstWhere(
      (s) => s.style?.fontWeight == FontWeight.bold,
      orElse: () => const TextSpan(),
    );
    expect(bold.text, 'Old bold wording');
    // No asterisks reached the rendered previous bubble either.
    expect(spans.map((s) => s.text ?? '').join().contains('*'), isFalse);
  });

  testWidgets('missing segments falls back to body_plain', (tester) async {
    await _pumpNotif(tester, {
      'current': {
        // No body_segments at all — plain must win over body_rendered.
        'body_rendered': 'RENDERED',
        'body_plain': 'Just plain text',
        'buttons': const [],
      },
      'current_label': 'Live now',
      'current_tone': 'good',
      'has_previous': false,
    });

    expect(find.text('Just plain text'), findsOneWidget);
    expect(find.text('RENDERED'), findsNothing);
  });
}
