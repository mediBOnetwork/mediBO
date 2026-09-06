import 'package:flutter/material.dart';

import '../../../design_tokens.dart';

/// The Claude login state on the Runner card (CHANGE #1816).
///
/// A PRINTER. Every word — "Claude login — logged in", "expires in 3 days",
/// "expired · run /login on the VM", the last-login stamp and the valid-until
/// date — is `claude_login_line()`'s, composed in SQL from the VM's real
/// credential facts. Nothing here counts days, formats a date, decides a state
/// or guesses when a login happened: a widget that re-derived any of that would
/// eventually disagree with the backend and print a confident lie.
///
/// Display only, by design. #1369 tried the same subject and grew doctor
/// checks, a claim gate and an auto re-login; this draws a line and stops.
class ClaudeLoginLine extends StatelessWidget {
  final Map<String, dynamic> payload;
  const ClaudeLoginLine({super.key, required this.payload});

  List<Map<String, dynamic>> get _lines => ((payload['lines'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();

  /// One lookup, the backend's own tone name. An unknown tone stays neutral —
  /// a new state must never arrive as an accidental red.
  Color _toneColor(String tone) {
    switch (tone) {
      case 'danger':
        return Ds.c.danger;
      case 'warning':
        return Ds.c.warning;
      case 'success':
        return Ds.c.success;
      default:
        return Ds.c.text;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Absence is the backend's word too: nothing read yet draws nothing at all.
    if ((payload['has'] ?? false) != true) return const SizedBox.shrink();

    final tone = _toneColor((payload['tone'] ?? '').toString());
    final title = (payload['title'] ?? '').toString();
    final lines = _lines;

    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x8, bottom: Ds.space.x4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.vpn_key_outlined,
              size: Ds.space.x16, color: Ds.c.textSecondary),
          SizedBox(width: Ds.space.x8),
          Expanded(
            child: Text(title,
                style: Ds.t.caption
                    .copyWith(fontWeight: FontWeight.w600, color: tone)),
          ),
        ]),
        for (final l in lines) ...[
          SizedBox(height: Ds.space.x4),
          Padding(
            padding: EdgeInsets.only(left: Ds.space.x24),
            child: Text((l['text'] ?? '').toString(),
                style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          ),
        ],
      ]),
    );
  }
}
