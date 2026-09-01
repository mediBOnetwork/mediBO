// CHANGE #414 — the counter margin finder.
//
// The patient asks for a brand. It is on the shelf. This strip answers one
// question: is there another brand of the SAME SALT, also on the shelf, that
// this pharmacy earns more on?
//
// Every part of that answer is the backend's. The strip does not know what
// "same salt" means, does not compute a margin, does not rank anything, and
// does not decide whether a row is worth showing — `pos_margin_options()`
// returns rows already ranked by real landed margin, already worded ("₹2.10
// more margin"), and already filtered to what is actually in stock with a
// recorded cost. A row with no real cost never arrives here at all.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

String _ms(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

List<Map<String, dynamic>> _mrows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const <Map<String, dynamic>>[];

/// The pure view. Hand it a `pos_margin_options()` payload; it draws it.
class PosMarginStrip extends StatelessWidget {
  final Map<String, dynamic> payload;
  final void Function(Map<String, dynamic> row) onSwap;

  const PosMarginStrip({
    super.key,
    required this.payload,
    required this.onSwap,
  });

  @override
  Widget build(BuildContext context) {
    // `has` is the backend's flag, not `rows.isEmpty`: it is the one that knows
    // whether silence is the right answer.
    if (payload['has'] != true) return const SizedBox.shrink();
    final rows = _mrows(payload['rows']);
    if (rows.isEmpty) return const SizedBox.shrink();
    RenderLog.write('c414_margin_rows', rows.length);

    return Container(
      margin: EdgeInsets.only(top: Ds.space.x12),
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: Ds.c.successSoft,
        borderRadius: Ds.r.rCard,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_ms(payload, 'title'),
              style: Ds.t.bodyStrong.copyWith(color: Ds.c.success)),
          if (_ms(payload, 'subtitle').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_ms(payload, 'subtitle'), style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x12),
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) SizedBox(height: Ds.space.x8),
            _MarginRow(row: rows[i], onSwap: () => onSwap(rows[i])),
          ],
        ],
      ),
    );
  }
}

class _MarginRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback onSwap;
  const _MarginRow({required this.row, required this.onSwap});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rButton,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_ms(row, 'product_name'), style: Ds.t.body),
                if (_ms(row, 'company').isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(_ms(row, 'company'), style: Ds.t.caption),
                ],
                SizedBox(height: Ds.space.x4),
                Row(
                  children: [
                    // The comparison IS the reason this row is on screen, so it
                    // is the backend's sentence, printed whole.
                    if (_ms(row, 'delta_display').isNotEmpty)
                      Text(_ms(row, 'delta_display'),
                          style: Ds.t.caption.copyWith(color: Ds.c.success)),
                    if (_ms(row, 'delta_display').isNotEmpty &&
                        _ms(row, 'stock_display').isNotEmpty)
                      Text(' · ', style: Ds.t.caption),
                    if (_ms(row, 'stock_display').isNotEmpty)
                      Text(_ms(row, 'stock_display'), style: Ds.t.caption),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(width: Ds.space.x8),
          // A margin is printed only where the backend says one exists. There
          // is no fallback figure here, because an estimated margin is worse
          // than none: the owner would act on it.
          if (row['has_margin'] == true &&
              _ms(row, 'margin_display').isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(_ms(row, 'margin_label'), style: Ds.t.caption),
                Text(_ms(row, 'margin_display'), style: Ds.t.bodyStrong),
              ],
            ),
          SizedBox(width: Ds.space.x12),
          SizedBox(
            height: Ds.touch.minTarget,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Ds.c.brand),
                foregroundColor: Ds.c.brand,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              onPressed: onSwap,
              child: Text(_ms(row, 'swap_label')),
            ),
          ),
        ],
      ),
    );
  }
}
