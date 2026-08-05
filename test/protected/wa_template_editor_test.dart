// PROTECTED — WhatsApp template manager, editor.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes template-editor behaviour.
//
// What this holds down:
//
//   1. The LINT is the backend's. errors[] and warnings[] are printed verbatim,
//      one line per message, and Save/Submit are disabled precisely while
//      errors[] is non-empty. Warnings never block — Meta approves those.
//      No regex, no length rule and no category rule lives in Dart.
//
//   2. The PREVIEW is the backend's. The bubble prints wa_template_preview()'s
//      `body`, not a locally-substituted copy of the body text. The fixture
//      returns a preview that could NOT have been produced by string-replacing
//      the components in Dart, so a local implementation fails this test.
//
//   3. Choosing a starter fills name, category and components together. Half a
//      starter is worse than none: the name would no longer describe the body.
//
//   4. Inserting a value asks wa_body_insert_token to drop a NUMBERED variable
//      ({{1}}) at the cursor — never a named one, never appended to the end.
//      The editor picks no number and builds no placeholder; it writes back the
//      body, caret and token_map the RPC returns, together.
//
//      CHANGED by the numbered-variable CHANGE, deliberately. This test twice
//      before asserted the wrong thing: first that the editor appended the next
//      {{n}} from a fixed nine-value list, then that it dropped the value's
//      NAMED `insert_as` ({{customer_name}}) at the cursor. Both were bugs —
//      Meta accepts numbered variables only, so a named one reached the
//      pharmacy as the literal characters "{{customer_name}}". Numbering is now
//      wa_body_insert_token's job, at insert time.
//
//   5. A body is ALWAYS numbered — that is the only form Meta accepts, and the
//      form the backend stores. Loading a starter or a saved template keeps its
//      {{1}} verbatim and adopts its token_map as-is: nothing is converted to
//      named placeholders, nothing is re-derived from the text.
//
// Fixture mirrors the real wa_templates_screen() sub-payloads (starters,
// categories, languages, button_spec) and wa_tokens_screen(), taken off the
// live database on 2026-08-04. No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/features/whatsapp/data/wa_template_api.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_template_editor_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ────────────────────────────────────────────────────────────────

/// The real "Payment pending" starter, verbatim from wa_template_starters().
const _paymentPendingBody =
    'Hi {{1}}, payment for order {{2}} is still pending. Amount due {{3}}. Please complete it to avoid a delay in dispatch.';

const _starters = [
  {
    'key': 'payment_pending',
    'name': 'payment_pending',
    'label': 'Payment pending',
    'note': 'Reminder for an unpaid accepted order',
    'category': 'MARKETING',
    'token_map': ['customer_name', 'order_code', 'amount'],
    'components': [
      {
        'type': 'BODY',
        'text': _paymentPendingBody,
        'example': {
          'body_text': [
            ['Chandra Medicom', 'CPO020826CHAO1', '₹4,500.00']
          ]
        }
      }
    ],
  },
];

/// wa_templates_screen() still carries a `tokens` list, and the editor still
/// deliberately ignores it — the picker is the only source of values now. Kept
/// in the fixture so that stays true: nothing below is asserted to be on screen.
const _tokens = [
  {'key': 'customer_name', 'label': 'Customer name', 'example': 'Chandra Medicom'},
  {'key': 'order_code', 'label': 'Order code', 'example': 'CPO020826CHAO1'},
  {'key': 'amount', 'label': 'Amount', 'example': '₹12,447.71'},
];

/// One row of wa_tokens_screen(), verbatim in shape: the label, the example,
/// the grouping and the insert text are all the backend's. `insert_as` is a
/// NAMED placeholder — the editor never builds "{{" + key + "}}" itself.
Map<String, dynamic> _tokenRow(
  String key,
  String label,
  String group,
  int sort,
  String example, {
  String? coverageLabel,
  String coverageTone = 'good',
  int usedIn = 0,
  bool canDelete = false,
}) =>
    {
      'key': key,
      'label': label,
      'group_label': group,
      'sort_order': sort,
      'source_kind': 'customer',
      'source_ref': key,
      'format': 'plain',
      'fallback': '',
      'enabled': true,
      'is_system': !canDelete,
      'insert_as': '{{$key}}',
      'example': example,
      'live': true,
      'source_label': 'From the customer record',
      'coverage_pct': 100,
      'coverage_label': coverageLabel,
      'coverage_tone': coverageTone,
      'used_in': usedIn,
      'can_delete': canDelete,
    };

