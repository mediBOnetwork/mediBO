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
/// Two vocabularies reach this function and both are the backend's. The
/// campaign/template RPCs speak colours (green/yellow/red/blue); the budget,
/// segment and sequence RPCs added later speak meanings (good/warn/bad/muted).
/// They are aliases onto the same four palettes — the app still holds no
/// status -> colour map, only tone -> palette.
(Color, Color) waToneColors(String? tone) => switch (tone) {
      'green' || 'good' => (const Color(0xFFD1FAE5), const Color(0xFF065F46)),
      'yellow' || 'warn' => (const Color(0xFFFEF3C7), const Color(0xFF92400E)),
      'red' || 'bad' => (const Color(0xFFFEE2E2), const Color(0xFF991B1B)),
      'blue' => (const Color(0xFFDBEAFE), const Color(0xFF1E40AF)),
      // 'muted' lands here deliberately, alongside every tone a future backend
      // invents: grey with the label intact.
      _ => (const Color(0xFFF3F4F6), const Color(0xFF4B5563)),
    };

/// The bar under a `*_label` chip — budget spend today, and whatever else the
/// backend later reports as a percentage.
///
/// `pct` is the backend's number. It is clamped only because the widget cannot
/// draw past its own width; the LABEL beside it, not this bar, is what states
/// how far over the cap a campaign went.
class WaToneBar extends StatelessWidget {
  final num pct;
  final String? tone;
  const WaToneBar({super.key, required this.pct, this.tone});

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = waToneColors(tone);
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
        value: (pct / 100).clamp(0.0, 1.0).toDouble(),
        minHeight: 6,
        backgroundColor: bg,
        valueColor: AlwaysStoppedAnimation(fg),
      ),
    );
  }
}

/// A backend sentence in a warn-toned box. Used for blank_warning and for the
/// control-group refusal — both are things the admin must read but neither
/// blocks anything, so neither is an error state.
class WaWarnBanner extends StatelessWidget {
  final String text;
  const WaWarnBanner({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF3C7),
        border: Border.all(color: const Color(0xFFFDE68A)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_outlined,
              size: 15, color: Color(0xFF92400E)),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                  fontSize: 12, height: 1.35, color: Color(0xFF92400E)),
            ),
          ),
        ],
      ),
    );
  }
}

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
