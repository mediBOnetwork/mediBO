// lib/widgets/adaptive_map.dart — CHANGE #634
//
// THE ONE MAP WIDGET. Every map surface in the app renders through this file:
//   • Route tab            (route_map)            — route_google_map_panel.dart
//   • Supplier Shop map    (map_supplier_groups)  — supplier_map_groups_panel.dart
//   • Delivery rider/admin (delivery_run_map)     — delivery_run_map_panel.dart
//
// Before #634 each of those carried its own provider choice and its own Google
// API key, so one key problem showed up as "This page can't load Google Maps
// correctly" in five places at once and needed five fixes plus a deploy.
//
// THE APP RENDERS, IT NEVER DECIDES. This widget makes NO provider decision:
// map_config_get().uses_google_js — a backend boolean — selects the render
// path. Flip that column and every map in the app switches provider on the next
// session, with no rebuild.
//
// Markers, polylines, pin colours and stop ordering are NOT touched here: each
// screen keeps building them from its own RPC and hands them in already
// decided (A6). Only the BASE MAP layer lives in this file.

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:latlong2/latlong.dart' as ll;

import '../services/map_config.dart';
import '../services/maps_js_loader_stub.dart'
    if (dart.library.js_interop) '../services/maps_js_loader_web.dart';
import '../utils/render_log.dart';

// ── Provider-neutral inputs ───────────────────────────────────────────────
// Deliberately NOT google_maps_flutter types: a screen that spoke LatLng could
// only ever be drawn by Google.

@immutable
class MapPoint {
  final double lat;
  final double lng;
  const MapPoint(this.lat, this.lng);
}

@immutable
class MapBoundsBox {
  final double south;
  final double west;
  final double north;
  final double east;
  const MapBoundsBox({
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  });
}

/// One marker. [iconBytes] is a PNG the calling screen painted itself, so both
/// render paths draw byte-identical pins — switching provider never changes
/// what a pin looks like.
@immutable
class MapPin {
  final String id;
  final double lat;
  final double lng;
  final Uint8List? iconBytes;
  final double iconWidth;
  final double iconHeight;

  /// true  -> the bottom tip of the icon sits on the coordinate (teardrop pins)
  /// false -> the icon is centred on the coordinate (dots, hub, "me")
  final bool tipAtPoint;

  /// Drawn only when [iconBytes] is null (icons are painted asynchronously, so
  /// the first frame has none). Never a status->colour decision: the caller
  /// passes the colour the backend sent.
  final Color? fallbackColor;

  /// Backend text, rendered verbatim on tap/hover.
  final String title;

  /// Higher draws on top.
  final int zIndex;

  final VoidCallback? onTap;

  const MapPin({
    required this.id,
    required this.lat,
    required this.lng,
    this.iconBytes,
    this.iconWidth = 32,
    this.iconHeight = 46,
    this.tipAtPoint = true,
    this.fallbackColor,
    this.title = '',
    this.zIndex = 0,
    this.onTap,
  });
}

@immutable
class MapLine {
  final String id;
  final List<MapPoint> points;
  final Color color;
  final double width;
  const MapLine({
    required this.id,
    required this.points,
    required this.color,
    this.width = 5,
  });
}

// ── The widget ────────────────────────────────────────────────────────────

class AdaptiveMap extends StatefulWidget {
  final List<MapPin> pins;
  final List<MapLine> lines;

  /// Where to open when there is nothing to fit. Null falls through to the
  /// backend's default_center (A7) — never to a coordinate written in Dart.
  final MapPoint? center;
  final double? zoom;

  /// Explicit bounds from an RPC (route_map().bounds). Wins over [fitToContent].
  final MapBoundsBox? fitBounds;

  /// Frame every pin + line point.
  final bool fitToContent;

  /// Changing this string re-runs the camera fit. Screens pass their route/run
  /// id so switching routes reframes but a repaint does not.
  final String cameraSignature;

  final double height;
  final BorderRadius borderRadius;

  /// Flipped while a finger is on the map so an ancestor scroll view can lock.
  final ValueNotifier<bool>? touchLock;

  /// A7 — shown INSTEAD of a blank map when there is nothing to plot. The
  /// caller supplies its screen's existing backend copy; this file writes no
  /// user-facing string of its own.
  final Widget? emptyState;

  /// Render-log key so a deploy can be proven from curl alone.
  final String logKey;

  const AdaptiveMap({
    super.key,
    this.pins = const [],
    this.lines = const [],
    this.center,
    this.zoom,
    this.fitBounds,
    this.fitToContent = true,
    this.cameraSignature = '',
    required this.height,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.touchLock,
    this.emptyState,
    this.logKey = 'c634_map',
  });

