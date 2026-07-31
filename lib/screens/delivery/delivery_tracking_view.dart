// lib/screens/delivery/delivery_tracking_view.dart — CHANGE #629 (PART F)
//
// ONE tracking view, rendered by both places the spec asks for it:
//   • the signed-in customer's Track action   -> customer_track_order()
//   • the public /track/{token} page (F4)     -> delivery_track_public()
// F4 says "Same tracking view", so there is one widget and two callers, not two
// screens that will drift apart.
//
// The two RPCs answer the same question in two shapes: customer_track_order()
// returns SQL nulls (rider_lat null when the run has not started), while
// delivery_track_public() — a public endpoint, so it obeys "never null in a
// payload" strictly — returns 0 alongside an explicit has_rider_location /
// has_destination / has_stops_ahead boolean.
//
// THAT DISTINCTION IS PRESERVED, NOT FLATTENED. [DeliveryTrackingData] carries
// the backend's own presence booleans; where the customer payload has no such
// boolean, presence is read from the field the backend nulls FOR that purpose
// (rider_lat is null exactly when there is no rider position to show — that is
// the backend encoding absence, not the app inferring it). Nothing here turns a
// missing coordinate into a message, a colour or a status: every user-facing
// string on this screen arrived finished.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../fulfill/fulfill_lookups.dart';
import '../../utils/render_log.dart';
import 'delivery_run_map_panel.dart';

Color get _kText => FulfillLookups.instance.color('c_ff111827', const Color(0xFF111827));
Color get _kSub => FulfillLookups.instance.color('c_ff6b7280', const Color(0xFF6B7280));
Color get _kBorder => FulfillLookups.instance.color('c_ffe5e7eb', const Color(0xFFE5E7EB));

String _ui(String k) => FulfillLookups.instance.ui(k);

/// The tracking payload, in the one shape this view renders. Every field is
/// something a backend said; none is computed.
class DeliveryTrackingData {
  final bool ok;
  final bool found;
  final bool tracking;
  final String statusLabel;
  final String partnerName;
  final String orderCode;

  final String stopsAheadLabel;
  final bool hasStopsAhead;

  final double riderLat;
  final double riderLng;
  final bool hasRiderLocation;

  final double destLat;
  final double destLng;
  final bool hasDestination;

  final String qrToken;

  /// Present only on the public payload; '' elsewhere.
  final String title;
  final String message;

  const DeliveryTrackingData({
    required this.ok,
    required this.found,
    required this.tracking,
    required this.statusLabel,
    required this.partnerName,
    required this.orderCode,
    required this.stopsAheadLabel,
    required this.hasStopsAhead,
    required this.riderLat,
    required this.riderLng,
    required this.hasRiderLocation,
    required this.destLat,
    required this.destLng,
    required this.hasDestination,
    required this.qrToken,
    required this.title,
    required this.message,
  });

  static double _d(dynamic v) => (v as num?)?.toDouble() ?? 0;
  static String _s(dynamic v) => v?.toString() ?? '';

  /// customer_track_order() — nulls mean "nothing to show", which is the
  /// backend's own encoding of absence for this RPC.
  factory DeliveryTrackingData.fromCustomer(Map<String, dynamic> m) {
    final riderLat = m['rider_lat'] as num?;
    final riderLng = m['rider_lng'] as num?;
    final destLat = m['destination_lat'] as num?;
    final destLng = m['destination_lng'] as num?;
    final ahead = _s(m['stops_ahead_label']);
    return DeliveryTrackingData(
      ok: m['ok'] == true,
      // The customer RPC has no `found` — reaching it at all means the order
      // resolved. not_authorized is handled by the caller before this point.
      found: m['ok'] == true,
      tracking: m['tracking'] == true,
      statusLabel: _s(m['status_label']),
      partnerName: _s(m['partner_name']),
      orderCode: '',
      stopsAheadLabel: ahead,
      hasStopsAhead: ahead.isNotEmpty,
      riderLat: riderLat?.toDouble() ?? 0,
      riderLng: riderLng?.toDouble() ?? 0,
      hasRiderLocation: riderLat != null && riderLng != null,
      destLat: destLat?.toDouble() ?? 0,
      destLng: destLng?.toDouble() ?? 0,
      hasDestination: destLat != null && destLng != null,
      qrToken: _s(m['qr_token']),
      title: '',
      message: '',
    );
  }

