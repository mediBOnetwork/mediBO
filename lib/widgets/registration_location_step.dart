// lib/widgets/registration_location_step.dart — CMD #2127
//
// Registration step 2 · Location, as the approved design draws it: the map IS
// the input. A pin sits on the centre of the map, the map moves under it, and
// whatever is under the pin is reverse-geocoded BY THE BACKEND into the card
// below — address line, landmark, city, state and pincode — which the shop may
// correct with Edit.
//
// What it decides: nothing. The card's title, its second line, the boxed
// labels, the Edit sheet, "Use my location", every note and the footer's
// "Confirm location" all arrive inside `wizard.steps[].map` and are printed
// verbatim. The only numbers produced here are the two the map reports, and
// they go straight back out to `custreg_location_resolve`, which answers with
// the values to keep AND the card to draw.
//
// Two traps this closes:
//  • AdaptiveMap treats "no pins" as "nothing to plot" and drew map_config's
//    empty sentence INSTEAD of the map, so #1888's picker was a grey box. A
//    picker has a centre, and a centre is content — `centerCounts: true`.
//  • The pin is Google or it is nothing (`provider` from the backend). A
//    platform with no Google key gets the backend's sentence, never OSM tiles
//    behind a Google-shaped flow.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design_tokens.dart';
import '../services/device_location.dart';
import '../utils/render_log.dart';
import 'adaptive_map.dart';

typedef LocationRpc = Future<dynamic> Function(
    String fn, Map<String, dynamic>? params);

class RegistrationLocationStep extends StatefulWidget {
  const RegistrationLocationStep({
    super.key,
    required this.map,
    required this.values,
    required this.rpc,
    required this.onValues,
    this.height = 220,
  });

  /// wizard.steps[location].map — the geo block plus this step's own copy.
  final Map<String, dynamic> map;

  /// What the form is holding right now (address, city, latitude, …).
  final Map<String, String> values;

  /// The same transport every registration surface uses.
  final LocationRpc rpc;

  /// Values the backend wants kept, handed back to the form controller.
  final void Function(Map<String, dynamic> values) onValues;

  final double height;

  @override
  State<RegistrationLocationStep> createState() =>
      _RegistrationLocationStepState();
}

class _RegistrationLocationStepState extends State<RegistrationLocationStep> {
  Map<String, dynamic> _card = const {};
  Map<String, String> _values = const {};
  double? _lat;
  double? _lng;
  String _signature = 'initial';
  String _note = '';
  String _tone = 'neutral';
  bool _reading = false;
  bool _locating = false;
  bool _denied = false;
  Timer? _settle;

