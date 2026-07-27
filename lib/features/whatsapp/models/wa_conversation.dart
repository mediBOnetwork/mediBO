
class WaConversation {
  final String senderPhone;
  final String senderType;
  final String? name;
  final String? label;
  final String? linkedSupplier;
  final int total;
  /// CHANGE #548: RAW backend timestamp, verbatim.
  final String? lastAt;
  final String lastText;
  final int unread;

  const WaConversation({
    required this.senderPhone,
    required this.senderType,
    this.name,
    this.label,
    this.linkedSupplier,
    required this.total,
    this.lastAt,
    required this.lastText,
    required this.unread,
  });

  /// Returns a copy with selected fields overridden (used for optimistic
  /// unread-badge clearing when a chat is opened).
  WaConversation copyWith({int? unread}) {
    return WaConversation(
      senderPhone: senderPhone,
      senderType: senderType,
      name: name,
      label: label,
      linkedSupplier: linkedSupplier,
      total: total,
      lastAt: lastAt,
      lastText: lastText,
      unread: unread ?? this.unread,
    );
  }

  factory WaConversation.fromJson(Map<String, dynamic> j) {
    return WaConversation(
      senderPhone: (j['sender_phone'] ?? '').toString(),
      senderType: (j['sender_type'] ?? 'unknown').toString(),
      name: j['name']?.toString(),
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

  static String? _asDate(dynamic v) {
    if (v == null) return null;
    final s = v.toString();
    return s.isEmpty ? null : s;
  }

  /// Resolved display name. Priority: resolved business/customer name >
  /// allowed-list label > prettified phone number.
  String get displayName {
    if (name != null && name!.trim().isNotEmpty) return name!.trim();
    if (label != null && label!.trim().isNotEmpty) return label!.trim();
    return _pretty(senderPhone);
  }

  /// True when a real name OR a label is available (so the tile/header should
  /// show the phone number as a secondary line).
  bool get hasName =>
      (name != null && name!.trim().isNotEmpty) ||
      (label != null && label!.trim().isNotEmpty);

  String get phonePretty => _pretty(senderPhone);

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
