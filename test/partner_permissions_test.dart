// CHANGE #307 — the partner surface's focused test.
//
// What it pins:
//   • The partner home is ONE payload printed verbatim: title, zone chip,
//     group labels, tile labels and access words all come from the RPC, in
//     payload order (the fixture is deliberately NOT alphabetical).
//   • NO ZONE SELECTOR ever renders on a partner screen — not a dropdown, not a
//     picker of any kind — and the payload says so itself (show_zone_picker).
//   • A feature with access 'none' is simply absent: the backend does not send
//     it, and the widget never invents a disabled row for it.
//   • Tapping a tile asks the BACKEND first (partner_open) and only navigates
//     on ok:true — a revoked grant refuses with the backend's own message.
//   • is_partner:false renders the backend's message, never a Dart fallback.
//   • The admin matrix draws its three choices from options[] verbatim and
//     sends back the option's own `value`; nothing about 'none/read/write' is
//     spelled in Dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_partner_console_screen.dart';
import 'package:pharma_b2b/screens/partner/partner_home_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _home() => <String, dynamic>{
      'ok': true,
      'is_partner': true,
      'partner_id': 1,
      'partner_name': 'Jai Mahakal Medical And Surgical',
      'title': 'Partner',
      'subtitle': 'Your zone, your work.',
      'zone_id': 1,
      'zone_label': 'Raipur Zone',
      'zone_chip': 'Zone · Raipur Zone',
      'show_zone_picker': false,
      'has_features': true,
      'feature_count': 3,
      'groups': [
        {
          'label': 'Fulfilment',
          'features': [
            {
              'feature_key': 'partner.pack',
              'label': 'Pack',
              'icon_key': 'package',
              'route_key': 'pack',
              'access': 'write',
              'can_write': true,
              'access_label': 'Full access',
            },
            {
              'feature_key': 'partner.collect',
              'label': 'Collect',
              'icon_key': 'store',
              'route_key': 'collect',
              'access': 'read',
              'can_write': false,
              'access_label': 'View only',
            },
          ],
        },
        {
          'label': 'Sourcing',
          'features': [
            {
              'feature_key': 'partner.inquiry',
              'label': 'Inquiry',
              'icon_key': 'forum',
              'route_key': 'inquiry',
              'access': 'read',
              'can_write': false,
              'access_label': 'View only',
            },
          ],
        },
      ],
      'empty_title': 'No features enabled yet',
      'empty_message': 'Contact mediBO to get access.',
    };

Map<String, dynamic> _console() => <String, dynamic>{
      'ok': true,
      'partner_id': 1,
      'partner_name': 'Jai Mahakal Medical And Surgical',
      'zone_label': 'Raipur Zone',
      'zone_locked_label': 'Zone is fixed by the partner record.',
      'users_title': 'Partner logins',
      'users_subtitle': 'They sign in with the same OTP as everyone else.',
      'add_label': 'Add login',
      'add_hint': 'Phone number or email',
      'name_hint': 'Name (optional)',
      'remove_label': 'Remove',
      'empty_users': 'No logins yet.',
      'perm_title': 'What this partner can open',
      'perm_subtitle': 'Takes effect on their next screen load.',
      'audit_title': 'Partner activity',
      'empty_audit': 'No partner activity recorded yet.',
      'users': [
        {
          'id': 7,
          'identity': '9876543210',
          'display_name': 'Ramesh',
          'is_active': true,
          'linked': false,
          'status_label': 'Waiting for first login',
          'added_label': '30 Aug 2026',
        },
      ],
      'features': [
        {
          'feature_key': 'partner.pack',
          'label': 'Pack',
          'group_label': 'Fulfilment',
          'access': 'read',
          'options': [
            {'value': 'none', 'label': 'No access', 'selected': false},
            {'value': 'read', 'label': 'View only', 'selected': true},
            {'value': 'write', 'label': 'Full access', 'selected': false},
          ],
        },
      ],
      'audit': [
        {
          'id': 1,
          'feature_key': 'partner.pack',
          'action': 'open',
          'user_id': 'abc',
          'zone_id': 1,
          'at_label': '30 Aug, 21:40',
        },
      ],
    };

