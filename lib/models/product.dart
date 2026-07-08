// Domain models for the B2B pharmacy ordering platform.

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
  });

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
