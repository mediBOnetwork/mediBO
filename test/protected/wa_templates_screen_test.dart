// PROTECTED — WhatsApp template manager, list screen.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes template-manager behaviour.
//
// What this holds down:
//
//   1. The count chips print the backend's label AND its value. Neither is
//      recomputed from templates.length — counts come from the payload, which
//      counts rows this screen may not even be showing.
//
//   2. status_label and status_tone are rendered verbatim. There is no
//      status -> label map and no status -> colour map in Dart, so a status
//      Meta invents tomorrow still paints.
//
//   3. An UNKNOWN status/tone falls back to a grey chip carrying the backend's
//      raw label, and does not throw. This is the whole reason tone is a string
//      from the server rather than an enum here.
//
//   4. A REJECTED row shows rejection_help.title and .fix, and offers
//      "Fix & resubmit" — the one route back into the editor that carries the
//      rejected components.
//
//   5. category_changed shows category_change_note. Meta silently re-classifies
//      templates and the cost per message changes with it; that note is the
//      only warning the admin gets.
//
//   6. Every action button appears ONLY when its own can_* flag is true. A
//      PENDING row must not offer Edit (Meta rejects edits under review) and a
//      DRAFT row must not offer Test send (there is nothing at Meta to send).
//      These are backend booleans, never inferred from status here.
//
// Fixture mirrors the real wa_templates_screen() payload shape taken off the
// live database on 2026-08-04. No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/features/whatsapp/data/wa_template_api.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_template_bits.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_templates_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── design-system tones, as the widgets resolve them ────────────────────────
const _green = Color(0xFFD1FAE5);
const _yellow = Color(0xFFFEF3C7);
const _red = Color(0xFFFEE2E2);
const _grey = Color(0xFFF3F4F6);

// ── fixtures ────────────────────────────────────────────────────────────────

Map<String, dynamic> _tpl({
  required String name,
  required String status,
  required String statusLabel,
  required String statusTone,
  String bodyPreview = 'Hi {{1}}, your order {{2}} is accepted.',
  bool canEdit = true,
  bool canSubmit = false,
  bool canTestSend = false,
  bool canClone = true,
  bool canDelete = true,
  List<dynamic> versions = const [],
  Map<String, dynamic>? rejectionHelp,
  bool categoryChanged = false,
  String? categoryChangeNote,
}) =>
    {
      'id': 'id_$name',
      'meta_id': '',
      'name': name,
      'language': 'en',
      'category': 'UTILITY',
      'category_label': 'Utility',
      'status': status,
      'status_label': statusLabel,
      'status_tone': statusTone,
      'components': [
        {'type': 'BODY', 'text': bodyPreview}
      ],
      'token_map': const [],
      'preview': {'body': bodyPreview, 'buttons': const [], 'used_values': const []},
      'body_preview': bodyPreview,
      'rejected_reason': null,
      'rejection_help': rejectionHelp,
      'quality_score': null,
      'quality_tone': 'grey',
      'category_changed': categoryChanged,
      'category_change_note': categoryChangeNote,
      'edits_used': 0,
      'edits_limit': 10,
      'edits_label': '0 of 10 edits used this month',
      'versions': versions,
      'performance': {'summary': '0 sent · 0 read · 0 clicks · 0 orders'},
      'last_used_label': 'Never used',
      'can_edit': canEdit,
      'can_submit': canSubmit,
      'can_delete': canDelete,
      'can_test_send': canTestSend,
      'can_clone': canClone,
      'can_use_in_campaign': false,
      'submitted_label': null,
      'synced_label': null,
      'last_error': null,
    };

