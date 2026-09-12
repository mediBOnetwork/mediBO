import 'package:flutter/material.dart';
import '../design_tokens.dart';

/// CHANGE #1017 (2) — THE one list row for every staff surface.
///
/// name · one status colour · one number · chevron. Details live behind the
/// tap, never in the row. Every string and every tone arrives in the payload:
///   { title, subtitle?, tone?, value?, value_label?, badge_count?, route_key? }
/// `tone` is one of the backend's state words — 'bad' | 'warn' | 'good' |
/// anything else is neutral. Colour is STATE and nothing else (spec 4): red
/// overdue, amber due, green done, grey otherwise.
class StaffRow extends StatelessWidget {
  const StaffRow({
    super.key,
    required this.row,
    this.onTap,
    this.leading,
  });

  final Map<String, dynamic> row;
  final VoidCallback? onTap;
  final Widget? leading;

  static String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString().trim();

  /// The tone → colour map is the ONLY interpretation this widget makes, and it
  /// is the design system's own state palette, not a colour chosen here.
  static Color toneColor(String tone) {
    switch (tone) {
      case 'bad':
      case 'error':
      case 'danger':
      case 'overdue':
        return Ds.c.danger;
      case 'warn':
      case 'warning':
      case 'due':
        return Ds.c.warning;
      case 'good':
      case 'ok':
      case 'success':
      case 'done':
        return Ds.c.success;
      default:
        return Ds.c.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _s(row, 'title').isNotEmpty ? _s(row, 'title') : _s(row, 'label');
    final sub = _s(row, 'subtitle');
    final tone = _s(row, 'tone');
    final value = _s(row, 'value_label').isNotEmpty ? _s(row, 'value_label') : _s(row, 'value');
    final count = (row['badge_count'] as num?)?.toInt() ?? 0;
    final color = toneColor(tone);

    return Semantics(
      button: onTap != null,
      label: title,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x16, vertical: Ds.space.x12),
          decoration: BoxDecoration(
            color: Ds.c.surface,
            border: Border(bottom: BorderSide(color: Ds.c.divider)),
          ),
          child: Row(children: [
            // one status colour: a dot, never a second hue on the row
            Container(
              width: Ds.space.x8,
              height: Ds.space.x8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            SizedBox(width: Ds.space.x12),
            if (leading != null) ...[leading!, SizedBox(width: Ds.space.x12)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: Ds.t.body, maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (sub.isNotEmpty)
                    Text(sub, style: Ds.t.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            SizedBox(width: Ds.space.x12),
            // one number, big; a badge only when work is waiting (spec 4)
            if (count > 0)
              Container(
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: Ds.space.x4),
                decoration: BoxDecoration(color: Ds.c.dangerSoft, borderRadius: Ds.r.rChip),
                child: Text('$count', style: Ds.t.caption.copyWith(color: Ds.c.danger, fontWeight: FontWeight.w600)),
              )
            else if (value.isNotEmpty)
              Text(value, style: Ds.t.bodyStrong.copyWith(color: tone.isEmpty ? Ds.c.text : color), textAlign: TextAlign.right),
            SizedBox(width: Ds.space.x8),
            Icon(Icons.chevron_right, size: Ds.space.x16 + Ds.space.x4, color: Ds.c.textSecondary),
          ]),
        ),
      ),
    );
  }
}

/// The empty state every staff list shares: the backend's title, hint and
/// (when it sent one) the next action. Never a blank card, never a spinner.
class StaffEmptyState extends StatelessWidget {
  const StaffEmptyState({super.key, required this.empty, this.onAction});
  final Map<String, dynamic> empty;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final title = (empty['title'] ?? '').toString();
    final hint = (empty['hint'] ?? '').toString();
    final action = (empty['action_label'] ?? '').toString();
    if (title.isEmpty && hint.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.all(Ds.space.x24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (title.isNotEmpty) Text(title, style: Ds.t.subtitle, textAlign: TextAlign.center),
        if (hint.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(hint, style: Ds.t.caption, textAlign: TextAlign.center),
        ],
        if (action.isNotEmpty && onAction != null) ...[
          SizedBox(height: Ds.space.x16),
          SizedBox(
            height: Ds.touch.minTarget,
            child: FilledButton(onPressed: onAction, child: Text(action)),
          ),
        ],
      ]),
    );
  }
}