/// The live value set. "Delivery person" is the one that matters: it was NOT on
/// the fixed nine-value list, which is the whole reason the picker exists.
Map<String, dynamic> _tokensScreen() => {
      'rows': [
        _tokenRow('customer_name', 'Customer name', 'Customer', 1,
            'Chandra Medicom'),
        _tokenRow('order_code', 'Order code', 'Order', 1, 'CPO020826CHAO1'),
        _tokenRow('amount', 'Amount', 'Order', 2, '₹4,500.00'),
        _tokenRow('rider_name', 'Delivery person', 'Delivery', 1, 'Suresh K.',
            coverageLabel: '82% of customers have this — the rest send blank',
            coverageTone: 'warn',
            canDelete: true),
      ],
      'search': null,
      'sample_from': 'Examples are from your latest real order',
      'empty_copy': 'No values yet',
      'source_kinds': const [
        {'value': 'customer', 'label': 'Customer record', 'table': 'pharmacy_profiles'},
        {'value': 'delivery', 'label': 'Delivery', 'options': ['rider_name']},
      ],
      'formats': const ['plain', 'money', 'date'],
    };

Map<String, dynamic> _screen() => {
      'copy': const {
        'save': 'Save',
        'submit': 'Submit',
        'editor_new_title': 'New template',
        'editor_edit_title': 'Edit template',
        'starters_title': 'Start from a ready template',
        'tokens_title': 'Insert a value',
        'examples_title': 'Example values',
        'preview_title': 'Preview',
        'errors_title': 'Fix before saving',
        'warnings_title': 'Suggestions',
        'name_label': 'Template name',
        'name_hint': 'Lowercase letters, numbers and underscores only',
        'language_label': 'Language',
        'category_label': 'Category',
        'body_label': 'Message body',
        'header_label': 'Header (optional)',
        'footer_label': 'Footer (optional)',
        'buttons_title': 'Buttons',
      },
      'starters': _starters,
      'tokens': _tokens,
      'categories': const [
        {
          'key': 'UTILITY',
          'label': 'Utility',
          'note': 'Order updates, alerts — cheapest, not throttled'
        },
        {
          'key': 'MARKETING',
          'label': 'Marketing',
          'note': 'Offers — needs opt-in, ~7x the cost, can be paused'
        },
      ],
      'languages': const [
        {'key': 'en', 'label': 'English'},
        {'key': 'hi', 'label': 'Hindi'},
      ],
      'button_spec': const {
        'types': [
          {
            'key': 'URL',
            'label': 'Open link',
            'max': 2,
            'note':
                'For campaign tracking the URL must end with {{1}} — mediBO appends the short code',
            'attribution_url': 'https://medibo.in/r/{{1}}',
            'attribution_example': ['https://medibo.in/r/ab3k9zq'],
          },
          {
            'key': 'QUICK_REPLY',
            'label': 'Quick reply',
            'max': 3,
            'note': 'Use "Stop promotions" on marketing templates',
            'attribution_url': '',
            'attribution_example': [],
          },
        ],
        'total_max': 10,
        'text_max': 25,
      },
    };

// ── harness ─────────────────────────────────────────────────────────────────

