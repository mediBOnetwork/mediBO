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
import '../utils/ist_date.dart';
import '../utils/render_log.dart';

// ════════════════════════════════════════════════════════════════════════════
// CHANGE #471 — fw_get_state date scoping + backend-owned display strings.
// PURE logic only, so the RPC param shape and the render decisions (does the
// older-pill show, does the date chip show) are unit-testable without pumping
// the (huge, Supabase-backed) admin_fulfillment_screen widget tree.
// ════════════════════════════════════════════════════════════════════════════

/// The exact params map every fw_get_state call must send. p_date is NEVER
/// omitted — relying on the server default was the #471 bug (it made the box
/// ignore the selected Fulfill date and show the wrong day's items).
/// p_include_older is deliberately NOT sent: fw_get_state (like every other
/// Fulfill RPC) is strict single-date now — the date picker is the only
/// intended way to view another date, and the RPC ignores this param anyway.
Map<String, dynamic> fwGetStateParams({
  required String supplierName,
  required String stage,
  required DateTime date,
}) =>
    {
      'p_supplier_name': supplierName,
      'p_stage': stage,
      'p_date': ymd(date),
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
