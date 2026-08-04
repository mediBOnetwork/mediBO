import 'package:flutter/material.dart';

/// Shared rendering primitives for the WhatsApp template manager.
///
/// The ONLY mapping allowed in this file is tone -> theme colour, which
/// CLAUDE.md permits explicitly. Every label, every string and every number
/// arrives from the backend already decided. In particular there is no
/// status -> label map and no status -> colour map here: the payload carries
/// `status_label` and `status_tone`, and an unrecognised tone falls back to
/// grey rather than throwing, because Meta adds statuses over time.

/// Backend-owned copy for the template manager.
///
/// Every user-facing string in this feature is looked up here, so rewording is
/// an UPDATE on app_settings.wa_templates_copy — never a deploy. A missing key
/// returns "" rather than throwing, so a copy row that has not caught up with a
/// new widget degrades to a blank label instead of a crash.
class WaCopy {
  final Map<String, dynamic> _m;
  const WaCopy(this._m);

  String operator [](String key) => (_m[key] ?? '').toString();

  /// Fills the backend's own placeholders ({n}, {name}) into the backend's own
  /// sentence. The sentence itself is never assembled here.
  String sub(String key, Map<String, String> vars) {
    var s = this[key];
    vars.forEach((k, v) => s = s.replaceAll('{$k}', v));
    return s;
  }
}

class WaTone {
  final Color bg;
  final Color fg;
  final Color dot;
  const WaTone({required this.bg, required this.fg, required this.dot});

  static const _green =
      WaTone(bg: Color(0xFFD1FAE5), fg: Color(0xFF065F46), dot: Color(0xFF059669));
  static const _yellow =
      WaTone(bg: Color(0xFFFEF3C7), fg: Color(0xFF92400E), dot: Color(0xFFD97706));
  static const _red =
      WaTone(bg: Color(0xFFFEE2E2), fg: Color(0xFF991B1B), dot: Color(0xFFDC2626));
  static const _grey =
      WaTone(bg: Color(0xFFF3F4F6), fg: Color(0xFF6B7280), dot: Color(0xFF9CA3AF));

  /// Unknown / null / misspelled tones render grey. Never throws — a new Meta
  /// status arriving with a tone we have never seen must still paint.
  static WaTone of(Object? tone) {
    switch ((tone ?? '').toString().toLowerCase()) {
      case 'green':
        return _green;
      case 'yellow':
      case 'amber':
        return _yellow;
      case 'red':
        return _red;
      default:
        return _grey;
    }
  }
}

/// A small pill. `label` is printed verbatim — never pluralised, capitalised or
/// reworded here.
class WaChip extends StatelessWidget {
  final String label;
  final Object? tone;
  final String? value;
  final IconData? icon;

  const WaChip({
    super.key,
    required this.label,
    this.tone,
    this.value,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final t = WaTone.of(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: t.fg),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w500, color: t.fg),
          ),
          if (value != null) ...[
            const SizedBox(width: 6),
            Text(
              value!,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: t.fg),
            ),
          ],
        ],
      ),
    );
  }
}

/// A coloured dot — used for quality_tone, where the score itself is the label.
class WaDot extends StatelessWidget {
  final Object? tone;
  const WaDot({super.key, this.tone});

  @override
  Widget build(BuildContext context) => Container(
        width: 8,
        height: 8,
        decoration:
            BoxDecoration(color: WaTone.of(tone).dot, shape: BoxShape.circle),
      );
}

/// An inline banner. Title + body, both verbatim from the payload.
class WaBanner extends StatelessWidget {
  final String? title;
  final String? body;
  final Object? tone;
  final Widget? action;

  /// One entry per backend message, each rendered as its own line. Used for
  /// errors[] / warnings[] so every message stays a separate, verbatim string
  /// rather than being joined into one blob.
  final List<String>? lines;

  const WaBanner(
      {super.key, this.title, this.body, this.tone, this.action, this.lines});

  @override
  Widget build(BuildContext context) {
    final t = WaTone.of(tone);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if ((title ?? '').isNotEmpty)
            Text(
              title!,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700, color: t.fg),
            ),
          if ((body ?? '').isNotEmpty) ...[
            if ((title ?? '').isNotEmpty) const SizedBox(height: 4),
            Text(
              body!,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w400, color: t.fg),
            ),
          ],
          for (final line in lines ?? const <String>[])
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                line,
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w400, color: t.fg),
              ),
            ),
          if (action != null) ...[
            const SizedBox(height: 8),
            action!,
          ],
        ],
      ),
    );
  }
}

/// The WhatsApp bubble.
///
/// Every string here comes out of wa_template_preview(): `body` is already
/// rendered with the example values substituted, so this widget never touches
/// {{n}} and never joins strings together. Passing the payload straight through
/// is the point — the bubble and the message Meta actually sends cannot drift.
class WaPreviewBubble extends StatelessWidget {
  final Map<String, dynamic> preview;
  const WaPreviewBubble({super.key, required this.preview});

  @override
  Widget build(BuildContext context) {
    final header = preview['header'];
    final headerText =
        header is Map ? (header['text'] ?? '').toString() : '';
    final body = (preview['body'] ?? '').toString();
    final footer = (preview['footer'] ?? '').toString();
    final buttons = (preview['buttons'] as List?) ?? const [];

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFE7F8D8),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 8,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (headerText.isNotEmpty) ...[
                  Text(
                    headerText,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF111827)),
                  ),
                  const SizedBox(height: 6),
                ],
                Text(
                  body,
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w400,
                      height: 1.35,
                      color: Color(0xFF111827)),
                ),
                if (footer.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    footer,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        color: Color(0xFF6B7280)),
                  ),
                ],
              ],
            ),
          ),
          for (final b in buttons)
            if (b is Map)
              Container(
                decoration: const BoxDecoration(
                  border: Border(
                      top: BorderSide(color: Color(0x22000000), width: 0.5)),
                ),
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(_buttonIcon(b['type']),
                        size: 14, color: const Color(0xFF1E40AF)),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        (b['text'] ?? '').toString(),
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF1E40AF)),
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  /// Icon per button type. Unknown types get a neutral icon rather than an
  /// error — Meta may add button types we have not seen.
  static IconData _buttonIcon(Object? type) {
    switch ((type ?? '').toString().toUpperCase()) {
      case 'URL':
        return Icons.open_in_new;
      case 'PHONE_NUMBER':
        return Icons.call_outlined;
      case 'QUICK_REPLY':
        return Icons.reply_outlined;
      default:
        return Icons.smart_button_outlined;
    }
  }
}

/// Grey block used while the list / preview loads. Never a blank screen.
class WaSkeleton extends StatelessWidget {
  final double height;
  final double? width;
  const WaSkeleton({super.key, this.height = 14, this.width});

  @override
  Widget build(BuildContext context) => Container(
        height: height,
        width: width,
        decoration: BoxDecoration(
          color: const Color(0xFFE5E7EB),
          borderRadius: BorderRadius.circular(6),
        ),
      );
}

/// Standard error state with a retry — used by both the list and the editor.
class WaErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const WaErrorState({super.key, required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: Color(0xFF6B7280)),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF1B7A43)),
                foregroundColor: const Color(0xFF1B7A43),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
}
