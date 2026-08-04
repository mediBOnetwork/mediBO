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
//   4. Inserting a token appends the NEXT {{n}} and records the binding. The
//      index comes from how many bindings exist, so it never depends on parsing
//      the body text.
//
// Fixture mirrors the real wa_templates_screen() sub-payloads (starters,
// tokens, categories, languages, button_spec) taken off the live database on
// 2026-08-04. No network, no Supabase, no goldens.

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

const _tokens = [
  {'key': 'customer_name', 'label': 'Customer name', 'example': 'Chandra Medicom'},
  {'key': 'order_code', 'label': 'Order code', 'example': 'CPO020826CHAO1'},
  {'key': 'amount', 'label': 'Amount', 'example': '₹12,447.71'},
];

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
    // components — the starter's body, verbatim.
    expect(find.text(_paymentPendingBody), findsOneWidget);
    // category — the starter said MARKETING, so the dropdown moved off UTILITY
    // and the MARKETING cost note is now on screen.
    expect(find.text('Marketing'), findsWidgets);
    expect(find.text('Offers — needs opt-in, ~7x the cost, can be paused'),
        findsOneWidget);
    // example values came across with it, one per placeholder.
    expect(find.text('Chandra Medicom'), findsWidgets);
    expect(find.text('₹4,500.00'), findsWidgets);
  });

  testWidgets('inserting a token appends the next {{n}}', (tester) async {
    _stub();
    await _pump(tester);

    // Each token chip shows its own example beside the label.
    expect(find.text('Customer name'), findsOneWidget);
    expect(find.text('CPO020826CHAO1'), findsWidgets);

    await tester.tap(find.text('Customer name'));
    await tester.pumpAndSettle();
    expect(find.text('{{1}}'), findsWidgets);

    await tester.tap(find.text('Order code'));
    await tester.pumpAndSettle();
    // The second insert becomes {{2}} — the body now holds both, in order.
    expect(find.text('{{1}}{{2}}'), findsOneWidget);

    await tester.tap(find.text('Amount'));
    await tester.pumpAndSettle();
    expect(find.text('{{1}}{{2}}{{3}}'), findsOneWidget);
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
