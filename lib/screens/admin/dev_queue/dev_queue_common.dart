import 'package:flutter/material.dart';
import '../../../services/ui_copy.dart';

/// Presentation tokens for the Dev Queue tab.
///
/// Colours here are the DESIGN SYSTEM state palette from CLAUDE.md (fixed
/// design tokens, not business content). Every visible word is a backend
/// string via [c] — a status enum maps to `dev_queue.status_<enum>`, never to
/// a Dart literal.

class Tone {
  final Color bg;
  final Color fg;
  const Tone(this.bg, this.fg);
}

const _success = Tone(Color(0xFFD1FAE5), Color(0xFF065F46));
const _warning = Tone(Color(0xFFFEF3C7), Color(0xFF92400E));
const _error = Tone(Color(0xFFFEE2E2), Color(0xFF991B1B));
const _info = Tone(Color(0xFFEFF6FF), Color(0xFF1E40AF));
const _neutral = Tone(Color(0xFFF3F4F6), Color(0xFF374151));

const kBorder = Color(0xFFE5E7EB);
const kBrand = Color(0xFF1B7A43);
const kPageBg = Color(0xFFF5F6F8);
const kTextHi = Color(0xFF111827);
const kTextLo = Color(0xFF6B7280);

Tone statusTone(String status) {
  switch (status) {
    case 'completed':
      return _success;
    case 'failed':
      return _error;
    case 'building':
      return _info;
    case 'needs_input':
    case 'awaiting_approval':
      return _warning;
    case 'paused':
    case 'cancelled':
      return _neutral;
    default: // pending
      return _info;
  }
}

String statusLabel(String status) => c('dev_queue.status_$status');

/// Maps a backend-chosen tone NAME (the server decides which lane/state colour a
/// chip wears — the app only resolves the name to the fixed design palette).
Tone toneByName(String name) {
  switch (name) {
    case 'success':
      return _success;
    case 'warning':
      return _warning;
    case 'error':
      return _error;
    case 'info':
      return _info;
    default: // neutral
      return _neutral;
  }
}

/// Presentation-only icon for a build route (fast/sonnet/opus). The label and
/// colour come from the backend; only this glyph is chosen locally, the same way
/// existing chips pick Icons.cloud / Icons.android for their kind.
IconData routeIcon(String route) {
  switch (route) {
    case 'fast':
      return Icons.bolt;
    case 'sonnet':
      return Icons.auto_awesome;
    case 'opus':
      return Icons.psychology_outlined;
    default:
      return Icons.memory;
  }
}

Tone androidTone(String s) {
  switch (s) {
    case 'built':
      return _success;
    case 'failed':
      return _error;
    case 'building':
    case 'requested':
      return _warning;
    default:
      return _neutral;
  }
}

String androidLabel(String s) => c('dev_queue.android_$s');

/// UTC ISO → `d MMM, HH:mm` in IST (UTC+5:30). Internal ops tool only; the
/// dev_cmd_list payload carries raw timestamps, so this local format is the
/// single place it happens and is never shown to customers.
String istShort(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final dt = DateTime.tryParse(iso);
  if (dt == null) return '';
  final ist = dt.toUtc().add(const Duration(hours: 5, minutes: 30));
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  final hh = ist.hour.toString().padLeft(2, '0');
  final mm = ist.minute.toString().padLeft(2, '0');
  return '${ist.day} ${months[ist.month - 1]}, $hh:$mm';
}

String rupee(num? v) => '₹${(v ?? 0).toStringAsFixed(2)}';

int asInt(dynamic v) => (v as num?)?.toInt() ?? 0;

/// The backend's render-ready "model · effort · mode" chip (e.g.
/// "opus-4-8 · high · standard"), or its "opus-4-8 (assumed)" label for a
/// historical row with no model. Composed in SQL (_dev_model_chip) and rendered
/// here verbatim — no model id or separator is assembled in Dart.
String priceModelChip(Map row) => (row['model_chip'] ?? '').toString();

/// The backend's render-ready cost caption, verbatim — e.g.
/// "₹93 — API-equivalent (included in your Max plan · ₹0 extra)". Empty when the
/// row has no usage yet. No price is computed or worded in Dart.
String costNote(Map row) => (row['cost_note'] ?? '').toString();

/// A small pill used for status / android / flags.
class ToneChip extends StatelessWidget {
  final String label;
  final Tone tone;
  final IconData? icon;
  final bool spinning;
  const ToneChip(
      {super.key,
      required this.label,
      required this.tone,
      this.icon,
      this.spinning = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: tone.bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (spinning)
          SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(strokeWidth: 2, color: tone.fg),
          )
        else if (icon != null)
          Icon(icon, size: 13, color: tone.fg),
        if (spinning || icon != null) const SizedBox(width: 5),
        Text(label,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: tone.fg)),
      ]),
    );
  }
}

/// White card wrapper matching the design system — soft shadow, hairline
/// border, and an optional coloured status accent bar down the left edge that
/// makes each card scannable at a glance.
class DqCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final Color? accent;
  const DqCard(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(16),
      this.onTap,
      this.accent});

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: radius,
        border: Border.all(color: kBorder),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 8,
              offset: const Offset(0, 2)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (accent != null)
                Container(width: 4, color: accent),
              Expanded(child: Padding(padding: padding, child: child)),
            ]),
          ),
        ),
      ),
    );
  }
}
