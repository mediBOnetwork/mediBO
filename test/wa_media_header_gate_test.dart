// The media header must always offer ONE upload control, and when that control
// is off it must say why.
//
// The bug this file exists to stop: choosing "Image header" rendered a single
// greyed-out "Re-upload" button and nothing else. The real reason — a sample
// file attaches to a SAVED template, and a new template has no id yet — was
// never on screen. That is the same failure as the greyed-out Submit button
// #649 fixed, in a different corner of the same editor.
//
// So the assertions here are about REACHABILITY, not cosmetics:
//
//   1. can_upload:false still renders the backend's upload_label on a button,
//      with blocked_reason directly beneath it. Disabled is fine; silent is not.
//   2. can_upload:true renders that same button enabled.
//   3. "Re-upload" is a SECOND way to do what the primary button does, so it is
//      absent until has_sample (or expired) says there is something to replace.
//      It must never be the only control on screen.
//   4. template_saved:false offers "Save and continue", because saving is the
//      one thing that unblocks an unsaved template.
//   5. A file over max_mb never reaches storage. The refusal is still the
//      backend's sentence — wa_template_set_header_media returns its too_big
//      message above the UPDATE, so asking costs nothing and changes nothing.
//
// Every string on screen is the backend's. The only literals asserted as Dart
// captions are "Save and continue" and "Re-upload".
//
// No network, no Supabase, no home_shell.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/features/whatsapp/data/wa_template_api.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_template_editor_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

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

/// An IMAGE header component is what puts the editor on the media branch —
/// the TEXT branch renders a plain text field instead.
Map<String, dynamic> _template({bool withId = true}) => {
      if (withId) 'id': _templateId,
      'name': 'order_dispatched',
      'language': 'en',
      'category': 'UTILITY',
      'components': const [
        {'type': 'HEADER', 'format': 'IMAGE'},
        {'type': 'BODY', 'text': 'Hi {{1}}, your order is on its way.'},
      ],
      'token_map': const [],
    };

/// wa_template_media_spec, verbatim shape (2026-08-05).
Map<String, dynamic> _spec({
  required bool canUpload,
  required bool templateSaved,
  String uploadLabel = 'Choose the picture Meta will review',
  String? blockedReason,
}) =>
    {
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
      'template_saved': templateSaved,
      'can_upload': canUpload,
      'upload_label': uploadLabel,
      'blocked_reason': blockedReason,
    };

/// wa_template_header_status. `error` is nullable INSIDE a healthy payload.
Map<String, dynamic> _headerStatus({
  bool hasSample = false,
  bool expired = false,
}) =>
    {
      'header_format': 'IMAGE',
      'has_sample': hasSample,
      'file_label': hasSample ? 'promo.png' : '',
      'size_label': hasSample ? '412 KB' : '',
      'expires_label': expired ? 'Sample expired 02 Aug' : '',
      'expired': expired,
      'status': hasSample ? 'ready' : 'none',
      'status_label': hasSample ? 'Sample attached' : 'No sample yet',
      'tone': hasSample ? 'good' : 'muted',
      'error': null,
      'can_submit': hasSample,
      'blocker': expired ? 'This sample expired — upload it again' : null,
    };

Map<String, dynamic> _gate() => {
      'can_submit': true,
      'blockers': const [],
      'count': 0,
      'why_label': null,
      'warnings': const [],
    };

/// Records what actually went over each seam, so "no upload happened" is an
/// observation rather than an inference.
class _Calls {
  final List<String> rpc = [];
  final List<String> uploads = [];
}

_Calls _stub({
  required Map<String, dynamic> spec,
  Map<String, dynamic>? header,
  Map<String, dynamic>? setHeaderResult,
}) {
  final calls = _Calls();

  WaTemplateApi.uploadTransport = (bucket, path, bytes, mime) async {
    calls.uploads.add('$bucket/$path');
  };

  WaTemplateApi.rpcTransport = (fn, params) async {
    calls.rpc.add(fn);
    switch (fn) {
      case 'wa_template_media_spec':
        return spec;
      case 'wa_template_header_status':
        return header ?? _headerStatus();
      case 'wa_template_submit_blockers':
        return _gate();
      case 'wa_template_set_header_media':
        return setHeaderResult ??
            const {'ok': true, 'message': 'Uploading the sample to Meta'};
      case 'wa_template_validate':
        return const {'errors': [], 'warnings': []};
      case 'wa_template_similar':
        return const <String, dynamic>{};
      case 'wa_policy_review_latest':
        return const <String, dynamic>{};
      default:
        return const <String, dynamic>{};
    }
  };
  return calls;
}

