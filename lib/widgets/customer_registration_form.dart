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
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';

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

  String text(String key) => (_schema?[key] ?? '').toString();

  Future<void> load() async {
    try {
      final res = await Supabase.instance.client
          .rpc('customer_form_schema', params: {'p_context': formContext});
      if (res is Map) {
        _schema = Map<String, dynamic>.from(res);
        for (final f in fields) {
          final k = f['key'].toString();
          final ctl = controllerFor(k);
          final def = f['default'];
          if (ctl.text.isEmpty && def != null && def.toString().isNotEmpty) {
            ctl.text = def.toString();
          }
        }
        RenderLog.write('c1887_form_schema',
            'ctx=$formContext;fields=${fields.length};req=${requiredKeys.length}');
      }
    } catch (e) {
      loadError = '$e';
    }
    notifyListeners();
  }

  TextEditingController controllerFor(String key) =>
      _ctl.putIfAbsent(key, () => TextEditingController());

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
      final v = (_ctl[k]?.text ?? '').trim();
      if (v.isNotEmpty) out[k] = v;
    }
    return out;
  }

  /// Required keys with nothing typed in them — the backend's own list.
  List<String> missingRequired() => [
        for (final k in requiredKeys)
          if ((_ctl[k]?.text ?? '').trim().isEmpty) k,
      ];

  String labelOf(String key) {
    for (final f in fields) {
      if (f['key'].toString() == key) return f['label'].toString();
    }
    return key;
  }

  @override
  void dispose() {
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
  });

  final CustomerFormController controller;

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
      return Padding(
        padding: EdgeInsets.all(Ds.space.x32),
        child: Column(children: [
          SizedBox(
            width: Ds.space.x24,
            height: Ds.space.x24,
            child: CircularProgressIndicator(color: Ds.c.brand),
          ),
          SizedBox(height: Ds.space.x12),
          Text(ctrl.loadError ?? ctrl.text('loading_label'),
              style: Ds.t.caption, textAlign: TextAlign.center),
        ]),
      );
    }

    final wide = MediaQuery.of(context).size.width >= 600;
    final children = <Widget>[];
    if (widget.header != null) {
      children
        ..add(widget.header!)
        ..add(SizedBox(height: Ds.space.x16));
    }

    for (final section in ctrl.sections) {
      children.add(_sectionTitle(section['title'].toString()));
      final fields = ((section['fields'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
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

    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
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
        SizedBox(height: Ds.space.x4),
        if (type == 'select' && options.isNotEmpty)
          _dropdown(key, options, flagged)
        else
          _input(key, type, hint, f['max_lines'], flagged),
      ]),
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
