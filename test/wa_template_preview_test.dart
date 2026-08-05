// WhatsApp template editor — the message preview shows the uploaded sample.
//
// What this holds down (all DISPLAY, nothing here changes what is saved):
//
//   1. wa_preview_draft feeds the whole bubble, off the live editor state. When
//      its header is an approved image (media_url set) the picture renders
//      INSIDE the bubble, ABOVE the rendered body — the message reads the way
//      the customer will see it.
//
//   2. A sample in the PRIVATE bucket is signed from the bucket and path the
//      backend named — never a guessed public URL. The signer is called with
//      exactly those two values.
//
//   3. A PDF sample renders as a file tile carrying the backend's file_label
//      (no image, no wording invented here).
//
//   4. Before a sample exists the bubble shows the backend's placeholder box
//      and the missing-sample warning — both verbatim.
//
//   5. A null header draws no header area at all.
//
//   6. The bubble reads body_rendered (values substituted), never body_raw
//      ({{1}}).
//
//   7. An expired sample is shown in the bad tone beside the re-upload action.
//
// The RPC and the storage signer are both mocked inline — no network, no
// Supabase client, no home_shell.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/features/whatsapp/data/wa_template_api.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_template_bits.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_template_editor_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ────────────────────────────────────────────────────────────────

/// The wa_templates_screen() sub-payload the editor needs to build. Only the
/// keys this screen reads are present; every user-facing string is here, none
/// is written in Dart.
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

/// A saved template whose header format is IMAGE, so the media-header section
/// renders alongside the bubble.
Map<String, dynamic> _template() => {
      'id': 'tpl-1',
      'name': 'order_shipped',
      'language': 'en',
      'category': 'UTILITY',
      'components': const [
        {'type': 'HEADER', 'format': 'IMAGE'},
        {'type': 'BODY', 'text': 'Hi {{1}}'},
      ],
      'token_map': const [],
    };

// ── harness ─────────────────────────────────────────────────────────────────

/// Records every signer call so a test can prove the bucket and path came from
/// the payload, not from anywhere the app guessed.
class _SignerLog {
  final List<List<String>> calls = [];
  String? url = 'https://signed.example/sample?token=abc';
}

/// Installs the transports. [preview] is the wa_preview_draft payload under
/// test — the editor drives the bubble off the live state now, so this is what
/// feeds it whether or not the row is saved.
_SignerLog _install(Map<String, dynamic> preview) {
  final signer = _SignerLog();

  WaTemplateApi.rpcTransport = (fn, params) async {
    switch (fn) {
      case 'wa_template_validate':
        return {'ok': true, 'errors': const [], 'warnings': const []};
      case 'wa_preview_draft':
        // The bubble is the live draft preview now — built from the components
        // the editor holds. wa_template_preview is no longer called here.
        return preview;
      case 'wa_tokens_screen':
        return {'rows': const [], 'search': null, 'empty_copy': 'No values'};
      // The header block now reads the sample's location from the STATUS, so a
      // saved row's header status mirrors the media header under test (with the
      // has_sample flag the block gates on).
      case 'wa_template_header_status':
        final hdr = preview['header'];
        if (hdr is Map) {
          return {
            ...hdr.cast<String, dynamic>(),
            'has_sample': true,
            'header_format': hdr['format'],
          };
        }
        return const <String, dynamic>{};
      // The remaining reads the editor fires for a saved row. Empty maps are
      // healthy here (each is guarded by its own required-field check).
      case 'wa_template_media_spec':
      case 'wa_template_submit_blockers':
      case 'wa_policy_review_latest':
      default:
        return const <String, dynamic>{};
    }
  };

  WaTemplateApi.signerTransport = (bucket, path, expiresIn) async {
    signer.calls.add([bucket, path]);
    return signer.url;
  };

  return signer;
}

Future<void> _pump(WidgetTester tester, Map<String, dynamic> preview) async {
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  _install(preview);
  await tester.pumpWidget(MaterialApp(
    home: WaTemplateEditorScreen(screen: _screen(), template: _template()),
  ));
  // Let the id-preview fetch, the signer future and the lint debounce settle.
  await tester.pump();
  await tester.pump(WaTemplateEditorScreen.debounce + const Duration(milliseconds: 50));
  await tester.pump();
}

/// The image inside the bubble specifically (the media-header section may hold
/// its own copy of the same picture).
Finder _bubbleImage() => find.descendant(
      of: find.byKey(const Key('wa_preview_bubble')),
      matching: find.byType(Image),
    );

// ── media payloads ────────────────────────────────────────────────────────────

