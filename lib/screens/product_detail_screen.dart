import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/medicine_repository.dart';
import '../models/product_detail.dart';
import '../widgets/animations.dart';
import '../widgets/compact_product_card.dart';
import '../widgets/notify_control.dart';
import '../widgets/product_image.dart';

/// CHANGE #636 — the full-page product detail screen (PDP).
///
/// ONE RPC: `product_detail(p_product_id)` returns the whole page render-ready
/// — copy, labels, price strings, the availability verdict and the similar
/// rail. This screen calls nothing else and computes nothing: every visible
/// string below is printed straight out of that payload, including the section
/// headings and the not-found copy.
///
/// The only `if`s here are the backend's own booleans (`has_mrp`, `has_gst`,
/// `buyable`, `rx_required`, `has`), which is the payload telling the page what
/// to show — not the page deciding.
class ProductDetailScreen extends StatefulWidget {
  final String productId;

  /// Test seam. Production leaves this null and the screen calls
  /// `product_detail` through [MedicineRepository]; a test supplies the parsed
  /// payload directly so the page can be rendered with no network and no
  /// Supabase. Same constructor-injected-closure shape the rest of the
  /// protected suite uses.
  final Future<ProductDetail> Function(String productId)? loader;

  /// CHANGE #638 — test seams for the stock-notify wiring. Production reads
  /// `stock_notify_status` once on load and calls `stock_notify_request` on
  /// tap; there is no polling.
  final Future<bool> Function(String productId)? notifyStatusLoader;
  final NotifyRequest? notifyRequest;

  const ProductDetailScreen({
    super.key,
    required this.productId,
    this.loader,
    this.notifyStatusLoader,
    this.notifyRequest,
  });

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  ProductDetail? _data;
  bool _loading = true;
  bool _subscribed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ProductDetailScreen old) {
    super.didUpdateWidget(old);
    if (old.productId != widget.productId) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    ProductDetail res;
    try {
      final load = widget.loader ??
          (id) => MedicineRepository().fetchProductDetail(id);
      res = await load(widget.productId);
    } catch (_) {
      // A thrown call is indistinguishable from a missing product as far as
      // this page is concerned: show the backend's not-found page, never a
      // crash and never a Dart-authored error string.
      res = ProductDetail.notFound(const {});
    }
    if (!mounted) return;
    setState(() {
      _data = res;
      _loading = false;
    });

    // Only ask about a subscription for a product that cannot be bought —
    // that is the only state where the control exists. Read ONCE.
    final av = res.availability;
    final oos = res.ok && (av != null ? !av.canAdd : !res.buyable);
    if (!oos) return;

    final status = widget.notifyStatusLoader ??
        (id) => MedicineRepository().stockNotifyStatus(id);
    final subscribed = await status(widget.productId);
    if (!mounted) return;
    setState(() => _subscribed = subscribed);
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0.5,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF111827)),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: _loading
          ? const _PdpSkeleton()
          : (d == null || !d.ok)
              ? _NotFound(data: d)
              : _Body(data: d),
      bottomNavigationBar: (!_loading && d != null && d.ok)
          ? _StickyBar(
              data: d,
              subscribed: _subscribed,
              notifyRequest: widget.notifyRequest,
            )
          : null,
    );
  }
}

// ── Content ──────────────────────────────────────────────────────────────────

