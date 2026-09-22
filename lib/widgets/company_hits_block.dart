import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../models/storefront_p3.dart';

/// CMD #2118 · redlined by CMD #2165 — the Companies block.
///
/// A buyer who types "sun pharma" is naming a MAKER, not a molecule, and the
/// medicine list can never answer that in two taps. `storefront_search_page`
/// carries the matched companies with the results, and this block prints them
/// ABOVE the products: the heading, then up to three rows of name, the
/// backend's own count sentence, and a tap that opens `/company/<key>`.
///
/// It decides nothing. The heading, the row order, the tile's letter, every
/// count string and every size in the redline are the payload's; matching
/// happens in Postgres (`storefront_company_search`), the cap at three and the
/// "is there a block at all?" answer in `storefront_search_page`, never here.
class CompanyHitsBlock extends StatelessWidget {
  final CompanyHits hits;

  /// The grid owns routing, so the block stays free of route literals.
  final void Function(CompanyHit hit) onOpen;

  const CompanyHitsBlock({
    super.key,
    required this.hits,
    required this.onOpen,
  });

  /// The row height when the payload sends none. Comfortably past the 44pt
  /// touch minimum at 360px, and fixed so a list of three cannot be three
  /// different heights.
  static const double rowH = 60;

  @override
  Widget build(BuildContext context) {
    if (!hits.has) return const SizedBox.shrink();
    final st = hits.style;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hits.title.isNotEmpty) ...[
          Text(
            hits.title,
            style: Ds.t.caption.copyWith(
              fontSize: st.titleSize ?? Ds.t.captionSize,
              letterSpacing: st.titleTracking,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: Ds.space.x8),
        ],
        Container(
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            border: Border.all(color: Ds.c.divider, width: Ds.space.hairline),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < hits.rows.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: st.divider ?? Ds.space.hairline,
                    thickness: st.divider ?? Ds.space.hairline,
                    color: Ds.c.divider,
                  ),
                _CompanyRow(
                  hit: hits.rows[i],
                  style: st,
                  onTap: () => onOpen(hits.rows[i]),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _CompanyRow extends StatelessWidget {
  final CompanyHit hit;
  final CompanyBlockStyle style;
  final VoidCallback onTap;

  const _CompanyRow({
    required this.hit,
    required this.style,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tile = style.tile ?? Ds.space.x32;
    return Semantics(
      identifier: 'company_hit_${hit.key}',
      button: true,
      container: true,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: style.rowH ?? CompanyHitsBlock.rowH,
          child: Padding(
            padding: EdgeInsets.symmetric(
                horizontal: style.padH ?? Ds.space.x16),
            child: Row(
              children: [
                // There is no company artwork in the catalogue, so the
                // entity's own initial is the honest mark — and the letter
                // itself is the backend's, never `label[0]` taken here.
                Container(
                  width: tile,
                  height: tile,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Ds.hex(style.tileBg, Ds.c.brandSoft),
                    borderRadius: BorderRadius.circular(
                        style.tileRadius ?? Ds.r.button),
                  ),
                  child: Text(
                    hit.iconLetter,
                    maxLines: 1,
                    style: Ds.t.subtitle.copyWith(
                      color: Ds.hex(style.tileFg, Ds.c.brand),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                SizedBox(width: style.gap ?? Ds.space.x12),
                // The label and the count take whatever width is left, and
                // each shortens with an ellipsis. Nothing is shrunk to fit:
                // a FittedBox would make one row's text smaller than the next
                // purely because the company has a longer name.
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        hit.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Ds.t.body.copyWith(
                          fontSize: style.labelSize ?? Ds.t.bodySize,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (hit.countLabel.isNotEmpty)
                        Text(
                          hit.countLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Ds.t.caption.copyWith(
                            fontSize: style.countSize ?? Ds.t.captionSize,
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(width: Ds.space.x8),
                Icon(
                  Icons.chevron_right,
                  size: style.chevron,
                  color: Ds.c.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
