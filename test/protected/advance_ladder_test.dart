// PROTECTED — CMD #1932, the advance ladder.
//
// See CLAUDE.md: this file runs before EVERY deploy and may be edited only by
// a CHANGE that deliberately changes advance-ladder behaviour — never to make
// an unrelated change go green.
//
// What it holds down:
//
//   1. The screen computes NOTHING about the ladder. Each rung's "3rd order
//      onwards", its "20%", its zone name, its status chip and its "On 4
//      orders" line are printed exactly as advance_slabs_list() sent them, in
//      the order the payload sent them. The advance a pharmacy pays is a
//      business decision with money attached; a Dart-side ordinal, a
//      Dart-side "%" or a Dart-side re-sort would put the app's opinion on a
//      screen that is supposed to be reading the backend's.
//
//   2. can_write / can_edit / can_delete are the BACKEND's verdicts. The
//      partner matrix (#307) is what decides whether this admin may touch the
//      Bilaspur ladder, so the screen never infers "editable" from a zone id
//      it compares itself — a read-only payload renders no add button, no
//      edit action and no delete.
//
//   3. A refusal is rendered in the backend's words. The delete of a rung that
//      is already frozen on live orders comes back ok:false with its own
//      message; the screen shows THAT, and does not remove the row.
//
//   4. Access denied is a state, not a crash: ok:false renders the payload's
//      own title/message plus its retry label.
//
//   5. CMD #1933 — the card's ACTIONS are words, not a Switch. "Deactivate"
//      and what the tap means (`toggle_to`) are both the backend's; a Switch
//      made the app decide that flipping it means `!active`, which is the
//      app having an opinion about money.
//
//   6. CMD #1933 — a read-only admin is TOLD it is read-only. The absence of
//      buttons is not the message; `read_only_hint` is, and it is printed
//      verbatim.
//
//   7. CMD #1933 — "Who can edit" appears only when the payload says
//      `show_access`, renders the matrix verbatim, and WRITE IMPLIES READ
//      when it is turned on (one permission truth, decided backend-side and
//      mirrored here so the two toggles can never be sent contradicting).
//
// No network, no Supabase: every RPC is injected.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_advance_slabs_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _rung({
  required int id,
  required int orderNo,
  required String orderLabel,
  required String pctLabel,
  required String zoneLabel,
  bool active = true,
  bool canEdit = true,
  bool canDelete = true,
  String usedLabel = 'Not used yet',
}) =>
    {
      'id': id,
      'order_no': orderNo,
      'order_label': orderLabel,
      'pct': 10,
      'pct_label': pctLabel,
      'zone_id': null,
      'zone_label': zoneLabel,
      'active': active,
      'status_label': active ? 'Active' : 'Off',
      'status_tone': active ? 'success' : 'warning',
      'toggle_to': !active,
      'toggle_label': active ? 'Deactivate' : 'Activate',
      'valid_from': '2026-09-01',
      'effective_label': 'From 01 Sep 2026',
      'used_count': 0,
      'used_label': usedLabel,
      'note': '',
      'can_edit': canEdit,
      'can_delete': canDelete,
    };

