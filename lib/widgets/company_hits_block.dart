import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../models/storefront_p3.dart';

/// CMD #2118 — the Companies block.
///
/// A buyer who types "sun pharma" is naming a MAKER, not a molecule, and the
/// medicine list can never answer that in two taps. `storefront_search_page`
/// now carries the matched companies with the results, and this block prints
/// them ABOVE the grid: name, the backend's own count sentence, and a tap that
/// opens `/company/<key>`.
///
/// It decides nothing. The heading, the row order and every count string are
/// the payload's; matching happens in Postgres (`storefront_company_search`),
/// never here.
class CompanyHitsBlock extends StatelessWidget {
  final CompanyHits hits;

  /// The grid owns routing, so the block stays free of route literals.
  final void Function(CompanyHit hit) onOpen;

  const CompanyHitsBlock({
    super.key,
    required this.hits,
    required this.onOpen,
  });

  /// One row's height. Comfortably past the 44pt touch minimum at 360px, and
  /// fixed so a list of three cannot be three different heights.
  static const double rowH = 60;

  @override
  Widget build(BuildContext context) {
    if (!hits.has) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hits.title.isNotEmpty) ...[
          Text(hits.title, style: Ds.t.caption),
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
                if (i > 0) Divider(height: Ds.space.hairline, color: Ds.c.divider),
                _CompanyRow(hit: hits.rows[i], onTap: () => onOpen(hits.rows[i])),
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
  final VoidCallback onTap;

  const _CompanyRow({required this.hit, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
        identifier: 'company_hit_${hit.key}',
        button: true,
        container: true,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: CompanyHitsBlock.rowH,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
              child: Row(
                children: [
                  // There is no company artwork in the catalogue, so the
                  // entity's own initial is the honest mark — the same
                  // fallback the company page's logo box uses.
                  Container(
                    width: Ds.space.x32,
                    height: Ds.space.x32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Ds.c.bg,
                      borderRadius: Ds.r.rChip,
                      border: Border.all(color: Ds.c.divider, width: Ds.space.hairline),
                    ),
                    child: Text(
                      hit.label.isEmpty ? '' : hit.label.substring(0, 1),
                      style: Ds.t.subtitle,
                    ),
                  ),
                  SizedBox(width: Ds.space.x12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          hit.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Ds.t.body,
                        ),
                        if (hit.countLabel.isNotEmpty)
                          Text(hit.countLabel, style: Ds.t.caption),
                      ],
                    ),
                  ),
                  SizedBox(width: Ds.space.x8),
                  Icon(Icons.chevron_right, color: Ds.c.textSecondary),
                ],
              ),
            ),
          ),
        ),
      );
}
