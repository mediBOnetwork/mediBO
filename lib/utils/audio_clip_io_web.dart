// Web ClipPlayer via html.AudioElement — verbatim behaviour from the original
// fulfillment code (bare AudioElement, no Web Audio routing).
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

class ClipPlayer {
  html.AudioElement? _el;
  void Function()? _onEnded;
  void Function()? _onError;

  void onEnded(void Function() cb) => _onEnded = cb;
  void onError(void Function() cb) => _onError = cb;

  Future<void> play(String src) async {
    final el = html.AudioElement(src);
    _el = el;
    el.onEnded.listen((_) => _onEnded?.call());
    el.onError.listen((_) => _onError?.call());
    await el.play();
  }

  /// Interrupt playback. Does NOT fire onEnded (matches the pause()+src='' path).
  void stop() {
    _el?.pause();
    _el?.src = '';
    _el = null;
  }
}
