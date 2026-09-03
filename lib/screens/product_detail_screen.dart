import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/medicine_repository.dart';
import '../design_tokens.dart';
import '../models/product.dart';
import '../models/product_compare.dart';
import '../models/product_detail.dart';
import '../models/product_reviews.dart';
import '../models/storefront_p3.dart';
import '../services/storefront_fast_order.dart';
import '../theme.dart';
import '../utils/render_log.dart';
import '../utils/toast.dart';
import '../widgets/animations.dart';
import '../widgets/compact_product_card.dart';
import '../widgets/companion_rail.dart';
import '../widgets/compare_tray.dart';
import '../widgets/notify_control.dart';
import '../widgets/product_image.dart';
import '../widgets/purchase_overlay_card.dart';
import '../widgets/product_reviews_block.dart';

typedef WishlistToggle = Future<WishlistResult> Function(String productId);

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

  /// CHANGE #160 — test seam for the wishlist toggle. Production calls
  /// `wishlist_toggle` through [MedicineRepository].
  final WishlistToggle? wishlistToggle;

  /// CMD #410 — test seams for reviews/Q&A and compare. Production goes
  /// through [MedicineRepository]; a test supplies parsed payloads so the
  /// block can be rendered with no network and no Supabase, the same
  /// constructor-injected-closure shape the rest of the protected suite uses.
  final Future<ProductReviews> Function(String productId, int offset)? reviewsLoader;
  final Future<ReviewWriteResult> Function(String productId, int stars, String body)? reviewSubmit;
  final Future<ReviewWriteResult> Function(String productId, String body)? questionSubmit;
  final Future<ReviewWriteResult> Function(String questionId, String body)? answerSubmit;
  final Future<ReviewWriteResult> Function(String kind, String targetId)? flagRaise;
  final Future<ProductCompare> Function(List<String> ids)? compareLoader;

  const ProductDetailScreen({
    super.key,
    required this.productId,
    this.loader,
    this.notifyStatusLoader,
    this.notifyRequest,
    this.wishlistToggle,
    this.reviewsLoader,
    this.reviewSubmit,
    this.questionSubmit,
    this.answerSubmit,
    this.flagRaise,
    this.compareLoader,
  });

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  ProductDetail? _data;
  bool _loading = true;
  bool _subscribed = false;
  bool _wishlisted = false;

  /// CMD #410 — the reviews block is a SECOND call on purpose: it pages by the
  /// backend's own offset and it is re-read after every write, while the page
  /// payload above it is not. Folding it into product_detail_v2 would make
  /// every "show more" refetch the whole product.
  ProductReviews _reviews = ProductReviews.empty_;

  /// The compare tray. The app owns exactly this: which ids are ticked.
  late final CompareSelection _compare = CompareSelection(max: 3);

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
      _wishlisted = res.isWishlisted;
    });

    if (res.ok) unawaited(_loadReviews());
    // CMD #409 — one product open, recorded into the customer's recently-viewed
    // ring. Fire-and-forget by contract: a customer never waits on, and is
    // never shown an error from, their own view history. An anonymous viewer
    // keeps none — the backend refuses it, and that refusal is silent here.
    if (res.ok) unawaited(StorefrontFastOrder.recordView(widget.productId));

    // Only ask about a subscription for a product that cannot be bought —
    // that is the only state where the control exists. Read ONCE.
    // CHANGE #640 — through the page's ONE add decision, so the Notify probe
    // can never disagree with the button the bar is about to draw.
    final oos = res.ok && !res.canAdd;
    if (!oos) return;

    final status = widget.notifyStatusLoader ??
        (id) => MedicineRepository().stockNotifyStatus(id);
    final subscribed = await status(widget.productId);
    if (!mounted) return;
    setState(() => _subscribed = subscribed);
  }

  /// CMD #410 — (re)read the reviews block. Called on load and after every
  /// successful write, because a submitted review is PENDING and only the
  /// backend knows what the list looks like afterwards. Nothing is patched
  /// optimistically here.
  Future<void> _loadReviews({int offset = 0}) async {
    ProductReviews res;
    try {
      final load = widget.reviewsLoader ??
          (id, off) => MedicineRepository().fetchProductReviews(id, offset: off);
      res = await load(widget.productId, offset);
    } catch (_) {
      // The block is an ADDITION to the page, never a gate on it: a product
      // page that cannot reach the reviews RPC still shows the product. The
      // empty payload renders as ok:false, which draws nothing at all.
      res = ProductReviews.empty_;
    }
    if (!mounted) return;
    setState(() => _reviews = res);
    // CMD #410 — REACHABILITY PROOF for the PDP block. Canvas cannot be
    // clicked by a tool, so this records what the backend actually decided:
    // whether the composer is open to this account, whether the aggregate
    // cleared its floor, and how many rows were drawn.
    RenderLog.write('c410_reviews_block',
        'ok=${res.ok};can_write=${res.canWrite};rating=${res.summary.has};'
        'items=${res.items.length};qs=${res.questions.length}');
  }

  /// The tray refuses at the cap with the BACKEND's sentence — the payload
  /// already carries it, so the widget looks it up instead of writing one.
  void _toggleCompare(String id, String fullMessage) {
    final reason = _compare.toggle(id);
    if (reason == 'full' && fullMessage.isNotEmpty) {
      showToast(context, fullMessage);
      return;
    }
    setState(() {});
  }

  Future<void> _openCompare() async {
    ProductCompare res;
    try {
      final load = widget.compareLoader ??
          (ids) => MedicineRepository().fetchCompare(ids);
      res = await load(_compare.ids);
    } catch (_) {
      res = ProductCompare.failed;
    }
    if (!mounted) return;
    await CompareSheet.show(context, res);
  }

  Future<void> _toggleWishlist() async {
    final d = _data;
    if (d == null) return;
    final toggle = widget.wishlistToggle ??
        (id) => MedicineRepository().wishlistToggle(id);
    final res = await toggle(d.id);
    if (!mounted) return;
    if (res.loginRequired) {
      Navigator.of(context).pushNamed('/login');
      return;
    }
    if (res.ok) {
      setState(() => _wishlisted = res.isWishlisted);
      if (res.toast.isNotEmpty) showToast(context, res.toast);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final showWishlistBtn = !_loading && d != null && d.ok && d.showWishlist;

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
        actions: [
          if (showWishlistBtn)
            IconButton(
              tooltip: d.label(
                  _wishlisted ? 'pdp_wishlist_remove' : 'pdp_wishlist_add'),
              icon: Icon(
                _wishlisted ? Icons.favorite : Icons.favorite_border,
                color: _wishlisted ? Ds.c.danger : Ds.c.textSecondary,
              ),
              onPressed: _toggleWishlist,
            ),
        ],
      ),
      body: _loading
          ? const _PdpSkeleton()
          : (d == null || !d.ok)
              ? _NotFound(data: d)
              : _Body(
                  data: d,
                  reviews: _reviews,
                  compare: _compare,
                  onToggleCompare: _toggleCompare,
                  onOpenCompare: _openCompare,
                  onClearCompare: () => setState(_compare.clear),
                  onReviewsChanged: _loadReviews,
                  onReview: (stars, body) =>
                      (widget.reviewSubmit ??
                              (id, s2, b) => MedicineRepository()
                                  .reviewSubmit(id, s2, b))(d.id, stars, body),
                  onQuestion: (body) =>
                      (widget.questionSubmit ??
                              (id, b) => MedicineRepository()
                                  .questionSubmit(id, b))(d.id, body),
                  onAnswer: (qid, body) =>
                      (widget.answerSubmit ??
                              (id, b) => MedicineRepository()
                                  .answerSubmit(id, b))(qid, body),
                  onFlag: (kind, target) =>
                      (widget.flagRaise ??
                              (k, t) => MedicineRepository()
                                  .contentFlag(k, t))(kind, target),
                ),
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

  /// CMD #410 — the reviews block and the compare tray. Both are handed in
  /// already resolved; this widget still prints and decides nothing.
  final ProductReviews reviews;
  final CompareSelection compare;
  final void Function(String id, String fullMessage) onToggleCompare;
  final Future<void> Function() onOpenCompare;
  final VoidCallback onClearCompare;
  final Future<void> Function() onReviewsChanged;
  final Future<ReviewWriteResult> Function(int stars, String body) onReview;
  final Future<ReviewWriteResult> Function(String body) onQuestion;
  final Future<ReviewWriteResult> Function(String questionId, String body) onAnswer;
  final Future<ReviewWriteResult> Function(String kind, String targetId) onFlag;

  const _Body({
    required this.data,
    required this.reviews,
    required this.compare,
    required this.onToggleCompare,
    required this.onOpenCompare,
    required this.onClearCompare,
    required this.onReviewsChanged,
    required this.onReview,
    required this.onQuestion,
    required this.onAnswer,
    required this.onFlag,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _Gallery(gallery: data.gallery, heroId: data.id),
        SizedBox(height: Ds.space.x12),
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
        // CMD #410 — the aggregate rating. `has` is the backend's verdict on
        // whether there is enough evidence to show one at all; below its floor
        // there is no row here, not a 5.0 written by a single customer.
        if (data.rating.has) ...[
          SizedBox(height: Ds.space.x8),
          _RatingRow(summary: data.rating),
        ],
        const SizedBox(height: 14),
        _PriceRow(data: data),
        // CMD #791 — this pharmacy's own history with the pack, and the one
        // tap that re-orders its usual quantity. `has` is false for an
        // anonymous visitor because the RPC returned nothing, not because this
        // page checked a login flag (spec item 4).
        if (data.purchase.has) ...[
          SizedBox(height: Ds.space.x12),
          PurchaseOverlayCard(
            overlay: data.purchase,
            onAddUsual: () => AppState.of(context)
                .setQuantityId(data.id, data.purchase.usualQty),
          ),
        ] else if (data.hasHistory) ...[
          SizedBox(height: Ds.space.x8),
          _Chip(
            text: data.historyLabel,
            bg: const Color(0xFFEFF6FF),
            fg: const Color(0xFF1D4ED8),
          ),
        ],
        // CHANGE #461/#170 — the prescription class. header.rx_required came
        // back false on EVERY product until this change (including packs whose
        // "MEDICINE".rx_required reads 'Rx'), so this banner had never once
        // fired. The block below is rx_badge()'s: title, note and both tone
        // colours are the backend's, and an Rx product also prints whether
        // this pharmacy's drug licence is on file for it.
        if (data.hasRxBlock) ...[
          const SizedBox(height: 12),
          _C461RxBlock(data: data),
        ] else if (data.rxRequired) ...[
          const SizedBox(height: 12),
          _RxBanner(text: data.label('pdp_rx_banner')),
        ],
        const SizedBox(height: 12),
        _StockRow(data: data),
        // CMD #367 (row 177) — the supply trust strip. `has` is the backend's
        // verdict, so a product with no supply history shows nothing at all
        // rather than a flattering default. No expiry claim is rendered here
        // or anywhere else on this page: we do not know a batch's expiry
        // before we buy it.
        if (data.trust.has) ...[
          SizedBox(height: Ds.space.x16),
          _SectionTitle(text: data.trust.title),
          SizedBox(height: Ds.space.x8),
          _TrustStrip(trust: data.trust),
        ],
        if (data.overview.isNotEmpty) ...[
          const SizedBox(height: 24),
          _SectionTitle(text: data.label('pdp_overview_title')),
          const SizedBox(height: 10),
          _OverviewTable(rows: data.overview),
        ],
        // CMD #791 — composition & strength, form, pack, Rx/OTC, habit
        // forming, cold chain, storage. `product_facts()` sends only the rows
        // whose column actually holds something, so an absent value is an
        // absent ROW here — never a label with a dash beside it.
        if (data.facts.has) ...[
          SizedBox(height: Ds.space.x24),
          _SectionTitle(text: data.facts.title),
          SizedBox(height: Ds.space.x8),
          _FactsTable(rows: data.facts.rows),
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
        // CMD #366 row 175 — the delivery promise. `has` is the backend's
        // answer to "have we delivered here often enough to promise
        // anything". Below its sample floor there is no block at all: an
        // invented date on a pharmacy's buying screen is worse than none,
        // because it is a promise nobody ever measured.
        if (data.deliveryPromise.has) ...[
          SizedBox(height: Ds.space.x16),
          _PromiseRow(promise: data.deliveryPromise),
        ],
        // CMD #366 row 171 — the priced substitute block. Same mechanism as
        // the salt rail below, extended: normalised strength and form, the
        // real price, and a saving computed net-rate against net-rate.
        if (data.substitutes.has) ...[
          SizedBox(height: Ds.space.x24),
          _SectionTitle(text: data.substitutes.heading),
          SizedBox(height: Ds.space.x4),
          Text(
            data.substitutes.note,
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
          ),
          SizedBox(height: Ds.space.x12),
          _SubstituteRail(
            items: data.substitutes.items,
            compareLabel: data.compareAddLabel,
            selection: compare,
            onToggleCompare: (id) =>
                onToggleCompare(id, data.label('cmp_full')),
          ),
          // CMD #410 — the tray. It appears the moment something is ticked and
          // its CTA only fires at two or more, which is the backend's rule
          // (`cmp_min`) expressed as a disabled button rather than a toast the
          // app would have to word itself.
          if (compare.count > 0) ...[
            SizedBox(height: Ds.space.x12),
            CompareBar(
              count: compare.count,
              max: data.compareMax,
              ctaLabel: data.compareCtaLabel,
              clearLabel: data.label('cmp_clear'),
              onCompare: compare.canCompare ? () => onOpenCompare() : null,
              onClear: onClearCompare,
            ),
          ],
        ],
        // CMD #791 — frequently bought together, from the nightly co-purchase
        // job. `has` is the backend's verdict, so a pack with no real
        // co-purchase evidence shows no rail at all rather than a
        // recommendation the platform made up. Pairs are same-Rx-class only,
        // decided where the pair is FORMED, so nothing here has to filter.
        if (data.companions.has) ...[
          SizedBox(height: Ds.space.x24),
          _SectionTitle(text: data.companions.title),
          SizedBox(height: Ds.space.x4),
          Text(
            data.companions.note,
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
          ),
          SizedBox(height: Ds.space.x12),
          CompanionRail(items: data.companions.items),
        ],
        // The rail renders only when the backend actually sent tiles.
        if (data.similar.isNotEmpty) ...[
          const SizedBox(height: 28),
          _SectionTitle(text: data.label('pdp_similar_title')),
          const SizedBox(height: 12),
          _SimilarRail(items: data.similar),
        ],
        // CMD #410 — ratings, reviews and Q&A. The block renders nothing at
        // all until product_reviews() answers ok:true, so a slow second call
        // never leaves a half-drawn section on the page.
        ProductReviewsBlock(
          data: reviews,
          onChanged: onReviewsChanged,
          onReview: onReview,
          onQuestion: onQuestion,
          onAnswer: onAnswer,
          onFlag: onFlag,
        ),
      ],
    );
  }
}

