import 'package:flutter/material.dart';

import '../../../design_tokens.dart';

/// CHANGE #1470 — the build branch, on the card that already asks for it.
///
/// THE APP RENDERS. IT NEVER DECIDES. Every word here — the title, the state
/// sentence, the "{ref} · {builds} builds" sub-line, each attempt row and the
/// empty state — is `dev_ctl_get().build_branch`, which is
/// `build_branch_card()` printed verbatim. The widget computes no age, no
/// percentage, no plural and no reason; it does not know what a Supabase branch
/// is. That is the whole point: #1149 shipped a gate that could refuse and say
/// nothing, because there was no surface for a reason to appear on. Now there
/// is one, and it prints whatever the backend put in `display` — including
/// "Branch blocked: <reason>".
class BuildBranchCard extends StatelessWidget {
  final Map<String, dynamic> branch;
  const BuildBranchCard({super.key, required this.branch});

  /// One lookup, and an unknown tone stays neutral — the backend may add a
  /// tone this build has never heard of and the row must still draw.
  static (Color, Color) _tone(String tone) {
    switch (tone) {
      case 'completed':
        return (Ds.c.successSoft, Ds.c.success);
      case 'failed':
        return (Ds.c.dangerSoft, Ds.c.danger);
      case 'building':
        return (Ds.c.infoSoft, Ds.c.info);
      case 'warning':
        return (Ds.c.warningSoft, Ds.c.warning);
      default:
        return (Ds.c.bg, Ds.c.textSecondary);
    }
  }

  @override
  Widget build(BuildContext context) {
    // has:false is the backend saying "draw nothing" — a disabled capability
    // must not leave a dead card behind.
    if (branch['has'] != true) return const SizedBox.shrink();

    final title = (branch['title'] ?? '').toString();
    final display = (branch['display'] ?? '').toString();
    final sub = (branch['sub'] ?? '').toString();
    final attempts = ((branch['attempts'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final (chipBg, chipFg) = _tone((branch['tone'] ?? '').toString());

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.alt_route,
            size: Ds.space.x16 + 2, color: Ds.c.textSecondary),
        SizedBox(width: Ds.space.x8),
        if (title.isNotEmpty)
          Text(title,
              style: Ds.t.caption
                  .copyWith(fontWeight: FontWeight.w700, color: Ds.c.text)),
        SizedBox(width: Ds.space.x8),
        if (display.isNotEmpty)
          Flexible(
            child: Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x8, vertical: Ds.space.x4),
              decoration:
                  BoxDecoration(color: chipBg, borderRadius: Ds.r.rChip),
              child: Text(display,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Ds.t.caption
                      .copyWith(fontWeight: FontWeight.w600, color: chipFg)),
            ),
          ),
      ]),
      // Absent sub-line: omitted, never dashed.
      if (sub.isNotEmpty) ...[
        SizedBox(height: Ds.space.x4),
        Padding(
          padding: EdgeInsets.only(left: Ds.space.x24),
          child: Text(sub, style: Ds.t.caption),
        ),
      ],
      SizedBox(height: Ds.space.x8),
      Padding(
        padding: EdgeInsets.only(left: Ds.space.x24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text((branch['attempts_title'] ?? '').toString(),
              style: Ds.t.caption.copyWith(fontWeight: FontWeight.w600)),
          SizedBox(height: Ds.space.x4),
          if (attempts.isEmpty)
            Text((branch['attempts_none'] ?? '').toString(),
                style: Ds.t.caption)
          else
            // Payload order. The backend already sorted them newest first.
            for (final a in attempts) _AttemptRow(attempt: a),
        ]),
      ),
    ]);
  }
}

class _AttemptRow extends StatelessWidget {
  final Map<String, dynamic> attempt;
  const _AttemptRow({required this.attempt});

  @override
  Widget build(BuildContext context) {
    final (_, fg) = BuildBranchCard._tone((attempt['tone'] ?? '').toString());
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: EdgeInsets.only(top: Ds.space.x4),
          child: Container(
            width: Ds.space.x4 + 2,
            height: Ds.space.x4 + 2,
            decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
          ),
        ),
        SizedBox(width: Ds.space.x8),
        Text((attempt['at_display'] ?? '').toString(), style: Ds.t.caption),
        SizedBox(width: Ds.space.x8),
        Expanded(
          child: Text((attempt['label'] ?? '').toString(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Ds.t.caption.copyWith(color: Ds.c.text)),
        ),
      ]),
    );
  }
}
