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
import '../widgets/cart_pill.dart';
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

    // CMD #791 — REACHABILITY PROOF for the four depth blocks. Flutter renders
    // to canvas, so no browser tool can read this page; the render log is how a
    // live build proves the gallery, the fact table, the buyer's own overlay
    // and the co-purchase rail actually reached a real device — and, for the
    // overlay, that an ANONYMOUS visit reports has=false while the content
    // blocks still report their counts.
    RenderLog.write('c791_product_depth',
        'gallery=${res.gallery.images.length};facts=${res.facts.rows.length};'
        'purchase=${res.purchase.has};usual=${res.purchase.usualQty};'
        'companions=${res.companions.items.length}');

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
      // CMD #1896 — the sticky PTR + MRP + Add-to-cart bar is GONE. It repeated
      // the price block a thumb's width below the price block, and it took 68px
      // off every product page to do it. The buy control moved onto the price
      // row where the number it acts on already is, and the bottom of the page
      // now carries the SAME floating cart pill the storefront shell carries —
      // one cart control in the app, drawn from `cart_render().render.pill`.
      body: Stack(
        children: [
          _loading
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
                  subscribed: _subscribed,
                  notifyRequest: widget.notifyRequest,
                ),
          // The pill shows itself: `render.pill.show` is the backend's answer
          // to "is there a cart", so an empty cart draws nothing here and this
          // page never counts the cart to decide.
          if (!_loading && d != null && d.ok)
            Positioned(
              left: 0,
              right: 0,
              bottom: Ds.space.x16,
              child: RepaintBoundary(
                child: CartPill(onTap: () => requestOpenCart(context)),
              ),
            ),
        ],
      ),
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

  /// CMD #1896 — the buy control moved onto the price row, so the Notify state
  /// the sticky bar used to hold comes down here with it.
  final bool subscribed;
  final NotifyRequest? notifyRequest;

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
    required this.subscribed,
    required this.notifyRequest,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      // CMD #1896 — the bottom inset clears the floating cart pill, so the last
      // row of the page is readable instead of sitting under it.
      padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x8, Ds.space.x16,
          Ds.touch.bottomBarGap + Ds.space.x24),
      children: [
        _Gallery(gallery: data.gallery, heroId: data.id),
        SizedBox(height: Ds.space.x16),
        _TitleBlock(data: data),
        // CMD #410 — the aggregate rating. `has` is the backend's verdict on
        // whether there is enough evidence to show one at all; below its floor
        // there is no row here, not a 5.0 written by a single customer.
        if (data.rating.has) ...[
          SizedBox(height: Ds.space.x8),
          _RatingRow(summary: data.rating),
        ],
        SizedBox(height: Ds.space.x16),
        _PriceRow(
          data: data,
          subscribed: subscribed,
          notifyRequest: notifyRequest,
        ),
        // CMD #1903 — the pack family, and the ONLY place it appears in the
        // app. Every list is one row per product now; a buyer who wants the
        // syrup instead of the tablet chooses it here, on the page where they
        // are already deciding, rather than from a chip on a card in a list.
        if (data.otherPacks.has) ...[
          SizedBox(height: Ds.space.x12),
          _OtherPacks(packs: data.otherPacks),
        ],
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
        // CMD #1825 — the CHANGE #461 prescription block (title + licence
        // note in a full-width tinted box) and the older `pdp_rx_banner`
        // fallback both left this spot. The class is the tag beside the name;
        // the regulatory detail stays in the Product details fact row.
        const SizedBox(height: 12),
        _StockRow(data: data),
        // CMD #1826 — supply confidence: a band, never a count. `has` is the
        // backend's verdict; a pack nobody has answered on lately draws
        // nothing here rather than a grey "unknown".
        if (data.supply.has) ...[
          SizedBox(height: Ds.space.x12),
          _SupplyBand(supply: data.supply),
        ],
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

/// CMD #1896 — the title block, tight.
///
/// Order: the pack-type pill (pale green — "Strip", "Vial", "Tablet"), then the
/// product name with the prescription tag on its right, then the company, then
/// ONE pack line. What went: the lone grey "Vial" line that repeated what the
/// pill now says, and the second pack string beneath it.
///
/// `title` is `product_detail()`'s own block — the pill's word, the pack
/// sentence ("Strip of 10 tablets") and the tone are all rendered in SQL. A
/// payload older than this change has no `title`, and the block then reads the
/// `header` fields it always did, so an app build in a cache still works.
/// CMD #1903 — "Other packs": the strip under the price.
///
/// One chip per OTHER pack, in the backend's order. The pack being viewed is
/// not in the row — the page's own title already says which one it is — so
/// every chip is the same outlined pill and none of them is highlighted.
/// Tapping one REPLACES this page with that pack's own page, so the back stack
/// does not fill up with a walk around one family. Every word is
/// `pdp_other_packs()`'s — the heading and each label.
class _OtherPacks extends StatelessWidget {
  final PdOtherPacks packs;
  const _OtherPacks({required this.packs});

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c1903_other_packs', 'n=${packs.items.length}');
    // CMD #1903 (Om, live) — ONE sideways-scrolling row, never a stack. A
    // Wrap gave each pack its own full-width line as soon as three labels no
    // longer fitted across, which read as three buttons to press rather than
    // as a list of the other packs. The row scrolls instead: the packs stay
    // side by side however many there are, and a long family runs off the
    // right edge rather than down the page.
    RenderLog.write('c1903_packs_hscroll', '${packs.items.length}');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (packs.title.isNotEmpty) ...[
          Text(packs.title,
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          SizedBox(height: Ds.space.x8),
        ],
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < packs.items.length; i++) ...[
                if (i > 0) SizedBox(width: Ds.space.x8),
                _PackChip(
                  label: packs.items[i].label,
                  onTap: () => Navigator.of(context).pushReplacementNamed(
                      '/product/${packs.items[i].productId}'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// CMD #1903 (Om, live) — every pack in the row is the SAME chip: a small
/// outlined pill the height of the form chip above the title. There is no
/// selected state, because the pack being viewed is not in the row at all.
class _PackChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _PackChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rChip,
      child: Container(
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x4),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rChip,
          border: Border.all(color: Ds.c.divider),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Ds.t.caption.copyWith(color: Ds.c.text),
        ),
      ),
    );
  }
}

