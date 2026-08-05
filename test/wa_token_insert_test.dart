// The value picker inserts NUMBERED Meta variables, via the backend.
//
// Meta accepts numbered variables only — {{1}}, {{2}}. A named one
// ({{customer_name}}) is literal text: the pharmacy receives those characters.
// So the editor never builds a placeholder and never picks a number. Tapping a
// chip calls wa_body_insert_token; the returned body, caret and token_map are
// adopted as one. Editing the body calls wa_body_renumber, which closes the gap
// a deleted variable leaves. The stored token_map — not one rebuilt from the
// text — is what wa_template_save receives.
//
// Both RPCs are mocked inline: no network, no Supabase, no home_shell import.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/features/whatsapp/data/wa_template_api.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_template_editor_screen.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_token_picker.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

/// One row of wa_tokens_screen(), shaped like the live payload. `insert_as`
/// carries the NAMED placeholder the picker must never use — it is here only to
/// prove the screen never puts it on screen.
Map<String, dynamic> _row(String key, String label, String group, String example,
        {bool canDelete = false}) =>
    {
      'key': key,
      'label': label,
      'group_label': group,
      'sort_order': 10,
      'source_kind': 'customer',
      'source_ref': key,
      'format': 'plain',
      'fallback': '',
      'enabled': true,
      'is_system': !canDelete,
      'insert_as': '{{$key}}',
      'example': example,
      'live': true,
      'source_label': 'From the customer record',
      'coverage_pct': 100,
      'coverage_label': null,
      'coverage_tone': 'good',
      'used_in': 0,
      'can_delete': canDelete,
    };

Map<String, dynamic> _tokensScreen() => {
      'rows': [
        _row('customer_name', 'Customer name', 'Customer', 'Nitesh'),
        _row('rider_name', 'Delivery person', 'Delivery', 'Suresh K.',
            canDelete: true),
      ],
      'search': null,
      'sample_from': 'Examples are from your latest real order',
      'empty_copy': 'No values yet',
      'source_kinds': const [],
      'formats': const ['plain'],
    };

