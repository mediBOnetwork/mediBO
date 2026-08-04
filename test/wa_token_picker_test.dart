import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/features/whatsapp/data/wa_template_api.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_template_editor_screen.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_token_picker.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// The searchable value picker.
///
/// Every RPC is mocked inline — no network, no Supabase, and nothing here
/// imports home_shell.dart (it cannot load on the Dart VM).
///
/// What these tests hold down is the bug that caused them: the old list was a
/// fixed nine values, so a value it lacked could not be inserted, and typing a
/// bare {{2}} instead sent a customer a message reading "{{2}}". So: the insert
/// text is the backend's `insert_as` dropped at the cursor, the coverage
/// warning is visible BEFORE the insert, and p_token_map carries exactly the
/// keys the picker provided — never one it did not.

// ── fixtures ─────────────────────────────────────────────────────────────────

/// Shaped from the live wa_tokens_screen() payload.
Map<String, dynamic> tokensPayload({List<dynamic>? rows, String? search}) => {
      'rows': rows ?? defaultRows,
      'search': search,
      'sample_from': 'Examples are from your latest real order',
      'empty_copy': 'No values yet',
      'formats': ['plain', 'money', 'title_case'],
      'source_kinds': [
        {'value': 'customer', 'label': 'Customer record', 'table': 'pharmacy_profiles'},
        {
          'value': 'delivery',
          'label': 'Delivery',
          'options': ['rider_name', 'eta_min'],
        },
      ],
    };

final List<dynamic> defaultRows = [
  {
    'key': 'customer_name',
    'label': 'Customer name',
    'group_label': 'Customer',
    'sort_order': 10,
    'source_kind': 'customer',
    'source_ref': 'customer_name',
    'format': 'title_case',
    'fallback': 'there',
    'enabled': true,
    'is_system': true,
    'insert_as': '{{customer_name}}',
    'example': 'Nitesh',
    'live': true,
    'source_label': 'From the customer record',
    'coverage_pct': 100,
    'coverage_label': 'Every customer has this',
    'coverage_tone': 'good',
    'used_in': 6,
    'can_delete': false,
  },
  {
    'key': 'days',
    'label': 'Days since last order',
    'group_label': 'Customer',
    'sort_order': 55,
    'source_kind': 'computed',
    'source_ref': 'last_order_days',
    'format': 'days',
    'fallback': null,
    'enabled': true,
    'is_system': true,
    'insert_as': '{{days}}',
    'example': '2',
    'live': true,
    'source_label': 'Worked out at send time',
    'coverage_pct': 38,
    'coverage_label': '38% of customers have this — the rest send blank',
    'coverage_tone': 'bad',
    'used_in': 0,
    'can_delete': false,
  },
  {
    'key': 'rider_name',
    'label': 'Delivery person',
    'group_label': 'Delivery',
    'sort_order': 80,
    'source_kind': 'delivery',
    'source_ref': 'rider_name',
    'format': 'title_case',
    'fallback': 'our delivery team',
    'enabled': true,
    'is_system': false,
    'insert_as': '{{rider_name}}',
    'example': 'our delivery team',
    'live': true,
    'source_label': 'From the delivery',
    'coverage_pct': null,
    'coverage_label': null,
    'coverage_tone': 'muted',
    'used_in': 0,
    'can_delete': true,
  },
];

/// Minimal wa_templates_screen() payload — the editor renders its copy verbatim.
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
        'save': 'Save',
        'submit': 'Submit',
        'saved': 'Saved',
        'generic_error': 'Something went wrong',
      },
      'starters': [],
      'categories': [
        {'key': 'MARKETING', 'label': 'Marketing'}
      ],
      'languages': [
        {'key': 'en', 'label': 'English'}
      ],
      'button_spec': {'types': [], 'total_max': 0},
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
}

