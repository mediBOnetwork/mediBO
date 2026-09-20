// lib/widgets/store_pin_picker.dart — CHANGE #1888
//
// The shop's GPS pin, picked instead of typed.
//
// Before this, latitude and longitude were two text boxes on the admin form
// and nothing at all on self-signup, so 10 of the 12 shops on file had no
// coordinates, 11 had no maps link and 8 had no district — every one of them a
// field a human was supposed to fill in and nobody did.
//
// This widget makes the pin the only way in. It opens on the DEVICE's own
// location, draws a fixed pin over the centre of the map, and the owner drags
// the map until the pin sits on their shop door. Whatever is under the pin is
// what gets saved.
//
// It decides nothing. Every string here — the button, the "finding you",
// the refusal when location is off, the "pin set" line — arrives inside
// customer_form_schema().geo and is printed verbatim. The only numbers it
// produces are the two the map itself reports.
//
// CMD #2112 — GOOGLE MAPS ONLY, AND A FIX WORTH PINNING.
//  • `geo.provider` ('google') is a REQUIREMENT passed to [AdaptiveMap]. A
//    platform whose map_config has no Google key for it gets the backend's
//    `unavailable_label` and the current-location button; it never gets OSM
//    tiles. Two different base maps behind one field is how a pin set here
//    disagreed with the map an admin then checked it on.
//  • The fix is [DeviceLocation.best], not the first answer the browser has.
//    `getCurrentPosition` returns the wifi/cell estimate the moment it has
//    one — hundreds of metres out — and a shop door dropped on that looks
//    exactly like a working map.
import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../services/device_location.dart';
import '../utils/render_log.dart';
import 'adaptive_map.dart';

class StorePinPicker extends StatefulWidget {
  const StorePinPicker({
    super.key,
    required this.geo,
    required this.lat,
    required this.lng,
    required this.onPicked,
    this.height = 220,
  });

  /// customer_form_schema().geo — labels, the fallback centre and the zoom.
  final Map<String, dynamic> geo;

  /// The coordinates already held, if any. Empty string = nothing picked yet.
  final String lat;
  final String lng;

  /// Fires with the point under the pin. Strings, because that is what the
  /// form controller carries and what the RPC takes.
  final void Function(String lat, String lng) onPicked;

  final double height;

  @override
  State<StorePinPicker> createState() => _StorePinPickerState();
}

class _StorePinPickerState extends State<StorePinPicker> {
  bool _locating = false;
  bool _denied = false;
  double? _lat;
  double? _lng;
  String _cameraSignature = 'initial';