class _Body extends StatelessWidget {
  final ProductDetail data;
  const _Body({required this.data});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _Carousel(images: data.images, heroId: data.id),
        const SizedBox(height: 14),
        if (data.formChip.isNotEmpty) ...[
          _Chip(
            text: data.formChip,
            bg: const Color(0xFFF1F5F9),
            fg: const Color(0xFF64748B),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          data.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 19,
            height: 1.28,
            fontWeight: FontWeight.w800,
            color: Color(0xFF111827),
          ),
        ),
        if (data.company.isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(
            data.company.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              letterSpacing: 0.7,
              fontWeight: FontWeight.w600,
              color: Color(0xFF9CA3AF),
            ),
          ),
        ],
        if (data.packLabel.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            data.packLabel,
            style: const TextStyle(fontSize: 13, color: Color(0xFF4B5563)),
          ),
        ],
        const SizedBox(height: 14),
        _PriceRow(data: data),
        if (data.hasHistory) ...[
          const SizedBox(height: 8),
          _Chip(
            text: data.historyLabel,
            bg: const Color(0xFFEFF6FF),
            fg: const Color(0xFF1D4ED8),
          ),
        ],
        if (data.rxRequired) ...[
          const SizedBox(height: 12),
          _RxBanner(text: data.label('pdp_rx_banner')),
        ],
        const SizedBox(height: 12),
        _StockRow(data: data),
        if (data.overview.isNotEmpty) ...[
          const SizedBox(height: 24),
          _SectionTitle(text: data.label('pdp_overview_title')),
          const SizedBox(height: 10),
          _OverviewTable(rows: data.overview),
        ],
        for (final s in data.sections) ...[
          const SizedBox(height: 24),
          _SectionTitle(text: s.title),
          const SizedBox(height: 8),
          _CollapsibleBody(
            text: s.body,
            moreLabel: data.label('pdp_read_more'),
            lessLabel: data.label('pdp_read_less'),
          ),
        ],
        // The rail renders only when the backend actually sent tiles.
        if (data.similar.isNotEmpty) ...[
          const SizedBox(height: 28),
          _SectionTitle(text: data.label('pdp_similar_title')),
          const SizedBox(height: 12),
          _SimilarRail(items: data.similar),
        ],
      ],
    );
  }
}

class _Carousel extends StatefulWidget {
  final List<String> images;
  final String heroId;
  const _Carousel({required this.images, required this.heroId});

  @override
  State<_Carousel> createState() => _CarouselState();
}

class _CarouselState extends State<_Carousel> {
  final _ctrl = PageController();
  int _page = 0;

  static const double _h = 260;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final imgs = widget.images;

    // The box is the same height whether there are 0, 1 or 5 images, so the
    // rest of the page never moves.
    if (imgs.isEmpty) {
      return SizedBox(
        height: _h,
        child: Center(
          child: ProductImage(
            url: '',
            width: _h,
            height: _h,
            radius: BorderRadius.circular(14),
          ),
        ),
      );
    }

    return Column(
      children: [
        SizedBox(
          height: _h,
          child: PageView.builder(
            controller: _ctrl,
            itemCount: imgs.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (_, i) {
              final img = ProductImage(
                url: imgs[i],
                width: _h,
                height: _h,
                radius: BorderRadius.circular(14),
              );
              // Only the first image participates in the Hero — it is the one
              // the card flew from.
              return Center(
                child: i == 0
                    ? Hero(
                        tag: CompactProductCard.heroTag(widget.heroId),
                        child: img,
                      )
                    : img,
              );
            },
          ),
        ),
        if (imgs.length > 1) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 6,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < imgs.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _page ? 16 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _page
                          ? const Color(0xFF1B7A43)
                          : const Color(0xFFD9DDE3),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// CHANGE #638 — ONE price source.
///
/// This row used to print `price.mrp_label` big while every card in the app
/// printed `pricing.price_display`. Same product, two renderings of one
/// number, and nothing kept them honest — the moment a discount existed they
/// would have disagreed. The page now reads the card's block.
class _PriceRow extends StatelessWidget {
  final ProductDetail data;
  const _PriceRow({required this.data});

  @override
  Widget build(BuildContext context) {
    final pr = data.pricing;
    // has_price is explicit absence: no MRP at all, so show no price rather
    // than a fabricated ₹0.00.
    if (pr == null || !pr.hasPrice) return const SizedBox.shrink();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          pr.priceDisplay,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: Color(0xFF111827),
          ),
        ),
        // The struck MRP appears only when the backend says there IS a
        // discount — otherwise it would strike through the same number.
        if (pr.hasDiscount) ...[
          const SizedBox(width: 8),
          Text(
            pr.mrpDisplay,
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF9CA3AF),
              decoration: TextDecoration.lineThrough,
              decorationColor: Color(0xFF9CA3AF),
            ),
          ),
        ],
        if (data.hasGst) ...[
          const SizedBox(width: 8),
          _Chip(
            text: data.gstLabel,
            bg: const Color(0xFFF1F5F9),
            fg: const Color(0xFF475569),
          ),
        ],
      ],
    );
  }
}

class _StockRow extends StatelessWidget {
  final ProductDetail data;
  const _StockRow({required this.data});

