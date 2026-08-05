// The submit gate, the media header, the duplicate check and the AI policy
// review — all four rendered from their own RPC and nothing else.
//
// What this holds down:
//
//   1. Submit stays DISABLED when wa_template_submit_blockers says
//      can_submit:false, and why_label is printed under it. A greyed-out
//      button with no reason on screen is the bug this file exists to stop.
//
//   2. Tapping that disabled button opens the blockers sheet listing every
//      issue AND its fix. Both halves matter: the issue alone tells the admin
//      they are stuck without telling them how to get out.
//
//   3. can_submit:true enables Submit. The gate is a backend answer in both
//      directions — it must not become a one-way latch that never re-opens.
//
//   4. wa_template_similar with blocking:true disables Submit and shows the
//      backend's summary as the reason, exactly like a blocker.
//
//   5. wa_template_header_status with expired:true paints the blocker in the
//      BAD tone and offers Re-upload. A stale sample looks fine right up until
//      Meta rejects the submission, so it may not render as merely muted.
//
//   6. A verdict whose suggested_body is null offers NO "Use this wording"
//      button. Offering a rewrite that does not exist would wipe the body.
//
// Every payload below is the shape the live RPCs actually return, taken from
// their function definitions on 2026-08-04 — including the trap that
// wa_template_header_status and wa_policy_review_latest each carry a NULLABLE
// `error` INSIDE a perfectly healthy payload.
//
// No network, no Supabase, no home_shell, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/features/whatsapp/data/wa_template_api.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_template_bits.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_template_editor_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ────────────────────────────────────────────────────────────────

const _templateId = '6b18ac69-c378-472c-99e1-df977a140a2a';

Map<String, dynamic> _screen() => {
      'copy': const {
        'save': 'Save',
        'submit': 'Submit',
        'editor_edit_title': 'Edit template',
        'editor_new_title': 'New template',
        'body_label': 'Message body',
        'header_label': 'Header (optional)',
        'footer_label': 'Footer (optional)',
        'name_label': 'Template name',
        'language_label': 'Language',
        'category_label': 'Category',
        'buttons_title': 'Buttons',
        'tokens_title': 'Insert a value',
        'preview_title': 'Preview',
        'errors_title': 'Fix before saving',
        'warnings_title': 'Suggestions',
      },
      'starters': const [],
      'tokens': const [],
      'categories': const [
        {'key': 'UTILITY', 'label': 'Utility'},
      ],
      'languages': const [
        {'key': 'en', 'label': 'English'},
      ],
      'button_spec': const {'types': [], 'total_max': 10, 'text_max': 25},
    };

Map<String, dynamic> _template() => {
      'id': _templateId,
      'name': 'order_dispatched',
      'language': 'en',
      'category': 'UTILITY',
      'components': const [
        {'type': 'BODY', 'text': 'Hi {{1}}, your order {{2}} has been sent.'},
      ],
      'token_map': const [],
    };

/// wa_template_submit_blockers, verbatim shape.
Map<String, dynamic> _gate({required bool canSubmit}) => canSubmit
    ? {
        'can_submit': true,
        'blockers': const [],
        'count': 0,
        'why_label': null,
        'warnings': const [],
      }
    : {
        'can_submit': false,
        'count': 2,
        'why_label': "Can't submit yet — 2 things to fix",
        'blockers': const [
          {
            'issue': 'The picture or file header has no sample yet',
            'fix': 'Upload the sample file Meta will review',
          },
          {
            'issue': 'Meta is still reviewing this template',
            'fix': 'Wait for the verdict — you cannot resubmit while it is pending',
          },
        ],
        'warnings': const ['Marketing templates need an opt-out button'],
      };

/// wa_template_header_status. Note `error` is present and NULL on a healthy
/// payload — it is the upload's failure text, not an error envelope.
Map<String, dynamic> _headerStatus({required bool expired}) => expired
    ? {
        'header_format': 'IMAGE',
        'has_sample': false,
        'file_label': 'promo.png',
        'size_label': '412 KB',
        'expires_label': 'Sample expired 02 Aug',
        'expired': true,
        'status': 'expired',
        'status_label': 'Sample expired — upload it again',
        'tone': 'bad',
        'error': null,
        'can_submit': false,
        'blocker':
            'The sample file you uploaded has expired at Meta — upload it again',
      }
    : {
        'header_format': 'TEXT',
        'has_sample': false,
        'file_label': '—',
        'size_label': null,
        'expires_label': null,
        'expired': false,
        'status': 'none',
        'status_label': 'No sample uploaded yet',
        'tone': 'muted',
        'error': null,
        'can_submit': true,
        'blocker': null,
      };

const _mediaSpec = {
  'formats': [
    {'value': 'TEXT', 'label': 'Text header', 'max_chars': 60, 'needs_sample': false},
    {
      'value': 'IMAGE',
      'label': 'Image header',
      'accepts': 'jpg, png',
      'max_mb': 5,
      'needs_sample': true,
    },
  ],
  'rules': ['A media header cannot also carry text.'],
  'blocked_reason': null,
};

