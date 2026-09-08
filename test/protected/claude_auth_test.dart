// PROTECTED — CHANGE #1369.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes Claude-login behaviour, never to make an unrelated
// change go green.
//
// What this holds down — the Claude login banner is a PRINTER, and the ONE
// thing it must never do is invent reassurance:
//
//   1. A healthy login draws NOTHING. The fixture's success payload is complete
//      and truthful and still renders an empty box, because a permanent green
//      badge is exactly how a real red stops being read. `has:false` draws
//      nothing either.
//
//   2. Every word is the backend's. Title, sub-line, the "checked … on <host>"
//      line, the CLI chip, the button's label, the handshake's state sentence
//      and its hint all come from `claude_auth_status()`. The fixture's title
//      deliberately disagrees with its own bucket and tone, so a widget that
//      re-derived any of them from `bucket` fails here.
//
//   3. Absence is absence. An empty sub-line, an empty version or an absent
//      code is a line that is not drawn — never a dash, never a placeholder.
//
//   4. `can` is the backend's decision, and it gates the BUTTON, not the
//      widget. While a login is already running the button is gone but the link
//      and the code are still on screen: a second tap must not be able to
//      restart the VM's login mid-flow, and that judgement is not Dart's.
//
//   5. The Cron health panel and the Runner-card banner are the SAME widget
//      underneath, so the two surfaces can never disagree about what red looks
//      like; and until its payload has arrived the panel draws NOTHING, rather
//      than a spinner that outlives the screen or a half-built card.
//
//   6. The widget never talks to the network. Tapping the button calls the
//      callback the parent supplied — exactly once — and nothing else.
//
//   7. CHANGE #1401 — the Runner card's copy of it, which is plumbing rather
//      than judgement and so is held down here as plumbing: the block is read
//      off `dev_ctl_get().claude_auth` and nowhere else, an absent one is an
//      empty map rather than a synthesised login, and a re-login reply — which
//      carries the login block ALONE — is FOLDED into the card's snapshot, so
//      the toggles, the breaker, the pool and the queue counts on that same
//      snapshot survive the tap untouched. An empty reply changes nothing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/claude_auth_banner.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/claude_auth_section.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_control.dart';

Map<String, dynamic> _payload({
  String tone = 'danger',
  String title = 'Runners blocked: Claude login expired',
  String sub =
      'No worker can start a session, so nothing is being claimed. Re-login below to bring the fleet back.',
  String checked = 'Checked 4m ago on ip-172-31-41-212',
  String version = 'CLI 2.1.261',
  bool has = true,
  Map<String, dynamic>? relogin,
}) =>
    {
      'has': has,
      'host': 'ip-172-31-41-212',
      'blocked': true,
      // Deliberately inconsistent with the title and tone above: the card
      // prints, it never re-derives.
      'bucket': 'warn_3d',
      'tone': tone,
      'title': title,
      'sub': sub,
      'checked': checked,
      'version': version,
      'detail': 'claude auth status reports loggedIn=false',
      'relogin': relogin ??
          const {
            'can': true,
            'label': 'Re-login from here',
            'state': 'idle',
            'state_label': '',
            'url': '',
            'code': '',
            'message': '',
            'hint':
                'The VM starts the login and posts the link and code here within a minute.',
          },
      'zone': null,
      'date': '2026-09-05',
    };

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> payload, {
  Future<void> Function()? onRelogin,
  bool busy = false,
}) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ClaudeAuthBanner(
              auth: payload, onRelogin: onRelogin, busy: busy),
        ),
      ),
    ));