  @override
  Widget build(BuildContext context) {
    if (data.buyable) {
      if (!data.hasSupplierLabel) return const SizedBox.shrink();
      return _Chip(
        text: data.supplierLabel,
        bg: const Color(0xFFECFDF3),
        fg: const Color(0xFF15803D),
      );
    }
    return Text(
      data.label('stock_out_label'),
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Color(0xFF9CA3AF),
      ),
    );
  }
}

class _OverviewTable extends StatelessWidget {
  final List<PdOverviewRow> rows;
  const _OverviewTable({required this.rows});

  @override
  Widget build(BuildContext context) {
    return Table(
      columnWidths: const {
        0: FlexColumnWidth(1.0),
        1: FlexColumnWidth(1.6),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      children: [
        for (final r in rows)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 10, right: 12),
                child: Text(
                  r.label,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: Color(0xFF9CA3AF),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  r.value,
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: Color(0xFF1F2937),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// A long section body, clamped to 6 lines with the backend's own
/// "Read more" / "Read less" labels. The toggle only appears when the text
/// genuinely overflows — measured, not guessed from a character count.
class _CollapsibleBody extends StatefulWidget {
  final String text;
  final String moreLabel;
  final String lessLabel;

  const _CollapsibleBody({
    required this.text,
    required this.moreLabel,
    required this.lessLabel,
  });

  @override
  State<_CollapsibleBody> createState() => _CollapsibleBodyState();
}

class _CollapsibleBodyState extends State<_CollapsibleBody> {
  static const int _maxLines = 6;
  static const TextStyle _style = TextStyle(
    fontSize: 13,
    height: 1.55,
    color: Color(0xFF374151),
  );

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final tp = TextPainter(
          text: TextSpan(text: widget.text, style: _style),
          maxLines: _maxLines,
          textDirection: Directionality.of(context),
        )..layout(maxWidth: c.maxWidth);
        final overflows = tp.didExceedMaxLines;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              alignment: Alignment.topCenter,
              child: Text(
                widget.text,
                style: _style,
                maxLines: _expanded ? null : _maxLines,
                overflow:
                    _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
              ),
            ),
            if (overflows && widget.moreLabel.isNotEmpty) ...[
              const SizedBox(height: 4),
              InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    _expanded ? widget.lessLabel : widget.moreLabel,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1B7A43),
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _SimilarRail extends StatelessWidget {
  final List<PdSimilar> items;
  const _SimilarRail({required this.items});

  static const double _tileW = 132;
  static const double _railH = 214;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _railH,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        // Fixed extent — the rail never measures its children, so scrolling
        // it costs no layout. The tile carries its own trailing gap.
        itemExtent: _tileW,
        itemBuilder: (_, i) => _SimilarTile(item: items[i], width: _tileW),
      ),
    );
  }
}

class _SimilarTile extends StatelessWidget {
  final PdSimilar item;
  final double width;
  const _SimilarTile({required this.item, required this.width});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        // Each tile pushes its OWN product page — a fresh route, so back
        // returns to this product rather than skipping the chain.
        onTap: () => Navigator.of(context)
            .pushNamed('/product/${item.id}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: width - 10,
              height: 108,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFEDEFF2)),
              ),
              child: Center(
                child: ProductImage(
                  url: item.image,
                  width: 92,
                  height: 92,
                  radius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 15,
              child: item.formChip.isEmpty
                  ? const SizedBox.shrink()
                  : Text(
                      item.formChip,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF94A3B8),
                      ),
                    ),
            ),
            SizedBox(
              height: 32,
              child: Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  height: 1.32,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1F2937),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              item.mrpLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: Color(0xFF111827),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Sticky bottom bar ────────────────────────────────────────────────────────

class _StickyBar extends StatelessWidget {
  final ProductDetail data;
  final bool subscribed;
  final NotifyRequest? notifyRequest;

  const _StickyBar({
    required this.data,
    required this.subscribed,
    required this.notifyRequest,
  });