class _TitleBlock extends StatelessWidget {
  final ProductDetail data;
  const _TitleBlock({required this.data});

  @override
  Widget build(BuildContext context) {
    final t = data.title;
    // The fallback is per-PAYLOAD, not per-field: `title.has` false means an
    // app build reading a payload older than CMD #1896, and only then does the
    // block read `header`. Once the block IS present its answers are final —
    // a `form_chip.has:false` is the backend saying "no pill", and reaching
    // past it to header.form_chip would be the page overruling the backend.
    final chipLabel = t.has ? t.formChip.label : data.formChip;
    final packLine = t.has ? t.packLine.label : data.packLabel;
    final name = t.has && t.name.isNotEmpty ? t.name : data.name;
    final company = t.has && t.company.isNotEmpty ? t.company : data.company;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (chipLabel.isNotEmpty) ...[
          _Chip(
            key: const ValueKey('pdp-form-chip'),
            text: chipLabel,
            bg: Ds.c.successSoft,
            fg: Ds.c.success,
          ),
          SizedBox(height: Ds.space.x8),
        ],
        // CMD #1825 — the prescription class is a small tag beside the name,
        // nothing more. mediBO's buyers are licence-verified pharmacies, so
        // the old full-width red "your licence must be on file" block was a
        // warning aimed at nobody; the licence RULE itself is unchanged and
        // still speaks at the cart (rx_licence_gate). Label and tone are
        // rx_badge()'s; `has:false` draws no tag at all.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Ds.t.title,
              ),
            ),
            if (data.hasRxTag) ...[
              SizedBox(width: Ds.space.x8),
              _RxTag(data: data),
            ],
          ],
        ),
        if (company.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(
            company.toUpperCase(),
            style: Ds.t.caption.copyWith(
                color: Ds.c.textSecondary,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.7),
          ),
        ],
        if (packLine.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(
            packLine,
            key: const ValueKey('pdp-pack-line'),
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
          ),
        ],
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

