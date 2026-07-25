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

/// Canonical derived view for one fulfill row — used only by the single raw
/// order-item tile (_buildItemTile). Merged/product-level rows read
/// fw_get_state()'s merged_items[] fields (qty_label, status_label,
/// status_colors, issue_chip) verbatim instead — see _MergedProduct.fromBackend.
class FulfillRowView {
  /// e.g. "3/5" — right-aligned quantity progress for the row.
  final String qtyLabel;

  /// Warehouse-only: the line is fully short and awaiting dispute resolution
  /// (expected == 0). Layouts render a muted "in dispute · awaiting resolution".
  final bool awaitingResolution;

  const FulfillRowView({
    required this.qtyLabel,
    required this.awaitingResolution,
  });
}

/// Derive the qty label for a single fulfill row (not a merged product).
///
/// [arrivals]      false = Supplier Shop stage, true = Warehouse stage.
/// [ordered]       ordered qty.
/// [shopQty]       shop-stage counted qty; null = not yet counted (shop only).
/// [received]      received qty.
/// [expected]      warehouse forwarded/expected qty; null → falls back to ordered.
/// [combinedState] the row's fulfillment state ('pending'|'received'|'short'|
///                 'wrong'|'not_coming').
FulfillRowView fulfillRowView({
  required bool arrivals,
  required int ordered,
  int? shopQty,
  required int received,
  int? expected,
  required String combinedState,
}) {
  RenderLog.write('c355_shared', 'fn=rowView');
  if (arrivals) {
    // Warehouse: measure against the forwarded/expected qty, not raw ordered.
    final whExpected = (expected != null) ? expected : ordered;
    if (whExpected == 0) {
      return const FulfillRowView(qtyLabel: '', awaitingResolution: true);
    }
    return FulfillRowView(
      qtyLabel: '$received/$whExpected',
      awaitingResolution: false,
    );
  }
  // Supplier Shop: EXCEPT terminal fulfillment states ("Got all"/"Wrong"/
  // "Not coming") which write fulfillment_state but not shop_qty.
  const terminals = {'received', 'wrong', 'not_coming'};
  final terminal = terminals.contains(combinedState);
  final qtyLabel = (terminal && shopQty == null)
      ? '$received/$ordered'
      : '${shopQty ?? 0}/$ordered';
  return FulfillRowView(qtyLabel: qtyLabel, awaitingResolution: false);
}

/// C365: renders a qty with its pack type pluralised, e.g. `2 strips` (falls back to
/// `unit`/`units`). Shared so the breakdown, row chip and popup render the identical string.
String qtyWithPack(int n, String? packType) {
  final p = (packType == null || packType.trim().isEmpty) ? 'unit' : packType.trim();
  return '$n ${n == 1 ? p : '${p}s'}';
}

/// C364/C365: row chip that shows HOW MUCH is in dispute WITH pack type, e.g.
/// "In dispute — 2 strips". [issueQty] = the disputed count (aggregated issue_qty or the
/// matched dispute short_qty). Returns null when the line has no dispute flag (nothing
/// renders). Flagged but qty unknown (a whole-line 'wrong') -> plain "In dispute". Shared
/// so the mobile card + web table row show the identical label (no drift).
String? disputedChipLabel(String? countIssue, int? issueQty, [String? packType]) {
  if (countIssue == null || countIssue.isEmpty || countIssue == 'null') {
    return null;
  }
  RenderLog.write('c355_shared', 'fn=disputedChip');
  final n = issueQty ?? 0;
  if (n > 0) return 'In dispute — ${qtyWithPack(n, packType)}';
  return 'In dispute';
}

/// Whether a row should show the active-dispute strip. Canonical rule: only when
/// a dispute exists AND is still active (web used to show it for resolved ones).
bool disputeStripVisible(DisputeItem? item) {
  final visible = item != null && item.isActive;
  if (visible) RenderLog.write('c355_shared', 'fn=stripVisible');
  return visible;
}

// ════════════════════════════════════════════════════════════════════════════
// CHANGE #359 — 2-STEP DISPUTE FLOW: shared candidate / balance / gate logic.
//
// FALLBACK ONLY as of the backend-fields migration: fw_get_state now returns
// is_dispute_candidate / dispute_qty / confirm_gate.can_confirm directly on
// items[] and merged_items[], and the live screen reads those verbatim. The
// functions below run only when one of those fields is absent on a given
// line/product, reproducing the prior client-side rule for that one line so
// nothing crashes or silently misbehaves during a partial backend rollout.
// Counting is stage-dependent: SHOP counts shop_qty vs ordered, WAREHOUSE
// counts received_qty vs expected.
// ════════════════════════════════════════════════════════════════════════════

String? _cleanIssue359(String? raw) {
  if (raw == null || raw.isEmpty || raw == 'null') return null;
  return raw;
}

/// Stage-appropriate counted quantity for a fulfill line/merged product.
int countedQtyFor({required bool arrivals, int? shopQty, required int received}) =>
    arrivals ? received : (shopQty ?? 0);

/// Has this line been counted at all? An un-counted line (shop_qty null at shop,
/// nothing received/flagged at warehouse) is NOT a candidate — counting is still
/// pending for it (the confirm RPC's own uncounted gate forces it to be counted).
bool _isCounted359({
  required bool arrivals,
  int? shopQty,
  required int received,
  String? countIssue,
  required String state,
}) {
  // A flag or terminal state also proves the line was acted on (covers a merged
  // product whose shop_qty total is null because a sibling line is uncounted).
  final actedOn = _cleanIssue359(countIssue) != null ||
      state == 'short' ||
      state == 'wrong' ||
      state == 'not_coming';
  if (arrivals) return received > 0 || actedOn;
  return shopQty != null || actedOn;
}

