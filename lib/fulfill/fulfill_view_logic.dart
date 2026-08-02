// C355 — SHARED FULFILL VIEW LOGIC (single source of truth for BOTH layouts).
//
// The mobile card layout and the desktop/web table layout are kept visually
// DIFFERENT on purpose — but every chip text, status pill, quantity label and
// dispute indicator they show MUST come from here, never computed inline in a
// layout. Before #355 the qty label / pill state / issue chip / kind tag were
// derived in THREE places (single mobile tile, merged mobile tile, web table row)
// and had already drifted (web ignored `expected`, skipped terminal states, and
// never gated the dispute strip on isActive). Folding them here makes the two
// layouts agree by construction: fix a rule once → both layouts change together.
//
// PURE logic only — no widgets. Emits c355_shared so we can prove a layout used it.

import '../screens/admin/dispute/dispute_models.dart';
import '../utils/render_log.dart';

// ════════════════════════════════════════════════════════════════════════════
// CHANGE #471 — fw_get_state date scoping + backend-owned display strings.
// PURE logic only, so the RPC param shape and the render decisions (does the
// older-pill show, does the date chip show) are unit-testable without pumping
// the (huge, Supabase-backed) admin_fulfillment_screen widget tree.
// ════════════════════════════════════════════════════════════════════════════

/// The exact params map every fw_get_state call must send.
///
/// CHANGE #545 — p_date is now ALWAYS OMITTED, inverting #471. The date lives
/// server-side (admin_date_scope, set by the ONE Dashboard picker) and
/// fw_get_state defaults p_date to admin_active_date(), so omitting the key is
/// what makes the box follow the picker. The key must be ABSENT, never
/// present-with-null: an explicit null reads as "all dates".
///
/// p_include_older is likewise not sent: fw_get_state (like every other Fulfill
/// RPC) is strict single-date — the Dashboard picker is the only way to view
/// another date, and the RPC ignores this param anyway.
Map<String, dynamic> fwGetStateParams({
  required String supplierName,
  required String stage,
}) =>
    {
      'p_supplier_name': supplierName,
      'p_stage': stage,
    };

// ════════════════════════════════════════════════════════════════════════════
// CHANGE #635 — count_locked, verbatim.
// ════════════════════════════════════════════════════════════════════════════

/// Is counting locked for this fw_get_state item?
///
/// fw_get_state already answers this. It emits `count_locked` per item, resolved
/// server-side to the flag that actually governs the stage being viewed:
///
///   shop view      → collect_locked
///   warehouse view → received_locked
///
/// The client used to OR the two raw flags together instead. That is the app
/// deciding: on a supplier whose shop lines were locked but whose warehouse
/// lines were not, the OR locked entry on BOTH stages, because it could not tell
/// which flag applied to the screen the operator was looking at. The backend can
/// and does tell — read its answer.
///
/// The legacy OR survives only as a fallback for payloads that predate the field
/// (get_receiving_box still returns collect_locked alone). When `count_locked` is
/// present it always wins; the fallback is never consulted.
bool countLockedOf(Map<String, dynamic> item) {
  final v = item['count_locked'];
  if (v != null) return v == true;
  return item['collect_locked'] == true || item['received_locked'] == true;
}

/// CHANGE #635 — the four display values a fw_get_state / merged_items row owns.
///
/// Every field here is READ, never composed. There is deliberately no fallback
/// that invents text: an empty `qty_label` renders as empty, because the
/// alternative (falling back to qtyWithPack, or to "$counted/$ordered") is the
/// app answering "what do I show?" and is exactly how the two layouts drifted
/// apart before #355.
class ShopItemDisplay {
  final String qtyLabel;
  final String statusLabel;
  final String statusTone;
  final Map<String, String>? statusColors;
  final bool countLocked;

  const ShopItemDisplay({
    required this.qtyLabel,
    required this.statusLabel,
    required this.statusTone,
    required this.statusColors,
    required this.countLocked,
  });
}

ShopItemDisplay shopItemDisplayOf(Map<String, dynamic> m) {
  final colors = m['status_colors'];
  return ShopItemDisplay(
    qtyLabel: m['qty_label']?.toString() ?? '',
    statusLabel: m['status_label']?.toString() ?? '',
    statusTone: m['status_tone']?.toString() ?? '',
    statusColors: colors is Map
        ? {
            'bg': colors['bg']?.toString() ?? '',
            'fg': colors['fg']?.toString() ?? '',
          }
        : null,
    countLocked: countLockedOf(m),
  );
}

