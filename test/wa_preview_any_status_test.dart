// Preview EVERY template from the list, whatever its status — and preview a
// PENDING template from the dashboard notifications box too.
//
// A PENDING template cannot be edited (Meta is reviewing it) but it can always
// be LOOKED at. This holds down:
//
//   1. Every row — DRAFT, PENDING, REJECTED, APPROVED — carries a Preview action
//      that is never hidden and never disabled, captioned from preview_label.
//   2. Tapping it calls wa_template_preview with that row's id and shows the
//      delivered-message bubble.
//   3. A PENDING row shows edit_blocked_reason (the backend's own sentence) and
//      offers no Edit button.
//   4. The dashboard notifications preview sheet renders a bubble for a PENDING
//      template exactly as for any other — status decides the label, never
//      whether the bubble paints.
//   5. body_segments with a bold run paints FontWeight.bold and no literal
//      asterisk ever reaches the screen.
//
// Every RPC is mocked inline. No network, no Supabase, no home_shell.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/features/whatsapp/data/wa_template_api.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_templates_screen.dart';
import 'package:pharma_b2b/widgets/notifications_card.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── shared preview payload: a bold run, and a body_rendered that DELIBERATELY
// still carries asterisks. Because body_segments is present the bubble paints
// the segments and never the markers, so the asterisks below must never show. ──
const _previewPayload = <String, dynamic>{
  'header': null,
  'body_segments': [
    {'text': 'Hi ', 'bold': false},
    {'text': 'Nitesh', 'bold': true},
    {'text': ', your order is ready', 'bold': false},
  ],
  'body_plain': 'Hi Nitesh, your order is ready',
  'body_rendered': 'Hi *Nitesh*, your order is ready',
  'footer': '',
  'footer_segments': <dynamic>[],
  'buttons': <dynamic>[],
  'char_count': '0',
  'rendered_note': '',
};

// ── templates-list fixtures ─────────────────────────────────────────────────

Map<String, dynamic> _tpl({
  required String name,
  required String status,
  required String statusLabel,
  required String statusTone,
  bool canEdit = true,
  String editBlockedReason = '',
}) =>
    {
      'id': 'id_$name',
      'name': name,
      'language': 'en',
      'category_label': 'Utility',
      'status': status,
      'status_label': statusLabel,
      'status_tone': statusTone,
      'components': const [
        {'type': 'BODY', 'text': 'Hi {{1}}, your order {{2}} is ready.'}
      ],
      'body_preview': 'Hi {{1}}, your order {{2}} is ready.',
      'rejection_help': null,
      'quality_score': null,
      'quality_tone': 'grey',
      'category_changed': false,
      'edits_label': '0 of 10 edits used this month',
      'versions': const [],
      'performance': const {'summary': '0 sent · 0 read'},
      'last_used_label': 'Never used',
      // The two fields this change turns on:
      'can_preview': true,
      'preview_label': 'Preview',
      'can_edit': canEdit,
      'edit_blocked_reason': editBlockedReason,
      'can_submit': false,
      'can_delete': true,
      'can_test_send': false,
      'can_clone': true,
      'last_error': null,
    };

Map<String, dynamic> _screen() => {
      'ok': true,
      'copy': const {
        'title': 'WhatsApp templates',
        'edit': 'Edit',
        'submit': 'Submit',
        'test_send': 'Test send',
        'clone': 'Clone',
        'delete': 'Delete',
        'versions': 'Versions',
        'sync_now': 'Sync now',
        'sync_note': 'Verdicts arrive automatically',
        'new_template': 'New template',
        'alerts_title': 'Needs attention',
        'fix_resubmit': 'Fix & resubmit',
        'quality_label': 'Quality',
        'load_error': 'Could not load templates',
      },
      'count_chips': const [],
      'alerts': const [],
      'templates': [
        _tpl(
          name: 'order_ready',
          status: 'APPROVED',
          statusLabel: 'Approved',
          statusTone: 'green',
        ),
        _tpl(
          name: 'payment_pending',
          status: 'PENDING',
          statusLabel: 'Pending review',
          statusTone: 'yellow',
          canEdit: false,
          editBlockedReason:
              'Meta is reviewing this template — you can edit it once a verdict arrives.',
        ),
        _tpl(
          name: 'back_in_stock',
          status: 'DRAFT',
          statusLabel: 'Draft',
          statusTone: 'grey',
        ),
      ],
      'empty': const {'title': 'No templates yet', 'note': 'Start below'},
    };

// ── RPC transport for WaTemplateApi (screen + preview through one seam) ───────

class _Txn {
  final List<MapEntry<String, Map<String, dynamic>>> calls = [];
  Future<dynamic> call(String fn, Map<String, dynamic> params) async {
    calls.add(MapEntry(fn, params));
    if (fn == 'wa_template_preview') return _previewPayload;
    return _screen(); // wa_templates_screen
  }

  Map<String, dynamic>? lastParams(String fn) {
    for (final c in calls.reversed) {
      if (c.key == fn) return c.value;
    }
    return null;
  }
}

// ── notifications fixtures/transport ─────────────────────────────────────────

Map<String, dynamic> _pendingMatrix() => {
      'audiences': const [
        {'value': 'customer', 'label': 'Customer', 'sort': 1},
      ],
      'rows': const [
        {
          'audience': 'customer',
          'audience_label': 'Customer',
          'audience_sort': 1,
          'action_key': 'payment_reminder',
          'label': 'Payment reminder',
          'enabled': true,
          'sort': 1,
          'template_id': 'tpl-pending',
          'template_name': 'payment_reminder',
          // The template is PENDING — the sheet must still paint the bubble.
          'template_status': 'PENDING',
          'template_label': 'Pending review — waiting on Meta',
          'template_tone': 'warn',
          'can_edit': false,
          'can_preview': true,
          'can_generate': false,
          'edit_label': 'Edit template',
          'has_pending_change': false,
          'auto_manage': false,
        },
      ],
      'note': 'These are the messages mediBO can send.',
    };

