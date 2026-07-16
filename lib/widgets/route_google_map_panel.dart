// lib/widgets/route_google_map_panel.dart — CHANGE #463
// Google Maps rendering of ONE route (route_map() RPC). DUMB: this widget
// only draws what the server sends — no ETA maths, no km rounding, no
// building of Google Maps URLs, no deriving marker colour from open/closed
// (that's `tone`, already decided server-side).
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../utils/render_log.dart';

// CHANGE #484: fetch the actual road-following path from the self-hosted
// OSRM server so the route line curves along streets instead of jumping
// straight between stops. NEVER allowed to block or crash the map — any
// error/timeout returns null and the caller falls back to the existing
// straight-line polyline built from `path`.
const String _osrmBaseUrl = 'http://35.234.212.254:5000/route/v1/driving/';
const int _osrmMaxWaypointsPerRequest = 100;

/// Fetches the road-following geometry through [stops] (already in visit
/// order, e.g. hub -> stop1 -> ... -> stopN -> hub) from OSRM. Chunks into
/// groups of ~100 waypoints (OSRM's practical cap) when a route has more
/// stops than that, overlapping chunk boundaries by one point so the
/// concatenated path has no gap. Returns null on ANY failure (timeout,
/// non-200, malformed body, network error, VM off) so the caller can fall
/// back to straight lines — this must never throw.
Future<List<LatLng>?> fetchRoadPolyline(List<LatLng> stops) async {
  if (stops.length < 2) return null;

  final chunks = <List<LatLng>>[];
  if (stops.length <= _osrmMaxWaypointsPerRequest) {
    chunks.add(stops);
  } else {
    var start = 0;
    while (start < stops.length - 1) {
      final end = (start + _osrmMaxWaypointsPerRequest - 1)
          .clamp(0, stops.length - 1);
      chunks.add(stops.sublist(start, end + 1));
      if (end >= stops.length - 1) break;
      start = end; // overlap: last point of this chunk = first of next
    }
  }

  final result = <LatLng>[];
  for (final chunk in chunks) {
    final points = await _fetchOsrmChunk(chunk);
    if (points == null) return null; // any chunk failing fails the whole path
    if (result.isNotEmpty && points.isNotEmpty) {
      result.addAll(points.skip(1)); // drop duplicate boundary point
    } else {
      result.addAll(points);
    }
  }
  return result.length >= 2 ? result : null;
}

Future<List<LatLng>?> _fetchOsrmChunk(List<LatLng> points) async {
  if (points.length < 2) return null;
  try {
    final coords = points.map((p) => '${p.longitude},${p.latitude}').join(';');
    final url = Uri.parse('$_osrmBaseUrl$coords?overview=full&geometries=polyline');
    final resp = await http.get(url).timeout(const Duration(seconds: 6));
    if (resp.statusCode != 200) return null;
    final body = jsonDecode(resp.body);
    if (body is! Map) return null;
    final routes = body['routes'];
    if (routes is! List || routes.isEmpty) return null;
    final first = routes[0];
    if (first is! Map) return null;
    final geometry = first['geometry'];
    if (geometry is! String || geometry.isEmpty) return null;
    return _decodeEncodedPolyline(geometry);
  } catch (_) {
    return null;
  }
}

// CHANGE #487: decode via the flutter_polyline_points package instead of a
// hand-rolled decoder — same standard Encoded Polyline Algorithm Format (used
// by both OSRM's geometries=polyline and Google Routes API's
// ENCODED_POLYLINE), but battle-tested instead of reimplemented here.
List<LatLng> _decodeEncodedPolyline(String encoded) {
  return PolylinePoints()
      .decodePolyline(encoded)
      .map((p) => LatLng(p.latitude, p.longitude))
      .toList();
}

