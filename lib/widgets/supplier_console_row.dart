// CHANGE #753 — one row of the admin Suppliers list.
//
// Om rejected the first version (3 Sep): it crammed a waiting count, a rupee
// amount, a KYC badge and an overflow menu into a row that then truncated on
// anything narrower than a desktop. "This is a supplier INFO list, not an
// orders tab." So the row is now a NAME — allowed to wrap, never ellipsised —
// with one quiet line under it and a status dot. Every number and every action
// lives on the supplier page you reach by tapping it.
//
// Extracted out of the 13k-line supplier screen so the thing the protected
// suite needs to hold down — that this row COMPUTES NOTHING — can be rendered
// in a test without Supabase, a shell, or a screen. name, subtitle,
// status_label and status_tone are all payload fields; there is no fallback
// wording here, because inventing one puts a second, staler answer on the
// screen next to the server's.
import 'package:flutter/material.dart';

import '../design_tokens.dart';

class SupplierConsoleRow extends StatelessWidget {
  final Map<String, dynamic> row;

  /// Tapping the row opens the supplier page.
  final VoidCallback? onOpen;

  const SupplierConsoleRow({super.key, required this.row, this.onOpen});

  String _s(String key) => (row[key] as String?) ?? '';

  Color _dot() {
    switch (_s('status_tone')) {
      case 'success':
        return Ds.c.success;
      case 'warning':
        return Ds.c.warning;
      case 'danger':
        return Ds.c.danger;
      default:
        return Ds.c.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _s('subtitle');
    final status = _s('status_label');
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // The full name, wrapping onto a second line rather than losing
            // half of itself to an ellipsis.
            Text(_s('name'), style: Ds.t.bodyStrong, softWrap: true),
            if (subtitle.isNotEmpty || status.isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Row(children: [
                if (subtitle.isNotEmpty)
                  Flexible(
                    child: Text(subtitle,
                        style: Ds.t.caption, overflow: TextOverflow.ellipsis),
                  ),
                if (subtitle.isNotEmpty && status.isNotEmpty)
                  SizedBox(width: Ds.space.x8),
                if (status.isNotEmpty) ...[
                  Container(
                    width: Ds.space.x8,
                    height: Ds.space.x8,
                    decoration:
                        BoxDecoration(color: _dot(), shape: BoxShape.circle),
                  ),
                  SizedBox(width: Ds.space.x4),
                  Text(status, style: Ds.t.caption),
                ],
              ]),
            ],
          ],
        ),
      ),
    );
  }
}
