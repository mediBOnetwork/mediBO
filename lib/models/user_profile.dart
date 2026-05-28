class UserProfile {
  final String id; // = auth.users.id
  final String fullName;
  final String businessName;
  final String phone;
  final String gstin;
  final String drugLicense;
  final String addressLine;
  final String city;
  final String pincode;

  const UserProfile({
    required this.id,
    required this.fullName,
    required this.businessName,
    required this.phone,
    this.gstin = '',
    this.drugLicense = '',
    required this.addressLine,
    required this.city,
    required this.pincode,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        id: json['id'] as String? ?? '',
        fullName: json['full_name'] as String? ?? '',
        businessName: json['business_name'] as String? ?? '',
        phone: json['phone'] as String? ?? '',
        gstin: json['gstin'] as String? ?? '',
        drugLicense: json['drug_license'] as String? ?? '',
        addressLine: json['address_line'] as String? ?? '',
        city: json['city'] as String? ?? '',
        pincode: json['pincode'] as String? ?? '',
      );

  Map<String, dynamic> toInsertJson() => {
        'id': id,
        'full_name': fullName,
        'business_name': businessName,
        'phone': phone,
        if (gstin.isNotEmpty) 'gstin': gstin,
        if (drugLicense.isNotEmpty) 'drug_license': drugLicense,
        'address_line': addressLine,
        'city': city,
        'pincode': pincode,
      };

  String get displayName =>
      businessName.isNotEmpty ? businessName : fullName;
}