// ════════════════════════════════════════════════════════════════════════════
// CHANGE #635 — Pack hold-to-undo contract.
//
// Pack's 5-second hold-to-undo is spelled out in TWO places in the screen
// (_performUndo for the swipe flow, _doUndo for the accordion flow), and both
// hand-wrote the same RPC name and the same params map. A divergence between
// them is invisible until a packer holds the wrong one: dropping p_qty picks
// PostgREST's 2-arg legacy overload, which marks the line unpacked but leaves
// packed_qty stale, so the row reads "0 packed" while still counting as packed.
//
// One definition, both call sites, one test.
// ════════════════════════════════════════════════════════════════════════════

/// The RPC Pack's undo calls. NOT pack_undo_item — that function exists in the
/// database but nothing in this app has ever called it; Pack undoes by marking
/// the line unpacked through the same function that packed it.
const String kPackUndoRpc = 'pack_mark_item';

/// May this line be undone? Backend-owned: pack_get_queue emits `is_done` using
/// the packed-AND-counted rule, and the client must not re-derive it from
/// packed/packed_qty (which is what disagreed with the bag quick-view before).
bool packUndoAllowed(Map<String, dynamic> item) => item['is_done'] == true;

/// The exact params [kPackUndoRpc] must be called with to undo a packed line.
///
/// `p_qty: null` is load-bearing and must be PRESENT-with-null, never omitted:
/// it selects the 3-arg overload, which is the only one that clears packed_qty.
Map<String, dynamic> packUndoParams(String orderItemId) => {
      'p_order_item_id': orderItemId,
      'p_packed': false,
      'p_qty': null,
    };

/// Backend-owned progress fields for the box header. Renders progress.label
/// verbatim; the counted/total fallback only applies before the first
/// fw_get_state response has landed (e.g. mid-load).
class BoxProgress {
  final int counted;
  final int total;
  final String label;
  const BoxProgress({required this.counted, required this.total, required this.label});
}

BoxProgress boxProgressFrom(Map<String, dynamic>? progress, {required int fallbackTotal}) {
  final counted = (progress?['counted'] as num?)?.toInt() ?? 0;
  final total = (progress?['total'] as num?)?.toInt() ?? fallbackTotal;
  final label = progress?['label']?.toString() ?? '$counted/$total';
  return BoxProgress(counted: counted, total: total, label: label);
}

/// Backend-owned "N from earlier dates" control. show/label come straight
/// from the backend's `older` object — never constructed client-side.
class BoxOlder {
  final bool show;
  final String label;
  const BoxOlder({required this.show, required this.label});
}

BoxOlder boxOlderFrom(Map<String, dynamic>? older) => BoxOlder(
      show: older != null && older['show'] == true,
      label: older?['label']?.toString() ?? '',
    );

/// Backend-owned per-item date chip. Returns null when the line's own date
/// matches the selected Fulfill date (nothing to render).
String? itemDateChip(Map<String, dynamic> item) =>
    (item['show_date_chip'] == true && (item['date_chip']?.toString() ?? '').isNotEmpty)
        ? item['date_chip'].toString()
        : null;

/// C365: renders a qty with its pack type pluralised, e.g. `2 strips` (falls back to
/// `unit`/`units`). Shared so the breakdown, row chip and popup render the identical string.
String qtyWithPack(int n, String? packType) {
  final p = (packType == null || packType.trim().isEmpty) ? 'unit' : packType.trim();
  return '$n ${n == 1 ? p : '${p}s'}';
}

/// Whether a row should show the active-dispute strip. Canonical rule: only when
/// a dispute exists AND is still active (web used to show it for resolved ones).
bool disputeStripVisible(DisputeItem? item) {
  final visible = item != null && item.isActive;
  if (visible) RenderLog.write('c355_shared', 'fn=stripVisible');
  return visible;
}

/// #363-A: the confirm button's visual — GREEN + enabled when NO product is
/// unsatisfied, else RED + disabled. Caller counts unsatisfied products via
/// each product's backend-owned confirm_gate.can_confirm (fw_get_state's
/// merged_items[]), verbatim, so mobile + web agree by construction.
class ConfirmButtonVisual {
  /// true → button is clickable (all lines satisfy the gate).
  final bool enabled;
  /// true → paint RED (disabled); false → paint GREEN (enabled).
  final bool red;
  const ConfirmButtonVisual({required this.enabled, required this.red});
}

ConfirmButtonVisual confirmButtonVisual({required int unsatisfiedLines}) {
  final enabled = unsatisfiedLines == 0;
  return ConfirmButtonVisual(enabled: enabled, red: !enabled);
}
