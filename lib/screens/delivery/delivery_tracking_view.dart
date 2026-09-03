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
import 'package:url_launcher/url_launcher_string.dart';

import '../../design_tokens.dart';
import '../../services/live_feed.dart';

import '../../fulfill/fulfill_lookups.dart';
import '../../utils/render_log.dart';
import '../../widgets/delivery_proof_card.dart';
import 'run_live_map.dart';

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

  /// CHANGE #691 (register rows 122 / 126). The arrival window and the proof of
  /// delivery, each a finished block from the backend. Rendered by
  /// DeliveryEtaCard / DeliveryProofCard, which compute nothing either.
  final Map<String, dynamic> eta;
  final Map<String, dynamic> proof;

  final double riderLat;
  final double riderLng;
  final bool hasRiderLocation;

  /// CHANGE #700 — the pair the BACKEND says to plot: road-snapped where OSRM
  /// answered, raw where it did not. The choice is made server-side precisely
  /// so the customer map and the admin map can never disagree about it.
  final double mapLat;
  final double mapLng;
  final bool riderSnapped;

  /// The run-scoped broadcast topic this viewer may listen to, and the
  /// backend's own staleness block ("Live" / "Last seen 4 min ago" /
  /// "Rider offline") — never computed here from a timestamp.
  final String channel;
  final Map<String, dynamic> live;
  final String note;
  final int animateMs;

  final double destLat;
  final double destLng;
  final bool hasDestination;

  final String qrToken;

  /// Present only on the public payload; '' elsewhere.
  final String title;
  final String message;

  // CHANGE #463 gap 117 — the masked "Call rider" affordance.
  //
  // This carries NO phone number, by design: the button reports intent and the
  // backend places the masked call, so a number never reaches this build. It
  // is populated ONLY from the authenticated customer payload — the public
  // token payload deliberately does not offer it, because that link never
  // expires (register row 125) and holding it is not proof of being the buyer.
  final bool hasCall;
  final String callLabel;
  final String callPrivacyNote;

  // CHANGE #463 register row 121 — the rider's verified face. The payload
  // sends a BUCKET and a PATH, never a URL: `rider-selfies` is private and its
  // storage policy is what decides whether this viewer may sign it. `has` is
  // the backend's answer — it is false unless an admin verified the identity
  // AND this stop is live, so nothing here infers a face from a name.
  final bool hasPhoto;
  final String photoBucket;
  final String photoPath;

  /// The order the call is about — the backend's own `order_id`, echoed back
  /// from call_action, so no caller has to thread an id down to this view.
  final String callOrderId;

  // CHANGE #701 (register #125) — the route to THIS door.
  //
  // `route.polyline` is the SEGMENT from where the rider is to this stop, cut
  // in the database: the rest of the run passes other pharmacies' doors, so it
  // is never sent. The distance sentence and the stops-ahead sentence arrive
  // finished, and the stops ahead are named by postal area only — this view
  // has no way to render another customer's address because it never receives
  // one.
  final String routePolyline;
  final String routeKmLabel;
  final String routeHeading;
  final bool hasRoute;

  /// Postal-area names of the stops in front of this one, in run order.
  final List<String> stopsAheadAreas;

  // CHANGE #701 — "share live link with staff". Offered only when the BACKEND
  // says so: the public /track page has no identity to authorise a send, so it
  // never receives this block and the button simply is not there.
  final bool hasShare;
  final String shareLabel;
  final String shareRpc;
  final String shareOrderId;

  const DeliveryTrackingData({
    required this.ok,
    required this.found,
    required this.tracking,
    required this.statusLabel,
    required this.partnerName,
    required this.orderCode,
    required this.stopsAheadLabel,
    required this.hasStopsAhead,
    this.eta = const {},
    this.proof = const {},
    required this.riderLat,
    required this.riderLng,
    required this.hasRiderLocation,
    required this.mapLat,
    required this.mapLng,
    required this.riderSnapped,
    required this.channel,
    required this.live,
    required this.note,
    required this.animateMs,
    required this.destLat,
    required this.destLng,
    required this.hasDestination,
    required this.qrToken,
    required this.title,
    required this.message,
    this.hasCall = false,
    this.callLabel = '',
    this.callPrivacyNote = '',
    this.callOrderId = '',
    this.hasPhoto = false,
    this.photoBucket = '',
    this.photoPath = '',
    this.routePolyline = '',
    this.routeKmLabel = '',
    this.routeHeading = '',
    this.hasRoute = false,
    this.stopsAheadAreas = const [],
    this.hasShare = false,
    this.shareLabel = '',
    this.shareRpc = '',
    this.shareOrderId = '',
  });

  /// The backend's `route` block, read the same way by both callers.
  static Map<String, dynamic> _route(Map<String, dynamic> m) =>
      m['route'] is Map ? Map<String, dynamic>.from(m['route'] as Map) : const {};

  static List<String> _areas(Map<String, dynamic> route) {
    final sa = route['stops_ahead'];
    if (sa is! Map) return const [];
    final raw = (sa['areas'] as List?) ?? const [];
    return [
      for (final a in raw)
        if (a != null && a.toString().trim().isNotEmpty) a.toString()
    ];
  }

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
    // gap 117 — an absent or empty call_action means the backend decided this
    // customer may not ring this rider right now. `has` is its answer, never
    // inferred here from the status or from a phone number being present.
    final call = (m['call_action'] as Map?) ?? const {};
    final photo = (m['rider_photo'] as Map?) ?? const {};
    return DeliveryTrackingData(
      hasPhoto: photo['has'] == true,
      photoBucket: _s(photo['bucket']),
      photoPath: _s(photo['path']),
      hasCall: call['has'] == true,
      callLabel: _s(call['label']),
      callPrivacyNote: _s(call['privacy_note']),
      callOrderId: _s(call['order_id']),
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
      eta: m['eta'] is Map ? Map<String, dynamic>.from(m['eta'] as Map) : const {},
      proof: m['proof'] is Map ? Map<String, dynamic>.from(m['proof'] as Map) : const {},
      riderLat: riderLat?.toDouble() ?? 0,
      riderLng: riderLng?.toDouble() ?? 0,
      hasRiderLocation: riderLat != null && riderLng != null,
      mapLat: (m['map_lat'] as num?)?.toDouble() ?? riderLat?.toDouble() ?? 0,
      mapLng: (m['map_lng'] as num?)?.toDouble() ?? riderLng?.toDouble() ?? 0,
      riderSnapped: m['rider_snapped'] == true,
      channel: m['has_channel'] == true ? _s(m['channel']) : '',
      live: m['live'] is Map ? Map<String, dynamic>.from(m['live'] as Map) : const {},
      note: _s(m['note']),
      animateMs: (m['animate_ms'] as num?)?.toInt() ?? 1200,
      destLat: destLat?.toDouble() ?? 0,
      destLng: destLng?.toDouble() ?? 0,
      hasDestination: destLat != null && destLng != null,
      qrToken: _s(m['qr_token']),
      routePolyline: _s(_route(m)['polyline']),
      routeKmLabel: _s(_route(m)['km_label']),
      routeHeading: _s(_route(m)['heading']),
      hasRoute: _route(m)['has'] == true,
      stopsAheadAreas: _areas(_route(m)),
      hasShare: ((m['share'] as Map?) ?? const {})['has'] == true,
      shareLabel: _s(((m['share'] as Map?) ?? const {})['label']),
      shareRpc: _s(((m['share'] as Map?) ?? const {})['rpc']),
      shareOrderId: _s(((m['share'] as Map?) ?? const {})['order_id']),
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
      eta: m['eta'] is Map ? Map<String, dynamic>.from(m['eta'] as Map) : const {},
      proof: m['proof'] is Map ? Map<String, dynamic>.from(m['proof'] as Map) : const {},
      riderLat: _d(m['rider_lat']),
      riderLng: _d(m['rider_lng']),
      hasRiderLocation: m['has_rider_location'] == true,
      // The public /track/{token} page has no signed-in identity, so it cannot
      // pass the private channel's RLS check. Empty channel = no subscription;
      // that page keeps the refetch it already had. Stated, not inferred.
      mapLat: (m['map_lat'] as num?)?.toDouble() ?? _d(m['rider_lat']),
      mapLng: (m['map_lng'] as num?)?.toDouble() ?? _d(m['rider_lng']),
      riderSnapped: m['rider_snapped'] == true,
      channel: '',
      live: m['live'] is Map ? Map<String, dynamic>.from(m['live'] as Map) : const {},
      note: _s(m['note']),
      animateMs: (m['animate_ms'] as num?)?.toInt() ?? 1200,
      destLat: _d(m['destination_lat']),
      destLng: _d(m['destination_lng']),
      hasDestination: m['has_destination'] == true,
      qrToken: _s(m['qr_token']),
      routePolyline: _s(_route(m)['polyline']),
      routeKmLabel: _s(_route(m)['km_label']),
      routeHeading: _s(_route(m)['heading']),
      hasRoute: _route(m)['has'] == true,
      stopsAheadAreas: _areas(_route(m)),
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
  LiveFeedHandle? _channel;
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
    // CHANGE #700 — when the backend handed this viewer a run channel, the
    // rider's dot arrives on that BROADCAST (inside RunLiveMap, which also
    // animates between frames and drives the debounced refetch below). The
    // 15 s poll #643 introduced is then pure duplicate traffic, so it is not
    // opened at all.
    //
    // It is still opened for a viewer with NO channel — the public
    // /track/{token} page, which has no signed-in identity and so cannot pass
    // the private channel's RLS check. One surface gains realtime; the other
    // keeps exactly what it had.
    if (widget.data.channel.isNotEmpty) {
      RenderLog.write('c700_track_realtime', 'broadcast');
      return;
    }
    try {
      // CHANGE #643: an UNFILTERED binding on a rider-position table fanned
      // every rider's every ping to every viewer. The registry puts this on a
      // 15 s poll — inside the useful resolution of a road move — and the
      // refetch below is unchanged.
      LiveFeed.instance
          .watch(
            channelPrefix: 'delivery_track',
            tables: const ['delivery_partner_locations'],
            onChange: (_) => _bump(),
          )
          .then((h) {
        if (!mounted) {
          h.dispose();
          return;
        }
        _channel?.unsubscribe();
        _channel = h;
      });
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
          // CHANGE #463 register row 121 unblocks register row 117's other
          // half: the name now has a verified face beside it.
          Row(children: [
            if (d.hasPhoto) ...[
              _RiderAvatar(bucket: d.photoBucket, path: d.photoPath),
              SizedBox(width: Ds.space.x8),
            ],
            Expanded(
              child: Text(d.partnerName,
                  style: TextStyle(fontSize: 13, color: _kSub)),
            ),
          ]),
        ],
        // CHANGE #463 gap 117 — "the customer cannot contact the rider at
        // all". The masking layer was already built and enabled; this payload
        // just never asked for it.
        if (d.hasCall) ...[
          const SizedBox(height: 8),
          _MaskedCallButton(
            orderId: d.callOrderId,
            label: d.callLabel,
            privacyNote: d.callPrivacyNote,
          ),
        ],
        // CHANGE #691 (register row 122) — "3 stops before you" WAS the whole
        // answer, because deliveries.eta_min was stamped once by the optimiser
        // and never rebased. The card now leads with a time and keeps the stop
        // count under it; both strings are the payload's, and the stop-count
        // chip moved inside the card so the two can never disagree.
        DeliveryEtaCard(eta: d.eta),

        // CHANGE #691 (register row 126) — proof of delivery, on the stop it
        // belongs to. `has:false` until the order is delivered.
        DeliveryProofCard(proof: d.proof),

        // F2 — the live map, shown while the backend says tracking is on.
        // CHANGE #700: the marker now rides run:<run_id> and animates between
        // the points the backend publishes, under the backend's own staleness
        // line. The pair plotted is map_lat/map_lng — road-snapped where OSRM
        // answered — so this view and the admin's show the same dot.
        if (d.tracking && (d.hasDestination || d.hasRiderLocation)) ...[
          const SizedBox(height: 12),
          RunLiveMap(
            channel: d.channel,
            stops: stops,
            live: d.live,
            note: d.note,
            animateMs: d.animateMs,
            initialPoint: d.hasRiderLocation
                ? RiderPoint(d.mapLat, d.mapLng, d.riderSnapped)
                : null,
            // CHANGE #701 — the road line the customer is allowed to see: the
            // segment from the rider to THIS door, already cut server-side.
            // The map draws whatever polyline it is handed; the decision about
            // how much of the run that is was made in _c701_route_segment.
            roadPolyline: d.routePolyline,
            height: 240,
            onFrame: (_) => _bump(),
          ),
          // Distance and who is in front, both printed verbatim. The areas are
          // postal areas, never addresses — the payload carries nothing finer.
          if (d.routeKmLabel.isNotEmpty || d.stopsAheadAreas.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            _RouteSummary(
              heading: d.routeHeading,
              kmLabel: d.routeKmLabel,
              areas: d.stopsAheadAreas,
            ),
          ],
          if (d.hasShare) ...[
            SizedBox(height: Ds.space.x8),
            _ShareLinkButton(
              label: d.shareLabel,
              rpc: d.shareRpc,
              orderId: d.shareOrderId,
            ),
          ],
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

/// CHANGE #463 gap 117 — the customer's masked "Call rider" button.
///
/// It carries no phone number and never will. `call_mask_prepare` returns a
/// `did` — the masked number the CALLER dials — alongside a `callee` block
/// holding the real number. This widget dials the DID and only the DID; the
/// callee's phone is deliberately never read, never shown and never dialled,
/// which is the whole point of the masking layer.
///
/// Every string the customer sees — the button label, the connecting notice,
/// the dial hint, the privacy note and every refusal — is the backend's.
class _MaskedCallButton extends StatefulWidget {
  final String orderId;
  final String label;
  final String privacyNote;

  const _MaskedCallButton({
    required this.orderId,
    required this.label,
    required this.privacyNote,
  });

  @override
  State<_MaskedCallButton> createState() => _MaskedCallButtonState();
}

class _MaskedCallButtonState extends State<_MaskedCallButton> {
  bool _busy = false;

  Future<void> _call() async {
    if (widget.orderId.isEmpty) return;
    setState(() => _busy = true);
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      final raw = await Supabase.instance.client.rpc('call_mask_prepare', params: {
        'p_actor': uid,
        'p_order_id': widget.orderId,
        'p_target_role': 'delivery',
      });
      final m = Map<String, dynamic>.from((raw is List ? raw.first : raw) as Map);
      if (!mounted) return;

      if (m['ok'] != true) {
        final msg = (m['message'] as String?) ?? '';
        if (msg.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
          );
        }
        setState(() => _busy = false);
        return;
      }

      final copy = Map<String, dynamic>.from((m['copy'] as Map?) ?? const {});
      final did = (m['did'] as String?) ?? '';

      // The DID is the only number this build may touch. When the backend
      // placed the call itself there is no DID to dial, and the notice it sent
      // is what the customer reads.
      if (did.isNotEmpty) {
        await launchUrlString('tel:$did');
        final hint = (copy['dial_hint'] as String?) ?? '';
        if (mounted && hint.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(hint), behavior: SnackBarBehavior.floating),
          );
        }
      } else {
        final placed = (copy['placed'] as String?) ??
            (copy['connecting'] as String?) ?? '';
        if (mounted && placed.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(placed), behavior: SnackBarBehavior.floating),
          );
        }
      }
      if (mounted) setState(() => _busy = false);
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 44,
          child: OutlinedButton.icon(
            onPressed: _busy ? null : _call,
            icon: const Icon(Icons.phone_outlined, size: 18),
            label: Text(widget.label),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: _kBorder),
              shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
            ),
          ),
        ),
        if (widget.privacyNote.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(widget.privacyNote, style: Ds.t.caption.copyWith(color: _kSub)),
        ],
      ],
    );
  }
}