// CHANGE #478 (fix v2): the ancestor page SingleChildScrollView (owned by
// admin_customer_screen.dart, several widget layers above this file) needs to
// switch to NeverScrollableScrollPhysics for as long as a finger is down on
// the map, then switch back. NotificationListener<ScrollNotification> cannot
// do this — it only observes a scroll AFTER it has already happened. This
// widget flips the lock on pointer down/up; admin_customer_screen.dart reads
// it to choose the outer scroll view's physics.
final ValueNotifier<bool> routeMapTouchLock = ValueNotifier<bool>(false);

class RouteGoogleMapPanel extends StatefulWidget {
  final Map<String, dynamic> mapData; // route_map() response
  final bool isDesktop;
  final void Function(Map<String, dynamic> stop) onTapStop;
  const RouteGoogleMapPanel({
    super.key,
    required this.mapData,
    required this.isDesktop,
    required this.onTapStop,
  });

  @override
  State<RouteGoogleMapPanel> createState() => _RouteGoogleMapPanelState();
}

class _RouteGoogleMapPanelState extends State<RouteGoogleMapPanel> {
  GoogleMapController? _controller;
  final Map<String, BitmapDescriptor> _iconCache = {};

  // CHANGE #484: road-following polyline fetched from OSRM, cached per
  // route_id so switching Map/List tabs doesn't refetch. Null (or a
  // mismatched route id) means "still on the straight-line fallback".
  final Map<String, List<LatLng>> _roadPolylineCache = {};
  String? _roadFetchInFlightForRouteId;

  @override
  void initState() {
    super.initState();
    _prepareIcons();
    _fetchRoadIfNeeded();
  }

  @override
  void didUpdateWidget(covariant RouteGoogleMapPanel old) {
    super.didUpdateWidget(old);
    if (old.mapData['route_id'] != widget.mapData['route_id']) {
      _prepareIcons();
      _fetchRoadIfNeeded();
    }
  }

  // CHANGE #485: route_plan_routes.road_polyline, set by route_apply_google()
  // after a Google Routes optimization. Same encoding as OSRM's, so the
  // shared _decodeEncodedPolyline handles it. Null/empty/malformed -> null,
  // and the caller falls back to OSRM or the straight-line path — never throws.
  List<LatLng>? _googlePolylinePoints(Map<String, dynamic> data) {
    final encoded = data['road_polyline']?.toString();
    if (encoded == null || encoded.isEmpty) return null;
    try {
      final points = _decodeEncodedPolyline(encoded);
      return points.length >= 2 ? points : null;
    } catch (_) {
      return null;
    }
  }

  List<LatLng> _pathPoints(Map<String, dynamic> data) {
    final path = ((data['path'] as List?) ?? [])
        .map((p) => Map<String, dynamic>.from(p as Map))
        .toList();
    return path
        .map((p) {
          final lat = (p['lat'] as num?)?.toDouble();
          final lng = (p['lng'] as num?)?.toDouble();
          return (lat != null && lng != null) ? LatLng(lat, lng) : null;
        })
        .whereType<LatLng>()
        .toList();
  }

  Future<void> _fetchRoadIfNeeded() async {
    final routeId = widget.mapData['route_id']?.toString();
    if (routeId == null) return;
    // CHANGE #485: a Google-optimized route already carries a server-side
    // road polyline (see _googlePolylinePoints) — no need to also hit OSRM.
    if ((widget.mapData['road_polyline']?.toString() ?? '').isNotEmpty) return;
    if (_roadPolylineCache.containsKey(routeId)) return; // already cached
    if (_roadFetchInFlightForRouteId == routeId) return; // already fetching
    final stops = _pathPoints(widget.mapData);
    if (stops.length < 2) return;

    _roadFetchInFlightForRouteId = routeId;
    List<LatLng>? result;
    try {
      result = await fetchRoadPolyline(stops);
    } catch (_) {
      result = null; // belt-and-braces: fetchRoadPolyline already swallows errors
    }
    if (_roadFetchInFlightForRouteId == routeId) {
      _roadFetchInFlightForRouteId = null;
    }
    if (!mounted) return;
    if (result != null && result.length >= 2) {
      setState(() => _roadPolylineCache[routeId] = result!);
    }
  }

