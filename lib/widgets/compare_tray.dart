import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../models/product_compare.dart';

/// CMD #410 — side-by-side compare.
///
/// Three pieces:
///  * [CompareSelection] — the ONLY thing the app owns: which product ids the
///    customer ticked. It is a list of ids and a cap, nothing else. It holds
///    no prices, no labels and no verdicts.
///  * [CompareCheckbox] — the tick on a same-salt row or a search result. Its
///    caption is the backend's (`compare.add_label`), never a Dart literal.
///  * [CompareSheet] — the table. It prints `product_compare()` verbatim: rows
///    in payload order, each with the backend's label and one cell per column.
///
/// The reason the sheet computes nothing is the #366 no-false-numbers rule. A
/// cell arrives as {has, value}: a product with no real trade rate is has:false
/// on the rate AND margin rows and prints the backend's dash. There is no
/// fallback to MRP here — MRP is the legal ceiling on the pack, not a rate we
/// sell at, so a margin against it would be a number nobody measured.
class CompareSelection extends ChangeNotifier {
  final int max;
  final List<String> _ids = [];

  CompareSelection({this.max = 3});

  List<String> get ids => List.unmodifiable(_ids);
  int get count => _ids.length;
  bool get isFull => _ids.length >= max;
  bool get canCompare => _ids.length >= 2;
  bool contains(String id) => _ids.contains(id);

  /// Returns null when the tick was accepted, or the reason key the caller
  /// should print the backend's copy for ('full'). The STRING is never built
  /// here — the caller looks it up in the payload it already has.
  String? toggle(String id) {
    if (_ids.remove(id)) {
      notifyListeners();
      return null;
    }
    if (_ids.length >= max) return 'full';
    _ids.add(id);
    notifyListeners();
    return null;
  }

  void remove(String id) {
    if (_ids.remove(id)) notifyListeners();
  }

  void clear() {
    if (_ids.isEmpty) return;
    _ids.clear();
    notifyListeners();
  }
}

/// The tick that puts a product in the tray. [label] is the backend's.
class CompareCheckbox extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const CompareCheckbox({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rChip,
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected ? Icons.check_box : Icons.check_box_outline_blank,
              size: Ds.space.x16,
              color: selected ? Ds.c.brand : Ds.c.textSecondary,
            ),
            SizedBox(width: Ds.space.x4),
            Text(
              label,
              style: Ds.t.caption.copyWith(
                color: selected ? Ds.c.brand : Ds.c.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The docked bar that appears once something is ticked.
class CompareBar extends StatelessWidget {
  final int count;
  final int max;
  final String ctaLabel;
  final String clearLabel;

  /// Null while fewer than two are picked — the CTA is disabled, and the
  /// reason ('min') is the backend's sentence, printed by the caller.
  final VoidCallback? onCompare;
  final VoidCallback onClear;

  const CompareBar({
    super.key,
    required this.count,
    required this.max,
    required this.ctaLabel,
    required this.clearLabel,
    required this.onCompare,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
          boxShadow: Ds.elevation.e2,
        ),
        child: Row(
          children: [
            Text('$count/$max', style: Ds.t.bodyStrong),
            SizedBox(width: Ds.space.x12),
            SizedBox(
              height: 44,
              child: TextButton(
                onPressed: onClear,
                style: TextButton.styleFrom(foregroundColor: Ds.c.textSecondary),
                child: Text(clearLabel),
              ),
            ),
            const Spacer(),
            SizedBox(
              height: 44,
              child: FilledButton(
                onPressed: onCompare,
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                child: Text(ctaLabel),
              ),
            ),
          ],
        ),
      );
}

/// The table itself. A nested loop over `rows` × `cells` and nothing else.
class CompareSheet extends StatelessWidget {
  final ProductCompare data;
  const CompareSheet({super.key, required this.data});

  static Future<void> show(BuildContext context, ProductCompare data) {
    // A sheet, not a dialog (DESIGN.md): the table is wide and the customer
    // is mid-decision, so it must be dismissible with a thumb.
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
      ),
      builder: (_) => CompareSheet(data: data),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colWidth = 132.0;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(data.title, style: Ds.t.title),
            SizedBox(height: Ds.space.x4),
            Text(data.note, style: Ds.t.caption),
            SizedBox(height: Ds.space.x16),
            if (!data.has)
              Text(data.empty, style: Ds.t.body)
            else
              Flexible(
                child: SingleChildScrollView(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _HeaderRow(products: data.products, colWidth: colWidth),
                        for (final row in data.rows)
                          _BodyRow(row: row, colWidth: colWidth),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  final List<CompareProduct> products;
  final double colWidth;
  const _HeaderRow({required this.products, required this.colWidth});

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox(width: 96, height: 1),
          for (final p in products)
            SizedBox(
              width: colWidth,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Ds.t.bodyStrong),
                    SizedBox(height: Ds.space.x4),
                    Text(p.company,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Ds.t.caption),
                    SizedBox(height: Ds.space.x8),
                  ],
                ),
              ),
            ),
        ],
      );
}

class _BodyRow extends StatelessWidget {
  final CompareRow row;
  final double colWidth;
  const _BodyRow({required this.row, required this.colWidth});

  /// The tone is a backend word. Anything it does not recognise falls back to
  /// body text — an unknown tone must never crash a table the customer is
  /// reading mid-decision.
  Color _tone(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.success;
      case 'warning':
        return Ds.c.warning;
      case 'danger':
        return Ds.c.danger;
      case 'info':
        return Ds.c.info;
      default:
        return Ds.c.text;
    }
  }

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: Ds.c.divider)),
        ),
        padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 96,
              child: Text(row.label, style: Ds.t.caption),
            ),
            for (final cell in row.cells)
              SizedBox(
                width: colWidth,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: Ds.space.x4),
                  child: Text(
                    cell.value,
                    style: Ds.t.body.copyWith(
                      // has:false is the backend saying "we do not know this".
                      // It is drawn in the secondary colour so a dash never
                      // reads as a measured value.
                      color: cell.has ? _tone(cell.tone) : Ds.c.textSecondary,
                      fontWeight:
                          cell.has ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}
