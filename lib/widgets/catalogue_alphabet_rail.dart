import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design_tokens.dart';
import '../models/catalogue.dart';

/// CHANGE #799 — the A–Z rail down the right edge of the company list.
///
/// The track is EVERY letter the backend sent, always, with `enabled` saying
/// which ones have companies behind them. A rail that grows and shrinks as the
/// list filters is a rail nobody can learn the shape of — and drag-to-jump
/// needs a track whose geometry does not move under the thumb.
///
/// It decides nothing: the letters, their order, their labels and the "All"
/// word all arrive in `catalogue_companies().rail`. What lives here is the
/// GESTURE — which letter the finger is currently over — because that is a
/// pointer position and not a business fact.
class CatalogueAlphabetRail extends StatefulWidget {
  final CatRail rail;

  /// The letter currently applied, or null for "All".
  final String? active;

  /// Called with the letter key, or null for "All".
  final ValueChanged<String?> onPick;

  const CatalogueAlphabetRail({
    super.key,
    required this.rail,
    required this.active,
    required this.onPick,
  });

  static const double width = 24;
  static const double _rowH = 15;
  static const double _bubble = 44;

  @override
  State<CatalogueAlphabetRail> createState() => _CatalogueAlphabetRailState();
}

class _CatalogueAlphabetRailState extends State<CatalogueAlphabetRail> {
  /// The letter under the finger during a drag. Null when nothing is dragging.
  String? _dragging;

  void _handle(Offset local, double height) {
    final letters = widget.rail.letters;
    if (letters.isEmpty || height <= 0) return;
    final i = (local.dy / height * letters.length).floor().clamp(0, letters.length - 1);
    final l = letters[i];
    if (!l.enabled || l.key == _dragging) return;
    HapticFeedback.selectionClick();
    setState(() => _dragging = l.key);
    widget.onPick(l.key);
  }

  @override
  Widget build(BuildContext context) {
    final letters = widget.rail.letters;
    if (letters.isEmpty) return const SizedBox.shrink();
    final shown = _dragging ?? widget.active;

    return LayoutBuilder(builder: (context, c) {
      final h = c.maxHeight;
      return Stack(
        clipBehavior: Clip.none,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (d) => _handle(d.localPosition, h),
            onVerticalDragUpdate: (d) => _handle(d.localPosition, h),
            onVerticalDragEnd: (_) => setState(() => _dragging = null),
            onVerticalDragCancel: () => setState(() => _dragging = null),
            onTapDown: (d) => _handle(d.localPosition, h),
            onTapUp: (_) => setState(() => _dragging = null),
            child: SizedBox(
              width: CatalogueAlphabetRail.width,
              height: h,
              child: Semantics(
                label: widget.rail.label,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final l in letters)
                      SizedBox(
                        height: CatalogueAlphabetRail._rowH,
                        child: Center(
                          child: Text(
                            l.label,
                            style: Ds.t.caption.copyWith(
                              color: !l.enabled
                                  ? Ds.c.divider
                                  : (l.key == shown ? Ds.c.brand : Ds.c.textSecondary),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          // The bubble that follows the thumb. It only exists while a drag is
          // live, so nothing hovers over the list at rest.
          if (_dragging != null)
            Positioned(
              right: CatalogueAlphabetRail.width,
              top: _bubbleTop(h, letters),
              child: Container(
                width: CatalogueAlphabetRail._bubble,
                height: CatalogueAlphabetRail._bubble,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Ds.c.brand,
                  borderRadius: Ds.r.rChip,
                  boxShadow: Ds.elevation.e2,
                ),
                child: Text(_dragging!,
                    style: Ds.t.title.copyWith(color: Ds.c.surface)),
              ),
            ),
        ],
      );
    });
  }

  double _bubbleTop(double h, List<CatRailLetter> letters) {
    final i = letters.indexWhere((l) => l.key == _dragging);
    if (i < 0) return 0;
    final centre = (i + 0.5) / letters.length * h;
    return (centre - CatalogueAlphabetRail._bubble / 2)
        .clamp(0.0, (h - CatalogueAlphabetRail._bubble).clamp(0.0, h));
  }
}