class _NotifRpc {
  Future<dynamic> call(String fn, Map<String, dynamic>? params) async {
    switch (fn) {
      case 'notification_matrix':
        return _pendingMatrix();
      case 'get_notification_allowlist':
        return <dynamic>[];
      case 'wa_template_preview_pair':
        return {
          'current': _previewPayload,
          'current_label': 'Pending review — waiting on Meta',
          'current_tone': 'warn',
          'has_previous': false,
          'previous_body': null,
        };
      default:
        return const <String, dynamic>{};
    }
  }
}

// ── helpers ──────────────────────────────────────────────────────────────────

Finder _card(String name) => find.ancestor(
      of: find.text(name),
      matching: find.byType(WaTemplateCard),
    );

Finder _inCard(String name, Finder matching) =>
    find.descendant(of: _card(name), matching: matching);

/// True when some RichText in the tree contains a run [text] painted bold.
bool _hasBoldRun(WidgetTester tester, String text) {
  for (final r in tester.widgetList<RichText>(find.byType(RichText))) {
    var found = false;
    r.text.visitChildren((span) {
      if (span is TextSpan &&
          span.text == text &&
          span.style?.fontWeight == FontWeight.bold) {
        found = true;
      }
      return true;
    });
    if (found) return true;
  }
  return false;
}

/// Everything the screen actually renders as text, so an assertion can prove a
/// marker like '*' is nowhere on it.
String _allRenderedText(WidgetTester tester) {
  final b = StringBuffer();
  for (final r in tester.widgetList<RichText>(find.byType(RichText))) {
    b.write(r.text.toPlainText());
  }
  return b.toString();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  // ── A. TEMPLATES LIST ──────────────────────────────────────────────────────

  group('templates list', () {
    late _Txn txn;

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      txn = _Txn();
      WaTemplateApi.rpcTransport = txn.call;
      addTearDown(() => WaTemplateApi.rpcTransport = null);
      await tester.pumpWidget(const MaterialApp(home: WaTemplatesScreen()));
      await tester.pumpAndSettle();
    }

    testWidgets('every row — DRAFT, PENDING, APPROVED — offers Preview',
        (tester) async {
      await pump(tester);
      expect(_inCard('order_ready', find.text('Preview')), findsOneWidget);
      expect(_inCard('payment_pending', find.text('Preview')), findsOneWidget);
      expect(_inCard('back_in_stock', find.text('Preview')), findsOneWidget);
    });

    testWidgets('a PENDING row shows the blocked reason and no Edit button',
        (tester) async {
      await pump(tester);
      // The reason is the backend's own sentence, printed verbatim on the row.
      expect(
        _inCard(
            'payment_pending',
            find.text(
                'Meta is reviewing this template — you can edit it once a verdict arrives.')),
        findsOneWidget,
      );
      // No Edit action on the pending row...
      expect(_inCard('payment_pending', find.text('Edit')), findsNothing);
      // ...but the APPROVED row still has Edit, and no blocked reason.
      expect(_inCard('order_ready', find.text('Edit')), findsOneWidget);
    });

    testWidgets(
        'tapping Preview on the PENDING row calls wa_template_preview with its '
        'id and shows the bubble (bold run, no asterisks)', (tester) async {
      await pump(tester);

      final previewBtn = _inCard('payment_pending', find.text('Preview'));
      await tester.ensureVisible(previewBtn);
      await tester.pumpAndSettle();
      await tester.tap(previewBtn);
      await tester.pumpAndSettle();

      // The RPC was called for THIS row.
      final p = txn.lastParams('wa_template_preview');
      expect(p, isNotNull);
      expect(p!['p_template_id'], 'id_payment_pending');

      // The delivered-message bubble is on screen (same widget as notifications).
      expect(find.byKey(const Key('notif_preview_bubble')), findsOneWidget);

      // body_segments won: the bold run paints bold, and the asterisks that
      // body_rendered still carries never reach the screen.
      expect(_hasBoldRun(tester, 'Nitesh'), isTrue);
      expect(_allRenderedText(tester).contains('*'), isFalse);
      expect(find.textContaining('Nitesh'), findsWidgets);
    });
  });

  // ── B. NOTIFICATIONS SHEET ─────────────────────────────────────────────────

  group('notifications sheet', () {
    setUp(NotificationsCard.debugResetCache);
    tearDown(() {
      NotificationsCard.rpcOverride = null;
      NotificationsCard.debugResetCache();
    });

    testWidgets('renders a bubble for a PENDING template', (tester) async {
      tester.view.physicalSize = const Size(500, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      NotificationsCard.rpcOverride = _NotifRpc().call;

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: NotificationsCard())),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('NOTIFICATIONS'));
      await tester.pumpAndSettle();

      // The eye is offered (can_preview is true even though the template is
      // PENDING), and it is the only gate — not status.
      final eye = find.byIcon(Icons.visibility_outlined);
      await tester.ensureVisible(eye);
      await tester.pumpAndSettle();
      await tester.tap(eye);
      await tester.pumpAndSettle();

      // The bubble paints for a PENDING template just like any other.
      expect(find.byKey(const Key('notif_preview_bubble')), findsOneWidget);
      expect(_hasBoldRun(tester, 'Nitesh'), isTrue);
      expect(_allRenderedText(tester).contains('*'), isFalse);
    });
  });
}
