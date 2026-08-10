// PROTECTED — WhatsApp campaign builder.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes campaign-builder behaviour.
//
// What this holds down:
//
//   1. PREFLIGHT IS THE ONLY JUDGE, AND IT IS QUOTED. wa_campaign_preflight()
//      returns errors[] and the builder prints them word for word. These are
//      not cosmetic warnings: a variable-count mismatch makes Meta reject EVERY
//      message in the campaign, not one. If Dart ever grew its own opinion of
//      "looks fine", the check the admin trusts and the check that is enforced
//      would be two different checks.
//
//   2. SCHEDULE IS DISABLED WHILE errors[] IS NON-EMPTY, and enabled when it
//      empties. This is the guard, so it is asserted on the button's onPressed
//      being null — not on a colour.
//
//   3. THE DRY-RUN SHEET PRINTS `preview` FROM THE RESPONSE. wa_render_preview()
//      substitutes variables server-side. A preview built in Dart would be a
//      SECOND renderer, and the message an admin approved would not be the one
//      Meta is handed.
//
//   4. SEGMENT AND TRIGGER ARE MUTUALLY EXCLUSIVE. wa_campaign_materialize()
//      ignores audience_kind entirely once trigger_kind is set, so a UI that
//      let both look selected would show an audience that is not the one that
//      sends.
//
//   5. A `needs` FIELD RENDERS EXACTLY ONE EXTRA INPUT, keyed by the backend's
//      own name ('zone_id' | 'days' | 'hours' | 'limit').
//
// Fixtures mirror the real wa_templates_screen(), wa_template_tokens() and
// wa_campaign_preflight() payloads, read off the live database on 2026-08-04.
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ui_copy_fixture.dart';

import 'package:pharma_b2b/screens/admin/wa_campaign_builder_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> _templatesPayload() => {
      'ok': true,
      'templates': [
        {
          'id': 't-approved',
          'name': 'refill_reminder',
          'language': 'en',
          'category': 'MARKETING',
          'category_label': 'Marketing',
          'status': 'APPROVED',
          'body_preview': 'Hi {{1}}, your {{2}} is due for a refill.',
          'can_use_in_campaign': true,
        },
        {
          'id': 't-pending',
          'name': 'not_yet_approved',
          'language': 'en',
          'category': 'MARKETING',
          'category_label': 'Marketing',
          'status': 'PENDING',
          'body_preview': 'Hello {{1}}',
          // Meta has not approved it, so it may not be used in a campaign.
          'can_use_in_campaign': false,
        },
      ],
    };

List<dynamic> _tokens() => [
      {'key': 'customer_name', 'label': 'Customer name', 'example': 'Chandra Medicom'},
      {'key': 'product', 'label': 'Product name', 'example': 'Monticope Tablet'},
      {'key': 'custom', 'label': 'Fixed text (type your own)', 'example': ''},
    ];

List<dynamic> _audiences() => [
      {'key': 'all_approved', 'label': 'All approved customers'},
      {'key': 'zone', 'label': 'By zone', 'needs': 'zone_id'},
      {'key': 'never_ordered', 'label': 'Never ordered'},
    ];

List<dynamic> _triggers() => [
      {'key': 'payment_due', 'label': 'Payment pending', 'needs': 'days'},
      {'key': 'back_in_stock', 'label': 'Item back in stock'},
    ];

/// The real preflight wording for a variable mismatch.
const _kMismatch =
    'Template needs 2 value(s) but the campaign supplies 1 — Meta rejects every message on a mismatch';
const _kNoButton =
    'Tracking link is set but this template has no link button — add a URL button ending in {{1}}, or clear the link';