/// CMD #410 — the stars plus the backend's own sentence. The app paints the
/// five icons; it does not build the words beside them.
class _RatingRow extends StatelessWidget {
  final RatingSummary summary;
  const _RatingRow({required this.summary});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          for (var i = 1; i <= 5; i++)
            Icon(
              summary.stars >= i
                  ? Icons.star_rounded
                  : (summary.stars >= i - 0.5
                      ? Icons.star_half_rounded
                      : Icons.star_border_rounded),
              size: Ds.space.x16,
              color: Ds.c.warning,
            ),
          SizedBox(width: Ds.space.x8),
          Flexible(
            child: Text(summary.countLabel,
                overflow: TextOverflow.ellipsis, style: Ds.t.caption),
          ),
        ],
      );
}

/// CMD #366 row 175 — one line, both strings from `delivery_promise()`.
class _PromiseRow extends StatelessWidget {
  final PdPromise promise;
  const _PromiseRow({required this.promise});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(
          color: Ds.c.infoSoft,
          borderRadius: Ds.r.rButton,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.local_shipping_outlined,
                size: Ds.space.x16, color: Ds.c.info),
            SizedBox(width: Ds.space.x8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(promise.label,
                      style: Ds.t.body.copyWith(
                          fontWeight: FontWeight.w600, color: Ds.c.text)),
                  SizedBox(height: Ds.space.x4),
                  Text(promise.note,
                      style:
                          Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
                ],
              ),
            ),
          ],
        ),
      );
}

