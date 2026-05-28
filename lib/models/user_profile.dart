class UserProfile {
  final String userId;
  final String ownerName;
  final String pharmacyName;
  final String phone;
  final String gstin;
  final String drugLicense;
  final String address;
  final String city;
  final String pincode;

  const UserProfile({
    required this.userId,
    required this.ownerName,
    required this.pharmacyName,
    required this.phone,
    this.gstin = '',
    this.drugLicense = '',
    required this.address,
    required this.city,
    required this.pincode,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        userId: json['user_id'] as String? ?? '',
        ownerName: json['owner_name'] as String? ?? '',
        pharmacyName: json['pharmacy_name'] as String? ?? '',
        phone: json['phone'] as String? ?? '',
        gstin: json['gstin'] as String? ?? '',
        drugLicense: json['drug_license'] as String? ?? '',
        address: json['address'] as String? ?? '',
        city: json['city'] as String? ?? '',
        pincode: json['pincode'] as String? ?? '',
      );

  Map<String, dynamic> toInsertJson() => {
        'user_id': userId,
        'owner_name': ownerName,
        'pharmacy_name': pharmacyName,
        'phone': phone,
        if (gstin.isNotEmpty) 'gstin': gstin,
        if (drugLicense.isNotEmpty) 'drug_license': drugLicense,
        'address': address,
        'city': city,
        'pincode': pincode,
      };

  String get displayName =>
      pharmacyName.isNotEmpty ? pharmacyName : ownerName;
}
