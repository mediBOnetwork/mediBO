// The sample file can be chosen BEFORE the template is ever saved.
//
// The old flow greyed the picker out with "Save this template once before
// adding a picture or file" and offered a "Save and continue" button. The
// backend dropped that restriction: Meta's upload holds the handle on a
// detached job, and the first save claims it. So:
//
//   1. A new (unsaved) template with an Image header offers the picker ENABLED
//      and shows no save-first text.
//   2. Picking a file with no template id calls wa_media_upload_detached (not
//      set_header_media) and keeps the returned job_id — proven by the job
//      being polled with that id.
//   3. The job status is polled and its status_label renders.
//   4. The next save passes that job_id as p_media_job.
//   5. A template that already has an id still uses wa_template_set_header_media.
//   6. A 'media_not_ready' save shows the backend's message and KEEPS the job
//      id, so a second save still carries it.
//
// Every RPC and the storage upload are mocked inline. No network, no Supabase,
// no home_shell.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/features/whatsapp/data/wa_template_api.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_template_editor_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

const _savedId = 'a1b2c3d4-0000-0000-0000-00000000abcd';
const _jobId = 'job-9f3a';

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
        {'key': 'UTILITY', 'label': 'Utility'},
      ],
      'languages': const [
        {'key': 'en', 'label': 'English'},
      ],
      'button_spec': const {'types': [], 'total_max': 10, 'text_max': 25},
    };

/// A template on the media branch. Without an id it is UNSAVED — exactly the
/// case that used to be blocked.
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

/// wa_template_media_spec — the NEW shape: can_upload true and no blocked_reason
/// even before the template is saved.
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

Map<String, dynamic> _jobStatus() => {
      'status': 'ready',
      'ready': true,
      'format': 'IMAGE',
      'file_label': 'promo.png',
      'size_label': '210 KB',
      'expires_label': 'Sample expires 08 Aug',
      'status_label': 'Sample ready — attaching on save',
      'tone': 'good',
      'error': null,
    };

/// Records what crossed each seam so a test observes behaviour rather than
/// inferring it.
class _Calls {
  final List<String> rpc = [];
  final List<Map<String, dynamic>> params = [];
  final List<String> uploads = [];

  Map<String, dynamic>? last(String fn) {
    for (var i = rpc.length - 1; i >= 0; i--) {
      if (rpc[i] == fn) return params[i];
    }
    return null;
  }

  bool called(String fn) => rpc.contains(fn);
}

_Calls _stub({
  Map<String, dynamic> detachedResult = const {
    'ok': true,
    'job_id': _jobId,
    'format': 'IMAGE',
    'message': 'Uploading the sample to Meta',
  },
  Map<String, dynamic> saveResult = const {
    'ok': true,
    'template': {'id': _savedId, 'name': 'order_dispatched'},
  },
}) {
  final calls = _Calls();

  WaTemplateApi.uploadTransport = (bucket, path, bytes, mime) async {
    calls.uploads.add('$bucket/$path');
  };

  WaTemplateApi.rpcTransport = (fn, p) async {
    calls.rpc.add(fn);
    calls.params.add(p);
    switch (fn) {
      case 'wa_template_media_spec':
        return _spec();
      case 'wa_media_upload_detached':
        return detachedResult;
      case 'wa_media_job_status':
        return _jobStatus();
      case 'wa_template_set_header_media':
        return const {'ok': true, 'message': 'Uploading the sample to Meta'};
      case 'wa_template_save':
        return saveResult;
      case 'wa_template_validate':
        return const {'errors': [], 'warnings': []};
      case 'wa_template_preview':
        return const {
          'header': null,
          'body': 'Hi there, your order is on its way.',
          'body_raw': '',
          'footer': '',
          'buttons': [],
        };
      case 'wa_body_renumber':
        return const {'changed': false};
      case 'wa_tokens_screen':
        return const {'rows': [], 'empty_copy': 'No values'};
      default:
        return const <String, dynamic>{};
    }
  };
  return calls;
}

final _navKey = GlobalKey<NavigatorState>();

