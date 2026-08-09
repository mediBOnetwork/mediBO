// COUNT MODE — the bridge that lets the unified Count screen show and drive
// the tab's voice engine while the camera runs.
//
// THE APP RENDERS. IT NEVER DECIDES: the Count screen does not own a second
// voice pipeline. The tab's existing engine (live stream on Android, clip
// recorder elsewhere — with its caps, fallbacks, bag boundaries and finalize
// flow) keeps running exactly as before; these hooks only expose its state and
// its toggle. Every string in [CountVoiceStatus] is one the tab already read
// from the backend (ready label, live hint, error copy) or the live caption.
library;

/// A snapshot of the tab's voice state, rendered verbatim by the Count screen.
class CountVoiceStatus {
  final bool supported;
  final bool listening;
  final bool processing;

  /// Interim caption — the words currently being spoken.
  final String caption;

  /// Backend hint from the live snapshot (voice_live_preview/commit).
  final String hint;

  /// Backend error copy, empty when none.
  final String error;

  /// Warehouse active-bag label from the live snapshot; '' elsewhere.
  final String bagLabel;

  const CountVoiceStatus({
    this.supported = false,
    this.listening = false,
    this.processing = false,
    this.caption = '',
    this.hint = '',
    this.error = '',
    this.bagLabel = '',
  });
}

/// What a fulfillment tab hands the Count screen: a toggle that starts/stops
/// the tab's own voice engine, and a status read the screen polls to repaint.
class CountVoiceHooks {
  final Future<void> Function() toggle;
  final CountVoiceStatus Function() status;

  const CountVoiceHooks({required this.toggle, required this.status});
}
