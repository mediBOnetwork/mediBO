import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import 'dev_queue_common.dart';

/// The deploy-lock card (CMD #1940 built the payload, CMD #1990 wired it).
///
/// Every word here is `dev_ctl_get().deploy_wait`, rendered verbatim: the
/// holder line, the reservation line while a woken waiter still has its 60 s to
/// take the lock itself, and one row per sleeping waiter. Nothing is computed,
/// worded, pluralised or toned in Dart.
class DeployLockCard extends StatelessWidget {
  final Map<String, dynamic> card;
  const DeployLockCard({super.key, required this.card});

  static Map<String, dynamic> _m(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  static String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    if ((card['has'] ?? false) != true) return const SizedBox.shrink();
    final holder = _m(card['holder']);
    final intervals = _m(card['intervals']);
    final reserved = _s(holder, 'reserved_label');
    final reservedDetail = _s(holder, 'reserved_detail');
    final waiters = (card['waiters'] as List?) ?? const <dynamic>[];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_s(card, 'title'), style: Ds.t.subtitle),
      SizedBox(height: Ds.space.x8),
      // Holder + reservation ride in a Wrap so 360 px never overflows.
      Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x8, children: [
        ToneChip(
            label: _s(holder, 'label'),
            tone: toneByName(_s(holder, 'tone')),
            icon: Icons.lock_outline),
        if (reserved.isNotEmpty)
          ToneChip(
              label: reserved,
              tone: toneByName(_s(holder, 'reserved_tone')),
              icon: Icons.hourglass_bottom),
      ]),
      if (_s(holder, 'detail').isNotEmpty) ...[
        SizedBox(height: Ds.space.x8),
        Text(_s(holder, 'detail'), style: Ds.t.caption),
      ],
      if (reservedDetail.isNotEmpty) ...[
        SizedBox(height: Ds.space.x4),
        Text(reservedDetail, style: Ds.t.caption),
      ],
      SizedBox(height: Ds.space.x12),
      Text(_s(card, 'count_label'), style: Ds.t.caption),
      for (final w in waiters) _waiterRow(_m(w)),
      if (_s(intervals, 'push_label').isNotEmpty) ...[
        SizedBox(height: Ds.space.x12),
        Text(_s(intervals, 'push_label'), style: Ds.t.caption),
      ],
    ]);
  }

  Widget _waiterRow(Map<String, dynamic> w) => Padding(
        padding: EdgeInsets.only(top: Ds.space.x12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: EdgeInsets.only(right: Ds.space.x8),
            child: ToneChip(
                label: _s(w, 'position_label').isEmpty
                    ? _s(w, 'kind_label')
                    : _s(w, 'position_label'),
                tone: toneByName(_s(w, 'tone'))),
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_s(w, 'label'), style: Ds.t.body),
              if (_s(w, 'detail').isNotEmpty)
                Text(_s(w, 'detail'), style: Ds.t.caption),
            ]),
          ),
        ]),
      );
}
