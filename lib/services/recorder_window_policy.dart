// CHANGE #635 — the recorder's DECISIONS, extracted away from the recorder.
//
// ContinuousVoiceSession / PackVoiceSession own MediaRecorder plumbing: start a
// window, stop it, upload the blob, transcribe, write mentions. Mixed into that
// plumbing were four judgement calls that no test could reach, because reaching
// them meant driving a real microphone:
//
//   1. after closing a window, may we open another one?
//   2. is the window we just closed worth submitting at all?
//   3. did a completed window count something, hear silence, or actually fail?
//   4. does the operator see the red "failed to save" toast?
//
// A wrong answer to (1) spawned a spurious trailing window on every Stop (live:
// 2.webm, 11 KB, ~1 s, finalized 80 ms after window 1). A wrong answer to (3)
// turned ordinary silence into a red error toast mid-count.
//
// This class holds those four answers and nothing else. No dart:html, no
// `record` plugin, no Supabase, no Flutter — pure Dart, so test/protected/
// recorder_policy_test.dart drives every branch in milliseconds.
library;

/// What a finished recording window turned out to be.
enum WindowOutcome {
  /// Transcribed and produced at least one mention. Normal.
  counted,

  /// Uploaded and registered cleanly, but the mic heard nothing worth counting
  /// — empty transcript, or a transcript with no mentions in it. This is the
  /// common case between spoken items and it is NOT an error: no toast, no
  /// interruption, counting continues.
  silent,

  /// A real failure: storage upload threw, voice_clip_register answered
  /// ok:false, or the transcribe call errored. Only this reaches the operator.
  error,
}

/// The recorder's window lifecycle decisions, as pure functions.
///
/// Const-constructible and stateless — every session can share one instance,
/// and a test can construct one with a different [minStopWindowSec] without
/// touching global state.
class RecorderWindowPolicy {
  /// A window closed by Stop shorter than this is a stop artifact, not audio
  /// the operator meant to record. ~1 s trailing windows are what the rotation
  /// leaves open when Stop lands just after a rotate; they contain no speech,
  /// cost an upload plus a transcribe round trip, and their failures surfaced
  /// as a red toast on an otherwise successful count.
  ///
  /// Mid-session rotations are never subject to this — a rotation only fires on
  /// the 24 s timer, so its window is 24 s by construction, and dropping a
  /// short one would silently discard real speech.
  final double minStopWindowSec;

  const RecorderWindowPolicy({this.minStopWindowSec = 2.0});

  /// May the recorder open a new window after closing one?
  ///
  /// Once Stop has been requested the answer is permanently no. The recorder
  /// must re-ask this AFTER its `start()` future resolves as well as before it:
  /// Stop can land while start() is still in flight, and a window opened in
  /// that gap outlives the session — the mic stays hot with nobody left to
  /// close it.
  bool shouldStartNewWindow({required bool stopping}) => !stopping;

  /// Is the window that just closed worth uploading + transcribing?
  ///
  /// [atStop] distinguishes the final window (closed because the operator hit
  /// Stop) from a mid-session rotation. Only the final one can be a stop
  /// artifact.
  bool shouldSubmitWindow({
    required double durationSec,
    required bool atStop,
  }) {
    if (!atStop) return true;
    return durationSec >= minStopWindowSec;
  }

  /// Classify a window that finished its upload → transcribe → write pipeline.
  ///
  /// [error] is whatever the pipeline threw, or null if it completed.
  /// [registerOk] is voice_clip_register's own `ok` field — false means the
  /// usage ledger refused the clip, which is a real failure even though nothing
  /// threw. Daily-cap refusals are NOT routed here; they have their own limit
  /// sheet and must not also raise the failure toast.
  WindowOutcome classifyWindowResult({
    Object? error,
    String transcript = '',
    int mentionCount = 0,
    bool registerOk = true,
  }) {
    if (error != null) return WindowOutcome.error;
    if (!registerOk) return WindowOutcome.error;
    if (transcript.trim().isEmpty || mentionCount <= 0) {
      return WindowOutcome.silent;
    }
    return WindowOutcome.counted;
  }

  /// The red "A recording window failed to save" toast fires for exactly one
  /// outcome. Silence is not a failure and must never interrupt a count.
  bool shouldShowFailureToast(WindowOutcome outcome) =>
      outcome == WindowOutcome.error;
}
