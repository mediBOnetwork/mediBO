// lib/screens/delivery/delivery_run_map_panel.dart — CHANGE #629 (PART B2/B3, D5)
//
// The map at the top of the rider screen. DUMB, like every other map in this
// app: it draws the stops it is handed, in the colour the backend chose.
//
// B3 — "Render pin_color verbatim; do not map statuses to colours in Dart."
// There is no status -> colour table anywhere in this file. The only thing done
// to `pin_color` is parsing the backend's own hex string into a Color so the
// canvas can paint it; if the backend changes a colour, this file needs no
// change and no deploy.
//
// D5 — the road polyline is delivery_runs.road_polyline, decoded with the SAME
// decoder the Route tab's map uses (decodeEncodedPolyline, exported from
// route_google_map_panel.dart). No second decoder, no second polyline library.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../utils/render_log.dart';
import '../../widgets/route_google_map_panel.dart' show decodeEncodedPolyline;

/// Parses the backend's `#RRGGBB`. Returns null when absent/malformed so the
/// caller can fall back to Google's default marker rather than inventing a
/// colour of its own.
Color? colorFromBackendHex(String? hex) {
  final h = (hex ?? '').trim().replaceFirst('#', '');
  if (h.length != 6 && h.length != 8) return null;
  final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
  return v == null ? null : Color(v);
}

class DeliveryRunMapPanel extends StatefulWidget {
  /// Stops to pin. Each needs lat, lng, pin_color and (optionally) seq +
  /// pharmacy_name — exactly the shape my_delivery_run().stops and
  /// delivery_run_map().waypoints both already have.
  final List<Map<String, dynamic>> stops;

  /// CHANGE #630 (D6): additional people to plot on this SAME map — an
  /// agency's riders, from agency_team().riders. Each needs lat, lng and name;
  /// rows without a fix are skipped rather than dropped at (0,0). They are
  /// deliberately NOT merged into [stops]: a rider is not a stop, has no
  /// pin_color and must not be numbered into the route sequence.
  final List<Map<String, dynamic>> extraMarkers;

  /// delivery_run_map().road_polyline — empty/absent draws no line.
  final String roadPolyline;

  /// The rider's position, when known.
  final double? originLat;
  final double? originLng;

  final double height;
  final void Function(Map<String, dynamic> stop)? onTapStop;

  const DeliveryRunMapPanel({
    super.key,
    required this.stops,
    this.extraMarkers = const [],
    this.roadPolyline = '',
    this.originLat,
    this.originLng,
    this.height = 260,
    this.onTapStop,
  });

  @override
  State<DeliveryRunMapPanel> createState() => _DeliveryRunMapPanelState();
}

class _DeliveryRunMapPanelState extends State<DeliveryRunMapPanel> {
  GoogleMapController? _controller;
  final Map<String, BitmapDescriptor> _iconCache = {};

  @override
  void initState() {
    super.initState();
    _prepareIcons();
  }

  @override
  void didUpdateWidget(covariant DeliveryRunMapPanel old) {
    super.didUpdateWidget(old);
    if (old.stops.length != widget.stops.length || _signature(old.stops) != _signature(widget.stops)) {
      _prepareIcons();
      WidgetsBinding.instance.addPostFrameCallback((_) => _fitBounds());
    }
  }

  String _signature(List<Map<String, dynamic>> stops) =>
      stops.map((s) => '${s['delivery_id']}:${s['pin_color']}:${s['seq']}').join(',');

  String _iconKey(Map<String, dynamic> s) {
    final label = (s['seq'] as num?)?.toInt().toString() ?? '';
    return '${s['pin_color'] ?? ''}|$label';
  }

  Future<void> _prepareIcons() async {
    for (final s in widget.stops) {
      final key = _iconKey(s);
      if (_iconCache.containsKey(key)) continue;
      final color = colorFromBackendHex(s['pin_color']?.toString());
      if (color == null) continue;
      final label = (s['seq'] as num?)?.toInt().toString() ?? '';
      _iconCache[key] = await _pinIcon(label, color);
    }
    if (mounted) setState(() {});
  }

