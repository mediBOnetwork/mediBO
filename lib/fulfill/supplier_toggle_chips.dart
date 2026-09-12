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
import '../services/ui_copy.dart';
import '../utils/render_log.dart';

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

/// CHANGE #1890 — the Automation strip.
///
/// Om, 08 Sep: the AutoFlow / Bundle toggles were inside the tab BODY — on
/// inquiry they were squeezed onto the SEND-ALL READINESS header line (which
/// is what crushed that label to one character wide) and on Supplier orders
/// they were floating in the tab header row. There is now exactly ONE place
/// they live: a single-line strip directly under the tab bar, the same strip
/// on both tabs, carrying whichever chips the backend sent for that tab.
///
/// Still nothing decided here. `supplier_toggle_chips()` sends the label, the
/// ON/OFF word and the tone; `admin_supplier.automation_pill` decides how the
/// two are joined; `admin_supplier.settings_<chip key>_title` / `_body` is the
/// long-press sheet. A new toggle is rows in those two tables and no Dart.
class SupplierAutomationStrip extends StatelessWidget {
  const SupplierAutomationStrip({
    super.key,
    required this.chips,
    required this.onToggle,
    this.onSettings,
    this.busyKeys = const {},
  });

  final List<SupplierToggleChip> chips;

  /// (chip, nextValue) — the screen calls the setting RPC it already owned.
  final void Function(SupplierToggleChip chip, bool next) onToggle;

  /// Long-press. Null means the strip offers no settings affordance.
  final void Function(SupplierToggleChip chip)? onSettings;

  /// Keys whose RPC is in flight; those pills spin and refuse taps.
  final Set<String> busyKeys;

  /// The strip is one line and stays one line: a fixed height nothing inside
  /// it can grow past, so the tab body below never shifts when a word changes
  /// from OFF to ON.
  static double get height => Ds.touch.minTarget + Ds.space.x16;

  @override
  Widget build(BuildContext context) {
    // A tab whose backend sent no toggles gets no strip at all — an empty bar
    // under the tab bar is the thing #754 removed and must not come back.
    if (chips.isEmpty) return const SizedBox.shrink();
    RenderLog.write('c1890_automation_strip',
        chips.map((c) => '${c.key}=${c.tone}').join(','));
    return Container(
      height: height,
      padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        border: Border(bottom: BorderSide(color: Ds.c.divider)),
      ),
      child: Row(children: [
        // The title is a fixed-size child, never a flexible one — that is the
        // whole lesson of the readiness label this change also repaired.
        Text(c('admin_supplier.automation_title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Ds.t.caption.copyWith(fontWeight: FontWeight.w700)),
        SizedBox(width: Ds.space.x12),
        Expanded(
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            itemCount: chips.length,
            separatorBuilder: (_, _) => SizedBox(width: Ds.space.x8),
            itemBuilder: (_, i) => Center(child: _pill(chips[i])),
          ),
        ),
      ]),
    );
  }

  Widget _pill(SupplierToggleChip chip) {
    final busy = busyKeys.contains(chip.key);
    // A tone, never a colour: `ui_design_set()` restyles this with no deploy.
    final on = chip.tone == 'on';
    final fg = on ? Ds.c.brand : Ds.c.textSecondary;
    return Tooltip(
      message: c('admin_supplier.automation_hint'),
      child: InkWell(
        borderRadius: Ds.r.rChip,
        onTap: busy ? null : () => onToggle(chip, !chip.on),
        onLongPress:
            onSettings == null ? null : () => onSettings!(chip),
        child: Container(
          constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x12, vertical: Ds.space.x8),
          decoration: BoxDecoration(
            color: on ? Ds.c.brandSoft : Ds.c.bg,
            borderRadius: Ds.r.rChip,
            border: Border.all(color: on ? Ds.c.brand : Ds.c.divider),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            // ON carries a dot; OFF is grey and carries none. The dot is the
            // state, so a colour-blind reading of the strip still works.
            if (on) ...[
              Container(
                width: Ds.space.x8,
                height: Ds.space.x8,
                decoration: BoxDecoration(
                    color: Ds.c.brand, shape: BoxShape.circle),
              ),
              SizedBox(width: Ds.space.x8),
            ],
            if (busy)
              SizedBox(
                width: Ds.t.captionSize,
                height: Ds.t.captionSize,
                child: CircularProgressIndicator(strokeWidth: 2, color: fg),
              )
            else
              Text(
                cf('admin_supplier.automation_pill',
                    {'label': chip.label, 'state': chip.stateLabel}),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Ds.t.caption
                    .copyWith(fontWeight: FontWeight.w700, color: fg),
              ),
          ]),
        ),
      ),
    );
  }
}

/// The long-press sheet. Title and body are addressed BY THE CHIP'S OWN KEY,
/// so this function never learns which toggle it is looking at, and the chip's
/// extra affordance (Bundle's re-optimise) appears only because the payload
/// named one.
Future<void> showAutomationSettingsSheet(
  BuildContext context,
  SupplierToggleChip chip, {
  required void Function(SupplierToggleChip chip, bool next) onToggle,
  void Function(SupplierToggleChip chip)? onAction,
}) {
  RenderLog.write('c1890_automation_settings', chip.key);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Ds.c.surface,
    shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
    builder: (sheetCtx) => SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c('admin_supplier.settings_${chip.key}_title'),
              style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          Text(c('admin_supplier.settings_${chip.key}_body'),
              style: Ds.t.bodySecondary),
          SizedBox(height: Ds.space.x24),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              onPressed: () {
                Navigator.of(sheetCtx).pop();
                onToggle(chip, !chip.on);
              },
              child: Text(cf('admin_supplier.automation_pill',
                  {'label': chip.label, 'state': chip.stateLabel})),
            ),
          ),
          if (chip.on && chip.hasAction && onAction != null) ...[
            SizedBox(height: Ds.space.x12),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(sheetCtx).pop();
                  onAction(chip);
                },
                icon: Icon(Icons.auto_fix_high_outlined, size: Ds.t.bodySize),
                label: Text(chip.actionLabel),
              ),
            ),
          ],
          SizedBox(height: Ds.space.x12),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: TextButton(
              onPressed: () => Navigator.of(sheetCtx).pop(),
              child: Text(c('admin_supplier.settings_close')),
            ),
          ),
        ]),
      ),
    ),
  );
}
