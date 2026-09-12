// CHANGE #307 (step 9) — the full-screen-intent consent, as a pure decision.
//
// Play Console → App content → Full-screen intent was answered OTHER, because
// mediBO is neither an alarm clock nor a calling app. Google's rule for that
// answer (22 Jan 2025 onwards, apps targeting Android 14+) is that
// USE_FULL_SCREEN_INTENT is NOT granted at install — the admin grants it in
// Settings, or the alert degrades to a heads-up banner.
//
// Two inputs meet here and nothing else does:
//   * the WORDS, which are order_alert_fsi()'s payload — this file never
//     writes a sentence, a fallback caption or a default string;
//   * the FACT, which is Android's own canUseFullScreenIntent().
//
// Keeping the pairing pure is what lets it be tested without a device: the
// widget just prints whatever card comes back.
import 'package:flutter/foundation.dart';

/// Which of the backend's four sentences this device has earned.
enum FsiTone {
  /// Not read yet — show the backend's "checking" line, never a guess.
  unknown,

  /// Android 14+, permission granted: the alert takes over the lock screen.
  granted,

  /// Android 14+, permission withheld: still rings, still Accept/Reject.
  denied,

  /// Below Android 14 — the manifest permission IS the grant, nothing to ask.
  unsupported,

  /// Web (or any non-Android build): lock-screen alerts are an app feature.
  web,
}

/// Android's answer, verbatim. `known:false` until the channel has replied.
@immutable
class FsiDeviceState {
  /// False on web and on any platform without the order-alert channel.
  final bool isAndroid;

  /// True only where the runtime grant exists to be given (API 34+).
  final bool supported;

  /// canUseFullScreenIntent(). Below API 34 the platform answers true.
  final bool granted;

  /// False before the first successful channel call.
  final bool known;

  const FsiDeviceState({
    required this.isAndroid,
    required this.supported,
    required this.granted,
    required this.known,
  });

  static const FsiDeviceState unknown = FsiDeviceState(
    isAndroid: true,
    supported: false,
    granted: false,
    known: false,
  );

  static const FsiDeviceState notAndroid = FsiDeviceState(
    isAndroid: false,
    supported: false,
    granted: false,
    known: true,
  );

  /// The channel's reply, read without inventing a default for a missing key:
  /// an absent `granted` is not a grant.
  factory FsiDeviceState.fromChannel(Map<Object?, Object?> raw) {
    return FsiDeviceState(
      isAndroid: true,
      supported: raw['supported'] == true,
      granted: raw['granted'] == true,
      known: true,
    );
  }
}

/// One card's worth of backend copy, already chosen for this device.
@immutable
class FsiCard {
  final FsiTone tone;
  final String title;
  final String body;

  /// The button caption, or '' when there is nothing this admin can change.
  final String actionLabel;

  /// The "check again" caption — offered only alongside an action.
  final String recheckLabel;

  /// The reassurance line, shown only when the permission is withheld.
  final String note;

  const FsiCard({
    required this.tone,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.recheckLabel,
    required this.note,
  });

  /// True when the card is offering the Settings trip.
  bool get hasAction => actionLabel.isNotEmpty;
}

/// The point-of-use prompt: the sheet shown the moment an admin switches
/// new-order alerts ON and this device cannot raise a full-screen intent.
@immutable
class FsiPrompt {
  final String title;
  final String body;
  final String ctaLabel;
  final String skipLabel;

  const FsiPrompt({
    required this.title,
    required this.body,
    required this.ctaLabel,
    required this.skipLabel,
  });
}

/// The backend's copy block (`order_alert_settings().fsi`), read verbatim.
class FsiCopy {
  final Map<String, dynamic> raw;
  const FsiCopy(this.raw);

  /// A missing key is an ABSENCE, not a place to put an English default.
  String _s(String key) {
    final v = raw[key];
    return v is String ? v : '';
  }

  String get sectionLabel => _s('section');

  /// Which card this device gets. The device supplies facts; the payload
  /// supplies every word.
  FsiCard card(FsiDeviceState d) {
    if (!d.isAndroid) {
      return FsiCard(
        tone: FsiTone.web,
        title: _s('web_title'),
        body: _s('web_body'),
        actionLabel: '',
        recheckLabel: '',
        note: '',
      );
    }
    if (!d.known) {
      return FsiCard(
        tone: FsiTone.unknown,
        title: _s('checking'),
        body: '',
        actionLabel: '',
        recheckLabel: '',
        note: '',
      );
    }
    if (!d.supported) {
      return FsiCard(
        tone: FsiTone.unsupported,
        title: _s('unsupported_title'),
        body: _s('unsupported_body'),
        actionLabel: '',
        recheckLabel: '',
        note: '',
      );
    }
    if (d.granted) {
      return FsiCard(
        tone: FsiTone.granted,
        title: _s('granted_title'),
        body: _s('granted_body'),
        actionLabel: '',
        recheckLabel: '',
        note: '',
      );
    }
    return FsiCard(
      tone: FsiTone.denied,
      title: _s('denied_title'),
      body: _s('denied_body'),
      actionLabel: _s('action'),
      recheckLabel: _s('recheck'),
      note: _s('degraded_note'),
    );
  }

  /// The prompt exists only where the grant is both askable and missing —
  /// so an admin on Android 13, or one who already granted it, is never
  /// interrupted for a permission that is not theirs to give.
  bool shouldPrompt(FsiDeviceState d) =>
      d.isAndroid && d.known && d.supported && !d.granted;

  FsiPrompt get prompt => FsiPrompt(
        title: _s('prompt_title'),
        body: _s('prompt_body'),
        ctaLabel: _s('prompt_cta'),
        skipLabel: _s('prompt_skip'),
      );
}