/// CHANGE #463 register row 121 — the rider's face, signed on demand.
///
/// `rider-selfies` is a private bucket, so there is no public URL to render and
/// this widget never builds one: it asks storage to sign the backend's own
/// bucket + path, and a refusal (the policy says this viewer is not the buyer
/// on that stop, or the stop is over) simply renders nothing. A face is never
/// a placeholder here.
class _RiderAvatar extends StatefulWidget {
  final String bucket;
  final String path;

  const _RiderAvatar({required this.bucket, required this.path});

  @override
  State<_RiderAvatar> createState() => _RiderAvatarState();
}

class _RiderAvatarState extends State<_RiderAvatar> {
  String _url = '';

  @override
  void initState() {
    super.initState();
    _sign();
  }

  Future<void> _sign() async {
    try {
      final u = await Supabase.instance.client.storage
          .from(widget.bucket)
          .createSignedUrl(widget.path, 600);
      if (mounted) setState(() => _url = u);
    } catch (_) {
      // Not permitted, or gone. Silence is the correct render.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_url.isEmpty) return const SizedBox.shrink();
    return ClipOval(
      child: Image.network(
        _url,
        width: Ds.space.x32,
        height: Ds.space.x32,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );
  }
}

/// CHANGE #701 — the route summary under the map: how far by road, and the
/// postal areas the rider still has to reach before this one.
///
/// Every string here arrived finished. This widget does not count the stops,
/// pluralise the sentence or format the distance — doing any of that would put
/// a second, staler answer next to the server's.
class _RouteSummary extends StatelessWidget {
  const _RouteSummary({
    required this.heading,
    required this.kmLabel,
    required this.areas,
  });

  final String heading;
  final String kmLabel;
  final List<String> areas;

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c701_route_summary', areas.length.toString());
    return Container(
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: Ds.c.bg,
        borderRadius: Ds.r.rButton,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (heading.isNotEmpty)
          Text(heading, style: Ds.t.caption),
        if (kmLabel.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(kmLabel, style: Ds.t.bodyStrong),
        ],
        if (areas.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              for (final a in areas)
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x12, vertical: Ds.space.x4),
                  decoration: BoxDecoration(
                    color: Ds.c.surface,
                    borderRadius: Ds.r.rChip,
                    border: Border.all(color: Ds.c.divider),
                  ),
                  child: Text(a, style: Ds.t.caption),
                ),
            ],
          ),
        ],
      ]),
    );
  }
}

