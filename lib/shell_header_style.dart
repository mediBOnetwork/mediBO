// CMD #2187 (Om, live on CHANGE #1527) — THE HEADER ROW'S OWN NUMBERS.
//
// Om, looking at the live header: "nothing is aligned. The logo green, the
// pill and the bell icon are three different heights, so the row looks
// broken." The cause is in the artwork, not the layout: the logo PNG is
// 65.2% artwork and 34.8% white (90 px above, 88 px below on a 512 canvas),
// so a 40 dp tile showed only 26 dp of GREEN beside a 40 dp pill.
//
// The fix is a set of numbers, and they are already rows:
// `shell_style().header` carries logo_size 49 (49 × 0.652 = 32 of visible
// green), logo_radius 11, bell_icon 32 with a 40 dp tap box, pad_y 3.5 and
// align "center". `header_status_pill().style` carries the pill at 32/16 and
// its own max_w. Measure the GREEN, never the tile — the tile's white edges
// are invisible on a white header.
//
// This file is the wire, exactly as `shell_motion.dart` is for the motion
// policy: `shellStyleLoad()` publishes the block here once per session, the
// header row and the pieces inside it read it, and the design tokens are what
// each one falls back to until it lands. Re-tuning the row is an UPDATE.

import 'package:flutter/foundation.dart';

/// `shell_style().header`, verbatim. Empty until the payload lands.
final ValueNotifier<Map<String, dynamic>> shellHeaderStyle =
    ValueNotifier<Map<String, dynamic>>(const <String, dynamic>{});

void shellHeaderStylePublish(Map<String, dynamic> header) =>
    shellHeaderStyle.value = header;

/// One of the block's numbers, or [fallback] while the payload is in flight.
double shellHeaderNum(String key, double fallback) {
  final v = shellHeaderStyle.value[key];
  return v is num ? v.toDouble() : fallback;
}

/// Om's rule, as the row reads it: the green, the pill and the bell share ONE
/// centre line through the middle of the 56 dp row. Never top, never baseline.
bool get shellHeaderCentred =>
    (shellHeaderStyle.value['align'] ?? 'center') == 'center';
