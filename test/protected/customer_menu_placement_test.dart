// PROTECTED — CHANGE #745.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes where a customer feature lives, never to make an
// unrelated change go green.
//
// THE BUG THIS RETIRES, IN ITS OWN WORDS
//
// Om, on My Profile (3 Sep): "the profile dropdown is a dumping ground". My
// Wishlist, Rewards and "Deliver with mediBO" sat next to Edit my details and
// Logout — a wishlist is shopping, rewards are purchases, and a pharmacy
// buying trade stock is not a rider applicant. Each one was a hardcoded
// `if (...) _EntryCard()` line in profile_screen.dart, so WHERE a customer
// feature lives was a Dart decision and moving one meant a deploy.
//
// So this file does not test three menu rows. It tests the INVARIANT that
// replaced them:
//
//   The customer's menu is `customer_surfaces()`. Every entry, its order, its
//   words, its icon and the SURFACE it appears on arrive in the payload; the
//   widgets contain no feature list and no feature-key switch. A feature moves
//   between surfaces with an UPDATE to customer_feature_placement.
//
// It also pins the two halves Om named specifically: nothing on the profile
// surface may carry the wishlist or the rewards key, and the string
// "Deliver with mediBO" must not exist anywhere under lib/ — a row that is
// merely hidden could come back with a flag.
//
// No network, no Supabase, no goldens: the payload is a map, and the removal
// is a source scan.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/customer/profile_account_menu.dart';
import 'package:pharma_b2b/services/customer_surfaces.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/delete_account_section.dart';