  @override
  State<AdaptiveMap> createState() => _AdaptiveMapState();
}

class _AdaptiveMapState extends State<AdaptiveMap> {
  late Future<MapConfig> _cfg;

  @override
  void initState() {
    super.initState();
    _cfg = MapConfigService.load();
  }

  List<MapPoint> get _allPoints => [
        for (final p in widget.pins) MapPoint(p.lat, p.lng),
        for (final l in widget.lines) ...l.points,
      ];

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<MapConfig>(
      future: _cfg,
      builder: (context, snap) {
        final cfg = snap.data ?? MapConfigService.cached;
        if (cfg == null) {
          // Waiting on, or failed to get, the one authoritative answer. We do
          // NOT guess a provider or a key here — that is exactly the bug this
          // change removes.
          return _shell(child: const Center(
            child: SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43)),
            ),
          ));
        }

        RenderLog.write('c634_map_config', cfg.provider);
        RenderLog.write('c634_map_google_js', cfg.usesGoogleJs ? 1 : 0);
        RenderLog.write(widget.logKey, widget.pins.length.toString());

        // A7 — nothing to plot: show the screen's own empty copy (or the
        // backend's map_config.empty_label) instead of a grey rectangle.
        if (_allPoints.isEmpty) {
          final empty = widget.emptyState ?? _configEmpty(cfg);
          if (empty != null) {
            RenderLog.write('c634_map_empty', 1);
            return SizedBox(height: widget.height, child: empty);
          }
        }

        final map = cfg.usesGoogleJs
            ? _GoogleJsMap(cfg: cfg, host: widget)
            : _TileMap(cfg: cfg, host: widget);

        return _shell(child: map);
      },
    );
  }

  /// The backend's own empty copy, printed verbatim. Null when the config row
  /// carries none — then the map simply opens on default_center, which is
  /// still a backend decision, not a Dart one.
  Widget? _configEmpty(MapConfig cfg) {
    if (cfg.emptyLabel.isEmpty) return null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          cfg.emptyLabel,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B7280)),
        ),
      ),
    );
  }

  Widget _shell({required Widget child}) {
    final lock = widget.touchLock;
    Widget body = ClipRRect(
      borderRadius: widget.borderRadius,
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: Container(color: const Color(0xFFEDEDED), child: child),
      ),
    );
    if (lock != null) {
      body = Listener(
        onPointerDown: (_) => lock.value = true,
        onPointerUp: (_) => lock.value = false,
        onPointerCancel: (_) => lock.value = false,
        onPointerSignal: (_) {},
        child: body,
      );
    }
    return body;
  }
}

// ── Path 1: tile-based (provider = 'osm', uses_google_js = false) ──────────
// No Google JS loader, no key, nothing to bill or misconfigure. Tile URL,
// attribution and max zoom are used VERBATIM from the config row.

class _TileMap extends StatefulWidget {
  final MapConfig cfg;
  final AdaptiveMap host;
  const _TileMap({required this.cfg, required this.host});

  @override
  State<_TileMap> createState() => _TileMapState();
}

class _TileMapState extends State<_TileMap> {
  final fm.MapController _controller = fm.MapController();
  bool _ready = false;
  String _fittedFor = 'unfitted';

  List<ll.LatLng> _points() => [
        for (final p in widget.host.pins) ll.LatLng(p.lat, p.lng),
        for (final l in widget.host.lines)
          for (final pt in l.points) ll.LatLng(pt.lat, pt.lng),
      ];

  @override
  void didUpdateWidget(covariant _TileMap old) {
    super.didUpdateWidget(old);
    _maybeFit();
  }

  void _maybeFit() {
    if (!_ready) return;
    final sig = '${widget.host.cameraSignature}|${_points().length}';
    if (sig == _fittedFor) return;
    _fittedFor = sig;
    WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
  }

