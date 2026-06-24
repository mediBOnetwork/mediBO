// Canonical dispute data layer — shared by admin (#188), supplier (#189), and
// public link (#190) surfaces. Parses the union of fw_get_disputes,
// supplier_my_disputes, and get_dispute_form response shapes.

num _n(dynamic v) =>
    v == null ? 0 : (v is num ? v : num.tryParse(v.toString()) ?? 0);

class DisputeException implements Exception {
  final String message;
  const DisputeException(this.message);
  @override
  String toString() => 'DisputeException: $message';
}

class DisputeAction {
  final String code;
  final String label;
  const DisputeAction({required this.code, required this.label});

  factory DisputeAction.fromJson(Map<String, dynamic> j) => DisputeAction(
        code: (j['code'] ?? '').toString(),
        label: (j['label'] ?? '').toString(),
      );

  static List<DisputeAction> listFrom(dynamic v) {
    if (v is! List) return const [];
    return v
        .whereType<Map>()
        .map((e) => DisputeAction.fromJson(Map<String, dynamic>.from(e)))
        .where((a) => a.code.isNotEmpty)
        .toList();
  }
}

class DisputeItem {
  final String disputeId;
  final String orderItemId;
  final String productName;
  final String? wrongProductName;
  final String supplier;
  final String mode;
  final String kind;
  final num ordered;
  final num received;
  final num short;
  final String statusCode;
  final String itemStatusLabel;
  final String disputeStatus;
  final bool isActive;
  final List<DisputeAction> actions;
  final List<DisputeAction> adminActions;
  final String? response;
  final bool unfillable;
  final bool rebuyStarted;
  final String? token;
  final String? packType;
  final String? category;
  final String? company;
  final String? imageUrl;
  final String? resolutionOutcome;
  final String? resolutionNote;
  final String? createdAt;
  final String? respondedAt;
  final String? resolvedAt;

  const DisputeItem({
    required this.disputeId,
    required this.orderItemId,
    required this.productName,
    this.wrongProductName,
    required this.supplier,
    required this.mode,
    required this.kind,
    required this.ordered,
    required this.received,
    required this.short,
    required this.statusCode,
    required this.itemStatusLabel,
    required this.disputeStatus,
    required this.isActive,
    required this.actions,
    required this.adminActions,
    this.response,
    required this.unfillable,
    required this.rebuyStarted,
    this.token,
    this.packType,
    this.category,
    this.company,
    this.imageUrl,
    this.resolutionOutcome,
    this.resolutionNote,
    this.createdAt,
    this.respondedAt,
    this.resolvedAt,
  });

  factory DisputeItem.fromJson(Map<String, dynamic> j) {
    final statusCode = (j['status'] ?? '').toString();
    final rawDisputeStatus = (j['dispute_status'] ?? '').toString();
    final rawActive = j['active'];
    final isActive = rawActive is bool
        ? rawActive
        : rawDisputeStatus == 'active';
    final rawLabel = j['item_status_label'];
    final itemStatusLabel = (rawLabel != null && rawLabel.toString().isNotEmpty)
        ? rawLabel.toString()
        : statusCode;

    return DisputeItem(
      disputeId: (j['dispute_id'] ?? '').toString(),
      orderItemId: (j['order_item_id'] ?? '').toString(),
      productName: (j['product_name'] ?? '').toString(),
      wrongProductName: j['wrong_product_name']?.toString(),
      supplier: (j['supplier'] ?? '').toString(),
      mode: (j['mode'] ?? '').toString(),
      kind: (j['kind'] ?? 'short').toString(),
      ordered: _n(j['ordered']),
      received: _n(j['received']),
      short: _n(j['short']),
      statusCode: statusCode,
      itemStatusLabel: itemStatusLabel,
      disputeStatus: rawDisputeStatus,
      isActive: isActive,
      actions: DisputeAction.listFrom(j['actions']),
      adminActions: DisputeAction.listFrom(j['admin_actions']),
      response: (j['response'] ?? j['supplier_response'])?.toString(),
      unfillable: j['unfillable'] == true,
      rebuyStarted: j['rebuy_started'] == true,
      token: j['token']?.toString(),
      packType: j['pack_type']?.toString(),
      category: j['category']?.toString(),
      company: j['company']?.toString(),
      imageUrl: j['image_url']?.toString(),
      resolutionOutcome: j['resolution_outcome']?.toString(),
      resolutionNote: j['resolution_note']?.toString(),
      createdAt: j['created_at']?.toString(),
      respondedAt: j['responded_at']?.toString(),
      resolvedAt: j['resolved_at']?.toString(),
    );
  }

  static List<DisputeItem> listFromResponse(dynamic response) {
    if (response is! Map) return [];
    final err = response['error'];
    if (err != null) throw DisputeException(err.toString());
    final list = response['disputes'];
    if (list is! List) return [];
    return list
        .whereType<Map>()
        .map((e) => DisputeItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
}
