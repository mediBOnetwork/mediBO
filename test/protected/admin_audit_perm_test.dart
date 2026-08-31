// PROTECTED — CHANGE #394. The audit trail and granular admin roles.
//
// What this holds down is the boundary, not the pixels: the two new screens
// are pure renderers over `admin_audit_screen()` / `admin_roles_screen()`, and
// the fence lives in the BACKEND. Concretely:
//
//   • a refusal (`ok:false`) is rendered as the backend's own message — the
//     screen never invents "Access denied", and never throws;
//   • the action wording, the actor line, the IST timestamp and every
//     Before → After value are printed VERBATIM from the payload, so a
//     rewording is an UPDATE to ui_copy and not a deploy;
//   • rows keep payload order (the fixture is deliberately not chronological
//     by content) — no client-side sort;
//   • "no field changed" is the backend's `changes_label`, not a Dart branch
//     on an empty list;
//   • the roles editor marks the access level the PAYLOAD says is current, and
//     tapping another level sends that level's own value — Dart never decides
//     what 'read' or 'write' mean, and never counts grants (`role_label` is
//     composed server-side);
//   • a super admin row is not editable, because the backend flags it, not
//     because the screen recognised an email.
//
// Mocked RPCs inline: no network, no Supabase, no goldens. ~1s on the Dart VM.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/admin_audit_screen.dart';
import 'package:pharma_b2b/screens/admin/admin_roles_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _auditPayload({List<Map<String, dynamic>>? rows}) => {
      'ok': true,
      'title': 'Audit trail',
      'subtitle': 'Every consequential change, with who made it.',
      'count': 3,
      'count_label': '3 changes',
      'has_more': false,
      'more_label': 'Load more',
      'next_offset': 3,
      'before_label': 'Before',
      'after_label': 'After',
      'history_title': 'Full history',
      'empty_title': 'Nothing recorded yet',
      'empty_hint': 'Changes appear here the moment somebody makes one.',
      'applied': const {},
      'filters': [
        {
          'key': 'entity_type',
          'label': 'What',
          'options': [
            {'value': '', 'label': 'All'},
            {'value': 'discount_slab', 'label': 'Discount slab'},
          ],
        },
      ],
      'rows': rows ??
          [
            {
              'id': 91,
              'title': 'Discount slab',
              'entity_label': '#7',
              'action': 'discount_slab.update',
              'action_label': 'Update',
              'entity_type': 'discount_slab',
              'entity_id': '7',
              'actor_label': 'accounts@medibo.in',
              'when_label': '31 Aug 2026, 07:45 PM',
              'tone': 'info',
              'changes_label': 'Discount pct',
              'changes': [
                {
                  'field': 'discount_pct',
                  'label': 'Discount pct',
                  'before': '8',
                  'after': '12',
                },
              ],
            },
            {
              'id': 90,
              'title': 'Admin permission',
              'entity_label': '#9e6db32e-303',
              'action': 'admin_permission.insert',
              'action_label': 'Insert',
              'entity_type': 'admin_permission',
              'entity_id': '9e6db32e-303a',
              'actor_label': 'masteromprakashsahu@gmail.com',
              'when_label': '31 Aug 2026, 07:31 PM',
              'tone': 'success',
              'changes_label': 'Created',
              'changes': const [],
            },
          ],
    };