Future<void> _pump(WidgetTester tester, {bool withId = false}) async {
  tester.view.physicalSize = const Size(1000, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // Push the editor above a placeholder so a save that pops returns cleanly.
  await tester.pumpWidget(MaterialApp(
    navigatorKey: _navKey,
    home: const Scaffold(body: Center(child: Text('HOME'))),
  ));
  _navKey.currentState!.push(MaterialPageRoute(
    builder: (_) => WaTemplateEditorScreen(
        screen: _screen(), template: _template(withId: withId)),
  ));
  await tester.pump();
  await tester.pump(WaTemplateEditorScreen.similarDebounce +
      const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

Finder _uploadBtn() => find.widgetWithText(
    ElevatedButton, 'Choose the picture Meta will review');

Future<void> _pick(WidgetTester tester) async {
  WaTemplateEditorScreen.filePicker = (exts, mime) async =>
      WaPickedFile(name: 'promo.png', bytes: Uint8List(1024));
  await tester.ensureVisible(_uploadBtn());
  await tester.pumpAndSettle();
  await tester.tap(_uploadBtn());
  await tester.pumpAndSettle();
}

/// Flush the toast's fade + dismissal timer so no timer outlives the test.
Future<void> _flushToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() {
    WaTemplateApi.rpcTransport = null;
    WaTemplateApi.uploadTransport = null;
    WaTemplateEditorScreen.filePicker = null;
  });

  testWidgets('unsaved template: picker is enabled and no save-first text',
      (tester) async {
    _stub();
    await _pump(tester);

    await tester.ensureVisible(_uploadBtn());
    await tester.pumpAndSettle();
    expect(tester.widget<ElevatedButton>(_uploadBtn()).onPressed, isNotNull);
    expect(find.text('Save and continue'), findsNothing);
    expect(find.textContaining('Save this template once'), findsNothing);
  });

  testWidgets('picking a file with no id calls wa_media_upload_detached and '
      'keeps the job id', (tester) async {
    final calls = _stub();
    await _pump(tester);
    await _pick(tester);

    // Detached upload, not the attached RPC.
    expect(calls.called('wa_media_upload_detached'), isTrue);
    expect(calls.called('wa_template_set_header_media'), isFalse);
    // Uploaded to the detached path.
    expect(calls.uploads.single,
        startsWith('whatsapp-media/whatsapp/tpl_new_'));
    // The job id is kept — the poll asked about exactly it.
    expect(calls.last('wa_media_job_status')?['p_job_id'], _jobId);
  });

  testWidgets('the job status is polled and its status_label renders',
      (tester) async {
    _stub();
    await _pump(tester);
    await _pick(tester);

    expect(find.text('Sample ready — attaching on save'), findsWidgets);
  });

  testWidgets('the next save passes the job id as p_media_job', (tester) async {
    final calls = _stub();
    await _pump(tester);
    await _pick(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Save'));
    await tester.pumpAndSettle();

    expect(calls.last('wa_template_save')?['p_media_job'], _jobId);
    await _flushToast(tester);
  });

  testWidgets('an existing template uses wa_template_set_header_media instead',
      (tester) async {
    final calls = _stub();
    await _pump(tester, withId: true);
    await _pick(tester);

    expect(calls.called('wa_template_set_header_media'), isTrue);
    expect(calls.called('wa_media_upload_detached'), isFalse);
    expect(calls.uploads.single,
        startsWith('whatsapp-media/whatsapp/tpl_$_savedId' '_'));
  });

  testWidgets('media_not_ready shows the message and keeps the job id',
      (tester) async {
    final calls = _stub(saveResult: const {
      'ok': false,
      'error': 'media_not_ready',
      'message': 'The sample is still uploading to Meta — try again in a moment',
    });
    await _pump(tester);
    await _pick(tester);

    // First save: refused, message shown.
    await tester.tap(find.widgetWithText(OutlinedButton, 'Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
        find.text(
            'The sample is still uploading to Meta — try again in a moment'),
        findsOneWidget);
    await _flushToast(tester);

    // The job id was NOT cleared — a second save still carries it.
    await tester.tap(find.widgetWithText(OutlinedButton, 'Save'));
    await tester.pumpAndSettle();
    expect(calls.last('wa_template_save')?['p_media_job'], _jobId);
    await _flushToast(tester);
  });
}
