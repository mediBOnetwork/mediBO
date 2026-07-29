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

  /// e.g. "18% off". Empty when [hasDiscount] is false.
  final String discountLabel;
  final bool hasDiscount;

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
  });

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

  const Product({
    required this.id,
    required this.name,
    required this.genericName,
    required this.manufacturer,
    required this.category,
    required this.therapeuticClass,
    required this.imageUrl,
    this.imageUrls = const [],
    required this.packSize,
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
      );

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
      // pack_qty preferred; fall back to pack_size then pack_type (e.g. "Strip")
      packSize: (map['pack_qty'] as String?)?.isNotEmpty == true
          ? map['pack_qty'] as String
          : (map['pack_size'] as String?)?.isNotEmpty == true
              ? map['pack_size'] as String
              : (map['pack_type'] as String?) ?? '',
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
      mrp: mrp,
      b2bPrice: mrp,
      gstPercent: (m['gst_percent'] as num?)?.toDouble() ?? 12.0,
      moq: 1,
      stock: mrp > 0 ? 100 : 0,
      buyable: m['buyable'] as bool?,
      schedule: 'OTC',
      requiresPrescription: false,
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
      schedule: 'OTC',
      requiresPrescription: false,
      discount: 0.0,
    );
  }

  /// Margin the buyer earns reselling at MRP, as a percentage.
  double get marginPercent => mrp <= 0 ? 0 : ((mrp - b2bPrice) / mrp) * 100;

  bool get inStock => stock > 0;

  /// True when the product has a price — legacy check still used for MRP display.
  bool get hasMrp => mrp > 0;

  /// #102: True only when buyable==true (at least one PS supplier).
  /// null (during backfill) is treated as false (unavailable) for safety.
  bool get isBuyable => buyable == true;
}