  @override
  void initState() {
    super.initState();
    _values = Map<String, String>.from(widget.values);
    _card = _m(widget.map['card']);
    _lat = double.tryParse(_values['latitude'] ?? '');
    _lng = double.tryParse(_values['longitude'] ?? '');
    // Nothing pinned yet: open on the device, so the common case is one nudge
    // rather than a hunt across the country.
    if (_lat == null || _lng == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _useDevice());
    }
  }

  @override
  void dispose() {
    _settle?.cancel();
    super.dispose();
  }

  Map<String, dynamic> _m(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : const {};

  String _s(String key) => (widget.map[key] ?? '').toString();

  MapPoint? get _fallbackCentre {
    final c = widget.map['default_center'];
    if (c is Map) {
      final la = (c['lat'] as num?)?.toDouble();
      final ln = (c['lng'] as num?)?.toDouble();
      // 0,0 is the Gulf of Guinea, not a fallback.
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
      fix = await DeviceLocation.best();
    } catch (_) {
      fix = null;
    }
    if (!mounted) return;
    setState(() {
      _locating = false;
      _denied = fix == null;
      if (fix != null) {
        _lat = fix.lat;
        _lng = fix.lng;
        _signature = 'device:${fix.lat},${fix.lng}';
      }
    });
    RenderLog.write('c2127_loc_device', fix == null ? 'denied' : 'ok');
    if (fix != null) await _resolve(geocode: true);
  }

  /// The map reports its centre continuously while a finger is down. The
  /// lookup waits for the map to stand still — one read per placement, not
  /// one per frame.
  void _onCentre(double lat, double lng) {
    _lat = lat;
    _lng = lng;
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 700), () {
      if (mounted) _resolve(geocode: true);
    });
  }

  Future<void> _resolve({required bool geocode}) async {
    final la = _lat, ln = _lng;
    if (la == null || ln == null) return;
    setState(() => _reading = geocode);
    try {
      final res = _m(await widget.rpc('custreg_location_resolve', {
        'p_lat': la,
        'p_lng': ln,
        'p_values': _values,
        'p_geocode': geocode,
      }));
      if (!mounted) return;
      if (res['ok'] != true) {
        setState(() => _reading = false);
        return;
      }
      final vals = _m(res['values']);
      setState(() {
        _reading = false;
        _values = {
          for (final e in vals.entries) e.key: (e.value ?? '').toString()
        };
        _card = _m(res['card']);
        _note = (res['note'] ?? '').toString();
        _tone = (res['tone'] ?? 'neutral').toString();
      });
      widget.onValues(vals);
      RenderLog.write('c2127_loc_resolve', (res['source'] ?? '').toString());
    } catch (_) {
      if (!mounted) return;
      setState(() => _reading = false);
    }
  }

  Future<void> _edit() async {
    final block = _m(widget.map['edit']);
    final fields = ((block['fields'] as List?) ?? const []).map(_m).toList();
    if (fields.isEmpty) return;
    final ctl = <String, TextEditingController>{
      for (final f in fields)
        (f['key'] ?? '').toString(): TextEditingController(
            text: _values[(f['key'] ?? '').toString()] ?? ''),
    };
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => _EditSheet(block: block, fields: fields, ctl: ctl),
    );
    if (saved == true) {
      final typed = <String, String>{
        for (final e in ctl.entries) e.key: e.value.text.trim(),
      };
      setState(() => _values = {..._values, ...typed});
      widget.onValues(typed);
      // The card is composed in the backend, so an edit is a round trip too —
      // never a comma joined in Dart.
      await _resolve(geocode: false);
      RenderLog.write('c2127_loc_edit', 'saved');
    }
    for (final c in ctl.values) {
      c.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final has = _lat != null && _lng != null;
    RenderLog.write('c2127_loc_step', has ? 'pin' : 'empty');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _mapCard(has),
        if (_note.isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          _noteLine(),
        ],
        SizedBox(height: Ds.space.x16),
        _addressCard(),
      ],
    );
  }

  Widget _mapCard(bool has) {
    final centre = has ? MapPoint(_lat!, _lng!) : _fallbackCentre;
    return ClipRRect(
      borderRadius: Ds.r.rCard,
      child: SizedBox(
        height: widget.height,
        child: Stack(children: [
          AdaptiveMap(
            height: widget.height,
            center: centre,
            zoom: (widget.map['default_zoom'] as num?)?.toDouble() ?? 16,
            fitToContent: false,
            centerCounts: true,
            cameraSignature: _signature,
            logKey: 'c2127_loc_map',
            borderRadius: Ds.r.rCard,
            onCenterChanged: _onCentre,
            requireProvider:
                _s('provider').isEmpty ? null : _s('provider'),
            unavailableState: _unavailable(),
          ),
          // The pin does not move — the map does. Its tip is the point.
          IgnorePointer(
            child: Center(
              child: Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x24),
                child: Icon(Icons.location_on,
                    size: Ds.space.x32, color: Ds.c.brand),
              ),
            ),
          ),
          if (_pillText().isNotEmpty)
            Positioned(
              left: Ds.space.x8,
              right: Ds.space.x8,
              top: Ds.space.x8,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _pill(_pillText()),
              ),
            ),
          Positioned(
            right: Ds.space.x8,
            bottom: Ds.space.x8,
            child: _useMyLocationButton(),
          ),
        ]),
      ),
    );
  }

  String _pillText() {
    if (_locating) return _s('locating_label');
    if (_reading) return _s('reading_label');
    if (_denied) return _s('denied_label');
    if (_lat == null || _lng == null) return _s('drag_hint');
    return '';
  }

  Widget _useMyLocationButton() => Semantics(
        identifier: 'reg_loc_use_my_location',
        button: true,
        child: Material(
          color: Ds.c.surface,
          borderRadius: Ds.r.rChip,
          elevation: 0,
          child: InkWell(
            borderRadius: Ds.r.rChip,
            onTap: _locating ? null : _useDevice,
            child: Container(
              constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rChip,
                boxShadow: Ds.elevation.e1,
              ),
              alignment: Alignment.center,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.my_location,
                    size: Ds.space.x16, color: Ds.c.brand),
                SizedBox(width: Ds.space.x8),
                Flexible(
                  child: Text(_s('use_my_location_label'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Ds.t.bodyStrong.copyWith(color: Ds.c.brand)),
                ),
              ]),
            ),
          ),
        ),
      );

  Widget _addressCard() {
    final fields = ((_card['fields'] as List?) ?? const []).map(_m).toList();
    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text((_card['title'] ?? '').toString(),
                  style: Ds.t.subtitle),
            ),
            SizedBox(width: Ds.space.x8),
            Semantics(
              identifier: 'reg_loc_edit',
              button: true,
              child: InkWell(
                onTap: _edit,
                borderRadius: Ds.r.rChip,
                child: Container(
                  constraints: BoxConstraints(
                      minHeight: Ds.touch.minTarget,
                      minWidth: Ds.touch.minTarget),
                  alignment: Alignment.center,
                  padding: EdgeInsets.symmetric(horizontal: Ds.space.x8),
                  child: Text((_card['edit_label'] ?? '').toString(),
                      style: Ds.t.bodyStrong.copyWith(color: Ds.c.brand)),
                ),
              ),
            ),
          ]),
          SizedBox(height: Ds.space.x4),
          Text((_card['line'] ?? '').toString(), style: Ds.t.bodySecondary),
          if (fields.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            LayoutBuilder(builder: (context, box) {
              final w = (box.maxWidth - Ds.space.x12) / 2;
              return Wrap(
                spacing: Ds.space.x12,
                runSpacing: Ds.space.x12,
                children: [
                  for (final f in fields)
                    SizedBox(width: w > 0 ? w : box.maxWidth, child: _box(f)),
                ],
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _box(Map<String, dynamic> f) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x8),
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rChip,
          border: Border.all(color: Ds.c.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text((f['label'] ?? '').toString(),
                style: Ds.t.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text((f['value'] ?? '').toString(),
                style: Ds.t.bodyStrong,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ],
        ),
      );

  /// The one instruction the map needs, and it is the backend's.
  Widget _pill(String text) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x8),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rChip,
          boxShadow: Ds.elevation.e1,
        ),
        child: Text(text,
            style: Ds.t.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
      );

  Widget _noteLine() {
    final bg = switch (_tone) {
      'success' => Ds.c.successSoft,
      'warning' => Ds.c.warningSoft,
      'danger' => Ds.c.dangerSoft,
      _ => Ds.c.infoSoft,
    };
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rCard),
      child: Text(_note, style: Ds.t.caption),
    );
  }

  /// Drawn INSTEAD of the map when this platform has no Google key. The pin
  /// can still be set from the device, and the address can still be typed.
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
}