  @override
  void initState() {
    super.initState();
    _lat = double.tryParse(widget.lat);
    _lng = double.tryParse(widget.lng);
    // "defaulting to device location" — asked for the moment the field is
    // shown, so the common case is one drag, not a hunt across the country.
    if (_lat == null || _lng == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _useDevice());
    }
  }

  String _s(String key) => (widget.geo[key] ?? '').toString();

  MapPoint? get _fallbackCentre {
    final c = widget.geo['default_center'];
    if (c is Map) {
      final la = (c['lat'] as num?)?.toDouble();
      final ln = (c['lng'] as num?)?.toDouble();
      // A backend that has not been given a centre sends 0,0 — the Gulf of
      // Guinea is not a fallback, it is a bug. Better to show no map than a
      // pin in the sea.
      if (la != null && ln != null && (la != 0 || ln != 0)) {
        return MapPoint(la, ln);
      }
    }
    return null;
  }

  Future<void> _useDevice() async {
    if (_locating) return;
    setState(() {
      _locating = true;
      _denied = false;
    });
    DeviceFix? fix;
    try {
      // The most accurate reading the device can give inside a few seconds,
      // not the first one it happens to have cached.
      fix = await DeviceLocation.best();
    } catch (_) {
      fix = null;
    }
    if (!mounted) return;
    setState(() {
      _locating = false;
      if (fix == null) {
        _denied = true;
      } else {
        _lat = fix.lat;
        _lng = fix.lng;
        _cameraSignature = 'device:${fix.lat},${fix.lng}';
      }
    });
    if (fix != null) _emit();
    RenderLog.write('c1888_pin_device', fix == null ? 'denied' : 'ok');
    RenderLog.write('c2112_pin_accuracy',
        fix?.accuracy?.round().toString() ?? 'none');
  }

  void _emit() {
    final la = _lat, ln = _lng;
    if (la == null || ln == null) return;
    widget.onPicked(la.toStringAsFixed(6), ln.toStringAsFixed(6));
  }

  void _onCentre(double lat, double lng) {
    _lat = lat;
    _lng = lng;
    _emit();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final has = _lat != null && _lng != null;
    final centre = has ? MapPoint(_lat!, _lng!) : _fallbackCentre;

    RenderLog.write('c1888_pin_picker', has ? 'set' : 'empty');

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: Ds.r.rCard,
        child: SizedBox(
          height: widget.height,
          child: Stack(children: [
            AdaptiveMap(
              height: widget.height,
              center: centre,
              zoom: (widget.geo['default_zoom'] as num?)?.toDouble() ?? 16,
              fitToContent: false,
              cameraSignature: _cameraSignature,
              logKey: 'c1888_pin_map',
              borderRadius: Ds.r.rCard,
              onCenterChanged: _onCentre,
              // The backend's requirement, passed through. Not a Dart choice.
              requireProvider: _s('provider').isEmpty ? null : _s('provider'),
              unavailableState: _unavailable(),
            ),
            // The pin does not move — the map does. Its tip sits on the exact
            // centre of the viewport, which is the point being reported.
            IgnorePointer(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.only(bottom: Ds.space.x24),
                  child: Icon(Icons.location_on,
                      size: Ds.space.x32, color: Ds.c.brand),
                ),
              ),
            ),
            if (_locating)
              Positioned(
                left: Ds.space.x8,
                top: Ds.space.x8,
                child: _pill(_s('locating_label'), Ds.c.infoSoft),
              )
            // The one instruction the pin needs, and it is the backend's. It
            // stands down the moment a point is set, so it never sits on top
            // of the map a shop is reading.
            else if (!has && _s('drag_hint').isNotEmpty)
              Positioned(
                left: Ds.space.x8,
                right: Ds.space.x8,
                top: Ds.space.x8,
                child: _pill(_s('drag_hint'), Ds.c.infoSoft),
              ),
          ]),
        ),
      ),
      SizedBox(height: Ds.space.x8),
      Row(children: [
        Expanded(
          child: Text(
            _denied
                ? _s('denied_label')
                : has
                    ? '${_s('set_label')} · ${_lat!.toStringAsFixed(5)}, ${_lng!.toStringAsFixed(5)}'
                    : _s('none_label'),
            style: Ds.t.caption,
          ),
        ),
        SizedBox(width: Ds.space.x8),
        SizedBox(
          height: 44,
          child: TextButton.icon(
            onPressed: _locating ? null : _useDevice,
            icon: Icon(Icons.my_location, size: Ds.space.x16, color: Ds.c.brand),
            label: Text(_s('use_device_label'),
                style: Ds.t.caption.copyWith(color: Ds.c.brand)),
          ),
        ),
      ]),
    ]);
  }

  /// Drawn INSTEAD of the map when the platform has no Google key. The pin can
  /// still be set — the current-location button below is the same button —
  /// and no tile server is ever reached for it.
  Widget _unavailable() {
    final line = _s('unavailable_label');
    if (line.isEmpty) return const SizedBox.shrink();
    return Container(
      color: Ds.c.bg,
      alignment: Alignment.center,
      padding: EdgeInsets.all(Ds.space.x16),
      child: Text(line, style: Ds.t.caption, textAlign: TextAlign.center),
    );
  }

  Widget _pill(String text, Color bg) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x8, vertical: Ds.space.x4),
        decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
        child: Text(text, style: Ds.t.caption, maxLines: 2,
            overflow: TextOverflow.ellipsis),
      );
}
