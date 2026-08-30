// CHANGE #307 (step 9) — the full-screen-intent consent decision.
//
// Play Console → App content → Full-screen intent was answered OTHER, so from
// 22 Jan 2025 Android 14+ withholds USE_FULL_SCREEN_INTENT until the admin
// grants it. What must never happen is the alert going quiet, or Dart
// inventing a sentence when the backend sent none. Both are pinned here.
import 'package:flutter_test/flutter_test.dart';
import 'package:medibo/models/order_alert_fsi.dart';

/// The payload order_alert_fsi() returns, deliberately full of words that
/// exist nowhere in the Dart source — so a hardcoded fallback cannot pass.
const Map<String, dynamic> kCopy = {
  'section': 'SECTION-ZZ',
  'checking': 'CHECKING-ZZ',
  'granted_title': 'GRANTED-T',
  'granted_body': 'GRANTED-B',
  'denied_title': 'DENIED-T',
  'denied_body': 'DENIED-B',
  'unsupported_title': 'UNSUP-T',
  'unsupported_body': 'UNSUP-B',
  'web_title': 'WEB-T',
  'web_body': 'WEB-B',
  'action': 'ACTION-ZZ',
  'recheck': 'RECHECK-ZZ',
  'prompt_title': 'PROMPT-T',
  'prompt_body': 'PROMPT-B',
  'prompt_cta': 'CTA-ZZ',
  'prompt_skip': 'SKIP-ZZ',
  'degraded_note': 'NOTE-ZZ',
};

FsiDeviceState android({required bool supported, required bool granted}) =>
    FsiDeviceState(
      isAndroid: true,
      supported: supported,
      granted: granted,
      known: true,
    );

void main() {
  final copy = FsiCopy(kCopy);

  group('which card the device earns', () {
    test('Android 14+ without the grant asks, and says it still rings', () {
      final c = copy.card(android(supported: true, granted: false));
      expect(c.tone, FsiTone.denied);
      expect(c.title, 'DENIED-T');
      expect(c.body, 'DENIED-B');
      // The button and the reassurance both come from the payload.
      expect(c.actionLabel, 'ACTION-ZZ');
      expect(c.recheckLabel, 'RECHECK-ZZ');
      expect(c.note, 'NOTE-ZZ');
      expect(c.hasAction, isTrue);
    });

    test('granted shows the ON copy and offers no settings trip', () {
      final c = copy.card(android(supported: true, granted: true));
      expect(c.tone, FsiTone.granted);
      expect(c.title, 'GRANTED-T');
      expect(c.hasAction, isFalse, reason: 'nothing left to grant');
      expect(c.note, isEmpty);
    });

    test('below Android 14 the manifest IS the grant — nothing to ask', () {
      final c = copy.card(android(supported: false, granted: true));
      expect(c.tone, FsiTone.unsupported);
      expect(c.title, 'UNSUP-T');
      expect(c.hasAction, isFalse);
    });

    test('web says lock-screen alerts are an app feature', () {
      final c = copy.card(FsiDeviceState.notAndroid);
      expect(c.tone, FsiTone.web);
      expect(c.title, 'WEB-T');
      expect(c.hasAction, isFalse);
    });

    test('before the channel answers it shows checking, never a verdict', () {
      final c = copy.card(FsiDeviceState.unknown);
      expect(c.tone, FsiTone.unknown);
      expect(c.title, 'CHECKING-ZZ');
      expect(c.body, isEmpty);
      expect(c.hasAction, isFalse);
    });
  });

  group('the point-of-use prompt', () {
    test('fires only where the grant is askable AND missing', () {
      expect(copy.shouldPrompt(android(supported: true, granted: false)), isTrue);
      expect(copy.shouldPrompt(android(supported: true, granted: true)), isFalse);
      expect(copy.shouldPrompt(android(supported: false, granted: false)), isFalse);
      expect(copy.shouldPrompt(FsiDeviceState.notAndroid), isFalse);
      expect(copy.shouldPrompt(FsiDeviceState.unknown), isFalse,
          reason: 'an unread device must not be interrupted on a guess');
    });

    test('every word of the sheet is the payload', () {
      final p = copy.prompt;
      expect(p.title, 'PROMPT-T');
      expect(p.body, 'PROMPT-B');
      expect(p.ctaLabel, 'CTA-ZZ');
      expect(p.skipLabel, 'SKIP-ZZ');
    });
  });

  group('absence is an absence, not an English default', () {
    test('an empty payload prints nothing at all', () {
      const empty = FsiCopy({});
      final c = empty.card(android(supported: true, granted: false));
      expect(c.title, isEmpty);
      expect(c.body, isEmpty);
      expect(c.actionLabel, isEmpty);
      expect(c.hasAction, isFalse);
      expect(empty.sectionLabel, isEmpty);
    });

    test('a non-string label is not coerced into one', () {
      const odd = FsiCopy({'denied_title': 42, 'denied_body': null});
      final c = odd.card(android(supported: true, granted: false));
      expect(c.title, isEmpty);
      expect(c.body, isEmpty);
    });
  });

  group('the channel reply is read without inventing a grant', () {
    test('a missing granted key is NOT a grant', () {
      final d = FsiDeviceState.fromChannel(const {'supported': true});
      expect(d.known, isTrue);
      expect(d.granted, isFalse);
      expect(copy.card(d).tone, FsiTone.denied);
    });

    test('the platform booleans are carried through verbatim', () {
      final d = FsiDeviceState.fromChannel(
          const {'supported': true, 'granted': true, 'sdk': 34});
      expect(d.supported, isTrue);
      expect(d.granted, isTrue);
      expect(copy.card(d).tone, FsiTone.granted);
    });
  });
}
