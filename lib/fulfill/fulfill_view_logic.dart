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

/// Canonical derived view for one fulfill row (shop or warehouse stage).
class FulfillRowView {
  /// e.g. "3/5" — right-aligned quantity progress for the row.
  final String qtyLabel;

  /// State string handed to the status pill widget
  /// ('pending'|'received'|'short'|'wrong'|'not_coming').
  final String pillState;

  /// Warehouse-only: the line is fully short and awaiting dispute resolution
  /// (expected == 0). Layouts render a muted "in dispute · awaiting resolution".
  final bool awaitingResolution;

  const FulfillRowView({
    required this.qtyLabel,
    required this.pillState,
    required this.awaitingResolution,
  });
}

/// Derive the qty label + pill state for a fulfill row. Works for both a single
/// line and a merged product — the caller passes the right totals.
///
/// [arrivals]      false = Supplier Shop stage, true = Warehouse stage.
/// [ordered]       ordered qty (merged: orderedTotal).
/// [shopQty]       shop-stage counted qty; null = not yet counted (shop only).
/// [received]      received qty (merged: receivedTotal).
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
      return const FulfillRowView(
          qtyLabel: '', pillState: 'pending', awaitingResolution: true);
    }
    final pill = received >= whExpected ? 'received' : combinedState;
    return FulfillRowView(
      qtyLabel: '$received/$whExpected',
      pillState: pill,
      awaitingResolution: false,
    );
  }
  // Supplier Shop: pill derives from shop_qty vs ordered, EXCEPT terminal
  // fulfillment states ("Got all"/"Wrong"/"Not coming") which write
  // fulfillment_state but not shop_qty — those must win over the shop_qty pill.
  const terminals = {'received', 'wrong', 'not_coming'};
  final terminal = terminals.contains(combinedState);
  final qtyLabel = (terminal && shopQty == null)
      ? '$received/$ordered'
      : '${shopQty ?? 0}/$ordered';
  final pill = terminal
      ? combinedState
      : (shopQty == null
          ? 'pending'
          : (shopQty >= ordered && ordered > 0 ? 'received' : 'short'));
  return FulfillRowView(
      qtyLabel: qtyLabel, pillState: pill, awaitingResolution: false);
}

/// Amber "count_issue" chip label from the raw payload value. Returns null when
/// there is no issue (so the layout renders nothing). Used by every row chip.
String? issueChipLabel(String? countIssue) {
  if (countIssue == null || countIssue.isEmpty || countIssue == 'null') {
    return null;
  }
  RenderLog.write('c355_shared', 'fn=issueChip');
  return switch (countIssue) {
    'wrong' => 'Wrong',
    'few_wrong' => 'Few wrong',
    'damaged' => 'Damaged',
    'excess' => 'Excess',
    'not_coming' => 'Not coming',
    _ => countIssue,
  };
}

/// Canonical status-pill label. C361: the web "Item Status" column re-derived this
/// inline (capitalised) with a different casing than the _StatePill chip in the SAME
/// row ("Received" vs "received"). One definition so a pill and any text column that
/// shows the same state can never disagree.
String statusPillLabel(String state) {
  RenderLog.write('c355_shared', 'fn=statusLabel');
  return switch (state) {
    'wrong' => 'Wrong item',
    'not_coming' => 'Not coming',
    _ => state.replaceAll('_', ' '),
  };
}