/// CMD #1896 — ONE hero shot in a bordered card, dots beneath it, tap to zoom.
///
/// What left, and why: a thumbnail strip (five 52px squares that duplicated
/// the swipe you already have) and a "1 / 5 · Tap to zoom" caption line. The
/// counter still exists in the payload and the ZOOM viewer still prints it —
/// it is useful when the image is filling the screen and useless as a caption
/// on a page you are scrolling past. Nothing about the images is decided here:
/// how many there are, what each counter says and what the close control is
/// called all arrive from `product_gallery()`.
///
/// The card is a fixed height whether there are 0, 1 or 5 shots, so nothing
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

  /// The frame every state of the hero sits in — empty, single, or a swipe.
  Widget _card(Widget child) => Container(
        height: _h,
        width: double.infinity,
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider, width: Ds.space.hairline),
        ),
        padding: EdgeInsets.all(Ds.space.x12),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final imgs = widget.gallery.images;

    if (imgs.isEmpty) {
      return _card(Center(
        child: ProductImage(
          url: '',
          width: _h,
          height: _h,
          radius: Ds.r.rCard,
        ),
      ));
    }

    final page = _page.clamp(0, imgs.length - 1);

    return Column(
      children: [
        _card(PageView.builder(
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
                key: ValueKey('pdp-gallery-shot-$i'),
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
        )),
        // Dots, and only when there is more than one shot to move between.
        if (imgs.length > 1) ...[
          SizedBox(height: Ds.space.x12),
          Row(
            key: const ValueKey('pdp-gallery-dots'),
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Indicators, not controls. An 8px dot cannot be a 44px tap
              // target and does not need to be: the hero is swiped, and a tap
              // ON the hero opens the zoom. A tappable dot would be the one
              // control on this page below the touch minimum.
              for (var i = 0; i < imgs.length; i++)
                AnimatedContainer(
                  duration: Ds.motion.standard,
                  margin: EdgeInsets.symmetric(horizontal: Ds.space.x4),
                  width: i == page ? Ds.space.x16 : Ds.space.x8,
                  height: Ds.space.x8,
                  decoration: BoxDecoration(
                    color: i == page ? Ds.c.brand : Ds.c.divider,
                    borderRadius: Ds.r.rChip,
                  ),
                ),
            ],
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

/// CMD #791 — the fact table. Same card as the Overview above it; both halves
/// of every row arrive rendered.
class _FactsTable extends StatelessWidget {
  final List<PdFactRow> rows;
  const _FactsTable({required this.rows});

  @override
  Widget build(BuildContext context) => _FactCard(
        rows: [for (final r in rows) (label: r.label, value: r.value)],
      );
}

/// CMD #1896 — the price block, and the one control that acts on it.
///
/// Reading order is the order a pharmacy reads a pack: the printed ceiling
/// first, small, struck and grey, then the number they actually pay, large.
/// Beside the big number, the discount off MRP; under it, the per-unit rate.
/// All four are strings from `price_lines` — this widget divides nothing,
/// subtracts nothing and formats nothing.
///
/// The buy control sits on the same row, right-aligned, because the price and
/// the button that acts on it belong together. It used to live in a sticky bar
/// that reprinted the price to explain itself.
class _PriceRow extends StatelessWidget {
  final ProductDetail data;
  final bool subscribed;
  final NotifyRequest? notifyRequest;

  const _PriceRow({
    required this.data,
    required this.subscribed,
    required this.notifyRequest,
  });

  @override
  Widget build(BuildContext context) {
    final pr = data.pricing;
    final pl = data.priceLines;
    // CMD #1826 — when the two-line block is present the page prints it and
    // never the legacy single price. Without it (an older backend) has_price
    // is the explicit absence: no MRP at all, so no price rather than ₹0.00.
    final hasPrice = pl.has || (pr != null && pr.hasPrice);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (hasPrice)
              Expanded(
                child: pl.has
                    ? _PriceLines(lines: pl)
                    : _LegacyPriceRow(data: data, pricing: pr!),
              )
            else
              const Spacer(),
            SizedBox(width: Ds.space.x12),
            _BuyControl(
              data: data,
              subscribed: subscribed,
              notifyRequest: notifyRequest,
            ),
          ],
        ),
        // The margin line: the whole reason a pharmacy is on this screen.
        // Rendered only when the backend computed one — never derived here
        // from mrp minus price, which would be the app pricing the product.
        if (pr != null && pr.marginLabel.isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          Container(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x12, vertical: Ds.space.x8),
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
                SizedBox(width: Ds.space.x8),
                Text(
                  data.label('pdp_margin_title'),
                  style: AppType.t2.copyWith(color: Brand.positiveFg),
                ),
                SizedBox(width: Ds.space.x8),
                Text(
                  pr.marginLabel,
                  style: AppType.l4.copyWith(
                      color: Brand.positiveFg, fontWeight: FontWeight.w800),
                ),
                if (pr.discountLabel.isNotEmpty) ...[
                  SizedBox(width: Ds.space.x8),
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
        if (pr != null && (pr.hasPtr || pr.gst != null)) ...[
          SizedBox(height: Ds.space.x12),
          _TradeBreakdown(pricing: pr),
        ],
      ],
    );
  }
}

/// CHANGE #638's single price, kept for a payload that predates the two-line
/// block. Same rule as everything else here: the string is the backend's.
class _LegacyPriceRow extends StatelessWidget {
  final ProductDetail data;
  final Pricing pricing;
  const _LegacyPriceRow({required this.data, required this.pricing});

  @override
  Widget build(BuildContext context) {
    final pr = pricing;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        if (pr.priceCaption.isNotEmpty) ...[
          Text(pr.priceCaption,
              style: AppType.t2.copyWith(
                  color: Brand.inkMuted,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6)),
          SizedBox(width: Ds.space.x4),
        ],
        Flexible(
          child: Text(
            pr.priceDisplay,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.h4.copyWith(color: Brand.price),
          ),
        ),
        // The struck MRP appears only when the backend says there IS a
        // discount — otherwise it would strike through the same number.
        if (pr.hasDiscount) ...[
          SizedBox(width: Ds.space.x8),
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
          SizedBox(width: Ds.space.x8),
          _Chip(
            text: data.gstLabel,
            bg: Brand.field,
            fg: Brand.inkSub,
          ),
        ],
      ],
    );
  }
}

