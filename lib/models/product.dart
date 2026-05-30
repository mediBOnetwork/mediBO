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
      // pack_size is null in MEDICINE; pack_qty holds "10 tablets in 1 strip"
      packSize: (map['pack_qty'] as String?) ?? (map['pack_size'] as String?) ?? '',
      mrp: mrp,
      b2bPrice: b2bPrice,
      gstPercent: (map['gst_percent'] as num?)?.toDouble() ?? 12.0,
      moq: 1,
      stock: status == 'Available' ? 100 : 0,
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
      schedule: (map['schedule'] as String?) ?? 'OTC',
      requiresPrescription: (map['requiresPrescription'] as bool?) ?? false,
      discount: (map['discount'] as num?)?.toDouble() ?? 0.0,
      scheme: (map['scheme'] as String?) ?? '',
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
      schedule: 'OTC',
      requiresPrescription: false,
      discount: 0.0,
    );
  }

  /// Margin the buyer earns reselling at MRP, as a percentage.
  double get marginPercent => mrp <= 0 ? 0 : ((mrp - b2bPrice) / mrp) * 100;

  bool get inStock => stock > 0;
}