void main() {
  setUpAll(() {
    // The 800 ms debounce is a real Timer that would outlive the test.
    RenderLog.flushEnabled = false;
    WaTokenPicker.searchDebounce = Duration.zero;
    WaTokenPicker.pollInterval = Duration.zero;
    WaTemplateEditorScreen.debounce = Duration.zero;
  });

  tearDown(() => WaTemplateApi.rpcTransport = null);

  Future<void> pumpPicker(
    WidgetTester tester,
    MockRpc mock, {
    void Function(Map<String, dynamic>)? onInsert,
  }) async {
    WaTemplateApi.rpcTransport = mock.call;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WaTokenPicker(
            onInsert: onInsert ?? (_) {},
            onRows: (_) {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  // ── A: the list ────────────────────────────────────────────────────────────

  testWidgets('chips render grouped by group_label, with example text',
      (tester) async {
    final mock = MockRpc({'wa_tokens_screen': (_) => tokensPayload()});
    await pumpPicker(tester, mock);

    // Group headings, from the payload — not invented here.
    expect(find.text('Customer'), findsOneWidget);
    expect(find.text('Delivery'), findsOneWidget);

    // Labels and their examples.
    expect(find.text('Customer name'), findsOneWidget);
    expect(find.text('Nitesh'), findsOneWidget);
    expect(find.text('Delivery person'), findsOneWidget);
    expect(find.text('our delivery team'), findsOneWidget);

    // sample_from, shown once above the list.
    expect(find.text('Examples are from your latest real order'), findsOneWidget);

    // The value that the old fixed list of nine could not offer at all.
    expect(find.text('Delivery person'), findsOneWidget);
  });

  testWidgets("a 'bad' coverage row shows its warning BEFORE any insert",
      (tester) async {
    var inserted = 0;
    final mock = MockRpc({'wa_tokens_screen': (_) => tokensPayload()});
    await pumpPicker(tester, mock, onInsert: (_) => inserted++);

    // Visible on first paint, with nothing tapped yet — the whole point.
    expect(inserted, 0);
    expect(
      find.text('38% of customers have this — the rest send blank'),
      findsOneWidget,
    );
    expect(find.text('Every customer has this'), findsOneWidget);
  });

  testWidgets('used_in is shown when above zero, and not when zero',
      (tester) async {
    final mock = MockRpc({'wa_tokens_screen': (_) => tokensPayload()});
    await pumpPicker(tester, mock);

    expect(find.text('used in 6 templates'), findsOneWidget);
    expect(find.text('used in 0 templates'), findsNothing);
  });

  // ── C: row actions ─────────────────────────────────────────────────────────

  testWidgets('can_delete false hides Delete; can_delete true offers it',
      (tester) async {
    final mock = MockRpc({'wa_tokens_screen': (_) => tokensPayload()});
    await pumpPicker(tester, mock);

    // customer_name — can_delete: false.
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Disable'), findsOneWidget);
    expect(find.text('Delete'), findsNothing);

    await tester.tapAt(const Offset(5, 5)); // dismiss
    await tester.pumpAndSettle();

    // rider_name — can_delete: true.
    await tester.tap(find.byIcon(Icons.more_vert).last);
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsOneWidget);
  });

  // ── A/B: search and AI ─────────────────────────────────────────────────────

  testWidgets('an empty search result shows empty_copy and the Ask-AI action',
      (tester) async {
    final mock = MockRpc({
      'wa_tokens_screen': (p) => p['p_search'] == null
          ? tokensPayload()
          : tokensPayload(rows: const [], search: p['p_search'] as String?),
    });
    await pumpPicker(tester, mock);

    expect(find.text('Ask AI to find it'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'delivery person');
    await tester.pumpAndSettle();

    expect(find.text('No values yet'), findsOneWidget);
    expect(find.text('Ask AI to find it'), findsOneWidget);
    expect(mock.paramsFor('wa_tokens_screen')!['p_search'], 'delivery person');
  });

  testWidgets('a result with proposal null renders matches and no Create button',
      (tester) async {
    final mock = MockRpc({
      'wa_tokens_screen': (p) => p['p_search'] == null
          ? tokensPayload()
          : tokensPayload(rows: const []),
      'wa_token_ai_search': (_) => {'ok': true, 'job_id': 'j1', 'status': 'queued'},
      'wa_token_search_result': (_) => {
            'status': 'done',
            'status_label': 'Done',
            'result': {
              'matches': [
                {'key': 'rider_name', 'why': 'This is the delivery person'},
              ],
              'proposal': null,
              'note': 'One existing value already covers this',
            },
          },
    });
    await pumpPicker(tester, mock);

    await tester.enterText(find.byType(TextField).first, 'delivery guy');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask AI to find it'));
    await tester.pumpAndSettle();

    expect(find.text('One existing value already covers this'), findsOneWidget);
    expect(find.text('rider_name'), findsOneWidget);
    expect(find.text('This is the delivery person'), findsOneWidget);

    // proposal was null — nothing to create.
    expect(find.text('Create and insert'), findsNothing);
  });

  testWidgets('a proposal renders a Create and insert card', (tester) async {
    final mock = MockRpc({
      'wa_tokens_screen': (p) =>
          p['p_search'] == null ? tokensPayload() : tokensPayload(rows: const []),
      'wa_token_ai_search': (_) => {'ok': true, 'job_id': 'j1'},
      'wa_token_search_result': (_) => {
            'status': 'done',
            'result': {
              'matches': const [],
              'proposal': {
                'key': 'eta_min',
                'label': 'Delivery ETA',
                'group_label': 'Delivery',
                'source_kind': 'delivery',
                'source_ref': 'eta_min',
                'format': 'plain',
                'fallback': 'soon',
                'why': 'Minutes until the rider arrives',
              },
              'note': 'No existing value matches',
            },
          },
    });
    await pumpPicker(tester, mock);

    await tester.enterText(find.byType(TextField).first, 'eta');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask AI to find it'));
    await tester.pumpAndSettle();

    expect(find.text('Delivery ETA'), findsOneWidget);
    expect(find.text('Minutes until the rider arrives'), findsOneWidget);
    expect(find.text('delivery · eta_min'), findsOneWidget);
    expect(find.text('Create and insert'), findsOneWidget);
  });

  // ── C: the form ────────────────────────────────────────────────────────────

  testWidgets('wa_token_save returning resolves false renders its warning',
      (tester) async {
    final mock = MockRpc({
      'wa_tokens_screen': (_) => tokensPayload(),
      'wa_token_save': (_) => {
            'ok': true,
            'key': 'rider_phone',
            'insert_as': '{{rider_phone}}',
            'sample': 'Sample: (blank)',
            'resolves': false,
            'warning': 'That field is empty on your latest order',
          },
    });
    await pumpPicker(tester, mock);

    await tester.tap(find.text('Add a value'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('That field is empty on your latest order'), findsOneWidget);
    expect(find.text('Sample: (blank)'), findsOneWidget);
  });

  testWidgets('wa_token_save returning an error renders its message verbatim',
      (tester) async {
    final mock = MockRpc({
      'wa_tokens_screen': (_) => tokensPayload(),
      'wa_token_save': (_) =>
          {'error': 'no_such_field', 'message': 'orders has no column rider_phone'},
    });
    await pumpPicker(tester, mock);

    await tester.tap(find.text('Add a value'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('orders has no column rider_phone'), findsOneWidget);
  });

  // ── the pure mapping ───────────────────────────────────────────────────────

  test('WaTokenMap reads keys in body order and never invents one', () {
    final index = WaTokenMap.indexOf(defaultRows);

    expect(
      WaTokenMap.fromBody('Hi {{customer_name}}, {{rider_name}} is coming', index),
      ['customer_name', 'rider_name'],
    );

    // Order follows the TEXT, not the payload.
    expect(
      WaTokenMap.fromBody('{{rider_name}} then {{customer_name}}', index),
      ['rider_name', 'customer_name'],
    );

    // A placeholder the picker never provided contributes no key.
    expect(WaTokenMap.fromBody('Hi {{2}} and {{made_up}}', index), isEmpty);

    // Used twice, listed once — every occurrence becomes the same {{n}}.
    expect(
      WaTokenMap.fromBody('{{customer_name}} x {{customer_name}}', index),
      ['customer_name'],
    );
  });

  // ── D: the editor ──────────────────────────────────────────────────────────

  Future<MockRpc> pumpEditor(WidgetTester tester,
      {Map<String, dynamic>? extraHandlers}) async {
    // The editor is a long form; at the default 800x600 the value chips land
    // below the fold and cannot be tapped.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final mock = MockRpc({
      'wa_tokens_screen': (_) => tokensPayload(),
      'wa_template_validate': (_) => {'ok': true, 'errors': [], 'warnings': []},
      'wa_template_preview': (_) => {'body': 'preview', 'buttons': []},
      'wa_template_save': (_) => {
            'ok': true,
            'template': {'id': 't1'},
          },
      ...?extraHandlers?.cast<String, dynamic Function(Map<String, dynamic>)>(),
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

  /// The body field is the multi-line one.
  TextEditingController bodyController(WidgetTester tester) =>
      tester
          .widget<TextField>(find.byWidgetPredicate(
              (w) => w is TextField && w.maxLines == 6))
          .controller!;

  testWidgets('tapping a chip inserts insert_as AT THE CURSOR, not appended',
      (tester) async {
    await pumpEditor(tester);

    final body = bodyController(tester);
    body.text = 'Hi , your order is ready';
    body.selection = const TextSelection.collapsed(offset: 3); // after "Hi "
    await tester.pumpAndSettle();

    await tester.tap(find.text('Customer name'));
    await tester.pumpAndSettle();

    // Inserted at offset 3 — NOT appended to the end.
    expect(body.text, 'Hi {{customer_name}}, your order is ready');
    expect(body.text.endsWith('{{customer_name}}'), isFalse);

    // And the caret sits after what was inserted.
    expect(body.selection.baseOffset, 3 + '{{customer_name}}'.length);
  });

  testWidgets('saving passes p_token_map with exactly the inserted keys',
      (tester) async {
    final mock = await pumpEditor(tester);

    final body = bodyController(tester);
    body.text = 'Hello ';
    body.selection = const TextSelection.collapsed(offset: 6);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Customer name'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delivery person'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pump(); // run the save
    // The success toast schedules a 4s auto-dismiss; let it expire so no real
    // Timer outlives the test.
    await tester.pump(const Duration(seconds: 5));

    final params = mock.paramsFor('wa_template_save')!;
    expect(params['p_token_map'], ['customer_name', 'rider_name']);
  });

  testWidgets('a hand-typed {{2}} contributes no key to p_token_map',
      (tester) async {
    final mock = await pumpEditor(tester);

    final body = bodyController(tester);
    body.text = 'Hello ';
    body.selection = const TextSelection.collapsed(offset: 6);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Customer name'));
    await tester.pumpAndSettle();

    // Exactly the bug that started this: a bare placeholder typed by hand.
    body.text = '${body.text} and {{2}}';
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pump(); // run the save
    // The success toast schedules a 4s auto-dismiss; let it expire so no real
    // Timer outlives the test.
    await tester.pump(const Duration(seconds: 5));

    final params = mock.paramsFor('wa_template_save')!;
    expect(params['p_token_map'], ['customer_name']);
  });
}
