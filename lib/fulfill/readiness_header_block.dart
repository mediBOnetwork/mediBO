// CHANGE #1890 — the SEND-ALL READINESS card's header, as a widget of its own.
//
// Om, 08 Sep 01:31: the label column had collapsed to a single character and
// "SEND-ALL READINESS" was wrapping one letter per line. The cause was one
// line of layout: #754 dropped the AutoFlow / Bundle chips into the same Row
// as the title, the title was the Row's only `Expanded`, and once the chips
// were wide enough that Expanded was handed a width of a few pixels. A Row
// starves its flexible child in silence — there is no overflow stripe to see.
//
// So the rule this file exists to hold: THE LABEL NEVER SHARES A ROW WITH A
// FLEXIBLE CHILD. It owns a full-width row of its own, and everything else —
// the status pill, the date — goes into a strip below it that scrolls
// sideways rather than competing for the same line.
//
// Both rows are fixed, token-sized heights and BOTH are drawn whether the card
// is open or closed, so the header block measures the same in either state and
// the card cannot jump under the finger that just tapped it.
//
// It lives here, outside the 13k-line supplier screen, because that is what
// makes it reachable from test/protected/fulfill_tabs_layout_test.dart with no
// network and no Supabase.

import 'package:flutter/material.dart';

import '../design_tokens.dart';

class ReadinessHeaderBlock extends StatelessWidget {
  const ReadinessHeaderBlock({
    super.key,
    required this.title,
    required this.onTap,
    this.statusLabel,
    this.statusBg,
    this.statusFg,
    this.dateLabel,
  });

  /// readiness['title'] — the backend's words, printed verbatim.
  final String title;

  /// Tapping anywhere on the block opens or closes the card.
  final VoidCallback onTap;

  /// readiness['status_label'] and the two colours the screen resolved from
  /// readiness['status_tone']. Null means the payload sent no status.
  final String? statusLabel;
  final Color? statusBg;
  final Color? statusFg;

  /// readiness['date_label']. Null means the payload sent no date.
  final String? dateLabel;

  /// The label's row. Fixed, so the block's height is a constant.
  static double get labelHeight => Ds.space.x24;

  /// The chip strip's row. Also fixed, and also drawn in BOTH states.
  static double get chipsHeight => Ds.space.x24 + Ds.space.x4;

  /// What the card's header measures — the same number open or closed.
  static double get blockHeight => labelHeight + chipsHeight;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: blockHeight,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // ── Row 1: the label, and nothing else. ─────────────────────────
          SizedBox(
            height: labelHeight,
            width: double.infinity,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(title,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: Ds.t.caption
                      .copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.6)),
            ),
          ),
          // ── Row 2: the chips, scrolling sideways. ───────────────────────
          SizedBox(
            height: chipsHeight,
            child: ListView(
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              children: [
                if (statusLabel != null) ...[
                  Center(
                    child: Container(
                      padding: EdgeInsets.symmetric(
                          horizontal: Ds.space.x12, vertical: Ds.space.x4),
                      decoration: BoxDecoration(
                        color: statusBg ?? Ds.c.bg,
                        borderRadius: Ds.r.rChip,
                      ),
                      child: Text(statusLabel!,
                          style: Ds.t.caption.copyWith(
                              fontWeight: FontWeight.w700,
                              color: statusFg ?? Ds.c.text)),
                    ),
                  ),
                  SizedBox(width: Ds.space.x8),
                ],
                if (dateLabel != null)
                  Center(
                    child: Text(dateLabel!,
                        style:
                            Ds.t.caption.copyWith(fontWeight: FontWeight.w600)),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}
