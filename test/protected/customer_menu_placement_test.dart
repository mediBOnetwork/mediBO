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
import 'package:pharma_b2b/widgets/customer_surface_widgets.dart';
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
            'badge': '4',
          },
        ],
        // ONE list for the home strip, in the backend's order — the chip is
        // NOT first because Dart concatenated two placements, it is first
        // because sort_order said so.
        'home_strip': [
          {
            'feature_key': 'cust.wishlist',
            'label': 'My Wishlist',
            'icon_key': 'favorite',
            'route_key': 'cust_wishlist',
            'render_kind': 'chip',
            'badge': '4',
          },
          {
            'feature_key': 'cust.rewards',
            'label': 'Rewards',
            'icon_key': 'stars',
            'route_key': 'cust_rewards',
            'render_kind': 'badge',
            'badge': '250 points',
          },
        ],
        'orders_section': [
          {
            'feature_key': 'cust.rewards',
            'label': 'Rewards',
            'icon_key': 'stars',
            'route_key': 'cust_rewards',
            'render_kind': 'section',
            'badge': '250 points',
            'lines': ['250 points', 'Silver', 'Your code MB52ED6A'],
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

    testWidgets('an empty payload draws no MENU ROWS', (tester) async {
      // The sign-out fallback below is deliberate and is tested there; what
      // must never appear is a row this build invented for itself.
      CustomerSurfaces.value.value = const {};
      await tester.pumpWidget(_host(const ProfileAccountMenu()));
      expect(find.text('Edit my details'), findsNothing);
      expect(find.text('Delivery addresses'), findsNothing);
      expect(find.text('Staff logins'), findsNothing);
      expect(find.byType(DeleteAccountSection), findsNothing);
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

  group('a signed-in account can ALWAYS sign out', () {
    // HOSTILE QA ROUND 1, BLOCKER 1 AND 2 — the class of bug this retires.
    //
    // #745 turned Logout from an unconditional button into a placement row.
    // That made the one affordance a wrong-account login needs depend on two
    // things it never depended on before: having a pharmacy_profiles row, and
    // one RPC answering. A visitor who signed in with the wrong login landed on
    // the registration form with no way back out on a phone, and a registered
    // pharmacy on a flaky connection got an empty Account group with no error
    // and no retry.
    //
    // Signing out is an identity action, not a pharmacy feature. The backend
    // still owns its WORDS (ui_copy) and its ORDER when it sends one, but its
    // PRESENCE for a signed-in account is not negotiable.

    testWidgets('an empty payload still offers Logout', (tester) async {
      CustomerSurfaces.value.value = const {};
      await tester.pumpWidget(_host(const ProfileAccountMenu()));
      expect(find.byType(OutlinedButton), findsOneWidget,
          reason: 'a signed-in account with no payload cannot sign out');
    });

    testWidgets('a payload that describes no Logout still offers one',
        (tester) async {
      // Exactly the shape customer_surfaces() returns for a signed-in caller
      // whose role the customer menu does not admit.
      CustomerSurfaces.value.value = const {
        'ok': true,
        'has_account': false,
        'placements': {'profile_account': []},
      };
      await tester.pumpWidget(_host(const ProfileAccountMenu()));
      expect(find.byType(OutlinedButton), findsOneWidget);
    });

    testWidgets('the backend\'s own Logout is never duplicated',
        (tester) async {
      CustomerSurfaces.value.value = _payload();
      await tester.pumpWidget(_host(const ProfileAccountMenu()));
      expect(find.text('Logout'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsOneWidget);
    });

    testWidgets('View As still offers neither — it is not your session',
        (tester) async {
      CustomerSurfaces.value.value = const {};
      await tester
          .pumpWidget(_host(const ProfileAccountMenu(interactive: false)));
      expect(find.byType(OutlinedButton), findsNothing);
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

  group('the surfaces render the entry\'s own strings', () {
    // Round 1 QA, finding 4: the widgets switched on 'cust.wishlist' /
    // 'cust.rewards' to pick what to print beside a label, so a placement
    // UPDATE — the zero-deploy move this change promises — would have printed
    // "My Wishlist" over the rewards lines. Every trailing number and every
    // body line is the ENTRY's own now.

    testWidgets('the rewards card prints the entry\'s lines, in order',
        (tester) async {
      CustomerSurfaces.value.value = _payload();
      await tester.pumpWidget(_host(const CustomerRewardsSection()));
      expect(find.text('Rewards'), findsOneWidget);
      for (final line in const ['250 points', 'Silver', 'Your code MB52ED6A']) {
        expect(find.text(line), findsOneWidget, reason: '$line is missing');
      }
      final first = tester.getTopLeft(find.text('250 points')).dy;
      final last = tester.getTopLeft(find.text('Your code MB52ED6A')).dy;
      expect(first, lessThan(last));
    });

    testWidgets('a moved feature carries its own badge with it',
        (tester) async {
      // The placement UPDATE the old code got wrong: put the rewards entry on
      // the app bar and it must print the REWARDS badge, not the wishlist's.
      final p = _payload();
      (p['placements'] as Map)['catalogue_appbar'] = [
        {
          'feature_key': 'cust.rewards',
          'label': 'Rewards',
          'icon_key': 'stars',
          'route_key': 'cust_rewards',
          'render_kind': 'icon',
          'badge': '250 points',
        },
      ];
      CustomerSurfaces.value.value = p;
      await tester.pumpWidget(_host(const CustomerAppBarActions()));
      expect(find.text('250 points'), findsOneWidget);
      expect(find.text('4'), findsNothing);
    });

    testWidgets('an entry with no badge shows none', (tester) async {
      final p = _payload();
      (p['placements'] as Map)['catalogue_appbar'] = [
        {
          'feature_key': 'cust.wishlist',
          'label': 'My Wishlist',
          'icon_key': 'favorite',
          'route_key': 'cust_wishlist',
          'render_kind': 'icon',
          'badge': '',
        },
      ];
      CustomerSurfaces.value.value = p;
      await tester.pumpWidget(_host(const CustomerAppBarActions()));
      expect(find.text('4'), findsNothing);
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
      // The strip is ONE ordered list. Two placements concatenated in Dart
      // would make this order un-editable from the backend.
      expect(CustomerSurfaces.itemsFor(p, 'home_strip').map((e) => e['label']),
          ['My Wishlist', 'Rewards']);
      // A surface the payload never mentioned is empty, not an error.
      expect(CustomerSurfaces.itemsFor(p, 'a_surface_from_next_year'), isEmpty);
      expect(CustomerSurfaces.itemsFor(const {}, 'home_strip'), isEmpty);
    });

    test('the widgets carry no feature list of their own', () {
      // The one Dart-side map that may exist is route_key -> screen class, and
      // it lives in customerMenuScreen. Everything else — labels, icons,
      // order, audience, surface — must come from the payload, so no widget
      // file may name a feature key.
      for (final path in const [
        'lib/widgets/customer_surface_widgets.dart',
        'lib/screens/profile_screen.dart',
        // Round 2 QA, NEW-3: the file that actually renders the Account group
        // and holds the sign-out fallback was the one file this scan skipped.
        'lib/screens/customer/profile_account_menu.dart',
      ]) {
        final src = File(path).readAsStringSync();
        final code = src
            .split('\n')
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        // Round 1 QA: this used to assert on two keys the files never held,
        // while the widgets really did switch on 'cust.wishlist' and
        // 'cust.rewards' to decide what to print beside a label. Scan for
        // EVERY registered key, so the test cannot pass by naming the wrong
        // ones — the failure it exists to catch is a placement UPDATE
        // rendering "My Wishlist" over the rewards lines.
        for (final key in const [
          'cust.profile_edit',
          'cust.address_book',
          'cust.staff_logins',
          'cust.logout',
          'cust.delete_account',
          'cust.wishlist',
          'cust.rewards',
          'cust.loyalty_admin',
        ]) {
          expect(code.contains("'$key'"), isFalse,
              reason: '$path names $key — the payload decides, not Dart');
        }
      }
    });
  });

  group('the device cache belongs to ONE account', () {
    // HOSTILE QA ROUND 2, NEW-1 — the leak the offline fix introduced.
    //
    // The menu is cached on the device so a failed refresh cannot empty the
    // Account group. That cache is account data: a customer code, a payment
    // term, a points balance, a referral code, a wishlist count. Keyed on a
    // constant and validated only on ok:true, it survived a sign-out in
    // localStorage and was painted to the NEXT login — on a shared pharmacy
    // counter, which is the machine this app ships "Staff logins" for.
    //
    // Two properties, both scanned in the source because SharedPreferences
    // needs a platform channel this suite deliberately does not have: the
    // stored payload carries its owner and is dropped on a mismatch, and the
    // sign-out path drops it with the rest of the account state.

    test('the cached payload is stamped with, and checked against, its owner',
        () {
      final src =
          File('lib/services/customer_surfaces.dart').readAsStringSync();
      expect(src.contains('_ownerKey'), isTrue,
          reason: 'the cache no longer records whose menu it is');
      expect(src.contains('currentUser?.id'), isTrue,
          reason: 'the cache is no longer compared against the signed-in uid');
      expect(RegExp(r'static\s+Future<void>\s+clear\(').hasMatch(src), isTrue,
          reason: 'CustomerSurfaces.clear() is the only way to forget a menu');
      expect(src.contains('remove(_cacheKey)'), isTrue,
          reason: 'clear() must delete the stored payload, not just the '
              'in-memory notifier');
    });

    test('signing out drops it with the rest of the account state', () {
      final src = File('lib/user_state.dart').readAsStringSync();
      final start = src.indexOf('void _clearAccountState()');
      expect(start, greaterThan(0),
          reason: 'the hard reset must stay in one place');
      final end = src.indexOf('\n  }', start);
      expect(end, greaterThan(start));
      expect(src.substring(start, end).contains('CustomerSurfaces.clear()'),
          isTrue,
          reason: 'the customer menu cache outlives the credential that owns '
              'it — the exact half-cleared session this method exists to '
              'prevent');
    });
  });

  group('a failed refresh never empties the Account group', () {
    // HOSTILE QA ROUND 1, BLOCKER 2 — the class of bug this retires, and the
    // journey qa-745-426 asserts.
    //
    // #745 made the WHOLE Account group payload-driven. That handed one RPC
    // the power to blank a signed-in pharmacy's profile: customer_surfaces()
    // times out on a shop's flaky connection, the notifier goes empty, and the
    // customer is left on a screen with no rows, no error and nothing to tap
    // to try again. Before #745 those rows were unconditional widgets and no
    // network call could take them away.
    //
    // The rule that replaced it: the last good answer is kept on the device and
    // repainted before the network says anything, and a BAD answer is never
    // allowed to replace a good one. The customer is told what they are looking
    // at in the backend's own words — a silent stale menu is its own defect.

    test('a non-ok answer is discarded before it can reach the notifier', () {
      final src =
          File('lib/services/customer_surfaces.dart').readAsStringSync();
      final start = src.indexOf('static Future<void> load()');
      expect(start, greaterThan(0), reason: 'load() must stay in one place');
      final body = src.substring(start, src.indexOf('\n  }', start));

      // Every failure path leaves early, BEFORE the single assignment.
      final assign = body.indexOf('value.value = p');
      expect(assign, greaterThan(0),
          reason: 'load() no longer publishes the payload it fetched');
      for (final guard in const [
        "if (map is! Map) return;",
        "if (p['ok'] != true) return;",
      ]) {
        final at = body.indexOf(guard);
        expect(at, greaterThan(0), reason: 'the guard `$guard` is gone — a '
            'bad answer can now replace a good one');
        expect(at, lessThan(assign),
            reason: '`$guard` must run BEFORE the notifier is written');
      }

      // The notifier is written exactly once, and never from the catch: a
      // throwing RPC must leave what is already on screen alone.
      expect('value.value = '.allMatches(body).length, 1,
          reason: 'load() writes the notifier more than once — one of those '
              'paths is how an empty menu gets published');
      final katch = body.substring(body.indexOf('} catch'));
      expect(katch.contains('value.value'), isFalse,
          reason: 'a failed fetch clears the menu it could not refresh');
      expect(katch.contains('clear()'), isFalse,
          reason: 'a failed fetch forgets the cached menu it could not '
              'refresh — the exact blocker, one layer down');
    });

    test('the device cache is painted BEFORE the network is asked', () {
      final src =
          File('lib/services/customer_surfaces.dart').readAsStringSync();
      final start = src.indexOf('static void ensureLoaded()');
      expect(start, greaterThan(0));
      final body = src.substring(start, src.indexOf('\n  }', start));
      final restore = body.indexOf('_restore()');
      final load = body.indexOf('load();');
      expect(restore, greaterThan(0),
          reason: 'boot no longer repaints the last good menu, so a slow or '
              'failed first fetch shows an empty Account group');
      expect(restore, lessThan(load),
          reason: 'the cache must be drawn first — restoring AFTER the fetch '
              'is the blank frame this fix exists to remove');
    });

    testWidgets('the cached menu is drawn in full, and says so', (tester) async {
      // isLive is false until a fetch of THIS session lands, which is exactly
      // the state a customer is in when the RPC failed and the cache is what
      // is on screen.
      final p = _payload();
      p['offline_note'] = 'Showing your last saved menu.';
      CustomerSurfaces.value.value = p;
      await tester.pumpWidget(_host(const ProfileAccountMenu()));

      expect(CustomerSurfaces.isLive, isFalse);
      // The group is INTACT — this is the blocker.
      expect(find.text('Edit my details'), findsOneWidget);
      expect(find.text('Delivery addresses'), findsOneWidget);
      expect(find.text('Staff logins'), findsOneWidget);
      expect(find.text('Logout'), findsOneWidget);
      expect(find.byType(DeleteAccountSection), findsOneWidget);
      // And the customer is told, in the BACKEND's sentence.
      expect(find.text('Showing your last saved menu.'), findsOneWidget);
    });

    testWidgets('no note is invented when the payload did not send one',
        (tester) async {
      CustomerSurfaces.value.value = _payload(); // carries no offline_note
      await tester.pumpWidget(_host(const ProfileAccountMenu()));
      expect(find.text('Edit my details'), findsOneWidget);
      expect(find.textContaining('last saved'), findsNothing,
          reason: 'the staleness sentence is ui_copy, not a Dart literal');
    });

    test('the words of the offline state are the backend\'s', () {
      final src =
          File('lib/screens/customer/profile_account_menu.dart')
              .readAsStringSync();
      expect(src.contains("payload['offline_note']"), isTrue,
          reason: 'the staleness sentence must come from the payload');
      expect(src.contains('Showing your last saved'), isFalse,
          reason: 'the sentence was hardcoded into Dart — changing it is an '
              'UPDATE to ui_copy, never a deploy');
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
