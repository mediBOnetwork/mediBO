// The uploaded picture shows in the header block and in the preview BEFORE the
// template is saved.
//
// What this holds down (all display; nothing changes what is saved):
//
//   1. A ready detached-upload job with is_image signs storage_bucket +
//      storage_path and renders a thumbnail inside the header block.
//   2. A PDF job renders a file tile, not an image.
//   3. The editor previews through wa_preview_draft whether or not the template
//      is saved — the saved-row preview (wa_template_preview by p_template_id)
//      is never asked, so an edit shows at once instead of only after a save.
//   4. The delivered bubble renders the signed draft image above body_rendered.
//   5. A draft header with missing_label and no file renders the placeholder box.
//
// Every RPC and the storage signer are mocked inline. No network, no Supabase,
// no home_shell.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/features/whatsapp/data/wa_template_api.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_template_editor_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

const _savedId = 'c1d2e3f4-0000-0000-0000-0000000abcde';

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
        'saved': 'Template saved',
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

/// A template on the media branch. Without an id it is UNSAVED.
Map<String, dynamic> _template({bool withId = false}) => {
      if (withId) 'id': _savedId,
      'name': 'order_dispatched',
      'language': 'en',
      'category': 'UTILITY',
      'components': const [
        {'type': 'HEADER', 'format': 'IMAGE'},
        {'type': 'BODY', 'text': 'Hi there, your order is on its way.'},
      ],
      'token_map': const [],
    };

Map<String, dynamic> _spec() => {
      'formats': const [
        {'value': 'TEXT', 'label': 'Text header', 'needs_sample': false},
        {
          'value': 'IMAGE',
          'label': 'Image header',
          'accepts': 'jpg, png',
          'mime': 'image/jpeg,image/png',
          'max_mb': 5,
          'needs_sample': true,
        },
      ],
      'rules': const ['One header per template, and only one media header.'],
      'template_saved': false,
      'can_upload': true,
      'needs_save_first': false,
      'upload_label': 'Choose the picture Meta will review',
      'blocked_reason': null,
    };

// ── harness ─────────────────────────────────────────────────────────────────

class _Calls {
  final List<String> rpc = [];
  final List<Map<String, dynamic>> params = [];
  final List<List<String>> signs = [];

  bool called(String fn) => rpc.contains(fn);

  bool calledWithParam(String fn, String key) {
    for (var i = 0; i < rpc.length; i++) {
      if (rpc[i] == fn && params[i][key] != null) return true;
    }
    return false;
  }
}

_Calls _install({
  Map<String, dynamic>? draft,
  Map<String, dynamic>? jobStatus,
  String signedUrl = 'https://signed.example/sample?token=abc',
}) {
  final calls = _Calls();

  WaTemplateApi.uploadTransport = (bucket, path, bytes, mime) async {};

  WaTemplateApi.signerTransport = (bucket, path, expiresIn) async {
    calls.signs.add([bucket, path]);
    return signedUrl;
  };

  WaTemplateApi.rpcTransport = (fn, p) async {
    calls.rpc.add(fn);
    calls.params.add(p);
    switch (fn) {
      case 'wa_template_media_spec':
        return _spec();
      case 'wa_template_validate':
        return const {'ok': true, 'errors': [], 'warnings': []};
      case 'wa_preview_draft':
        return draft ??
            const {
              'header': null,
              'body_raw': 'Hi {{1}}',
              'body_rendered': 'Hi there, your order is on its way.',
              'footer': '',
              'buttons': [],
              'char_count': 0,
              'rendered_note': '',
            };
      case 'wa_template_preview':
        // The saved-row preview (p_template_id) vs the live components preview
        // (p_components) share this name; only the first is the saved path.
        return const {
          'header': null,
          'body': 'saved-body',
          'body_rendered': 'saved-body',
          'body_raw': 'x',
          'footer': '',
          'buttons': [],
        };
      case 'wa_media_upload_detached':
        return const {
          'ok': true,
          'job_id': 'job-1',
          'format': 'IMAGE',
          'message': 'Uploading the sample to Meta',
        };
      case 'wa_media_job_status':
        return jobStatus ?? const {'status': 'pending', 'ready': false};
      case 'wa_template_header_status':
        return const <String, dynamic>{};
      case 'wa_tokens_screen':
        return const {'rows': [], 'search': null, 'empty_copy': 'No values'};
      case 'wa_body_renumber':
        return {'body': p['p_body'], 'token_map': p['p_token_map'], 'changed': false};
      default:
        return const <String, dynamic>{};
    }
  };
  return calls;
}

final _navKey = GlobalKey<NavigatorState>();

Future<void> _pump(WidgetTester tester, {bool withId = false}) async {
  tester.view.physicalSize = const Size(1000, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    navigatorKey: _navKey,
    home: const Scaffold(body: Center(child: Text('HOME'))),
  ));
  _navKey.currentState!.push(MaterialPageRoute(
    builder: (_) => WaTemplateEditorScreen(
        screen: _screen(), template: _template(withId: withId)),
  ));
  await tester.pump();
  await tester
      .pump(WaTemplateEditorScreen.debounce + const Duration(milliseconds: 60));
  await tester.pumpAndSettle();
}

Finder _uploadBtn() => find.widgetWithText(
    ElevatedButton, 'Choose the picture Meta will review');

