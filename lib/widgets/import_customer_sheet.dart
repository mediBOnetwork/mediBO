// Import Customer / Convert lead — now just a shell around THE registration
// form (CHANGE #1887).
//
// One form, three entry paths, and they are the same widget as self-signup:
//   • Import Manually  -> opened empty
//   • Import by File   -> opened pre-filled from customer-import 'extract'
//   • Convert lead     -> opened pre-filled from lead_customer_prefill()
//
// The field list, labels, order, required flags and dropdown options all come
// from customer_form_schema(); this file composes no display string.
//
// BACKEND OWNS EVERYTHING:
//   • saving          -> admin_import_customer(), which provisions the auth
//                        login itself (WhatsApp number as the identity, no
//                        password, OTP later). CHANGE #1887 retired the
//                        customer-import 'import' round-trip; the edge
//                        function stays for CSV bulk import, OCR extract and
//                        geocoding only.
//   • address lookup  -> customer-import mode 'geocode' / 'forward'
//   • all messages    -> shown verbatim; this file composes no error copy.
//   • normalisation   -> phone / pincode / GSTIN are NOT formatted or validated
//                        here. The backend normalises and validates them.
import 'dart:convert';

import 'package:file_picker/file_picker.dart';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'customer_registration_form.dart';
import 'geo_position.dart';
import '../design_tokens.dart';
import '../services/ui_copy.dart';
import '../utils/render_log.dart';

/// Fields whose per_field_confidence is below this are flagged for review.
const double kLowConfidence = 0.6;

class ImportCustomerSheet extends StatefulWidget {
  /// customer-import 'extract' payload, or null for the manual path.
  final Map<String, dynamic>? extracted;

  /// lead_customer_prefill().customer, for importing a customer straight from
  /// a route visit. Everything stays editable.
  final Map<String, dynamic>? prefill;

  /// lead_customer_prefill().missing[]: fields the lead could not supply.
  final List<String> missing;

  /// CMD #1874 — the lead this form was opened from. When it is set the save
  /// goes through lead_import_customer(), which writes the customer AND the
  /// lead's matched_customer_id in ONE transaction, so a converted shop can
  /// never be left as an unlinked lead.
  final int? leadId;

  /// Which schema the backend should send. A caller may name it; otherwise a
  /// sheet opened with a LEAD prefill is the Convert-lead surface and asks for
  /// that schema, so the S Leads call sites need no change to get their own
  /// title and field list.
  final String? formContext;

  String get schemaContext =>
      formContext ?? (prefill != null ? 'lead_convert' : 'admin');

  const ImportCustomerSheet({
    super.key,
    this.extracted,
    this.prefill,
    this.missing = const [],
    this.formContext,
    this.leadId,
  });

  /// Returns true when a customer was imported (caller should refresh).
  static Future<bool?> open(
    BuildContext context, {
    Map<String, dynamic>? extracted,
    Map<String, dynamic>? prefill,
    List<String> missing = const [],
    String? formContext,
    int? leadId,
  }) =>
      showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ImportCustomerSheet(
            extracted: extracted,
            prefill: prefill,
            missing: missing,
            formContext: formContext,
            leadId: leadId),
      );

  @override
  State<ImportCustomerSheet> createState() => _ImportCustomerSheetState();
}

