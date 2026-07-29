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

/// One body cell, chosen by the column's `type`.
///
/// [buttonBuilder] supplies the widget for `type:"button"` columns — the caller
/// owns that because a send button carries a tap handler this widget knows
/// nothing about. When it is null the button cell renders nothing rather than
/// inventing a placeholder.
class BackendTableCell extends StatelessWidget {
  final BackendColumn column;
  final Map<String, dynamic> row;
  final Widget Function(Map<String, dynamic> row)? buttonBuilder;
  final TextStyle? textStyle;

  const BackendTableCell({
    super.key,
    required this.column,
    required this.row,
    this.buttonBuilder,
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

  const BackendTableRowCells({
    super.key,
    required this.columns,
    required this.row,
    this.buttonBuilder,
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
          ),
        ),
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