  Future<void> _prepareIcons() async {
    final hub = widget.mapData['hub'] as Map?;
    final stops = ((widget.mapData['stops'] as List?) ?? [])
        .map((s) => Map<String, dynamic>.from(s as Map))
        .toList();

    // key -> (label to draw, background colour)
    final wanted = <String, (String, Color)>{};
    if (hub != null) {
      final hubLabel = hub['marker_label']?.toString() ?? 'H';
      wanted['hub|$hubLabel'] = (hubLabel, const Color(0xFF1E3A8A));
    }
    for (final s in stops) {
      final label = s['marker_label']?.toString() ?? s['seq']?.toString() ?? '?';
      final bad = s['tone'] == 'bad';
      wanted['stop|$label|${bad ? 'bad' : 'ok'}'] =
          (label, bad ? const Color(0xFFDC2626) : const Color(0xFF1B7A43));
    }

    for (final entry in wanted.entries) {
      if (_iconCache.containsKey(entry.key)) continue;
      final (label, color) = entry.value;
      // CHANGE #490: hub keeps its original circle icon untouched; only stop
      // markers switch to the smaller teardrop pin.
      final isHub = entry.key.startsWith('hub|');
      _iconCache[entry.key] = await _numberedMarkerIcon(label, color, teardrop: !isHub);
    }
    if (mounted) setState(() {});
  }

