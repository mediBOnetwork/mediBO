// The preview bubble follows every edit, not only the saved template.
//
// The editor drives the bubble from wa_preview_draft — built from the LIVE
// editor state — on a short debounce. wa_template_preview (the saved row) is
// never called from here, so typing, adding a button, or changing the footer
// shows at once instead of only after a Save-and-reopen.
//
// What this holds down (all display; nothing changes what is saved):
//
//   1. Typing in the body fires wa_preview_draft after the debounce, and the
//      bubble paints the returned body_segments.
//   2. Adding a button fires it again, and the returned buttons render.
//   3. The editor never calls wa_template_preview.
//   4. A rapid second edit wins: a slow earlier response is dropped, never
//      painted over the newer render.
//   5. An error response leaves the previous bubble intact and shows `message`.
//
// Every RPC is mocked inline. No network, no Supabase, no home_shell.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/features/whatsapp/data/wa_template_api.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_template_editor_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ──────────────────────────────────────────────────────────────────

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
      'button_spec': const {
        'types': [
          {'key': 'QUICK_REPLY', 'label': 'Quick reply', 'max': 3},
        ],
        'total_max': 10,
        'text_max': 25,
      },
    };

Map<String, dynamic> _spec() => {
      'formats': const [
        {'value': 'TEXT', 'label': 'Text header', 'needs_sample': false},
      ],
      'rules': const [],
      'template_saved': false,
      'can_upload': true,
      'upload_label': 'Choose a file',
      'blocked_reason': null,
    };

/// A wa_preview_draft payload in the same shape wa_template_preview returned:
/// styled body_segments plus the fields the bubble reads. [seg] is painted
/// through the segment path (#660), so a test proves the SEGMENTS rendered, not
/// a locally-substituted copy.
Map<String, dynamic> _draft(String seg, {List<dynamic> buttons = const []}) => {
      'header': null,
      'body_raw': 'x',
      'body_rendered': seg,
      'body_plain': '',
      'body_segments': [
        {'text': seg, 'bold': false},
      ],
      'footer': '',
      'footer_segments': const [],
      'buttons': buttons,
      'char_count': 0,
      'rendered_note': '',
    };

/// The BODY text out of the components the editor sent — what the mock keys its
/// answer off, so behaviour follows the edit rather than a fragile call count.
String _bodyOf(Map<String, dynamic> params) {
  for (final c in (params['p_components'] as List?) ?? const []) {
    if (c is Map && (c['type'] ?? '') == 'BODY') return (c['text'] ?? '').toString();
  }
  return '';
}

// ── harness ───────────────────────────────────────────────────────────────────

class _Calls {
  final List<String> rpc = [];
  final List<Map<String, dynamic>> params = [];
  bool called(String fn) => rpc.contains(fn);
  int count(String fn) => rpc.where((f) => f == fn).length;
}

/// Installs a transport whose wa_preview_draft answer comes from [onDraft], so a
/// test controls both the payload and — via a delay inside it — its timing.
_Calls _install(
    Future<Map<String, dynamic>> Function(Map<String, dynamic> params) onDraft) {
  final calls = _Calls();
  WaTemplateApi.rpcTransport = (fn, p) async {
    calls.rpc.add(fn);
    calls.params.add(p);
    switch (fn) {
      case 'wa_template_validate':
        return const {'ok': true, 'errors': [], 'warnings': []};
      case 'wa_preview_draft':
        return await onDraft(p);
      case 'wa_template_media_spec':
        return _spec();
      case 'wa_tokens_screen':
        return const {'rows': [], 'search': null, 'empty_copy': 'No values'};
      case 'wa_body_renumber':
        return {
          'body': p['p_body'],
          'token_map': p['p_token_map'],
          'changed': false,
        };
      default:
        return const <String, dynamic>{};
    }
  };
  return calls;
}

Future<void> _pump(WidgetTester tester) async {
  // Wide viewport: the editor lays the preview beside the form at >=900px, and
  // tall enough that the bubble is not clipped. The editor is still taller than
  // the viewport, so each assertion scrolls the bubble in first.
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    home: WaTemplateEditorScreen(screen: _screen()),
  ));
  await tester
      .pump(WaTemplateEditorScreen.previewDebounce + const Duration(milliseconds: 60));
  await tester.pumpAndSettle();
}

