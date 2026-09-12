import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../design_tokens.dart';
import '../../../utils/render_log.dart';
import '../../../utils/toast.dart';

/// The monthly cloud waste scan, rendered from `dev_gcp_get().waste`.
///
/// cmd #433. Every string on this card is a backend string: the title, the
/// group headings, each row's label, each rupee amount, the empty states, the
/// footer. Dart adds up nothing and words nothing — `cloud_waste_compose()`
/// prices the whole thing from `cloud_waste_rates`, so changing a rate or a
/// sentence is an UPDATE and never a deploy.
///
/// The one distinction the card DOES draw is a group the scan was not allowed
/// to read: `blocked` comes from the payload, and it exists so an IAM refusal
/// can never be painted as a clean bill of health. It gets the warning tint and
/// the backend's refusal sentence, not the green "nothing found" line.
class DevQueueWasteCard extends StatelessWidget {
  final Map<String, dynamic> waste;
  final bool busy;
  final VoidCallback onScan;

  const DevQueueWasteCard({
    super.key,
    required this.waste,
    required this.busy,
    required this.onScan,
  });

  List<Map<String, dynamic>> get _groups => (waste['groups'] as List?)
          ?.whereType<Map>()
          .map((g) => g.cast<String, dynamic>())
          .toList() ??
      const [];

  String _s(Object? v) => v == null ? '' : v.toString();

  @override
  Widget build(BuildContext context) {
    final has = waste['has'] == true;
    final groups = _groups;
    RenderLog.write('waste_groups', groups.length);
    RenderLog.write(
        'waste_rows',
        groups.fold<int>(
            0, (n, g) => n + ((g['rows'] as List?)?.length ?? 0)));

    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_s(waste['title']), style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x4),
              Text(_s(waste['subtitle']), style: Ds.t.caption),
            ]),
          ),
          SizedBox(width: Ds.space.x12),
          OutlinedButton(
            onPressed: busy ? null : onScan,
            style: OutlinedButton.styleFrom(
              minimumSize: Size(Ds.touch.minTarget * 2, Ds.touch.minTarget),
              side: BorderSide(color: Ds.c.brand),
              shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
            ),
            child: Text(_s(waste['button']),
                style: Ds.t.body.copyWith(color: Ds.c.brand)),
          ),
        ]),
        if (!has) ...[
          SizedBox(height: Ds.space.x16),
          Text(_s(waste['empty_label']), style: Ds.t.bodySecondary),
        ] else ...[
          SizedBox(height: Ds.space.x16),
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(Ds.space.x12),
            decoration: BoxDecoration(
                color: Ds.c.brandSoft, borderRadius: Ds.r.rChip),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_s(waste['total_display']), style: Ds.t.body),
              if (_s(waste['ran_label']).isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(_s(waste['ran_label']), style: Ds.t.caption),
              ],
            ]),
          ),
          for (final g in groups) ...[
            SizedBox(height: Ds.space.x24),
            _group(context, g),
          ],
          if (_s(waste['blocked']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x24),
            _band(context, _s(waste['blocked']), Ds.c.warningSoft),
          ],
          if (_s(waste['warning']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            _band(context, _s(waste['warning']), Ds.c.warningSoft),
          ],
          SizedBox(height: Ds.space.x24),
          Text(_s(waste['footer']), style: Ds.t.caption),
        ],
      ]),
    );
  }

  Widget _band(BuildContext context, String text, Color bg) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
        child: Text(text, style: Ds.t.caption),
      );

  Widget _group(BuildContext context, Map<String, dynamic> g) {
    final rows = (g['rows'] as List?)
            ?.whereType<Map>()
            .map((r) => r.cast<String, dynamic>())
            .toList() ??
        const [];
    final blocked = g['blocked'] == true;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(_s(g['title']), style: Ds.t.body)),
        SizedBox(width: Ds.space.x8),
        // Right-aligned money, as every number on every screen is.
        Text(_s(g['subtotal_display']), style: Ds.t.body),
      ]),
      if (rows.isEmpty) ...[
        SizedBox(height: Ds.space.x8),
        blocked
            ? _band(context, _s(g['empty_label']), Ds.c.warningSoft)
            : Text(_s(g['empty_label']), style: Ds.t.caption),
      ] else
        for (final r in rows) ...[
          SizedBox(height: Ds.space.x8),
          _row(context, r),
        ],
      if (_s(g['note']).isNotEmpty) ...[
        SizedBox(height: Ds.space.x8),
        Text(_s(g['note']), style: Ds.t.caption),
      ],
    ]);
  }

  Widget _row(BuildContext context, Map<String, dynamic> r) {
    final copy = _s(r['copy_text']);
    return InkWell(
      borderRadius: Ds.r.rChip,
      onTap: copy.isEmpty
          ? null
          : () {
              Clipboard.setData(ClipboardData(text: copy));
              showToast(context, copy);
            },
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x8),
        decoration:
            BoxDecoration(color: Ds.c.bg, borderRadius: Ds.r.rChip),
        child: Row(children: [
          Expanded(child: Text(_s(r['label']), style: Ds.t.caption)),
          SizedBox(width: Ds.space.x8),
          Text(_s(r['amount_display']), style: Ds.t.caption),
        ]),
      ),
    );
  }
}
