// PROTECTED — the Claude login line is a PRINTER (CHANGE #1816).
//
// The card's one sentence about the VM's Claude login exists so Om can trust a
// date. Everything that could make it lie lives here:
//   • the fixture's `state`, `tone` and expiry DELIBERATELY disagree with its
//     own status sentence, so a widget that re-derived "expires in N days" from
//     the date, or picked its colour from `state`, fails;
//   • "credential first seen" and "last login" are two different backend
//     strings — the widget must never relabel one as the other;
//   • has:false draws NOTHING (an invented "checking…" is how a real red stops
//     being read);
//   • an unknown tone stays neutral, never an accidental red;
//   • sub-lines render in payload order, and an absent one is omitted rather
//     than dashed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_claude_login.dart';

Widget _host(Map<String, dynamic> payload) => MaterialApp(
      home: Scaffold(body: ClaudeLoginLine(payload: payload)),
    );

Color _colorOf(WidgetTester t, String text) =>
    (t.widget<Text>(find.text(text)).style?.color)!;

void main() {
  // The widget writes one render-log key, whose 800 ms debounce is a real Timer
  // that would otherwise outlive the test and try to reach Supabase.
  setUpAll(() => RenderLog.flushEnabled = false);

  // Healthy login: the sentence is the backend's, and its colour is the plain
  // text colour — a permanent green badge is how a real red stops being read.
  testWidgets('logged in prints the backend sentence in plain text',
      (t) async {
    await t.pumpWidget(_host(const {
      'has': true,
      'state': 'ok',
      'tone': 'neutral',
      'label': 'Claude login',
      'status': 'logged in',
      'title': 'Claude login — logged in',
      'lines': [
        {'key': 'last_login', 'text': 'credential first seen 06 Sep 2026, 11:51 AM IST'},
        {'key': 'valid_until', 'text': 'valid until 04 Oct 2026, 05:58 PM IST'},
      ],
    }));

    expect(find.text('Claude login — logged in'), findsOneWidget);
    expect(find.text('credential first seen 06 Sep 2026, 11:51 AM IST'),
        findsOneWidget);
    expect(find.text('valid until 04 Oct 2026, 05:58 PM IST'), findsOneWidget);
    expect(_colorOf(t, 'Claude login — logged in'), Ds.c.text);
  });

  // The fixture is a trap: a title that says 3 days over a valid-until date
  // 40 days out. Only the backend's words may appear.
  testWidgets('expiring prints the payload countdown, never a computed one',
      (t) async {
    await t.pumpWidget(_host(const {
      'has': true,
      'state': 'soon',
      'tone': 'warning',
      'status': 'expires in 3 days',
      'title': 'Claude login — expires in 3 days',
      'lines': [
        {'key': 'last_login', 'text': 'last login 01 Aug 2026, 09:10 PM IST'},
        {'key': 'valid_until', 'text': 'valid until 16 Oct 2026, 05:58 PM IST'},
      ],
    }));

    expect(find.text('Claude login — expires in 3 days'), findsOneWidget);
    expect(_colorOf(t, 'Claude login — expires in 3 days'), Ds.c.warning);
    // The date on screen is the payload's, not one recomputed from "3 days".
    expect(find.text('valid until 16 Oct 2026, 05:58 PM IST'), findsOneWidget);
    // "last login" and "credential first seen" are different backend strings.
    expect(find.textContaining('credential first seen'), findsNothing);
  });

  testWidgets('expired is red and keeps the backend instruction verbatim',
      (t) async {
    await t.pumpWidget(_host(const {
      'has': true,
      'state': 'expired',
      'tone': 'danger',
      'status': 'expired · run /login on the VM',
      'title': 'Claude login — expired · run /login on the VM',
      'lines': [
        {'key': 'last_login', 'text': 'last login 05 Jun 2026, 07:02 AM IST'},
        {'key': 'valid_until', 'text': 'valid until 03 Sep 2026, 07:02 AM IST'},
        {'key': 'read', 'text': 'last read 4h ago'},
      ],
    }));

    expect(find.text('Claude login — expired · run /login on the VM'),
        findsOneWidget);
    expect(_colorOf(t, 'Claude login — expired · run /login on the VM'),
        Ds.c.danger);
    // Sub-lines keep PAYLOAD order — the staleness note is last because the
    // backend put it last, not because Dart sorted anything.
    final texts = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .toList();
    expect(texts.indexOf('last login 05 Jun 2026, 07:02 AM IST'),
        lessThan(texts.indexOf('valid until 03 Sep 2026, 07:02 AM IST')));
    expect(texts.indexOf('valid until 03 Sep 2026, 07:02 AM IST'),
        lessThan(texts.indexOf('last read 4h ago')));
  });

  testWidgets('an unknown tone stays neutral', (t) async {
    await t.pumpWidget(_host(const {
      'has': true,
      'state': 'brand_new_state',
      'tone': 'chartreuse',
      'title': 'Claude login — something new',
      'lines': [],
    }));

    expect(_colorOf(t, 'Claude login — something new'), Ds.c.text);
  });

  testWidgets('nothing read yet draws nothing at all', (t) async {
    await t.pumpWidget(_host(const {'has': false}));
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('an absent sub-line is omitted, never dashed', (t) async {
    // No valid-until: the credential is gone, so there is no date to print.
    await t.pumpWidget(_host(const {
      'has': true,
      'state': 'missing',
      'tone': 'danger',
      'title': 'Claude login — no credential on the VM · run /login there',
      'lines': [
        {'key': 'last_login', 'text': 'last login 05 Jun 2026, 07:02 AM IST'},
      ],
    }));

    expect(find.textContaining('valid until'), findsNothing);
    expect(find.text('—'), findsNothing);
    expect(find.byType(Text), findsNWidgets(2));
  });
}
