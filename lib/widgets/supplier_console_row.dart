// CHANGE #753 — one compact row of the admin Suppliers list.
//
// Extracted out of the 13k-line supplier screen so the thing the protected
// suite actually needs to hold down — that this row COMPUTES NOTHING — can be
// rendered in a test without Supabase, a shell, or a screen.
//
// Every visible string is a field of the payload row: name, zone_label,
// rank_label, spn_label, waiting_label, dues_label, and the kyc_chip object.
// `has_waiting` / `has_dues` are the BACKEND's flags, never a Dart comparison
// against a number, and the ⋮ menu is the backend's list in the backend's
// order. There is no fallback wording anywhere: a field the payload omits
// renders as empty, because inventing one puts a second, staler answer on the
// screen next to the server's.
import 'package:flutter/material.dart';

import '../design_tokens.dart';
import 'backend_chip.dart';

class SupplierConsoleRow extends StatelessWidget {
  final Map<String, dynamic> row;

  /// Tapping the row opens the supplier page.
  final VoidCallback? onOpen;

  /// One entry of `row['menu']` was chosen.
  final void Function(Map<String, dynamic> item)? onMenu;

  const SupplierConsoleRow({
    super.key,
    required this.row,
    this.onOpen,
    this.onMenu,
  });

  String _s(String key) => (row[key] as String?) ?? '';

  List<Map<String, dynamic>> get menuItems => row['menu'] is List
      ? (row['menu'] as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList()
      : const <Map<String, dynamic>>[];

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onOpen,
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16, vertical: Ds.space.x12),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          border: Border(bottom: BorderSide(color: Ds.c.divider)),
        ),
        child: Row(children: [
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_s('name'),
                    style: Ds.t.bodyStrong, overflow: TextOverflow.ellipsis),
                SizedBox(height: Ds.space.x4),
                Text(
                  '${_s('zone_label')}  ·  ${_s('rank_label')}  ${_s('spn_label')}',
                  style: Ds.t.caption,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          SizedBox(width: Ds.space.x8),
          Expanded(
            flex: 3,
            child: Text(
              _s('waiting_label'),
              style: row['has_waiting'] == true
                  ? Ds.t.caption.copyWith(color: Ds.c.warning)
                  : Ds.t.caption,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(width: Ds.space.x8),
          Expanded(
            flex: 2,
            child: Text(
              _s('dues_label'),
              style: row['has_dues'] == true
                  ? Ds.t.bodyStrong.copyWith(color: Ds.c.danger)
                  : Ds.t.caption,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(width: Ds.space.x12),
          BackendChip(chip: backendChipOf(row, 'kyc_chip')),
          SizedBox(width: Ds.space.x8),
          _menu(),
        ]),
      ),
    );
  }

  Widget _menu() {
    final items = menuItems;
    if (items.isEmpty) return const SizedBox.shrink();
    return PopupMenuButton<int>(
      icon: Icon(Icons.more_vert,
          size: Ds.space.x16 + Ds.space.x4, color: Ds.c.textSecondary),
      tooltip: '',
      onSelected: (i) => onMenu?.call(items[i]),
      itemBuilder: (_) => [
        for (var i = 0; i < items.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: Text(
              (items[i]['label'] as String?) ?? '',
              style: (items[i]['tone'] == 'danger')
                  ? Ds.t.body.copyWith(color: Ds.c.danger)
                  : Ds.t.body,
            ),
          ),
      ],
    );
  }
}