Map<String, dynamic> _similar({required bool blocking}) => blocking
    ? {
        'rows': const [
          {
            'name': 'order_sent',
            'language': 'en',
            'status': 'APPROVED',
            'pct': 82,
            'label': 'order_sent (en) — 82% similar',
            'tone': 'bad',
          },
        ],
        'top_pct': 82,
        'tone': 'bad',
        'blocking': true,
        'summary':
            'Too close to an existing template (82%) — Meta rejects near-duplicates.',
      }
    : {
        'rows': const [],
        'top_pct': 0,
        'tone': 'good',
        'blocking': false,
        'summary': 'No template close enough to risk a duplicate rejection',
      };

/// wa_policy_review_latest. `error` is null INSIDE the healthy payload.
Map<String, dynamic> _policy({required String? suggestedBody}) => {
      'review_id': 'r1',
      'status': 'done',
      'label': 'Approved as UTILITY',
      'tone': 'good',
      'error': null,
      'when_label': '04 Aug, 11:20 AM',
      'verdict': {
        'risk': 'low',
        'verdict_label': 'Approved as UTILITY',
        'category_advice': 'The UTILITY category is correct.',
        'likely_rejection_reason': null,
        'issues': const [
          {
            'severity': 'low',
            'issue': 'The footer repeats the brand name',
            'fix': 'Drop the footer — the sender name already shows it',
          },
        ],
        'suggested_body': suggestedBody,
      },
    };

// ── harness ─────────────────────────────────────────────────────────────────