Widget _builder({
  Map<String, dynamic>? preflight,
  Map<String, dynamic>? dryRun,
  Map<String, dynamic>? saveResult,
  Map<String, dynamic>? campaign,
  List<Map<String, dynamic>>? saveCalls,
}) =>
    MaterialApp(
      home: WaCampaignBuilderScreen(
        campaign: campaign,
        audiences: _audiences(),
        triggers: _triggers(),
        templatesRpc: () async => _templatesPayload(),
        tokensRpc: () async => _tokens(),
        saveRpc: (params) async {
          saveCalls?.add(params);
          return saveResult ??
              {
                'ok': true,
                'campaign': {'id': 'c-new', 'name': 'x'}
              };
        },
        preflightRpc: (id) async =>
            preflight ?? {'ok': true, 'errors': [], 'recipients': 500, 'template_status': 'APPROVED'},
        estimateRpc: (n, cat) async => {
          'recipients': n,
          'rate': 0.7846,
          'total': 392.30,
          'label': '₹392.30 for $n messages',
        },
        dryRunRpc: (id, n) async =>
            dryRun ??
            {
              'ok': true,
              'template_body': 'Hi {{1}}, your {{2}} is due for a refill.',
              'pending': 500,
              'samples': [
                {
                  'phone': '919876500001',
                  'variables': ['Chandra Medicom', 'Monticope Tablet'],
                  'preview':
                      'Hi Chandra Medicom, your Monticope Tablet is due for a refill.',
                },
                {
                  'phone': '919876500002',
                  'variables': ['Sahu Pharma', 'Zincovit'],
                  'preview': 'Hi Sahu Pharma, your Zincovit is due for a refill.',
                },
              ],
              'estimate': {'label': '₹392.30 for 500 messages'},
            },
        scheduleRpc: (id, at) async =>
            {'ok': true, 'status': 'scheduled', 'recipients': 500, 'estimate': {'label': '₹392.30 for 500 messages'}},
      ),
    );

/// The builder is a five-step form: on the default 800x600 test viewport the
/// Save and Schedule buttons sit below the fold and are never built, so a
/// tap() on them fails with "found 0 widgets" — which reads like a missing
/// button rather than a missing pixel. A tall surface renders the whole form.
Future<void> _pump(WidgetTester tester, Widget w) async {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(w);
  await tester.pumpAndSettle();
}

/// Save, then drain the toast.
///
/// showToast() holds a 4-second Timer that outlives pumpAndSettle() (a pending
/// timer schedules no frames, so settling returns while it is still armed) and
/// the binding then fails the test on teardown. Pumping past the toast's own
/// lifetime lets it dismiss and remove its overlay entry.
Future<void> _tapSave(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

/// Finds the Schedule ElevatedButton (not the chip or the sheet entry).
ElevatedButton _scheduleButton(WidgetTester tester) => tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Schedule'),
    );