  Future<BitmapDescriptor> _numberedMarkerIcon(String label, Color bg, {bool teardrop = false}) async {
    if (!teardrop) {
      // Unchanged — still used for the hub "H" pin.
      const size = 84.0;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, size, size));
      final center = const Offset(size / 2, size / 2);
      canvas.drawCircle(center, size / 2 - 4, Paint()..color = bg);
      canvas.drawCircle(
        center, size / 2 - 4,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: Colors.white,
            fontSize: label.length > 2 ? 24 : 30,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));
      final picture = recorder.endRecording();
      final image = await picture.toImage(size.toInt(), size.toInt());
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      return BitmapDescriptor.bytes(bytes!.buffer.asUint8List(), width: 40, height: 40);
    }

    // CHANGE #490: small teardrop pin — head ~32dp, full height ~46dp (down
    // from the old 40dp circle), tip anchored at the stop coordinate so
    // `anchor: Offset(0.5, 1.0)` lands exactly on it. Supersampled 3x for
    // crisp text at this size.
    const double w = 32.0;
    const double h = 46.0;
    const double scale = 3.0;
    const double headR = w / 2;
    const double cx = w / 2;
    const double cy = headR;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w * scale, h * scale));
    canvas.scale(scale);

    const drawnR = headR - 1.5; // matches the circle actually drawn below
    final theta = 50 * math.pi / 180;
    final baseLeft = Offset(cx - drawnR * math.sin(theta), cy + drawnR * math.cos(theta));
    final baseRight = Offset(cx + drawnR * math.sin(theta), cy + drawnR * math.cos(theta));
    const tip = Offset(cx, h - 1);
    final headPath = Path()..addOval(Rect.fromCircle(center: const Offset(cx, cy), radius: drawnR));
    final tipPath = Path()
      ..moveTo(baseLeft.dx, baseLeft.dy)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(baseRight.dx, baseRight.dy)
      ..close();
    final pinPath = Path.combine(PathOperation.union, headPath, tipPath);

    canvas.drawPath(pinPath, Paint()..color = bg);
    canvas.drawPath(
      pinPath,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: Colors.white,
          fontSize: label.length > 1 ? 12.0 : 14.0,
          fontWeight: FontWeight.w800,
          shadows: const [Shadow(color: Colors.black45, blurRadius: 1.5, offset: Offset(0, 0.5))],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));

    final picture = recorder.endRecording();
    final image = await picture.toImage((w * scale).round(), (h * scale).round());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(bytes!.buffer.asUint8List(), width: w, height: h);
  }

  BitmapDescriptor? _iconFor({required bool isHub, required String label, required bool bad}) {
    final key = isHub ? 'hub|$label' : 'stop|$label|${bad ? 'bad' : 'ok'}';
    return _iconCache[key];
  }

  Future<void> _fitBounds() async {
    final c = _controller;
    final b = widget.mapData['bounds'];
    if (c == null || b is! Map) return;
    final south = (b['south'] as num?)?.toDouble();
    final north = (b['north'] as num?)?.toDouble();
    final west = (b['west'] as num?)?.toDouble();
    final east = (b['east'] as num?)?.toDouble();
    if (south == null || north == null || west == null || east == null) return;
    try {
      await c.animateCamera(CameraUpdate.newLatLngBounds(
        LatLngBounds(southwest: LatLng(south, west), northeast: LatLng(north, east)),
        48,
      ));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.mapData;
    final hub = data['hub'] as Map?;
    final stops = ((data['stops'] as List?) ?? [])
        .map((s) => Map<String, dynamic>.from(s as Map))
        .toList();
    final center = data['center'] as Map?;

    final markers = <Marker>{};
    if (hub != null) {
      final lat = (hub['lat'] as num?)?.toDouble();
      final lng = (hub['lng'] as num?)?.toDouble();
      final hubLabel = hub['marker_label']?.toString() ?? 'H';
      if (lat != null && lng != null) {
        markers.add(Marker(
          markerId: const MarkerId('hub'),
          position: LatLng(lat, lng),
          icon: _iconFor(isHub: true, label: hubLabel, bad: false) ?? BitmapDescriptor.defaultMarker,
          anchor: const Offset(0.5, 0.5),
          infoWindow: InfoWindow(title: hub['title']?.toString() ?? hubLabel),
          zIndexInt: 10,
        ));
      }
    }
    for (final s in stops) {
      final lat = (s['lat'] as num?)?.toDouble();
      final lng = (s['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      final label = s['marker_label']?.toString() ?? s['seq']?.toString() ?? '?';
      final bad = s['tone'] == 'bad';
      final seq = (s['seq'] as num?)?.toInt() ?? 0;
      markers.add(Marker(
        markerId: MarkerId('stop_${s['seq']}'),
        position: LatLng(lat, lng),
        icon: _iconFor(isHub: false, label: label, bad: bad) ??
            BitmapDescriptor.defaultMarkerWithHue(bad ? BitmapDescriptor.hueRed : BitmapDescriptor.hueGreen),
        // CHANGE #490: teardrop pin — tip (not center) sits on the stop coord.
        anchor: const Offset(0.5, 1.0),
        // Earlier stops stay on top when pins overlap.
        zIndexInt: 1000 - seq,
        onTap: () => widget.onTapStop(s),
      ));
    }

    final straightPoints = _pathPoints(data);
    // CHANGE #485: prefer the server-side Google-optimized road polyline when
    // present (authoritative — matches the stop order route_apply_google()
    // saved). CHANGE #484: otherwise fall back to the OSRM road-following
    // path if it's cached for THIS route. Otherwise, the straight hub->stops
    // ->hub line.
    final googlePoints = _googlePolylinePoints(data);
    final roadPoints = _roadPolylineCache[data['route_id']?.toString()];
    final usingGooglePolyline = googlePoints != null;
    final usingOsrmPolyline = !usingGooglePolyline && roadPoints != null && roadPoints.length >= 2;
    final usingRoadPolyline = usingGooglePolyline || usingOsrmPolyline;
    final polylinePoints = usingGooglePolyline
        ? googlePoints
        : (usingOsrmPolyline ? roadPoints : straightPoints);

    RenderLog.write('c463_map', 1);
    RenderLog.write('c463_markers', stops.length.toString());
    RenderLog.write('c463_hub', hub != null ? 1 : 0);
    RenderLog.write('c463_polyline', polylinePoints.length.toString());
    RenderLog.write('c472_route_map_eager_gestures', 1);
    RenderLog.write('c473_route_map_one_finger_fixed', 1);
    RenderLog.write('c478_map_scroll_locked', 1);
    RenderLog.write('c478_physics_lock_wired', 1);
    if (usingOsrmPolyline) {
      RenderLog.write('c484_osrm_road_polyline', polylinePoints.length.toString());
    }
    if (usingGooglePolyline) {
      RenderLog.write('c485_google_road_polyline', polylinePoints.length.toString());
      // CHANGE #487: confirms the decoded road_polyline actually reaches the
      // GoogleMap's `polylines:` set below, not just that it was decoded.
      RenderLog.write('c487_road_polyline_drawn', polylinePoints.length.toString());
    }

    // CHANGE #492: direction arrows (added #490) removed — they rendered as
    // a dense chevron band that made the route harder to read. Back to a
    // single plain polyline; pins are untouched.
    RenderLog.write('c490_pins_teardrop', 1);
    RenderLog.write('c492_arrows_removed', 1);

    final centerLat = (center?['lat'] as num?)?.toDouble();
    final centerLng = (center?['lng'] as num?)?.toDouble();
    final initialTarget = (centerLat != null && centerLng != null)
        ? LatLng(centerLat, centerLng)
        : (polylinePoints.isNotEmpty ? polylinePoints.first : const LatLng(0, 0));

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Listener(
        // C478 v2: NotificationListener<ScrollNotification> (tried previously)
        // only observes a scroll AFTER the ancestor SingleChildScrollView has
        // already moved — it can't prevent it. The real fix is upstream: flip
        // routeMapTouchLock the instant a finger touches the map, which
        // admin_customer_screen.dart's outer scroll view reads to switch to
        // NeverScrollableScrollPhysics for the duration of the touch. Even if
        // the page's drag recognizer still wins the gesture arena for this
        // pointer, NeverScrollableScrollPhysics rejects the resulting scroll
        // offset deltas, so the page stays visually still either way.
        onPointerDown: (_) => routeMapTouchLock.value = true,
        onPointerUp: (_) => routeMapTouchLock.value = false,
        onPointerCancel: (_) => routeMapTouchLock.value = false,
        // Absorb wheel/trackpad pointer signals over the map box too.
        onPointerSignal: (_) {},
        child: SizedBox(
          height: widget.isDesktop ? 420 : 320,
          child: GoogleMap(
            initialCameraPosition: CameraPosition(target: initialTarget, zoom: 13),
            markers: markers,
            polylines: {
              if (polylinePoints.length >= 2)
                Polyline(
                  polylineId: const PolylineId('route'),
                  points: polylinePoints,
                  color: const Color(0xFF1B7A43),
                  width: usingRoadPolyline ? 5 : 4,
                  geodesic: true,
                  startCap: Cap.roundCap,
                  endCap: Cap.roundCap,
                  jointType: JointType.round,
                ),
            },
            onMapCreated: (c) {
              _controller = c;
              _fitBounds();
            },
            myLocationButtonEnabled: false,
            mapToolbarEnabled: false,
            zoomControlsEnabled: true,
            zoomGesturesEnabled: true,
            scrollGesturesEnabled: true,
            rotateGesturesEnabled: false,
            tiltGesturesEnabled: false,
            // C473: google_maps_flutter_web ignores gestureRecognizers
            // entirely — the map is a real embedded DOM element (Google
            // Maps JS SDK), not a canvas platform view, so Flutter's
            // gesture arena never sees its touches. The actual fix for the
            // "two fingers" overlay + page-steals-scroll behaviour is the
            // JS SDK's own gestureHandling option: 'cooperative' (the
            // default when embedded in a scrollable page) explicitly lets
            // one-finger touches pass through to scroll the page and shows
            // the overlay; 'greedy' makes the map consume all touch/scroll
            // gestures instead, which is what removes both symptoms.
            webGestureHandling: WebGestureHandling.greedy,
            // Kept for parity if this ever ships to Android/iOS, where
            // gestureRecognizers IS read and Eager wins the gesture arena.
            gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
              Factory<EagerGestureRecognizer>(() => EagerGestureRecognizer()),
            }.toSet(),
          ),
        ),
      ),
    );
  }
}
