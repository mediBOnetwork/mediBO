// CHANGE #1887 — THE one registration form.
//
// Self-signup, Import customer and Convert lead used to be three different
// forms with three different field lists and labels written in Dart. They are
// now the SAME widget, and the field list is a payload:
//
//     customer_form_schema(p_context)  ->  sections[] / fields[]
//
// Every label, hint, order, required flag, dropdown option and default comes
// from that payload. This file decides nothing about the form's content — it
// renders what the backend sent, in the order it sent it, and hands the typed
// values back untouched. Re-wording a label or re-ordering a field is an
// UPDATE on customer_form_field, never a deploy.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../services/registration_payload.dart';
import '../utils/render_log.dart';
import 'store_pin_picker.dart';

/// Holds the schema and one TextEditingController per field, so a caller can
/// pre-fill, read values and submit without knowing which fields exist.
class CustomerFormController extends ChangeNotifier {
  CustomerFormController({this.formContext = 'admin'});

  /// 'admin' (Import customer), 'signup' (self-registration) or
  /// 'lead_convert' (S Leads). The backend decides what each one shows.
  final String formContext;

  Map<String, dynamic>? _schema;
  String? loadError;

  final Map<String, TextEditingController> _ctl = {};

  /// Field keys the caller wants marked for a second look (OCR low confidence,
  /// or the fields a lead could not supply). Backend-supplied, never guessed.
  final Set<String> flagged = {};

  bool get ready => _schema != null;
  Map<String, dynamic> get schema => _schema ?? const {};

