// PROTECTED — CMD #1862.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes this behaviour, never to make an unrelated change go
// green.
//
// What this holds down — the Runners card cannot disappear again:
//
//   1. THE STRIP TALKS TO THE CONTROL PLANE. #1761 moved the dev-queue backend
//      onto its own Supabase project and left one card behind: the v3 strip
//      kept calling `Supabase.instance`, where `strip_v3_card`, `dev_ctl_set`
//      and `runner_action_request` answer PGRST202 and nothing else. The card
//      swallows its own errors by design, so the only visible symptom was the
//      VM / Start building / Parallel building switches quietly vanishing from
//      Dev Queue. So: none of those three is a production RPC, and the router
//      hands each of them the control-plane client — while an RPC that really
//      does describe production (`cron_health`) still goes to production.
//
//   2. THE FOOTER DRAWS THEM WHENEVER THE STRIP DID NOT. #1570 tied that
//      suppression to `embedded`, which is a fact about layout, not about what
//      reached the screen — so when the strip went blind, NEITHER card drew a
//      switch and there was no way to start the fleet at all. The owner is
//      decided by the payload: an empty map (the 404 case), a has:false
//      payload and a payload whose `toggles` list is empty all mean the footer
//      draws.
//
//   3. THE LOGIN BANNER IS NOT ON DEV QUEUE. Om logs in on the VM by hand;
//      the banner's stale-check title, its OAuth link and its "Re-login from
//      here" button are gone from the runner card. (The widget itself stays —
//      Cron health still prints it — so this asserts the CARD no longer
//      imports it.)

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_service.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/strip_v3/strip_v3_card.dart';

void main() {
  group('CMD #1862 — the strip reads the control plane', () {
    // A real client object, never used to make a request: pinning it is what
    // proves the router chose the control-plane side without a network.
    final pinned = SupabaseClient('https://control-plane.example', 'anon-key');

    test('the strip RPCs are not production RPCs', () {
      for (final fn in const [
        'strip_v3_card',
        'dev_ctl_set',
        'runner_action_request',
      ]) {
        expect(DevQueueService.productionRpcs.contains(fn), isFalse,
            reason: '$fn lives on the control plane, not production');
      }
      // The control group: an RPC that describes production itself.
      expect(DevQueueService.productionRpcs.contains('cron_health'), isTrue);
    });

    test('the router hands the strip RPCs the control-plane client', () async {
      final svc = DevQueueService(client: pinned);
      for (final fn in const [
        'strip_v3_card',
        'dev_ctl_set',
        'runner_action_request',
      ]) {
        expect(identical(await svc.clientFor(fn), pinned), isTrue,
            reason: '$fn must not go to Supabase.instance');
      }
    });

    test('a production RPC still goes to production', () async {
      final prod = SupabaseClient('https://production.example', 'anon-key');
      final svc = DevQueueService(client: pinned, storageClient: prod);
      expect(identical(await svc.clientFor('cron_health'), prod), isTrue);
    });
  });

  group('CMD #1862 — who draws the three switches', () {
    Map<String, dynamic> payload(List toggles) => {
          'has': true,
          'title': 'Runners',
          'toggles': toggles,
        };

    test('an empty payload means the footer draws them', () {
      // Exactly what a 404'd / thrown strip_v3_card leaves behind.
      expect(StripToggleOwner.stripDraws(const {}), isFalse);
    });

    test('has:false means the footer draws them', () {
      expect(
          StripToggleOwner.stripDraws({
            'has': false,
            'toggles': [
              {'key': 'vm'}
            ],
          }),
          isFalse);
    });

    test('an empty toggles list means the footer draws them', () {
      expect(StripToggleOwner.stripDraws(payload(const [])), isFalse);
    });

    test('toggles on the payload means the strip draws them', () {
      expect(
          StripToggleOwner.stripDraws(payload([
            {'key': 'vm', 'label': 'VM'},
            {'key': 'claude', 'label': 'Start building'},
            {'key': 'workflow', 'label': 'Parallel building'},
          ])),
          isTrue);
    });
  });

  test('CMD #1862 — the runner card no longer draws the login banner', () {
    final src = File('lib/screens/admin/dev_queue/dev_queue_control.dart')
        .readAsStringSync();
    expect(src.contains('ClaudeAuthBanner('), isFalse,
        reason: 'the Claude login banner was removed from Dev Queue');
    expect(src.contains("import 'claude_auth_banner.dart';"), isFalse);
    // The widget itself survives — Cron health still prints it.
    expect(File('lib/screens/admin/dev_queue/claude_auth_banner.dart').existsSync(),
        isTrue);
  });
}
