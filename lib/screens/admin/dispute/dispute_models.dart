// Canonical dispute data layer — shared by admin (#188), supplier (#189), and
// public link (#190) surfaces. Parses the union of fw_get_disputes,
// supplier_my_disputes, and get_dispute_form response shapes.

import 'package:supabase_flutter/supabase_flutter.dart';

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
  final String? proofUrl;

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
    this.proofUrl,
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
      proofUrl: j['proof_url']?.toString(),
    );
  }

  /// True when the dispute is awaiting the supplier's Yes/No response.
  /// Use this to suppress "Awaiting supplier response" on supplier-facing surfaces.
  bool get isAwaitingSupplier =>
      statusCode == 'reminder_sent' || statusCode == 'shop_logged';

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

// ── Supplier disputes result wrapper (#189) ───────────────────────────────────

class SupplierDisputesResult {
  final String supplier;
  final bool acting;
  final List<DisputeItem> items;
  const SupplierDisputesResult({
    required this.supplier,
    required this.acting,
    required this.items,
  });
}

// ── Service functions (#189) — shared across screens ─────────────────────────

/// Fetch admin dispute list (fw_get_disputes).
Future<List<DisputeItem>> fetchAdminDisputesList() async {
  final res = await Supabase.instance.client.rpc('fw_get_disputes') as Map;
  return DisputeItem.listFromResponse(res);
}

/// Build a map from orderItemId -> DisputeItem for quick line-level badge lookup.
Future<Map<String, DisputeItem>> fetchAdminDisputeIndexByOrderItem() async {
  final items = await fetchAdminDisputesList();
  final map = <String, DisputeItem>{};
  for (final item in items) {
    if (item.orderItemId.isNotEmpty) {
      map[item.orderItemId] = item;
    }
  }
  return map;
}

/// Fetch supplier's own disputes (supplier_my_disputes).
/// Pass actingSupplier non-null when an admin is acting-as a supplier.
Future<SupplierDisputesResult> fetchSupplierDisputesList({
  String? actingSupplier,
}) async {
  final params = <String, dynamic>{
    'p_acting_supplier': actingSupplier,
  };
  final res = await Supabase.instance.client
      .rpc('supplier_my_disputes', params: params) as Map;
  final err = res['error']?.toString();
  if (err != null) throw DisputeException(err);
  final rawList = res['disputes'];
  final items = (rawList is List)
      ? rawList
          .whereType<Map>()
          .map((e) => DisputeItem.fromJson(Map<String, dynamic>.from(e)))
          .toList()
      : <DisputeItem>[];
  return SupplierDisputesResult(
    supplier: (res['supplier'] ?? '').toString(),
    acting: res['acting'] == true,
    items: items,
  );
}

/// Supplier response to a dispute (supplier_respond_dispute).
Future<Map<String, dynamic>> supplierRespondDisputeRpc({
  required String disputeId,
  required String response,
  String? actingSupplier,
}) async {
  final res = await Supabase.instance.client.rpc(
    'supplier_respond_dispute',
    params: {
      'p_dispute_id': disputeId,
      'p_response': response,
      'p_acting_supplier': actingSupplier,
    },
  );
  final data = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
  final err = data['error']?.toString();
  if (err != null) throw DisputeException(err);
  return data;
}

/// Fetch the public dispute-link form (get_dispute_form) — no auth required.
Future<({String supplierName, List<DisputeItem> items})> fetchDisputeForm(
    String token) async {
  final res = await Supabase.instance.client
      .rpc('get_dispute_form', params: {'p_token': token}) as Map;
  final err = res['error']?.toString();
  if (err != null) throw DisputeException(err);
  final rawList = res['items'];
  final items = (rawList is List)
      ? rawList
          .whereType<Map>()
          .map((e) => DisputeItem.fromJson(Map<String, dynamic>.from(e)))
          .toList()
      : <DisputeItem>[];
  return (supplierName: (res['supplier_name'] ?? '').toString(), items: items);
}

/// Submit a supplier response via the public dispute link (submit_dispute_response).
Future<Map<String, dynamic>> submitDisputeResponse({
  required String token,
  required String disputeId,
  required String response,
}) async {
  final res = await Supabase.instance.client.rpc(
    'submit_dispute_response',
    params: {
      'p_token': token,
      'p_dispute_id': disputeId,
      'p_response': response,
    },
  );
  final data = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
  final err = data['error']?.toString();
  if (err != null) throw DisputeException(err);
  return data;
}

/// Admin resolve a dispute (fw_resolve_dispute).
Future<Map<String, dynamic>> resolveAdminDisputeRpc({
  required String disputeId,
  required String outcome,
  String? note,
}) async {
  final res = await Supabase.instance.client.rpc(
    'fw_resolve_dispute',
    params: {
      'p_dispute_id': disputeId,
      'p_outcome': outcome,
      'p_note': note,
    },
  ) as Map;
  final err = res['error']?.toString();
  if (err != null) throw DisputeException(err);
  return Map<String, dynamic>.from(res);
}
