// CMD #2060 — Admin › Customer documents: one three-way choice, per zone.
//
// Two switches (Required, Collected) let four combinations exist for a thing
// that has three states, and two of those combinations meant nothing. What is
// held down here is that the replacement never drifts back into Dart:
//
//   1. The three segments are the backend's `options[]` — value AND label —
//      rendered in payload order. The screen does not know the words
//      "Mandatory", "Optional" or "Off", and it does not know there are three.
//   2. Picking a segment sends customer_doc_type_set with {'mode': <value>}
//      and re-renders from the PAYLOAD THE RPC RETURNED, never from a local
//      flip of the row.
//   3. The zone is the backend's. zone_name, zone_note and the locked note
//      print verbatim; a partner (zone_locked) gets no zone control on this
//      screen at all, because admin_active_zone() already pinned them.
//   4. Add and reorder are capabilities, not roles guessed in Dart:
//      can_add / can_reorder false means the button and the drag handles are
//      absent — not disabled.
//   5. "Copy defaults to this zone" appears only while the backend says
//      can_copy_defaults, and "Use the default" only where can_reset.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/customer_doc_types_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

List<Map<String, dynamic>> _options() => [
      {'value': 'mandatory', 'label': 'Mandatory'},
      {'value': 'optional', 'label': 'Optional'},
      {'value': 'off', 'label': 'Off'},
    ];

Map<String, dynamic> _item({
  required String key,
  required String label,
  required String mode,
  String source = 'default',
  String sourceLabel = 'Default',
  bool canReset = false,
}) =>
    {
      'key': key,
      'label': label,
      'hint': '',
      'mode': mode,
      'mode_label': mode,
      'note': 'note:$mode',
      'options': _options(),
      'sort_order': 10,
      'camera_only': false,
      'source': source,
      'source_label': sourceLabel,
      'can_reset': canReset,
      'reset_label': 'Use the default',
    };

