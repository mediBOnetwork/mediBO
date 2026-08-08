// Native ClipPlayer via package:audioplayers — mirrors audio_clip_io_web.dart.
import 'dart:async';
import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';

class ClipPlayer {
  final AudioPlayer _p = AudioPlayer();
  void Function()? _onEnded;
  void Function()? _onError;
  StreamSubscription<void>? _endSub;

  void onEnded(void Function() cb) {
    _onEnded = cb;
    _endSub ??= _p.onPlayerComplete.listen((_) => _onEnded?.call());
  }

  void onError(void Function() cb) => _onError = cb;

  Future<void> play(String src) async {
    try {
      if (src.startsWith('data:')) {
        final b64 = src.substring(src.indexOf(',') + 1);
        await _p.play(BytesSource(base64Decode(b64)));
      } else {
        await _p.play(UrlSource(src));
      }
    } catch (_) {
      _onError?.call();
    }
  }

  void stop() {
    _p.stop();
    _endSub?.cancel();
    _endSub = null;
  }
}