/// CMD #1896 — the buy control, on the price row.
///
/// One decision, and it is not this widget's: `data.canAdd` is the payload's
/// availability verdict. Buyable → the backend's own CTA word, which becomes
/// the stepper IN PLACE the moment there is a quantity. Not buyable → Notify,
/// whose two labels are also the payload's.
class _BuyControl extends StatelessWidget {
  final ProductDetail data;
  final bool subscribed;
  final NotifyRequest? notifyRequest;

  const _BuyControl({
    required this.data,
    required this.subscribed,
    required this.notifyRequest,
  });

  static const double _w = 148;

  @override
  Widget build(BuildContext context) {
    final av = data.availability;
    // No verdict and not buyable — nothing to offer, so no control at all.
    if (av == null && !data.buyable) return const SizedBox.shrink();

    final cart = AppState.of(context);
    final qty = cart.quantityOf(data.id);
    // CHANGE #640 — the page's ONE add decision, the same one the stock chip
    // and the Notify probe above read.
    final canAdd = data.canAdd;

    // CHANGE #638 — an unbuyable product offers Notify instead of a dead
    // disabled button.
    // CMD #1812 — and it ALWAYS offers Notify now: the only way to be
    // unavailable is zone standby 0, which is stock that can come back.
    if (!canAdd) {
      return NotifyControl(
        productId: data.id,
        initiallySubscribed: subscribed,
        compact: false,
        notifyLabel: data.label('card_notify_label'),
        subscribedLabel: data.label('notify_subscribed_label'),
        request: notifyRequest,
      );
    }

    return SizedBox(
      width: _w,
      height: Ds.touch.minTarget,
      child: qty > 0
          ? _BarStepper(
              qty: qty,
              onMinus: () => cart.decrementId(data.id),
              onPlus: () => cart.incrementId(data.id),
            )
          : FilledButton(
              onPressed: () {
                if (cart.isPending(data.id)) return;
                cart.addId(data.id);
              },
              style: FilledButton.styleFrom(
                backgroundColor: Ds.c.brand,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x8),
              ),
              // Verbatim backend label; falls back to the stock label the
              // payload also carries, never to a word typed here.
              child: Text(
                av?.ctaLabel ?? data.label('stock_out_label'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Ds.t.bodyStrong.copyWith(color: Ds.c.surface),
              ),
            ),
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

/// CMD #1826 — one tone word → one pair of colours. The ONLY place the band's
/// colour is decided, and it reads `tone`, never `band` or the sub-line.
Color _toneBg(String tone) => switch (tone) {
      'success' => Brand.positiveBg,
      'warning' => Ds.c.warningSoft,
      'danger' => Brand.negativeBg,
      _ => Brand.field,
    };

Color _toneFg(String tone) => switch (tone) {
      'success' => Brand.positiveFg,
      'warning' => Ds.c.warning,
      'danger' => Brand.negativeFg,
      _ => Brand.inkSub,
    };

/// CMD #1896 — MRP first (small, struck, grey, with the ceiling sentence on an
/// info tooltip), the sale price under it (large, the number the buyer acts
/// on), the discount beside it and the per-unit rate beneath.
///
/// #1826 put the sale price on top and printed the ceiling sentence as a line
/// of its own. Om's sketch reverses the pair and demotes the sentence: a
/// pharmacy scans the printed MRP, then the rate — and the sentence explaining
/// what MRP is does not need to be on screen every time to be available.
class _PriceLines extends StatelessWidget {
  final PdPriceLines lines;
  const _PriceLines({required this.lines});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MrpLine(key: const ValueKey('pdp-mrp-line'), line: lines.mrp),
        SizedBox(height: Ds.space.x4),
        _SaleLine(
          key: const ValueKey('pdp-sale-line'),
          line: lines.sale,
          discount: lines.discount,
        ),
      ],
    );
  }
}