void main() {
  setUp(seedUiCopy);
  setUpAll(() => RenderLog.flushEnabled = false);

  group('template picker', () {
    testWidgets('lists only can_use_in_campaign templates', (tester) async {
      await _pump(tester, _builder());
      await tester.pumpAndSettle();

      expect(find.text('refill_reminder'), findsOneWidget);
      // PENDING at Meta — the app does not re-derive this from status, it
      // obeys can_use_in_campaign.
      expect(find.text('not_yet_approved'), findsNothing);
    });

    testWidgets('shows name, language and category', (tester) async {
      await _pump(tester, _builder());
      await tester.pumpAndSettle();

      expect(find.text('en'), findsOneWidget);
      expect(find.text('Marketing'), findsOneWidget);
    });

    testWidgets('selecting a template draws one row per {{n}} placeholder',
        (tester) async {
      await _pump(tester, _builder());
      await tester.pumpAndSettle();

      expect(find.text('{{1}}'), findsNothing);

      await tester.tap(find.text('refill_reminder'));
      await tester.pumpAndSettle();

      // Body is 'Hi {{1}}, your {{2}} …' — exactly two rows, no more.
      expect(find.text('{{1}}'), findsOneWidget);
      expect(find.text('{{2}}'), findsOneWidget);
      expect(find.text('{{3}}'), findsNothing);
    });
  });

  group('audience: segment and trigger are mutually exclusive', () {
    testWidgets('picking a trigger clears the segment and vice versa',
        (tester) async {
      await _pump(tester, _builder());
      await tester.pumpAndSettle();

      await tester.tap(find.text('All approved customers'));
      await tester.pumpAndSettle();

      ChoiceChip chip(String label) =>
          tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));

      expect(chip('All approved customers').selected, isTrue);
      expect(chip('Payment pending').selected, isFalse);

      await tester.tap(find.text('Payment pending'));
      await tester.pumpAndSettle();

      // Exactly one of the two survives.
      expect(chip('Payment pending').selected, isTrue);
      expect(chip('All approved customers').selected, isFalse);

      await tester.tap(find.text('Never ordered'));
      await tester.pumpAndSettle();

      expect(chip('Never ordered').selected, isTrue);
      expect(chip('Payment pending').selected, isFalse);
    });

    testWidgets('a needs field renders exactly one extra input, keyed by the backend name',
        (tester) async {
      await _pump(tester, _builder());
      await tester.pumpAndSettle();

      final before = find.byType(TextField).evaluate().length;

      // 'Never ordered' has no `needs` — nothing extra appears.
      await tester.tap(find.text('Never ordered'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField).evaluate().length, before);
      expect(find.widgetWithText(TextField, 'zone_id'), findsNothing);

      // 'By zone' needs zone_id — exactly one more field, hinted with the
      // backend's own key.
      await tester.tap(find.text('By zone'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField).evaluate().length, before + 1);
      expect(find.text('zone_id'), findsOneWidget);

      // Switching to a trigger with its own `needs` swaps the input, never
      // stacks a second one.
      await tester.tap(find.text('Payment pending'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField).evaluate().length, before + 1);
      expect(find.text('days'), findsOneWidget);
      expect(find.text('zone_id'), findsNothing);
    });

    testWidgets('the needs value is sent inside p_audience_params',
        (tester) async {
      final calls = <Map<String, dynamic>>[];
      await _pump(tester, _builder(saveCalls: calls));
      await tester.pumpAndSettle();

      await tester.tap(find.text('refill_reminder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('By zone'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'zone_id'), '3');
      await tester.pumpAndSettle();

      await _tapSave(tester);

      expect(calls, hasLength(1));
      expect(calls.first['p_audience_kind'], 'zone');
      expect(calls.first['p_audience_params'], {'zone_id': 3});
      // A segment campaign carries no trigger.
      expect(calls.first['p_trigger_kind'], isNull);
    });

    testWidgets('a trigger campaign sends p_trigger_kind and no audience kind',
        (tester) async {
      final calls = <Map<String, dynamic>>[];
      await _pump(tester, _builder(saveCalls: calls));
      await tester.pumpAndSettle();

      await tester.tap(find.text('refill_reminder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Payment pending'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'days'), '7');
      await tester.pumpAndSettle();

      await _tapSave(tester);

      expect(calls.first['p_trigger_kind'], 'payment_due');
      expect(calls.first['p_audience_kind'], isNull);
      expect(calls.first['p_audience_params'], {'days': 7});
    });
  });

  group('variables', () {
    testWidgets('a token row sends "{{token_key}}" and shows its example',
        (tester) async {
      final calls = <Map<String, dynamic>>[];
      await _pump(tester, _builder(saveCalls: calls));
      await tester.pumpAndSettle();

      await tester.tap(find.text('refill_reminder'));
      await tester.pumpAndSettle();

      // Bind {{1}} to the customer-name token.
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Customer name').last);
      await tester.pumpAndSettle();

      // The token's example is shown inline, from the payload.
      expect(find.text('e.g. Chandra Medicom'), findsOneWidget);

      await _tapSave(tester);

      // p_variable_map is an ORDERED ARRAY OF STRINGS — wa_render_vars()
      // replaces {{customer_name}} per recipient. Anything else renders as
      // itself in the customer's message.
      final map = calls.first['p_variable_map'] as List;
      expect(map, hasLength(2));
      expect(map.first, '{{customer_name}}');
    });

    testWidgets('the fixed-text token reveals a text input and sends it raw',
        (tester) async {
      final calls = <Map<String, dynamic>>[];
      await _pump(tester, _builder(saveCalls: calls));
      await tester.pumpAndSettle();

      await tester.tap(find.text('refill_reminder'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fixed text (type your own)').last);
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'Fixed text'), findsOneWidget);
      await tester.enterText(
          find.widgetWithText(TextField, 'Fixed text'), 'Diwali offer');
      await tester.pumpAndSettle();

      await _tapSave(tester);

      expect((calls.first['p_variable_map'] as List).first, 'Diwali offer');
    });
  });

  group('preflight gates scheduling', () {
    testWidgets('errors[] render verbatim and Schedule is disabled',
        (tester) async {
      await _pump(tester, _builder(
        preflight: {
          'ok': false,
          'errors': [_kMismatch, _kNoButton],
          'recipients': 0,
          'template_status': 'APPROVED',
        },
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('refill_reminder'));
      await tester.pumpAndSettle();
      await _tapSave(tester);

      // Word for word, both of them.
      expect(find.text(_kMismatch), findsOneWidget);
      expect(find.text(_kNoButton), findsOneWidget);

      // The guard itself.
      expect(_scheduleButton(tester).onPressed, isNull);
    });

    testWidgets('an empty errors[] enables Schedule and shows the cost line',
        (tester) async {
      await _pump(tester, _builder());
      await tester.pumpAndSettle();

      await tester.tap(find.text('refill_reminder'));
      await tester.pumpAndSettle();
      await _tapSave(tester);

      expect(_scheduleButton(tester).onPressed, isNotNull);
      expect(find.text('Ready to schedule'), findsOneWidget);
      // The estimate sentence is the backend's; nothing is multiplied here.
      expect(find.text('₹392.30 for 500 messages'), findsOneWidget);
    });

    testWidgets('changing the template after a clean preflight re-disables Schedule',
        (tester) async {
      await _pump(tester, _builder());
      await tester.pumpAndSettle();

      await tester.tap(find.text('refill_reminder'));
      await tester.pumpAndSettle();
      await _tapSave(tester);
      expect(_scheduleButton(tester).onPressed, isNotNull);

      // Re-selecting the template invalidates what preflight said about the
      // old form. A green light must never outlive the thing it approved.
      await tester.tap(find.text('refill_reminder'));
      await tester.pumpAndSettle();

      expect(_scheduleButton(tester).onPressed, isNull);
      expect(find.text('Ready to schedule'), findsNothing);
    });

    testWidgets('a save error is printed and no campaign is scheduled',
        (tester) async {
      await _pump(tester, _builder(
        saveResult: {
          'error': 'template_not_approved',
          'message': 'Only an Approved template can be used for a campaign',
        },
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('refill_reminder'));
      await tester.pumpAndSettle();

      // Asserted while the toast is still up — _tapSave() deliberately pumps
      // past its lifetime, which would dismiss the very message under test.
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pumpAndSettle();

      expect(
        find.text('Only an Approved template can be used for a campaign'),
        findsOneWidget,
      );
      // Never reached a state that offers Schedule.
      expect(find.widgetWithText(ElevatedButton, 'Schedule'), findsNothing);

      // Let the toast retire so its timer does not outlive the tree.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  group('dry run sheet', () {
    testWidgets('shows each sample preview from the response and the estimate',
        (tester) async {
      await _pump(tester, _builder());
      await tester.pumpAndSettle();

      await tester.tap(find.text('refill_reminder'));
      await tester.pumpAndSettle();
      await _tapSave(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Dry run'));
      await tester.pumpAndSettle();

      // The template body, still holding its placeholders.
      expect(find.text('Hi {{1}}, your {{2}} is due for a refill.'),
          findsOneWidget);

      // Each sample's `preview` — rendered by wa_render_preview() server-side,
      // printed here unchanged.
      expect(
        find.text('Hi Chandra Medicom, your Monticope Tablet is due for a refill.'),
        findsOneWidget,
      );
      expect(
        find.text('Hi Sahu Pharma, your Zincovit is due for a refill.'),
        findsOneWidget,
      );
      expect(find.text('919876500001'), findsOneWidget);
      expect(find.text('919876500002'), findsOneWidget);

      // estimate.label and the pending count, both verbatim.
      expect(find.text('₹392.30 for 500 messages'), findsWidgets);
      expect(find.text('500 pending'), findsOneWidget);
    });
  });
}