Map<String, dynamic> _rolesPayload() => {
      'ok': true,
      'title': 'Admin roles',
      'subtitle': 'What each admin can open, and whether they can change it.',
      'preset_label': 'Apply a preset',
      'preset_hint': 'A preset replaces every grant this admin has.',
      'empty_title': 'No other admins yet',
      'empty_hint': 'Add an admin above, then grant the screens they need.',
      'admins': [
        {
          'admin_id': 'aaa',
          'email': 'om@medibo.in',
          'is_super': true,
          'role_label': 'Super admin — full access',
          'zone_label': '',
          'access': const {},
        },
        {
          'admin_id': 'bbb',
          'email': 'accounts@medibo.in',
          'is_super': false,
          'role_label': '6 granted',
          'zone_label': 'Zone 1',
          'access': {'admin.bill_pipeline': 'write', 'admin.customers': 'read'},
        },
      ],
      'groups': [
        {
          'label': 'Money',
          'features': [
            {
              'feature_key': 'admin.bill_pipeline',
              'label': 'Bill pipeline',
              'hint': 'Customer bills and their re-runs.',
            },
          ],
        },
        {
          'label': 'Customers & Suppliers',
          'features': [
            {'feature_key': 'admin.customers', 'label': 'Customers', 'hint': ''},
          ],
        },
      ],
      'presets': [
        {'preset_key': 'accounts', 'label': 'Accounts', 'hint': 'Money.', 'count_label': '9 screens'},
      ],
      'access_options': [
        {'value': 'none', 'label': 'No access', 'tone': 'neutral'},
        {'value': 'read', 'label': 'View', 'tone': 'info'},
        {'value': 'write', 'label': 'Edit', 'tone': 'success'},
      ],
    };

