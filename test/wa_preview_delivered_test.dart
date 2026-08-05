// The preview renders the way WhatsApp DELIVERS the message, and AI fixes apply
// with one tap.
//
// What this holds down (all DISPLAY, nothing here changes what is saved except
// the one-tap apply, which goes through wa_policy_apply server-side):
//
//   A. A private-bucket sample is SIGNED from the bucket and path the backend
//      named, then shown as the real picture — not a file tile. An approved
//      image (media_url set) is used directly, with no signing.
//   B. The buttons are NOT inside the bubble: they render as their own
//      full-width tiles BELOW it, one per row, never in a Row. The footer sits
//      beneath the body inside the bubble.
//   C. "Use this wording" (or the review's apply_all_label) calls wa_policy_apply
//      and replaces the body with the wording it returns, showing its message.
//      An error leaves the body untouched. No rewrite button when suggested_body
//      is null.
//
// The RPCs and the storage signer are both mocked inline — no network, no
// Supabase client, no home_shell import.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/features/whatsapp/data/wa_template_api.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_template_editor_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ────────────────────────────────────────────────────────────────

Map<String, dynamic> _screen() => {
      'copy': const {
        'save': 'Save',
        'submit': 'Submit',
        'editor_new_title': 'New template',
        'editor_edit_title': 'Edit template',
        'preview_title': 'Preview',
        'errors_title': 'Fix before saving',
        'warnings_title': 'Suggestions',
        'name_label': 'Template name',
        'language_label': 'Language',
        'category_label': 'Category',
        'body_label': 'Message body',
        'header_label': 'Header (optional)',
        'footer_label': 'Footer (optional)',
        'buttons_title': 'Buttons',
        'tokens_title': 'Insert a value',
        'examples_title': 'Example values',
        'saved': 'Saved',
        'generic_error': 'Something went wrong',
      },
      'starters': const [],
      'tokens': const [],
      'categories': const [
        {'key': 'UTILITY', 'label': 'Utility', 'note': ''},
      ],
      'languages': const [
        {'key': 'en', 'label': 'English'},
      ],
      'button_spec': const {'types': [], 'total_max': 10, 'text_max': 25},
    };

Map<String, dynamic> _template() => {
      'id': 'tpl-1',
      'name': 'order_shipped',
      'language': 'en',
      'category': 'UTILITY',
      'components': const [
        {'type': 'BODY', 'text': 'Hi {{1}}'},
      ],
      'token_map': const [],
    };

Map<String, dynamic> _imageHeader({
  String mediaUrl = '',
  String storageBucket = '',
  String storagePath = '',
}) =>
    {
      'format': 'IMAGE',
      'is_image': true,
      'is_pdf': false,
      'is_video': false,
      'media_url': mediaUrl,
      'storage_bucket': storageBucket,
      'storage_path': storagePath,
      'file_label': 'promo.jpg',
      'size_label': '210 KB',
      'expires_label': '',
      'expired': false,
      'placeholder_label': '',
      'missing_label': '',
    };

Map<String, dynamic> _preview({
  Object? header,
  String bodyRendered = 'Hi Chandra Medicom',
  String footer = 'Reply STOP to opt out',
  List<dynamic> buttons = const [],
}) =>
    {
      'header': header,
      'body_raw': 'Hi {{1}}',
      'body_rendered': bodyRendered,
      'footer': footer,
      'buttons': buttons,
      'rendered_note': '',
      'char_count': 0,
    };

/// wa_policy_review_latest with a done verdict.
Map<String, dynamic> _policy({
  required String? suggestedBody,
  String? applyAllLabel,
}) =>
    {
      'review_id': 'r1',
      'status': 'done',
      'label': 'Approved as UTILITY',
      'tone': 'good',
      'error': null,
      'verdict': {
        'risk': 'low',
        'verdict_label': 'Approved as UTILITY',
        'category_advice': '',
        'likely_rejection_reason': null,
        'issues': const [],
        'suggested_body': suggestedBody,
        'apply_all_label': ?applyAllLabel,
      },
    };

// ── harness ─────────────────────────────────────────────────────────────────

class _Signer {
  final List<List<String>> calls = [];
  String? url = 'https://signed.example/sample?token=abc';
}

