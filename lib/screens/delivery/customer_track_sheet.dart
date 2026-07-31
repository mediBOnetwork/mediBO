// lib/screens/delivery/customer_track_sheet.dart — CHANGE #629 (PART F1–F3)
//
// The signed-in customer's Track action, opened from the Orders screen.
//
// WHY THE BUTTON IS ALWAYS OFFERED, AND WHY THAT IS NOT THE APP DECIDING:
// F1 says "when an order has a delivery show a Track action". "Does this order
// have a delivery" is a backend question, and my_orders_screen() — which builds
// the Orders list — does not answer it. The alternatives were to add a second
// RPC per card (two payloads that can disagree, forbidden) or to infer it from
// order.status in Dart (deciding, forbidden). So the action opens the sheet and
// customer_track_order() answers: it returns tracking:false with
// status_label 'Preparing your order' for an order that has no delivery row
// yet, and the catalog's dlv_track_none sentence explains the rest. The app
// never works out whether there is something to track — it asks, and prints.
//
// F1 also requires not_authorized to be handled QUIETLY: it closes with no
// error chrome, because a customer who does not own the order has nothing to be
// told and no accusation to receive.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../fulfill/fulfill_lookups.dart';
import '../../utils/render_log.dart';
import 'delivery_tracking_view.dart';

String _ui(String k) => FulfillLookups.instance.ui(k);

Future<void> showCustomerTrackSheet(BuildContext context, String orderId) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _CustomerTrackSheet(orderId: orderId),
  );
}

class _CustomerTrackSheet extends StatefulWidget {
  final String orderId;
  const _CustomerTrackSheet({required this.orderId});

  @override
  State<_CustomerTrackSheet> createState() => _CustomerTrackSheetState();
}

class _CustomerTrackSheetState extends State<_CustomerTrackSheet> {
  DeliveryTrackingData? _data;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    FulfillLookups.instance.ensureLoaded();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await Supabase.instance.client
          .rpc('customer_track_order', params: {'p_order_id': widget.orderId});
      if (!mounted) return;
      if (res is Map) {
        final m = Map<String, dynamic>.from(res);
        // Quietly: no message, no red box — just close.
        if (m['error']?.toString() == 'not_authorized') {
          RenderLog.write('c629_track_not_authorized', '1');
          Navigator.of(context).maybePop();
          return;
        }
        setState(() {
          _data = DeliveryTrackingData.fromCustomer(m);
          _loading = false;
        });
        return;
      }
      setState(() => _loading = false);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollCtrl) => SingleChildScrollView(
        controller: scrollCtrl,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFE5E7EB),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(_ui('dlv_track_title'),
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
            const SizedBox(height: 14),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (d != null)
              DeliveryTrackingView(data: d, onRefetch: _load),
          ],
        ),
      ),
    );
  }
}