Map<String, dynamic> _payload({
  List<Map<String, dynamic>>? items,
  bool isDefaults = false,
  String zoneName = 'Raipur',
  bool zoneLocked = false,
  bool canCopy = false,
  bool canAdd = true,
  bool canReorder = true,
}) =>
    {
      'ok': true,
      'title': 'Customer documents',
      'subtitle': 'Choose how each document is asked for in this zone.',
      'mode_label': 'How it is asked',
      'zone_label': 'Zone',
      'zone_id': isDefaults ? null : 1,
      'zone_name': zoneName,
      'is_defaults': isDefaults,
      'zone_note': isDefaults
          ? 'These apply to every zone that has not set its own.'
          : 'This list applies to Raipur only.',
      'zone_locked': zoneLocked,
      'zone_locked_note': zoneLocked ? 'You are editing your own zone.' : '',
      'can_copy_defaults': canCopy,
      'copy_defaults_label': 'Copy defaults to this zone',
      'can_add': canAdd,
      'add_label': 'Add a document',
      'add_title': 'New document',
      'add_name_label': 'What is it called?',
      'add_hint_label': 'A line of help for the customer',
      'add_save_label': 'Add',
      'can_reorder': canReorder,
      'reorder_hint': canReorder ? 'Drag to reorder.' : '',
      'empty_line': 'No documents yet.',
      'items': items ??
          [
            _item(key: 'drug_licence', label: 'Drug licence', mode: 'mandatory'),
            _item(key: 'gst', label: 'GST certificate', mode: 'optional'),
            _item(key: 'pan', label: 'PAN card', mode: 'off'),
          ],
      'item_count': 3,
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => CustomerDocTypesScreen.rpcTransport = null);

  // A 412 px phone, tall enough that the whole page is built: an assertion
  // that something is ABSENT must not be able to pass merely because it is
  // below the fold.
  Future<void> pump(WidgetTester t) async {
    t.view.physicalSize = const Size(412, 1600);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(const MaterialApp(home: CustomerDocTypesScreen()));
    await t.pumpAndSettle();
  }

  testWidgets('three segments per document, labelled by the backend, in order',
      (t) async {
    CustomerDocTypesScreen.rpcTransport = (fn, p) async {
      expect(fn, 'customer_doc_types_admin');
      return _payload();
    };
    await pump(t);

    // One set of segments per document, each carrying the payload's own words.
    expect(find.text('Mandatory'), findsNWidgets(3));
    expect(find.text('Optional'), findsNWidgets(3));
    expect(find.text('Off'), findsNWidgets(3));

    // The old two-switch control is gone — not hidden, gone.
    expect(find.byType(Switch), findsNothing);

    // Payload order, not alphabetical.
    final labels = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .where((s) =>
            s == 'Drug licence' || s == 'GST certificate' || s == 'PAN card')
        .toList();
    expect(labels, ['Drug licence', 'GST certificate', 'PAN card']);

    // The caption under each control is the backend's note for the mode it is
    // actually on — never a sentence Dart assembled.
    expect(find.text('note:mandatory'), findsOneWidget);
    expect(find.text('note:optional'), findsOneWidget);
    expect(find.text('note:off'), findsOneWidget);
  });

  testWidgets('picking a segment sends mode and renders the RPC reply',
      (t) async {
    final calls = <List<Object?>>[];
    CustomerDocTypesScreen.rpcTransport = (fn, p) async {
      calls.add([fn, p]);
      if (fn == 'customer_doc_types_admin') return _payload();
      return {
        'ok': true,
        'message': 'Saved.',
        // The server says GST is now mandatory AND that it is this zone's own
        // row. The screen must take both from here.
        'payload': _payload(items: [
          _item(key: 'drug_licence', label: 'Drug licence', mode: 'mandatory'),
          _item(
              key: 'gst',
              label: 'GST certificate',
              mode: 'mandatory',
              source: 'zone',
              sourceLabel: 'Changed for this zone',
              canReset: true),
          _item(key: 'pan', label: 'PAN card', mode: 'off'),
        ]),
      };
    };
    await pump(t);

    // The 'Mandatory' segment of the SECOND card (GST).
    await t.tap(find.text('Mandatory').at(1));
    await t.pumpAndSettle();

    final set = calls.firstWhere((c) => c[0] == 'customer_doc_type_set');
    final args = set[1] as Map<String, dynamic>;
    expect(args['p_key'], 'gst');
    expect(args['p_patch'], {'mode': 'mandatory'});

    expect(find.text('Changed for this zone'), findsOneWidget);
    expect(find.text('Use the default'), findsOneWidget);
    expect(find.text('note:optional'), findsNothing);
  });

  testWidgets('"Use the default" drops this zone\'s override', (t) async {
    final calls = <List<Object?>>[];
    CustomerDocTypesScreen.rpcTransport = (fn, p) async {
      calls.add([fn, p]);
      if (fn == 'customer_doc_types_admin') {
        return _payload(items: [
          _item(
              key: 'gst',
              label: 'GST certificate',
              mode: 'mandatory',
              source: 'zone',
              sourceLabel: 'Changed for this zone',
              canReset: true),
        ]);
      }
      return {'ok': true, 'message': 'Back to the default.', 'payload': _payload()};
    };
    await pump(t);

    await t.tap(find.text('Use the default'));
    await t.pumpAndSettle();

    final set = calls.firstWhere((c) => c[0] == 'customer_doc_type_set');
    expect((set[1] as Map<String, dynamic>)['p_patch'], {'reset': true});
  });

  testWidgets('the zone is the backend\'s, and a partner gets no picker here',
      (t) async {
    CustomerDocTypesScreen.rpcTransport = (fn, p) async =>
        _payload(zoneLocked: true, canAdd: false, canReorder: false);
    await pump(t);

    expect(find.text('Zone'), findsOneWidget);
    expect(find.text('Raipur'), findsOneWidget);
    expect(find.text('This list applies to Raipur only.'), findsOneWidget);
    expect(find.text('You are editing your own zone.'), findsOneWidget);

    // A partner cannot change the list itself: both are ABSENT, not disabled.
    expect(find.text('Add a document'), findsNothing);
    expect(find.byIcon(Icons.drag_handle), findsNothing);
    expect(find.text('Drag to reorder.'), findsNothing);
  });

  testWidgets('super admin on Defaults: no copy button, no per-zone chrome',
      (t) async {
    CustomerDocTypesScreen.rpcTransport = (fn, p) async =>
        _payload(isDefaults: true, zoneName: 'Defaults');
    await pump(t);

    expect(find.text('Defaults'), findsOneWidget);
    expect(find.text('These apply to every zone that has not set its own.'),
        findsOneWidget);
    expect(find.text('Copy defaults to this zone'), findsNothing);
    // The list itself is editable here.
    expect(find.text('Add a document'), findsOneWidget);
    expect(find.byIcon(Icons.drag_handle), findsNWidgets(3));
  });

  testWidgets('a fresh zone is offered the defaults, once', (t) async {
    final calls = <String>[];
    CustomerDocTypesScreen.rpcTransport = (fn, p) async {
      calls.add(fn);
      if (fn == 'customer_doc_types_admin') return _payload(canCopy: true);
      return {
        'ok': true,
        'message': 'Defaults copied to this zone.',
        'payload': _payload(canCopy: false),
      };
    };
    await pump(t);

    expect(find.text('Copy defaults to this zone'), findsOneWidget);
    await t.tap(find.text('Copy defaults to this zone'));
    await t.pumpAndSettle();

    expect(calls, contains('customer_doc_zone_copy_defaults'));
    expect(find.text('Copy defaults to this zone'), findsNothing);
  });

  testWidgets('reorder sends the whole new key order', (t) async {
    final calls = <List<Object?>>[];
    CustomerDocTypesScreen.rpcTransport = (fn, p) async {
      calls.add([fn, p]);
      if (fn == 'customer_doc_types_admin') return _payload();
      return {'ok': true, 'message': 'New order saved.', 'payload': _payload()};
    };
    await pump(t);

    final handle = find.byIcon(Icons.drag_handle).first;
    final start = t.getCenter(handle);
    final drag = await t.startGesture(start);
    await t.pump(const Duration(milliseconds: 600));
    await drag.moveBy(const Offset(0, 220));
    await t.pump();
    await drag.up();
    await t.pumpAndSettle();

    final r = calls.firstWhere((c) => c[0] == 'customer_doc_types_reorder');
    final keys = (r[1] as Map<String, dynamic>)['p_keys'] as List;
    // Every key still there, exactly once, and the first one has moved.
    expect(keys.toSet(), {'drug_licence', 'gst', 'pan'});
    expect(keys.length, 3);
    expect(keys.first, isNot('drug_licence'));
  });

  testWidgets('a refusal prints the backend message and nothing else',
      (t) async {
    CustomerDocTypesScreen.rpcTransport = (fn, p) async => {
          'ok': false,
          'message': 'Only an admin can open this.',
          'items': const [],
        };
    await pump(t);

    expect(find.text('Only an admin can open this.'), findsOneWidget);
    expect(find.text('Mandatory'), findsNothing);
    expect(find.text('Add a document'), findsNothing);
  });
}
