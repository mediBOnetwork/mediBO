// CMD #409 — the recently-viewed rail, for the surfaces the home feed does not
// cover.
//
// On HOME this rail is a `storefront_home_section` row and is drawn by the
// ordinary section renderer — there is no Dart for it at all. This widget
// exists for the one place that is not the home feed: the search-empty state,
// where a customer who found nothing should still see what they were just
// looking at. It renders `recently_viewed_rail()` verbatim and draws NOTHING
// when the backend says `has` is false (signed out, no history, or everything
// viewed has gone off-sale).
import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../models/product.dart';
import '../services/storefront_fast_order.dart';
import '../widgets/compact_product_card.dart';

class RecentlyViewedRail extends StatefulWidget {
  /// Test seam. Production calls `recently_viewed_rail()` through
  /// [StorefrontFastOrder]; a test supplies the parsed payload directly.
  final Future<RecentRail> Function()? loader;
  final int limit;

  const RecentlyViewedRail({super.key, this.loader, this.limit = 12});

  @override
  State<RecentlyViewedRail> createState() => _RecentlyViewedRailState();
}

class _RecentlyViewedRailState extends State<RecentlyViewedRail> {
  RecentRail _rail = RecentRail.none;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final load = widget.loader ??
        () => StorefrontFastOrder.recentRail(limit: widget.limit);
    final r = await load();
    if (!mounted) return;
    setState(() => _rail = r);
  }

  @override
  Widget build(BuildContext context) {
    // `has` is the BACKEND's answer, never a length check here: it already
    // applied availability after picking the ids.
    if (!_rail.has) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.symmetric(vertical: Ds.space.x24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_rail.subtitle.isNotEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
              child: Text(_rail.subtitle,
                  key: const Key('c409_recent_subtitle'), style: Ds.t.caption),
            ),
          if (_rail.title.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
              child: Text(_rail.title,
                  key: const Key('c409_recent_title'), style: Ds.t.title),
            ),
          ],
          SizedBox(height: Ds.space.x16),
          SizedBox(
            height: CompactProductCard.extent,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
              itemExtent: 162 + 12,
              itemCount: _rail.items.length,
              itemBuilder: (context, i) {
                final card = _rail.items[i];
                return Padding(
                  padding: EdgeInsets.only(right: Ds.space.x12),
                  child: CompactProductCard(
                    product: Product.fromHomeCard(card),
                    onTap: () => Navigator.of(context)
                        .pushNamed('/product/${card['id']}'),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