  /// delivery_track_public() — never null, and carries its own has_* booleans.
  factory DeliveryTrackingData.fromPublic(Map<String, dynamic> m) {
    return DeliveryTrackingData(
      ok: m['ok'] == true,
      found: m['found'] == true,
      tracking: m['tracking'] == true,
      statusLabel: _s(m['status_label']),
      partnerName: _s(m['partner_name']),
      orderCode: _s(m['order_code']),
      stopsAheadLabel: _s(m['stops_ahead_label']),
      hasStopsAhead: m['has_stops_ahead'] == true,
      riderLat: _d(m['rider_lat']),
      riderLng: _d(m['rider_lng']),
      hasRiderLocation: m['has_rider_location'] == true,
      destLat: _d(m['destination_lat']),
      destLng: _d(m['destination_lng']),
      hasDestination: m['has_destination'] == true,
      qrToken: _s(m['qr_token']),
      title: _s(m['title']),
      message: _s(m['message']),
    );
  }
}

/// The live map + status + QR. [onRefetch] is called whenever the rider's
/// position row changes, so the host re-reads its own RPC rather than this
/// widget patching a coordinate it was handed.
class DeliveryTrackingView extends StatefulWidget {
  final DeliveryTrackingData data;
  final Future<void> Function() onRefetch;

  const DeliveryTrackingView({
    super.key,
    required this.data,
    required this.onRefetch,
  });

  @override
  State<DeliveryTrackingView> createState() => _DeliveryTrackingViewState();
}

class _DeliveryTrackingViewState extends State<DeliveryTrackingView> {
  RealtimeChannel? _channel;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    try {
      _channel?.unsubscribe();
    } catch (_) {}
    super.dispose();
  }

  /// F2 — realtime on delivery_partner_locations, never polling.
  ///
  /// Neither tracking RPC returns partner_id (the customer has no business
  /// knowing it), so the subscription cannot be filtered to one rider. It
  /// listens to the table and re-reads the RPC on a change; the RPC is the only
  /// thing that decides what this customer may see, so an event about somebody
  /// else's rider costs one read and changes nothing on screen. Debounced so a
  /// fleet mid-run cannot turn into a refetch storm.
  void _subscribe() {
    try {
      _channel = Supabase.instance.client
          .channel('delivery_track_${DateTime.now().microsecondsSinceEpoch}')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'delivery_partner_locations',
            callback: (_) => _bump(),
          )
          .subscribe();
      RenderLog.write('c629_track_realtime', 'subscribed');
    } catch (_) {
      // No socket -> the view still renders the payload it already has.
    }
  }

  void _bump() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () async {
      if (!mounted) return;
      await widget.onRefetch();
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    RenderLog.write('c629_track_view', 'tracking=${d.tracking};rider=${d.hasRiderLocation}');

    // The destination is drawn as the single "stop"; the rider rides the origin
    // marker. Same map widget as the rider's own screen — one map, one
    // behaviour. No pin_color is invented here: the tracking payload carries
    // none, so the map falls back to Google's default marker.
    final stops = <Map<String, dynamic>>[
      if (d.hasDestination)
        {
          'delivery_id': 'destination',
          'lat': d.destLat,
          'lng': d.destLng,
        },
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (d.statusLabel.isNotEmpty)
          Text(d.statusLabel,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _kText)),
        if (d.orderCode.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(d.orderCode, style: TextStyle(fontSize: 12.5, color: _kSub)),
        ],
        if (d.partnerName.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(d.partnerName, style: TextStyle(fontSize: 13, color: _kSub)),
        ],
        if (d.hasStopsAhead && d.stopsAheadLabel.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFE6F1FB),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(d.stopsAheadLabel,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF0C447C))),
          ),
        ],

        // F2 — the live map, shown while the backend says tracking is on.
        if (d.tracking && (d.hasDestination || d.hasRiderLocation)) ...[
          const SizedBox(height: 12),
          DeliveryRunMapPanel(
            stops: stops,
            originLat: d.hasRiderLocation ? d.riderLat : null,
            originLng: d.hasRiderLocation ? d.riderLng : null,
            height: 240,
          ),
        ],

        // Not tracking yet — the catalog's sentence, not one written here.
        if (!d.tracking) ...[
          const SizedBox(height: 10),
          Text(_ui('dlv_track_none'), style: TextStyle(fontSize: 12.5, color: _kSub)),
        ],

        // F3 — the customer's QR: show it to the rider, or scan the parcel's own.
        if (d.qrToken.isNotEmpty) ...[
          const SizedBox(height: 16),
          Divider(height: 1, color: _kBorder),
          const SizedBox(height: 14),
          Text(_ui('dlv_your_qr'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: _kSub)),
          const SizedBox(height: 10),
          Center(
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: _kBorder),
                borderRadius: BorderRadius.circular(12),
              ),
              child: QrImageView(
                data: d.qrToken,
                size: 168,
                backgroundColor: Colors.white,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