Map<String, dynamic> _payload({bool canWrite = true}) => {
      'ok': true,
      'title': 'Advance ladder',
      'subtitle': 'Advance % by how many orders the pharmacy has already paid',
      'hint': 'A zone rung beats the all-zones rung at the same order number.',
      'add_label': 'Add rung',
      'empty_text': 'No rungs yet.',
      'can_write': canWrite,
      'can_add_all_zones': true,
      'zone_id': null,
      'zone_label': 'All zones',
      'all_zones_label': 'All zones',
      'active_date': '13 Sep 2026',
      'retry_label': 'Try again',
      'edit_label': 'Edit',
      'delete_label': 'Delete',
      'delete_confirm': 'Delete this rung?',
      'cancel_label': 'Cancel',
      'access_title': 'Who can edit',
      'show_access': false,
      'read_only_hint': canWrite
          ? ''
          : 'View only — ask super admin for edit access',
      'columns': const [
        {'key': 'order_label', 'label': 'Order', 'align': 'left'},
        {'key': 'pct_label', 'label': 'Advance', 'align': 'right'},
        {'key': 'zone_label', 'label': 'Zone', 'align': 'left'},
        {'key': 'status_label', 'label': 'Status', 'align': 'left'},
      ],
      'form': const {
        'add_title': 'New rung',
        'edit_title': 'Edit rung',
        'save_label': 'Save rung',
        'order_label': "Applies from the customer's nth order",
        'pct_label': 'Advance % of MRP',
        'zone_label': 'Zone',
        'from_label': 'Valid from',
        'note_label': 'Note (optional)',
        'active_label': 'Rung is on',
      },
      'zones': const [
        {'id': 1, 'label': 'Bilaspur'},
        {'id': 2, 'label': 'Raipur'},
      ],
      // Deliberately NOT in ascending order: the screen must not sort.
      'rows': [
        _rung(
            id: 3,
            orderNo: 3,
            orderLabel: '3rd order onwards',
            pctLabel: '20%',
            zoneLabel: 'All zones',
            usedLabel: 'On 4 orders',
            canDelete: false),
        _rung(
            id: 1,
            orderNo: 1,
            orderLabel: '1st order onwards',
            pctLabel: '10%',
            zoneLabel: 'All zones'),
        _rung(
            id: 7,
            orderNo: 2,
            orderLabel: '2nd order onwards',
            pctLabel: '12%',
            zoneLabel: 'Bilaspur',
            active: false),
      ],
    };

Widget _host(AdminAdvanceSlabsScreen screen) => MaterialApp(home: screen);

/// Mobile-first (build_rules.mobile_first): every check below runs at a phone
/// width. The height is generous only so a lazy ListView builds all three
/// rungs — the WIDTH is the one that matters, and it is a phone's.
Future<void> _phone(WidgetTester t, {double width = 412, double height = 1600}) async {
  t.view.physicalSize = Size(width, height);
  t.view.devicePixelRatio = 1.0;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
}

