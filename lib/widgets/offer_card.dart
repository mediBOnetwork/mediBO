import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// One offer in the customer Offers feed.
///
/// The card DECIDES NOTHING. Every word on it — the action button's label, the
/// "12 units left" line, the type badge, the sold-out state, the "you order
/// this" chip — arrives in the `offers_feed` row and is printed verbatim. The
/// only thing Dart does here is choose which callback a tap fires, and even
/// that follows the backend's `can_waitlist` flag rather than a qty number.
class OfferCard extends StatelessWidget {
  final Map<String, dynamic> row;

  /// Fired when the backend's action is "add to cart".
  final VoidCallback onAdd;

  /// Fired when the backend's action is "join the waitlist".
  final VoidCallback onWaitlist;

  /// True while this card's RPC is in flight.
  final bool busy;

  const OfferCard({
    super.key,
    required this.row,
    required this.onAdd,
    required this.onWaitlist,
    this.busy = false,
  });

  static Color _hex(String? value, Color fallback) {
    if (value == null || value.length < 7) return fallback;
    final parsed = int.tryParse(value.replaceFirst('#', 'FF'), radix: 16);
    return parsed == null ? fallback : Color(parsed);
  }

  String _s(String key) => row[key] as String? ?? '';

  bool get _soldOut => row['sold_out'] == true;
  bool get _canWaitlist => row['can_waitlist'] == true;
  bool get _enabled => row['action_enabled'] != false;

  @override
  Widget build(BuildContext context) {
    final badge = (row['type_badge'] as Map?) ?? const {};

    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (badge.isNotEmpty)
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x8, vertical: Ds.space.x4),
              decoration: BoxDecoration(
                color: _hex(badge['bg'] as String?, Ds.c.infoSoft),
                borderRadius: Ds.r.rChip,
              ),
              child: Text(badge['label'] as String? ?? '',
                  style: Ds.t.caption.copyWith(
                      color: _hex(badge['fg'] as String?, Ds.c.info),
                      fontWeight: FontWeight.w600)),
            ),
          if (_s('match_label').isNotEmpty) ...[
            SizedBox(width: Ds.space.x8),
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x8, vertical: Ds.space.x4),
              decoration: BoxDecoration(
                  color: Ds.c.successSoft, borderRadius: Ds.r.rChip),
              child: Text(_s('match_label'),
                  style: Ds.t.caption.copyWith(
                      color: Ds.c.success, fontWeight: FontWeight.w600)),
            ),
          ],
          const Spacer(),
          if (_s('discount_label').isNotEmpty)
            Text(_s('discount_label'),
                style: Ds.t.caption
                    .copyWith(color: Ds.c.brand, fontWeight: FontWeight.w700)),
        ]),
        SizedBox(height: Ds.space.x8),
        Text(_s('product_name'),
            style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
        if (_s('company').isNotEmpty)
          Text(_s('company'),
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
        if (_s('pack').isNotEmpty)
          Text(_s('pack'),
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
        SizedBox(height: Ds.space.x8),
        Row(children: [
          if (_s('price_display').isNotEmpty)
            Text(_s('price_display'),
                style: Ds.t.subtitle
                    .copyWith(color: Ds.c.brand, fontWeight: FontWeight.w700)),
          SizedBox(width: Ds.space.x8),
          if (_s('mrp_display').isNotEmpty)
            Text(_s('mrp_display'),
                style: Ds.t.caption.copyWith(
                    decoration: TextDecoration.lineThrough,
                    color: Ds.c.textSecondary)),
        ]),
        if (_s('scheme_text').isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x4),
            child: Text(_s('scheme_text'),
                style: Ds.t.caption
                    .copyWith(color: Ds.c.brand, fontWeight: FontWeight.w600)),
          ),
        if (_s('near_expiry_label').isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x4),
            child: Text(
                '${_s('near_expiry_label')}'
                '${_s('expiry_date_display').isEmpty ? '' : ' · ${_s('expiry_date_display')}'}',
                style: Ds.t.caption.copyWith(color: Ds.c.warning)),
          ),
        if (_s('end_date_display').isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x4),
            child: Text(_s('end_date_display'),
                style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          ),
        SizedBox(height: Ds.space.x12),
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_s('qty_display'),
                  style: Ds.t.caption.copyWith(
                      color: row['qty_low'] == true || _soldOut
                          ? Ds.c.warning
                          : Ds.c.textSecondary)),
              if (_s('seller_display').isNotEmpty)
                Text(_s('seller_display'),
                    style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
            ]),
          ),
          SizedBox(
            height: 44,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _canWaitlist ? Ds.c.surface : Ds.c.brand,
                foregroundColor: _canWaitlist ? Ds.c.brand : Colors.white,
                side: _canWaitlist ? BorderSide(color: Ds.c.brand) : null,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
              ),
              onPressed: (!_enabled || busy)
                  ? null
                  : (_canWaitlist ? onWaitlist : onAdd),
              child: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(_s('action_label')),
            ),
          ),
        ]),
      ]),
    );
  }
}