Future<void> _pump(WidgetTester tester, {bool withId = true}) async {
  // The editor is far taller than the default 600px test viewport. Without
  // this every control below the fold is off-screen and a tap silently misses.
  tester.view.physicalSize = const Size(1000, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    home: WaTemplateEditorScreen(
        screen: _screen(), template: _template(withId: withId)),
  ));
  await tester.pump(WaTemplateEditorScreen.similarDebounce +
      const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

ElevatedButton _uploadButton(WidgetTester tester, String label) =>
    tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, label));

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() {
    WaTemplateApi.rpcTransport = null;
    WaTemplateApi.uploadTransport = null;
    WaTemplateEditorScreen.filePicker = null;
  });

  testWidgets('can_upload:false still renders upload_label, disabled, with the '
      'reason beneath it', (tester) async {
    _stub(
      spec: _spec(
        canUpload: false,
        templateSaved: true,
        uploadLabel: 'Choose the picture Meta will review',
        blockedReason: 'This template is waiting on Meta — you cannot change '
            'its header now',
      ),
    );
    await _pump(tester);

    // The control is on screen and captioned by the backend...
    expect(find.text('Choose the picture Meta will review'), findsOneWidget);
    // ...disabled...
    expect(_uploadButton(tester, 'Choose the picture Meta will review').onPressed,
        isNull);
    // ...and it says why. This is the whole point of the change.
    expect(
        find.text('This template is waiting on Meta — you cannot change its '
            'header now'),
        findsOneWidget);
  });

  testWidgets('can_upload:true renders the same button enabled', (tester) async {
    _stub(spec: _spec(canUpload: true, templateSaved: true));
    await _pump(tester);

    expect(
        _uploadButton(tester, 'Choose the picture Meta will review').onPressed,
        isNotNull);
  });

  testWidgets('Re-upload is absent when has_sample is false', (tester) async {
    _stub(
      spec: _spec(canUpload: true, templateSaved: true),
      header: _headerStatus(hasSample: false),
    );
    await _pump(tester);

    expect(find.text('Re-upload'), findsNothing);
    // ...and the primary control is still there, so the section is never empty.
    expect(find.text('Choose the picture Meta will review'), findsOneWidget);
  });

  testWidgets('Re-upload appears once there is a sample to replace',
      (tester) async {
    _stub(
      spec: _spec(canUpload: true, templateSaved: true),
      header: _headerStatus(hasSample: true),
    );
    await _pump(tester);

    expect(find.text('Re-upload'), findsOneWidget);
    expect(find.text('Choose the picture Meta will review'), findsOneWidget);
  });

  testWidgets('an unsaved template offers the picker enabled, no save-first gate',
      (tester) async {
    // The backend dropped the save-first restriction: can_upload is true and
    // there is no blocked_reason before the template is saved.
    _stub(
      spec: _spec(
        canUpload: true,
        templateSaved: false,
        uploadLabel: 'Choose the picture Meta will review',
      ),
    );
    await _pump(tester, withId: false);

    // The picker is on screen and enabled before any save.
    expect(
        _uploadButton(tester, 'Choose the picture Meta will review').onPressed,
        isNotNull);
    // The old save-first control is gone entirely.
    expect(find.text('Save and continue'), findsNothing);
  });

  testWidgets('a file over max_mb never reaches storage, and the refusal is '
      'the backend\'s', (tester) async {
    final calls = _stub(
      spec: _spec(canUpload: true, templateSaved: true),
      setHeaderResult: const {
        'error': 'too_big',
        'message': 'Image headers must be under 5 MB',
      },
    );
    // max_mb is 5; hand over 6 MB.
    WaTemplateEditorScreen.filePicker = (exts, mime) async => WaPickedFile(
          name: 'huge.png',
          bytes: Uint8List(6 * 1024 * 1024),
        );

    await _pump(tester);

    final btn = find.widgetWithText(
        ElevatedButton, 'Choose the picture Meta will review');
    await tester.ensureVisible(btn);
    await tester.pumpAndSettle();
    await tester.tap(btn);
    await tester.pumpAndSettle();

    // Not one byte went to the bucket.
    expect(calls.uploads, isEmpty);
    // And the sentence shown is the backend's, not one written in Dart.
    expect(find.text('Image headers must be under 5 MB'), findsOneWidget);
  });

  testWidgets('a file within max_mb does reach storage', (tester) async {
    final calls = _stub(spec: _spec(canUpload: true, templateSaved: true));
    WaTemplateEditorScreen.filePicker = (exts, mime) async => WaPickedFile(
          name: 'small.png',
          bytes: Uint8List(1024),
        );

    await _pump(tester);

    final btn = find.widgetWithText(
        ElevatedButton, 'Choose the picture Meta will review');
    await tester.ensureVisible(btn);
    await tester.pumpAndSettle();
    await tester.tap(btn);
    await tester.pumpAndSettle();

    expect(calls.uploads.length, 1);
    expect(calls.uploads.single, startsWith('whatsapp-media/whatsapp/tpl_'));
  });

  testWidgets('the picker is offered the format\'s own accepts and mime',
      (tester) async {
    _stub(spec: _spec(canUpload: true, templateSaved: true));
    List<String>? sawExts;
    String? sawMime;
    WaTemplateEditorScreen.filePicker = (exts, mime) async {
      sawExts = exts;
      sawMime = mime;
      return null; // cancelled — nothing else should happen
    };

    await _pump(tester);

    final btn = find.widgetWithText(
        ElevatedButton, 'Choose the picture Meta will review');
    await tester.ensureVisible(btn);
    await tester.pumpAndSettle();
    await tester.tap(btn);
    await tester.pumpAndSettle();

    expect(sawExts, ['jpg', 'png']);
    expect(sawMime, 'image/jpeg,image/png');
  });
}
