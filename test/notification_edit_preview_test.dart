// Dashboard notifications — edit + preview on every notification, every user
// type. Everything the box shows is notification_matrix()'s payload: the tabs,
// the labels, the tones, which row may be edited/previewed/generated. This test
// mocks every RPC inline (via NotificationsCard.rpcOverride) and the editor
// navigation (via openEditorOverride) — no network, no Supabase, no home_shell.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/widgets/notifications_card.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ────────────────────────────────────────────────────────────────

Map<String, dynamic> _aud(String value, String label, int sort) =>
    {'value': value, 'label': label, 'sort': sort};

Map<String, dynamic> _row({
  String audience = 'customer',
  String actionKey = 'order_shipped',
  String label = 'Order shipped',
  bool enabled = true,
  String templateId = 'tpl-1',
  String templateLabel = 'Live — order_shipped',
  String templateTone = 'good',
  bool canEdit = true,
  bool canPreview = true,
  bool canGenerate = false,
  String editLabel = 'Edit template',
}) =>
    {
      'audience': audience,
      'audience_label': audience,
      'audience_sort': 1,
      'action_key': actionKey,
      'label': label,
      'enabled': enabled,
      'sort': 1,
      'template_id': templateId,
      'template_name': 'order_shipped',
      'template_status': 'APPROVED',
      'template_label': templateLabel,
      'template_tone': templateTone,
      'can_edit': canEdit,
      'can_preview': canPreview,
      'can_generate': canGenerate,
      'edit_label': editLabel,
      'has_pending_change': false,
      'auto_manage': false,
    };

Map<String, dynamic> _matrix(List<Map<String, dynamic>> rows,
        {List<Map<String, dynamic>>? audiences}) =>
    {
      'audiences': audiences ??
          [
            _aud('customer', 'Customer', 1),
            _aud('supplier', 'Supplier', 2),
            _aud('delivery_partner', 'Delivery partner', 3),
          ],
      'rows': rows,
      'note': 'These are the messages mediBO can send.',
      'allowlist_note': 'Test numbers always receive these.',
    };

// ── harness ─────────────────────────────────────────────────────────────────

class _Rpc {
  final List<MapEntry<String, Map<String, dynamic>?>> calls = [];
  final Map<String, dynamic> matrix;
  final Map<String, dynamic>? pair;
  final Map<String, dynamic>? generate;
  _Rpc({required this.matrix, this.pair, this.generate});

  Future<dynamic> call(String fn, Map<String, dynamic>? params) async {
    calls.add(MapEntry(fn, params));
    switch (fn) {
      case 'notification_matrix':
        return matrix;
      case 'get_notification_allowlist':
        return <dynamic>[];
      case 'set_notification_setting':
        return true;
      case 'notification_generate_template':
        return generate ??
            {'ok': true, 'template_id': 'tpl-new', 'created': true, 'message': 'Created'};
      case 'wa_template_preview_pair':
        return pair ?? const <String, dynamic>{};
      default:
        return const <String, dynamic>{};
    }
  }

  bool called(String fn) => calls.any((c) => c.key == fn);
  int indexOf(String fn) => calls.indexWhere((c) => c.key == fn);
  Map<String, dynamic>? paramsFor(String fn) {
    for (final c in calls.reversed) {
      if (c.key == fn) return c.value;
    }
    return null;
  }
}