/// CMD #366 row 171 — the substitute rail. Price, saving and margin are
/// printed only when the payload carried them; there is no "—" placeholder and
/// no locally computed comparison, because an item with no imported trade rate
/// genuinely has no price to compare.
class _SubstituteRail extends StatelessWidget {
  final List<PdSubstitute> items;

  /// CMD #410 — the compare tick's caption, straight from the payload. An
  /// empty label means the backend did not send one and the tick is not drawn.
  final String compareLabel;
  final CompareSelection selection;
  final void Function(String id) onToggleCompare;

  const _SubstituteRail({
    required this.items,
    required this.compareLabel,
    required this.selection,
    required this.onToggleCompare,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 270,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: items.length,
          separatorBuilder: (_, _) => SizedBox(width: Ds.space.x12),
          itemBuilder: (_, i) => _SubstituteTile(
            item: items[i],
            compareLabel: compareLabel,
            compareSelected: selection.contains(items[i].id),
            onToggleCompare: () => onToggleCompare(items[i].id),
          ),
        ),
      );
}

class _SubstituteTile extends StatelessWidget {
  final PdSubstitute item;
  final String compareLabel;
  final bool compareSelected;
  final VoidCallback onToggleCompare;
  const _SubstituteTile({
    required this.item,
    required this.compareLabel,
    required this.compareSelected,
    required this.onToggleCompare,
  });

