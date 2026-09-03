// CHANGE #754 — the AutoFlow / Bundle toggles, as inline chips.
//
// Om's report: on the Supplier inquiry and Supplier order tabs the ⋮ menu sat
// alone on an otherwise empty row, and everything it held was a toggle. So the
// row goes, the ⋮ goes, and the toggles become chips that sit on a line that
// already exists — the SEND-ALL READINESS header on inquiry, the tab header on
// order.
//
// Nothing here decides anything. `supplier_toggle_chips()` sends the label,
// the on/off word and the tone for every chip; this file is the model that
// reads that payload and the widget that prints it. A chip with no label is
// not rendered rather than being given one in Dart.

import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// One toggle, exactly as `supplier_toggle_chips()` sent it.
@immutable
class SupplierToggleChip {
  const SupplierToggleChip({
    required this.key,
    required this.label,
    required this.on,
    required this.stateLabel,
    required this.tone,
    this.actionLabel = '',
  });

  /// 'auto_meta' | 'bundle' | 'order_auto_meta' — the backend's own key, which
  /// is what the screen switches on when the chip is tapped.
  final String key;

  /// The chip's word ("AutoFlow", "Bundle"). Never written in Dart.
  final String label;

  final bool on;

  /// The ON/OFF word. Also the backend's — a chip must not translate itself.
  final String stateLabel;

  /// 'on' | 'off'. A tone, not a colour: the colour is this build's token, so
  /// `ui_design_set()` still restyles the chip with no deploy.
  final String tone;

  /// An extra affordance the chip offers while it is on (Bundle's re-optimise).
  /// Empty means the chip offers none.
  final String actionLabel;

  bool get hasAction => actionLabel.isNotEmpty;

  factory SupplierToggleChip.fromJson(Map<String, dynamic> j) =>
      SupplierToggleChip(
        key: (j['key'] ?? '').toString(),
        label: (j['label'] ?? '').toString(),
        on: j['on'] == true,
        stateLabel: (j['state_label'] ?? '').toString(),
        tone: (j['tone'] ?? '').toString(),
        actionLabel: (j['action_label'] ?? '').toString(),
      );

  /// One scope's chips, in payload order. A chip the backend did not name is
  /// dropped rather than guessed at.
  static List<SupplierToggleChip> listFrom(dynamic raw) => ((raw as List?) ?? const [])
      .whereType<Map>()
      .map((e) => SupplierToggleChip.fromJson(e.cast<String, dynamic>()))
      .where((c) => c.key.isNotEmpty && c.label.isNotEmpty)
      .toList(growable: false);
}

/// The whole `supplier_toggle_chips()` reply.
@immutable
class SupplierToggleChipSet {
  const SupplierToggleChipSet({
    this.inquiry = const [],
    this.order = const [],
    this.toastOn = '',
    this.toastOff = '',
  });

  static const SupplierToggleChipSet empty = SupplierToggleChipSet();

  final List<SupplierToggleChip> inquiry;
  final List<SupplierToggleChip> order;

  /// The AutoFlow toast copy, so the screen stops wording it in Dart.
  final String toastOn;
  final String toastOff;

  String toast(bool on) => on ? toastOn : toastOff;

  factory SupplierToggleChipSet.fromJson(Map<String, dynamic>? j) {
    if (j == null || j['ok'] != true) return empty;
    return SupplierToggleChipSet(
      inquiry: SupplierToggleChip.listFrom(j['inquiry']),
      order: SupplierToggleChip.listFrom(j['order']),
      toastOn: (j['toast_on'] ?? '').toString(),
      toastOff: (j['toast_off'] ?? '').toString(),
    );
  }
}

/// The chip row. Sits inline on a header line — it never owns a row of its own,
/// which is the whole point of the change.
class SupplierToggleChipRow extends StatelessWidget {
  const SupplierToggleChipRow({
    super.key,
    required this.chips,
    required this.onToggle,
    this.onAction,
    this.busyKeys = const {},
  });

  final List<SupplierToggleChip> chips;

  /// (key, nextValue) — the screen calls the setting RPC it already had.
  final void Function(SupplierToggleChip chip, bool next) onToggle;

  /// The chip's own extra affordance (Bundle → re-optimise).
  final void Function(SupplierToggleChip chip)? onAction;

  /// Keys whose RPC is in flight; those chips show a spinner and refuse taps.
  final Set<String> busyKeys;

  @override
  Widget build(BuildContext context) {
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: Ds.space.x8,
      runSpacing: Ds.space.x8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [for (final c in chips) _chip(context, c)],
    );
  }

  Widget _chip(BuildContext context, SupplierToggleChip c) {
    final busy = busyKeys.contains(c.key);
    final on = c.tone == 'on';
    final fg = on ? Ds.c.surface : Ds.c.textSecondary;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      InkWell(
        borderRadius: Ds.r.rChip,
        onTap: busy ? null : () => onToggle(c, !c.on),
        child: Container(
          constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x12, vertical: Ds.space.x8),
          decoration: BoxDecoration(
            color: on ? Ds.c.brand : Ds.c.bg,
            borderRadius: Ds.r.rChip,
            border: Border.all(color: on ? Ds.c.brand : Ds.c.divider),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(c.label,
                style: Ds.t.caption
                    .copyWith(fontWeight: FontWeight.w600, color: fg)),
            SizedBox(width: Ds.space.x8),
            if (busy)
              SizedBox(
                width: Ds.t.captionSize,
                height: Ds.t.captionSize,
                child: CircularProgressIndicator(strokeWidth: 2, color: fg),
              )
            else
              Text(c.stateLabel,
                  style: Ds.t.caption
                      .copyWith(fontWeight: FontWeight.w700, color: fg)),
          ]),
        ),
      ),
      // The extra affordance only exists while the backend offers it, and it
      // is a separate tap target so toggling stays one tap.
      if (c.on && c.hasAction && !busy && onAction != null) ...[
        SizedBox(width: Ds.space.x4),
        Tooltip(
          message: c.actionLabel,
          child: InkWell(
            borderRadius: Ds.r.rChip,
            onTap: () => onAction!(c),
            child: SizedBox(
              width: Ds.touch.minTarget,
              height: Ds.touch.minTarget,
              child: Icon(Icons.auto_fix_high_outlined,
                  size: Ds.t.bodySize, color: Ds.c.brand),
            ),
          ),
        ),
      ],
    ]);
  }
}