/// One `customer_surfaces()` answer. Deliberately NOT in label order and
/// deliberately NOT in feature-key order, so a client-side sort fails here
/// instead of in front of a pharmacy.
Map<String, dynamic> _payload() => {
      'ok': true,
      'role': 'customer',
      'has_account': true,
      'account_title': 'Account',
      'placements': {
        'profile_account': [
          {
            'feature_key': 'cust.profile_edit',
            'label': 'Edit my details',
            'icon_key': 'person',
            'route_key': 'cust_profile_edit',
            'render_kind': 'row',
          },
          {
            'feature_key': 'cust.address_book',
            'label': 'Delivery addresses',
            'icon_key': 'map',
            'route_key': 'cust_addresses',
            'render_kind': 'row',
          },
          {
            'feature_key': 'cust.staff_logins',
            'label': 'Staff logins',
            'icon_key': 'badge',
            'route_key': 'cust_staff_logins',
            'render_kind': 'row',
          },
          {
            'feature_key': 'cust.logout',
            'label': 'Logout',
            'icon_key': 'logout',
            'route_key': 'cust_logout',
            'render_kind': 'action',
          },
          {
            'feature_key': 'cust.delete_account',
            'label': 'Delete account or data',
            'icon_key': 'person_remove',
            'route_key': 'cust_delete_account',
            'render_kind': 'danger_zone',
          },
        ],
        'catalogue_appbar': [
          {
            'feature_key': 'cust.wishlist',
            'label': 'My Wishlist',
            'icon_key': 'favorite',
            'route_key': 'cust_wishlist',
            'render_kind': 'icon',
          },
        ],
        'home_chip': [
          {
            'feature_key': 'cust.wishlist',
            'label': 'My Wishlist',
            'icon_key': 'favorite',
            'route_key': 'cust_wishlist',
            'render_kind': 'chip',
          },
        ],
        'orders_section': [
          {
            'feature_key': 'cust.rewards',
            'label': 'Rewards',
            'icon_key': 'stars',
            'route_key': 'cust_rewards',
            'render_kind': 'section',
          },
        ],
        'home_badge': [
          {
            'feature_key': 'cust.rewards',
            'label': 'Rewards',
            'icon_key': 'stars',
            'route_key': 'cust_rewards',
            'render_kind': 'badge',
          },
        ],
      },
      'account_setup': {
        'title': 'Account setup',
        'rows': [
          {
            'key': 'payment_term',
            'label': 'Payment term',
            'value': 'Advance Payment',
            'has': true,
            'icon_key': 'payments',
          },
          {
            'key': 'customer_code',
            'label': 'Customer code',
            'value': 'Not set yet',
            'has': false,
            'icon_key': 'rule',
          },
        ],
      },
    };

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => CustomerSurfaces.value.value = const {});

  group('the profile menu is the backend\'s list', () {
    testWidgets('renders every profile_account entry, in payload order',
        (tester) async {
      CustomerSurfaces.value.value = _payload();
      await tester.pumpWidget(_host(const ProfileAccountMenu()));

      for (final label in const [
        'Edit my details',
        'Delivery addresses',
        'Staff logins',
        'Logout',
      ]) {
        expect(find.text(label), findsOneWidget, reason: '$label is missing');
      }
      // The danger zone keeps its OWN backend copy (DeleteAccountSection reads
      // ui_copy for every word of the confirm flow), so the placement row is
      // proven by the widget being built, not by its label being reprinted.
      expect(find.byType(DeleteAccountSection), findsOneWidget);

      // Order is the payload's, not alphabetical and not by feature key.
      final edit = tester.getTopLeft(find.text('Edit my details')).dy;
      final addr = tester.getTopLeft(find.text('Delivery addresses')).dy;
      final staff = tester.getTopLeft(find.text('Staff logins')).dy;
      final logout = tester.getTopLeft(find.text('Logout')).dy;
      expect(edit, lessThan(addr));
      expect(addr, lessThan(staff));
      expect(staff, lessThan(logout));
    });

    testWidgets('Wishlist and Rewards are NOT on the profile surface',
        (tester) async {
      CustomerSurfaces.value.value = _payload();
      await tester.pumpWidget(_host(const ProfileAccountMenu()));
      expect(find.text('My Wishlist'), findsNothing);
      expect(find.text('Rewards'), findsNothing);
    });

    testWidgets('an entry this build cannot open is skipped, never thrown',
        (tester) async {
      final p = _payload();
      (p['placements'] as Map)['profile_account'] = [
        {
          'feature_key': 'cust.future_thing',
          'label': 'A screen from next month',
          'icon_key': 'rule',
          'route_key': 'cust_not_built_yet',
          'render_kind': 'row',
        },
      ];
      CustomerSurfaces.value.value = p;
      await tester.pumpWidget(_host(const ProfileAccountMenu()));
      expect(tester.takeException(), isNull);
      expect(find.text('A screen from next month'), findsNothing);
    });

    testWidgets('an empty payload draws nothing at all', (tester) async {
      CustomerSurfaces.value.value = const {};
      await tester.pumpWidget(_host(const ProfileAccountMenu()));
      expect(find.byType(Card), findsNothing);
      expect(find.text('Logout'), findsNothing);
    });

    testWidgets('View As renders the rows but never the logout or delete zone',
        (tester) async {
      CustomerSurfaces.value.value = _payload();
      await tester
          .pumpWidget(_host(const ProfileAccountMenu(interactive: false)));
      expect(find.text('Edit my details'), findsOneWidget);
      expect(find.text('Logout'), findsNothing);
      expect(find.byType(DeleteAccountSection), findsNothing);
    });
  });

  group('Account setup prints the backend\'s values, never an em-dash', () {
    testWidgets('both rows render label + value verbatim', (tester) async {
      CustomerSurfaces.value.value = _payload();
      await tester.pumpWidget(_host(const AccountSetupCard()));
      expect(find.text('Account setup'), findsOneWidget);
      expect(find.text('Payment term'), findsOneWidget);
      expect(find.text('Advance Payment'), findsOneWidget);
      expect(find.text('Customer code'), findsOneWidget);
      // Absence is the BACKEND's word. The em-dash this screen used to print
      // was written in Dart over a NULL column — that is the defect.
      expect(find.text('Not set yet'), findsOneWidget);
      expect(find.text('—'), findsNothing);
    });

    testWidgets('no rows means no card', (tester) async {
      CustomerSurfaces.value.value = const {
        'ok': true,
        'account_setup': {'title': 'Account setup', 'rows': []},
      };
      await tester.pumpWidget(_host(const AccountSetupCard()));
      expect(find.text('Account setup'), findsNothing);
    });
  });

  group('placements are read, never guessed', () {
    test('itemsFor returns exactly what the payload placed there', () {
      final p = _payload();
      expect(
          CustomerSurfaces.itemsFor(p, 'catalogue_appbar')
              .map((e) => e['feature_key']),
          ['cust.wishlist']);
      expect(
          CustomerSurfaces.itemsFor(p, 'orders_section')
              .map((e) => e['feature_key']),
          ['cust.rewards']);
      // A surface the payload never mentioned is empty, not an error.
      expect(CustomerSurfaces.itemsFor(p, 'a_surface_from_next_year'), isEmpty);
      expect(CustomerSurfaces.itemsFor(const {}, 'home_chip'), isEmpty);
    });

    test('the widgets carry no feature list of their own', () {
      // The one Dart-side map that may exist is route_key -> screen class, and
      // it lives in customerMenuScreen. Everything else — labels, icons,
      // order, audience, surface — must come from the payload, so no widget
      // file may name a feature key.
      for (final path in const [
        'lib/widgets/customer_surface_widgets.dart',
        'lib/screens/profile_screen.dart',
      ]) {
        final src = File(path).readAsStringSync();
        final code = src
            .split('\n')
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        expect(code.contains("'cust.profile_edit'"), isFalse,
            reason: '$path names a feature key — the payload decides, not Dart');
        expect(code.contains("'cust.staff_logins'"), isFalse, reason: path);
      }
    });
  });

  group('the profile is reachable by URL, not only by tapping the avatar', () {
    test('/admin/go/profile is self-gated so a pharmacy can open its own', () {
      // CHANGE #745. The profile route existed and had a case in the shell,
      // but it was missing from selfGatedRoutes — the same shape that parked
      // 'refill' (#432/#440) and 'pharmacy_gst' for every pharmacy, who is not
      // an admin, and landed the link on the storefront in silence. The screen
      // resolves the caller through my_session()/my_profile_row() and prints
      // the backend's own unregistered state for anyone else, so the entry
      // grants a door and never a permission.
      final src = File('lib/screens/home_shell.dart').readAsStringSync();
      final start = src.indexOf('static const Set<String> selfGatedRoutes');
      expect(start, greaterThan(0),
          reason: 'selfGatedRoutes must stay on HomeShell where links read it');
      final end = src.indexOf('};', start);
      expect(end, greaterThan(start));
      final set = src.substring(start, end);
      expect(set.contains("'profile'"), isTrue,
          reason: '/admin/go/profile is parked for a pharmacy again');
      // And the route must actually open something.
      expect(src.contains("case 'profile':"), isTrue,
          reason: 'the shell no longer routes profile — the door opens onto '
              'the backend-worded default branch');
    });
  });

  group('Deliver with mediBO left the customer app', () {
    test('the phrase exists nowhere under lib/', () {
      final offenders = <String>[];
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final code = e
            .readAsStringSync()
            .split('\n')
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        if (code.contains('Deliver with')) offenders.add(e.path);
      }
      expect(offenders, isEmpty,
          reason: 'rider signup is not a pharmacy customer feature; its door '
              'is /delivery-register for the public site and the delivery app');
    });

    test('the customer menu admits no operator role', () {
      // Spec item 5: anything admin/partner/supplier-only must be hidden from
      // role customer. The audit is the registry itself — a customer_menu row
      // may admit `customer` and `super_admin` (the operator viewing their own
      // pharmacy) and nothing else. An admin tool that wandered onto this
      // surface fails here rather than in front of a pharmacy.
      final dir = Directory('supabase/migrations');
      final offenders = <String>[];
      var seen = 0;
      final roleList = RegExp(r"array\[([^\]]*)\], 'medibo'");
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.sql')) continue;
        final sql = f.readAsStringSync();
        if (!sql.contains("'customer_menu'")) continue;
        for (final m in roleList.allMatches(sql)) {
          seen++;
          final roles = m
              .group(1)!
              .split(',')
              .map((r) => r.trim().replaceAll("'", ''))
              .where((r) => r.isNotEmpty);
          for (final r in roles) {
            if (r != 'customer' && r != 'super_admin') {
              offenders.add('${f.path}: $r');
            }
          }
        }
      }
      expect(offenders, isEmpty);
      // Never vacuous: the scan must actually have read the registry rows.
      expect(seen, greaterThanOrEqualTo(7),
          reason: 'the role-list scan matched nothing — it stopped auditing');
    });

    test('no migration registers it onto the customer menu surface', () {
      final dir = Directory('supabase/migrations');
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.sql')) continue;
        final sql = f.readAsStringSync();
        if (!sql.contains("'customer_menu'")) continue;
        expect(sql.contains('deliver_with'), isFalse,
            reason: '${f.path} puts rider signup back on the customer menu');
      }
    });
  });
}
