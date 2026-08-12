// CHANGE #547 — Import Customer registration form (Customers tab).
//
// One form, three entry paths:
//   • Import Manually        -> opened empty
//   • Import by File         -> opened pre-filled from customer-import 'extract'
//   • (both)                 -> Location fetch button in the Address section
//
// EVERY field stays fully editable in all paths, including anything the OCR or
// the geocoder filled in.
//
// BACKEND OWNS EVERYTHING:
//   • saving          -> customer-import mode 'import' (provisions the auth
//                        login, writes the profile, auto-approves and sends the
//                        approval WhatsApp). We never call admin_import_customer
//                        directly, and never call an approve/notify RPC after.
//   • address lookup  -> customer-import mode 'geocode'
//   • all messages    -> shown verbatim; this file composes no error copy.
//   • normalisation   -> phone / pincode / GSTIN are NOT formatted or validated
//                        here. The backend normalises and validates them.
import 'dart:convert';

import 'package:file_picker/file_picker.dart';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'geo_position.dart';
import '../services/ui_copy.dart';
import '../utils/render_log.dart';

/// Fields whose per_field_confidence is below this are flagged for review.
const double kLowConfidence = 0.6;

class ImportCustomerSheet extends StatefulWidget {
  /// customer-import 'extract' payload, or null for the manual path.
  final Map<String, dynamic>? extracted;

  /// CHANGE #550 — lead_customer_prefill().customer, for importing a customer
  /// straight from a route visit. Everything stays editable.
  final Map<String, dynamic>? prefill;

  /// CHANGE #550 — lead_customer_prefill().missing[]: fields the lead could
  /// not supply. Highlighted so the rep knows what to fill in.
  final List<String> missing;

  const ImportCustomerSheet({
    super.key,
    this.extracted,
    this.prefill,
    this.missing = const [],
  });

  /// Returns true when a customer was imported (caller should refresh).
  static Future<bool?> open(
    BuildContext context, {
    Map<String, dynamic>? extracted,
    Map<String, dynamic>? prefill,
    List<String> missing = const [],
  }) =>
      showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ImportCustomerSheet(
            extracted: extracted, prefill: prefill, missing: missing),
      );

  @override
  State<ImportCustomerSheet> createState() => _ImportCustomerSheetState();
}

class _ImportCustomerSheetState extends State<ImportCustomerSheet> {
  // Backend field name -> controller. Keyed by the exact name the edge
  // function expects, so submission is a straight map build with no renaming.
  final Map<String, TextEditingController> _c = {
    for (final k in const [
      'pharmacy_name',
      'customer_name',
      'phone',
      'whatsapp_no',
      'other_contact_no',
      'email',
      'address',
      'address_local',
      'city',
      'district',
      'state',
      'pincode',
      'latitude',
      'longitude',
      'store_location_link',
      'store_type',
      'range_zone',
      'payment_term',
      'gstin',
      'dl_20b',
      'dl_21b',
      'customer_code',
    ])
      k: TextEditingController(),
  };

  /// Fields the backend flagged as low-confidence or dropped during extract.
  final Set<String> _review = {};

  // ── CHANGE #549: the form's SHAPE is backend-owned ──────────────────────
  // customer_form_options() decides which fields are hidden, which are
  // required, which are single-select, and what each dropdown's choices are.
  // Nothing here is hardcoded.
  Set<String> _hidden = {};
  Set<String> _required = {};
  Set<String> _singleSelect = {};
  Map<String, List<String>> _choices = {};
  bool _optionsLoaded = false;

  bool _saving = false;
  bool _locating = false;
  bool _forwarding = false;
  bool _scanning = false;