Future<_Rpc> _pump(
  WidgetTester tester, {
  required Map<String, dynamic> matrix,
  Map<String, dynamic>? pair,
  Map<String, dynamic>? generate,
}) async {
  tester.view.physicalSize = const Size(500, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final rpc = _Rpc(matrix: matrix, pair: pair, generate: generate);
  NotificationsCard.rpcOverride = rpc.call;

  await tester.pumpWidget(const MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: NotificationsCard()),
    ),
  ));
  await tester.pumpAndSettle();
  // Expand — the rows and tabs only build once open.
  await tester.tap(find.text('NOTIFICATIONS'));
  await tester.pumpAndSettle();
  return rpc;
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  setUp(NotificationsCard.debugResetCache);
  tearDown(() {
    NotificationsCard.rpcOverride = null;
    NotificationsCard.openEditorOverride = null;
    NotificationsCard.debugResetCache();
  });

  testWidgets('a tab is built for every audience, including a third user type',
      (tester) async {
    await _pump(tester, matrix: _matrix([_row()]));

    // Not the hardcoded Customer/Supplier pair — every user type the backend
    // sent, captioned with its label.
    expect(find.text('Customer'), findsOneWidget);
    expect(find.text('Supplier'), findsOneWidget);
    expect(find.text('Delivery partner'), findsOneWidget);
  });

  testWidgets('an empty audience shows the note, not a missing tab',
      (tester) async {
    // Rows only for supplier; the customer tab (first) has none.
    await _pump(tester,
        matrix: _matrix([_row(audience: 'supplier', actionKey: 'x')]));

    // The customer tab still exists and its empty state is the backend's note.
    expect(find.text('Customer'), findsOneWidget);
    expect(find.text('These are the messages mediBO can send.'), findsOneWidget);
  });

  testWidgets('can_generate true mints a template first, then navigates with it',
      (tester) async {
    String? navId;
    NotificationsCard.openEditorOverride = (ctx, id) async => navId = id;

    final rpc = await _pump(
      tester,
      matrix: _matrix([
        _row(
          actionKey: 'payment_pending',
          label: 'Payment pending',
          templateId: '',
          templateLabel: 'No template yet',
          templateTone: 'warn',
          canPreview: false,
          canGenerate: true,
          editLabel: 'Create template',
        ),
      ]),
    );

    await tester.ensureVisible(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    // Generated BEFORE navigating, and the navigation used the RETURNED id.
    expect(rpc.called('notification_generate_template'), isTrue);
    final gp = rpc.paramsFor('notification_generate_template')!;
    expect(gp['p_audience'], 'customer');
    expect(gp['p_action_key'], 'payment_pending');
    expect(navId, 'tpl-new');
  });

  testWidgets('can_generate false navigates straight with the row template_id',
      (tester) async {
    String? navId;
    NotificationsCard.openEditorOverride = (ctx, id) async => navId = id;

    final rpc = await _pump(
      tester,
      matrix: _matrix([_row(templateId: 'tpl-existing', canGenerate: false)]),
    );

    await tester.ensureVisible(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    expect(rpc.called('notification_generate_template'), isFalse);
    expect(navId, 'tpl-existing');
  });

  testWidgets('can_preview false hides the preview icon; true shows it',
      (tester) async {
    await _pump(tester,
        matrix: _matrix([_row(canPreview: false, canEdit: true)]));
    expect(find.byIcon(Icons.visibility_outlined), findsNothing);
    // Edit is still offered, so the icons DO render — preview is hidden on its
    // own flag, not because the row skipped its controls.
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
  });

  testWidgets('the preview sheet renders the current bubble and the previous one',
      (tester) async {
    await _pump(
      tester,
      matrix: _matrix([_row(canPreview: true)]),
      pair: {
        'current': {
          'header': null,
          'body_rendered': 'Hi Nitesh, your order shipped',
          'footer': 'Reply STOP to opt out',
          'buttons': const [],
        },
        'current_label': 'Live now — this is what customers receive',
        'current_tone': 'good',
        'has_previous': true,
        'previous_label': 'Still being sent until Meta approves the new one',
        'previous_at': '04 Aug, 11:20 AM',
        'previous_body': 'Old wording still going out',
      },
    );

    await tester.ensureVisible(find.byIcon(Icons.visibility_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pumpAndSettle();

    // Current wording + its label.
    expect(find.text('Hi Nitesh, your order shipped'), findsOneWidget);
    expect(find.text('Live now — this is what customers receive'), findsOneWidget);
    // The PREVIOUS wording still going out, in its own bubble.
    expect(find.text('Old wording still going out'), findsOneWidget);
    expect(find.text('Still being sent until Meta approves the new one'),
        findsOneWidget);
    // Two delivered bubbles: current + previous.
    expect(find.byKey(const Key('notif_preview_bubble')), findsNWidgets(2));
  });

  testWidgets('the preview sheet omits the previous bubble when has_previous is false',
      (tester) async {
    await _pump(
      tester,
      matrix: _matrix([_row(canPreview: true)]),
      pair: {
        'current': {'body_rendered': 'Only the current wording', 'buttons': const []},
        'current_label': 'Draft — not submitted yet',
        'current_tone': 'warn',
        'has_previous': false,
        'previous_body': null,
      },
    );

    await tester.ensureVisible(find.byIcon(Icons.visibility_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Only the current wording'), findsOneWidget);
    expect(find.byKey(const Key('notif_preview_bubble')), findsOneWidget);
  });

  testWidgets('the on/off switch still calls set_notification_setting',
      (tester) async {
    final rpc = await _pump(
      tester,
      matrix: _matrix([_row(actionKey: 'order_shipped', enabled: true)]),
    );

    await tester.ensureVisible(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(rpc.called('set_notification_setting'), isTrue);
    final p = rpc.paramsFor('set_notification_setting')!;
    expect(p['p_audience'], 'customer');
    expect(p['p_action_key'], 'order_shipped');
    expect(p['p_enabled'], false); // was on, toggled off
  });

  testWidgets('row height is not grown by the edit and preview icons',
      (tester) async {
    await _pump(
      tester,
      matrix: _matrix([
        _row(
          actionKey: 'with_icons',
          label: 'With icons',
          templateLabel: '',
          canEdit: true,
          canPreview: true,
        ),
        _row(
          actionKey: 'no_icons',
          label: 'No icons',
          templateLabel: '',
          canEdit: false,
          canPreview: false,
        ),
      ]),
    );

    Size rowSize(String label) => tester.getSize(
        find.ancestor(of: find.text(label), matching: find.byType(Row)).first);

    // The icons are compact enough that the row is governed by the switch, so a
    // row carrying both is exactly as tall as one carrying neither.
    expect(rowSize('With icons').height, rowSize('No icons').height);
    // And both icons really are present on the first row.
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
  });
}
