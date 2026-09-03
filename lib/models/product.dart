// Domain models for the B2B pharmacy ordering platform.

/// CHANGE #553 — the backend's own rendered availability verdict for one row.
///
/// Every field here is produced by `storefront_cta()` in Postgres and arrives
/// ready to paint: the label, the two colours and the enabled/disabled
/// decision. The client NEVER derives any of them — no supplier_count
/// comparison, no threshold, no colour constant, no hardcoded string. Add a
/// rule here and the storefront stops agreeing with the database.
///
/// Carried by the three storefront RPCs (`storefront_page`,
/// `storefront_search_page`, `storefront_product`) and by `cart_availability`.
class Availability {
  /// Button text, e.g. "Add to cart" / "Unavailable". Print verbatim.
  final String ctaLabel;

  /// CHANGE #274 — the SHORT form of [ctaLabel] ("ADD"), for the compact card's
  /// 68px pill. A separate backend string rather than a truncation of the long
  /// one, because "Add to cart" → "ADD" is a wording decision: shortening it in
  /// Dart would put a display string back in the app.
  final String ctaShort;

  /// Whether the row may be added to the cart. Drives enabled/disabled.
  final bool canAdd;

  /// Whether the backend considers the product available at all.
  final bool isAvailable;

  /// True when the viewer is an approved customer (real availability shown).
  /// False for unapproved / anonymous / incognito — everything looks available.
  final bool gated;

  /// True when the backend could not resolve the product. Deliberately still
  /// addable — never block on something that could not be checked.
  final bool unresolved;

  /// Explanation shown when [canAdd] is false. Null when there is nothing to say.
  final String? note;

  /// Background / foreground as ARGB ints, parsed from the `#RRGGBB` the
  /// backend sends. Null when the row carried no colours — the caller then
  /// keeps its default styling rather than inventing one.
  final int? bg;
  final int? fg;

  const Availability({
    required this.ctaLabel,
    this.ctaShort = '',
    required this.canAdd,
    required this.isAvailable,
    this.gated = false,
    this.unresolved = false,
    this.note,
    this.bg,
    this.fg,
  });

  /// Parses the `availability` object attached to every storefront/cart row.
  /// Returns null when the row carried none (a legacy/fallback path that never
  /// went through the storefront RPCs) — callers keep their existing styling
  /// for that case rather than fabricating a verdict.
  static Availability? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final label = m['cta_label']?.toString();
    if (label == null || label.isEmpty) return null;
    final colors = m['colors'];
    final c = colors is Map ? Map<String, dynamic>.from(colors) : const {};
    final noteRaw = m['note']?.toString().trim();
    return Availability(
      ctaLabel: label,
      ctaShort: (m['cta_short'] ?? '').toString(),
      canAdd: m['can_add'] == true,
      isAvailable: m['is_available'] == true,
      gated: m['gated'] == true,
      unresolved: m['unresolved'] == true,
      note: (noteRaw == null || noteRaw.isEmpty) ? null : noteRaw,
      bg: _argb(c['bg']),
      fg: _argb(c['fg']),
    );
  }

  /// "#1B7A43" → 0xFF1B7A43. Null for anything unparseable.
  static int? _argb(Object? hex) {
    final s = hex?.toString().replaceAll('#', '').trim() ?? '';
    if (s.length == 6) {
      final v = int.tryParse(s, radix: 16);
      return v == null ? null : 0xFF000000 | v;
    }
    if (s.length == 8) return int.tryParse(s, radix: 16);
    return null;
  }

  Map<String, dynamic> toJson() => {
        'cta_label': ctaLabel,
        'cta_short': ctaShort,
        'can_add': canAdd,
        'is_available': isAvailable,
        'gated': gated,
        'unresolved': unresolved,
        if (note != null) 'note': note,
        'colors': {
          if (bg != null) 'bg': _hex(bg!),
          if (fg != null) 'fg': _hex(fg!),
        },
      };

  static String _hex(int argb) =>
      '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

/// CHANGE #573 — the backend's own rendered PRICE block for one row.
///
/// product_card.dart used to do this per card:
///     final discPct   = cart.discountPct;                  // server-decided
///     final salePrice = product.mrp * (1 - discPct / 100); // app COMPUTES
///     Text(rupees(salePrice));                             // app FORMATS
///     Text('${discPct.round()}% off');                     // app COMPOSES
///
/// The percentage was already server-decided, which made it worse rather than
/// better: the app took a server number and derived a price from it, so the
/// price on the card and the price the server would actually charge were two
/// answers to one question.
///
/// [hasPrice] encodes absence explicitly. 9.7% of MEDICINE rows (54,353 of
/// 562,549) carry no mrp at all; rendering those as "₹0.00" reads as a FREE
/// product rather than a missing one, so the card hides the price row instead.
class Pricing {
  /// False when the product has no usable MRP. NOT the same as a price of 0.
  final bool hasPrice;

  /// Backend-formatted, e.g. "₹98.40". Print verbatim; never re-format.
  final String priceDisplay;
  final String mrpDisplay;

  /// e.g. "18% margin". Empty when [hasDiscount] is false.
  final String discountLabel;
  final bool hasDiscount;

  /// CHANGE #673 — the caption printed above the price. "PTR" for B2B; the
  /// word itself is backend-owned so a B2C surface could say something else
  /// without a deploy. Empty means print no caption.
  final String priceCaption;