  @override
  Widget build(BuildContext context) {
    final price = item.pricing?.priceDisplay ?? '';
    return InkWell(
      borderRadius: Ds.r.rCard,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ProductDetailScreen(productId: item.id),
        ),
      ),
      child: Container(
        width: 168,
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Center(
                child: ProductImage(
                  url: item.image,
                  width: 96,
                  height: 76,
                  radius: Ds.r.rButton,
                ),
              ),
            ),
            SizedBox(height: Ds.space.x8),
            Text(item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Ds.t.body.copyWith(
                    fontWeight: FontWeight.w600, color: Ds.c.text)),
            Text(item.company,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
            SizedBox(height: Ds.space.x4),
            Text(item.matchLabel,
                style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
            if (price.isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(price,
                  style: Ds.t.body.copyWith(
                      fontWeight: FontWeight.w700, color: Ds.c.text)),
            ],
            if (item.hasSaving) ...[
              SizedBox(height: Ds.space.x4),
              Text(item.savingLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ds.t.caption.copyWith(
                      fontWeight: FontWeight.w600, color: Ds.c.success)),
            ],
            if (item.hasMargin) ...[
              SizedBox(height: Ds.space.x4),
              Text(item.marginLabel,
                  style: Ds.t.caption.copyWith(color: Ds.c.info)),
            ],
            // CMD #410 — the compare entry point, on the same-salt row the
            // spec names. Ticking it only records an id; every number in the
            // resulting table is composed by product_compare().
            CompareCheckbox(
              label: compareLabel,
              selected: compareSelected,
              onTap: onToggleCompare,
            ),
          ],
        ),
      ),
    );
  }
}