Map<String, dynamic> _screen() => {
      'copy': const {
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

  bool called(String fn) => calls.any((c) => c.key == fn);
}

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    WaTokenPicker.searchDebounce = Duration.zero;
    WaTokenPicker.pollInterval = Duration.zero;
    WaTemplateEditorScreen.debounce = Duration.zero;
    WaTemplateEditorScreen.renumberDebounce = Duration.zero;
    // The 600 ms duplicate-check debounce is a real Timer that would outlive
    // the test; collapse it too.
    WaTemplateEditorScreen.similarDebounce = Duration.zero;
  });

  tearDown(() => WaTemplateApi.rpcTransport = null);

  /// Answers everything the editor touches on open with benign defaults, so a
  /// test only has to describe the RPCs it is actually about.
  Map<String, dynamic Function(Map<String, dynamic>)> base({
    dynamic Function(Map<String, dynamic>)? insert,
    dynamic Function(Map<String, dynamic>)? renumber,
    dynamic Function(Map<String, dynamic>)? save,
  }) =>
      {
        'wa_tokens_screen': (_) => _tokensScreen(),
        'wa_template_validate': (_) =>
            {'ok': true, 'errors': [], 'warnings': []},
        'wa_template_preview': (_) => {'body': 'preview', 'buttons': []},
        // Default renumber is a no-op: an already-numbered body has no gap.
        'wa_body_renumber': renumber ??
            (p) => {
                  'body': p['p_body'],
                  'token_map': p['p_token_map'],
                  'changed': false,
                },
        'wa_body_insert_token': ?insert,
        'wa_template_save': save ??
            (_) => {
                  'ok': true,
                  'template': {'id': 't1'},
                },
      };

  Future<MockRpc> pumpEditor(
    WidgetTester tester,
    Map<String, dynamic Function(Map<String, dynamic>)> handlers,
  ) async {
    // The editor is a tall form; at 800x600 the chips land below the fold.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final mock = MockRpc(handlers);
    WaTemplateApi.rpcTransport = mock.call;

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    final ctx = tester.element(find.byType(SizedBox));
    Navigator.of(ctx).push(MaterialPageRoute(
      builder: (_) => WaTemplateEditorScreen(screen: _screen()),
    ));
    await tester.pumpAndSettle();
    return mock;
  }

  /// The body field is the multi-line one.
  TextEditingController bodyController(WidgetTester tester) => tester
      .widget<TextField>(
          find.byWidgetPredicate((w) => w is TextField && w.maxLines == 6))
      .controller!;

  Future<void> tapChip(WidgetTester tester, String label) async {
    // The editor is taller than the viewport; an un-scrolled tap silently
    // misses, so the chip is scrolled into view first.
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'tapping a chip sends the field text and cursor, writes the returned body '
      'and caret back, and never puts a named placeholder on screen',
      (tester) async {
    late Map<String, dynamic> insertParams;
    await pumpEditor(
      tester,
      base(insert: (p) {
        insertParams = p;
        // The backend's answer — a NUMBERED variable, dropped at the caret.
        return {
          'body': 'Hi {{1}}, welcome',
          'cursor': 'Hi {{1}}'.length,
          'inserted': '{{1}}',
          'token_map': ['customer_name'],
          'label': 'Customer name',
          'preview_value': 'Nitesh',
        };
      }),
    );

    final body = bodyController(tester);
    body.text = 'Hi , welcome';
    body.selection = const TextSelection.collapsed(offset: 3); // after "Hi "
    await tester.pumpAndSettle();

    await tapChip(tester, 'Customer name');

    // 1. The RPC received exactly what was in the field, and the caret offset.
    expect(insertParams['p_body'], 'Hi , welcome');
    expect(insertParams['p_cursor'], 3);
    expect(insertParams['p_key'], 'customer_name');

    // 2. The field now shows the body the backend produced — numbered, not named.
    expect(body.text, 'Hi {{1}}, welcome');
    // 3. The caret sits where the backend put it.
    expect(body.selection.baseOffset, 'Hi {{1}}'.length);

    // 4. The literal named placeholder appears nowhere — not in the body, not
    //    on a chip. This is the entire bug.
    expect(find.textContaining('{{customer_name}}'), findsNothing);
    expect(body.text.contains('{{customer_name}}'), isFalse);

    // Let the preview toast's auto-dismiss timer expire.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets(
      'save passes the token_map the insert RPC returned, not one rebuilt in Dart',
      (tester) async {
    final mock = await pumpEditor(
      tester,
      base(insert: (p) => {
            'body': 'Hi {{1}}',
            'cursor': 'Hi {{1}}'.length,
            'inserted': '{{1}}',
            // A map the editor could NOT have derived from "{{1}}" by itself —
            // it can only have come from here.
            'token_map': ['customer_name'],
            'label': 'Customer name',
            'preview_value': 'Nitesh',
          }),
    );

    final body = bodyController(tester);
    body.text = 'Hi ';
    body.selection = const TextSelection.collapsed(offset: 3);
    await tester.pumpAndSettle();

    await tapChip(tester, 'Customer name');

    await tester.tap(find.text('Save'));
    await tester.pump(); // run the save
    await tester.pump(const Duration(seconds: 5)); // let toast timers expire

    // The stored map is passed straight through — index 0 is what {{1}} means.
    final params = mock.paramsFor('wa_template_save')!;
    expect(params['p_token_map'], ['customer_name']);
  });

  testWidgets('an insert error inserts nothing and shows the message',
      (tester) async {
    await pumpEditor(
      tester,
      base(insert: (_) => {
            'error': 'unknown_value',
            'message': 'That value no longer exists',
          }),
    );

    final body = bodyController(tester);
    body.text = 'Hello';
    body.selection = const TextSelection.collapsed(offset: 5);
    await tester.pumpAndSettle();

    await tapChip(tester, 'Customer name');

    // The body is untouched — a refusal never leaves half an insert behind.
    expect(body.text, 'Hello');
    // The backend's own sentence is shown.
    expect(find.text('That value no longer exists'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets(
      'editing the body runs wa_body_renumber and adopts it when changed is true',
      (tester) async {
    late Map<String, dynamic> renumberParams;
    final mock = await pumpEditor(
      tester,
      base(renumber: (p) {
        renumberParams = p;
        // The admin deleted {{1}} from the middle, leaving a hole at {{2}}.
        // The backend closes it and hands back the rebuilt map.
        return {
          'body': 'Bye {{1}}',
          'token_map': ['rider_name'],
          'changed': true,
        };
      }),
    );

    final body = bodyController(tester);
    body.text = 'Bye {{2}}';
    await tester.pumpAndSettle(); // fire the renumber debounce (zero)

    // The RPC saw the gapped body, and the field now shows the closed-up one.
    expect(mock.called('wa_body_renumber'), isTrue);
    expect(renumberParams['p_body'], 'Bye {{2}}');
    expect(body.text, 'Bye {{1}}');
  });

  testWidgets('a no-op renumber (changed:false) leaves the body alone',
      (tester) async {
    final mock = await pumpEditor(
      tester,
      base(renumber: (p) => {
            'body': 'DIFFERENT — must not be applied',
            'token_map': p['p_token_map'],
            'changed': false,
          }),
    );

    final body = bodyController(tester);
    body.text = 'All good {{1}}';
    await tester.pumpAndSettle();

    expect(mock.called('wa_body_renumber'), isTrue);
    // changed:false means the backend said the body was already correct.
    expect(body.text, 'All good {{1}}');
  });
}