/// Installs the transports. [preview] drives the saved-row bubble; [policy] the
/// AI check; [apply] the one-tap wa_policy_apply result.
_Signer _install({
  required Map<String, dynamic> preview,
  Map<String, dynamic>? policy,
  Map<String, dynamic>? apply,
}) {
  final signer = _Signer();

  WaTemplateApi.rpcTransport = (fn, params) async {
    switch (fn) {
      case 'wa_template_validate':
        return {'ok': true, 'errors': const [], 'warnings': const []};
      case 'wa_template_preview':
        // The saved-row call carries p_template_id; the live components call
        // carries p_components. Only the first drives the bubble.
        if (params.containsKey('p_template_id')) return preview;
        return {'header': null, 'body': 'live', 'footer': '', 'buttons': const []};
      case 'wa_body_renumber':
        return {
          'body': params['p_body'],
          'token_map': params['p_token_map'],
          'changed': false,
        };
      case 'wa_tokens_screen':
        return {'rows': const [], 'search': null, 'empty_copy': 'No values'};
      case 'wa_policy_review_latest':
        return policy ?? const <String, dynamic>{};
      case 'wa_policy_apply':
        return apply ?? const <String, dynamic>{};
      default:
        // Header status, media spec, submit blockers, similar — each guarded by
        // its own required-field check, so an empty map leaves them alone.
        return const <String, dynamic>{};
    }
  };

  WaTemplateApi.signerTransport = (bucket, path, expiresIn) async {
    signer.calls.add([bucket, path]);
    return signer.url;
  };

  return signer;
}