/// Answers every RPC the editor calls. Anything not named here returns {},
/// which must leave the gate alone rather than block Submit.
void _stub({
  Map<String, dynamic>? gate,
  Map<String, dynamic>? headerStatus,
  Map<String, dynamic>? similar,
  Map<String, dynamic>? policy,
}) {
  WaTemplateApi.rpcTransport = (fn, params) async {
    switch (fn) {
      case 'wa_template_validate':
        return {'ok': true, 'errors': const [], 'warnings': const []};
      case 'wa_template_preview':
        return {'body': 'PREVIEW-FROM-BACKEND', 'buttons': const []};
      case 'wa_template_submit_blockers':
        return gate ?? const <String, dynamic>{};
      case 'wa_template_header_status':
        return headerStatus ?? const <String, dynamic>{};
      case 'wa_template_media_spec':
        return _mediaSpec;
      case 'wa_template_similar':
        return similar ?? const <String, dynamic>{};
      case 'wa_policy_review_latest':
        return policy ?? const <String, dynamic>{};
      case 'wa_policy_apply':
        // The one-tap apply persists and re-lints the review's rewrite
        // server-side, then hands the new body back. Mirror that: echo the
        // verdict's suggested_body as the applied wording.
        final sb =
            ((policy?['verdict'] as Map?)?['suggested_body'] ?? '').toString();
        return {
          'ok': true,
          'body': sb,
          'message': 'Suggested wording applied',
          'warnings': const [],
        };
      default:
        return const <String, dynamic>{};
    }
  };
}

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1000, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    home: WaTemplateEditorScreen(screen: _screen(), template: _template()),
  ));
  // Past the lint debounce AND the longer duplicate-check debounce.
  await tester.pump(WaTemplateEditorScreen.similarDebounce +
      const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

ElevatedButton _submit(WidgetTester tester) =>
    tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Submit'));

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() {
    WaTemplateApi.rpcTransport = null;
    WaTemplateEditorScreen.filePicker = null;
  });

  // ── A. the submit gate ────────────────────────────────────────────────────

  testWidgets('can_submit:false leaves Submit disabled and prints why_label',
      (tester) async {
    _stub(gate: _gate(canSubmit: false));
    await _pump(tester);

    expect(_submit(tester).onPressed, isNull);
    expect(find.text("Can't submit yet — 2 things to fix"), findsOneWidget);
  });

  testWidgets('tapping the disabled Submit lists every issue AND its fix',
      (tester) async {
    _stub(gate: _gate(canSubmit: false));
    await _pump(tester);

    // The blockers live ONLY in the sheet. Proving they are absent first is
    // what makes the assertions below evidence that the tap opened it, rather
    // than evidence that the strings happened to be on the page all along.
    expect(find.text('The picture or file header has no sample yet'),
        findsNothing);

    // The editor is taller than the 800x600 test viewport, so the button sits
    // off-screen and a bare tap() would miss it and silently pass.
    final submit = find.widgetWithText(ElevatedButton, 'Submit');
    await tester.ensureVisible(submit);
    await tester.pumpAndSettle();
    // warnIfMissed: the disabled button sits under an IgnorePointer so the tap
    // is caught by the GestureDetector wrapping it — the hit test resolving to
    // the ancestor instead of the button is the design, not a missed tap. The
    // findsNothing above and findsOneWidget below are what prove it landed.
    await tester.tap(submit, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.text('The picture or file header has no sample yet'),
        findsOneWidget);
    expect(find.text('Upload the sample file Meta will review'), findsOneWidget);
    expect(find.text('Meta is still reviewing this template'), findsOneWidget);
    expect(
        find.text(
            'Wait for the verdict — you cannot resubmit while it is pending'),
        findsOneWidget);
    // Warnings are listed, but apart from the blockers — they do not block.
    expect(find.text('Marketing templates need an opt-out button'),
        findsOneWidget);
  });

  testWidgets('can_submit:true enables Submit', (tester) async {
    _stub(gate: _gate(canSubmit: true), similar: _similar(blocking: false));
    await _pump(tester);

    expect(_submit(tester).onPressed, isNotNull);
    expect(find.textContaining("Can't submit yet"), findsNothing);
  });

  // ── C. duplicate check ────────────────────────────────────────────────────

  testWidgets('similar blocking:true disables Submit and shows the summary',
      (tester) async {
    _stub(gate: _gate(canSubmit: true), similar: _similar(blocking: true));
    await _pump(tester);

    expect(_submit(tester).onPressed, isNull);
    expect(
        find.text(
            'Too close to an existing template (82%) — Meta rejects near-duplicates.'),
        findsWidgets);
    // The row is listed with the backend's own label.
    expect(find.text('order_sent (en) — 82% similar'), findsOneWidget);
  });

  // ── B. media header ───────────────────────────────────────────────────────

  testWidgets('expired sample shows the blocker in the bad tone with Re-upload',
      (tester) async {
    _stub(
      gate: _gate(canSubmit: false),
      headerStatus: _headerStatus(expired: true),
    );
    await _pump(tester);

    final blocker =
        'The sample file you uploaded has expired at Meta — upload it again';
    expect(find.text(blocker), findsOneWidget);
    expect(find.text('Re-upload'), findsOneWidget);

    // The banner carrying it is painted in the BAD tone, not merely muted.
    final banner = tester.widget<WaBanner>(
      find.ancestor(of: find.text(blocker), matching: find.byType(WaBanner)),
    );
    expect(WaTone.of(banner.tone).bg, equals(WaTone.of('bad').bg));
    expect(WaTone.of('bad').bg, isNot(equals(WaTone.of('muted').bg)));
  });

  // ── D. AI policy review ───────────────────────────────────────────────────

  testWidgets('a verdict with suggested_body null offers no rewrite button',
      (tester) async {
    _stub(
      gate: _gate(canSubmit: true),
      similar: _similar(blocking: false),
      policy: _policy(suggestedBody: null),
    );
    await _pump(tester);

    // The verdict itself renders...
    expect(find.text('Approved as UTILITY'), findsWidgets);
    expect(find.text('The footer repeats the brand name'), findsOneWidget);
    // ...but nothing offers to replace the body with wording that is not there.
    expect(find.text('Use this wording'), findsNothing);
  });

  testWidgets('a verdict WITH suggested_body offers it and replaces the body',
      (tester) async {
    const rewrite = 'Hi {{1}}, order {{2}} is on its way.';
    _stub(
      gate: _gate(canSubmit: true),
      similar: _similar(blocking: false),
      policy: _policy(suggestedBody: rewrite),
    );
    await _pump(tester);

    expect(find.text('Use this wording'), findsOneWidget);
    await tester.tap(find.text('Use this wording'));
    await tester.pumpAndSettle();
    // wa_policy_apply's success toast schedules a 4s auto-dismiss; let it expire
    // so no real Timer outlives the test.
    await tester.pump(const Duration(seconds: 5));

    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, rewrite))
          .controller
          ?.text,
      equals(rewrite),
    );
  });

  // ── the trap ──────────────────────────────────────────────────────────────

  testWidgets('a null `error` inside a healthy payload is not an error',
      (tester) async {
    // Both of these carry error:null in their SUCCESS shape. Treating "has an
    // error key" as a failure would blank both sections.
    _stub(
      gate: _gate(canSubmit: true),
      similar: _similar(blocking: false),
      headerStatus: _headerStatus(expired: true),
      policy: _policy(suggestedBody: null),
    );
    await _pump(tester);

    expect(find.text('Sample expired — upload it again'), findsOneWidget);
    expect(find.text('Approved as UTILITY'), findsWidgets);
  });

  testWidgets('an error envelope changes nothing', (tester) async {
    WaTemplateApi.rpcTransport = (fn, params) async {
      switch (fn) {
        case 'wa_template_validate':
          return {'ok': true, 'errors': const [], 'warnings': const []};
        case 'wa_template_preview':
          return {'body': 'PREVIEW-FROM-BACKEND', 'buttons': const []};
        // Every gated RPC refuses, with no message to render.
        default:
          return {'error': 'not_authorized'};
      }
    };
    await _pump(tester);

    // A refusal must not invent a reason, and must not latch Submit off.
    expect(_submit(tester).onPressed, isNotNull);
    expect(find.textContaining("Can't submit yet"), findsNothing);
  });
}
