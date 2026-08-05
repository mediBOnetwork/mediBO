import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/features/whatsapp/data/wa_template_api.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_template_editor_screen.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_token_picker.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// Two things this holds down.
///
/// A. The AI can now invent a value AND write the lookup behind it. Accepting it
/// must send the JOB id to wa_token_apply_proposal (which re-reads the proposal
/// and writes the lookup) and then insert the returned key exactly like a normal
/// chip — i.e. through the editor's wa_body_insert_token. A refusal creates
/// nothing and inserts nothing. A fresh lookup shows its sample.
///
/// B. WhatsApp renders *bold*, _italic_ and ~strike~; the customer never sees a
/// literal asterisk. The bubble paints the backend's already-split
/// body_segments, falling back to body_plain — never parsing markup in Dart.
///
/// Every RPC is mocked inline: no network, no Supabase, no home_shell import.

// ── fixtures ─────────────────────────────────────────────────────────────────

Map<String, dynamic> tokensPayload({List<dynamic>? rows, String? search}) => {
      'rows': rows ?? const [],
      'search': search,
      'sample_from': 'Examples are from your latest real order',
      'empty_copy': 'No values yet',
      'formats': const ['plain'],
      'source_kinds': const [
        {'value': 'delivery', 'label': 'Delivery'},
      ],
    };

Map<String, dynamic> screenPayload() => {
      'copy': {
        'editor_new_title': 'New template',
        'tokens_title': 'Insert a value',
        'examples_title': 'Example values',
        'body_label': 'Body',
        'header_label': 'Header',
        'footer_label': 'Footer',
        'name_label': 'Name',
        'language_label': 'Language',
        'category_label': 'Category',
        'buttons_title': 'Buttons',
        'preview_title': 'Preview',
        'save': 'Save',
        'submit': 'Submit',
        'saved': 'Saved',
        'generic_error': 'Something went wrong',
      },
      'starters': const [],
      'categories': const [
        {'key': 'MARKETING', 'label': 'Marketing'}
      ],
      'languages': const [
        {'key': 'en', 'label': 'English'}
      ],
      'button_spec': const {'types': [], 'total_max': 0},
    };

/// The proposal the AI comes back with — a brand-new value with a new lookup.
Map<String, dynamic> proposalResult() => {
      'status': 'done',
      'status_label': 'Done',
      'result': {
        'matches': const [],
        'proposal': {
          'key': 'delivery_person_name',
          'label': 'Delivery person',
          'group_label': 'Delivery',
          'source_kind': 'delivery',
          'source_ref': 'rider_name',
          'is_new_lookup': true,
          'why': 'The rider on this order',
        },
        'note': 'No existing value matches',
      },
    };

/// Records every RPC and answers from [handlers].
class MockRpc {
  final List<MapEntry<String, Map<String, dynamic>>> calls = [];
  final Map<String, dynamic Function(Map<String, dynamic>)> handlers;
  MockRpc(this.handlers);

  Future<dynamic> call(String fn, Map<String, dynamic> params) async {
    calls.add(MapEntry(fn, params));
    final h = handlers[fn];
    if (h != null) return h(params);
    return <String, dynamic>{};
  }

  Map<String, dynamic>? paramsFor(String fn) {
    for (final c in calls.reversed) {
      if (c.key == fn) return c.value;
    }
    return null;
  }