class _ImportCustomerSheetState extends State<ImportCustomerSheet> {
  late final CustomerFormController _form =
      CustomerFormController(formContext: widget.schemaContext);

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
    // Prefill first, then any extract merges on top of it.
    _form.applyMap(widget.prefill);
    _form.flagged.addAll(widget.missing);
    final e = widget.extracted;
    if (e != null) _applyExtract(e);
    RenderLog.write('c547_form_open',
        widget.extracted == null ? 'mode=manual' : 'mode=file');
  }

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  /// Pre-fills from an 'extract' response and marks anything the backend was
  /// unsure about, so the admin knows to check it.
  void _applyExtract(Map<String, dynamic> e) {
    _form.applyMap(e);

    final conf = e['per_field_confidence'];
    if (conf is Map) {
      conf.forEach((k, v) {
        final n = v is num ? v.toDouble() : double.tryParse('$v');
        if (n != null && n < kLowConfidence) _form.flagged.add(k.toString());
      });
    }
    final dropped = e['dropped'];
    if (dropped is List) {
      for (final d in dropped) {
        _form.flagged.add(d.toString());
      }
    } else if (dropped is Map) {
      _form.flagged.addAll(dropped.keys.map((k) => k.toString()));
    }

    final notes = e['notes'];
    if (notes != null && notes.toString().isNotEmpty) _notice = notes.toString();

    RenderLog.write('c547_extract_applied',
        'review=${_form.flagged.length};conf=${conf is Map ? conf.length : 0}');
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

      final status = m['status']?.toString();
      _form.applyMap(m);
      // Coordinates always come from the device when the backend omits them.
      if (_form.controllerFor('latitude').text.isEmpty) {
        _form.setValue('latitude', '$lat');
      }
      if (_form.controllerFor('longitude').text.isEmpty) {
        _form.setValue('longitude', '$lng');
      }

      RenderLog.write('c547_geocode', 'status=${status ?? ''}');
      setState(() {
        _locating = false;
        final note = m['note'] ?? m['message'] ?? m['notes'];
        if (note != null && note.toString().isNotEmpty) {
          _notice = note.toString();
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _locating = false;
        _error = e is FunctionException ? _fnError(e) : '$e';
      });
    }
  }

  /// Photograph the licence / GST board from inside the form and MERGE the
  /// extracted fields on top of what is already here.
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

  /// "Fill coordinates": derive coordinates from the address fields already
  /// typed in, via customer-import mode 'forward'.
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
          'address': _form.controllerFor('address').text.trim(),
          'city': _form.controllerFor('city').text.trim(),
          'district': _form.controllerFor('district').text.trim(),
          'state': _form.controllerFor('state').text.trim(),
          'pincode': _form.controllerFor('pincode').text.trim(),
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
        _form.setValue(k, m[k]);
      }

      final status = m['status']?.toString();
      RenderLog.write('c549_forward', 'status=${status ?? ''}');
      setState(() {
        _forwarding = false;
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
    final missing = _form.missingRequired();
    if (missing.isNotEmpty) {
      setState(() {
        // Backend copy; the field names come from the schema too.
        _error = '${_form.text('missing_required_message')} '
            '${missing.map(_form.labelOf).join(', ')}';
        for (final k in missing) {
          _form.flagged.add(k);
        }
      });
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    try {
      // CHANGE #1887 — straight to the RPC. admin_import_customer() makes the
      // auth login itself when there is no user_id, so adding a shop is one
      // call, not an edge-function round-trip first.
      // CMD #1874 — opened from a lead, the save is the lead-aware wrapper:
      // same import, plus the link back onto scraped_leads, one transaction.
      final res = widget.leadId == null
          ? await Supabase.instance.client
              .rpc('admin_import_customer', params: {'p': _form.payload()})
          : await Supabase.instance.client.rpc('lead_import_customer',
              params: {'p': _form.payload(), 'p_lead_id': widget.leadId});
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};

      if (m['error'] != null) {
        setState(() {
          _error = m['error'].toString(); // verbatim
          _saving = false;
        });
        return;
      }

      final code = m['customer_code']?.toString() ?? '';
      final msg = m['message']?.toString() ?? '';
      final stage = m['stage_label']?.toString() ?? '';
      // CMD #1874 — the link's own sentence, verbatim, when there was a lead.
      final link = m['link_message']?.toString() ?? '';
      RenderLog.write('c1887_import_ok',
          'code=$code;login=${m['login_created']};stage=${m['registration_stage']}');
      if (!mounted) return;
      Navigator.of(context).pop(true);
      final banner =
          [msg, link, code, stage].where((s) => s.isNotEmpty).join('  ·  ');
      if (banner.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(banner),
          backgroundColor: Ds.c.brand,
        ));
      }
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message; // the backend's own sentence, verbatim
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e is FunctionException ? _fnError(e) : '$e';
      });
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  Widget _actionButton({
    required bool busy,
    required VoidCallback? onPressed,
    required IconData icon,
    required String label,
  }) =>
      OutlinedButton.icon(
        onPressed: onPressed,
        icon: busy
            ? SizedBox(
                width: Ds.space.x16,
                height: Ds.space.x16,
                child: CircularProgressIndicator(color: Ds.c.brand))
            : Icon(icon),
        label: Text(label),
      );

  Widget _banner(String text, Color background) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x12),
        margin: EdgeInsets.only(bottom: Ds.space.x16),
        decoration:
            BoxDecoration(color: background, borderRadius: Ds.r.rButton),
        // Backend copy, verbatim.
        child: Text(text, style: Ds.t.body),
      );

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final isNarrow = w < 600;

    return Dialog(
      insetPadding: EdgeInsets.symmetric(
          horizontal: isNarrow ? Ds.space.x12 : Ds.space.x48,
          vertical: Ds.space.x24),
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rCard),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: Ds.space.x48 * 15, maxHeight: Ds.space.x48 * 15),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Header — the title is the schema's, so Convert lead says so itself.
          Padding(
            padding: EdgeInsets.fromLTRB(
                Ds.space.x24, Ds.space.x16, Ds.space.x12, Ds.space.x12),
            child: Row(children: [
              Expanded(
                child: Text(
                    _form.ready ? _form.text('title') : c('import_customer.title'),
                    style: Ds.t.title),
              ),
              IconButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(false),
                icon: const Icon(Icons.close),
              ),
            ]),
          ),
          Divider(height: Ds.space.x4, thickness: Ds.space.hairline, color: Ds.c.divider),

          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                  Ds.space.x24, Ds.space.x16, Ds.space.x24, Ds.space.x16),
              child: CustomerRegistrationForm(
                controller: _form,
                header: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_notice != null) _banner(_notice!, Ds.c.infoSoft),
                      if (_form.flagged.isNotEmpty)
                        _banner(
                            cf('import_customer.review_banner',
                                {'n': '${_form.flagged.length}'}),
                            Ds.c.warningSoft),
                      if (_form.ready)
                        Padding(
                          padding: EdgeInsets.only(bottom: Ds.space.x12),
                          child:
                              Text(_form.text('subtitle'), style: Ds.t.caption),
                        ),
                      Wrap(
                          spacing: Ds.space.x8,
                          runSpacing: Ds.space.x8,
                          children: [
                            _actionButton(
                              busy: _scanning,
                              onPressed: _scanning ? null : _scanDocuments,
                              icon: Icons.document_scanner_outlined,
                              label: c('import_customer.btn_scan'),
                            ),
                            _actionButton(
                              busy: _locating,
                              onPressed: (_locating || _forwarding)
                                  ? null
                                  : _fetchLocation,
                              icon: Icons.my_location,
                              label: c('import_customer.btn_fetch_location'),
                            ),
                            _actionButton(
                              busy: _forwarding,
                              onPressed: (_locating || _forwarding)
                                  ? null
                                  : _fillCoordinates,
                              icon: Icons.place_outlined,
                              label: c('import_customer.btn_fill_coordinates'),
                            ),
                          ]),
                    ]),
              ),
            ),
          ),

          if (_error != null)
            Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x24, vertical: Ds.space.x12),
              color: Ds.c.dangerSoft,
              // Backend message, verbatim.
              child: Text(_error!, style: Ds.t.body),
            ),

          Divider(height: Ds.space.x4, thickness: Ds.space.hairline, color: Ds.c.divider),
          Padding(
            padding: EdgeInsets.fromLTRB(
                Ds.space.x24, Ds.space.x12, Ds.space.x24, Ds.space.x16),
            child: Row(children: [
              const Spacer(),
              TextButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(false),
                child: Text(_form.ready
                    ? _form.text('cancel_label')
                    : c('import_customer.btn_cancel')),
              ),
              SizedBox(width: Ds.space.x8),
              ElevatedButton(
                onPressed: (_saving || !_form.ready) ? null : _submit,
                child: _saving
                    ? SizedBox(
                        width: Ds.space.x16,
                        height: Ds.space.x16,
                        child: CircularProgressIndicator(color: Ds.c.surface))
                    : Text(_form.ready
                        ? _form.text('save_label')
                        : c('import_customer.btn_save')),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
