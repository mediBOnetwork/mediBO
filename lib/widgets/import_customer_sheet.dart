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
// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

/// Fields whose per_field_confidence is below this are flagged for review.
const double kLowConfidence = 0.6;

class ImportCustomerSheet extends StatefulWidget {
  /// customer-import 'extract' payload, or null for the manual path.
  final Map<String, dynamic>? extracted;

  const ImportCustomerSheet({super.key, this.extracted});

  /// Returns true when a customer was imported (caller should refresh).
  static Future<bool?> open(BuildContext context,
          {Map<String, dynamic>? extracted}) =>
      showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ImportCustomerSheet(extracted: extracted),
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

  bool _saving = false;
  bool _locating = false;

  /// Backend copy only — never a string composed in this file.
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
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
      final completer = Completer<html.Geoposition>();
      html.window.navigator.geolocation
          .getCurrentPosition(
              enableHighAccuracy: true, timeout: const Duration(seconds: 20))
          .then((p) {
        if (!completer.isCompleted) completer.complete(p);
      }).catchError((e) {
        if (!completer.isCompleted) completer.completeError(e);
      });
      final pos = await completer.future.timeout(const Duration(seconds: 25));
      final lat = pos.coords?.latitude?.toDouble();
      final lng = pos.coords?.longitude?.toDouble();
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
      for (final k in const [
        'address',
        'city',
        'district',
        'state',
        'pincode',
        'latitude',
        'longitude',
        'store_location_link',
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
      final customer = <String, dynamic>{};
      _c.forEach((k, v) {
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

  Widget _field(String key, String label, {bool required = false, int maxLines = 1}) {
    final flagged = _review.contains(key);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(required ? '$label *' : label,
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
              child: const Text('Check this',
                  style: TextStyle(
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
              borderSide: const BorderSide(color: Color(0xFF1B7A43)),
            ),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ]),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 12),
        child: Text(title.toUpperCase(),
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
              const Expanded(
                child: Text('Complete Registration',
                    style: TextStyle(
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
            child: SingleChildScrollView(
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
                        '${_review.length} field(s) marked "Check this" — the scan was unsure. Review before saving.',
                        style: const TextStyle(
                            fontSize: 13, color: Color(0xFF92400E))),
                  ),

                _section('Business'),
                _field('pharmacy_name', 'Pharmacy name', required: true),
                _field('customer_name', 'Customer name'),
                _field('store_type', 'Store type'),
                _field('customer_code', 'Customer code'),

                _section('Contact'),
                _field('phone', 'Phone', required: true),
                _field('whatsapp_no', 'WhatsApp number'),
                _field('other_contact_no', 'Other contact number'),
                _field('email', 'Email'),

                Row(children: [
                  Expanded(child: _section('Address')),
                  if (_locating)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 4),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(0xFF1B7A43)),
                      ),
                    )
                  else
                    OutlinedButton.icon(
                      onPressed: _fetchLocation,
                      icon: const Icon(Icons.my_location, size: 16),
                      label: const Text('Fetch location'),
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
                _field('address', 'Address', required: true, maxLines: 2),
                _field('address_local', 'Address (local language)', maxLines: 2),
                if (isNarrow) ...[
                  _field('city', 'City', required: true),
                  _field('district', 'District'),
                ] else
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: _field('city', 'City', required: true)),
                    const SizedBox(width: 12),
                    Expanded(child: _field('district', 'District')),
                  ]),
                if (isNarrow) ...[
                  _field('state', 'State'),
                  _field('pincode', 'Pincode', required: true),
                ] else
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: _field('state', 'State')),
                    const SizedBox(width: 12),
                    Expanded(child: _field('pincode', 'Pincode', required: true)),
                  ]),
                if (isNarrow) ...[
                  _field('latitude', 'Latitude'),
                  _field('longitude', 'Longitude'),
                ] else
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: _field('latitude', 'Latitude')),
                    const SizedBox(width: 12),
                    Expanded(child: _field('longitude', 'Longitude')),
                  ]),
                _field('store_location_link', 'Store location link'),
                _field('range_zone', 'Range zone'),
                _field('payment_term', 'Payment term'),

                _section('Statutory'),
                _field('gstin', 'GSTIN'),
                if (isNarrow) ...[
                  _field('dl_20b', 'DL 20B'),
                  _field('dl_21b', 'DL 21B'),
                ] else
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: _field('dl_20b', 'DL 20B')),
                    const SizedBox(width: 12),
                    Expanded(child: _field('dl_21b', 'DL 21B')),
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
                child: const Text('Cancel',
                    style: TextStyle(color: Color(0xFF6B7280))),
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
                    : const Text('Save customer',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
