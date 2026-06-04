class UserProfile {
  final String userId;
  final String customerName;
  final String pharmacyName;
  final String storeType;
  final String rangeZone;
  final String addressLocal;
  final String city;
  final String state;
  final String pincode;
  final String? storeLocationLink;
  final String whatsappNo;
  final String otherContactNo;
  final String email;
  final String dl20b;
  final String? dl21b;
  final String? gstNo;
  final String paymentTerm;
  final String customerCode;
  final bool approved;
  final String status;

  const UserProfile({
    required this.userId,
    required this.customerName,
    required this.pharmacyName,
    required this.storeType,
    required this.rangeZone,
    required this.addressLocal,
    required this.city,
    required this.state,
    required this.pincode,
    this.storeLocationLink,
    required this.whatsappNo,
    this.otherContactNo = '',
    required this.email,
    required this.dl20b,
    this.dl21b,
    this.gstNo,
    required this.paymentTerm,
    required this.customerCode,
    this.approved = false,
    this.status = 'pending',
  });

  bool get isApproved => approved;

  // Backward-compat getters used by existing screens
  String get ownerName => customerName;
  String get phone => whatsappNo;
  String get address => addressLocal;
  String get gstin => gstNo ?? '';
  String get drugLicense => dl20b;

  String get displayName =>
      pharmacyName.isNotEmpty ? pharmacyName : customerName;

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        userId: json['user_id'] as String? ?? '',
        customerName: json['customer_name'] as String? ??
            json['owner_name'] as String? ??
            '',
        pharmacyName: json['pharmacy_name'] as String? ?? '',
        storeType: json['store_type'] as String? ?? '',
        rangeZone: json['range_zone'] as String? ?? '',
        addressLocal: json['address_local'] as String? ??
            json['address'] as String? ??
            '',
        city: json['city'] as String? ?? '',
        state: json['state'] as String? ?? '',
        pincode: json['pincode'] as String? ?? '',
        storeLocationLink: json['store_location_link'] as String?,
        whatsappNo: json['whatsapp_no'] as String? ??
            json['phone'] as String? ??
            '',
        otherContactNo: json['other_contact_no'] as String? ?? '',
        email: json['email'] as String? ?? '',
        dl20b: json['dl_20b'] as String? ??
            json['drug_license'] as String? ??
            '',
        dl21b: json['dl_21b'] as String?,
        gstNo: json['gst_no'] as String? ?? json['gstin'] as String?,
        paymentTerm: json['payment_term'] as String? ?? '',
        customerCode: json['customer_code'] as String? ?? '',
        approved: json['approved'] as bool? ?? false,
        status: json['status'] as String? ?? 'pending',
      );

  // Deliberately excludes approved/status — only admin/service role can set these.
  Map<String, dynamic> toInsertJson() => {
        'user_id': userId,
        'customer_name': customerName,
        'pharmacy_name': pharmacyName,
        'store_type': storeType,
        'range_zone': rangeZone,
        'address': addressLocal,       // NOT NULL column — must always be populated
        'address_local': addressLocal,
        'city': city,
        'state': state,
        'pincode': pincode,
        if (storeLocationLink != null && storeLocationLink!.isNotEmpty)
          'store_location_link': storeLocationLink,
        'whatsapp_no': whatsappNo,
        if (otherContactNo.isNotEmpty) 'other_contact_no': otherContactNo,
        'email': email,
        'dl_20b': dl20b,
        if (dl21b != null && dl21b!.isNotEmpty) 'dl_21b': dl21b,
        if (gstNo != null && gstNo!.isNotEmpty) 'gst_no': gstNo,
        'payment_term': paymentTerm,
        'customer_code': customerCode,
      };
}