/// The printed ceiling: caption, the amount struck through when the backend
/// says `strike`, and an (i) carrying the backend's sentence about it.
class _MrpLine extends StatelessWidget {
  final PdPriceLine line;
  const _MrpLine({super.key, required this.line});

  @override
  Widget build(BuildContext context) {
    final style = Ds.t.caption.copyWith(
      color: Ds.c.textSecondary,
      decoration: line.strike ? TextDecoration.lineThrough : null,
      decorationColor: Ds.c.textSecondary,
    );
    return Row(
      children: [
        if (line.caption.isNotEmpty) ...[
          Text(line.caption,
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          SizedBox(width: Ds.space.x4),
        ],
        Flexible(child: Text(line.value, maxLines: 1, style: style)),
        // CMD #1896 — the sentence that used to be printed here. `has` is the
        // backend's, and the words are the backend's; the page owns the icon.
        if (line.info.has) ...[
          SizedBox(width: Ds.space.x4),
          Tooltip(
            key: const ValueKey('pdp-mrp-info'),
            message: line.info.text,
            triggerMode: TooltipTriggerMode.tap,
            child: Semantics(
              label: line.info.label,
              child: Icon(Icons.info_outline,
                  size: Ds.space.x16, color: Ds.c.textSecondary),
            ),
          ),
        ],
      ],
    );
  }
}

/// The number the buyer acts on: the backend's rupee string, or the backend's
/// word ("PTR") when this viewer may not see a trade rate. `hasAmount` decides
/// the ink — a phrase is never painted as a price.
class _SaleLine extends StatelessWidget {
  final PdPriceLine line;
  final PdChip discount;
  const _SaleLine({super.key, required this.line, required this.discount});

  @override
  Widget build(BuildContext context) {
    final TextStyle valueStyle = line.hasAmount
        ? AppType.h4.copyWith(color: Brand.price)
        : AppType.l4.copyWith(
            color: Brand.inkSub, fontWeight: FontWeight.w600);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
                child: Text(line.value, maxLines: 1, style: valueStyle)),
            // The one green thing on the price block, and only when the
            // backend had a real trade rate to discount from.
            if (discount.has) ...[
              SizedBox(width: Ds.space.x8),
              Text(
                discount.label,
                key: const ValueKey('pdp-discount'),
                style: Ds.t.caption.copyWith(
                    color: Ds.c.success, fontWeight: FontWeight.w700),
              ),
            ],
          ],
        ),
        // "₹19.91 / tablet" — divided in SQL from the pack sentence.
        if (line.perUnit.has) ...[
          SizedBox(height: Ds.space.x4),
          Text(line.perUnit.label,
              key: const ValueKey('pdp-per-unit'),
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
        ],
        if (line.hasNote && line.note.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(line.note, style: AppType.t2.copyWith(color: Brand.inkMuted)),
        ],
      ],
    );
  }
}

/// CMD #1826 — the supply-confidence band. Label, tone, sub-line and speed
/// line are printed verbatim; nothing here counts anything.
class _SupplyBand extends StatelessWidget {
  final PdSupply supply;
  const _SupplyBand({required this.supply});

