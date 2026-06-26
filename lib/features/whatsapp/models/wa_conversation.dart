class WaConversation {
  final String senderPhone;
  final String senderType;
  final String? label;
  final String? linkedSupplier;
  final int total;
  final DateTime? lastAt;
  final String lastText;
  final int unread;

  const WaConversation({
    required this.senderPhone,
    required this.senderType,
    this.label,
    this.linkedSupplier,
    required this.total,
    this.lastAt,
    required this.lastText,
    required this.unread,
  });

  factory WaConversation.fromJson(Map<String, dynamic> j) {
    return WaConversation(
      senderPhone: (j['sender_phone'] ?? '').toString(),
      senderType: (j['sender_type'] ?? 'unknown').toString(),
      label: j['label']?.toString(),
      linkedSupplier: j['linked_supplier']?.toString(),
      total: _asInt(j['total']),
      lastAt: _asDate(j['last_at']),
      lastText: (j['last_text'] ?? '').toString(),
      unread: _asInt(j['unread']),
    );
  }

  static int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}') ?? 0;
  }

  static DateTime? _asDate(dynamic v) {
    if (v == null) return null;
    try {
      return DateTime.parse(v.toString()).toLocal();
    } catch (_) {
      return null;
    }
  }

  String get displayName {
    if (label != null && label!.trim().isNotEmpty) return label!;
    return _pretty(senderPhone);
  }

  static String _pretty(String phone) {
    try {
      if (phone.length == 12 && phone.startsWith('91')) {
        final digits = phone.substring(2);
        return '+91 ${digits.substring(0, 5)} ${digits.substring(5)}';
      }
    } catch (_) {}
    return phone;
  }

  bool get hasUnread => unread > 0;
}