  void _fit() {
    if (!mounted) return;
    final b = widget.host.fitBounds;
    try {
      if (b != null) {
        _controller.fitCamera(fm.CameraFit.bounds(
          bounds: fm.LatLngBounds(
            ll.LatLng(b.south, b.west),
            ll.LatLng(b.north, b.east),
          ),
          padding: const EdgeInsets.all(36),
          maxZoom: widget.cfg.maxZoom,
        ));
        return;
      }
      final pts = _points();
      if (!widget.host.fitToContent || pts.isEmpty) return;
      if (pts.length == 1) {
        _controller.move(pts.first, 14);
        return;
      }
      _controller.fitCamera(fm.CameraFit.coordinates(
        coordinates: pts,
        padding: const EdgeInsets.all(36),
        maxZoom: widget.cfg.maxZoom,
      ));
    } catch (_) {
      // A camera fit that fails must never take the screen down.
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = widget.cfg;
    final host = widget.host;

    // A7 — a map with no points opens on the backend's default centre/zoom.
    final centre = host.center;
    final initialCentre = centre != null
        ? ll.LatLng(centre.lat, centre.lng)
        : ll.LatLng(cfg.defaultLat, cfg.defaultLng);

    final pins = [...host.pins]..sort((a, b) => a.zIndex.compareTo(b.zIndex));

    RenderLog.write('c634_tile_map', pins.length.toString());

    return Stack(children: [
      fm.FlutterMap(
        mapController: _controller,
        options: fm.MapOptions(
          initialCenter: initialCentre,
          initialZoom: host.zoom ?? cfg.defaultZoom,
          maxZoom: cfg.maxZoom,
          backgroundColor: const Color(0xFFEDEDED),
          interactionOptions: const fm.InteractionOptions(
            flags: fm.InteractiveFlag.drag |
                fm.InteractiveFlag.flingAnimation |
                fm.InteractiveFlag.pinchMove |
                fm.InteractiveFlag.pinchZoom |
                fm.InteractiveFlag.doubleTapZoom |
                fm.InteractiveFlag.scrollWheelZoom,
          ),
          onMapReady: () {
            _ready = true;
            _fittedFor = 'unfitted';
            _maybeFit();
          },
        ),
        children: [
          if (cfg.hasTiles)
            fm.TileLayer(
              urlTemplate: cfg.tileUrl,
              // Retina variant only when the backend supplied one.
              fallbackUrl: cfg.tileUrlRetina.isEmpty ? null : cfg.tileUrlRetina,
              maxZoom: cfg.maxZoom,
              maxNativeZoom: cfg.maxZoom.round(),
              userAgentPackageName: 'in.medibo.app',
              tileDisplay: const fm.TileDisplay.instantaneous(),
            ),
          if (host.lines.isNotEmpty)
            fm.PolylineLayer(
              polylines: [
                for (final l in host.lines)
                  if (l.points.length >= 2)
                    fm.Polyline(
                      points: [for (final p in l.points) ll.LatLng(p.lat, p.lng)],
                      color: l.color,
                      strokeWidth: l.width,
                      strokeCap: StrokeCap.round,
                      strokeJoin: StrokeJoin.round,
                    ),
              ],
            ),
          fm.MarkerLayer(
            markers: [
              for (final p in pins)
                fm.Marker(
                  point: ll.LatLng(p.lat, p.lng),
                  width: p.iconWidth,
                  height: p.iconHeight,
                  alignment: p.tipAtPoint ? Alignment.topCenter : Alignment.center,
                  child: _PinChild(pin: p),
                ),
            ],
          ),
        ],
      ),
      // Attribution, printed verbatim from the config row (tile licences
      // require it, and the text is the backend's, not ours).
      if (cfg.attribution.isNotEmpty)
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            color: const Color(0xCCFFFFFF),
            child: Text(
              cfg.attribution,
              style: const TextStyle(fontSize: 9, color: Color(0xFF4B5563)),
            ),
          ),
        ),
    ]);
  }
}

class _PinChild extends StatelessWidget {
  final MapPin pin;
  const _PinChild({required this.pin});

  @override
  Widget build(BuildContext context) {
    final bytes = pin.iconBytes;
    Widget art = bytes != null
        ? Image.memory(bytes, width: pin.iconWidth, height: pin.iconHeight, fit: BoxFit.contain)
        : Center(
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: pin.fallbackColor ?? const Color(0xFF1B7A43),
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          );
    if (pin.title.isNotEmpty) {
      art = Tooltip(message: pin.title, child: art);
    }
    if (pin.onTap != null) {
      art = GestureDetector(behavior: HitTestBehavior.opaque, onTap: pin.onTap, child: art);
    }
    return art;
  }
}

// ── Path 2: Google Maps JavaScript API (uses_google_js = true) ─────────────
// Kept fully working so the provider can be switched from the database with no
// rebuild. The key is injected at runtime from the config — there is no key in
// this repo and no <script> tag in index.html.

class _GoogleJsMap extends StatefulWidget {
  final MapConfig cfg;
  final AdaptiveMap host;
  const _GoogleJsMap({required this.cfg, required this.host});

  @override
  State<_GoogleJsMap> createState() => _GoogleJsMapState();
}

class _GoogleJsMapState extends State<_GoogleJsMap> {
  late Future<bool> _js;
  gm.GoogleMapController? _controller;
  String _fittedFor = 'unfitted';

