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
  final bool noteRequired;
  const DisputeAction({required this.code, required this.label, this.noteRequired = false});

  factory DisputeAction.fromJson(Map<String, dynamic> j) => DisputeAction(
        code: (j['code'] ?? '').toString(),
        label: (j['label'] ?? '').toString(),
        noteRequired: j['note_required'] == true,
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

// Backend-owned (fw_get_disputes' return_note_chip): null when there's no
// return note; otherwise the exact label/colour/action-visibility to render.
// label_card is for the dispute card, label_sheet for the action sheet — the
// wording differs per-surface but is backend text either way, not composed here.
class DisputeReturnNoteChip {
  final bool isOpen;
  final String labelCard;
  final String labelSheet;
  final String bg;
  final String fg;
  final bool showCollectedAction;

  const DisputeReturnNoteChip({
    required this.isOpen,
    required this.labelCard,
    required this.labelSheet,
    required this.bg,
    required this.fg,
    required this.showCollectedAction,
  });

  static DisputeReturnNoteChip? fromJson(dynamic j) {
    if (j is! Map) return null;
    return DisputeReturnNoteChip(
      isOpen: j['is_open'] == true,
      labelCard: j['label_card']?.toString() ?? '',
      labelSheet: j['label_sheet']?.toString() ?? '',
      bg: j['bg']?.toString() ?? '',
      fg: j['fg']?.toString() ?? '',
      showCollectedAction: j['show_collected_action'] == true,
    );
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
  final String? disputeCode;
  // v1 new fields (#347–349)
  final num? disputeQty;
  final String? returnNoteStatus; // 'open'|'collected'|null
  final bool nudgePending;
  final String? lastReminderAt;
  // C354: monetary adjustment applied by the resolution (credit/debit), payload-driven.
  final num? adjAmount;
  // Backend-owned (fw_get_disputes): friendly kind text + its tag colour.
  final String kindLabel;
  final Map<String, String>? kindColors; // {bg, fg}
  // Backend-owned: null when there's no return note, else the full chip payload.
  final DisputeReturnNoteChip? returnNoteChip;

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
    this.disputeCode,
    this.disputeQty,
    this.returnNoteStatus,
    this.nudgePending = false,
    this.lastReminderAt,
    this.adjAmount,
    this.kindLabel = '',
    this.kindColors,
    this.returnNoteChip,
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
      disputeCode: j['dispute_code']?.toString(),
      disputeQty: j['dispute_qty'] != null ? _n(j['dispute_qty']) : null,
      returnNoteStatus: j['return_note_status']?.toString(),
      nudgePending: j['nudge_pending'] == true,
      lastReminderAt: j['last_reminder_at']?.toString(),
      adjAmount: j['adj_amount'] != null ? _n(j['adj_amount']) : null,
      kindLabel: j['kind_label']?.toString() ?? '',
      kindColors: j['kind_colors'] is Map
          ? {
              'bg': (j['kind_colors'] as Map)['bg']?.toString() ?? '',
              'fg': (j['kind_colors'] as Map)['fg']?.toString() ?? '',
            }
          : null,
      returnNoteChip: DisputeReturnNoteChip.fromJson(j['return_note_chip']),
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

// ── C362 point-7/8: ITEM-WISE dispute aggregation ─────────────────────────────
// Multiple order-lines of the SAME product for the SAME supplier (different customers)
// collapse into ONE row: disputed qty summed; the group is Active if ANY line is active.
// Shared by the admin Disputes tab, the supplier portal, and the token page so all three
// render one row per product with the total disputed qty (no per-line duplication).

class AggregatedDispute {
  final String supplier;
  final String productName;
  final String kind;
  final num disputedQty; // Σ short_qty (dispute_qty) across the group's lines
  final num orderedQty; // Σ ordered
  final num receivedQty; // Σ received
  final bool active; // true if ANY underlying line is active
  final String itemStatusLabel;
  final String? wrongProductName;
  final String? proofUrl;
  final List<DisputeItem> lines; // underlying per-line disputes (for action fan-out)
  final DisputeItem representative; // drives kind label + action buttons (prefers active)

  const AggregatedDispute({
    required this.supplier,
    required this.productName,
    required this.kind,
    required this.disputedQty,
    required this.orderedQty,
    required this.receivedQty,
    required this.active,
    required this.itemStatusLabel,
    this.wrongProductName,
    this.proofUrl,
    required this.lines,
    required this.representative,
  });

  List<DisputeAction> get actions => representative.actions;
  String get disputeId => representative.disputeId;
  String? get token => representative.token;
  String? get response => representative.response;
  String? get resolutionOutcome => representative.resolutionOutcome;

  /// C362: the ACTIVE underlying dispute ids — an action on the aggregated row fans out to
  /// each ACTIVE line only. Never re-touch a settled/inactive line: the special 'close'
  /// outcome skips the backend allow-list check and would clobber a closed line's
  /// resolution record (resolution_outcome/resolved_at). The representative is always an
  /// active line when any line is active, so its own id is included here.
  List<String> get allActiveDisputeIds => lines
      .where((d) => d.isActive)
      .map((d) => d.disputeId)
      .where((id) => id.isNotEmpty)
      .toList();
}

/// Collapse per-line disputes into ONE row per (supplier, product). Disputed qty is
/// summed; the representative (kind label + actions) prefers an ACTIVE line so the row
/// keeps live actions while any line is unresolved.
List<AggregatedDispute> aggregateDisputesByProduct(List<DisputeItem> items) {
  final groups = <String, List<DisputeItem>>{};
  final order = <String>[];
  for (final d in items) {
    final key = '${d.supplier}${d.kind}${d.productName.toLowerCase().trim()}';
    if (!groups.containsKey(key)) order.add(key);
    groups.putIfAbsent(key, () => []).add(d);
  }
  final out = <AggregatedDispute>[];
  for (final key in order) {
    final lines = groups[key]!;
    final active = lines.any((d) => d.isActive);
    final rep = lines.firstWhere((d) => d.isActive, orElse: () => lines.first);
    num disputed = 0, ordered = 0, received = 0;
    for (final d in lines) {
      disputed += (d.disputeQty ?? d.short);
      ordered += d.ordered;
      received += d.received;
    }
    out.add(AggregatedDispute(
      supplier: rep.supplier,
      productName: rep.productName,
      kind: rep.kind,
      disputedQty: disputed,
      orderedQty: ordered,
      receivedQty: received,
      active: active,
      itemStatusLabel: rep.itemStatusLabel,
      wrongProductName: rep.wrongProductName,
      proofUrl: rep.proofUrl,
      lines: lines,
      representative: rep,
    ));
  }
  return out;
}

/// Group aggregated rows by supplier (per-supplier header + dispute link).
Map<String, List<AggregatedDispute>> groupAggregatedBySupplier(
    List<AggregatedDispute> rows) {
  final map = <String, List<AggregatedDispute>>{};
  final order = <String>[];
  for (final r in rows) {
    if (!map.containsKey(r.supplier)) order.add(r.supplier);
    map.putIfAbsent(r.supplier, () => []).add(r);
  }
  return {for (final s in order) s: map[s]!};
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

/// Admin close a return note (fw_close_return_note).
Future<Map<String, dynamic>> closeReturnNoteRpc({
  required String disputeId,
}) async {
  final res = await Supabase.instance.client.rpc(
    'fw_close_return_note',
    params: {'p_dispute_id': disputeId},
  ) as Map;
  final err = res['error']?.toString();
  if (err != null) throw DisputeException(err);
  return Map<String, dynamic>.from(res);
}