  int countOf(String fn) => calls.where((c) => c.key == fn).length;
}

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    WaTokenPicker.searchDebounce = Duration.zero;
    WaTokenPicker.pollInterval = Duration.zero;
    WaTemplateEditorScreen.debounce = Duration.zero;
    WaTemplateEditorScreen.similarDebounce = Duration.zero;
    WaTemplateEditorScreen.renumberDebounce = Duration.zero;
  });

  tearDown(() => WaTemplateApi.rpcTransport = null);

  /// The editor with a tall viewport, so the value picker and its AI panel sit
  /// on the (scrollable) canvas rather than off the bottom. onInsert is the real
  /// editor path — it routes a key through wa_body_insert_token, which is what
  /// "insert exactly like a normal chip" means.
  Future<MockRpc> pumpEditor(WidgetTester tester,
      {Map<String, dynamic Function(Map<String, dynamic>)>? extra}) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final mock = MockRpc({
      'wa_tokens_screen': (p) =>
          p['p_search'] == null ? tokensPayload() : tokensPayload(rows: const []),
      'wa_template_validate': (_) => {'ok': true, 'errors': [], 'warnings': []},
      'wa_template_preview': (_) => {'body': 'preview', 'buttons': []},
      'wa_preview_draft': (_) => <String, dynamic>{},
      // Mirrors wa_body_insert_token: {{n}} at the caret, backend-owned map.
      'wa_body_insert_token': (p) {
        final body = (p['p_body'] ?? '').toString();
        final cursor = (p['p_cursor'] as num?)?.toInt() ?? body.length;
        final map = [
          for (final k in (p['p_token_map'] as List?) ?? const []) k.toString()
        ];
        final key = (p['p_key'] ?? '').toString();
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
      },
      'wa_body_renumber': (p) => {
            'body': p['p_body'],
            'token_map': p['p_token_map'],
            'changed': false,
          },
      ...?extra,
    });
    WaTemplateApi.rpcTransport = mock.call;

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    final ctx = tester.element(find.byType(SizedBox));
    Navigator.of(ctx).push(MaterialPageRoute(
      builder: (_) => WaTemplateEditorScreen(screen: screenPayload()),
    ));
    await tester.pumpAndSettle();
    return mock;
  }

  /// Drives the picker to a rendered proposal card, ready for the Create tap.
  Future<void> reachProposal(WidgetTester tester) async {
    final search = find
        .descendant(
            of: find.byType(WaTokenPicker), matching: find.byType(TextField))
        .first;
    await tester.ensureVisible(search);
    await tester.enterText(search, 'delivery person');
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Ask AI to find it'));
    await tester.tap(find.text('Ask AI to find it'));
    await tester.pumpAndSettle();
  }

  // ── A: accepting the proposal ────────────────────────────────────────────────

  testWidgets(
      'Create and insert calls wa_token_apply_proposal with the job id, '
      'then wa_body_insert_token with the returned key', (tester) async {
    final mock = await pumpEditor(tester, extra: {
      'wa_token_ai_search': (_) => {'ok': true, 'job_id': 'job-77'},
      'wa_token_search_result': (_) => proposalResult(),
      'wa_token_apply_proposal': (_) => {
            'ok': true,
            'key': 'delivery_person_name',
            'insert_as': '{{delivery_person_name}}',
            'sample': 'Ravi',
            'created_lookup': true,
            'message': 'Created and inserted',
          },
    });

    await reachProposal(tester);
    await tester.ensureVisible(find.text('Create and insert'));
    await tester.tap(find.text('Create and insert'));
    await tester.pumpAndSettle();

    // The JOB id is what is sent — never the proposal fields.
    expect(mock.paramsFor('wa_token_apply_proposal')!['p_job_id'], 'job-77');
    // Then the value is inserted exactly like a chip: through the editor's
    // wa_body_insert_token, keyed by the value the backend returned.
    expect(mock.paramsFor('wa_body_insert_token')!['p_key'],
        'delivery_person_name');
    // The old create-and-insert path (wa_token_save) is gone.
    expect(mock.countOf('wa_token_save'), 0);
  });

  testWidgets('an error response shows message and inserts nothing',
      (tester) async {
    final mock = await pumpEditor(tester, extra: {
      'wa_token_ai_search': (_) => {'ok': true, 'job_id': 'job-77'},
      'wa_token_search_result': (_) => proposalResult(),
      'wa_token_apply_proposal': (_) =>
          {'error': 'bad_lookup', 'message': 'That query does not run'},
    });

    await reachProposal(tester);
    await tester.ensureVisible(find.text('Create and insert'));
    await tester.tap(find.text('Create and insert'));
    await tester.pumpAndSettle();

    expect(find.text('That query does not run'), findsOneWidget);
    // Nothing was created, nothing was inserted.
    expect(mock.countOf('wa_body_insert_token'), 0);
    expect(mock.countOf('wa_token_save'), 0);
  });

  testWidgets('created_lookup true renders the sample it returned',
      (tester) async {
    await pumpEditor(tester, extra: {
      'wa_token_ai_search': (_) => {'ok': true, 'job_id': 'job-77'},
      'wa_token_search_result': (_) => proposalResult(),
      'wa_token_apply_proposal': (_) => {
            'ok': true,
            'key': 'delivery_person_name',
            'sample': 'Ravi (from order #123)',
            'created_lookup': true,
            'message': 'Created and inserted',
          },
    });

    await reachProposal(tester);
    await tester.ensureVisible(find.text('Create and insert'));
    await tester.tap(find.text('Create and insert'));
    await tester.pumpAndSettle();

    expect(find.text('Ravi (from order #123)'), findsOneWidget);
  });

  // ── B: WhatsApp styling in the preview ───────────────────────────────────────

  /// Every rich (segmented) Text on the canvas, flattened to its spans.
  List<TextSpan> segmentSpans(WidgetTester tester) {
    final rich = tester
        .widgetList<Text>(find.byType(Text))
        .where((t) => t.textSpan != null)
        .toList();
    final out = <TextSpan>[];
    void walk(InlineSpan? s) {
      if (s is TextSpan) {
        out.add(s);
        for (final c in s.children ?? const <InlineSpan>[]) {
          walk(c);
        }
      }
    }

    for (final t in rich) {
      walk(t.textSpan);
    }
    return out;
  }

  testWidgets('a bold body_segment renders FontWeight.bold and no asterisks',
      (tester) async {
    await pumpEditor(tester, extra: {
      'wa_preview_draft': (_) => {
            'header': null,
            'body_rendered': '*Payment received — mediBO* thanks',
            'body_plain': 'Payment received — mediBO thanks',
            'body_segments': [
              {'text': 'Payment received — mediBO', 'bold': true},
              {'text': ' thanks', 'bold': false},
            ],
            'buttons': const [],
          },
    });
    await tester.pumpAndSettle();

    final spans = segmentSpans(tester);
    final bold = spans.firstWhere(
      (s) => s.style?.fontWeight == FontWeight.bold,
      orElse: () => const TextSpan(),
    );
    expect(bold.text, 'Payment received — mediBO');

    // The customer never sees the raw markers — they were split out server-side.
    final rendered =
        spans.map((s) => s.text ?? '').join();
    expect(rendered.contains('*'), isFalse);
    expect(find.textContaining('*'), findsNothing);
  });

  testWidgets('an italic body_segment renders FontStyle.italic', (tester) async {
    await pumpEditor(tester, extra: {
      'wa_preview_draft': (_) => {
            'header': null,
            'body_rendered': '_Thank you_',
            'body_plain': 'Thank you',
            'body_segments': [
              {'text': 'Thank you', 'italic': true},
            ],
            'buttons': const [],
          },
    });
    await tester.pumpAndSettle();

    final spans = segmentSpans(tester);
    final italic = spans.firstWhere(
      (s) => s.style?.fontStyle == FontStyle.italic,
      orElse: () => const TextSpan(),
    );
    expect(italic.text, 'Thank you');
  });

  testWidgets('missing body_segments falls back to body_plain', (tester) async {
    await pumpEditor(tester, extra: {
      'wa_preview_draft': (_) => {
            'header': null,
            // No body_segments at all — plain must win over body_rendered.
            'body_rendered': 'RENDERED',
            'body_plain': 'Just plain text',
            'buttons': const [],
          },
    });
    await tester.pumpAndSettle();

    expect(find.text('Just plain text'), findsOneWidget);
    expect(find.text('RENDERED'), findsNothing);
  });
}