  /// CHANGE #673 — the corner ribbon, sent as TWO explicit lines rather than
  /// one string the app would have to split. Empty when there is no ribbon.
  final String ribbonTop;
  final String ribbonBottom;

  /// CHANGE #673 — "You earn ₹42.10", already formatted. Empty when none.
  final String marginLabel;

  /// CHANGE #174 — which of the two payloads this is: `full` (the product has
  /// real PTR + GST, so the net rate and the margin are known) or `mrp_only`
  /// (nothing has been captured yet). This is the ONLY thing a surface may
  /// branch on. Never infer the mode from a number being zero — a margin of
  /// zero and an unknown margin are different facts.
  final String displayMode;

  /// True when [mrpDisplay] holds a SECOND number worth striking through.
  /// Explicit rather than reusing [hasDiscount], which older payloads set for
  /// a different reason.
  final bool hasStruckMrp;

  /// CHANGE #174 — the trade rate, e.g. "₹82.50", and its caption ("PTR").
  final bool hasPtr;
  final String ptrDisplay;
  final String ptrCaption;

  /// The net payable per unit ("₹84.00") and its caption ("NET"). In full mode
  /// this is also what [priceDisplay] holds — the headline number on a card IS
  /// what the pharmacy pays.
  final bool hasNet;
  final String netDisplay;
  final String netCaption;

  /// The scheme exactly as captured, e.g. "10+1". Empty when there is none.
  final String schemeText;

  /// CHANGE #175 — true when the product has an active scheme with a badge.
  final bool hasSchemeBadge;

  /// CHANGE #175 — the scheme badge chip (label + colours). Null when none.
  final PricingChip? schemeBadge;

  /// The margin chip, colours included. Null when the backend sent none —
  /// which is how an un-priced product stays chip-less.
  final PricingChip? marginChip;

  /// The tax split, for surfaces with room to print it (the PDP). Null in
  /// `mrp_only` mode.
  final GstBreakup? gst;

  /// CHANGE #274 — the compact card's MRP/PTR pair. Null only on a payload
  /// that predates the block; every storefront RPC sends one.
  final CardPrice? cardPrice;

  /// Raw numbers, for anything that must sort or compare. Never for display.
  final double salePrice;
  final double mrp;

  const Pricing({
    required this.hasPrice,
    required this.priceDisplay,
    required this.mrpDisplay,
    required this.discountLabel,
    required this.hasDiscount,
    required this.salePrice,
    required this.mrp,
    this.priceCaption = '',
    this.ribbonTop = '',
    this.ribbonBottom = '',
    this.marginLabel = '',
    this.displayMode = 'mrp_only',
    this.hasStruckMrp = false,
    this.hasPtr = false,
    this.ptrDisplay = '',
    this.ptrCaption = '',
    this.hasNet = false,
    this.netDisplay = '',
    this.netCaption = '',
    this.schemeText = '',
    this.hasSchemeBadge = false,
    this.schemeBadge,
    this.marginChip,
    this.gst,
    this.cardPrice,
  });

  /// True when the backend has real trade pricing for this product.
  bool get isFullPricing => displayMode == 'full';

  /// True when both ribbon lines arrived. The card never paints a half ribbon.
  bool get hasRibbon => ribbonTop.isNotEmpty && ribbonBottom.isNotEmpty;

  /// Parses the `pricing` object attached to every storefront row. Returns
  /// null when the row carried none, so callers can tell "backend said no
  /// price" (hasPrice == false) apart from "this row never went through a
  /// storefront RPC" (null) — two different situations that must not collapse.
  static Pricing? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    if (!m.containsKey('has_price')) return null;
    return Pricing(
      hasPrice: m['has_price'] == true,
      priceDisplay: (m['price_display'] ?? '').toString(),
      mrpDisplay: (m['mrp_display'] ?? '').toString(),
      discountLabel: (m['discount_label'] ?? '').toString(),
      hasDiscount: m['has_discount'] == true,
      salePrice: (m['sale_price'] as num?)?.toDouble() ?? 0.0,
      mrp: (m['mrp'] as num?)?.toDouble() ?? 0.0,
      priceCaption: (m['price_caption'] ?? '').toString(),
      ribbonTop: (m['ribbon_top'] ?? '').toString(),
      ribbonBottom: (m['ribbon_bottom'] ?? '').toString(),
      marginLabel: (m['margin_label'] ?? '').toString(),
      displayMode: (m['display_mode'] ?? 'mrp_only').toString(),
      hasStruckMrp: m['has_struck_mrp'] == true,
      hasPtr: m['has_ptr'] == true,
      ptrDisplay: (m['ptr_display'] ?? '').toString(),
      ptrCaption: (m['ptr_caption'] ?? '').toString(),
      hasNet: m['has_net'] == true,
      netDisplay: (m['net_display'] ?? '').toString(),
      netCaption: (m['net_caption'] ?? '').toString(),
      schemeText: (m['scheme_text'] ?? '').toString(),
      hasSchemeBadge: m['has_scheme'] == true,
      schemeBadge: PricingChip.fromMap(m['scheme_badge']),
      marginChip: PricingChip.fromMap(m['margin_chip']),
      gst: GstBreakup.fromMap(m['gst']),
      cardPrice: CardPrice.fromMap(m['card_price']) ??
          CardPrice.fallbackFrom(
            hasPrice: m['has_price'] == true,
            priceDisplay: (m['price_display'] ?? '').toString(),
            priceCaption: (m['price_caption'] ?? '').toString(),
            mrpDisplay: (m['mrp_display'] ?? '').toString(),
            hasStruckMrp: m['has_struck_mrp'] == true,
            hasPtr: m['has_ptr'] == true,
            ptrDisplay: (m['ptr_display'] ?? '').toString(),
            ptrCaption: (m['ptr_caption'] ?? '').toString(),
          ),
    );
  }

  Map<String, dynamic> toJson() => {
        'has_price': hasPrice,
        'price_display': priceDisplay,
        'mrp_display': mrpDisplay,
        'discount_label': discountLabel,
        'has_discount': hasDiscount,
        'sale_price': salePrice,
        'mrp': mrp,
        'price_caption': priceCaption,
        'ribbon_top': ribbonTop,
        'ribbon_bottom': ribbonBottom,
        'margin_label': marginLabel,
        'display_mode': displayMode,
        'has_struck_mrp': hasStruckMrp,
        'has_ptr': hasPtr,
        'ptr_display': ptrDisplay,
        'ptr_caption': ptrCaption,
        'has_net': hasNet,
        'net_display': netDisplay,
        'net_caption': netCaption,
        'scheme_text': schemeText,
        'has_scheme': hasSchemeBadge,
        'scheme_badge': schemeBadge?.toJson(),
        'margin_chip': marginChip?.toJson(),
        'gst': gst?.toJson(),
        'card_price': cardPrice?.toJson(),
      };
}