/// Text in the order it appears in the tree.
List<String> _texts(WidgetTester t) => t
    .widgetList<Text>(find.byType(Text))
    .map((w) => w.data ?? '')
    .where((s) => s.isNotEmpty)
    .toList();

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('rungs print the backend strings, in the payload order',
      (t) async {
    await _phone(t);
    await t.pumpWidget(_host(AdminAdvanceSlabsScreen(
      listRpc: () async => _payload(),
    )));
    await t.pumpAndSettle();

    final texts = _texts(t);
    // Verbatim, and never re-sorted into 1-2-3.
    expect(texts.indexOf('3rd order onwards') >= 0, isTrue);
    expect(texts.indexOf('3rd order onwards'),
        lessThan(texts.indexOf('1st order onwards')));
    expect(texts.indexOf('1st order onwards'),
        lessThan(texts.indexOf('2nd order onwards')));

    // The numbers are strings from the payload, never formatted here.
    expect(find.text('20%'), findsOneWidget);
    expect(find.text('12%'), findsOneWidget);
    expect(find.text('On 4 orders'), findsOneWidget);
    expect(find.text('Bilaspur'), findsOneWidget);
    // The status chip is the backend's word, not a boolean rendered in Dart.
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('Active'), findsNWidgets(2));
  });

  testWidgets('a read-only payload offers no add, no edit, no delete',
      (t) async {
    await _phone(t);
    await t.pumpWidget(_host(AdminAdvanceSlabsScreen(
      listRpc: () async {
        final p = _payload(canWrite: false);
        p['rows'] = (p['rows'] as List)
            .map((r) => {
                  ...(r as Map<String, dynamic>),
                  'can_edit': false,
                  'can_delete': false,
                })
            .toList();
        return p;
      },
    )));
    await t.pumpAndSettle();

    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Delete'), findsNothing);
    expect(find.text('Deactivate'), findsNothing);
    // …and the screen SAYS why, in the backend's words.
    expect(find.text('View only — ask super admin for edit access'),
        findsOneWidget);
    // The rungs themselves are still readable.
    expect(find.text('20%'), findsOneWidget);
  });

  testWidgets('a refused delete shows the backend message and keeps the row',
      (t) async {
    var deleteCalls = 0;
    await t.pumpWidget(_host(AdminAdvanceSlabsScreen(
      listRpc: () async => _payload(),
      deleteRpc: (id) async {
        deleteCalls++;
        return {
          'ok': false,
          'error': 'in_use',
          'used_count': 4,
          'message': 'This rung is already frozen on 4 order(s), so it cannot '
              'be deleted. Turn it off instead.',
        };
      },
    )));
    await t.pumpAndSettle();

    // Rung 3 is the one the backend marked can_delete:false — the delete
    // action it DOES offer belongs to a deletable rung. Deleting is confirmed
    // first, in the backend's words.
    await t.tap(find.text('Delete').first);
    await t.pumpAndSettle();
    expect(find.text('Delete this rung?'), findsOneWidget);
    await t.tap(find.text('Delete').last);
    await t.pump();
    await t.pumpAndSettle();

    expect(deleteCalls, 1);
    expect(
        find.textContaining('already frozen on 4 order(s)'), findsOneWidget);
    // Let the toast's own timer expire so no Timer outlives the test.
    await t.pump(const Duration(seconds: 6));
    // Nothing was removed client-side; the list is whatever the reload said.
    expect(find.text('20%'), findsOneWidget);
  });

  testWidgets('ok:false renders the backend refusal, not an exception',
      (t) async {
    await _phone(t);
    await t.pumpWidget(_host(AdminAdvanceSlabsScreen(
      listRpc: () async => {
        'ok': false,
        'error': 'no_access',
        'title': 'Not available',
        'message': 'This screen is not turned on for your login.',
        'retry_label': 'Try again',
      },
    )));
    await t.pumpAndSettle();

    expect(find.text('Not available'), findsOneWidget);
    expect(find.text('This screen is not turned on for your login.'),
        findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('the editor sheet labels come from payload.form', (t) async {
    await _phone(t);
    Map<String, dynamic>? sent;
    await t.pumpWidget(_host(AdminAdvanceSlabsScreen(
      listRpc: () async => _payload(),
      saveRpc: (patch) async {
        sent = patch;
        return {'ok': true, 'id': 9, 'message': 'Rung saved'};
      },
    )));
    await t.pumpAndSettle();

    await t.tap(find.byType(FloatingActionButton));
    await t.pumpAndSettle();

    expect(find.text('New rung'), findsOneWidget);
    expect(find.text("Applies from the customer's nth order"), findsOneWidget);
    expect(find.text('Advance % of MRP'), findsOneWidget);
    expect(find.text('Save rung'), findsOneWidget);

    await t.enterText(find.byType(TextField).at(0), '4');
    await t.enterText(find.byType(TextField).at(1), '25');
    await t.tap(find.text('Save rung'));
    await t.pumpAndSettle();

    expect(sent, isNotNull);
    expect(sent!['order_no'], 4);
    expect(sent!['pct'], 25);
    // An "all zones" rung is sent as a null zone, never as a sentinel Dart
    // invented (0 / -1); the backend owns what null means.
    expect(sent!.containsKey('zone_id'), isTrue);
    expect(sent!['zone_id'], isNull);
    await t.pump(const Duration(seconds: 6));
  });

  testWidgets('the toggle is the backend word and sends the backend intent',
      (t) async {
    await _phone(t);
    final sent = <List<Object>>[];
    await t.pumpWidget(_host(AdminAdvanceSlabsScreen(
      listRpc: () async => _payload(),
      toggleRpc: (id, active) async {
        sent.add([id, active]);
        return {'ok': true, 'message': 'Rung turned off'};
      },
    )));
    await t.pumpAndSettle();

    // Two active rungs say "Deactivate"; the off one says "Activate". Neither
    // word is in this file's control — the payload carries both.
    expect(find.text('Deactivate'), findsNWidgets(2));
    expect(find.text('Activate'), findsOneWidget);

    await t.tap(find.text('Activate'));
    await t.pump();
    await t.pumpAndSettle();

    // Rung 7 is the inactive one, and the call carries the payload's
    // `toggle_to` (true) — not a `!active` the screen worked out itself.
    expect(sent, [
      [7, true]
    ]);
    await t.pump(const Duration(seconds: 6));
  });

  testWidgets('effective date is printed, never formatted here', (t) async {
    await _phone(t);
    await t.pumpWidget(_host(AdminAdvanceSlabsScreen(
      listRpc: () async => _payload(),
    )));
    await t.pumpAndSettle();
    // '2026-09-01' is in the payload too; what is PRINTED is the backend's
    // worded label, so a change of date format is an UPDATE, not a deploy.
    expect(find.text('From 01 Sep 2026'), findsNWidgets(3));
    expect(find.text('2026-09-01'), findsNothing);
  });

  testWidgets('Who can edit appears only when the payload says so', (t) async {
    await _phone(t);
    var accessCalls = 0;
    await t.pumpWidget(_host(AdminAdvanceSlabsScreen(
      listRpc: () async => _payload(),
      accessListRpc: () async {
        accessCalls++;
        return {'ok': true, 'rows': const []};
      },
    )));
    await t.pumpAndSettle();

    // show_access is false in the base payload: not asked for, not drawn.
    expect(accessCalls, 0);
    expect(find.text('Who can edit'), findsNothing);
  });

  testWidgets('Who can edit renders the matrix verbatim; write implies read',
      (t) async {
    await _phone(t);
    final sent = <List<Object?>>[];
    await t.pumpWidget(_host(AdminAdvanceSlabsScreen(
      listRpc: () async => {..._payload(), 'show_access': true},
      accessListRpc: () async => {
        'ok': true,
        'title': 'Who can edit',
        'subtitle': 'Admins and partners, by zone.',
        'read_label': 'Read',
        'write_label': 'Write',
        'empty_text': 'No admins or partners to grant yet.',
        'rows': const [
          {
            'kind': 'admin',
            'id': 'a1',
            'name': 'ops@medibo.in',
            'role_label': 'Admin',
            'zone_label': 'Bilaspur',
            'locked': false,
            'locked_note': '',
            'can_view': true,
            'can_write': false,
          },
          {
            'kind': 'admin',
            'id': 'a0',
            'name': 'om@medibo.in',
            'role_label': 'Super admin',
            'zone_label': 'All zones',
            'locked': true,
            'locked_note': 'Always on for a super admin.',
            'can_view': true,
            'can_write': true,
          },
        ],
      },
      accessSetRpc: (kind, id, view, write) async {
        sent.add([kind, id, view, write]);
        return {'ok': true, 'message': 'Access updated'};
      },
    )));
    await t.pumpAndSettle();

    await t.tap(find.text('Who can edit'));
    await t.pumpAndSettle();

    expect(find.text('ops@medibo.in'), findsOneWidget);
    expect(find.text('Admin · Bilaspur'), findsOneWidget);
    // A locked subject shows the backend's note instead of switches.
    expect(find.text('Always on for a super admin.'), findsOneWidget);

    // The editable admin has exactly two switches (Read, Write); turning
    // Write ON must also carry Read — the two can never be sent disagreeing.
    final switches = find.byType(Switch);
    expect(switches, findsNWidgets(2));
    await t.tap(switches.last);
    await t.pump();
    await t.pumpAndSettle();

    expect(sent, [
      ['admin', 'a1', true, true]
    ]);
    await t.pump(const Duration(seconds: 6));
  });

  testWidgets('editing sends the rung its own valid_from, never a rewind',
      (t) async {
    await _phone(t);
    Map<String, dynamic>? sent;
    await t.pumpWidget(_host(AdminAdvanceSlabsScreen(
      listRpc: () async => _payload(),
      saveRpc: (patch) async {
        sent = patch;
        return {'ok': true, 'id': 1, 'message': 'Rung saved'};
      },
    )));
    await t.pumpAndSettle();

    await t.tap(find.text('Edit').first);
    await t.pumpAndSettle();
    expect(find.text('Edit rung'), findsOneWidget);
    expect(find.text('Valid from'), findsOneWidget);
    await t.tap(find.text('Save rung'));
    await t.pumpAndSettle();

    expect(sent, isNotNull);
    // #1932 shipped a sheet with no date field, so every edit sent no
    // valid_from and the backend's fallback rewound the rung to 2000-01-01.
    expect(sent!['valid_from'], '2026-09-01');
    await t.pump(const Duration(seconds: 6));
  });
}
