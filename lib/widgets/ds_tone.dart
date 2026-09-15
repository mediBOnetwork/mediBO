import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// CHANGE #671 (gap 51) — the ONE place a backend tone NAME becomes a colour.
///
/// A screen that branches on a status string to pick a hex is making a display
/// decision client-side; that is the same bug as the hardcoded literal, only
/// wearing a switch. The backend answers with a tone — 'success' / 'warning' /
/// 'danger' / 'info' / 'neutral' — and the app performs exactly one lookup.
///
/// An unknown tone stays NEUTRAL rather than throwing or guessing, so a tone
/// this build has never heard of degrades to a quiet chip instead of a crash.
Color dsToneFg(String? tone) {
  switch (tone) {
    case 'success':
      return Ds.c.success;
    case 'warning':
      return Ds.c.warning;
    case 'danger':
      return Ds.c.danger;
    case 'info':
      return Ds.c.info;
    case 'brand':
      return Ds.c.brand;
    default:
      return Ds.c.textSecondary;
  }
}

Color dsToneBg(String? tone) {
  switch (tone) {
    case 'success':
      return Ds.c.successSoft;
    case 'warning':
      return Ds.c.warningSoft;
    case 'danger':
      return Ds.c.dangerSoft;
    case 'info':
      return Ds.c.infoSoft;
    case 'brand':
      return Ds.c.brandSoft;
    default:
      return Ds.c.bg;
  }
}
