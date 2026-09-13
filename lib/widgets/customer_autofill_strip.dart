// lib/widgets/customer_autofill_strip.dart — CHANGE #1888
//
// How complete the customer book actually is, printed above the customer list.
//
// The change that added this exists because nobody could see the hole: 10 of
// 12 shops had no GPS pin, 11 had no maps link, 8 had no district, and the
// only way to know was to read the table. This strip is that number, on the
// screen, every time somebody opens Customers.
//
// It computes nothing. customer_autofill_status() counts the rows — inside
// admin_active_zone() and admin_active_date(), so a partner sees its own zone
// — and decides each line's tone. This widget prints the label, the value and
// paints the tone.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';

class CustomerAutofillStrip extends StatefulWidget {
  const CustomerAutofillStrip({super.key, required this.padding});

  final EdgeInsets padding;

  @override
  State<CustomerAutofillStrip> createState() => _CustomerAutofillStripState();
}

class _CustomerAutofillStripState extends State<CustomerAutofillStrip> {
  Map<String, dynamic>? _p;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await Supabase.instance.client
          .rpc('customer_autofill_status', params: {'p': const {}});
      if (!mounted) return;
      setState(() =>
          _p = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{});
      RenderLog.write('c1888_autofill_strip',
          ((_p?['rows'] as List?) ?? const []).length.toString());
    } catch (_) {
      // A count that cannot be read must not take the customer list down.
    }
  }

  Color _bg(String tone) => switch (tone) {
        'success' => Ds.c.successSoft,
        'danger' => Ds.c.dangerSoft,
        'info' => Ds.c.infoSoft,
        _ => Ds.c.warningSoft,
      };

  @override
  Widget build(BuildContext context) {
    final p = _p;
    if (p == null || p['ok'] != true) return const SizedBox.shrink();
    final rows = ((p['rows'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    if (rows.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: widget.padding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${(p['title'] ?? '').toString()} · ${(p['as_of'] ?? '').toString()}',
            style: Ds.t.caption),
        SizedBox(height: Ds.space.x8),
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [
            for (final r in rows)
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x12, vertical: Ds.space.x8),
                decoration: BoxDecoration(
                  color: _bg((r['tone'] ?? '').toString()),
                  borderRadius: Ds.r.rChip,
                ),
                child: Text(
                  '${(r['label'] ?? '').toString()} · ${(r['value'] ?? '').toString()}',
                  style: Ds.t.caption,
                ),
              ),
          ],
        ),
      ]),
    );
  }
}
