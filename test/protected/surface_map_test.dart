// PROTECTED — CHANGE #570.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how the surface map renders.
//
// WHAT THIS HOLDS DOWN, and why it is worth a protected file:
//
// The surface map is the screen Om opens to answer "who can actually see this
// feature". The moment any part of that answer is computed in Dart, the screen
// stops being evidence and becomes a second opinion — and the whole point of
// the audit is that there is exactly ONE opinion, the backend's.
//
//   1. The truth table is printed VERBATIM and in PAYLOAD ORDER. Feature keys,
//      the audience it was built for, the audience that reaches it, its surface
//      and its door are all backend strings; the screen never re-sorts (a
//      registry that ordered itself wrongly must be visible, not hidden).
//   2. The four row captions come from the payload's `labels` block. "Built
//      for" is not a Dart literal, so renaming it is an UPDATE, not a deploy.
//   3. Zero drift renders the BACKEND's success sentence — the clean state is
//      the whole product, so it is not a bare "nothing here".
//   4. Drift renders the backend's own heading and each problem's own label,
//      detail and tone. Dart never counts the list and never pluralises it:
//      the fixture says "1 mapping problem" for a two-row list and the screen
//      prints that, because the day those disagree the backend is what changed.
//   5. A tone this build has never heard of renders neutral instead of
//      throwing — a payload written after this build shipped is forward
//      compatible.
//   6. `ok:false` is the backend refusing the reader, and its own `message` is
//      what appears. No Dart fallback wording, no exception.
//
// No network, no Supabase, no goldens — the screen is pumped through its `rpc`
// test seam against fixtures.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/surface_map_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _clean() => {
      'ok': true,
      'title': 'Surface map',
      'subtitle':
          'Every feature, the audience it was registered for, and the audience that can reach it.',
      'drift': const [],
      'drift_count': 0,
      'clean_label':
          'No mapping drift — every feature reaches exactly its own audience.',
      'drift_heading': '0 mapping problems',
      'labels': const {
        'intended': 'Built for',
        'actual': 'Reaches',
        'surface': 'Surface',
        'route': 'Door',
      },
      'summary': const [
        {'label': 'Features', 'value_label': '133', 'tone': 'neutral'},
        {'label': 'Drift', 'value_label': '0', 'tone': 'success'},
      ],
      'sections': const [
        {
          'heading': 'Feature registry — 133 active features',
          'empty_hint': 'The registry is empty.',
          'rows': [
            // Deliberately NOT alphabetical: payload order is the contract.
            {
              'feature_key': 'shop.pos',
              'label': 'Counter POS',
              'surface_label': 'Pharmacy My Shop',
              'intended_label': 'customer, super_admin',
              'actual_label': 'customer, super_admin',
              'route_label': 'home_shell · pos',
              'tone': 'success',
            },
            {
              'feature_key': 'admin.manage_admins',
              'label': 'Manage admins',
              'surface_label': 'Admin dashboard',
              'intended_label': 'super_admin',
              'actual_label': 'super_admin',
              'route_label': 'home_shell · manage_admins',
              'tone': 'success',
            },
            {
              'feature_key': 'identity.logout',
              'label': 'Logout',
              'surface_label': 'Profile menu',
              'intended_label': 'admin, super_admin, supplier, customer, partner',
              'actual_label': 'admin, super_admin, supplier, customer, partner',
              'route_label': 'home_shell · logout',
              // A tone this build has never heard of.
              'tone': 'chartreuse',
            },
          ],
        },
        {
          'heading': 'Supplier portal — 0 features',
          'empty_hint': 'No supplier feature is registered.',
          'rows': [],
        },
      ],
    };

Map<String, dynamic> _dirty() {
  final m = _clean();
  m['drift'] = const [
    {
      'code': 'unrouted_feature',
      'tone': 'danger',
      'label': 'Delivery waves has no door',
      'feature_key': 'admin.delivery_waves',
      'detail':
          'route_key "delivery_waves" is not declared in surface_route, so tapping the tile lands in the shell\'s default branch.',
    },
    {
      'code': 'role_cannot_sign_out',
      'tone': 'danger',
      'label': 'partner has no profile menu',
      'feature_key': 'identity.logout',
      'detail': 'partner accounts can sign in, but the role is missing.',
    },
  ];
  // Deliberately disagreeing with the list length: the screen must print the
  // backend's heading, never a count it derived itself.
  m['drift_heading'] = '1 mapping problem';
  m['drift_count'] = 2;
  return m;
}