/// CHANGE #701 — sends the pharmacy's own staff the SAME expiring link.
///
/// The button carries no phone number: `delivery_share_track_link` reads the
/// numbers already saved against this pharmacy, so there is no shape of this
/// call that texts a stranger somebody's tracking link. The RPC's name comes
/// from the payload, and its reply is printed verbatim.
class _ShareLinkButton extends StatefulWidget {
  const _ShareLinkButton({
    required this.label,
    required this.rpc,
    required this.orderId,
  });

  final String label;
  final String rpc;
  final String orderId;

  @override
  State<_ShareLinkButton> createState() => _ShareLinkButtonState();
}

class _ShareLinkButtonState extends State<_ShareLinkButton> {
  bool _busy = false;

  Future<void> _send() async {
    if (_busy || widget.rpc.isEmpty || widget.orderId.isEmpty) return;
    setState(() => _busy = true);
    String msg = '';
    try {
      final res = await Supabase.instance.client
          .rpc(widget.rpc, params: {'p_order_id': widget.orderId});
      msg = ((res as Map?)?['message'] ?? '').toString();
      RenderLog.write('c701_share_link', '1');
    } catch (_) {
      // A failed send says nothing rather than inventing an apology: the only
      // sentences this screen may show are the ones the backend sent.
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (msg.isNotEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.label.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      width: double.infinity,
      height: Ds.touch.minTarget,
      child: OutlinedButton.icon(
        onPressed: _busy ? null : _send,
        icon: _busy
            ? SizedBox(
                width: Ds.t.captionSize,
                height: Ds.t.captionSize,
                child: const CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.share_outlined),
        label: Text(widget.label),
      ),
    );
  }
}
