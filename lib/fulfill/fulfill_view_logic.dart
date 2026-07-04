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