  /// Backend copy only — never a string composed in this file.
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _loadOptions();
    // CHANGE #550: prefill first, then any extract merges on top of it.
    final pre = widget.prefill;
    if (pre != null) {
      for (final k in _c.keys) {
        _set(k, pre[k]);
      }
    }
    _review.addAll(widget.missing);
    final e = widget.extracted;
    if (e != null) _applyExtract(e);
    RenderLog.write('c547_form_open',
        widget.extracted == null ? 'mode=manual' : 'mode=file');
  }

  @override
  void dispose() {
    for (final ctl in _c.values) {
      ctl.dispose();
    }
    super.dispose();
  }

  Future<void> _loadOptions() async {
    try {
      final res = await Supabase.instance.client.rpc('customer_form_options');
      if (res is! Map || !mounted) return;
      final m = Map<String, dynamic>.from(res);
      Set<String> setOf(dynamic v) => v is List
          ? v.map((e) => e.toString()).toSet()
          : <String>{};
      List<String> listOf(dynamic v) => v is List
          ? v.map((e) => e.toString()).toList()
          : <String>[];
      setState(() {
        _hidden = setOf(m['hidden_fields']);
        _required = setOf(m['required_fields']);
        _singleSelect = setOf(m['single_select']);
        _choices = {
          for (final k in _singleSelect) k: listOf(m[k]),
        };
        _optionsLoaded = true;
      });
      RenderLog.write('c549_form_options',
          'hidden=${_hidden.length};required=${_required.length};'
          'single=${_singleSelect.length}');
    } catch (_) {
      // No hardcoded fallback: without options the dropdowns stay empty.
    }
  }

  void _set(String key, dynamic v) {
    final ctl = _c[key];
    if (ctl == null || v == null) return;
    final s = v.toString();
    if (s.isEmpty || s == 'null') return;
    ctl.text = s;
  }

  /// Pre-fills from an 'extract' response and marks anything the backend was
  /// unsure about, so the admin knows to check it.
  void _applyExtract(Map<String, dynamic> e) {
    for (final k in _c.keys) {
      _set(k, e[k]);
    }

    final conf = e['per_field_confidence'];
    if (conf is Map) {
      conf.forEach((k, v) {
        final n = v is num ? v.toDouble() : double.tryParse('$v');
        if (n != null && n < kLowConfidence) _review.add(k.toString());
      });
    }
    final dropped = e['dropped'];
    if (dropped is List) {
      for (final d in dropped) {
        _review.add(d.toString());
      }
    } else if (dropped is Map) {
      _review.addAll(dropped.keys.map((k) => k.toString()));
    }

    final notes = e['notes'];
    if (notes != null && notes.toString().isNotEmpty) _notice = notes.toString();

    RenderLog.write('c547_extract_applied',
        'review=${_review.length};conf=${conf is Map ? conf.length : 0}');
  }

  // ── Location ──────────────────────────────────────────────────────────────

  Future<void> _fetchLocation() async {
    setState(() {
      _locating = true;
      _error = null;
      _notice = null;
    });
    try {
      final pos = await getCurrentPosition(enableHighAccuracy: true);
      final lat = pos?.lat;
      final lng = pos?.lng;
      if (lat == null || lng == null) {
        throw Exception('no_coordinates');
      }

      final res = await Supabase.instance.client.functions.invoke(
        'customer-import',
        body: {'mode': 'geocode', 'lat': lat, 'lng': lng},
      );
      final data = res.data;
      final m = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};

      if (m['error'] != null) {
        setState(() {
          _error = m['error'].toString();
          _locating = false;
        });
        return;
      }

      // 'partial' -> coordinates + map link only; address stays blank.
      final status = m['status']?.toString();
      // CHANGE #549: range_zone is filled from the location response too, and
      // stays editable like every other auto-filled field.
      for (final k in const [
        'address',
        'city',
        'district',
        'state',
        'pincode',
        'latitude',
        'longitude',
        'store_location_link',
        'range_zone',
      ]) {
        _set(k, m[k]);
      }
      // Coordinates always come from the device when the backend omits them.
      if ((_c['latitude']!.text).isEmpty) _c['latitude']!.text = '$lat';
      if ((_c['longitude']!.text).isEmpty) _c['longitude']!.text = '$lng';

      RenderLog.write('c547_geocode', 'status=${status ?? ''}');
      setState(() {
        _locating = false;
        // Backend copy, verbatim.
        final note = m['note'] ?? m['message'] ?? m['notes'];
        if (note != null && note.toString().isNotEmpty) {
          _notice = note.toString();
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _locating = false;
        _error = e is FunctionException
            ? _fnError(e)
            : (_c['store_location_link']!.text.isEmpty ? '$e' : null);
      });
    }
  }

  /// CHANGE #550 — photograph the licence / GST board from inside the form and
  /// MERGE the extracted fields on top of what is already here. Same
  /// customer-import 'extract' mode the Customers tab uses.
  Future<void> _scanDocuments() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty || !mounted) return;
    final files = picked.files.where((f) => f.bytes != null).take(8).toList();
    if (files.isEmpty) return;

    setState(() {
      _scanning = true;
      _error = null;
      _notice = null;
    });
    try {
      final images = [for (final f in files) base64Encode(f.bytes!)];
      final res = await Supabase.instance.client.functions.invoke(
        'customer-import',
        body: {
          'mode': 'extract',
          'images': images,
          'mime_type': 'image/jpeg',
        },
      );
      final data = res.data;
      final m =
          data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
      if (!mounted) return;
      if (m['error'] != null) {
        setState(() {
          _error = m['error'].toString();
          _scanning = false;
        });
        return;
      }
      setState(() {
        _applyExtract(m); // merges over the current values, all still editable
        _scanning = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = e is FunctionException ? _fnError(e) : '$e';
      });
    }
  }

  /// CHANGE #549 — "Fill coordinates": derive coordinates from the address
  /// fields already typed in, via customer-import mode 'forward'.
  Future<void> _fillCoordinates() async {
    setState(() {
      _forwarding = true;
      _error = null;
      _notice = null;
    });
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'customer-import',
        body: {
          'mode': 'forward',
          'address': _c['address']!.text.trim(),
          'city': _c['city']!.text.trim(),
          'district': _c['district']!.text.trim(),
          'state': _c['state']!.text.trim(),
          'pincode': _c['pincode']!.text.trim(),
        },
      );
      final data = res.data;
      final m =
          data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};

      if (m['error'] != null) {
        setState(() {
          _error = m['error'].toString();
          _forwarding = false;
        });
        return;
      }

      for (final k in const [
        'latitude',
        'longitude',
        'store_location_link',
        'range_zone',
      ]) {
        _set(k, m[k]);
      }

      final status = m['status']?.toString();
      RenderLog.write('c549_forward', 'status=${status ?? ''}');
      setState(() {
        _forwarding = false;
        // 'not_found' (and any other) note is backend copy, verbatim.
        final note = m['note'] ?? m['message'] ?? m['notes'];
        if (note != null && note.toString().isNotEmpty) {
          _notice = note.toString();
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _forwarding = false;
        _error = e is FunctionException ? _fnError(e) : '$e';
      });
    }
  }

  /// Pulls the backend's own {"error": "..."} out of a FunctionException.
  String _fnError(FunctionException e) {
    final d = e.details;
    if (d is Map && d['error'] != null) return d['error'].toString();
    if (d != null && d.toString().isNotEmpty) return d.toString();
    return e.reasonPhrase ?? '';
  }

  // ── Save ──────────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    try {
      // Straight pass-through: no client-side formatting or validation. Empty
      // fields are omitted so the backend applies its own defaults.
      // CHANGE #549: hidden fields are NEVER sent — customer_code is generated
      // by the backend (same logic as supplier codes) and address_local is gone.
      final customer = <String, dynamic>{};
      _c.forEach((k, v) {
        if (_hidden.contains(k)) return;
        final s = v.text.trim();
        if (s.isNotEmpty) customer[k] = s;
      });

      final res = await Supabase.instance.client.functions.invoke(
        'customer-import',
        body: {'mode': 'import', 'customer': customer},
      );
      final data = res.data;
      final m = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};

      if (m['error'] != null) {
        setState(() {
          _error = m['error'].toString(); // verbatim
          _saving = false;
        });
        return;
      }

      final code = m['customer_code']?.toString() ?? '';
      final msg = m['message']?.toString() ?? '';
      RenderLog.write('c547_import_ok', 'code=$code');
      if (!mounted) return;
      Navigator.of(context).pop(true);
      final banner = [msg, if (code.isNotEmpty) code].where((s) => s.isNotEmpty);
      if (banner.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(banner.join('  ·  ')),
          backgroundColor: const Color(0xFF1B7A43),
          duration: const Duration(seconds: 6),
        ));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e is FunctionException ? _fnError(e) : '$e';
      });
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  /// CHANGE #549: renders nothing for a backend-hidden field, marks required
  /// from required_fields, and renders a single-select dropdown when the
  /// backend lists the field in single_select.
  Widget _field(String key, String label, {int maxLines = 1}) {
    if (_hidden.contains(key)) return const SizedBox.shrink();
    if (_singleSelect.contains(key)) return _dropdown(key, label);

    final required = _required.contains(key);
    final flagged = _review.contains(key);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(required ? cf('import_customer.required_label', {'label': label}) : label,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF374151))),
          if (flagged) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(c('import_customer.flag_check_this'),
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF92400E))),
            ),
          ],
        ]),
        const SizedBox(height: 6),
        TextField(
          controller: _c[key],
          maxLines: maxLines,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: const Color(0xFFF5F6F8),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(
                  color: flagged
                      ? const Color(0xFFFCD34D)
                      : const Color(0xFFE5E7EB)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
            ),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ]),
    );
  }

  /// Single-select built from customer_form_options()'s own list. The current
  /// value is kept in the same controller as every other field, so submission
  /// and auto-fill (e.g. range_zone from the location response) work unchanged.
  Widget _dropdown(String key, String label) {
    final required = _required.contains(key);
    final flagged = _review.contains(key);
    final opts = _choices[key] ?? const <String>[];
    final cur = _c[key]!.text.trim();
    // An auto-filled value the backend didn't list still shows, so nothing is
    // silently dropped — the admin can re-pick from the list.
    final items = <String>[
      if (cur.isNotEmpty && !opts.contains(cur)) cur,
      ...opts,
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(required ? cf('import_customer.required_label', {'label': label}) : label,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF374151))),
          if (flagged) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(c('import_customer.flag_check_this'),
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF92400E))),
            ),
          ],
        ]),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          initialValue: cur.isEmpty ? null : cur,
          isExpanded: true,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: const Color(0xFFF5F6F8),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(
                  color: flagged
                      ? const Color(0xFFFCD34D)
                      : const Color(0xFFE5E7EB)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
            ),
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          items: [
            for (final o in items)
              DropdownMenuItem<String>(value: o, child: Text(o)),
          ],
          // Still fully editable — re-picking simply overwrites the value.
          onChanged: (v) => setState(() => _c[key]!.text = v ?? ''),
        ),
      ]),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 12),
        child: Text(title,
            style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: Color(0xFF9CA3AF),
                letterSpacing: 1.0)),
      );

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final isNarrow = w < 600;

    return Dialog(
      insetPadding: EdgeInsets.symmetric(
          horizontal: isNarrow ? 12 : 40, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
            child: Row(children: [
              Expanded(
                child: Text(c('import_customer.title'),
                    style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111827))),
              ),
              IconButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(false),
                icon: const Icon(Icons.close, size: 20, color: Color(0xFF6B7280)),
              ),
            ]),
          ),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),

          Expanded(
            child: !_optionsLoaded
                // CHANGE #549: the form's shape (hidden / required / dropdown
                // choices) is backend-owned, so nothing renders until
                // customer_form_options() has landed.
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: CircularProgressIndicator(
                          color: Color(0xFF1B7A43), strokeWidth: 2.5),
                    ),
                  )
                : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (_notice != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    // Backend copy, verbatim.
                    child: Text(_notice!,
                        style: const TextStyle(
                            fontSize: 13, color: Color(0xFF1E40AF))),
                  ),
                ],
                if (_review.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF3C7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                        cf('import_customer.review_banner', {'n': '${_review.length}'}),
                        style: const TextStyle(
                            fontSize: 13, color: Color(0xFF92400E))),
                  ),

                // CHANGE #550 — the same two paths the Customers tab offers:
                // fill it in by hand, or photograph the licence / GST board and
                // let customer-import 'extract' merge those fields in.
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: OutlinedButton.icon(
                    onPressed: _scanning ? null : _scanDocuments,
                    icon: _scanning
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Color(0xFF1B7A43)))
                        : const Icon(Icons.document_scanner_outlined, size: 16),
                    label: Text(c('import_customer.btn_scan')),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF1B7A43),
                      side: const BorderSide(color: Color(0xFF1B7A43)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),

                _section(c('import_customer.section_business')),
                _field('pharmacy_name', c('import_customer.field_pharmacy_name')),
                _field('customer_name', c('import_customer.field_customer_name')),
                _field('store_type', c('import_customer.field_store_type')),

                _section(c('import_customer.section_contact')),
                _field('phone', c('import_customer.field_phone')),
                _field('whatsapp_no', c('import_customer.field_whatsapp_no')),
                _field('other_contact_no', c('import_customer.field_other_contact_no')),
                _field('email', c('import_customer.field_email')),

                _section(c('import_customer.section_address')),
                // CHANGE #549 — two backend-driven location actions.
                //  • Fetch current location : device GPS -> mode 'geocode'
                //  • Fill coordinates       : typed address -> mode 'forward'
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    OutlinedButton.icon(
                      onPressed:
                          (_locating || _forwarding) ? null : _fetchLocation,
                      icon: _locating
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Color(0xFF1B7A43)))
                          : const Icon(Icons.my_location, size: 16),
                      label: Text(c('import_customer.btn_fetch_location')),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF1B7A43),
                        side: const BorderSide(color: Color(0xFF1B7A43)),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed:
                          (_locating || _forwarding) ? null : _fillCoordinates,
                      icon: _forwarding
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Color(0xFF1B7A43)))
                          : const Icon(Icons.place_outlined, size: 16),
                      label: Text(c('import_customer.btn_fill_coordinates')),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF1B7A43),
                        side: const BorderSide(color: Color(0xFF1B7A43)),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ]),
                ),
                _field('address', c('import_customer.field_address'), maxLines: 2),
                if (isNarrow) ...[
                  _field('city', c('import_customer.field_city')),
                  _field('district', c('import_customer.field_district')),
                ] else
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: _field('city', c('import_customer.field_city'))),
                    const SizedBox(width: 12),
                    Expanded(child: _field('district', c('import_customer.field_district'))),
                  ]),
                if (isNarrow) ...[
                  _field('state', c('import_customer.field_state')),
                  _field('pincode', c('import_customer.field_pincode')),
                ] else
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: _field('state', c('import_customer.field_state'))),
                    const SizedBox(width: 12),
                    Expanded(child: _field('pincode', c('import_customer.field_pincode'))),
                  ]),
                if (isNarrow) ...[
                  _field('latitude', c('import_customer.field_latitude')),
                  _field('longitude', c('import_customer.field_longitude')),
                ] else
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: _field('latitude', c('import_customer.field_latitude'))),
                    const SizedBox(width: 12),
                    Expanded(child: _field('longitude', c('import_customer.field_longitude'))),
                  ]),
                _field('store_location_link', c('import_customer.field_store_location_link')),
                _field('range_zone', c('import_customer.field_range_zone')),
                _field('payment_term', c('import_customer.field_payment_term')),

                _section(c('import_customer.section_statutory')),
                _field('gstin', c('import_customer.field_gstin')),
                if (isNarrow) ...[
                  _field('dl_20b', c('import_customer.field_dl_20b')),
                  _field('dl_21b', c('import_customer.field_dl_21b')),
                ] else
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: _field('dl_20b', c('import_customer.field_dl_20b'))),
                    const SizedBox(width: 12),
                    Expanded(child: _field('dl_21b', c('import_customer.field_dl_21b'))),
                  ]),
              ]),
            ),
          ),

          if (_error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              color: const Color(0xFFFEE2E2),
              // Backend message, verbatim.
              child: Text(_error!,
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFF991B1B))),
            ),

          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Row(children: [
              const Spacer(),
              TextButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(false),
                child: Text(c('import_customer.btn_cancel'),
                    style: const TextStyle(color: Color(0xFF6B7280))),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _saving ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1B7A43),
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
                child: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(c('import_customer.btn_save'),
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