  @override
  void initState() {
    super.initState();
    _js = loadGoogleMapsJs(widget.cfg.browserKey);
  }

  @override
  void didUpdateWidget(covariant _GoogleJsMap old) {
    super.didUpdateWidget(old);
    _maybeFit();
  }

  List<gm.LatLng> _points() => [
        for (final p in widget.host.pins) gm.LatLng(p.lat, p.lng),
        for (final l in widget.host.lines)
          for (final pt in l.points) gm.LatLng(pt.lat, pt.lng),
      ];

  void _maybeFit() {
    final sig = '${widget.host.cameraSignature}|${_points().length}';
    if (sig == _fittedFor) return;
    _fittedFor = sig;
    WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
  }

  Future<void> _fit() async {
    final c = _controller;
    if (c == null || !mounted) return;
    final b = widget.host.fitBounds;
    try {
      if (b != null) {
        await c.animateCamera(gm.CameraUpdate.newLatLngBounds(
          gm.LatLngBounds(
            southwest: gm.LatLng(b.south, b.west),
            northeast: gm.LatLng(b.north, b.east),
          ),
          48,
        ));
        return;
      }
      final pts = _points();
      if (!widget.host.fitToContent || pts.isEmpty) return;
      if (pts.length == 1) {
        await c.animateCamera(gm.CameraUpdate.newLatLngZoom(pts.first, 14));
        return;
      }
      var south = pts.first.latitude, north = pts.first.latitude;
      var west = pts.first.longitude, east = pts.first.longitude;
      for (final p in pts) {
        if (p.latitude < south) south = p.latitude;
        if (p.latitude > north) north = p.latitude;
        if (p.longitude < west) west = p.longitude;
        if (p.longitude > east) east = p.longitude;
      }
      await c.animateCamera(gm.CameraUpdate.newLatLngBounds(
        gm.LatLngBounds(
          southwest: gm.LatLng(south, west),
          northeast: gm.LatLng(north, east),
        ),
        48,
      ));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _js,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(
            child: SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43)),
            ),
          );
        }
        if (snap.data != true) {
          // The JS API did not load. Show the caller's empty copy rather than
          // the grey "for development purposes only" watermark.
          RenderLog.write('c634_google_js_failed', 1);
          return widget.host.emptyState ?? const SizedBox.shrink();
        }

        final cfg = widget.cfg;
        final host = widget.host;
        final centre = host.center;
        final initial = centre != null
            ? gm.LatLng(centre.lat, centre.lng)
            : gm.LatLng(cfg.defaultLat, cfg.defaultLng);

        RenderLog.write('c634_google_js_map', host.pins.length.toString());

        return gm.GoogleMap(
          initialCameraPosition: gm.CameraPosition(
            target: initial,
            zoom: host.zoom ?? cfg.defaultZoom,
          ),
          markers: {
            for (final p in host.pins)
              gm.Marker(
                markerId: gm.MarkerId(p.id),
                position: gm.LatLng(p.lat, p.lng),
                icon: p.iconBytes != null
                    ? gm.BitmapDescriptor.bytes(p.iconBytes!,
                        width: p.iconWidth, height: p.iconHeight)
                    : gm.BitmapDescriptor.defaultMarker,
                anchor: p.tipAtPoint ? const Offset(0.5, 1.0) : const Offset(0.5, 0.5),
                zIndexInt: p.zIndex,
                infoWindow: p.title.isEmpty
                    ? gm.InfoWindow.noText
                    : gm.InfoWindow(title: p.title),
                onTap: p.onTap,
              ),
          },
          polylines: {
            for (final l in host.lines)
              if (l.points.length >= 2)
                gm.Polyline(
                  polylineId: gm.PolylineId(l.id),
                  points: [for (final p in l.points) gm.LatLng(p.lat, p.lng)],
                  color: l.color,
                  width: l.width.round(),
                  geodesic: true,
                  startCap: gm.Cap.roundCap,
                  endCap: gm.Cap.roundCap,
                  jointType: gm.JointType.round,
                ),
          },
          onMapCreated: (c) {
            _controller = c;
            _fittedFor = 'unfitted';
            _maybeFit();
          },
          myLocationButtonEnabled: false,
          mapToolbarEnabled: false,
          zoomControlsEnabled: true,
          zoomGesturesEnabled: true,
          scrollGesturesEnabled: true,
          rotateGesturesEnabled: false,
          tiltGesturesEnabled: false,
          webGestureHandling: gm.WebGestureHandling.greedy,
          gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
            Factory<EagerGestureRecognizer>(() => EagerGestureRecognizer()),
          },
        );
      },
    );
  }
}