/// CHANGE #174 — a small coloured chip the backend fully specifies: the words
/// AND the two colours. The band a margin falls into is a business rule, so it
/// is decided in Postgres (`app_settings.pricing_margin_bands`) and can be
/// re-tuned without a deploy. The app never picks a colour from a number.
class PricingChip {
  final String label;

  /// ARGB ints parsed from the `#RRGGBB` the backend sends. Null when the
  /// payload carried no colour — the caller then keeps its own styling rather
  /// than inventing one, exactly like [Availability].
  final int? bg;
  final int? fg;

  const PricingChip({required this.label, this.bg, this.fg});

  static PricingChip? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final label = (m['label'] ?? '').toString();
    if (label.isEmpty) return null;
    return PricingChip(
      label: label,
      bg: Availability._argb(m['bg']),
      fg: Availability._argb(m['fg']),
    );
  }

  Map<String, dynamic> toJson() => {'label': label};
}

/// CHANGE #174 — the tax split, already worded and formatted. [lines] is a
/// printable list ("CGST 6%" → "₹4.50"): the app prints the pairs in order and
/// never assembles a label out of a rate, because whether a sale is CGST+SGST
/// or IGST is a tax decision, not a layout one.
class GstBreakup {
  final String title;
  final String pctDisplay;
  final String taxableDisplay;
  final String amountDisplay;
  final String netDisplay;
  final List<({String label, String value})> lines;

  const GstBreakup({
    required this.title,
    required this.pctDisplay,
    required this.taxableDisplay,
    required this.amountDisplay,
    required this.netDisplay,
    required this.lines,
  });

  static GstBreakup? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final rawLines = m['lines'];
    final lines = <({String label, String value})>[];
    if (rawLines is List) {
      for (final l in rawLines) {
        if (l is Map) {
          lines.add((
            label: (l['label'] ?? '').toString(),
            value: (l['value'] ?? '').toString(),
          ));
        }
      }
    }
    if (lines.isEmpty) return null;
    return GstBreakup(
      title: (m['title'] ?? '').toString(),
      pctDisplay: (m['pct_display'] ?? '').toString(),
      taxableDisplay: (m['taxable_display'] ?? '').toString(),
      amountDisplay: (m['amount_display'] ?? '').toString(),
      netDisplay: (m['net_display'] ?? '').toString(),
      lines: lines,
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'pct_display': pctDisplay,
        'taxable_display': taxableDisplay,
        'amount_display': amountDisplay,
        'net_display': netDisplay,
        'lines': [
          for (final l in lines) {'label': l.label, 'value': l.value},
        ],
      };
}


/// CHANGE #274 — the card's own two-line B2B price block, rendered verbatim.
///
/// mediBO sells trade stock, so a product card carries two numbers with two
/// meanings and the card must never blur them:
///
///  * **MRP** — the printed consumer ceiling. Reference information, struck
///    through when there is a trade price under it. It is never what anyone is
///    charged.
///  * **PTR** — the price-to-retailer the pharmacy actually pays. Discounts
///    and GST land on the BILL, not on the shelf label, so this is the trade
///    rate as captured, not a computed net.
///
/// [hasPtr] is the backend's own answer to "may this viewer see a trade
/// price". It is not a hint: an un-entitled viewer's payload carries no
/// `ptr_display` key at all, so there is nothing here to hide in Flutter — see
/// `viewer_sees_trade_price()` in Postgres and the `storefront_ptr_entitlement`
/// regression guard. When PTR is withheld the backend sends [note] instead,
/// telling the visitor how to become entitled.
class CardPrice {
  final bool hasMrp;
  final String mrpLabel;
  final String mrpDisplay;

  /// Strike the MRP only when a trade price sits under it. A struck price with
  /// nothing beneath reads as "unavailable", which is a different claim.
  final bool strikeMrp;