/// CMD #791 — the pack-shot gallery: swipe, a backend-rendered counter, a
/// thumbnail strip, and tap-to-zoom.
///
/// The counter is NOT built here. `product_gallery()` ships a `counter_label`
/// per image ("2 / 5") and this widget prints the one belonging to the page it
/// is showing — the same rule the rest of the payload follows, applied to a
/// string that is very easy to assemble locally and therefore very easy to get
/// wrong in one place and not the other.
///
/// The box is a fixed height whether there are 0, 1 or 5 shots, so nothing
/// below it moves as the images load.
class _Gallery extends StatefulWidget {
  final PdGallery gallery;
  final String heroId;
  const _Gallery({required this.gallery, required this.heroId});

  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  final _ctrl = PageController();
  int _page = 0;

  static const double _h = 260;
  static const double _thumb = 52;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _open(int index) {
    final imgs = widget.gallery.images;
    if (imgs.isEmpty) return;
    Navigator.of(context).push(PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Ds.c.text,
      pageBuilder: (_, __, ___) => _ZoomViewer(
        gallery: widget.gallery,
        initialIndex: index,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final imgs = widget.gallery.images;

    if (imgs.isEmpty) {
      return SizedBox(
        height: _h,
        child: Center(
          child: ProductImage(
            url: '',
            width: _h,
            height: _h,
            radius: Ds.r.rCard,
          ),
        ),
      );
    }

    final page = _page.clamp(0, imgs.length - 1);

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
                url: imgs[i].url,
                width: _h,
                height: _h,
                radius: Ds.r.rCard,
              );
              // Only the first image participates in the Hero — it is the one
              // the card flew from.
              return Center(
                child: GestureDetector(
                  onTap: () => _open(i),
                  child: i == 0
                      ? Hero(
                          tag: CompactProductCard.heroTag(widget.heroId),
                          child: img,
                        )
                      : img,
                ),
              );
            },
          ),
        ),
        if (imgs.length > 1) ...[
          SizedBox(height: Ds.space.x8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // The backend's counter for the page on screen. Empty on a
              // cached pre-#791 payload, and then nothing is drawn.
              if (imgs[page].counterLabel.isNotEmpty)
                Text(imgs[page].counterLabel, style: Ds.t.caption),
              if (imgs[page].counterLabel.isNotEmpty &&
                  widget.gallery.zoomHint.isNotEmpty)
                Text(' · ', style: Ds.t.caption),
              if (widget.gallery.zoomHint.isNotEmpty)
                Text(widget.gallery.zoomHint, style: Ds.t.caption),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          SizedBox(
            height: _thumb,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              shrinkWrap: true,
              itemCount: imgs.length,
              separatorBuilder: (_, __) => SizedBox(width: Ds.space.x8),
              itemBuilder: (_, i) => GestureDetector(
                onTap: () {
                  setState(() => _page = i);
                  _ctrl.animateToPage(i,
                      duration: Ds.motion.standard, curve: Ds.motion.curve);
                },
                child: Container(
                  width: _thumb,
                  height: _thumb,
                  decoration: BoxDecoration(
                    borderRadius: Ds.r.rButton,
                    border: Border.all(
                      color: i == page ? Ds.c.brand : Ds.c.divider,
                      width: i == page ? 2 : 1,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: Ds.r.rButton,
                    child: ProductImage(
                      url: imgs[i].url,
                      width: _thumb,
                      height: _thumb,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// CMD #791 — the full-screen zoom. `InteractiveViewer` gives pinch and
/// double-tap-free pan on every platform the app ships to, and the dismiss
/// control's word is the backend's `close_label`.
class _ZoomViewer extends StatefulWidget {
  final PdGallery gallery;
  final int initialIndex;
  const _ZoomViewer({required this.gallery, required this.initialIndex});

  @override
  State<_ZoomViewer> createState() => _ZoomViewerState();
}

class _ZoomViewerState extends State<_ZoomViewer> {
  late final PageController _ctrl =
      PageController(initialPage: widget.initialIndex);
  late int _page = widget.initialIndex;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final imgs = widget.gallery.images;
    final page = _page.clamp(0, imgs.isEmpty ? 0 : imgs.length - 1);
    return Scaffold(
      backgroundColor: Ds.c.text,
      body: SafeArea(
        child: Stack(
          children: [
            PageView.builder(
              controller: _ctrl,
              itemCount: imgs.length,
              onPageChanged: (i) => setState(() => _page = i),
              itemBuilder: (_, i) => InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: Center(
                  child: ProductImage(
                    url: imgs[i].url,
                    width: MediaQuery.of(context).size.width,
                    height: MediaQuery.of(context).size.height,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: Ds.space.x24,
              child: Center(
                child: imgs.isEmpty || imgs[page].counterLabel.isEmpty
                    ? const SizedBox.shrink()
                    : Text(
                        imgs[page].counterLabel,
                        style: Ds.t.caption.copyWith(color: Ds.c.surface),
                      ),
              ),
            ),
            Positioned(
              top: Ds.space.x8,
              right: Ds.space.x8,
              child: TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(
                  widget.gallery.closeLabel,
                  style: Ds.t.body.copyWith(color: Ds.c.surface),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// CMD #791 — the fact table. Same two-column shape as the overview table it
/// sits under; both halves of every row arrive rendered.
class _FactsTable extends StatelessWidget {
  final List<PdFactRow> rows;
  const _FactsTable({required this.rows});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
      ),
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x16, vertical: Ds.space.x8),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: Ds.space.x16, color: Ds.c.divider),
            Padding(
              padding: EdgeInsets.symmetric(vertical: Ds.space.x4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 130,
                    child: Text(rows[i].label, style: Ds.t.caption),
                  ),
                  SizedBox(width: Ds.space.x12),
                  Expanded(
                    child: Text(rows[i].value, style: Ds.t.body),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
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

    // CHANGE #673, revised by #676 — the price block.
    //
    // #673 framed this as a PTR with a margin line. #676 withdrew that: the
    // page quotes MRP and nothing else. Nothing here needed an edit, because
    // the caption, the struck second price and the margin box are all gated on
    // backend strings — the backend simply stopped sending them.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            if (pr.priceCaption.isNotEmpty) ...[
              Text(pr.priceCaption,
                  style: AppType.t2.copyWith(
                      color: Brand.inkMuted,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6)),
              const SizedBox(width: 6),
            ],
            Text(
              pr.priceDisplay,
              style: AppType.h4.copyWith(color: Brand.price),
            ),
            // The struck MRP appears only when the backend says there IS a
            // discount — otherwise it would strike through the same number.
            if (pr.hasDiscount) ...[
              const SizedBox(width: 10),
              Text(
                '${data.label('pdp_mrp_caption')} ${pr.mrpDisplay}'.trim(),
                style: AppType.b3.copyWith(
                  color: Brand.inkFaint,
                  decoration: TextDecoration.lineThrough,
                  decorationColor: Brand.inkFaint,
                ),
              ),
            ],
            if (data.hasGst) ...[
              const SizedBox(width: 8),
              _Chip(
                text: data.gstLabel,
                bg: Brand.field,
                fg: Brand.inkSub,
              ),
            ],
          ],
        ),
        // The margin line: the whole reason a pharmacy is on this screen.
        // Rendered only when the backend computed one — never derived here
        // from mrp minus price, which would be the app pricing the product.
        if (pr.marginLabel.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Brand.positiveBg,
              borderRadius: BorderRadius.circular(Rad.chip),
              border: Border.all(color: Brand.positiveLine),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.trending_up_rounded,
                    size: 16, color: Brand.positiveFg),
                const SizedBox(width: 7),
                Text(
                  data.label('pdp_margin_title'),
                  style: AppType.t2.copyWith(color: Brand.positiveFg),
                ),
                const SizedBox(width: 8),
                Text(
                  pr.marginLabel,
                  style: AppType.l4.copyWith(
                      color: Brand.positiveFg, fontWeight: FontWeight.w800),
                ),
                if (pr.discountLabel.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    pr.discountLabel,
                    style: AppType.t2.copyWith(color: Brand.positiveFg),
                  ),
                ],
              ],
            ),
          ),
        ],
        // CHANGE #174 — the trade breakdown behind that margin: what the
        // pharmacy is billed (PTR), the scheme it was captured with, and the
        // tax split. Every row is a backend string; this widget prints pairs
        // and nothing else. Absent in mrp_only mode, so a product with no
        // captured pricing looks exactly as it did before.
        if (pr.hasPtr || pr.gst != null) ...[
          const SizedBox(height: 10),
          _TradeBreakdown(pricing: pr),
        ],
      ],
    );
  }
}

/// PTR + scheme + GST split, printed verbatim from the `pricing` block.
class _TradeBreakdown extends StatelessWidget {
  final Pricing pricing;
  const _TradeBreakdown({required this.pricing});

  @override
  Widget build(BuildContext context) {
    final gst = pricing.gst;
    final rows = <({String label, String value})>[
      if (pricing.hasPtr)
        (label: pricing.ptrCaption, value: pricing.ptrDisplay),
      if (pricing.schemeText.isNotEmpty)
        (label: 'Scheme', value: pricing.schemeText),
      if (gst != null) ...gst.lines,
    ];
    if (rows.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: Brand.field,
        borderRadius: BorderRadius.circular(Rad.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (gst != null && gst.title.isNotEmpty) ...[
            Text(gst.title, style: AppType.t2.copyWith(color: Brand.inkMuted)),
            const SizedBox(height: 8),
          ],
          for (final r in rows) ...[
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(r.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.b3.copyWith(color: Brand.inkSub)),
                  ),
                  const SizedBox(width: 12),
                  // Numbers right-aligned, as every money column in the app is.
                  Text(r.value,
                      style: AppType.b3
                          .copyWith(fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ],
          if (gst != null && gst.netDisplay.isNotEmpty)
            Row(
              children: [
                Expanded(
                  child: Text(pricing.netCaption,
                      style: AppType.t2.copyWith(color: Brand.inkMuted)),
                ),
                const SizedBox(width: 12),
                Text(gst.netDisplay,
                    style: AppType.l4.copyWith(fontWeight: FontWeight.w800)),
              ],
            ),
        ],
      ),
    );
  }
}

class _StockRow extends StatelessWidget {
  final ProductDetail data;
  const _StockRow({required this.data});

  @override
  Widget build(BuildContext context) {
    // CHANGE #640 — `data.buyable` is the availability VERDICT's own
    // `is_available` (see ProductDetail), not a second stock column. The chip
    // and the bottom bar are two renderings of one answer.
    if (data.buyable) {
      if (!data.hasSupplierLabel) return const SizedBox.shrink();
      return _Chip(
        text: data.supplierLabel,
        bg: const Color(0xFFECFDF3),
        fg: const Color(0xFF15803D),
      );
    }
    // CMD #451 row 84 — a banned / discontinued / not-for-sale product is not
    // "out of stock", and saying so beside a supplier count was the exact
    // contradiction the register row was raised for. The chip's words and the
    // reason under it are the backend's.
    if (data.blockedByStatus && data.statusLabel.isNotEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _Chip(
          text: data.statusLabel,
          bg: Ds.c.dangerSoft,
          fg: Ds.c.danger,
        ),
        if (data.statusReason.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x4),
            child: Text(data.statusReason, style: Ds.t.caption),
          ),
      ]);
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
    // CHANGE #640 — the page's ONE add decision, the same one the stock chip
    // and the Notify probe above read.
    final canAdd = data.canAdd;
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
                      // CHANGE #174 — the caption must name the number ABOVE
                      // it. `mrp_note` is always the word "MRP", so once a
                      // product had trade pricing this bar printed the NET
                      // rate under the caption "MRP" — the exact mislabelling
                      // this change exists to prevent. `price_caption` is the
                      // backend's own word for whatever price_display holds:
                      // 'NET' in full mode, 'MRP' in mrp_only, so no branch is
                      // needed here and the two modes cannot drift apart.
                      pr.priceCaption.isNotEmpty
                          ? pr.priceCaption
                          : data.mrpNote,
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
            // CMD #451 row 84 — Notify is for stock that can come back. A
            // product blocked by its catalogue status never will, so the bar
            // prints the backend's verdict instead of a subscription control.
            if (!canAdd && data.blockedByStatus)
              Expanded(
                child: Text(
                  av?.ctaLabel ?? data.statusLabel,
                  style: Ds.t.bodyStrong.copyWith(color: Ds.c.danger),
                ),
              )
            else if (!canAdd)
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

/// The trust strip: chips printed in payload order, each with the backend's
/// own label, note and tone. The only mapping done here is tone-name → design
/// token, which is styling, not a decision.
class _TrustStrip extends StatelessWidget {
  final PdTrust trust;
  const _TrustStrip({required this.trust});

  Color _toneColor(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.success;
      case 'warning':
        return Ds.c.warning;
      case 'danger':
        return Ds.c.danger;
      case 'info':
        return Ds.c.info;
      default:
        return Ds.c.textSecondary;
    }
  }

  Color _toneBg(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.successSoft;
      case 'warning':
        return Ds.c.warningSoft;
      case 'danger':
        return Ds.c.dangerSoft;
      case 'info':
        return Ds.c.infoSoft;
      default:
        return Ds.c.bg;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final chip in trust.chips)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x12, vertical: Ds.space.x4),
                  decoration: BoxDecoration(
                    color: _toneBg(chip.tone),
                    borderRadius: Ds.r.rChip,
                  ),
                  child: Text(
                    chip.label,
                    style: Ds.t.caption.copyWith(
                      color: _toneColor(chip.tone),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                SizedBox(width: Ds.space.x8),
                Expanded(
                  child: Text(
                    chip.note,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Ds.t.caption,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// CHANGE #461/#170 — the PDP's prescription block. Class chip, the backend's
/// title and note, and (for an Rx pack, signed in) the licence line. Nothing
/// here decides what a schedule is or what colour it should be.
class _C461RxBlock extends StatelessWidget {
  final ProductDetail data;
  const _C461RxBlock({required this.data});

  @override
  Widget build(BuildContext context) {
    final bg = Ds.hex(data.rxTone?['bg'], Ds.c.infoSoft);
    final fg = Ds.hex(data.rxTone?['fg'], Ds.c.text);
    final licenceNote = data.rxLicenceNote;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rCard),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (data.rxLabel.isNotEmpty)
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x8, vertical: Ds.space.x4 / 2),
                  decoration: BoxDecoration(
                      color: Ds.c.surface, borderRadius: Ds.r.rChip),
                  child: Text(data.rxLabel,
                      style: Ds.t.caption.copyWith(color: fg)),
                ),
              if (data.rxLabel.isNotEmpty) SizedBox(width: Ds.space.x8),
              Expanded(
                child: Text(data.rxTitle,
                    style: Ds.t.subtitle.copyWith(color: fg),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          if (data.rxNote.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(data.rxNote, style: Ds.t.body.copyWith(color: fg)),
          ],
          // Only an Rx pack viewed by a signed-in pharmacy carries this.
          if (data.isRx && licenceNote.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(licenceNote, style: Ds.t.caption.copyWith(color: fg)),
          ],
        ],
      ),
    );
  }
}
