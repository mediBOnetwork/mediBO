import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// App-wide animation constants that auto-adjust to the runtime environment.
///
/// On web, CanvasKit renders at the browser's refresh rate (typically 60 Hz,
/// up to 120 Hz on high-refresh displays). On mobile the OS controls VSYNC.
/// There is no reliable way to detect low-end hardware from Dart, so we use
/// the same durations everywhere and let the GPU/CPU decide the actual FPS.
abstract final class PerformanceConfig {
  /// Standard one-shot transition (page entrance, card pop-in).
  static const Duration standard = Duration(milliseconds: 300);

  /// Fast micro-interaction (button tap, badge pulse).
  static const Duration fast = Duration(milliseconds: 180);

  /// Slow reveal used for hero sections and celebration banners.
  static const Duration slow = Duration(milliseconds: 550);

  /// Default easing for entrances: slight overshoot feels snappy.
  static const Curve entranceCurve = Curves.easeOutCubic;

  /// Easing for exits: quick fade-out, no overshoot.
  static const Curve exitCurve = Curves.easeIn;

  /// Spring curve for elastic pop effects (bounce, slide-up).
  static const Curve springCurve = Curves.elasticOut;

  /// Returns true on Flutter web. Useful to skip expensive effects that
  /// don't render well in CanvasKit (e.g. BackdropFilter on low-spec devices).
  static bool get isWeb => kIsWeb;
}
