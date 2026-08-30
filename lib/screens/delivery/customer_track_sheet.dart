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
import '../../design_tokens.dart';

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

  // CHANGE #309 (7) — the rating prompt. The BACKEND decides whether to offer
  // it (delivered, and not already rated); this sheet only draws what it says.
  Map<String, dynamic> _rate = const {};
  int _stars = 0;
  final _commentCtrl = TextEditingController();
  bool _rateBusy = false;
  String _rateDone = '';

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
        await _loadRatePrompt();
        return;
      }
      setState(() => _loading = false);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadRatePrompt() async {
    try {
      final res = await Supabase.instance.client
          .rpc('delivery_rating_prompt', params: {'p_order_id': widget.orderId});
      if (!mounted || res is! Map) return;
      setState(() => _rate = Map<String, dynamic>.from(res));
      if (_rate['show'] == true) RenderLog.write('c309_rate_prompt', 1);
    } catch (_) {}
  }

  Future<void> _submitRating() async {
    if (_stars < 1 || _rateBusy) return;
    setState(() => _rateBusy = true);
    try {
      final res = await Supabase.instance.client.rpc('delivery_rate', params: {
        'p_delivery_id': _rate['delivery_id']?.toString() ?? '',
        'p_stars': _stars,
        'p_comment': _commentCtrl.text.trim().isEmpty ? null : _commentCtrl.text.trim(),
      });
      if (!mounted) return;
      // The confirmation sentence is the backend's, in both the happy case and
      // the already-rated case. Nothing is worded here.
      setState(() {
        _rateDone = (res is Map ? res['message']?.toString() : null) ?? '';
        _rateBusy = false;
      });
      RenderLog.write('c309_rate_submit', _stars);
    } catch (_) {
      if (mounted) setState(() => _rateBusy = false);
    }
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  // CHANGE #309 (7) — five taps, each a 44x44 target.
  Widget _ratingCard() {
    if (_rateDone.isNotEmpty) {
      return Container(
        margin: EdgeInsets.only(top: Ds.space.x24),
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.successSoft,
          borderRadius: Ds.r.rCard,
        ),
        child: Text(_rateDone,
            style: Ds.t.body.copyWith(
                fontWeight: FontWeight.w600, color: Ds.c.success)),
      );
    }
    if (_rate['show'] != true) return const SizedBox.shrink();

    return Container(
      margin: EdgeInsets.only(top: Ds.space.x24),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        border: Border.all(color: Ds.c.divider),
        borderRadius: Ds.r.rCard,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_rate['title']?.toString() ?? '', style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x4),
        Text(_rate['hint']?.toString() ?? '', style: Ds.t.caption),
        SizedBox(height: Ds.space.x12),
        Row(children: [
          for (var i = 1; i <= 5; i++)
            InkWell(
              onTap: () => setState(() => _stars = i),
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  i <= _stars ? Icons.star_rounded : Icons.star_outline_rounded,
                  size: 30,
                  color: i <= _stars ? Ds.c.brand : Ds.c.textSecondary,
                ),
              ),
            ),
        ]),
        SizedBox(height: Ds.space.x12),
        TextField(
          controller: _commentCtrl,
          maxLines: 2,
          decoration: InputDecoration(
            hintText: _rate['comment_hint']?.toString() ?? '',
            filled: true,
            fillColor: Ds.c.bg,
            border: OutlineInputBorder(
              borderRadius: Ds.r.rButton,
              borderSide: BorderSide(color: Ds.c.divider),
            ),
          ),
        ),
        SizedBox(height: Ds.space.x16),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Ds.c.brand,
              foregroundColor: Ds.c.surface,
              disabledBackgroundColor: Ds.c.divider,
            ),
            // Disabled until a star is chosen: a rating with no stars is not a
            // rating, and the backend would refuse it anyway.
            onPressed: (_stars > 0 && !_rateBusy) ? _submitRating : null,
            child: Text(_rate['submit_label']?.toString() ?? '',
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
      ]),
    );
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
            if (!_loading) _ratingCard(),
          ],
        ),
      ),
    );
  }
}
