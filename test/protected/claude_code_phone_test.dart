// CHANGE #237 — the Claude Code device list is MEASURED, and it is NOT the same
// thing as mediBO's live-view bridge.
//
// The bug this pins: for weeks the Dev Queue showed "On phone" (remote_display,
// mediBO's own medibo-bridge) while Om's Claude Code mobile app listed no
// devices at all. Nothing on the build VM had ever opened an ANTHROPIC Remote
// Control session — the GCP box typed `/remote-control` into an interactive TUI,
// and the headless `claude --print` loop that replaced it never registers one.
// Two different bridges, one badge, so the failure was invisible.
//
// These tests hold the two apart, and hold PhoneBadge to rendering backend
// strings only — no Dart-side count, wording, or pluralisation.
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/restart_safety.dart';

void main() {
  group('PhoneBadge — the Claude Code device list', () {
    test('renders the backend strings verbatim and never composes a label', () {
      const b = PhoneBadge({
        'phone_display': 'Claude app · 2 live',
        'phone_tone': 'success',
        'phone_hint': 'Open Claude Code on your phone.',
        'phone_sessions': 2,
        'phone_names': [
          'mediBO · runner-1 · #237 Make every worker session appear…',
          'mediBO · runner-2 · standby',
        ],
      });
      expect(b.show, isTrue);
      expect(b.isOn, isTrue);
      expect(b.count, 2);
      expect(b.display, 'Claude app · 2 live');
      expect(b.tone, 'success');
      expect(b.hint, 'Open Claude Code on your phone.');
      expect(b.names.length, 2);
      // The command id is what tells two live builds apart in a narrow list.
      expect(b.names.first, contains('#237'));
    });

    test('zero sessions is a VISIBLE state, not a missing chip', () {
      const b = PhoneBadge({
        'phone_display': 'Claude app · no session',
        'phone_tone': 'warning',
        'phone_hint': 'No worker has opened a Remote Control session yet.',
        'phone_sessions': 0,
        'phone_names': [],
      });
      expect(b.show, isTrue, reason: 'off must still render — that was the bug');
      expect(b.isOn, isFalse);
      expect(b.count, 0);
      expect(b.names, isEmpty);
      expect(b.hint, isNotEmpty, reason: 'the empty state carries guidance');
    });

    test('an older payload degrades to off, never to "assume connected"', () {
      const b = PhoneBadge({'remote_control': 'on', 'remote_display': 'On phone'});
      expect(b.show, isFalse);
      expect(b.isOn, isFalse);
      expect(b.count, 0);
      expect(b.names, isEmpty);
      expect(b.tone, 'neutral');
    });

    test('blank names are dropped rather than drawn as empty rows', () {
      const b = PhoneBadge({
        'phone_display': 'Claude app · 1 live',
        'phone_sessions': 1,
        'phone_names': ['mediBO · runner-1 · standby', '', null],
      });
      expect(b.names, ['mediBO · runner-1 · standby']);
    });

    test('mediBO live view and the Claude Code app are separate badges', () {
      // The exact shape that hid the bug: mediBO's bridge up, Anthropic's down.
      const status = {
        'remote_control': 'on',
        'remote_display': 'On phone',
        'remote_tone': 'success',
        'phone_display': 'Claude app · no session',
        'phone_tone': 'warning',
        'phone_sessions': 0,
      };
      const remote = RemoteBadge(status);
      const phone = PhoneBadge(status);
      expect(remote.isOn, isTrue);
      expect(phone.isOn, isFalse);
      expect(remote.display, isNot(equals(phone.display)));
    });
  });
}