  List<Map<String, dynamic>> get fields =>
      ((_schema?['fields'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  List<Map<String, dynamic>> get sections =>
      ((_schema?['sections'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  List<String> get requiredKeys =>
      ((_schema?['required_fields'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList();

  /// CHANGE #1888 — customer_form_schema().geo: every label the map pin
  /// prints, plus the fallback centre and zoom. Empty on a payload that
  /// predates the change, which simply means no pin field is listed either.
  Map<String, dynamic> get geo =>
      Map<String, dynamic>.from((_schema?['geo'] as Map?) ?? const {});

  /// customer_form_schema().gst — which key is the "no GST" answer, and the
  /// backend's own copy for the two ways it can be wrong.
  Map<String, dynamic> get gst =>
      Map<String, dynamic>.from((_schema?['gst'] as Map?) ?? const {});

  String get _latKey => (geo['lat_key'] ?? 'latitude').toString();
  String get _lngKey => (geo['lng_key'] ?? 'longitude').toString();

  /// Checkbox answers. Kept apart from the text controllers because a boolean
  /// is not a string, and because "unticked" and "never asked" must not be the
  /// same thing on the wire.
  final Map<String, bool> _checks = {};

  bool checkValue(String key) => _checks[key] ?? false;

  void setCheck(String key, bool value) {
    _checks[key] = value;
    notifyListeners();
  }

  /// The pin's own coordinates, as the map reported them.
  String get pinLat => (_ctl[_latKey]?.text ?? '').trim();
  String get pinLng => (_ctl[_lngKey]?.text ?? '').trim();

  void setPin(String lat, String lng) {
    controllerFor(_latKey).text = lat;
    controllerFor(_lngKey).text = lng;
  }

  String text(String key) => (_schema?[key] ?? '').toString();

  /// Install a schema payload directly (tests, and any caller that already
  /// holds the RPC's answer). Same code path as [load] minus the network.
  void seed(Map<String, dynamic> payload) {
    _schema = Map<String, dynamic>.from(payload);
    for (final f in fields) {
      final k = f['key'].toString();
      final ctl = controllerFor(k);
      final def = f['default'];
      if (ctl.text.isEmpty && def != null && def.toString().isNotEmpty) {
        ctl.text = def.toString();
      }
    }
    notifyListeners();
  }

  Future<void> load() async {
    try {
      final res = await Supabase.instance.client
          .rpc('customer_form_schema', params: {'p_context': formContext});
      if (res is Map) {
        seed(Map<String, dynamic>.from(res));
        RenderLog.write('c1887_form_schema',
            'ctx=$formContext;fields=${fields.length};req=${requiredKeys.length}');
      }
    } catch (e) {
      loadError = '$e';
    }
    notifyListeners();
  }

  TextEditingController controllerFor(String key) =>
      _ctl.putIfAbsent(key, () {
        final c = TextEditingController();
        // CMD #2059 — a field created after autosave was switched on is
        // watched too, so the draft never has a hole in it.
        if (_autosaveOn) c.addListener(_scheduleSave);
        return c;
      });

  // ── CMD #2059 — instant form, and a draft that survives everything ───────
  //
  // The schema, the login prefill and the saved draft all arrived with the
  // home feed. Seeding from them is what makes the form open RENDERED; the
  // network copy that follows replaces nothing the user has typed, because
  // the draft is written on every change and read back before it.
  bool _autosaveOn = false;
  Timer? _saveTimer;
  Map<String, String> _saved = {};

  /// The backend's own word for the draft's state ('', 'Saving…', 'Saved').
  final ValueNotifier<String> draftLabel = ValueNotifier<String>('');

  /// True when the payload the app was already holding filled this form in.
  bool seedFromSurface() {
    if (!RegistrationSurface.hasForm) return false;
    seed(RegistrationSurface.schema);
    // Identity first, then what was typed: a draft always outranks a prefill.
    applyMap(RegistrationSurface.prefill);
    applyMap(RegistrationSurface.draft);
    return true;
  }

  /// Start writing every change to the backend draft.
  void enableAutosave() {
    if (_autosaveOn) return;
    _autosaveOn = true;
    _saved = {for (final e in _ctl.entries) e.key: e.value.text.trim()};
    for (final e in _ctl.entries) {
      e.value.addListener(_scheduleSave);
    }
  }

  void _scheduleSave() {
    if (!_autosaveOn) return;
    final ms =
        (RegistrationSurface.autosave['debounce_ms'] as num?)?.toInt() ?? 800;
    _saveTimer?.cancel();
    _saveTimer = Timer(Duration(milliseconds: ms), flushDraft);
  }

  /// Send everything that has changed since the last write. Public so a test
  /// can drive it without waiting on a real debounce.
  Future<void> flushDraft() async {
    if (!_autosaveOn) return;
    final patch = <String, dynamic>{};
    for (final e in _ctl.entries) {
      final v = e.value.text.trim();
      if (v == (_saved[e.key] ?? '')) continue;
      _saved[e.key] = v;
      patch[e.key] = v;
    }
    if (patch.isEmpty) return;
    draftLabel.value =
        (RegistrationSurface.autosave['saving_label'] ?? '').toString();
    await RegistrationSurface.saveDraft(patch);
    draftLabel.value =
        (RegistrationSurface.autosave['saved_label'] ?? '').toString();
  }

  void setValue(String key, dynamic value) {
    if (value == null) return;
    final s = value.toString();
    if (s.isEmpty || s == 'null') return;
    controllerFor(key).text = s;
  }

  /// Pre-fill from a backend map (lead prefill, OCR extract, existing profile).
  /// Keys the schema does not carry are still stored, so a later schema load
  /// picks them up.
  void applyMap(Map? values) {
    if (values == null) return;
    values.forEach((k, v) => setValue(k.toString(), v));
    notifyListeners();
  }

  /// What gets sent. Only fields the schema listed, only non-empty ones, so
  /// the backend applies its own defaults for everything else.
  Map<String, dynamic> payload() {
    final out = <String, dynamic>{};
    for (final f in fields) {
      final k = f['key'].toString();
      if (f['type'].toString() == 'checkbox') {
        // A checkbox is only sent once it has been touched: the backend can
        // then tell "said no GST" from "was never asked".
        if (_checks.containsKey(k)) out[k] = _checks[k];
        continue;
      }
      if (f['type'].toString() == 'geo') continue; // it writes lat/lng, not itself
      final v = (_ctl[k]?.text ?? '').trim();
      if (v.isNotEmpty) out[k] = v;
    }
    // The pin's coordinates ride along even though no field is named after
    // them — the backend refuses a save without them.
    if (pinLat.isNotEmpty && pinLng.isNotEmpty) {
      out[_latKey] = pinLat;
      out[_lngKey] = pinLng;
    }
    return out;
  }

  /// Required keys with nothing in them — the backend's own list. A map-pin
  /// field carries no text of its own, so it counts as filled once the two
  /// coordinates it writes are there.
  List<String> missingRequired() {
    final types = {
      for (final f in fields) f['key'].toString(): f['type'].toString()
    };
    final out = <String>[];
    for (final k in requiredKeys) {
      final empty = types[k] == 'geo'
          ? (pinLat.isEmpty || pinLng.isEmpty)
          : (_ctl[k]?.text ?? '').trim().isEmpty;
      if (empty) out.add(k);
    }
    return out;
  }

  String labelOf(String key) {
    for (final f in fields) {
      if (f['key'].toString() == key) return f['label'].toString();
    }
    return key;
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _autosaveOn = false;
    draftLabel.dispose();
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }
}

/// Renders the schema. Nothing here is conditional on WHICH surface is showing
/// it — the payload already answered that.
class CustomerRegistrationForm extends StatefulWidget {
  const CustomerRegistrationForm({
    super.key,
    required this.controller,
    this.header,
    this.onlyFields,
    this.chips = const {},
    this.notes = const {},
  });

  final CustomerFormController controller;

  /// CMD #2126 — one STEP of the registration flow: exactly these field keys,
  /// in this order (the backend's `wizard.steps[].fields`), with no section
  /// titles — the step's own title heads them. Null renders the whole schema.
  final List<String>? onlyFields;

  /// CMD #2126 — select fields drawn as tappable chips instead of a dropdown,
  /// with the backend's own option list (`wizard.chips`).
  final Map<String, List<String>> chips;

  /// CMD #2126 — a caption under a field, from the backend
  /// (`wizard.field_notes`, e.g. "Pre-filled from your login — you can change
  /// it" under WhatsApp). Absent key → nothing drawn.
  final Map<String, String> notes;

  /// Surface-specific actions (scan documents, fetch location) that sit above
  /// the fields. They write into the same controller.
  final Widget? header;

  @override
  State<CustomerRegistrationForm> createState() =>
      _CustomerRegistrationFormState();
}

class _CustomerRegistrationFormState extends State<CustomerRegistrationForm> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
    // CMD #2059 — paint from what the app is already holding, then let the
    // network copy land behind it. An empty cache falls through to load(),
    // which is the only case that ever shows the skeleton.
    if (!widget.controller.ready) widget.controller.seedFromSurface();
    if (!widget.controller.ready) widget.controller.load();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    if (!ctrl.ready) {
      // CMD #2059 — a field SKELETON, never a lone spinner: the screen already
      // shows the shape it is about to fill, so nothing flashes empty.
      return FormFieldsSkeleton(note: ctrl.loadError ?? '');
    }

    final wide = MediaQuery.of(context).size.width >= 600;
    final children = <Widget>[];
    if (widget.header != null) {
      children
        ..add(widget.header!)
        ..add(SizedBox(height: Ds.space.x16));
    }

    final only = widget.onlyFields;
    final groups = <MapEntry<String, List<Map<String, dynamic>>>>[];
    if (only != null) {
      final byKey = {for (final f in ctrl.fields) f['key'].toString(): f};
      groups.add(MapEntry('', [
        for (final k in only)
          if (byKey[k] != null) byKey[k]!,
      ]));
    } else {
      for (final section in ctrl.sections) {
        groups.add(MapEntry(
            section['title'].toString(),
            ((section['fields'] as List?) ?? const [])
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList()));
      }
    }

    for (final group in groups) {
      if (only == null) children.add(_sectionTitle(group.key));
      final fields = group.value;
      var i = 0;
      while (i < fields.length) {
        final f = fields[i];
        final pairable = wide &&
            (f['half_width'] == true) &&
            i + 1 < fields.length &&
            (fields[i + 1]['half_width'] == true);
        if (pairable) {
          children.add(Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _field(f)),
              SizedBox(width: Ds.space.x12),
              Expanded(child: _field(fields[i + 1])),
            ],
          ));
          i += 2;
        } else {
          children.add(_field(f));
          i += 1;
        }
      }
      children.add(SizedBox(height: Ds.space.x12));
    }

    RenderLog.write('c1887_form_rendered',
        'ctx=${ctrl.formContext};sections=${ctrl.sections.length};'
        'fields=${ctrl.fields.length}');

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  Widget _sectionTitle(String title) => Padding(
        padding: EdgeInsets.only(top: Ds.space.x8, bottom: Ds.space.x12),
        child: Text(title, style: Ds.t.caption),
      );

  Widget _field(Map<String, dynamic> f) {
    final ctrl = widget.controller;
    final key = f['key'].toString();
    final label = f['label'].toString();
    final required = f['required'] == true;
    final flagged = ctrl.flagged.contains(key);
    final type = f['type'].toString();
    final hint = (f['hint'] ?? '').toString();
    final options = ((f['options'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();

    final labelText =
        required ? '$label${ctrl.text('required_suffix')}' : label;

    // The checkbox prints its own label beside the tick, so the field header
    // would say it twice.
    final showHeader = type != 'checkbox';

    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (showHeader) Row(children: [
          Flexible(child: Text(labelText, style: Ds.t.bodyStrong)),
          if (flagged) ...[
            SizedBox(width: Ds.space.x8),
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x8, vertical: Ds.space.x4),
              decoration: BoxDecoration(
                color: Ds.c.warningSoft,
                borderRadius: Ds.r.rChip,
              ),
              child: Text(ctrl.text('flag_label'), style: Ds.t.caption),
            ),
          ],
        ]),
        if (showHeader) SizedBox(height: Ds.space.x4),
        if (type == 'geo')
          StorePinPicker(
            geo: ctrl.geo,
            lat: ctrl.pinLat,
            lng: ctrl.pinLng,
            onPicked: ctrl.setPin,
          )
        else if (type == 'checkbox')
          _checkbox(key, label)
        else if (widget.chips[key]?.isNotEmpty == true)
          _chips(key, widget.chips[key]!)
        else if (type == 'select' && options.isNotEmpty)
          _dropdown(key, options, flagged)
        else
          _input(key, type, hint, f['max_lines'], flagged),
        if ((widget.notes[key] ?? '').isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(widget.notes[key]!, style: Ds.t.caption),
        ],
      ]),
    );
  }

  /// A tick is an ANSWER, not a style: "I don't have GST" is how a shop with
  /// no GSTIN stops being indistinguishable from a shop nobody has asked.
  Widget _checkbox(String key, String label) {
    final ctrl = widget.controller;
    return InkWell(
      onTap: () => setState(() => ctrl.setCheck(key, !ctrl.checkValue(key))),
      borderRadius: Ds.r.rButton,
      child: SizedBox(
        height: 44,
        child: Row(children: [
          Checkbox(
            value: ctrl.checkValue(key),
            activeColor: Ds.c.brand,
            onChanged: (v) => setState(() => ctrl.setCheck(key, v ?? false)),
          ),
          Flexible(child: Text(label, style: Ds.t.body)),
        ]),
      ),
    );
  }

  InputDecoration _decoration(String hint, bool flagged) => InputDecoration(
        isDense: true,
        filled: true,
        hintText: hint.isEmpty ? null : hint,
        hintStyle: Ds.t.caption,
        fillColor: Ds.c.bg,
        contentPadding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x12),
        enabledBorder: OutlineInputBorder(
          borderRadius: Ds.r.rButton,
          borderSide:
              BorderSide(color: flagged ? Ds.c.warning : Ds.c.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: Ds.r.rButton,
          borderSide: BorderSide(color: Ds.c.brand),
        ),
        border: OutlineInputBorder(borderRadius: Ds.r.rButton),
      );

  Widget _input(
      String key, String type, String hint, Object? maxLines, bool flagged) {
    final lines = maxLines is num ? maxLines.toInt() : 1;
    return TextField(
      controller: widget.controller.controllerFor(key),
      maxLines: lines,
      style: Ds.t.body,
      keyboardType: switch (type) {
        'phone' => TextInputType.phone,
        'number' => TextInputType.number,
        'email' => TextInputType.emailAddress,
        'textarea' => TextInputType.multiline,
        _ => TextInputType.text,
      },
      inputFormatters: (type == 'phone' || type == 'number')
          ? [FilteringTextInputFormatter.digitsOnly]
          : null,
      decoration: _decoration(hint, flagged),
    );
  }

  /// CMD #2126 — one tap picks, a second tap on the same chip clears. Chips
  /// wrap onto as many lines as the phone needs; each is a full touch target.
  Widget _chips(String key, List<String> options) {
    final ctl = widget.controller.controllerFor(key);
    final current = ctl.text.trim();
    return Wrap(
      spacing: Ds.space.x8,
      runSpacing: Ds.space.x8,
      children: [
        for (final o in options)
          Semantics(
            identifier: 'reg_chip_${key}_${options.indexOf(o)}',
            button: true,
            selected: o == current,
            child: InkWell(
              borderRadius: Ds.r.rChip,
              onTap: () => setState(() => ctl.text = o == current ? '' : o),
              child: Container(
                constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: o == current ? Ds.c.brandSoft : Ds.c.surface,
                  borderRadius: Ds.r.rChip,
                  border: Border.all(
                      color: o == current ? Ds.c.brand : Ds.c.divider),
                ),
                child: Text(o,
                    style: o == current
                        ? Ds.t.bodyStrong.copyWith(color: Ds.c.brand)
                        : Ds.t.body),
              ),
            ),
          ),
      ],
    );
  }

  Widget _dropdown(String key, List<String> options, bool flagged) {
    final ctl = widget.controller.controllerFor(key);
    final current = ctl.text.trim();
    // An auto-filled value the backend did not list still shows, so nothing is
    // silently dropped.
    final items = <String>[
      if (current.isNotEmpty && !options.contains(current)) current,
      ...options,
    ];
    return DropdownButtonFormField<String>(
      initialValue: current.isEmpty ? null : current,
      isExpanded: true,
      style: Ds.t.body,
      decoration: _decoration('', flagged),
      items: [
        for (final o in items)
          DropdownMenuItem<String>(
              value: o, child: Text(o, style: Ds.t.body, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (v) => setState(() => ctl.text = v ?? ''),
    );
  }
}

/// CMD #2059 — the form's own outline while the schema is on its way.
///
/// Four labelled bars at field height. It is not a loading message and it is
/// not a spinner: it is what the fields will look like, so the change when
/// they arrive is a fill, not a redraw.
class FormFieldsSkeleton extends StatelessWidget {
  const FormFieldsSkeleton({super.key, this.note = '', this.rows = 4});

  final String note;
  final int rows;

  @override
  Widget build(BuildContext context) {
    Widget bar(double widthFactor, double height) => FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: widthFactor,
          child: Container(
            height: height,
            decoration: BoxDecoration(
                color: Ds.c.divider, borderRadius: Ds.r.rButton),
          ),
        );
    final children = <Widget>[];
    for (var i = 0; i < rows; i++) {
      children
        ..add(bar(0.35, Ds.space.x12))
        ..add(SizedBox(height: Ds.space.x8))
        ..add(bar(1, Ds.touch.minTarget))
        ..add(SizedBox(height: Ds.space.x16));
    }
    if (note.isNotEmpty) {
      children.add(Text(note, style: Ds.t.caption));
    }
    return Padding(
      padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}