  /// Teardrop pin, tip on the coordinate — same shape the Route tab's map uses
  /// (CHANGE #490), just painted in the colour the backend sent.
  Future<BitmapDescriptor> _pinIcon(String label, Color bg) async {
    const double w = 32.0;
    const double h = 46.0;
    const double scale = 3.0;
    const double headR = w / 2;
    const double cx = w / 2;
    const double cy = headR;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w * scale, h * scale));
    canvas.scale(scale);

    const drawnR = headR - 1.5;
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

    if (label.isNotEmpty) {
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
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage((w * scale).round(), (h * scale).round());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(bytes!.buffer.asUint8List(), width: w, height: h);
  }

  List<LatLng> _points() {
    final pts = <LatLng>[];
    for (final s in widget.stops) {
      final lat = (s['lat'] as num?)?.toDouble();
      final lng = (s['lng'] as num?)?.toDouble();
      if (lat != null && lng != null) pts.add(LatLng(lat, lng));
    }
    // Riders count towards the fit too — an agency whose stops are all handed
    // out would otherwise have nothing to frame the camera on.
    for (final e in widget.extraMarkers) {
      final lat = (e['lat'] as num?)?.toDouble();
      final lng = (e['lng'] as num?)?.toDouble();
      if (lat != null && lng != null) pts.add(LatLng(lat, lng));
    }
    if (widget.originLat != null && widget.originLng != null) {
      pts.add(LatLng(widget.originLat!, widget.originLng!));
    }
    return pts;
  }

  Future<void> _fitBounds() async {
    final c = _controller;
    final pts = _points();
    if (c == null || pts.isEmpty) return;
    if (pts.length == 1) {
      try {
        await c.animateCamera(CameraUpdate.newLatLngZoom(pts.first, 14));
      } catch (_) {}
      return;
    }
    var south = pts.first.latitude, north = pts.first.latitude;
    var west = pts.first.longitude, east = pts.first.longitude;
    for (final p in pts) {
      south = math.min(south, p.latitude);
      north = math.max(north, p.latitude);
      west = math.min(west, p.longitude);
      east = math.max(east, p.longitude);
    }
    try {
      await c.animateCamera(CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(south, west),
          northeast: LatLng(north, east),
        ),
        48,
      ));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final markers = <Marker>{};

    for (var i = 0; i < widget.stops.length; i++) {
      final s = widget.stops[i];
      final lat = (s['lat'] as num?)?.toDouble();
      final lng = (s['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      final seq = (s['seq'] as num?)?.toInt() ?? (i + 1);
      markers.add(Marker(
        markerId: MarkerId('stop_${s['delivery_id'] ?? i}'),
        position: LatLng(lat, lng),
        icon: _iconCache[_iconKey(s)] ?? BitmapDescriptor.defaultMarker,
        anchor: const Offset(0.5, 1.0),
        zIndexInt: 1000 - seq,
        infoWindow: InfoWindow(title: s['pharmacy_name']?.toString() ?? ''),
        onTap: widget.onTapStop == null ? null : () => widget.onTapStop!(s),
      ));
    }

    // D6 — an agency's riders, in a distinct hue so they can never be mistaken
    // for a delivery stop. No status is read and no colour is chosen per rider.
    for (var i = 0; i < widget.extraMarkers.length; i++) {
      final e = widget.extraMarkers[i];
      final lat = (e['lat'] as num?)?.toDouble();
      final lng = (e['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      markers.add(Marker(
        markerId: MarkerId('rider_${e['partner_id'] ?? i}'),
        position: LatLng(lat, lng),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
        infoWindow: InfoWindow(title: e['name']?.toString() ?? ''),
        zIndexInt: 1500,
      ));
    }

    if (widget.originLat != null && widget.originLng != null) {
      markers.add(Marker(
        markerId: const MarkerId('me'),
        position: LatLng(widget.originLat!, widget.originLng!),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        anchor: const Offset(0.5, 0.5),
        zIndexInt: 2000,
      ));
    }

    List<LatLng> road = const [];
    if (widget.roadPolyline.isNotEmpty) {
      try {
        road = decodeEncodedPolyline(widget.roadPolyline);
      } catch (_) {
        road = const [];
      }
    }

    RenderLog.write('c629_delivery_map', markers.length.toString());
    if (road.length >= 2) {
      RenderLog.write('c629_delivery_road_polyline', road.length.toString());
    }

    final pts = _points();
    final initial = pts.isNotEmpty ? pts.first : const LatLng(21.2514, 81.6296);

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: widget.height,
        child: GoogleMap(
          initialCameraPosition: CameraPosition(target: initial, zoom: 12),
          markers: markers,
          polylines: {
            if (road.length >= 2)
              Polyline(
                polylineId: const PolylineId('run'),
                points: road,
                color: const Color(0xFF1B7A43),
                width: 5,
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
          rotateGesturesEnabled: false,
          tiltGesturesEnabled: false,
          webGestureHandling: WebGestureHandling.greedy,
          gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
            Factory<EagerGestureRecognizer>(() => EagerGestureRecognizer()),
          }.toSet(),
        ),
      ),
    );
  }
}