/// The five rows below deliberately cover: approved, pending, rejected, draft
/// and a status this app has never heard of.
Map<String, dynamic> _screen({List<dynamic>? templates, List<dynamic>? alerts}) =>
    {
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
        'sync_note': 'Meta verdicts also arrive automatically every 5 minutes',
        'new_template': 'New template',
        'alerts_title': 'Needs attention',
        'fix_resubmit': 'Fix & resubmit',
        'quality_label': 'Quality',
        'load_error': 'Could not load templates',
      },
      'counts': const {
        'total': 5,
        'approved': 1,
        'pending': 1,
        'rejected': 1,
        'paused': 0
      },
      'count_chips': const [
        {'key': 'total', 'label': 'Total', 'value': 5, 'tone': 'grey'},
        {'key': 'approved', 'label': 'Approved', 'value': 1, 'tone': 'green'},
        {'key': 'pending', 'label': 'Pending', 'value': 1, 'tone': 'yellow'},
        {'key': 'rejected', 'label': 'Rejected', 'value': 1, 'tone': 'red'},
        {'key': 'paused', 'label': 'Paused', 'value': 0, 'tone': 'yellow'},
      ],
      'alerts': alerts ?? const [],
      'templates': templates ??
          [
            _tpl(
              name: 'order_accepted',
              status: 'APPROVED',
              statusLabel: 'Approved',
              statusTone: 'green',
              canEdit: true,
              canTestSend: true,
              versions: const [
                {'version': 1, 'action': 'create', 'at': '02 Aug, 4:10 pm', 'components': []}
              ],
            ),
            _tpl(
              name: 'payment_pending',
              status: 'PENDING',
              statusLabel: 'Pending review',
              statusTone: 'yellow',
              // Meta refuses edits while a template is under review.
              canEdit: false,
              canTestSend: false,
            ),
            _tpl(
              name: 'monthly_offer',
              status: 'REJECTED',
              statusLabel: 'Rejected',
              statusTone: 'red',
              canSubmit: true,
              rejectionHelp: const {
                'title': 'Formatting problem',
                'fix':
                    'Usually the body starts or ends with a variable, two variables sit together, or example values are missing. Fix the highlighted issues and resubmit.',
              },
            ),
            _tpl(
              name: 'back_in_stock',
              status: 'DRAFT',
              statusLabel: 'Draft',
              statusTone: 'grey',
              canSubmit: true,
              // Nothing exists at Meta yet, so there is nothing to test-send.
              canTestSend: false,
              categoryChanged: true,
              categoryChangeNote:
                  'Meta moved this from Utility to Marketing — cost per message changes',
            ),
            // A status this build has never seen. Must still paint.
            _tpl(
              name: 'future_status',
              status: 'IN_APPEAL',
              statusLabel: 'In appeal',
              statusTone: 'chartreuse',
            ),
          ],
      'starters': const [],
      'tokens': const [],
      'button_spec': const {'types': [], 'total_max': 10, 'text_max': 25},
      'test_send': const {},
      'categories': const [
        {'key': 'UTILITY', 'label': 'Utility', 'note': 'Order updates'}
      ],
      'languages': const [
        {'key': 'en', 'label': 'English'}
      ],
      'empty': const {'title': 'No templates yet', 'note': 'Start from a ready template below'},
    };

// ── harness ─────────────────────────────────────────────────────────────────

Future<void> _pump(WidgetTester tester, Map<String, dynamic> payload) async {
  WaTemplateApi.rpcTransport = (fn, params) async => payload;
  await tester.pumpWidget(
    const MaterialApp(home: WaTemplatesScreen()),
  );
  await tester.pumpAndSettle();
}

/// Scopes a finder to one template's card, so "no Edit button" means "not on
/// THIS row" rather than "nowhere on the screen".
Finder _card(String name) => find.ancestor(
      of: find.text(name),
      matching: find.byType(WaTemplateCard),
    );

Finder _inCard(String name, Finder matching) =>
    find.descendant(of: _card(name), matching: matching);