Future<_Signer> _pump(
  WidgetTester tester, {
  required Map<String, dynamic> preview,
  Map<String, dynamic>? policy,
  Map<String, dynamic>? apply,
  // Narrow, so the two-pane layout collapses to a single column and the only
  // Rows around the preview are the ones the widgets themselves build.
  Size size = const Size(500, 4000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final signer = _install(preview: preview, policy: policy, apply: apply);
  await tester.pumpWidget(MaterialApp(
    home: WaTemplateEditorScreen(screen: _screen(), template: _template()),
  ));
  await tester.pump(); // id-preview fetch
  await tester.pump(
      WaTemplateEditorScreen.debounce + const Duration(milliseconds: 50));
  // Deliberately NOT pumpAndSettle: Image.network's fake-load error fires during
  // a settle and swaps the picture for the fallback tile, which would defeat the
  // "renders an image, not a tile" assertion. One more frame is enough to build.
  await tester.pump();
  return signer;
}

Finder _bubble() => find.byKey(const Key('wa_preview_bubble'));
Finder _bubbleImage() =>
    find.descendant(of: _bubble(), matching: find.byType(Image));

/// The body field is the multi-line one.
TextEditingController _bodyController(WidgetTester tester) => tester
    .widget<TextField>(
        find.byWidgetPredicate((w) => w is TextField && w.maxLines == 6))
    .controller!;

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() {
    WaTemplateApi.rpcTransport = null;
    WaTemplateApi.signerTransport = null;
  });

  // ── A. the real image ──────────────────────────────────────────────────────

  testWidgets('a private sample is signed from the payload bucket and path, '
      'and renders as an image not a tile', (tester) async {
    final signer = await _pump(
      tester,
      preview: _preview(
        header: _imageHeader(
          storageBucket: 'whatsapp-media',
          storagePath: 'whatsapp/tpl_1_sample.jpg',
        ),
      ),
    );

    // Signed from EXACTLY the bucket and path the backend named — never guessed.
    expect(signer.calls, isNotEmpty);
    expect(signer.calls.first[0], 'whatsapp-media');
    expect(signer.calls.first[1], 'whatsapp/tpl_1_sample.jpg');

    // The picture itself is built in the bubble — an Image on the signed URL,
    // not a bare file tile. (In a widget test Image.network's fake fetch always
    // errors to its fallback, so we assert the Image widget is there — the same
    // signal the existing preview test relies on — not a painted bitmap.)
    expect(_bubbleImage(), findsOneWidget);
  });

  testWidgets('an approved image (media_url set) is used directly, no signing',
      (tester) async {
    final signer = await _pump(
      tester,
      preview: _preview(
        header: _imageHeader(mediaUrl: 'https://cdn.example/promo.jpg'),
      ),
    );

    // Meta's CDN link is public — signing it would be pointless, so it is not.
    expect(signer.calls, isEmpty);
    expect(_bubbleImage(), findsOneWidget);
  });

  // ── B. the delivered bubble ────────────────────────────────────────────────

  testWidgets('buttons render as full-width tiles BELOW the bubble, one per row',
      (tester) async {
    await _pump(
      tester,
      preview: _preview(
        header: null,
        buttons: const [
          {'text': 'Track order', 'kind': 'URL', 'kind_label': 'Opens a link'},
          {
            'text': 'Stop promotions',
            'kind': 'QUICK_REPLY',
            'kind_label': 'Quick reply'
          },
        ],
      ),
    );

    await tester.ensureVisible(find.text('Stop promotions'));
    await tester.pumpAndSettle();

    // Both are on screen...
    expect(find.text('Track order'), findsOneWidget);
    expect(find.text('Stop promotions'), findsOneWidget);

    // ...OUTSIDE the bubble, in their own tile group...
    expect(
        find.descendant(of: _bubble(), matching: find.text('Track order')),
        findsNothing);
    expect(
        find.descendant(
            of: find.byKey(const Key('wa_preview_buttons')),
            matching: find.text('Track order')),
        findsOneWidget);

    // ...never side by side in a Row...
    expect(
        find.ancestor(
            of: find.text('Track order'), matching: find.byType(Row)),
        findsNothing);

    // ...one per row, stacked and centred in tiles of the same width (the
    // centres line up though the two labels differ in length), BELOW the bubble.
    final b1 = tester.getCenter(find.text('Track order'));
    final b2 = tester.getCenter(find.text('Stop promotions'));
    expect(b1.dy, lessThan(b2.dy)); // stacked, one per row
    expect(b1.dx, closeTo(b2.dx, 0.5)); // same tile width → same centre
    expect(tester.getBottomLeft(_bubble()).dy, lessThanOrEqualTo(b1.dy));
  });

  testWidgets('the footer renders beneath the body INSIDE the bubble',
      (tester) async {
    await _pump(
      tester,
      preview: _preview(
        header: null,
        bodyRendered: 'Your order has shipped',
        footer: 'Reply STOP to opt out',
      ),
    );

    // Footer is inside the bubble...
    expect(
        find.descendant(
            of: _bubble(), matching: find.text('Reply STOP to opt out')),
        findsOneWidget);
    // ...and below the body.
    final bodyTop = tester.getTopLeft(find.text('Your order has shipped')).dy;
    final footerTop = tester.getTopLeft(find.text('Reply STOP to opt out')).dy;
    expect(footerTop, greaterThan(bodyTop));
  });

  // ── C. one-tap apply ───────────────────────────────────────────────────────

  testWidgets('apply calls wa_policy_apply, replaces the body and shows message',
      (tester) async {
    const rewrite = 'Hi {{1}}, your order is on its way.';
    await _pump(
      tester,
      preview: _preview(header: null),
      policy: _policy(suggestedBody: rewrite, applyAllLabel: 'Apply all fixes'),
      apply: {
        'ok': true,
        'body': rewrite,
        'message': 'Suggested wording applied',
        'warnings': const [],
      },
    );

    // The caption is the review's own apply_all_label.
    final button = find.text('Apply all fixes');
    expect(button, findsOneWidget);
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5)); // drain the toast timer

    // The body field now holds the wording the backend returned.
    expect(_bodyController(tester).text, rewrite);
    // And its message is shown verbatim.
    expect(find.text('Suggested wording applied'), findsOneWidget);
  });

  testWidgets('an apply error leaves the body untouched and shows the message',
      (tester) async {
    await _pump(
      tester,
      preview: _preview(header: null),
      policy: _policy(suggestedBody: 'Hi {{1}}, rewritten.'),
      apply: {
        'error': 'variables_changed',
        'message': 'That rewrite would change the variables, so it was not applied',
      },
    );

    // No apply_all_label → the one permitted Dart literal is the caption.
    final button = find.text('Use this wording');
    expect(button, findsOneWidget);
    final before = _bodyController(tester).text;

    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));

    // Nothing changed; the refusal is shown in the backend's own words.
    expect(_bodyController(tester).text, before);
    expect(
        find.text(
            'That rewrite would change the variables, so it was not applied'),
        findsOneWidget);
  });

  testWidgets('no rewrite button when suggested_body is null', (tester) async {
    await _pump(
      tester,
      preview: _preview(header: null),
      policy: _policy(suggestedBody: null),
    );

    // The verdict still renders, but there is nothing to apply.
    expect(find.text('Approved as UTILITY'), findsWidgets);
    expect(find.text('Use this wording'), findsNothing);
    expect(find.text('Apply all fixes'), findsNothing);
  });
}