Map<String, dynamic> _imageHeader({
  String mediaUrl = '',
  String storageBucket = '',
  String storagePath = '',
  bool expired = false,
  String expiresLabel = '',
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
      'expires_label': expiresLabel,
      'expired': expired,
      'placeholder_label': '',
      'missing_label': '',
    };

Map<String, dynamic> _previewWith(
  Object? header, {
  String bodyRendered = 'Hi Chandra Medicom',
  String bodyRaw = 'Hi {{1}}',
  List<dynamic> buttons = const [],
}) =>
    {
      'header': header,
      'body_raw': bodyRaw,
      'body_rendered': bodyRendered,
      'footer': 'Reply STOP to opt out',
      'buttons': buttons,
      'rendered_note': '',
      'char_count': 0,
    };

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
  });

  tearDown(() {
    WaTemplateApi.rpcTransport = null;
    WaTemplateApi.signerTransport = null;
  });

  testWidgets('an approved image renders in the bubble, above body_rendered',
      (tester) async {
    await _pump(
      tester,
      _previewWith(
        _imageHeader(mediaUrl: 'https://cdn.example/promo.jpg'),
        bodyRendered: 'Hi Chandra Medicom, your order shipped',
        bodyRaw: 'Hi {{1}}, your order shipped',
      ),
    );

    // The picture is inside the bubble.
    expect(_bubbleImage(), findsOneWidget);
    // The rendered body is shown; the raw {{1}} body is not.
    expect(find.text('Hi Chandra Medicom, your order shipped'), findsOneWidget);
    expect(find.text('Hi {{1}}, your order shipped'), findsNothing);

    // The image sits ABOVE the body text.
    final imgTop = tester.getTopLeft(_bubbleImage()).dy;
    final bodyTop =
        tester.getTopLeft(find.text('Hi Chandra Medicom, your order shipped')).dy;
    expect(imgTop, lessThan(bodyTop));
  });

  testWidgets('a private sample is signed from the payload bucket and path',
      (tester) async {
    final signer = _install(_previewWith(_imageHeader(
      storageBucket: 'whatsapp-media',
      storagePath: 'whatsapp/tpl_1_sample.jpg',
    )));
    // _install was called directly to capture the log; pump installs its own,
    // so drive the pump manually with the same payload.
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: WaTemplateEditorScreen(screen: _screen(), template: _template()),
    ));
    await tester.pump();
    await tester
        .pump(WaTemplateEditorScreen.debounce + const Duration(milliseconds: 50));
    await tester.pump();

    expect(signer.calls, isNotEmpty);
    expect(signer.calls.first[0], 'whatsapp-media');
    expect(signer.calls.first[1], 'whatsapp/tpl_1_sample.jpg');
  });

  testWidgets('a PDF sample renders a file tile with its file_label',
      (tester) async {
    await _pump(
      tester,
      _previewWith({
        'format': 'DOCUMENT',
        'is_image': false,
        'is_pdf': true,
        'is_video': false,
        'media_url': '',
        'storage_bucket': 'whatsapp-media',
        'storage_path': 'whatsapp/tpl_1_invoice.pdf',
        'file_label': 'invoice_february.pdf',
        'size_label': '96 KB',
        'expires_label': '',
        'expired': false,
        'placeholder_label': '',
        'missing_label': '',
      }),
    );

    // The backend's file label is on screen; no image in the bubble.
    expect(find.text('invoice_february.pdf'), findsWidgets);
    expect(_bubbleImage(), findsNothing);
  });

  testWidgets('no sample yet shows the placeholder box and the warn line',
      (tester) async {
    await _pump(
      tester,
      _previewWith({
        'format': 'IMAGE',
        'is_image': false,
        'is_pdf': false,
        'is_video': false,
        'media_url': '',
        'storage_bucket': '',
        'storage_path': '',
        'file_label': '',
        'size_label': '',
        'expires_label': '',
        'expired': false,
        'placeholder_label': 'Picture at the top of the message',
        'missing_label': 'No sample uploaded yet — add one before submitting',
      }),
    );

    expect(find.text('Picture at the top of the message'), findsWidgets);
    expect(
        find.text('No sample uploaded yet — add one before submitting'),
        findsWidgets);
    // A placeholder is not a picture.
    expect(_bubbleImage(), findsNothing);
  });

  testWidgets('a null header draws no header area, body still shows',
      (tester) async {
    await _pump(
      tester,
      _previewWith(null, bodyRendered: 'Just a plain message'),
    );

    expect(_bubbleImage(), findsNothing);
    expect(find.text('Just a plain message'), findsOneWidget);
    // No placeholder box was drawn either.
    expect(find.textContaining('at the top of the message'), findsNothing);
  });

  testWidgets('the bubble reads body_rendered and never body_raw',
      (tester) async {
    await _pump(
      tester,
      _previewWith(
        null,
        bodyRendered: 'Amount due 4,500.00',
        bodyRaw: 'Amount due {{3}}',
      ),
    );

    expect(find.text('Amount due 4,500.00'), findsOneWidget);
    expect(find.text('Amount due {{3}}'), findsNothing);
  });

  testWidgets('an expired sample is shown in the bad tone', (tester) async {
    await _pump(
      tester,
      _previewWith(_imageHeader(
        mediaUrl: 'https://cdn.example/old.jpg',
        expired: true,
        expiresLabel: 'Sample expired — re-upload',
      )),
    );

    // It shows in the status line and beside the thumbnail — both in the bad
    // tone. (The header block now sources the sample from the status RPC.)
    final labels =
        tester.widgetList<Text>(find.text('Sample expired — re-upload'));
    expect(labels, isNotEmpty);
    expect(labels.every((t) => t.style?.color == WaTone.of('bad').fg), isTrue);
  });
}