Future<void> _pick(WidgetTester tester) async {
  WaTemplateEditorScreen.filePicker = (exts, mime) async =>
      WaPickedFile(name: 'promo.jpg', bytes: Uint8List(1024));
  await tester.ensureVisible(_uploadBtn());
  await tester.pumpAndSettle();
  await tester.tap(_uploadBtn());
  await tester.pumpAndSettle();
}

Finder _bubbleImage() => find.descendant(
      of: find.byKey(const Key('wa_preview_bubble')),
      matching: find.byType(Image),
    );

Map<String, dynamic> _imageJob() => const {
      'status': 'ready',
      'ready': true,
      'format': 'IMAGE',
      'mime': 'image/jpeg',
      'is_image': true,
      'is_pdf': false,
      'is_video': false,
      'storage_bucket': 'whatsapp-media',
      'storage_path': 'whatsapp/tpl_new_ready.jpg',
      'file_label': 'promo.jpg',
      'size_label': '210 KB',
      'expires_label': 'Sample expires 09 Aug',
      'status_label': 'Sample accepted by Meta',
      'tone': 'good',
      'error': null,
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() {
    WaTemplateApi.rpcTransport = null;
    WaTemplateApi.signerTransport = null;
    WaTemplateApi.uploadTransport = null;
    WaTemplateEditorScreen.filePicker = null;
  });

  testWidgets('a ready image job signs its path and shows a thumbnail in the '
      'header block', (tester) async {
    // Bubble header is null so the only image on screen is the header block's.
    final calls = _install(jobStatus: _imageJob());
    await _pump(tester);
    await _pick(tester);

    // Signed the job's own bucket and path.
    expect(
        calls.signs.any((c) =>
            c[0] == 'whatsapp-media' && c[1] == 'whatsapp/tpl_new_ready.jpg'),
        isTrue);
    // A thumbnail is on screen, and it is NOT in the bubble (header is null).
    expect(find.byType(Image), findsWidgets);
    expect(_bubbleImage(), findsNothing);
  });

  testWidgets('a ready PDF job shows a file tile, not an image', (tester) async {
    final job = Map<String, dynamic>.from(_imageJob());
    job['is_image'] = false;
    job['is_pdf'] = true;
    job['format'] = 'DOCUMENT';
    job['storage_path'] = 'whatsapp/tpl_new_ready.pdf';
    job['file_label'] = 'invoice_feb.pdf';
    _install(jobStatus: job);
    await _pump(tester);
    await _pick(tester);

    expect(find.text('invoice_feb.pdf'), findsWidgets);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('no id previews through wa_preview_draft, not the saved-row RPC',
      (tester) async {
    final calls = _install();
    await _pump(tester);

    expect(calls.called('wa_preview_draft'), isTrue);
    // The saved-row preview (by p_template_id) is never asked for a draft.
    expect(calls.calledWithParam('wa_template_preview', 'p_template_id'), isFalse);
  });

  testWidgets('a saved template previews through wa_preview_draft too, never '
      'the saved-row RPC', (tester) async {
    final calls = _install();
    await _pump(tester, withId: true);

    // The bubble follows the live editor state even for a saved row, so the
    // saved-row preview (by p_template_id) is never asked.
    expect(calls.called('wa_preview_draft'), isTrue);
    expect(calls.calledWithParam('wa_template_preview', 'p_template_id'), isFalse);
  });

  testWidgets('the delivered bubble renders the draft image above body_rendered',
      (tester) async {
    _install(draft: const {
      'header': {
        'format': 'IMAGE',
        'is_image': true,
        'is_pdf': false,
        'is_video': false,
        'media_url': 'https://cdn.example/promo.jpg',
        'storage_bucket': '',
        'storage_path': '',
        'file_label': 'promo.jpg',
        'size_label': '210 KB',
        'placeholder_label': '',
        'missing_label': '',
      },
      'body_raw': 'Hi {{1}}, your order shipped',
      'body_rendered': 'Hi Chandra Medicom, your order shipped',
      'footer': '',
      'buttons': [],
      'char_count': 0,
      'rendered_note': '',
    });
    await _pump(tester);

    expect(_bubbleImage(), findsOneWidget);
    expect(find.text('Hi Chandra Medicom, your order shipped'), findsOneWidget);
    final imgTop = tester.getTopLeft(_bubbleImage()).dy;
    final bodyTop = tester
        .getTopLeft(find.text('Hi Chandra Medicom, your order shipped'))
        .dy;
    expect(imgTop, lessThan(bodyTop));
  });

  testWidgets('a draft header with missing_label and no file renders the '
      'placeholder box', (tester) async {
    _install(draft: const {
      'header': {
        'format': 'IMAGE',
        'is_image': false,
        'is_pdf': false,
        'is_video': false,
        'media_url': '',
        'storage_bucket': '',
        'storage_path': '',
        'file_label': '',
        'size_label': '',
        'placeholder_label': 'Picture at the top of the message',
        'missing_label': 'No sample uploaded yet — add one before submitting',
      },
      'body_raw': 'Hi {{1}}',
      'body_rendered': 'Hi there',
      'footer': '',
      'buttons': [],
      'char_count': 0,
      'rendered_note': '',
    });
    await _pump(tester);

    expect(find.text('Picture at the top of the message'), findsWidgets);
    expect(find.text('No sample uploaded yet — add one before submitting'),
        findsWidgets);
    expect(_bubbleImage(), findsNothing);
  });
}