/// The Edit sheet — the backend's fields, in the backend's order, with the
/// backend's labels and hints. Sheets over dialogs (DESIGN.md).
class _EditSheet extends StatelessWidget {
  const _EditSheet({
    required this.block,
    required this.fields,
    required this.ctl,
  });

  final Map<String, dynamic> block;
  final List<Map<String, dynamic>> fields;
  final Map<String, TextEditingController> ctl;

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x16 + inset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text((block['title'] ?? '').toString(), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x16),
            for (final f in fields) ...[
              Text((f['label'] ?? '').toString(), style: Ds.t.caption),
              SizedBox(height: Ds.space.x4),
              TextField(
                controller: ctl[(f['key'] ?? '').toString()],
                maxLines: f['multiline'] == true ? 3 : 1,
                keyboardType: f['numeric'] == true
                    ? TextInputType.number
                    : TextInputType.text,
                inputFormatters: f['numeric'] == true
                    ? [FilteringTextInputFormatter.digitsOnly]
                    : null,
                decoration: InputDecoration(
                    hintText: (f['hint'] ?? '').toString()),
              ),
              SizedBox(height: Ds.space.x12),
            ],
            SizedBox(height: Ds.space.x4),
            Row(children: [
              Expanded(
                child: SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text((block['cancel_label'] ?? '').toString()),
                  ),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                flex: 2,
                child: Semantics(
                  identifier: 'reg_loc_edit_save',
                  button: true,
                  child: SizedBox(
                    height: Ds.touch.minTarget,
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: Text((block['save_label'] ?? '').toString()),
                    ),
                  ),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