  final bool hasPtr;
  final String ptrLabel;
  final String ptrDisplay;

  /// The filled box's colours, as ARGB ints parsed from the backend's
  /// `#RRGGBB`. Null keeps the caller's own styling.
  final int? ptrBg;
  final int? ptrFg;

  final bool hasNote;
  final String note;

  const CardPrice({
    required this.hasMrp,
    required this.mrpLabel,
    required this.mrpDisplay,
    required this.strikeMrp,
    required this.hasPtr,
    this.ptrLabel = '',
    this.ptrDisplay = '',
    this.ptrBg,
    this.ptrFg,
    this.hasNote = false,
    this.note = '',
  });

  /// CHANGE #274 — the block for a payload that predates `card_price`.
  ///
  /// Not every feed goes through `storefront_pricing()`: the short-dated rail,
  /// the back-in-stock strip and anything an older client cached send the
  /// pre-#274 shape. Without this they would draw an EMPTY price block, which
  /// is worse than the old single-line one.
  ///
  /// Nothing is computed or worded here — every value is a string the backend
  /// already sent, and a label it did not send is simply omitted rather than
  /// replaced with a Dart word. In particular the PTR half appears only when
  /// `ptr_display` is in the payload, which is exactly the entitlement rule
  /// `card_price` itself follows, so an old payload cannot leak a trade price
  /// a new one would have withheld.
  static CardPrice fallbackFrom({
    required bool hasPrice,
    required String priceDisplay,
    required String priceCaption,
    required String mrpDisplay,
    required bool hasStruckMrp,
    required bool hasPtr,
    required String ptrDisplay,
    required String ptrCaption,
  }) {
    // `mrp_only`: the headline IS the MRP, and price_caption is its word.
    if (!hasStruckMrp) {
      return CardPrice(
        hasMrp: hasPrice && priceDisplay.isNotEmpty,
        mrpLabel: priceCaption,
        mrpDisplay: priceDisplay,
        strikeMrp: false,
        hasPtr: false,
      );
    }
    // `full`: the MRP is the struck ceiling and the trade rate sits under it.
    return CardPrice(
      hasMrp: mrpDisplay.isNotEmpty,
      mrpLabel: '',
      mrpDisplay: mrpDisplay,
      strikeMrp: hasPtr && ptrDisplay.isNotEmpty,
      hasPtr: hasPtr && ptrDisplay.isNotEmpty,
      ptrLabel: ptrCaption,
      ptrDisplay: ptrDisplay,
    );
  }