void main() {
  setUpAll(() {
    // RenderLog's 800 ms debounce is a real Timer that would outlive the test
    // and try to reach Supabase.
    RenderLog.flushEnabled = false;
  });

  // Note: each test that inspects more than the first card widens the viewport
  // past the default 800 px. A lazily-built ListView otherwise never constructs
  // the later cards, and the can_* assertions below would pass vacuously.

  tearDown(() => WaTemplateApi.rpcTransport = null);

  testWidgets('count chips render the backend label and value', (tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pump(tester, _screen());

    final total = tester.widget<WaChip>(find.widgetWithText(WaChip, 'Total'));
    expect(total.value, '5');
    expect(WaTone.of(total.tone).bg, _grey);

    final pending =
        tester.widget<WaChip>(find.widgetWithText(WaChip, 'Pending'));
    expect(pending.value, '1');
    expect(WaTone.of(pending.tone).bg, _yellow);

    // The sync note tells the admin verdicts also arrive on their own.
    expect(
        find.text('Meta verdicts also arrive automatically every 5 minutes'),
        findsOneWidget);
  });

  testWidgets('status chip prints label and tone verbatim', (tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pump(tester, _screen());

    final approved = tester.widget<WaChip>(
        _inCard('order_accepted', find.widgetWithText(WaChip, 'Approved')));
    expect(WaTone.of(approved.tone).bg, _green);

    final pending = tester.widget<WaChip>(
        _inCard('payment_pending', find.widgetWithText(WaChip, 'Pending review')));
    expect(WaTone.of(pending.tone).bg, _yellow);

    final rejected = tester.widget<WaChip>(
        _inCard('monthly_offer', find.widgetWithText(WaChip, 'Rejected')));
    expect(WaTone.of(rejected.tone).bg, _red);
  });

  testWidgets('body_preview renders verbatim', (tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pump(tester, _screen());

    // The raw {{1}} / {{2}} text is shown exactly as the backend sent it — the
    // list does not try to render placeholders.
    expect(
        _inCard('order_accepted',
            find.text('Hi {{1}}, your order {{2}} is accepted.')),
        findsOneWidget);
  });

  testWidgets('an unknown status falls back to a grey chip without throwing',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pump(tester, _screen());

    expect(tester.takeException(), isNull);

    // 'chartreuse' is not a tone this build knows. It must degrade to grey and
    // keep the backend's own label.
    final chip = tester.widget<WaChip>(
        _inCard('future_status', find.widgetWithText(WaChip, 'In appeal')));
    expect(WaTone.of(chip.tone).bg, _grey);
  });

  testWidgets('REJECTED row shows rejection help and Fix & resubmit',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pump(tester, _screen());

    expect(_inCard('monthly_offer', find.text('Formatting problem')),
        findsOneWidget);
    expect(
      _inCard(
          'monthly_offer',
          find.text(
              'Usually the body starts or ends with a variable, two variables sit together, or example values are missing. Fix the highlighted issues and resubmit.')),
      findsOneWidget,
    );
    expect(_inCard('monthly_offer', find.text('Fix & resubmit')), findsOneWidget);

    // Only the rejected row gets the help block.
    expect(_inCard('order_accepted', find.text('Fix & resubmit')), findsNothing);
  });

  testWidgets('category_changed row shows the backend note', (tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pump(tester, _screen());

    expect(
      _inCard(
          'back_in_stock',
          find.text(
              'Meta moved this from Utility to Marketing — cost per message changes')),
      findsOneWidget,
    );
    expect(
      _inCard('order_accepted',
          find.textContaining('cost per message changes')),
      findsNothing,
    );
  });

  testWidgets('actions appear only for their own true flags', (tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pump(tester, _screen());

    // APPROVED: can_edit + can_test_send true, can_submit false.
    expect(_inCard('order_accepted', find.text('Edit')), findsOneWidget);
    expect(_inCard('order_accepted', find.text('Test send')), findsOneWidget);
    expect(_inCard('order_accepted', find.text('Submit')), findsNothing);
    // versions[] is non-empty on this row only.
    expect(_inCard('order_accepted', find.text('Versions')), findsOneWidget);

    // PENDING: can_edit is false — no Edit, and no Versions (empty list).
    expect(_inCard('payment_pending', find.text('Edit')), findsNothing);
    expect(_inCard('payment_pending', find.text('Versions')), findsNothing);
    expect(_inCard('payment_pending', find.text('Test send')), findsNothing);

    // DRAFT: submit yes, test send no.
    expect(_inCard('back_in_stock', find.text('Submit')), findsOneWidget);
    expect(_inCard('back_in_stock', find.text('Test send')), findsNothing);

    // can_clone / can_delete are true everywhere in this fixture.
    expect(_inCard('payment_pending', find.text('Clone')), findsOneWidget);
    expect(_inCard('payment_pending', find.text('Delete')), findsOneWidget);
  });

  testWidgets('alerts strip renders template, label and tone from the payload',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pump(
      tester,
      _screen(alerts: const [
        {
          'template': 'monthly_offer',
          'kind': 'status_rejected',
          'detail': {},
          'at': '04 Aug, 9:12 am',
          'tone': 'red',
          'label': 'Rejected by Meta',
          'detail_label': 'Formatting problem',
        },
      ]),
    );

    expect(find.text('Needs attention'), findsOneWidget);
    // template + kind label on one line, exactly as the payload named them.
    expect(find.text('monthly_offer · Rejected by Meta'), findsOneWidget);
    expect(find.text('04 Aug, 9:12 am'), findsOneWidget);
  });

  testWidgets('empty payload renders the backend empty state', (tester) async {
    await _pump(tester, _screen(templates: const []));

    expect(find.text('No templates yet'), findsOneWidget);
    expect(find.text('Start from a ready template below'), findsOneWidget);
  });
}