/// Waits out both the preview debounce (350 ms) and the lint debounce (400 ms).
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 420));
  await tester.pumpAndSettle();
}

Finder _bodyField() =>
    find.byWidgetPredicate((w) => w is TextField && w.maxLines == 6);

Finder _bubble() => find.byKey(const Key('wa_preview_bubble'));

/// The bubble paints body_segments through Text.rich, so the assertion reads the
/// RichText's plain text (findRichText) rather than a Text `data`.
Finder _segment(String text) => find.textContaining(text, findRichText: true);

Future<void> _showBubble(WidgetTester tester) async {
  await tester.ensureVisible(_bubble());
  await tester.pump();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => WaTemplateApi.rpcTransport = null);

  testWidgets('typing in the body fires wa_preview_draft and the bubble shows '
      'the returned body_segments', (tester) async {
    final calls = _install((p) async {
      final body = _bodyOf(p);
      return _draft(body.isEmpty ? 'OPEN' : 'SEG:$body');
    });
    await _pump(tester);

    await tester.enterText(_bodyField(), 'Hello there');
    await _settle(tester);
    await _showBubble(tester);

    expect(calls.called('wa_preview_draft'), isTrue);
    // Never the saved-row RPC.
    expect(calls.called('wa_template_preview'), isFalse);
    // The SEGMENTS painted — proof the bubble came from the draft preview.
    expect(_segment('SEG:Hello there'), findsWidgets);
  });

  testWidgets('adding a button fires the preview again and the returned buttons '
      'render', (tester) async {
    var withButton = false;
    final calls = _install((p) async => _draft(
          'BODY',
          buttons: withButton
              ? const [
                  {'text': 'Track order', 'kind_label': 'Quick reply'},
                ]
              : const [],
        ));
    await _pump(tester);

    expect(find.text('Track order'), findsNothing);
    final before = calls.count('wa_preview_draft');

    // The next draft answer carries a button; adding one triggers that refresh.
    withButton = true;
    final add = find.widgetWithText(OutlinedButton, 'Quick reply');
    await tester.ensureVisible(add);
    await tester.tap(add);
    await _settle(tester);
    await _showBubble(tester);

    expect(calls.count('wa_preview_draft'), greaterThan(before));
    expect(find.text('Track order'), findsWidgets);
    expect(calls.called('wa_template_preview'), isFalse);
  });

  testWidgets('a rapid second edit wins — the slow earlier response is dropped',
      (tester) async {
    final calls = _install((p) async {
      final body = _bodyOf(p);
      if (body.contains('SECOND')) return _draft('NEW-RENDER');
      if (body.contains('FIRST')) {
        // The earlier response arrives late, after the newer one has painted.
        await Future.delayed(const Duration(seconds: 2));
        return _draft('OLD-RENDER');
      }
      return _draft('OPEN');
    });
    await _pump(tester);

    // Edit 1 fires; its response is still in flight (delayed 2 s).
    await tester.enterText(_bodyField(), 'FIRST');
    await tester.pump(const Duration(milliseconds: 420));

    // Edit 2 fires and answers immediately — the newer render.
    await tester.enterText(_bodyField(), 'FIRST SECOND');
    await tester.pump(const Duration(milliseconds: 420));
    await _showBubble(tester);
    expect(_segment('NEW-RENDER'), findsWidgets);

    // Edit 1 finally returns — stale ticket, so it must be dropped.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(_segment('OLD-RENDER'), findsNothing);
    expect(_segment('NEW-RENDER'), findsWidgets);
    expect(calls.called('wa_template_preview'), isFalse);
  });

  testWidgets('an error response leaves the previous bubble intact and shows '
      'message', (tester) async {
    _install((p) async {
      final body = _bodyOf(p);
      if (body.contains('ERR')) {
        return const {'error': 'invalid', 'message': 'Preview unavailable right now'};
      }
      return _draft('GOOD-RENDER');
    });
    await _pump(tester);
    await _showBubble(tester);
    expect(_segment('GOOD-RENDER'), findsWidgets);

    await tester.enterText(_bodyField(), 'ERR');
    await _settle(tester);
    await _showBubble(tester);

    // The good bubble is untouched, and the backend's own sentence sits beneath.
    expect(_segment('GOOD-RENDER'), findsWidgets);
    expect(find.text('Preview unavailable right now'), findsOneWidget);
  });
}
