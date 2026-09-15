// PROTECTED — CHANGE #712.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how the Notifications card draws a channel.
//
// WHY THIS IS WORTH A PROTECTED FILE. Every message mediBO sends can travel on
// three channels with three independent switches on the route (enabled /
// push_enabled / email_enabled), and the paid one — WhatsApp — is the one an
// admin most wants to turn off alone. The card had ONE switch, so the payload's
// three flags were unreachable. Now they are chips, and the risk moves: a chip
// that decides anything for itself is a second opinion about what is switched
// on, and the card is not entitled to one.
//
// WHAT THIS HOLDS DOWN:
//   1. Chips are the payload's, in payload order, with the payload's words. A
//      channel key this build has never heard of still renders.
//   2. A row whose payload carries no channels draws no chips — absent is
//      absent, never a default set of three.
//   3. The reason a chip is dark is the BACKEND's sentence (`blocked_label`),
//      and a blocked chip reads as off however `enabled` arrived.
//   4. Tapping sends notification_channel_set with that row's audience, action
//      and channel, and the NEGATION of what arrived — never a value the chip
//      derived from its own colour.
//   5. A refusal (`ok:false`) puts the chip back and prints the backend's
//      message. The card never invents refusal wording.
//
// No network, no Supabase: NotificationsCard.rpcOverride feeds the payloads.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/widgets/notifications_card.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _ch(String key, String label,
        {bool enabled = false,
        bool blocked = false,
        String blockedLabel = 'the message switch is off',
        String hint = ''}) =>
    {
      'key': key,
      'label': label,
      'enabled': enabled,
      'blocked': blocked,
      'blocked_label': blockedLabel,
      'hint': hint,
    };

Map<String, dynamic> _row({List<Map<String, dynamic>>? channels}) => {
      'audience': 'customer',
      'audience_label': 'Customer',
      'audience_sort': 1,
      'action_key': 'sourcing_started',
      'label': 'Sourcing started',
      'enabled': true,
      'sort': 52,
      'template_id': 'tpl-1',
      'template_name': 'sourcing_started',
      'template_status': 'DRAFT',
      'template_label': 'Draft being prepared',
      'template_tone': 'warn',
      'can_edit': true,
      'can_preview': false,
      'can_generate': false,
      'edit_label': 'Edit the message',
      'has_pending_change': false,
      'auto_manage': true,
      if (channels != null) 'channels': channels,
    };

Map<String, dynamic> _matrix(List<Map<String, dynamic>> rows) => {
      'audiences': [
        {'value': 'customer', 'label': 'Customer', 'sort': 1},
      ],
      'rows': rows,
      'note': 'These are the messages mediBO can send.',
      'allowlist_note': 'Test numbers always receive these.',
    };

class _Rpc {
  final List<MapEntry<String, Map<String, dynamic>?>> calls = [];
  final Map<String, dynamic> matrix;
  final Map<String, dynamic> channelSet;
  _Rpc({required this.matrix, required this.channelSet});

  Future<dynamic> call(String fn, Map<String, dynamic>? params) async {
    calls.add(MapEntry(fn, params));
    switch (fn) {
      case 'notification_matrix':
        return matrix;
      case 'get_notification_allowlist':
        return <dynamic>[];
      case 'notification_channel_set':
        return channelSet;
      default:
        return const <String, dynamic>{};
    }
  }

  Map<String, dynamic>? paramsFor(String fn) {
    for (final c in calls.reversed) {
      if (c.key == fn) return c.value;
    }
    return null;
  }

  bool called(String fn) => calls.any((c) => c.key == fn);
}