Future<void> _pump(WidgetTester t, Map<String, dynamic> payload) async {
  // A tall surface so the whole table is laid out: this file asserts on rows
  // near the bottom of the list, and an off-screen row is not a rendering bug.
  t.view.physicalSize = const Size(1400, 4000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  // A fresh element tree per pump. Re-pumping the same widget type keeps the
  // old State — and therefore the old payload — which would make the caption
  // test below silently pass on stale data.
  await t.pumpWidget(const SizedBox.shrink());
  await t.pumpWidget(MaterialApp(
    home: SurfaceMapScreen(
      key: UniqueKey(),
      rpc: (fn, params) async {
        expect(fn, 'surface_map_audit');
        return payload;
      },
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('the truth table is printed, not computed', () {
    testWidgets('every feature row is verbatim — key, audiences, surface, door',
        (t) async {
      await _pump(t, _clean());
      expect(find.text('Counter POS'), findsOneWidget);
      expect(find.text('shop.pos'), findsOneWidget);
      expect(find.text('Pharmacy My Shop'), findsOneWidget);
      expect(find.text('home_shell · pos'), findsOneWidget);
      expect(find.text('admin.manage_admins'), findsOneWidget);
      expect(find.text('identity.logout'), findsOneWidget);
    });

    testWidgets('rows keep payload order — the screen never re-sorts',
        (t) async {
      await _pump(t, _clean());
      final pos = t.getTopLeft(find.text('shop.pos')).dy;
      final admins = t.getTopLeft(find.text('admin.manage_admins')).dy;
      final logout = t.getTopLeft(find.text('identity.logout')).dy;
      expect(pos < admins, isTrue);
      expect(admins < logout, isTrue);
    });

    testWidgets('the four row captions are the payload\'s labels block',
        (t) async {
      await _pump(t, _clean());
      expect(find.text('Built for'), findsWidgets);
      expect(find.text('Reaches'), findsWidgets);

      final renamed = _clean();
      renamed['labels'] = const {
        'intended': 'Registered for',
        'actual': 'Actually reaches',
        'surface': 'Drawn on',
        'route': 'Opened by',
      };
      await _pump(t, renamed);
      expect(find.text('Registered for'), findsWidgets);
      expect(find.text('Actually reaches'), findsWidgets);
      // The old wording is gone because it never lived in this file.
      expect(find.text('Built for'), findsNothing);
    });

    testWidgets('an empty registry prints the backend\'s own empty hint',
        (t) async {
      await _pump(t, _clean());
      expect(find.text('No supplier feature is registered.'), findsOneWidget);
    });

    testWidgets('a tone this build has never heard of renders, not throws',
        (t) async {
      await _pump(t, _clean());
      // takeException() is the real assertion: a build that threw would have
      // parked the error here, and the copied `=> true` helper other protected
      // files use would have passed regardless.
      expect(t.takeException(), isNull);
      expect(find.text('Logout'), findsOneWidget);
    });
  });

  group('drift is the backend\'s verdict', () {
    testWidgets('zero drift shows the backend\'s clean sentence', (t) async {
      await _pump(t, _clean());
      expect(
          find.text(
              'No mapping drift — every feature reaches exactly its own audience.'),
          findsOneWidget);
      expect(find.text('Delivery waves has no door'), findsNothing);
    });

    testWidgets('each problem prints its own label and detail', (t) async {
      await _pump(t, _dirty());
      expect(find.text('Delivery waves has no door'), findsOneWidget);
      expect(find.text('partner has no profile menu'), findsOneWidget);
      expect(
          find.text('partner accounts can sign in, but the role is missing.'),
          findsOneWidget);
      // and the clean sentence is gone
      expect(
          find.text(
              'No mapping drift — every feature reaches exactly its own audience.'),
          findsNothing);
    });

    testWidgets('the heading is the backend\'s, never a Dart count', (t) async {
      await _pump(t, _dirty());
      // Two rows in the list, and the payload says "1 mapping problem".
      // The screen prints what it was given.
      expect(find.text('1 mapping problem'), findsOneWidget);
      expect(find.text('2 mapping problems'), findsNothing);
    });

    testWidgets('summary counters are backend strings with backend tones',
        (t) async {
      await _pump(t, _clean());
      expect(find.text('133'), findsOneWidget);
      expect(find.text('Features'), findsOneWidget);
      expect(find.text('Drift'), findsOneWidget);
    });
  });

  group('a refusal is the backend\'s sentence', () {
    testWidgets('ok:false renders message, and does not throw', (t) async {
      await _pump(t, {
        'ok': false,
        'title': 'Surface map',
        'message': 'Only a super admin can read the surface map.',
      });
      expect(find.text('Only a super admin can read the surface map.'),
          findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}
