// lib/screens/delivery/delivery_history_sheet.dart — CHANGE #630 (PART D)
//
// D1 — my_delivery_history() -> {title, days[]}, each day carrying date_label,
// delivered, failed, total and earning_display. A simple list, printed.
//
// p_days is NOT sent. The RPC's own default is 14 and its `title` is composed
// from whatever it used ("Last 14 days"), so naming the number here would let
// the app and the heading disagree about the window — and would put a config
// value in Dart. The backend owns the window and the sentence describing it.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../fulfill/fulfill_lookups.dart';
import '../../utils/render_log.dart';

Color get _kBorder => FulfillLookups.instance.color('c_ffe5e7eb', const Color(0xFFE5E7EB));
Color get _kText => FulfillLookups.instance.color('c_ff111827', const Color(0xFF111827));
Color get _kSub => FulfillLookups.instance.color('c_ff6b7280', const Color(0xFF6B7280));

String _ui(String k) => FulfillLookups.instance.ui(k);

Future<void> showDeliveryHistorySheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _DeliveryHistorySheet(),
  );
}

class _DeliveryHistorySheet extends StatefulWidget {
  const _DeliveryHistorySheet();

  @override
  State<_DeliveryHistorySheet> createState() => _DeliveryHistorySheetState();
}

class _DeliveryHistorySheetState extends State<_DeliveryHistorySheet> {
  bool _loading = true;
  Map<String, dynamic> _payload = const {};

  List<Map<String, dynamic>> get _days => _payload['days'] is List
      ? (_payload['days'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList()
      : const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await Supabase.instance.client.rpc('my_delivery_history');
      if (!mounted) return;
      setState(() {
        _payload = res is Map ? Map<String, dynamic>.from(res) : const {};
        _loading = false;
      });
      RenderLog.write('c630_delivery_onboarding', 'history;days=${_days.length}');
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      builder: (context, ctrl) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFFF5F6F8),
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: ListView(
          controller: ctrl,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: _kBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // The heading is the backend's ("Last 14 days"), not a Dart string.
            Text(_payload['title']?.toString() ?? _ui('dlv_history'),
                style:
                    TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _kText)),
            const SizedBox(height: 12),

            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_days.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Text(_ui('dlv_no_history'),
                      style: TextStyle(fontSize: 13, color: _kSub)),
                ),
              )
            else
              for (final d in _days) _dayRow(d),
          ],
        ),
      ),
    );
  }

  Widget _dayRow(Map<String, dynamic> d) {
    // delivered / failed / total are counts the backend produced; the labels
    // beside them are the same tile labels the rest of the delivery UI uses.
    final line = [
      '${(d['delivered'] as num?)?.toInt() ?? 0} ${_ui('dlv_tile_delivered')}',
      '${(d['failed'] as num?)?.toInt() ?? 0} ${_ui('dlv_tile_failed')}',
      '${(d['total'] as num?)?.toInt() ?? 0} ${_ui('dlv_tile_total')}',
    ].join(' · ');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(d['date_label']?.toString() ?? '',
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600, color: _kText)),
            const SizedBox(height: 2),
            Text(line, style: TextStyle(fontSize: 12.5, color: _kSub)),
          ]),
        ),
        const SizedBox(width: 8),
        // Already an ₹ string from the backend — never formatted here.
        Text(d['earning_display']?.toString() ?? '',
            style:
                TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _kText)),
      ]),
    );
  }
}
