// CHANGE — WhatsApp campaign builder + tracking link redirect.
//
// The ONE place that turns a backend `*_tone` token into pixels. The app holds
// no status -> colour map and no status -> label map: the payload carries both
// `status_label` (the words) and `status_tone` (which of five palettes), and
// this file only looks up the palette.
//
// An unknown tone is NOT an error and MUST NOT throw. wa_campaign_detail()
// already emits a tone ('blue') that wa_campaigns_screen() never emits, and a
// backend that adds a sixth tomorrow must not blank an admin's screen. Anything
// unrecognised renders grey with the label untouched.
import 'package:flutter/material.dart';

/// (background, foreground) for a backend tone token.
///
/// Grey is the fallback, never a failure: an unknown tone still renders its
/// label, which is the part the admin actually needs to read.
(Color, Color) waToneColors(String? tone) => switch (tone) {
      'green' => (const Color(0xFFD1FAE5), const Color(0xFF065F46)),
      'yellow' => (const Color(0xFFFEF3C7), const Color(0xFF92400E)),
      'red' => (const Color(0xFFFEE2E2), const Color(0xFF991B1B)),
      'blue' => (const Color(0xFFDBEAFE), const Color(0xFF1E40AF)),
      _ => (const Color(0xFFF3F4F6), const Color(0xFF4B5563)),
    };

/// A status chip. `label` is printed verbatim — it is the backend's sentence,
/// not a key this app is allowed to translate.
class WaToneChip extends StatelessWidget {
  final String label;
  final String? tone;
  final double fontSize;

  const WaToneChip({
    super.key,
    required this.label,
    this.tone,
    this.fontSize = 11.5,
  });

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = waToneColors(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }
}

/// A plain outlined chip for values that carry no tone (category, language).
class WaPlainChip extends StatelessWidget {
  final String label;
  const WaPlainChip({super.key, required this.label});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFFF9FAFB),
          border: Border.all(color: const Color(0xFFE5E7EB)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Color(0xFF4B5563),
          ),
        ),
      );
}