/// The roles editor is a long page; a default 800x600 test surface never
/// builds the groups below the fold, so the assertions would be about
/// ListView laziness rather than about the payload.
void _tallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('audit trail — the screen prints the backend and nothing else', () {
    testWidgets('a refusal renders the backend message, never a Dart string',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: AdminAuditScreen(rpc: (fn, params) async => {
              'ok': false,
              'error': 'not_authorized',
              'title': 'Audit trail',
              'message': 'You do not have access to the audit trail. '
                  'Ask a super admin to grant it.',
            }),
      ));
      await tester.pumpAndSettle();

      expect(
          find.text('You do not have access to the audit trail. '
              'Ask a super admin to grant it.'),
          findsOneWidget,
          reason: 'ok:false must render the payload message verbatim');
      // Nothing invented, and nothing thrown.
      expect(find.text('Access denied'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('rows print action, actor, IST time and the Before → After pair',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: AdminAuditScreen(rpc: (fn, params) async => _auditPayload()),
      ));
      await tester.pumpAndSettle();

      expect(find.text('3 changes'), findsOneWidget);
      expect(find.text('Discount slab #7'), findsOneWidget);
      expect(find.text('Update'), findsOneWidget);
      expect(find.text('accounts@medibo.in · 31 Aug 2026, 07:45 PM'), findsOneWidget);
      // The two values arrive already paired with the backend's own captions.
      expect(find.text('Before 8'), findsOneWidget);
      expect(find.text('After 12'), findsOneWidget);
    });

    testWidgets('an entry with no field diff shows the backend changes_label',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: AdminAuditScreen(rpc: (fn, params) async => _auditPayload()),
      ));
      await tester.pumpAndSettle();

      // 'Created' is the backend's word for "there is no before"; Dart must not
      // substitute its own copy, and must not render an empty change list.
      expect(find.text('Created'), findsOneWidget);
      expect(find.text('Before —'), findsNothing);
    });

    testWidgets('rows keep payload order — no client-side sort', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: AdminAuditScreen(rpc: (fn, params) async => _auditPayload()),
      ));
      await tester.pumpAndSettle();

      final cards = tester.widgetList<AuditRowCard>(find.byType(AuditRowCard)).toList();
      expect(cards.length, 2);
      expect(cards[0].row['id'], 91);
      expect(cards[1].row['id'], 90);
    });

    testWidgets('the empty state is the backend copy, not a Dart placeholder',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: AdminAuditScreen(
            rpc: (fn, params) async => _auditPayload(rows: const [])),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Nothing recorded yet'), findsOneWidget);
      expect(find.text('Changes appear here the moment somebody makes one.'),
          findsOneWidget);
    });

    testWidgets('tapping a row asks for THAT entity history, by its own ids',
        (tester) async {
      final calls = <List<Object?>>[];
      await tester.pumpWidget(MaterialApp(
        home: AdminAuditScreen(rpc: (fn, params) async {
          calls.add([fn, params['p_entity_type'], params['p_entity_id']]);
          if (fn == 'admin_audit_screen') return _auditPayload();
          return {
            'ok': true,
            'title': 'Full history',
            'subtitle': 'Discount slab #7',
            'rows': const [],
            'empty_title': 'Nothing recorded yet',
            'empty_hint': 'Changes appear here the moment somebody makes one.',
            'before_label': 'Before',
            'after_label': 'After',
          };
        }),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Discount slab #7'));
      await tester.pumpAndSettle();

      expect(calls.last, ['admin_audit_entity', 'discount_slab', '7']);
      expect(find.text('Full history'), findsOneWidget);
    });
  });

  group('admin roles — the grant is the payload, the label is the backend', () {
    testWidgets('a non-super caller gets the backend refusal', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: AdminRolesScreen(rpc: (fn, params) async => {
              'ok': false,
              'error': 'not_authorized',
              'title': 'Admin roles',
              'message': 'Only a super admin can change admin roles.',
            }),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Only a super admin can change admin roles.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the role line is printed, never counted in Dart', (tester) async {
      _tallSurface(tester);
      await tester.pumpWidget(MaterialApp(
        home: AdminRolesScreen(rpc: (fn, params) async => _rolesPayload()),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Super admin — full access'), findsOneWidget);
      // "6 granted" is composed server-side; the fixture's access map holds 2
      // entries on purpose, so a Dart-side count would print "2 granted".
      expect(find.text('6 granted · Zone 1'), findsOneWidget);
    });

    testWidgets('the current level comes from the payload, and a tap sends that level',
        (tester) async {
      _tallSurface(tester);
      final sent = <Map<String, dynamic>>[];
      await tester.pumpWidget(MaterialApp(
        home: AdminRolesScreen(rpc: (fn, params) async {
          if (fn == 'admin_roles_screen') return _rolesPayload();
          sent.add(params);
          return {'ok': true, 'toast': 'Saved'};
        }),
      ));
      await tester.pumpAndSettle();

      final billRow = tester.widget<FeatureAccessRow>(find.byWidgetPredicate((w) =>
          w is FeatureAccessRow && w.feature['feature_key'] == 'admin.bill_pipeline'));
      expect(billRow.access, 'write',
          reason: 'the marked level is the payload access map, not a guess');

      final customersRow = tester.widget<FeatureAccessRow>(find.byWidgetPredicate((w) =>
          w is FeatureAccessRow && w.feature['feature_key'] == 'admin.customers'));
      expect(customersRow.access, 'read');

      // Tap "No access" on the customers row — the option's own value travels,
      // for the selected admin, with no Dart-side translation of the word.
      await tester.tap(find.descendant(
          of: find.byWidgetPredicate((w) =>
              w is FeatureAccessRow && w.feature['feature_key'] == 'admin.customers'),
          matching: find.text('No access')));
      // The backend's toast is a real overlay with a real 4 s dismissal timer;
      // pump past it so the assertion is about the RPC, not about the toast.
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      expect(sent.single, {
        'p_email': 'accounts@medibo.in',
        'p_feature_key': 'admin.customers',
        'p_access': 'none',
      });
    });

    testWidgets('a preset is applied by its own key, for the selected admin',
        (tester) async {
      _tallSurface(tester);
      final sent = <Map<String, dynamic>>[];
      await tester.pumpWidget(MaterialApp(
        home: AdminRolesScreen(rpc: (fn, params) async {
          if (fn == 'admin_roles_screen') return _rolesPayload();
          sent.add({'fn': fn, ...params});
          return {'ok': true, 'toast': 'Preset applied'};
        }),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Accounts · 9 screens'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      expect(sent.single, {
        'fn': 'admin_perm_apply_preset',
        'p_email': 'accounts@medibo.in',
        'p_preset_key': 'accounts',
      });
    });
  });
}
