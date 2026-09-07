import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// CMD #1849 — the receipt: everything a test session WOULD have sent.
///
/// A blocked session used to be silent, and silence proves nothing — you
/// cannot tell a working inquiry waterfall from one that never fired. This
/// prints the transcript instead: would have messaged supplier A, then supplier
/// B after no answer, would have charged this amount, would have paged the
/// admin at this time.
///
/// It is a PRINTER. Every word on it — the title, the channel names, each
/// sentence, each amount, each count and each verdict — is a string
/// `test_session_receipt()` sent. Nothing is derived here: not the rupee value,
/// not the plural, not the order of the lines, not which channel a line belongs
/// to. Given a payload whose `line` disagrees with its own `channel` and
/// `amount`, this widget prints the payload.
class OutboundReceiptView extends StatelessWidget {
  const OutboundReceiptView({super.key, required this.payload});

  final Map<String, dynamic> payload;

  String _s(String key) {
    final v = payload[key];
    return v is String ? v : '';
  }

  List<Map<String, dynamic>> get _groups {
    final g = payload['groups'];
    if (g is! List) return const [];
    return g.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  /// One lookup. A tone this build has never heard of stays neutral rather
  /// than guessing a colour from the words next to it.
  static Color _toneColor(String tone) {
    switch (tone) {
      case 'info':
        return Ds.c.info;
      case 'warning':
        return Ds.c.warning;
      case 'danger':
        return Ds.c.danger;
      default:
        return Ds.c.textSecondary;
    }
  }

  static Color _toneSoft(String tone) {
    switch (tone) {
      case 'info':
        return Ds.c.infoSoft;
      case 'warning':
        return Ds.c.warningSoft;
      case 'danger':
        return Ds.c.dangerSoft;
      default:
        return Ds.c.bg;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (payload['has'] != true) return const SizedBox.shrink();

    final groups = _groups;
    final title = _s('title');
    final subtitle = _s('subtitle');
    final count = _s('count_label');

    return Column(
      key: const ValueKey('outbound_receipt'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title.isNotEmpty) Text(title, style: Ds.t.title),
        if (subtitle.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(subtitle, style: Ds.t.caption),
        ],
        if (count.isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          Container(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x12, vertical: Ds.space.x4),
            decoration: BoxDecoration(color: Ds.c.infoSoft, borderRadius: Ds.r.rChip),
            child: Text(count, style: Ds.t.caption.copyWith(color: Ds.c.info)),
          ),
        ],
        if (groups.isEmpty) ...[
          SizedBox(height: Ds.space.x24),
          Text(_s('empty_label'),
              key: const ValueKey('outbound_receipt_empty'), style: Ds.t.bodySecondary),
        ],
        for (final g in groups) ...[
          SizedBox(height: Ds.space.x24),
          _GroupHeader(group: g),
          for (final l in _linesOf(g)) ...[
            SizedBox(height: Ds.space.x8),
            _ReceiptLine(line: l),
          ],
        ],
      ],
    );
  }

  static List<Map<String, dynamic>> _linesOf(Map<String, dynamic> g) {
    final l = g['lines'];
    if (l is! List) return const [];
    return l.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.group});

  final Map<String, dynamic> group;

  @override
  Widget build(BuildContext context) {
    final label = (group['label'] ?? '').toString();
    final count = (group['count_label'] ?? '').toString();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: Text(label, style: Ds.t.subtitle)),
        if (count.isNotEmpty)
          Text(count, style: Ds.t.caption),
      ],
    );
  }
}

class _ReceiptLine extends StatelessWidget {
  const _ReceiptLine({required this.line});

  final Map<String, dynamic> line;

  String _s(String key) {
    final v = line[key];
    return v is String ? v : '';
  }

  @override
  Widget build(BuildContext context) {
    final tone = _s('tone');
    final at = _s('at_label');
    final template = _s('template');
    final verdict = _s('verdict_label');
    final meta = [at, template].where((s) => s.isNotEmpty).join('  ·  ');
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_s('line'), style: Ds.t.body),
          if (meta.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(meta, style: Ds.t.caption),
          ],
          if (verdict.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x8, vertical: Ds.space.x4),
              decoration: BoxDecoration(
                color: OutboundReceiptView._toneSoft(tone),
                borderRadius: Ds.r.rChip,
              ),
              child: Text(verdict,
                  style: Ds.t.caption
                      .copyWith(color: OutboundReceiptView._toneColor(tone))),
            ),
          ],
        ],
      ),
    );
  }
}