Future<_Rpc> _pump(WidgetTester t, Map<String, dynamic> matrix,
    {Map<String, dynamic>? channelSet}) async {
  t.view.physicalSize = const Size(520, 1600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);

  final rpc = _Rpc(
      matrix: matrix, channelSet: channelSet ?? const {'ok': true});
  NotificationsCard.rpcOverride = rpc.call;

  await t.pumpWidget(const MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: NotificationsCard())),
  ));
  await t.pumpAndSettle();
  // The header caption is backend copy (seeded in setUpAll), which is also why
  // this file never asserts on a word the card wrote itself.
  await t.tap(find.text('Notifications'));
  await t.pumpAndSettle();
  return rpc;
}

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    UiCopy.debugSet(const {'notifications.card_title': 'Notifications'});
  });
  setUp(NotificationsCard.debugResetCache);
  tearDown(() {
    NotificationsCard.rpcOverride = null;
    NotificationsCard.debugResetCache();
  });

  testWidgets('the chips are the payload — its words, its order, its unknowns',
      (t) async {
    await _pump(
        t,
        _matrix([
          _row(channels: [
            _ch('whatsapp', 'WhatsApp', enabled: true),
            _ch('push', 'Push'),
            _ch('email', 'Email'),
            // A channel added after this build shipped.
            _ch('telegram', 'Telegram'),
          ])
        ]));

    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text('Push'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Telegram'), findsOneWidget);
    expect(t.takeException(), isNull);

    final wa = t.getTopLeft(find.text('WhatsApp'));
    final push = t.getTopLeft(find.text('Push'));
    final email = t.getTopLeft(find.text('Email'));
    // Payload order, left to right on one run.
    expect(wa.dx < push.dx, isTrue);
    expect(push.dx < email.dx, isTrue);
  });

  testWidgets('no channels in the payload means no chips', (t) async {
    await _pump(t, _matrix([_row()]));
    expect(find.text('WhatsApp'), findsNothing);
    expect(find.text('Push'), findsNothing);
    expect(find.text('Email'), findsNothing);
  });

  testWidgets('a blocked chip prints the backend\'s reason, not a Dart one',
      (t) async {
    await _pump(
        t,
        _matrix([
          _row(channels: [
            // enabled TRUE and blocked TRUE: the master switch wins, and the
            // sentence explaining that is the server's.
            _ch('whatsapp', 'WhatsApp',
                enabled: true,
                blocked: true,
                blockedLabel: 'the message switch is off'),
            _ch('push', 'Push', hint: 'no push wording yet'),
          ])
        ]));

    expect(find.text('the message switch is off'), findsOneWidget);
    expect(find.text('no push wording yet'), findsOneWidget);
  });

  testWidgets('a tap sends this row, this channel, and the opposite value',
      (t) async {
    final rpc = await _pump(
        t,
        _matrix([
          _row(channels: [
            _ch('whatsapp', 'WhatsApp', enabled: true),
            _ch('push', 'Push'),
          ])
        ]));

    await t.tap(find.text('Push'));
    await t.pumpAndSettle();

    expect(rpc.called('notification_channel_set'), isTrue);
    final p = rpc.paramsFor('notification_channel_set')!;
    expect(p['p_audience'], 'customer');
    expect(p['p_action_key'], 'sourcing_started');
    expect(p['p_channel'], 'push');
    expect(p['p_on'], true);

    // ...and turning the paid one off is the same call with false, which is
    // the whole reason this row exists.
    await t.tap(find.text('WhatsApp'));
    await t.pumpAndSettle();
    final p2 = rpc.paramsFor('notification_channel_set')!;
    expect(p2['p_channel'], 'whatsapp');
    expect(p2['p_on'], false);
  });

  testWidgets('a refusal rolls the chip back and shows the backend message',
      (t) async {
    await _pump(
      t,
      _matrix([
        _row(channels: [_ch('push', 'Push')])
      ]),
      channelSet: const {
        'ok': false,
        'error': 'not_authorized',
        'message': 'You do not have permission to change this.',
      },
    );

    await t.tap(find.text('Push'));
    await t.pumpAndSettle();

    expect(find.text('You do not have permission to change this.'),
        findsOneWidget);
    // and the chip is back where the server says it is: still off, so the
    // "on" icon is nowhere on the card.
    expect(find.byIcon(Icons.check_circle), findsNothing);
  });
}