/// Dispute-kind tag label (Disputes tab card + action sheet). One definition so
/// the card and the sheet header can never disagree.
String disputeKindLabel(String kind) {
  RenderLog.write('c355_shared', 'fn=kindTag');
  return switch (kind) {
    'wrong_item' => 'Wrong item',
    'few_wrong' => 'Few wrong',
    'damaged' => 'Damaged',
    'excess' => 'Excess',
    'not_coming' => 'Not coming',
    _ => 'Short',
  };
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
// SINGLE SOURCE OF TRUTH for both layouts (mobile card + web table) AND the
// response button, so a "yellow candidate row" and a "yellow disabled button"
// can never disagree. All pure — compute from the line/merged fields only, never
// from ephemeral UI state (Om's rule: "put it in the shared helper so mobile and
// web agree"). Counting is stage-dependent: SHOP counts shop_qty vs ordered,
// WAREHOUSE counts received_qty vs expected.
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

/// STEP B — a candidate is TAPPABLE (opens the Report-issue popup); a fully
/// correct / un-counted line is not. Alias of [isDisputeCandidate] so the rule
/// lives in one place and stage nuances can grow here later.
bool isTappableLine({
  required bool arrivals,
  required int ordered,
  int? shopQty,
  required int received,
  int? expected,
  String? countIssue,
  required String state,
}) =>
    isDisputeCandidate(
      arrivals: arrivals, ordered: ordered, shopQty: shopQty, received: received,
      expected: expected, countIssue: countIssue, state: state);

/// STEP C — is a candidate's discrepancy fully accounted for by its chosen dispute
/// type + qty? All measured against the SAME stage reference as candidacy (ordered
/// at shop, expected/forwarded shop_qty at warehouse), so the gate matches what the
/// backend actually disputes. Every balance point is REACHABLE via the popup stepper
/// (max = ref - received), i.e. no deadlock.
///   plain short (counted < ref, no flag) : accounted for — the confirm RPC auto-raises
///                            the short (short_qty = ref - counted). Matches
///                            `ref == counted + disputed`.
///   few_wrong / damaged    : issue_qty == ref - counted (the wrong/damaged units ARE
///                            the shortfall); if counted >= ref, any qty >= 1.
///   excess                 : issue_qty == counted - ref when over-ref; else any qty>=1.
///   not_coming             : whole remaining gap claimed  -> balanced once selected
///   wrong item (whole line): balanced once the type is selected
///   over-ref with no excess flag : NOT balanced (admin must flag excess — backend WILL
///                            raise it: received > expected at warehouse / shop_qty > ordered)
/// A non-candidate line is trivially balanced (nothing to reconcile).
bool lineBalanced({
  required bool arrivals,
  required int ordered,
  int? shopQty,
  required int received,
  int? expected,
  String? countIssue,
  int? issueQty,
  required String state,
}) {
  if (!isDisputeCandidate(
      arrivals: arrivals, ordered: ordered, shopQty: shopQty, received: received,
      expected: expected, countIssue: countIssue, state: state)) {
    return true;
  }
  final counted = countedQtyFor(arrivals: arrivals, shopQty: shopQty, received: received);
  final ref = stageRefFor(arrivals: arrivals, ordered: ordered, expected: expected);
  final ci = _cleanIssue359(countIssue);
  final iq = issueQty ?? 0;
  if (ci == 'wrong' || state == 'wrong') return true;           // whole line disputed
  if (state == 'not_coming') return true;                       // whole remaining gap
  if (ci == 'few_wrong' || ci == 'damaged') {
    final gap = ref - counted;                                 // == popup stepper max
    return gap > 0 ? iq == gap : iq >= 1;
  }
  if (ci == 'excess') {                                         // extra units = issue_qty
    final over = counted - ref;
    return over > 0 ? iq == over : iq >= 1;
  }
  if (counted < ref) return true;                              // plain short — RPC auto-raises
  return false;                                                 // over-ref, unflagged → must flag excess
}

/// Response/confirm button visual state for a tab.
enum ResponseButtonState { normal, yellowDisabled }

/// STEP C — the response button is YELLOW + DISABLED while any candidate is still
/// un-balanced; NORMAL + clickable when there are no candidates OR every candidate
/// balances (ordered == counted + disputed for all lines).
ResponseButtonState responseButtonState({
  required int candidateCount,
  required int unbalancedCandidateCount,
}) {
  if (candidateCount == 0) return ResponseButtonState.normal;
  return unbalancedCandidateCount == 0
      ? ResponseButtonState.normal
      : ResponseButtonState.yellowDisabled;
}