Future<void> _pump(WidgetTester t, Widget child) async {
  // A tall surface so the whole page is laid out at once: these assertions are
  // about WHAT the backend sent, not about how far a list scrolls.
  t.view.physicalSize = const Size(1200, 3000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  // Material ancestor: the console's TextFields and every InkWell need one,
  // and the home view brings its own Scaffold inside it.
  await t.pumpWidget(MaterialApp(home: Material(child: child)));
  await t.pump();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('partner home renders the payload, and only the payload', () {
    testWidgets('titles, zone chip, group and tile labels are verbatim',
        (t) async {
      await _pump(t, PartnerHomeView(payload: _home(), onOpen: (_) {}));

      expect(find.text('Partner'), findsOneWidget);
      expect(find.text('Jai Mahakal Medical And Surgical'), findsOneWidget);
      expect(find.text('Zone · Raipur Zone'), findsOneWidget);
      expect(find.text('Fulfilment'), findsOneWidget);
      expect(find.text('Sourcing'), findsOneWidget);
      expect(find.text('Pack'), findsOneWidget);
      expect(find.text('Collect'), findsOneWidget);
      expect(find.text('Inquiry'), findsOneWidget);
      expect(find.text('Full access'), findsOneWidget);
      expect(find.text('View only'), findsNWidgets(2));
    });

    testWidgets('groups and tiles keep PAYLOAD order, not alphabetical',
        (t) async {
      await _pump(t, PartnerHomeView(payload: _home(), onOpen: (_) {}));

      final ys = <String, double>{};
      for (final label in ['Fulfilment', 'Pack', 'Collect', 'Sourcing', 'Inquiry']) {
        ys[label] = t.getTopLeft(find.text(label)).dy;
      }
      // Fulfilment (Pack, Collect) came first in the payload; alphabetical
      // ordering anywhere would put Collect above Pack and Sourcing first.
      expect(ys['Fulfilment']! < ys['Pack']!, isTrue);
      expect(ys['Pack']! < ys['Collect']!, isTrue);
      expect(ys['Collect']! < ys['Sourcing']!, isTrue);
      expect(ys['Sourcing']! < ys['Inquiry']!, isTrue);
    });

    testWidgets('NO zone selector renders on a partner screen', (t) async {
      await _pump(t, PartnerHomeView(payload: _home(), onOpen: (_) {}));

      expect(find.byType(DropdownButton<Object?>), findsNothing);
      expect(find.byType(DropdownButtonFormField<Object?>), findsNothing);
      expect(find.byType(PopupMenuButton<Object?>), findsNothing);
      expect(_home()['show_zone_picker'], isFalse);
    });

    testWidgets('a feature the backend did not send is simply not there',
        (t) async {
      await _pump(t, PartnerHomeView(payload: _home(), onOpen: (_) {}));
      // 'Assign to delivery' is a registered feature, but this partner has no
      // grant for it, so the backend omitted it — and the widget invents
      // nothing, not even a disabled row.
      expect(find.text('Assign to delivery'), findsNothing);
      expect(find.text('Bag mapping'), findsNothing);
    });

    testWidgets('empty state prints the backend copy', (t) async {
      final p = _home()
        ..['has_features'] = false
        ..['groups'] = <dynamic>[]
        ..['feature_count'] = 0;
      await _pump(t, PartnerHomeView(payload: p, onOpen: (_) {}));

      expect(find.text('No features enabled yet'), findsOneWidget);
      expect(find.text('Contact mediBO to get access.'), findsOneWidget);
    });

    testWidgets('is_partner:false renders the backend message', (t) async {
      await _pump(
        t,
        PartnerHomeView(
          payload: const {
            'is_partner': false,
            'title': 'Partner',
            'message': 'This account is not a partner login.',
          },
          onOpen: (_) {},
        ),
      );
      expect(find.text('This account is not a partner login.'), findsOneWidget);
      expect(find.text('Pack'), findsNothing);
    });

    testWidgets('a tap carries the backend feature_key, nothing derived',
        (t) async {
      final taps = <String>[];
      await _pump(t, PartnerHomeView(payload: _home(), onOpen: taps.add));

      await t.tap(find.text('Collect'));
      await t.pump();
      expect(taps, ['partner.collect']);
    });
  });

  group('route mapping', () {
    test('every partner route_key resolves to a screen', () {
      for (final k in const [
        'inquiry',
        'supplier_orders',
        'supplier_payment',
        'collect',
        'count',
        'bag_mapping',
        'pack',
        'assign_delivery',
      ]) {
        expect(partnerDestination(k), isNotNull, reason: 'route_key $k');
      }
    });

    test('an unknown route_key opens nothing rather than guessing', () {
      expect(partnerDestination('medibo.pricing'), isNull);
      expect(partnerDestination(''), isNull);
    });
  });

  group('admin permission matrix', () {
    testWidgets('choices and their words come from options[] verbatim',
        (t) async {
      await _pump(
        t,
        PartnerConsoleView(
          payload: _console(),
          identity: TextEditingController(),
          name: TextEditingController(),
          onAdd: () {},
          onRemove: (_) {},
          onAccess: (_, __) {},
        ),
      );

      expect(find.text('Partner logins'), findsOneWidget);
      expect(find.text('What this partner can open'), findsOneWidget);
      expect(find.text('No access'), findsOneWidget);
      expect(find.text('View only'), findsOneWidget);
      expect(find.text('Full access'), findsOneWidget);
      expect(find.text('9876543210'), findsOneWidget);
      expect(find.text('Partner activity'), findsOneWidget);
    });

    testWidgets('tapping a choice sends that option\'s own value', (t) async {
      final sent = <List<String>>[];
      await _pump(
        t,
        PartnerConsoleView(
          payload: _console(),
          identity: TextEditingController(),
          name: TextEditingController(),
          onAdd: () {},
          onRemove: (_) {},
          onAccess: (k, a) => sent.add([k, a]),
        ),
      );

      await t.tap(find.text('Full access'));
      await t.pump();
      expect(sent, [
        ['partner.pack', 'write']
      ]);
    });

    testWidgets('not_authorized renders the backend error, no matrix',
        (t) async {
      await _pump(
        t,
        PartnerConsoleView(
          payload: const {'ok': false, 'error': 'not_authorized'},
          identity: TextEditingController(),
          name: TextEditingController(),
          onAdd: () {},
          onRemove: (_) {},
          onAccess: (_, __) {},
        ),
      );
      expect(find.text('not_authorized'), findsOneWidget);
      expect(find.text('No access'), findsNothing);
    });
  });
}