  static CardPrice? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    return CardPrice(
      hasMrp: m['has_mrp'] == true,
      mrpLabel: (m['mrp_label'] ?? '').toString(),
      mrpDisplay: (m['mrp_display'] ?? '').toString(),
      strikeMrp: m['strike_mrp'] == true,
      // Absent key and false both mean "no trade price for this viewer".
      hasPtr: m['has_ptr'] == true && (m['ptr_display'] ?? '').toString().isNotEmpty,
      ptrLabel: (m['ptr_label'] ?? '').toString(),
      ptrDisplay: (m['ptr_display'] ?? '').toString(),
      ptrBg: Availability._argb(m['ptr_bg']),
      ptrFg: Availability._argb(m['ptr_fg']),
      hasNote: m['has_note'] == true && (m['note'] ?? '').toString().isNotEmpty,
      note: (m['note'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'has_mrp': hasMrp,
        'mrp_label': mrpLabel,
        'mrp_display': mrpDisplay,
        'strike_mrp': strikeMrp,
        'has_ptr': hasPtr,
        if (hasPtr) 'ptr_label': ptrLabel,
        if (hasPtr) 'ptr_display': ptrDisplay,
        'has_note': hasNote,
        'note': note,
      };
}

/// A pharmaceutical product sold to business buyers (pharmacies, clinics).
///
/// Field names stay in the app's domain vocabulary; [Product.fromMap] maps
/// the `MEDICINE` table columns onto them.
class Product {
  final String id;
  final String name;

  /// Active composition, e.g. "Amoxicillin 500mg + Clavulanic Acid 125mg".
  final String genericName;
  final String manufacturer;
  final String category;

  /// Therapeutic class from the catalog (e.g. "GASTRO INTESTINAL"); drives the
  /// dynamic category list, tiles and filtering. Stored raw; prettify for UI.
  final String therapeuticClass;

  /// Product photo URL (onemg CDN). Empty when unavailable.
  final String imageUrl;

  /// All non-empty product image URLs (image_url_1 … image_url_5).
  final List<String> imageUrls;

  /// Pack description, e.g. "Strip of 10 tablets".
  final String packSize;

  /// CHANGE #636 — the dosage form ("Strip", "Vial", "Bottle"), straight from
  /// MEDICINE.pack_type. Rendered as the small chip under the compact card and
  /// on the product page. Never derived from the name or the pack size.
  final String formChip;

  /// CHANGE #287 — `pack_type_label`: the ONE word the storefront card prints
  /// beside the ADD pill ("Strip", "Vial"). MEDICINE.pack_type verbatim.
  /// Empty means the catalogue has no pack type for this row — the card prints
  /// nothing there rather than falling back to a sentence, which is exactly
  /// the truncation #287 removed.
  final String packTypeLabel;

  /// CHANGE #287 — `pack_qty_label`: the pack quantity chip ABOVE the product
  /// name, MEDICINE.pack_qty verbatim ("10.0 tablets in 1 strip"). Om's call on
  /// #287: the stored sentence, not the shortened badge. Empty means the column
  /// is null (most `Piece` rows) and the card draws no chip at all.
  final String packQtyLabel;

  /// Maximum Retail Price per pack (the printed consumer price).
  final double mrp;

  /// Wholesale (B2B) price per pack offered to the buyer.
  final double b2bPrice;

  /// GST percentage applied at checkout. Not stored on the medicines table;
  /// defaults to the standard 12% pharma rate.
  final double gstPercent;

  /// Minimum order quantity for B2B purchase.
  final int moq;

  /// Units currently available in the distributor's stock.
  final int stock;

  /// #102: true = at least one PS1–30 supplier exists → item is orderable.
  /// null (during backfill) is treated as false (unavailable) for safety.
  final bool? buyable;

  /// Regulatory schedule, e.g. "Schedule H", "OTC".
  final String schedule;

  /// Whether a valid prescription is required to dispense.
  final bool requiresPrescription;

  /// Distributor discount percentage off MRP.
  final double discount;

  /// Promotional scheme, e.g. "5+1" (buy 5 get 1 free). Empty when none.
  final String scheme;

  /// CHANGE #454 — "AV • 10S" etc., ALREADY formatted server-side by
  /// search_medicines_priority / get_storefront_feed. Print verbatim; never
  /// rebuild it. Null while the supplier-count backfill hasn't reached this
  /// row yet (buyable can still be true) or when not buyable.
  final String? supplierLabel;
  final int? supplierCount;

  /// CHANGE #553 — the backend's rendered availability verdict for this row.
  /// Non-null for anything fetched through the storefront RPCs; null on the
  /// legacy/fallback paths that do not carry one.
  final Availability? availability;

  /// CHANGE #573 — the backend's rendered price block for this row.
  final Pricing? pricing;

  /// CMD #791 — this buyer's own history with this pack, decided and worded by
  /// `purchase_overlay_map()`. Absent (`has:false`) for an anonymous visitor and
  /// for anyone with no order of it, which is how the same card serves both:
  /// the content is public, the history is not.
  final PurchaseOverlay purchase;

  /// CHANGE #673 — the backend's own offer chip, e.g. "Scheme available".
  /// [hasOffer] is the backend's boolean; the card NEVER infers an offer from
  /// the presence of a string, and never invents a "5+1" of its own.
  final bool hasOffer;
  final String offerChip;

  /// CHANGE #461/#170 — the prescription class, straight from `rx_badge()` in
  /// the payload: `{has, is_rx, label, title, note, tone}`. The app never
  /// decides what "Rx" means, never maps a schedule to a colour and never
  /// falls back to a locally-invented 'OTC' — an absent block renders nothing.
  final Map<String, dynamic>? rx;

  /// True only when the backend actually sent a class. Absence is absence.
  bool get hasRxBadge => rx?['has'] == true;
  bool get isRx => rx?['is_rx'] == true;
  String get rxLabel => (rx?['label'] ?? '').toString();
  String get rxTitle => (rx?['title'] ?? '').toString();
  String get rxNote => (rx?['note'] ?? '').toString();
  Map<String, dynamic>? get rxTone => (rx?['tone'] as Map?)?.cast<String, dynamic>();

  const Product({
    this.rx,
    required this.id,
    required this.name,
    required this.genericName,
    required this.manufacturer,
    required this.category,
    required this.therapeuticClass,
    required this.imageUrl,
    this.imageUrls = const [],
    required this.packSize,
    this.formChip = '',
    this.packTypeLabel = '',
    this.packQtyLabel = '',
    required this.mrp,
    required this.b2bPrice,
    required this.moq,
    required this.stock,
    this.buyable,
    required this.schedule,
    required this.requiresPrescription,
    required this.discount,
    this.gstPercent = 12,
    this.scheme = '',
    this.supplierLabel,
    this.supplierCount,
    this.availability,
    this.pricing,
    this.mrpText = '',
    this.hasOffer = false,
    this.offerChip = '',
    this.purchase = const PurchaseOverlay.absent(),
  });

  /// Returns a copy carrying [availability] — used to graft a cart line's
  /// backend verdict (from `cart_availability`) onto the stored product.
  Product withAvailability(Availability? a) => Product(
        id: id,
        name: name,
        genericName: genericName,
        manufacturer: manufacturer,
        category: category,
        therapeuticClass: therapeuticClass,
        imageUrl: imageUrl,
        imageUrls: imageUrls,
        packSize: packSize,
        formChip: formChip,
        packTypeLabel: packTypeLabel,
        packQtyLabel: packQtyLabel,
        mrp: mrp,
        b2bPrice: b2bPrice,
        gstPercent: gstPercent,
        moq: moq,
        stock: stock,
        buyable: buyable,
        schedule: schedule,
        requiresPrescription: requiresPrescription,
        discount: discount,
        scheme: scheme,
        supplierLabel: supplierLabel,
        supplierCount: supplierCount,
        availability: a,
        pricing: pricing,
        mrpText: mrpText,
        hasOffer: hasOffer,
        offerChip: offerChip,
        rx: rx,
      );

  /// CHANGE #287 — read one backend label, honouring the difference between a
  /// key that is ABSENT and one that is EMPTY.
  ///
  /// Absent = this payload predates the label (the offline cache written by an
  /// older build, and the outage fallbacks that return raw MEDICINE rows): fall
  /// back to the field the card used before, so a cached grid is never blank.
  /// Empty = the backend looked and the catalogue has no such string: print
  /// nothing. Inventing one here is the app deciding wording.
  static String _packLabel(
          Map<String, dynamic> map, String key, String fallback) =>
      map.containsKey(key)
          ? ((map[key] as String?) ?? '').trim()
          : fallback;

  /// CHANGE #637 — one card from `storefront_home_v2()`.
  ///
  /// The home feed sends an already-narrowed card, NOT a raw MEDICINE row, so
  /// the keys differ from [Product.fromMap]: `name`/`company`/`image`/
  /// `pack_label`/`form_chip` rather than `product_name`/`marketer`/
  /// `image_url_1`/`pack_size`/`pack_type`. This factory exists so
  /// [CompactProductCard] can be reused verbatim instead of forked — it is a
  /// field mapping and nothing else.
  ///
  /// The two blocks the card actually renders — `availability` and `pricing` —
  /// are the same ones `storefront_page()` sends, parsed by the same parsers,
  /// so a home rail and the category grid can never disagree about a product.
  ///
  /// Fields the card never reads (composition, category, schedule, stock) are
  /// filled with empty values rather than invented: the home payload does not
  /// carry them, and guessing them here would be the app deciding.
  factory Product.fromHomeCard(Map<String, dynamic> map) {
    final pricing = Pricing.fromMap(map['pricing']);
    final packLabel = (map['pack_label'] as String?) ?? '';
    final formChip = (map['form_chip'] as String?)?.trim() ?? '';
    return Product(
      id: map['id']?.toString() ?? '',
      name: (map['name'] as String?) ?? '',
      genericName: '',
      manufacturer: (map['company'] as String?) ?? '',
      category: 'Other',
      therapeuticClass: '',
      imageUrl: (map['image'] as String?)?.trim() ?? '',
      packSize: packLabel,
      formChip: formChip,
      packTypeLabel: _packLabel(map, 'pack_type_label', formChip),
      packQtyLabel: _packLabel(map, 'pack_qty_label', packLabel),
      mrp: pricing?.mrp ?? 0,
      b2bPrice: pricing?.salePrice ?? 0,
      moq: 1,
      stock: 0,
      buyable: map['buyable'] as bool?,
      // #461/#170: the class the BACKEND sent, not a hardcoded 'OTC'.
      schedule: ((map['rx'] as Map?)?['label'] ?? '').toString(),
      requiresPrescription: (map['rx'] as Map?)?['is_rx'] == true,
      discount: 0.0,
      availability: Availability.fromMap(map['availability']),
      pricing: pricing,
      mrpText: (map['mrp_label'] ?? '').toString(),
      hasOffer: map['has_offer'] == true,
      offerChip: (map['offer_chip'] ?? '').toString(),
      rx: (map['rx'] as Map?)?.cast<String, dynamic>(),
      // CMD #791 — present on the catalogue grid's rows (storefront_page
      // resolves the whole page's overlays in ONE scan of order_items) and
      // absent everywhere else, which parses to PurchaseOverlay.absent().
      purchase: PurchaseOverlay.fromMap(map['purchase']),
    );
  }

  /// Builds a [Product] from a `MEDICINE` row returned by Supabase.
  factory Product.fromMap(Map<String, dynamic> map) {
    // MRP is stored as text "₹59.06" — strip symbol/commas then parse.
    double parseMrp(Object? v) {
      if (v == null) return 0;
      final s = v.toString().replaceAll(RegExp(r'[₹,\s]'), '');
      return double.tryParse(s) ?? 0;
    }

    final tClass = (map['therapeutic_class'] as String?)?.trim() ?? '';
    final rxRequired = (map['rx_required'] as String?)?.trim() ?? '';
    final isPrescription = rxRequired == 'Rx';
    final status = (map['status'] as String?)?.trim() ?? '';
    final mrp = parseMrp(map['mrp']);
    final b2bPrice = mrp;

    final allImages = [
      (map['image_url_1'] as String?)?.trim() ?? '',
      (map['image_url_2'] as String?)?.trim() ?? '',
      (map['image_url_3'] as String?)?.trim() ?? '',
      (map['image_url_4'] as String?)?.trim() ?? '',
      (map['image_url_5'] as String?)?.trim() ?? '',
    ].where((u) => u.isNotEmpty).toList(growable: false);

    return Product(
      id: map['id'].toString(),
      name: (map['product_name'] as String?) ?? 'Unnamed',
      genericName: (map['salt_composition'] as String?) ?? '',
      manufacturer: (map['marketer'] as String?) ?? '',
      category: tClass.isNotEmpty ? tClass : 'Other',
      therapeuticClass: tClass,
      imageUrl: allImages.isNotEmpty ? allImages[0] : '',
      imageUrls: allImages,
      // Legacy chain, kept for the outage fallbacks that return a raw
      // MEDICINE row: pack_qty preferred, then pack_size, then pack_type.
      // CHANGE #287 — every storefront RPC now sends the two decided labels
      // below, and the card reads only those.
      packSize: (map['pack_qty'] as String?)?.isNotEmpty == true
          ? map['pack_qty'] as String
          : (map['pack_size'] as String?)?.isNotEmpty == true
              ? map['pack_size'] as String
              : (map['pack_type'] as String?) ?? '',
      formChip: (map['pack_type'] as String?)?.trim() ?? '',
      packTypeLabel: _packLabel(
          map, 'pack_type_label', (map['pack_type'] as String?)?.trim() ?? ''),
      packQtyLabel: _packLabel(
          map, 'pack_qty_label', (map['pack_qty'] as String?)?.trim() ?? ''),
      mrp: mrp,
      b2bPrice: b2bPrice,
      gstPercent: (map['gst_percent'] as num?)?.toDouble() ?? 12.0,
      moq: 1,
      // Stock flag kept for legacy compat; buyability now uses isBuyable getter.
      stock: mrp > 0 ? 100 : 0,
      buyable: map['buyable'] as bool?,
      schedule: isPrescription ? 'Schedule H' : 'OTC',
      requiresPrescription: isPrescription,
      discount: 0.0,
      scheme: (map['scheme'] as String?)?.trim() ?? '',
      supplierLabel: (map['supplier_label'] as String?)?.trim().isNotEmpty == true
          ? (map['supplier_label'] as String).trim()
          : null,
      supplierCount: (map['supplier_count'] as num?)?.toInt(),
      // CHANGE #553 — present on every storefront RPC row, absent elsewhere.
      availability: Availability.fromMap(map['availability']),
      pricing: Pricing.fromMap(map['pricing']),
      mrpText: (map['mrp_display'] ?? '').toString(),
      hasOffer: map['has_offer'] == true,
      offerChip: (map['offer_chip'] ?? '').toString(),
      rx: (map['rx'] as Map?)?.cast<String, dynamic>(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'genericName': genericName,
        'manufacturer': manufacturer,
        'category': category,
        'therapeuticClass': therapeuticClass,
        'imageUrl': imageUrl,
        'imageUrls': imageUrls,
        'packSize': packSize,
        'formChip': formChip,
        'packTypeLabel': packTypeLabel,
        'packQtyLabel': packQtyLabel,
        'mrp': mrp,
        'b2bPrice': b2bPrice,
        'gstPercent': gstPercent,
        'moq': moq,
        'stock': stock,
        'buyable': buyable,
        'schedule': schedule,
        'requiresPrescription': requiresPrescription,
        'discount': discount,
        'scheme': scheme,
        'supplierLabel': supplierLabel,
        'supplierCount': supplierCount,
        'availability': availability?.toJson(),
        'pricing': pricing?.toJson(),
        'rx': rx,
      };

  factory Product.fromJson(Map<String, dynamic> map) {
    return Product(
      id: (map['id'] as String?) ?? '',
      name: (map['name'] as String?) ?? '',
      genericName: (map['genericName'] as String?) ?? '',
      manufacturer: (map['manufacturer'] as String?) ?? '',
      category: (map['category'] as String?) ?? 'Other',
      therapeuticClass: (map['therapeuticClass'] as String?) ?? '',
      imageUrl: (map['imageUrl'] as String?) ?? '',
      imageUrls: (map['imageUrls'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      packSize: (map['packSize'] as String?) ?? '',
      formChip: (map['formChip'] as String?) ?? '',
      packTypeLabel: _packLabel(
          map, 'packTypeLabel', (map['formChip'] as String?) ?? ''),
      packQtyLabel: _packLabel(
          map, 'packQtyLabel', (map['packSize'] as String?) ?? ''),
      mrp: (map['mrp'] as num?)?.toDouble() ?? 0.0,
      b2bPrice: (map['b2bPrice'] as num?)?.toDouble() ?? 0.0,
      gstPercent: (map['gstPercent'] as num?)?.toDouble() ?? 12.0,
      moq: (map['moq'] as int?) ?? 1,
      stock: (map['stock'] as int?) ?? 0,
      buyable: map['buyable'] as bool?,
      schedule: (map['schedule'] as String?) ?? 'OTC',
      requiresPrescription: (map['requiresPrescription'] as bool?) ?? false,
      discount: (map['discount'] as num?)?.toDouble() ?? 0.0,
      scheme: (map['scheme'] as String?) ?? '',
      supplierLabel: map['supplierLabel'] as String?,
      supplierCount: (map['supplierCount'] as num?)?.toInt(),
      availability: Availability.fromMap(map['availability']),
      pricing: Pricing.fromMap(map['pricing']),
      mrpText: (map['mrp_display'] ?? '').toString(),
    );
  }

  /// Builds a [Product] from a `bulk_match_items` RPC response item.
  /// Fields: id, product_name, company, pack_type, pack_size, mrp, buyable, category, image_url, gst_percent.
  factory Product.fromBulkMatch(Map<String, dynamic> m) {
    final mrp = (m['mrp'] as num?)?.toDouble() ?? 0.0;
    final packSize = (m['pack_size'] as String?)?.trim() ?? '';
    final packType = (m['pack_type'] as String?)?.trim() ?? '';
    final imageUrl = (m['image_url'] as String?)?.trim() ?? '';
    final cat = (m['category'] as String?)?.trim() ?? '';
    return Product(
      id: m['id']?.toString() ?? '',
      name: (m['product_name'] as String?) ?? 'Unnamed',
      genericName: '',
      manufacturer: (m['company'] as String?) ?? '',
      category: cat.isNotEmpty ? cat : 'Other',
      therapeuticClass: cat,
      imageUrl: imageUrl,
      imageUrls: imageUrl.isNotEmpty ? [imageUrl] : [],
      packSize: packSize.isNotEmpty ? packSize : packType,
      formChip: packType,
      mrp: mrp,
      b2bPrice: mrp,
      gstPercent: (m['gst_percent'] as num?)?.toDouble() ?? 12.0,
      moq: 1,
      stock: mrp > 0 ? 100 : 0,
      buyable: m['buyable'] as bool?,
      // #461/#170: the class the BACKEND sent, not a hardcoded 'OTC'.
      schedule: ((m['rx'] as Map?)?['label'] ?? '').toString(),
      requiresPrescription: (m['rx'] as Map?)?['is_rx'] == true,
      rx: (m['rx'] as Map?)?.cast<String, dynamic>(),
      discount: 0.0,
    );
  }

  /// Reconstructs a minimal Product from cart row data (Supabase or localStorage).
  factory Product.fromCartData({
    required String id,
    required String name,
    required double b2bPrice,
    required double mrp,
    String imageUrl = '',
    String manufacturer = '',
    String packSize = '',
    String category = 'Other',
    double gstPercent = 12.0,
    bool? buyable,
  }) {
    return Product(
      id: id,
      name: name,
      genericName: '',
      manufacturer: manufacturer,
      category: category.isNotEmpty ? category : 'Other',
      therapeuticClass: category,
      imageUrl: imageUrl,
      imageUrls: imageUrl.isNotEmpty ? [imageUrl] : [],
      packSize: packSize,
      mrp: mrp,
      b2bPrice: b2bPrice,
      gstPercent: gstPercent,
      moq: 1,
      stock: 100,
      buyable: buyable,
      // fromCartData has no payload to read a class from: absence, not 'OTC'.
      schedule: '',
      requiresPrescription: false,
      discount: 0.0,
    );
  }

  /// Margin the buyer earns reselling at MRP, as a percentage.
  double get marginPercent => mrp <= 0 ? 0 : ((mrp - b2bPrice) / mrp) * 100;

  bool get inStock => stock > 0;

  /// True when the product has a price — legacy check still used for MRP display.
  bool get hasMrp => mrp > 0;

  /// CHANGE #597 — the backend's formatted MRP for this row ('' when the
  /// catalogue has none). Every medicine payload carries it, so no widget
  /// calls rupees() on a raw number.
  final String mrpText;

  /// #102: True only when buyable==true (at least one PS supplier).
  /// null (during backfill) is treated as false (unavailable) for safety.
  bool get isBuyable => buyable == true;
}


/// CMD #791 — "Last ordered 12 Aug · 3× last month · usual qty 9".
///
/// Every part of that sentence is `purchase_overlay_map()`'s: the date is
/// formatted in Postgres, the "×" count is counted there, the plural is decided
/// there and the whole line is joined there. This class parses; it formats
/// nothing. [chips] is the same content pre-split so a wide surface can show
/// three pills and a narrow one can show [label]; the app picks the layout, not
/// the words.
///
/// [has] is the backend's answer to "does this viewer have history here", and
/// it is false for an anonymous visitor by construction — the RPC returns an
/// empty map the moment `my_customer_id()` is null. There is no client-side
/// "am I logged in" branch anywhere near this.
class PurchaseOverlay {
  final bool has;
  final String title;
  final String label;
  final List<String> chips;

  /// The one-pill form for a catalogue card, where the full sentence does not
  /// fit: "Ordered 12 Aug".
  final String shortLabel;
  final String lastLabel;

  /// The quantity this pharmacy usually buys — the MODE of its past orders,
  /// decided server-side. [canAdd] is the backend's flag, never `usualQty > 0`
  /// re-derived here.
  final int usualQty;
  final bool canAdd;
  final String addLabel;

  /// `{bg, fg}` hex pair from the payload. The card resolves it through
  /// `Ds.hex(...)` with a token fallback, so a missing tone degrades to the
  /// theme rather than to a colour typed in Dart.
  final Map<String, dynamic> tone;

  const PurchaseOverlay({
    required this.has,
    required this.title,
    required this.label,
    required this.chips,
    required this.shortLabel,
    required this.lastLabel,
    required this.usualQty,
    required this.canAdd,
    required this.addLabel,
    required this.tone,
  });

  const PurchaseOverlay.absent()
      : has = false,
        title = '',
        label = '',
        chips = const [],
        shortLabel = '',
        lastLabel = '',
        usualQty = 0,
        canAdd = false,
        addLabel = '',
        tone = const {};

  factory PurchaseOverlay.fromMap(Object? raw) {
    if (raw is! Map) return const PurchaseOverlay.absent();
    if (raw['has'] != true) return const PurchaseOverlay.absent();
    final m = raw.cast<String, dynamic>();
    return PurchaseOverlay(
      has: true,
      title: (m['title'] ?? '').toString(),
      label: (m['label'] ?? '').toString(),
      chips: ((m['chips'] as List?) ?? const [])
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList(growable: false),
      shortLabel: (m['short_label'] ?? '').toString(),
      lastLabel: (m['last_label'] ?? '').toString(),
      usualQty: (m['usual_qty'] is num)
          ? (m['usual_qty'] as num).toInt()
          : int.tryParse((m['usual_qty'] ?? '').toString()) ?? 0,
      canAdd: m['can_add'] == true,
      addLabel: (m['add_label'] ?? '').toString(),
      tone: (m['tone'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }
}