/// Installs a transport that answers validate and preview independently, so a
/// test can hold errors and preview text apart.
void _stub({
  List<String> errors = const [],
  List<String> warnings = const [],
  String previewBody = 'PREVIEW-FROM-BACKEND',
}) {
  WaTemplateApi.rpcTransport = (fn, params) async {
    switch (fn) {
      case 'wa_template_validate':
        return {
          'ok': errors.isEmpty,
          'errors': errors,
          'warnings': warnings,
        };
      case 'wa_template_preview':
        return {
          'header': null,
          'body': previewBody,
          'body_raw': 'ignored',
          'footer': null,
          'buttons': const [],
          'used_values': const [],
        };
      // The picker's own payload. wa_template_tokens() is NOT stubbed here —
      // the editor must not call it any more.
      case 'wa_tokens_screen':
        return _tokensScreen();
      // Numbering lives entirely in these two. The editor sends the body, the
      // caret and the map; it never picks a number itself. This stub mirrors
      // wa_body_insert_token: it drops {{n}} at the caret, reusing the number a
      // value already has and appending a fresh one otherwise.
      case 'wa_body_insert_token':
        {
          final body = (params['p_body'] ?? '').toString();
          final cursor = (params['p_cursor'] as num?)?.toInt() ?? body.length;
          final map = [
            for (final k in (params['p_token_map'] as List?) ?? const [])
              k.toString()
          ];
          final key = (params['p_key'] ?? '').toString();
          final existing = map.indexOf(key);
          final n = existing >= 0 ? existing + 1 : (map..add(key)).length;
          final ins = '{{$n}}';
          final at = cursor.clamp(0, body.length);
          return {
            'body': body.substring(0, at) + ins + body.substring(at),
            'cursor': at + ins.length,
            'inserted': ins,
            'token_map': map,
            'label': key,
            'preview_value': '',
          };
        }
      // A body the editor already holds is numbered and gap-free, so renumber
      // reports nothing to change.
      case 'wa_body_renumber':
        return {
          'body': params['p_body'],
          'token_map': params['p_token_map'],
          'changed': false,
        };
      default:
        return const <String, dynamic>{};
    }
  };
}

Future<void> _pump(
  WidgetTester tester, {
  Map<String, dynamic>? template,
  List<dynamic>? initialComponents,
}) async {
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    home: WaTemplateEditorScreen(
      screen: _screen(),
      template: template,
      initialComponents: initialComponents,
    ),
  ));
  await tester.pumpAndSettle();
}