  @override
  Widget build(BuildContext context) {
    final fg = _toneFg(supply.tone);
    return Container(
      key: const ValueKey('pdp-supply-band'),
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x8),
      decoration: BoxDecoration(
        color: _toneBg(supply.tone),
        borderRadius: BorderRadius.circular(Rad.chip),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.verified_outlined, size: Ds.space.x16, color: fg),
              SizedBox(width: Ds.space.x8),
              Flexible(
                child: Text(supply.label,
                    style: AppType.b3
                        .copyWith(color: fg, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          if (supply.hasSub && supply.sub.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(supply.sub,
                style: AppType.t2.copyWith(color: Brand.inkMuted)),
          ],
          if (supply.hasSpeed && supply.speed.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(supply.speed,
                style: AppType.t2.copyWith(color: Brand.inkMuted)),
          ],
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
    // CMD #1812 — the red catalogue-status chip is gone. 1mg's scraped word
    // never described mediBO's supply, so there is exactly one non-available
    // state left and the backend words it: out of stock in this zone.
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

/// CMD #1896 — the Overview table, same shape as the fact table below it: one
/// bordered card, a FIXED label column so every value starts on the same
/// vertical line, and a hairline between rows. It was a `Table` with flex
/// columns, which meant the label column moved with the longest label and no
/// two products lined up the same way.
///
/// Composition is printed HERE and nowhere else on the page: `product_facts()`
/// stopped sending its duplicate row in CMD #1896.
class _OverviewTable extends StatelessWidget {
  final List<PdOverviewRow> rows;
  const _OverviewTable({required this.rows});

  @override
  Widget build(BuildContext context) => _FactCard(
        rows: [for (final r in rows) (label: r.label, value: r.value)],
      );
}

/// The one row-pair card both tables draw. Two columns, a fixed label width and
/// a hairline between rows — nothing else, on purpose.
class _FactCard extends StatelessWidget {
  final List<({String label, String value})> rows;
  const _FactCard({required this.rows});

  static const double _labelW = 130;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider, width: Ds.space.hairline),
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
                    width: _labelW,
                    child: Text(rows[i].label, style: Ds.t.caption),
                  ),
                  SizedBox(width: Ds.space.x12),
                  Expanded(child: Text(rows[i].value, style: Ds.t.body)),
                ],
              ),
            ),
          ],
        ],
      ),
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

// ── The stepper the buy control turns into ───────────────────────────────────

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

/// CMD #1896 — a section header is small, grey and wide-tracked now, not a
/// near-black 15.5px heading competing with the product name.
///
/// The text itself is NOT transformed. Om's sketch says "uppercase", and a
/// `.toUpperCase()` here would be the app rewriting a backend string — the one
/// thing this file exists not to do. Uppercase headings are one UPDATE to
/// storefront_ui_label away, with no deploy; the weight, size, colour and
/// tracking are what a screen is allowed to decide, and they are what changed.
class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle({required this.text});

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: Ds.t.caption.copyWith(
          color: Ds.c.textSecondary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      );
}

class _Chip extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;
  const _Chip(
      {super.key, required this.text, required this.bg, required this.fg});

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
                // CMD #1835 — a note only when the backend sent one. The
                // fill-rate chip no longer carries a sentence, so nothing is
                // laid out beside it; the cold-chain chip still explains
                // itself in the backend's own words.
                if (chip.note.isNotEmpty) ...[
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
              ],
            ),
          ),
      ],
    );
  }
}

/// CMD #1825 — the PDP's prescription class as a compact tag: the backend's
/// label in the backend's tone, chip radius, caption size, medium weight. No
/// container wider than its text, no sentence, no icon. It decides nothing:
/// what "Rx" means and what colour it wears both arrive in rx_badge().
class _RxTag extends StatelessWidget {
  final ProductDetail data;
  const _RxTag({required this.data});

  @override
  Widget build(BuildContext context) {
    if (data.rxLabel.isEmpty) return const SizedBox.shrink();
    final bg = Ds.hex(data.rxTone?['bg'], Ds.c.infoSoft);
    final fg = Ds.hex(data.rxTone?['fg'], Ds.c.info);
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
      child: Text(
        data.rxLabel,
        style: Ds.t.caption.copyWith(color: fg, fontWeight: FontWeight.w500),
      ),
    );
  }
}
