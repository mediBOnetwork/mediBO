// CHANGE #607 — the table shape is data, not code.
//
// #606 moved every STRING in the two admin order tables to the backend, but the
// tables themselves were still Dart: the column headers were literals
// ('CUSTOMER', 'STATUS', 'AMOUNT', …), the widths were hardcoded `flex:` values,
// and the order of the columns was the order somebody typed them in. Adding a
// column, renaming one, reordering them or changing a width all meant a deploy.
//
// admin_customer_orders and admin_supplier_orders now return `columns[]`:
//
//   [{ key, label, align, flex, type? }]
//
// `type` is absent for a plain string, "chip" for a {label,bg,fg,border,show}
// object, "button" for send_button. The client loops the array, prints
// `label` in the header and looks up `row[key]` for the cell. Column order IS
// the array order — never re-sorted here.
//
// There is deliberately NO fallback column list in Dart. A "for safety" copy is
// exactly the second competing answer this repo's first rule exists to kill: it
// would render a stale table shape the moment the config changed, and nobody
// would know which one they were looking at.
import 'package:flutter/material.dart';

import 'backend_chip.dart';

/// One column, exactly as the backend described it.
class BackendColumn {
  final String key;
  final String label;
  final String align;
  final String type;
  final int flex;

  const BackendColumn({
    required this.key,
    required this.label,
    required this.align,
    required this.type,
    required this.flex,
  });

  factory BackendColumn.fromMap(Map<String, dynamic> m) => BackendColumn(
        key: m['key'] as String? ?? '',
        label: m['label'] as String? ?? '',
        align: m['align'] as String? ?? 'left',
        // Absent `type` means a plain string cell.
        type: m['type'] as String? ?? '',
        flex: (m['flex'] as num?)?.toInt() ?? 1,
      );

  TextAlign get textAlign => switch (align) {
        'right' => TextAlign.right,
        'center' => TextAlign.center,
        _ => TextAlign.left,
      };

  Alignment get boxAlign => switch (align) {
        'right' => Alignment.centerRight,
        'center' => Alignment.center,
        _ => Alignment.centerLeft,
      };
}

/// Parses a `columns` payload. An unparseable or missing value yields an empty
/// list — and an empty list renders an empty header, which is the honest
/// outcome. It does not silently fall back to a hardcoded shape.
List<BackendColumn> backendColumns(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((e) => BackendColumn.fromMap(e.cast<String, dynamic>()))
      .toList();
}

/// The header row: one cell per column, label and alignment from the payload.
class BackendTableHeader extends StatelessWidget {
  final List<BackendColumn> columns;
  final EdgeInsets padding;

  /// Fixed-width chrome that trails the data columns (expand chevron, row
  /// icons). Not columns — they carry no header text and no payload flex.
  final double trailingWidth;

  const BackendTableHeader({
    super.key,
    required this.columns,
    this.padding = const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
    this.trailingWidth = 0,
  });

  @override
  Widget build(BuildContext context) {
    if (columns.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: padding,
      decoration: const BoxDecoration(
        color: Color(0xFFF9FAFB),
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(children: [
        for (final c in columns)
          Expanded(
            flex: c.flex,
            child: Text(
              c.label,
              textAlign: c.textAlign,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFF6B7280),
                letterSpacing: 0.4,
              ),
            ),
          ),
        if (trailingWidth > 0) SizedBox(width: trailingWidth),
      ]),
    );
  }
}

/// Runs one backend-described action: writes `status`, then lets the caller
/// refetch. [note] is the backend's success copy.
typedef BackendActionHandler = Future<void> Function(
    Map<String, dynamic> row, String status, String note);

/// One body cell, chosen by the column's `type`.
///
/// [buttonBuilder] supplies the widget for `type:"button"` columns — the caller
/// owns that because a send button carries a tap handler this widget knows
/// nothing about. When it is null the button cell renders nothing rather than
/// inventing a placeholder.
///
/// CHANGE #608 — [actionHandler] does the same job for `type:"actions"`.
class BackendTableCell extends StatelessWidget {
  final BackendColumn column;
  final Map<String, dynamic> row;
  final Widget Function(Map<String, dynamic> row)? buttonBuilder;
  final BackendActionHandler? actionHandler;
  final TextStyle? textStyle;

  const BackendTableCell({
    super.key,
    required this.column,
    required this.row,
    this.buttonBuilder,
    this.actionHandler,
    this.textStyle,
  });