  @override
  Widget build(BuildContext context) {
    final av = data.availability;

    // No verdict and not buyable — nothing to offer, so no bar at all.
    if (av == null && !data.buyable) return const SizedBox.shrink();

    final cart = AppState.of(context);
    final qty = cart.quantityOf(data.id);
    final canAdd = av?.canAdd ?? data.buyable;
    final pr = data.pricing;

    return SafeArea(
      top: false,
      child: Container(
        height: 68,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFEDEFF2))),
        ),
        child: Row(
          children: [
            // Same price source as the row above and as every card.
            if (pr != null && pr.hasPrice) ...[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      pr.priceDisplay,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111827),
                      ),
                    ),
                    Text(
                      data.mrpNote,
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: Color(0xFF9CA3AF),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
            ],
            // CHANGE #638 — an unbuyable product offers Notify instead of a
            // dead disabled button.
            if (!canAdd)
              NotifyControl(
                productId: data.id,
                initiallySubscribed: subscribed,
                compact: false,
                notifyLabel: data.label('card_notify_label'),
                subscribedLabel: data.label('notify_subscribed_label'),
                request: notifyRequest,
              )
            else
            SizedBox(
              width: 170,
              height: 46,
              child: qty > 0
                  ? _BarStepper(
                      qty: qty,
                      onMinus: () => cart.decrementId(data.id),
                      onPlus: () => cart.incrementId(data.id),
                    )
                  : FilledButton(
                      onPressed: canAdd
                          ? () {
                              if (cart.isPending(data.id)) return;
                              cart.addId(data.id);
                            }
                          : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF1B7A43),
                        disabledBackgroundColor: const Color(0xFFF3F4F6),
                        disabledForegroundColor: const Color(0xFF9CA3AF),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      // Verbatim backend label; falls back to the stock label
                      // the payload also carries, never to a word typed here.
                      child: Text(
                        av?.ctaLabel ?? data.label('stock_out_label'),
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BarStepper extends StatelessWidget {
  final int qty;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  const _BarStepper({
    required this.qty,
    required this.onMinus,
    required this.onPlus,
  });

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF1B7A43),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _BarStepIcon(icon: Icons.remove, onTap: onMinus),
            Text(
              '$qty',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            _BarStepIcon(icon: Icons.add, onTap: onPlus),
          ],
        ),
      );
}

class _BarStepIcon extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _BarStepIcon({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 46,
          child: Icon(icon, size: 20, color: Colors.white),
        ),
      );
}

// ── States ───────────────────────────────────────────────────────────────────

class _NotFound extends StatelessWidget {
  final ProductDetail? data;
  const _NotFound({required this.data});

  @override
  Widget build(BuildContext context) {
    final title = data?.label('pdp_not_found_title') ?? '';
    final body = data?.label('pdp_not_found_body') ?? '';
    final cta = data?.label('pdp_not_found_cta') ?? '';

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off,
                size: 44, color: Color(0xFFC7CBD1)),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111827),
              ),
            ),
            if (body.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                body,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF6B7280),
                ),
              ),
            ],
            if (cta.isNotEmpty) ...[
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () => Navigator.of(context).maybePop(),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1B7A43),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Text(cta),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PdpSkeleton extends StatelessWidget {
  const _PdpSkeleton();

  @override
  Widget build(BuildContext context) => Shimmer(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            // Same 260px carousel box the loaded page reserves.
            const SkeletonBox(
                width: double.infinity, height: 260, radius: 14),
            const SizedBox(height: 16),
            const SkeletonBox(width: 54, height: 17),
            const SizedBox(height: 10),
            const SkeletonBox(width: double.infinity, height: 22),
            const SizedBox(height: 6),
            const SkeletonBox(width: 180, height: 14),
            const SizedBox(height: 18),
            const SkeletonBox(width: 140, height: 26),
            const SizedBox(height: 24),
            const SkeletonBox(width: 110, height: 18),
            const SizedBox(height: 12),
            for (var i = 0; i < 5; i++) ...[
              const SkeletonBox(width: double.infinity, height: 14),
              const SizedBox(height: 10),
            ],
          ],
        ),
      );
}

// ── Shared bits ──────────────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle({required this.text});

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          fontSize: 15.5,
          fontWeight: FontWeight.w800,
          color: Color(0xFF111827),
        ),
      );
}

class _Chip extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;
  const _Chip({required this.text, required this.bg, required this.fg});

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ),
      );
}

class _RxBanner extends StatelessWidget {
  final String text;
  const _RxBanner({required this.text});

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFED7AA)),
      ),
      child: Row(
        children: [
          const Icon(Icons.receipt_long_outlined,
              size: 16, color: Color(0xFFB45309)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFFB45309),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
