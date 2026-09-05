import 'package:flutter/material.dart';
import '../../../design_tokens.dart';
import '../../../services/ui_copy.dart';
import 'restart_safety.dart';

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
    // 'danger' is the design-token name for the destructive tone and it is what
    // _dev_breaker_badge() sends. Without this case an auto-pause rendered grey,
    // which reads as "fine" — the one thing that badge must never look like.
    case 'danger':
      return _error;
    case 'info':
      return _info;
    default: // neutral
      return _neutral;
  }
}

/// Presentation-only glyph for a restart-safety chip (CHANGE #233). The label
/// and the tone arrive from the backend; only this icon is chosen locally, the
/// same way routeIcon picks a glyph for a route.
IconData safetyChipIcon(SafetyChipKind kind) {
  switch (kind) {
    case SafetyChipKind.offline:
      return Icons.cloud_off_outlined;
    case SafetyChipKind.agentSilent:
      return Icons.hourglass_disabled_outlined;
    case SafetyChipKind.stall:
      return Icons.report_problem_outlined;
    case SafetyChipKind.stepsStale:
      return Icons.rule_folder_outlined;
    case SafetyChipKind.steps:
      return Icons.checklist_rtl;
    case SafetyChipKind.resumed:
      return Icons.restart_alt;
  }
}

/// Presentation-only icon for a build route (fast/sonnet/opus). The label and
/// colour come from the backend; only this glyph is chosen locally, the same way
/// existing chips pick Icons.cloud / Icons.android for their kind.
IconData routeIcon(String route) {
  switch (route) {
    case 'fast':
      return Icons.bolt;
    case 'haiku':
      return Icons.eco_outlined;
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
        // CHANGE #1570 — Flexible, so a chip carrying a SENTENCE wraps inside
        // whatever width its parent gives it instead of overflowing. The Row is
        // still mainAxisSize.min, so a short label is still hugged; this only
        // bites when the parent has already constrained the chip (a Flexible
        // ToneChip in a Row), which is exactly when clipping the backend's own
        // words would be worst.
        Flexible(
          child: Text(label,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: tone.fg)),
        ),
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

// ── CHANGE #571 — completion integrity, on the screen ────────────────────────
// Two states the queue previously could not show, and the reason #536 read as
// a failure it never was. Both are PURE views over the backend payload: they
// choose nothing, compose nothing and format nothing. Held down by
// test/protected/completion_integrity_test.dart.

/// A command that is WAITING (parked on a lease, a merge retry, a busy DB) —
/// not failed. The chip text, the reassurance line and the tone are all the
/// backend's own strings; absent fields mean "not waiting", never a guess.
class WaitView {
  final bool waiting;
  final String chip;
  final String hint;
  final String reason;
  final String kind;
  final Tone tone;

  const WaitView({
    required this.waiting,
    required this.chip,
    required this.hint,
    required this.reason,
    required this.kind,
    required this.tone,
  });

  factory WaitView.fromRow(Map<String, dynamic> row) {
    final waiting = row['is_waiting'] == true;
    return WaitView(
      // A row is waiting only when the BACKEND says so. A `wait_chip` with no
      // flag renders nothing: the flag is the state, the chip is the wording.
      waiting: waiting,
      chip: waiting ? (row['wait_chip'] ?? '').toString() : '',
      hint: waiting ? (row['wait_hint'] ?? '').toString() : '',
      reason: (row['wait_reason'] ?? '').toString(),
      kind: (row['wait_kind'] ?? '').toString(),
      tone: toneByName((row['wait_tone'] ?? 'warning').toString()),
    );
  }
}

/// One line of a command's own spec checklist.
class SpecItemView {
  final int n;
  final String text;
  final String status;
  final String statusLabel;

  /// The backend's evidence (why it is built) or drop reason (why it is not).
  /// Never both, never invented — an item with neither shows neither.
  final String note;
  final Tone tone;
  bool get open => status == 'open';

  const SpecItemView({
    required this.n,
    required this.text,
    required this.status,
    required this.statusLabel,
    required this.note,
    required this.tone,
  });

  /// Items in PAYLOAD ORDER. The screen never sorts, never re-numbers and
  /// never decides that an item is done.
  static List<SpecItemView> listOf(Map<String, dynamic> payload) =>
      ((payload['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .map((it) {
            final drop = (it['drop_reason'] ?? '').toString();
            return SpecItemView(
              n: asInt(it['n']),
              text: (it['text'] ?? '').toString(),
              status: (it['status'] ?? '').toString(),
              statusLabel: (it['status_label'] ?? '').toString(),
              note: drop.isNotEmpty ? drop : (it['evidence'] ?? '').toString(),
              tone: toneByName((it['tone'] ?? 'neutral').toString()),
            );
          })
          .toList();

  /// How many items are still open, as the BACKEND counts them — the same
  /// number the finish gate refuses a completion on.
  static int openCount(Map<String, dynamic> payload) => asInt(payload['open']);
}

/// CHANGE #641 — the DB circuit breaker, drawn from `dev_ctl_get().breaker`.
///
/// When ten database timeouts land inside five minutes the BACKEND switches
/// Workflow off by itself and composes this badge (`_dev_breaker_badge()`):
/// the label, the sentence explaining what happened, the IST timestamp inside
/// it and the tone name are all server-side. Nothing here decides when the
/// badge appears, what it says, or what colour it wears — `tripped` is the
/// only question this widget asks, and it asks it of the payload.
class BreakerBanner extends StatelessWidget {
  final Map<String, dynamic> breaker;
  const BreakerBanner({super.key, required this.breaker});

  static bool tripped(Map<String, dynamic>? b) =>
      (b?['tripped'] ?? false) == true &&
      ((b?['label'] ?? '').toString().isNotEmpty);

  @override
  Widget build(BuildContext context) {
    if (!tripped(breaker)) return const SizedBox.shrink();
    final tone = toneByName((breaker['tone'] ?? 'error').toString());
    final label = (breaker['label'] ?? '').toString();
    final detail = (breaker['detail'] ?? '').toString();
    return Container(
      margin: EdgeInsets.only(top: Ds.space.x8),
      width: double.infinity,
      padding:
          EdgeInsets.symmetric(horizontal: Ds.space.x12, vertical: Ds.space.x12),
      decoration: BoxDecoration(color: tone.bg, borderRadius: Ds.r.rButton),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.pause_circle_filled, size: Ds.t.subtitleSize, color: tone.fg),
        SizedBox(width: Ds.space.x8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: Ds.t.bodyStrong.copyWith(color: tone.fg)),
            if (detail.isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(detail, style: Ds.t.caption.copyWith(color: tone.fg)),
            ],
          ]),
        ),
      ]),
    );
  }
}
