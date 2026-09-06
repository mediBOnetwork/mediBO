// test/protected/deep_link_routes_test.dart — CMD #757
//
// THE BUG CLASS: a destination ships, the registry advertises a link to it,
// and the link lands on "This one is not in your app yet — update the app and
// try again". Nothing is red. Every RPC works. The screen is one tap away in
// the bar. Only the LINK is dead, so only the people who arrive by link — a
// push notification, a WhatsApp button, an SLA digest, a pasted URL — ever see
// it, and they see it as "the app is broken".
//
// #690 fixed it once for `exceptions`. #688 shipped the Ops board with
// `deep_link=/admin/go/ops_board` in feature_registry and could not fix it for
// `ops_board`, because home_shell.dart was leased for that whole build. This
// file is the guard so it is not fixed a third time.
//
// WHAT IS ACTUALLY BEING PINNED. The route -> stage pairing is the BACKEND's
// (`access_boot().routes[].stage`, derived from feature_registry), and on a
// resolved matrix it is the only source — a fixture below deliberately pairs
// `ops_board` with the WRONG stage and the code must obey it, so a Dart map
// that "knows" the answer fails here. The cold-boot map is the FALLBACK for
// the seconds before that answer arrives, and it is the part that was missing:
// shellWhenAccessResolved gives up after five seconds and opens the route
// anyway, which on a cold app on mobile data is the normal case for exactly
// the alert-shaped destinations that carry deep links.
//
// Pure: no network, no Supabase, no widgets pumped. The post-frame callback
// that calls AdminFulfillmentScreen.openStage is scheduled and never run, so
// nothing here touches a screen.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/nav_registry_view.dart';
import 'package:pharma_b2b/screens/shell/shell_extra_routes.dart';
import 'package:pharma_b2b/services/access.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// An `access_boot()` answer, in the shape the RPC actually sends.
Map<String, dynamic> _boot({required String opsBoardStage}) => {
      'ok': true,
      'role': 'admin',
      'is_super': false,
      'denied_view_message': 'You do not have access to this.',
      'features': {
        'partner.ops_board': {'v': true, 'w': false},
        'fulfill.exceptions': {'v': true, 'w': false},
      },
      'routes': {
        'ops_board': {
          'feature': 'partner.ops_board',
          'label': 'Ops board',
          'stage': opsBoardStage,
          'v': true,
          'w': false,
        },
        'exceptions': {
          'feature': 'fulfill.exceptions',
          'label': 'Exceptions',
          'stage': 'exceptions',
          'v': true,
          'w': false,
        },
        'companies': {
          'feature': 'catalogue.companies',
          'label': 'Companies',
          'stage': '',
          'v': true,
          'w': false,
        },
      },
      'tabs': const {},
    };

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    RenderLog.flushEnabled = false;
  });

  tearDown(() {
    Access.instance.setMatrix(AccessMatrix.unresolved);
    PendingAdminNav.route = null;
    PendingAdminNav.seed = null;
  });

  group('CMD #757 — /admin/go/ops_board is a link, not a dead end', () {
    test('the URL parses to the registry route key, with no subject', () {
      // feature_registry stores this exact string as fulfill.ops_board's
      // deep_link, so the parser and the registry must agree on the key.
      final link = AdminGoLink.parse('/admin/go/ops_board');
      expect(link, isNotNull);
      expect(link!.route, 'ops_board');
      expect(link.seed, isNull,
          reason: 'the ops board is a whole destination; a welded-on subject '
              'is the #421 bug and would make the key unrecognisable');
    });

    test('a parked ops_board link survives the wait for the admin check', () {
      PendingAdminNav.park('ops_board', null);
      expect(PendingAdminNav.take(), 'ops_board');
    });

    test('a RESOLVED matrix opens Fulfill on the backend\'s stage', () {
      Access.instance.setMatrix(
          AccessMatrix.fromJson(_boot(opsBoardStage: 'ops_board')));
      var page = -1;
      final took = shellOpenFulfillStage('ops_board', null, (i) => page = i);
      expect(took, isTrue,
          reason: 'false means the route falls through to the switch, whose '
              'default prints home_shell.route_unavailable');
      expect(page, 10, reason: 'Fulfill is page 10 of the shell');
    });

    test('the STAGE is the payload\'s, never re-derived from the key', () {
      // Deliberately wrong on purpose: the backend pairs ops_board with the
      // warehouse stage here. A shell that "knows" ops_board is its own stage
      // — a Dart map consulted on a resolved matrix — cannot tell the two
      // fixtures apart, and moving a screen would need a deploy again.
      Access.instance.setMatrix(
          AccessMatrix.fromJson(_boot(opsBoardStage: 'warehouse')));
      expect(Access.instance.fulfillStageForRoute('ops_board'), 'warehouse');
      var page = -1;
      expect(shellOpenFulfillStage('ops_board', null, (i) => page = i), isTrue);
      expect(page, 10);
    });

    test('an UNRESOLVED matrix still opens it — the cold boot', () {
      // The whole of CMD #757. shellWhenAccessResolved gives up after five
      // seconds and calls the nav anyway, so a slow or failed access_boot()
      // used to drop /admin/go/ops_board into the switch's default. On a cold
      // app on mobile data — how a notification is opened — that was the
      // NORMAL path for this link, not an edge case.
      expect(Access.instance.matrix.resolved, isFalse);
      var page = -1;
      final took = shellOpenFulfillStage('ops_board', null, (i) => page = i);
      expect(took, isTrue,
          reason: 'ops_board is missing from the cold-boot map again — the '
              'link now prints "not in your app yet" for a stage that is '
              'sitting in the bar');
      expect(page, 10);
    });

    test('exceptions keeps its own cold boot (#690 is not undone)', () {
      var page = -1;
      expect(shellOpenFulfillStage('exceptions', null, (i) => page = i),
          isTrue);
      expect(page, 10);
    });

    test('a route that is not a stage is left alone, cold or warm', () {
      var page = -1;
      expect(shellOpenFulfillStage('companies', null, (i) => page = i), isFalse,
          reason: 'the cold-boot map must stay a short list of alert '
              'destinations, not a second route table');
      expect(page, -1, reason: 'Fulfill must not open over an unrelated route');

      Access.instance.setMatrix(
          AccessMatrix.fromJson(_boot(opsBoardStage: 'ops_board')));
      expect(shellOpenFulfillStage('companies', null, (i) => page = i), isFalse);
      expect(page, -1);
    });
  });

  group('CMD #757 — the shell still makes the call', () {
    final shell = File('lib/screens/home_shell.dart').readAsStringSync();

    test('shellOpenFulfillStage runs BEFORE the route switch', () {
      final hop = shell.indexOf('shellOpenFulfillStage(');
      final sw = shell.indexOf('switch (route) {');
      expect(hop, greaterThan(-1),
          reason: 'the shell stopped asking the shard — every fulfill deep '
              'link is dead again');
      expect(sw, greaterThan(-1));
      expect(hop, lessThan(sw),
          reason: 'after the switch, default: has already refused the route');
    });

    test('an unknown route is reported, not swallowed', () {
      // The one line that turned this class of bug from invisible into
      // findable: a link that lands nowhere writes its key to the render log.
      expect(shell, contains("RenderLog.write('c536_route_unknown', route)"));
    });
  });
}
