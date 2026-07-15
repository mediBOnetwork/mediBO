// lib/widgets/route_google_map_panel.dart — CHANGE #463
// Google Maps rendering of ONE route (route_map() RPC). DUMB: this widget
// only draws what the server sends — no ETA maths, no km rounding, no
// building of Google Maps URLs, no deriving marker colour from open/closed
// (that's `tone`, already decided server-side).
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../utils/render_log.dart';

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

  @override
  void initState() {
    super.initState();
    _prepareIcons();
  }

  @override
  void didUpdateWidget(covariant RouteGoogleMapPanel old) {
    super.didUpdateWidget(old);
    if (old.mapData['route_id'] != widget.mapData['route_id']) {
      _prepareIcons();
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
      _iconCache[entry.key] = await _numberedMarkerIcon(label, color);
    }
    if (mounted) setState(() {});
  }

  Future<BitmapDescriptor> _numberedMarkerIcon(String label, Color bg) async {
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
    final path = ((data['path'] as List?) ?? [])
        .map((p) => Map<String, dynamic>.from(p as Map))
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
      markers.add(Marker(
        markerId: MarkerId('stop_${s['seq']}'),
        position: LatLng(lat, lng),
        icon: _iconFor(isHub: false, label: label, bad: bad) ??
            BitmapDescriptor.defaultMarkerWithHue(bad ? BitmapDescriptor.hueRed : BitmapDescriptor.hueGreen),
        anchor: const Offset(0.5, 0.5),
        onTap: () => widget.onTapStop(s),
      ));
    }

    final polylinePoints = path
        .map((p) {
          final lat = (p['lat'] as num?)?.toDouble();
          final lng = (p['lng'] as num?)?.toDouble();
          return (lat != null && lng != null) ? LatLng(lat, lng) : null;
        })
        .whereType<LatLng>()
        .toList();

    RenderLog.write('c463_map', 1);
    RenderLog.write('c463_markers', stops.length.toString());
    RenderLog.write('c463_hub', hub != null ? 1 : 0);
    RenderLog.write('c463_polyline', polylinePoints.length.toString());
    RenderLog.write('c472_route_map_eager_gestures', 1);

    final centerLat = (center?['lat'] as num?)?.toDouble();
    final centerLng = (center?['lng'] as num?)?.toDouble();
    final initialTarget = (centerLat != null && centerLng != null)
        ? LatLng(centerLat, centerLng)
        : (polylinePoints.isNotEmpty ? polylinePoints.first : const LatLng(0, 0));

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
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
                width: 4,
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
          // C472: claim the pan gesture eagerly so ONE finger drags the map
          // instead of the page, and the "use two fingers" overlay never shows.
          gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
            Factory<EagerGestureRecognizer>(() => EagerGestureRecognizer()),
          }.toSet(),
        ),
      ),
    );
  }
}
