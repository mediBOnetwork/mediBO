// PROTECTED — CHANGE #635.
//
// See CLAUDE.md: this file runs before EVERY deploy. It may only be edited by a
// CHANGE that deliberately changes recorder window behaviour, never to make an
// unrelated change go green.
//
// What broke, and what these tests hold down:
//
//   Stop produced a spurious trailing window. Live evidence: 2.webm, 11 KB,
//   ~1 s of audio, finalized 80 ms after window 1. Two independent causes —
//   the recorder could open a window while Stop was already in flight, and
//   whatever window happened to be open at Stop was uploaded no matter how
//   short it was.
//
//   Ordinary silence raised the red "A recording window failed to save" toast.
//   A window that uploads and registers cleanly but transcribes to nothing is
//   the NORMAL state between two spoken items; it must pass in silence.
//
// Pure Dart, no mic, no network. Milliseconds.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/services/recorder_window_policy.dart';

void main() {
  const policy = RecorderWindowPolicy();

  group('stop never opens another window', () {
    test('a new window is allowed only while the session is running', () {
      expect(policy.shouldStartNewWindow(stopping: false), isTrue);
      expect(policy.shouldStartNewWindow(stopping: true), isFalse);
    });

    test('the answer stays no once stopping — asked before OR after start()', () {
      // The recorder asks twice: once before awaiting start(), once after it
      // resolves. Stop can land in that gap, and the window opened there is the
      // one nobody ever closes. Both asks must refuse.
      var stopping = false;
      final askedBefore = policy.shouldStartNewWindow(stopping: stopping);
      stopping = true; // Stop lands mid-start()
      final askedAfter = policy.shouldStartNewWindow(stopping: stopping);

      expect(askedBefore, isTrue, reason: 'was still running when start() began');
      expect(askedAfter, isFalse,
          reason: 'Stop raced start() — that window must be discarded, not kept');
    });
  });

  group('sub-2s stop artifact is never submitted', () {
    test('the ~1s trailing window seen live is dropped', () {
      expect(
        policy.shouldSubmitWindow(durationSec: 1.0, atStop: true),
        isFalse,
        reason: '2.webm/11KB/1s must never reach upload or transcribe',
      );
    });

    test('every sub-threshold duration at stop is dropped', () {
      for (final d in <double>[0.0, 0.08, 0.5, 1.0, 1.9, 1.999]) {
        expect(policy.shouldSubmitWindow(durationSec: d, atStop: true), isFalse,
            reason: '${d}s at stop is a stop artifact');
      }
    });

    test('a real final window is still submitted — 2s is the boundary', () {
      expect(policy.shouldSubmitWindow(durationSec: 2.0, atStop: true), isTrue);
      expect(policy.shouldSubmitWindow(durationSec: 7.5, atStop: true), isTrue);
      expect(policy.shouldSubmitWindow(durationSec: 24.0, atStop: true), isTrue);
    });

    test('a MID-SESSION rotation is never dropped, however short', () {
      // Rotations fire on the 24s timer, so a short one means the clock was
      // read oddly — dropping it would silently discard real speech.
      for (final d in <double>[0.1, 1.0, 1.9, 24.0]) {
        expect(policy.shouldSubmitWindow(durationSec: d, atStop: false), isTrue,
            reason: 'rotation windows carry real audio');
      }
    });
  });

  group('silence is not an error', () {
    test('empty transcript is silent — no toast', () {
      final o = policy.classifyWindowResult(transcript: '', mentionCount: 0);
      expect(o, WindowOutcome.silent);
      expect(policy.shouldShowFailureToast(o), isFalse);
    });

    test('whitespace-only transcript is silent', () {
      final o = policy.classifyWindowResult(transcript: '   \n\t ', mentionCount: 0);
      expect(o, WindowOutcome.silent);
      expect(policy.shouldShowFailureToast(o), isFalse);
    });

    test('a transcript with ZERO mentions is silent, not an error', () {
      // The mic heard the room, Gemini found no countable item in it.
      final o = policy.classifyWindowResult(
          transcript: 'uh, hold on', mentionCount: 0);
      expect(o, WindowOutcome.silent);
      expect(policy.shouldShowFailureToast(o), isFalse);
    });

    test('a window with mentions counted', () {
      final o = policy.classifyWindowResult(
          transcript: 'dolo 650 ten strips', mentionCount: 1);
      expect(o, WindowOutcome.counted);
      expect(policy.shouldShowFailureToast(o), isFalse);
    });
  });

  group('only a real failure toasts', () {
    test('a thrown exception is an error', () {
      final o = policy.classifyWindowResult(error: Exception('upload failed'));
      expect(o, WindowOutcome.error);
      expect(policy.shouldShowFailureToast(o), isTrue);
    });

    test('voice_clip_register ok:false is an error even with a good transcript', () {
      final o = policy.classifyWindowResult(
          transcript: 'dolo 650', mentionCount: 2, registerOk: false);
      expect(o, WindowOutcome.error);
      expect(policy.shouldShowFailureToast(o), isTrue);
    });

    test('an error outranks silence — a failed upload has no transcript', () {
      final o = policy.classifyWindowResult(
          error: StateError('storage 500'), transcript: '', mentionCount: 0);
      expect(o, WindowOutcome.error,
          reason: 'an empty transcript caused BY a failure is not silence');
      expect(policy.shouldShowFailureToast(o), isTrue);
    });

    test('exactly one outcome ever toasts', () {
      expect(policy.shouldShowFailureToast(WindowOutcome.counted), isFalse);
      expect(policy.shouldShowFailureToast(WindowOutcome.silent), isFalse);
      expect(policy.shouldShowFailureToast(WindowOutcome.error), isTrue);
    });
  });
}