void main() {
  testWidgets('a healthy login draws nothing at all', (tester) async {
    await _pump(
        tester,
        _payload(
            tone: 'success',
            title: 'Signed in',
            sub: '',
            checked: 'Checked 1m ago on ip-172-31-41-212'));
    expect(find.text('Signed in'), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(ClaudeAuthBanner.shows(_payload(tone: 'success')), isFalse);
  });

  testWidgets('has:false draws nothing', (tester) async {
    await _pump(tester, _payload(has: false));
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.textContaining('Runners blocked'), findsNothing);
  });

  testWidgets('every word on a red banner is the payload, verbatim',
      (tester) async {
    await _pump(tester, _payload(), onRelogin: () async {});
    expect(find.text('Runners blocked: Claude login expired'), findsOneWidget);
    expect(
        find.text(
            'No worker can start a session, so nothing is being claimed. Re-login below to bring the fleet back.'),
        findsOneWidget);
    // checked and version are joined by the widget's own separator and never
    // re-worded.
    expect(find.text('Checked 4m ago on ip-172-31-41-212 · CLI 2.1.261'),
        findsOneWidget);
    expect(find.text('Re-login from here'), findsOneWidget);
    // The bucket disagrees with the title on purpose — nothing may be derived
    // from it.
    expect(find.textContaining('3 days'), findsNothing);
  });

  testWidgets('an absent sub-line or version is omitted, never dashed',
      (tester) async {
    await _pump(tester, _payload(sub: '', version: ''), onRelogin: () async {});
    expect(find.text('—'), findsNothing);
    expect(find.text('Checked 4m ago on ip-172-31-41-212'), findsOneWidget);
  });

  testWidgets('the handshake prints the backend link and code, and closes the button',
      (tester) async {
    await _pump(
      tester,
      _payload(relogin: const {
        'can': false,
        'label': 'Re-login from here',
        'state': 'url_ready',
        'state_label': 'Open this link, then enter the code',
        'url': 'https://claude.ai/oauth/authorize?code=true&client_id=9d1c250a',
        'code': 'X7K2-9QMD',
        'message': '',
        'hint': 'The VM starts the login and posts the link and code here within a minute.',
      }),
      onRelogin: () async {},
    );
    expect(find.text('Open this link, then enter the code'), findsOneWidget);
    expect(
        find.text(
            'https://claude.ai/oauth/authorize?code=true&client_id=9d1c250a'),
        findsOneWidget);
    expect(find.text('X7K2-9QMD'), findsOneWidget);
    // can:false — a second tap must not be able to restart the VM's login.
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('the button calls the parent exactly once and nothing else',
      (tester) async {
    var taps = 0;
    await _pump(tester, _payload(), onRelogin: () async {
      taps++;
    });
    await tester.tap(find.byType(OutlinedButton));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('busy closes the button without the widget owning state',
      (tester) async {
    var taps = 0;
    await _pump(tester, _payload(), busy: true, onRelogin: () async {
      taps++;
    });
    await tester.tap(find.byType(OutlinedButton), warnIfMissed: false);
    await tester.pump();
    expect(taps, 0);
    expect(find.text('Re-login from here'), findsNothing);
  });

  testWidgets('the Cron health panel prints the same payload as the banner',
      (tester) async {
    // No client is injected, so the RPC never resolves and the panel stays in
    // its loading state — which must draw NOTHING rather than a spinner that
    // outlives the screen or a half-built card.
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: ClaudeAuthSection()),
    ));
    await tester.pump();
    expect(find.byType(Card), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
  });

  // ── CHANGE #1401 — the same banner, on the Runner control card ──────────
  //
  // The card renders `dev_ctl_get()` verbatim, and the login block rides that
  // same poll. Nothing below asks the widget to decide anything: these are the
  // two payload moves the card makes, and both are the kind that fail silently.

  group('Runner card payload moves', () {
    // A dev_ctl_get snapshot: the login block sits beside everything else the
    // card is already drawing, which is exactly why a tap must not replace it.
    Map<String, dynamic> snap({Map<String, dynamic>? auth}) => {
          'server_now': '2026-09-05T13:00:00+00:00',
          'desired_state': {'vm': 'on', 'claude': 'on', 'workflow': 'on'},
          'controls': {
            'workflow': {'locked': false}
          },
          'breaker': {'has': false},
          'pool': {'desired': 4},
          'queue_counts': {'pending': 11},
          if (auth != null) 'claude_auth': auth,
        };

    test('the block is read off claude_auth, verbatim', () {
      final auth = _payload();
      final read = ClaudeAuthSnap.read(snap(auth: auth));
      expect(read['title'], 'Runners blocked: Claude login expired');
      expect(read['tone'], 'danger');
      expect(read['checked'], 'Checked 4m ago on ip-172-31-41-212');
      expect((read['relogin'] as Map)['label'], 'Re-login from here');
    });

    test('an absent block is an empty map, never a synthesised login', () {
      expect(ClaudeAuthSnap.read(snap()), isEmpty);
      expect(ClaudeAuthSnap.read(const {}), isEmpty);
      // A card that read the wrong key would get this — and then print a
      // reassuring nothing over a fleet that cannot start a session.
      expect(ClaudeAuthSnap.read({'auth': _payload()}), isEmpty);
    });

    test('a re-login reply is folded in, not assigned over the snapshot', () {
      final before = snap(auth: _payload());
      final reply = _payload(
        tone: 'warning',
        title: 'Login started — waiting for the VM',
        relogin: const {
          'can': false,
          'state': 'requested',
          'state_label': 'Login started — the link appears here in a minute',
        },
      );

      final after = ClaudeAuthSnap.fold(before, reply);

      // The login block is the reply's…
      expect(ClaudeAuthSnap.read(after)['title'],
          'Login started — waiting for the VM');
      // …and everything else the card draws off this same snapshot survived.
      expect((after['desired_state'] as Map)['workflow'], 'on');
      expect((after['pool'] as Map)['desired'], 4);
      expect((after['queue_counts'] as Map)['pending'], 11);
      expect(after['breaker'], isNotNull);
      // The snapshot it was folded onto is left alone, so a poll that lands
      // mid-tap cannot resurrect the old login block from a shared map.
      expect(ClaudeAuthSnap.read(before)['title'],
          'Runners blocked: Claude login expired');
    });

    test('an empty reply changes nothing', () {
      final before = snap(auth: _payload());
      final after = ClaudeAuthSnap.fold(before, const {});
      expect(ClaudeAuthSnap.read(after)['title'],
          'Runners blocked: Claude login expired');
      expect(after, same(before));
    });

    testWidgets('the card draws NOTHING while the login is healthy',
        (tester) async {
      // The success payload is complete and truthful; the Runner card is a
      // strip Om reads every day, and a permanent green line on it is how a
      // real red stops being read.
      await _pump(tester,
          ClaudeAuthSnap.read(snap(auth: _payload(tone: 'success'))));
      expect(find.byType(Icon), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(
          find.text('Runners blocked: Claude login expired'), findsNothing);
    });

    testWidgets('and prints the backend sentence when it is not', (tester) async {
      // The card hands the widget a callback exactly as it does live, so the
      // backend's own button label is what the strip offers.
      await _pump(tester, ClaudeAuthSnap.read(snap(auth: _payload())),
          onRelogin: () async {});
      expect(find.text('Runners blocked: Claude login expired'), findsOneWidget);
      expect(find.text('Re-login from here'), findsOneWidget);
    });
  });
}
