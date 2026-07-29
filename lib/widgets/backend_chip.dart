// CHANGE #606 — the one chip the backend paints.
//
// Every status chip on the admin Customer Orders tab and the admin Supplier
// Orders table used to be built by a Dart `switch (status)` that owned both the
// label and the colour. That is the app answering "what do I show?", and it is
// the exact class of bug this repo's first rule exists to kill: the screen and
// `app_settings.order_status_chips` each held an answer and could disagree.
//
// The backend now returns a whole chip — {label, bg, fg, border, show} — from
// public.status_chip(group, value). This widget paints it and nothing else.
//
// `show:false` (or an empty label) means DO NOT RENDER. There is deliberately
// no Dart fallback label and no fallback colour: inventing one is deciding, and
// substituting a default for an empty backend string is what left an empty
// yellow blob on the Bag tab. An absent chip renders zero pixels.
import 'package:flutter/material.dart';

/// Parses a backend `#RRGGBB` / `#AARRGGBB` string. [fallback] is used only when
/// the string is malformed — never to substitute a colour the backend withheld,
/// because a withheld chip is not rendered at all (see [BackendChip]).
Color backendHex(String? hex, Color fallback) {
  var h = (hex ?? '').trim();
  if (h.isEmpty) return fallback;
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length == 6) h = 'FF$h';
  if (h.length != 8) return fallback;
  final v = int.tryParse(h, radix: 16);
  return v == null ? fallback : Color(v);
}

/// Reads a `{label,bg,fg,border,show}` chip object out of a backend row.
/// Returns `null` when the key is missing or the object is not a Map, so the
/// caller renders nothing rather than guessing.
Map<String, dynamic>? backendChipOf(Map<String, dynamic> row, String key) {
  final c = row[key];
  return c is Map ? c.cast<String, dynamic>() : null;
}

/// True when the backend says this chip should be painted.
bool backendChipVisible(Map<String, dynamic>? chip) {
  if (chip == null) return false;
  if (chip['show'] != true) return false;
  return (chip['label'] as String? ?? '').trim().isNotEmpty;
}

/// Paints a backend-supplied chip verbatim. Renders nothing when the backend
/// says not to.
class BackendChip extends StatelessWidget {
  final Map<String, dynamic>? chip;
  final double fontSize;
  final EdgeInsets padding;
  final IconData? icon;

  const BackendChip({
    super.key,
    required this.chip,
    this.fontSize = 11,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    if (!backendChipVisible(chip)) return const SizedBox.shrink();
    final c = chip!;
    final label = c['label'] as String;
    final bg = backendHex(c['bg'] as String?, const Color(0xFFEDEFF2));
    final fg = backendHex(c['fg'] as String?, const Color(0xFF5A6472));
    final border = backendHex(c['border'] as String?, bg);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, size: fontSize, color: fg),
          const SizedBox(width: 3),
        ],
        Flexible(
          child: Text(
            label,
            style: TextStyle(
                fontSize: fontSize, fontWeight: FontWeight.w600, color: fg),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ]),
    );
  }
}

/// Lays out several backend chips, dropping the hidden ones. Renders nothing
/// when every chip is hidden — no empty container, no stray spacing.
class BackendChipRow extends StatelessWidget {
  final List<Map<String, dynamic>?> chips;
  final double spacing;
  final double fontSize;

  const BackendChipRow({
    super.key,
    required this.chips,
    this.spacing = 4,
    this.fontSize = 11,
  });

  @override
  Widget build(BuildContext context) {
    final visible = chips.where(backendChipVisible).toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: spacing,
      runSpacing: spacing,
      children: [
        for (final c in visible) BackendChip(chip: c, fontSize: fontSize),
      ],
    );
  }
}
