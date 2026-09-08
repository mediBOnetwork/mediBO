// CHANGE #293 — the Payment and Partner screen's payment block.
//
// ONE switch for the whole platform (`payment_config.collection_mode`), the
// backend's own statement of where the money lands, and the zone + date
// collection summary — all three drawn straight from `payment_mode_get()`.
//
// This widget decides nothing. Every label, helper, amount and mode name is a
// string the RPC already finished; it does not know what "gateway" means, it
// only knows which option carries `selected: true`. Re-wording the screen is
// an UPDATE to razorpay_copy, not a deploy.
import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// Renders `payment_mode_get()` verbatim.
///
/// [payload] is the whole RPC reply. [onPick] receives the backend's own option
/// key (never a boolean). [onEditGateway] opens the settlement-details editor;
/// it is offered only when the backend says `money_lands.can_edit`.
class PaymentModeCard extends StatelessWidget {
  final Map<String, dynamic> payload;
  final bool busy;
  final ValueChanged<String> onPick;
  final VoidCallback? onEditGateway;

  const PaymentModeCard({
    super.key,
    required this.payload,
    required this.onPick,
    this.busy = false,
    this.onEditGateway,
  });

  static String _s(Object? v) => (v ?? '').toString();

  static List<Map<String, dynamic>> _rows(Object? v) => v is List
      ? v
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList(growable: false)
      : const <Map<String, dynamic>>[];

  static Map<String, dynamic> _map(Object? v) =>
      v is Map ? v.cast<String, dynamic>() : const <String, dynamic>{};

  @override
  Widget build(BuildContext context) {
    final canEdit = payload['can_edit'] == true;
    final options = _rows(payload['options']);
    final tone = _s(payload['mode_tone']);
    final lands = _map(payload['money_lands']);
    final collection = _map(payload['collection']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _shell(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(child: Text(_s(payload['title']), style: Ds.t.subtitle)),
                _chip(_s(payload['mode_label']),
                    tone == 'ok' ? Ds.c.successSoft : Ds.c.warningSoft),
              ]),
              SizedBox(height: Ds.space.x8),
              Text(_s(payload['helper']), style: Ds.t.caption),
              SizedBox(height: Ds.space.x16),
              for (final o in options) ...[
                _ModeOption(
                  label: _s(o['label']),
                  helper: _s(o['helper']),
                  selected: o['selected'] == true,
                  enabled: canEdit && !busy,
                  onTap: () => onPick(_s(o['key'])),
                ),
                SizedBox(height: Ds.space.x8),
              ],
              if (busy)
                Padding(
                  padding: EdgeInsets.only(top: Ds.space.x8),
                  child: SizedBox(
                    width: Ds.space.x24,
                    height: Ds.space.x24,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Ds.c.brand),
                  ),
                ),
            ],
          ),
        ),
        if (lands.isNotEmpty) ...[
          SizedBox(height: Ds.space.x16),
          _landsCard(lands),
        ],
        if (collection.isNotEmpty) ...[
          SizedBox(height: Ds.space.x16),
          _collectionCard(collection),
        ],
      ],
    );
  }

  // ── where the money lands ────────────────────────────────────────────────
  Widget _landsCard(Map<String, dynamic> lands) {
    final rows = _rows(lands['rows']);
    final note = _s(lands['note']);
    return _shell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(_s(lands['title']), style: Ds.t.subtitle)),
            if (lands['can_edit'] == true &&
                onEditGateway != null &&
                _s(lands['edit_label']).isNotEmpty)
              TextButton(
                onPressed: onEditGateway,
                child: Text(_s(lands['edit_label'])),
              ),
          ]),
          SizedBox(height: Ds.space.x4),
          Text(_s(lands['caption']), style: Ds.t.caption),
          if (note.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(note, style: Ds.t.caption),
          ],
          if (rows.isNotEmpty) SizedBox(height: Ds.space.x12),
          for (final r in rows)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Text(_s(r['label']), style: Ds.t.caption)),
                  SizedBox(width: Ds.space.x12),
                  Flexible(
                    child: Text(_s(r['value']),
                        textAlign: TextAlign.right, style: Ds.t.bodyStrong),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ── zone + date collection summary ───────────────────────────────────────
  Widget _collectionCard(Map<String, dynamic> col) {
    final modes = _rows(col['modes']);
    final empty = col['is_empty'] == true;
    return _shell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(_s(col['title']), style: Ds.t.subtitle)),
            _chip(_s(col['zone_label']), Ds.c.infoSoft),
            SizedBox(width: Ds.space.x8),
            _chip(_s(col['date_label']), Ds.c.brandSoft),
          ]),
          SizedBox(height: Ds.space.x16),
          Row(children: [
            Expanded(
              child: _stat(_s(col['total_label']), _s(col['total_display'])),
            ),
            Expanded(
              child: _stat(_s(col['orders_label']), _s(col['orders_count'])),
            ),
          ]),
          SizedBox(height: Ds.space.x12),
          Row(children: [
            Expanded(
              child:
                  _stat(_s(col['verified_label']), _s(col['verified_display'])),
            ),
            Expanded(
              child:
                  _stat(_s(col['pending_label']), _s(col['pending_display'])),
            ),
          ]),
          if (modes.isNotEmpty) SizedBox(height: Ds.space.x16),
          for (final m in modes)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x8),
              child: Row(children: [
                Expanded(child: Text(_s(m['label']), style: Ds.t.body)),
                Text(_s(m['amount_display']), style: Ds.t.bodyStrong),
              ]),
            ),
          if (empty) ...[
            SizedBox(height: Ds.space.x8),
            Text(_s(col['empty_label']), style: Ds.t.caption),
          ],
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Text(value, style: Ds.t.subtitle),
        ],
      );

  Widget _chip(String text, Color bg) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x4),
        decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
        child: Text(text, style: Ds.t.caption),
      );

  Widget _shell({required Widget child}) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
        ),
        child: child,
      );
}

/// One selectable collection mode. A radio, not a switch: the spec is a
/// two-option selector, and a boolean cannot grow a third payment provider.
class _ModeOption extends StatelessWidget {
  final String label;
  final String helper;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _ModeOption({
    required this.label,
    required this.helper,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: Ds.r.rCard,
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(
          color: selected ? Ds.c.brandSoft : Ds.c.bg,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: selected ? Ds.c.brand : Ds.c.divider),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? Ds.c.brand : Ds.c.textSecondary,
            ),
            SizedBox(width: Ds.space.x12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Ds.t.bodyStrong),
                  if (helper.isNotEmpty) ...[
                    SizedBox(height: Ds.space.x4),
                    Text(helper, style: Ds.t.caption),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