  @override
  Widget build(BuildContext context) {
    switch (column.type) {
      case 'chip':
        final chip = backendChipOf(row, column.key);
        if (!backendChipVisible(chip)) return const SizedBox.shrink();
        return Align(
          alignment: column.boxAlign,
          child: BackendChip(chip: chip),
        );
      case 'button':
        if (buttonBuilder == null) return const SizedBox.shrink();
        return Align(alignment: column.boxAlign, child: buttonBuilder!(row));
      case 'actions':
        // CHANGE #608 — the cell type that made the CONFIRMATION column render
        // blank. `actions` is an object, not a string, so the default branch
        // below printed nothing for it.
        if (actionHandler == null) return const SizedBox.shrink();
        final actions = row[column.key] is Map
            ? (row[column.key] as Map).cast<String, dynamic>()
            : null;
        return Align(
          alignment: column.boxAlign,
          child: BackendActionsCell(
            actions: actions,
            onAct: (status, note) => actionHandler!(row, status, note),
          ),
        );
      default:
        // A plain string, printed verbatim. An empty value prints nothing —
        // no em-dash, no placeholder.
        final v = row[column.key];
        final s = v is String ? v : '';
        if (s.isEmpty) return const SizedBox.shrink();
        return Text(
          s,
          textAlign: column.textAlign,
          overflow: TextOverflow.ellipsis,
          style: textStyle ??
              const TextStyle(fontSize: 13, color: Color(0xFF111827)),
        );
    }
  }
}

/// The data half of a body row: the columns, in payload order, at payload flex.
class BackendTableRowCells extends StatelessWidget {
  final List<BackendColumn> columns;
  final Map<String, dynamic> row;
  final Widget Function(Map<String, dynamic> row)? buttonBuilder;
  final BackendActionHandler? actionHandler;

  const BackendTableRowCells({
    super.key,
    required this.columns,
    required this.row,
    this.buttonBuilder,
    this.actionHandler,
  });

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      for (final c in columns)
        Expanded(
          flex: c.flex,
          child: BackendTableCell(
            column: c,
            row: row,
            buttonBuilder: buttonBuilder,
            actionHandler: actionHandler,
          ),
        ),
    ]);
  }
}

/// CHANGE #608 — the ONE accept/reject implementation.
///
/// #607 put this logic inside `_ConfirmActions`, a private widget in
/// admin_customer_screen.dart. The `type:"actions"` column needs exactly the
/// same behaviour, and copy-pasting it is how the same value ends up decided in
/// two places that then drift. It lives here now; the screen's mobile card and
/// the desktop table cell both render THIS widget.
///
/// Everything visible comes from the action object: whether the pair shows at
/// all (`actions.show`), each button's own `show`, its label, its three
/// colours, the `status` value written, and the `note` toasted afterwards.
/// Nothing here knows the words "Accept", "accepted", or what a pending order
/// is.
class BackendActionsCell extends StatefulWidget {
  final Map<String, dynamic>? actions;

  /// Called with the tapped action's `status` and `note`. The caller performs
  /// the write and the refetch — this widget never mutates a row.
  final Future<void> Function(String status, String note) onAct;

  const BackendActionsCell({
    super.key,
    required this.actions,
    required this.onAct,
  });

  @override
  State<BackendActionsCell> createState() => _BackendActionsCellState();
}

class _BackendActionsCellState extends State<BackendActionsCell> {
  bool _busy = false;

  Future<void> _run(Map<String, dynamic> action) async {
    if (_busy) return;
    final status = action['status'] as String? ?? '';
    if (status.isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.onAct(status, action['note'] as String? ?? '');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.actions;
    // show:false means an empty cell — no placeholder text, no dash, no
    // disabled button.
    if (a == null || a['show'] != true) return const SizedBox.shrink();

    if (_busy) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    final accept = (a['accept'] as Map?)?.cast<String, dynamic>();
    final reject = (a['reject'] as Map?)?.cast<String, dynamic>();
    final showAccept = BackendActionButton.visible(accept);
    final showReject = BackendActionButton.visible(reject);
    if (!showAccept && !showReject) return const SizedBox.shrink();

    return Row(mainAxisSize: MainAxisSize.min, children: [
      BackendActionButton(action: accept, onTap: () => _run(accept!)),
      if (showAccept && showReject) const SizedBox(width: 4),
      BackendActionButton(action: reject, onTap: () => _run(reject!)),
    ]);
  }
}

/// A button whose label, enabled state and three colours all came from the
/// backend. Renders nothing when the label is empty.
class BackendActionButton extends StatelessWidget {
  final Map<String, dynamic>? action;
  final VoidCallback? onTap;
  final IconData? icon;
  final double fontSize;

  const BackendActionButton({
    super.key,
    required this.action,
    required this.onTap,
    this.icon,
    this.fontSize = 11,
  });

  /// `show` defaults to true when the key is absent — an action object that
  /// carries a label but no `show` is meant to be seen.
  static bool visible(Map<String, dynamic>? a) {
    if (a == null) return false;
    if (a.containsKey('show') && a['show'] != true) return false;
    return (a['label'] as String? ?? '').trim().isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    if (!visible(action)) return const SizedBox.shrink();
    final a = action!;
    final label = a['label'] as String;
    // `enabled` is optional; absent means enabled.
    final enabled = !a.containsKey('enabled') || a['enabled'] == true;
    final bg = backendHex(a['bg'] as String?, const Color(0xFFEDEFF2));
    final fg = backendHex(a['fg'] as String?, const Color(0xFF5A6472));
    final border = backendHex(a['border'] as String?, bg);
    return Opacity(
      opacity: enabled ? 1.0 : 0.5,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[
              Icon(icon, size: fontSize + 2, color: fg),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                  fontSize: fontSize, fontWeight: FontWeight.w600, color: fg),
            ),
          ]),
        ),
      ),
    );
  }
}