/// Waits out the editor's debounce and the round-trip it schedules.
Future<void> _settleDebounce(WidgetTester tester) async {
  await tester.pump(WaTemplateEditorScreen.debounce + const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

T _button<T extends Widget>(WidgetTester tester, String label) =>
    tester.widget<T>(find.widgetWithText(T, label));

/// The message body — the editor's only six-line field. Reached through its
/// controller so a test can place the caret, which is the whole point of the
/// insert-at-cursor contract.
TextEditingController _bodyController(WidgetTester tester) => tester
    .widget<TextField>(
        find.byWidgetPredicate((w) => w is TextField && w.maxLines == 6))
    .controller!;

void main() {
  setUpAll(() {
    // RenderLog's 800 ms debounce is a real Timer that would outlive the test.
    RenderLog.flushEnabled = false;
  });

  tearDown(() => WaTemplateApi.rpcTransport = null);

  testWidgets('errors render verbatim and block Save and Submit',
      (tester) async {
    const err1 = 'Body cannot end with a variable — add a closing sentence';
    const err2 = 'Add 3 example value(s) — Meta rejects templates without them';
    _stub(errors: const [err1, err2]);

    await _pump(tester, initialComponents: const [
      {'type': 'BODY', 'text': 'Hi {{1}}'}
    ]);
    await _settleDebounce(tester);

    // Meta's reasons, word for word, one line each.
    expect(find.text('Fix before saving'), findsOneWidget);
    expect(find.text(err1), findsOneWidget);
    expect(find.text(err2), findsOneWidget);

    // Both write paths are shut while errors stand.
    expect(_button<OutlinedButton>(tester, 'Save').onPressed, isNull);
    expect(_button<ElevatedButton>(tester, 'Submit').onPressed, isNull);
  });

  testWidgets('warnings render verbatim and do NOT block', (tester) async {
    const warn =
        'Add a "Stop promotions" quick reply — it protects your quality rating';
    _stub(warnings: const [warn]);

    await _pump(tester, initialComponents: const [
      {'type': 'BODY', 'text': 'Hi there, your order is on its way.'}
    ]);
    await _settleDebounce(tester);

    expect(find.text('Suggestions'), findsOneWidget);
    expect(find.text(warn), findsOneWidget);

    // A warning is advice, not a gate.
    expect(_button<OutlinedButton>(tester, 'Save').onPressed, isNotNull);
    expect(_button<ElevatedButton>(tester, 'Submit').onPressed, isNotNull);
  });

  testWidgets('preview text comes from the RPC, not from local string building',
      (tester) async {
    // This string is not derivable from the components below by any local
    // substitution — it can only have come from the preview RPC.
    _stub(previewBody: 'Hi Chandra Medicom, payment for order CPO020826CHAO1 '
        'is still pending. Amount due ₹4,500.00.');

    await _pump(tester, initialComponents: const [
      {'type': 'BODY', 'text': _paymentPendingBody}
    ]);
    await _settleDebounce(tester);

    expect(
      find.text('Hi Chandra Medicom, payment for order CPO020826CHAO1 '
          'is still pending. Amount due ₹4,500.00.'),
      findsOneWidget,
    );
  });

  testWidgets('choosing a starter fills name, category and components',
      (tester) async {
    _stub();
    await _pump(tester);

    // A new template offers the ready drafts.
    expect(find.text('Start from a ready template'), findsOneWidget);
    expect(find.text('Reminder for an unpaid accepted order'), findsOneWidget);

    await tester.tap(find.text('Payment pending'));
    await tester.pumpAndSettle();

    // name — from the starter, not typed.
    expect(find.text('payment_pending'), findsWidgets);
    // components — the starter's body, kept NUMBERED exactly as stored. Meta
    // accepts only numbered variables, so there is nothing to convert; a named
    // placeholder on screen would be the bug.
    expect(find.text(_paymentPendingBody), findsOneWidget);
    expect(find.textContaining('{{customer_name}}'), findsNothing);
    // category — the starter said MARKETING, so the dropdown moved off UTILITY
    // and the MARKETING cost note is now on screen.
    expect(find.text('Marketing'), findsWidgets);
    expect(find.text('Offers — needs opt-in, ~7x the cost, can be paused'),
        findsOneWidget);
    // example values came across with it, one per placeholder.
    expect(find.text('Chandra Medicom'), findsWidgets);
    expect(find.text('₹4,500.00'), findsWidgets);
  });

  testWidgets('inserting a value drops a NUMBERED variable at the cursor',
      (tester) async {
    _stub();
    await _pump(tester);

    // The chips come from wa_tokens_screen(). "Delivery person" exists only in
    // that payload — it was never on the fixed nine-value list, and being
    // unable to insert it is the bug that created the picker.
    expect(find.text('Customer name'), findsOneWidget);
    expect(find.text('Delivery person'), findsOneWidget);
    expect(find.text('Suresh K.'), findsWidgets);

    // The coverage warning is on screen BEFORE anything is inserted. Learning
    // afterwards that a value is blank for some customers is too late.
    expect(find.text('82% of customers have this — the rest send blank'),
        findsOneWidget);

    final body = _bodyController(tester);
    body.text = 'Hi , your order is on its way.';
    body.selection = const TextSelection.collapsed(offset: 3); // after "Hi "
    await tester.pumpAndSettle();

    await tester.tap(find.text('Customer name'));
    await tester.pumpAndSettle();

    // wa_body_insert_token dropped {{1}} where the caret was — not appended to
    // the end, and NOT the named {{customer_name}} Meta would send literally.
    expect(body.text, 'Hi {{1}}, your order is on its way.');
    expect(body.selection.baseOffset, 3 + '{{1}}'.length);
    expect(find.textContaining('{{customer_name}}'), findsNothing);

    // A second value goes in at the new caret, gets the next number, still not
    // at the end.
    await tester.tap(find.text('Delivery person'));
    await tester.pumpAndSettle();
    expect(body.text, 'Hi {{1}}{{2}}, your order is on its way.');
    expect(body.text.endsWith('{{2}}'), isFalse);

    // The numbers came from the backend, never assembled here.
    expect(find.textContaining('{{rider_name}}'), findsNothing);
  });

  testWidgets('the name field locks once Meta has the template',
      (tester) async {
    _stub();
    await _pump(tester, template: const {
      'id': 'abc',
      'meta_id': '2536483966790559',
      'name': 'hello_world',
      'language': 'en',
      'category': 'UTILITY',
      'components': [
        {'type': 'BODY', 'text': 'Hello World'}
      ],
      'token_map': [],
    });
    await _settleDebounce(tester);

    final field = tester.widget<TextField>(
      find.ancestor(
        of: find.text('hello_world'),
        matching: find.byType(TextField),
      ),
    );
    // Meta will not rename an existing template, so neither will we.
    expect(field.enabled, isFalse);
    // Editing an existing template offers no starters — they would overwrite it.
    expect(find.text('Start from a ready template'), findsNothing);
  });
}