/// C360: the SINGLE stage reference for candidacy AND balance, matching the LIVE
/// backend (_fw_raise_dispute_for_line, verified via MCP):
///   SHOP      -> ordered (v_expected = quantity)
///   WAREHOUSE -> expected = forwarded shop_qty (v_expected = coalesce(shop_qty, quantity))
/// The backend raises short when counted < ref AND excess when counted > ref, for
/// BOTH stages against this same ref. (#359 wrongly used ordered as the warehouse
/// EXCESS threshold; the backend uses expected, so a warehouse line received above
/// the forwarded qty would false-green the confirm button. Unifying to one ref
/// fixes that and keeps candidacy == the backend's own raise condition.)
int stageRefFor({required bool arrivals, required int ordered, int? expected}) =>
    arrivals ? (expected ?? ordered) : ordered;

/// STEP B — a line is a DISPUTE CANDIDATE when, after voice counting, it is not
/// fully/correctly satisfied: counted != the stage reference (short OR excess), OR
/// it carries a count_issue flag, OR it is wrong/not_coming. Un-counted lines are
/// not candidates yet. Mirrors exactly the lines the confirm RPC raises disputes for.
bool isDisputeCandidate({
  required bool arrivals,
  required int ordered,
  int? shopQty,
  required int received,
  int? expected,
  String? countIssue,
  required String state,
}) {
  // Warehouse "awaiting resolution" rows (fully-short lines forwarded from shop,
  // expected==0) are ALREADY disputed and not admin-actionable — fulfillRowView
  // renders them muted. Exclude them so they don't tint, aren't tappable, and
  // never block the confirm gate. (Same guard as fulfillRowView.)
  if (arrivals && (expected ?? ordered) == 0) return false;
  if (!_isCounted359(
      arrivals: arrivals, shopQty: shopQty, received: received,
      countIssue: countIssue, state: state)) {
    return false;
  }
  final counted = countedQtyFor(arrivals: arrivals, shopQty: shopQty, received: received);
  final ref = stageRefFor(arrivals: arrivals, ordered: ordered, expected: expected);
  final ci = _cleanIssue359(countIssue);
  // `counted != ref` captures BOTH short (counted<ref) and excess (counted>ref);
  // state=='short' is NOT an independent trigger (a short is defined by counted<ref,
  // so an already-reconciled line at counted==ref never re-flags).
  final candidate = counted != ref ||
      ci != null ||
      state == 'wrong' ||
      state == 'not_coming';
  if (candidate) RenderLog.write('c355_shared', 'fn=candidate');
  return candidate;
}

// ════════════════════════════════════════════════════════════════════════════
// CHANGE #363 (re-issued, narrow) — CONFIRM-BUTTON GATE + COLOR.
//
// FALLBACK ONLY: the live screen reads each product's confirm_gate.can_confirm
// straight off merged_items[]. The rule below (ref <= counted + disputed) only
// runs for a product whose confirm_gate is absent, reproducing the prior
// client-side gate for that one product. ref = ordered @ shop / expected
// (forwarded shop_qty) @ warehouse (preserves the #360 over-forward fix).
// counted = shop_qty @ shop / received_qty @ warehouse. disputed = the qty
// already flagged on the line by kind. A short line with NO dispute flag has
// disputed=0 → ref<=counted is FALSE → stays unsatisfied until a matching
// dispute (count_issue) is assigned to that line. A fully-received line
// (counted>=ref, no flag) and an excess line are trivially balanced.
// ════════════════════════════════════════════════════════════════════════════

/// #363/#364: qty already disputed on a line, by kind. #364 — the popup now stores an
/// editable disputed qty in issue_qty for EVERY qty kind (incl short), so the gate reads
/// issue_qty as the disputed amount (a PARTIAL short with issue_qty < the gap must stay RED).
///   short / few_wrong / damaged / excess         -> issue_qty (the entered disputed units)
///   wrong      (count_issue='wrong')             -> ref             (whole line disputed)
///   not_coming (fulfillment_state='not_coming')  -> ref - counted   (whole remaining gap)
///   no flag                                      -> 0               (an unflagged short keeps the button RED)
int confirmDisputedQty({
  required int ref,
  required int counted,
  String? countIssue,
  int? issueQty,
  required String state,
}) {
  if (state == 'not_coming') return ref - counted;
  final ci = (countIssue == null || countIssue.isEmpty || countIssue == 'null')
      ? null
      : countIssue;
  switch (ci) {
    case 'wrong':
      return ref;
    case 'short': // C364: read the entered disputed qty, NOT the whole gap
    case 'few_wrong':
    case 'damaged':
    case 'excess':
      return issueQty ?? 0;
    default:
      return 0;
  }
}

/// #365-F: does a whole PRODUCT (summed over its order-lines) satisfy the confirm gate?
/// refTotal <= countedTotal + disputedTotal. refTotal = Σ (ordered@shop / expected@warehouse),
/// countedTotal = Σ (shop_qty@shop / received_qty@warehouse), disputedTotal = Σ per-line
/// confirmDisputedQty. This aggregated rule matches the one-row-per-product display and lets a
/// multi-line dispute (distributed across lines by fw_set_product_issue) cover the full gap and
/// turn the button green. A product with nothing to reconcile (refTotal<=0) never blocks.
bool productSatisfiesConfirmGate({
  required int refTotal,
  required int countedTotal,
  required int disputedTotal,
}) {
  if (refTotal <= 0) return true;
  return refTotal <= countedTotal + disputedTotal;
}

/// #363-A: the confirm button's visual — GREEN + enabled when NO product is
/// unsatisfied, else RED + disabled. Caller counts unsatisfied products via
/// each product's confirm_gate.can_confirm (fallback: [productSatisfiesConfirmGate])
/// so mobile + web agree by construction.
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
