// lib/screens/delivery/delivery_id_scan.dart — CHANGE #631 (PART A)
//
// "Scan Aadhaar / Driving licence" — ONE implementation, used by BOTH places a
// delivery partner is created:
//   (a) the public registration form  -> DeliveryRegisterScreen
//   (b) the agency's "Add rider" form -> AgencyTeamSection
//
// A2 — the image goes to the `delivery-id-ocr` edge function, which has
// verify_jwt=true. functions.invoke() attaches the live session's JWT itself,
// exactly as customer-payment-upload and wa-media-url are called elsewhere in
// this app; no token is read, cached or passed by hand here.
//
// A3 — the response's `prefill` keys are ALREADY the form's field names. This
// file therefore does no mapping and no renaming: it hands `prefill` to the
// caller verbatim and the caller assigns key -> controller. doc_type_label and
// confidence are printed as received — the app never decides what a document is
// called or how sure the read was.
//
// A5/A6 — `ocr_payload` and the uploaded `id_doc_path` are carried on the
// result object so the submitting form passes BOTH through to
// delivery_partner_register / agency_add_partner untouched.
//
// A3 (the rule that outranks the rest) — THE SCAN IS A SHORTCUT, NEVER A LOCK.
// This file owns no TextEditingController and disables no field. It emits a
// result; the form stays editable because the form's fields were never made
// read-only in the first place.

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../fulfill/fulfill_lookups.dart';
import '../../utils/doc_scan.dart';
import '../../utils/doc_capture.dart';
import '../../utils/render_log.dart';

Color get _kGreen => FulfillLookups.instance.color('c_ff1b7a43', const Color(0xFF1B7A43));
Color get _kBorder => FulfillLookups.instance.color('c_ffe5e7eb', const Color(0xFFE5E7EB));
Color get _kText => FulfillLookups.instance.color('c_ff111827', const Color(0xFF111827));
Color get _kSub => FulfillLookups.instance.color('c_ff6b7280', const Color(0xFF6B7280));
Color get _kBad => FulfillLookups.instance.color('c_ffb42318', const Color(0xFFB42318));

String _ui(String k) => FulfillLookups.instance.ui(k);

/// What one successful scan produced. Every field is the edge function's own
/// value — nothing here is derived, reworded or defaulted by the app.
class IdScanResult {
  /// 'aadhaar' | 'dl'
  final String docType;

  /// "Aadhaar card" / "Driving licence" — the backend's wording, printed as-is.
  final String docTypeLabel;

  /// 'high' | 'medium' | 'low' — printed as-is.
  final String confidence;

  /// full_name, id_doc_type, id_doc_number, address, city, state, pincode.
  /// The keys ARE the form's field names; the caller assigns them directly.
  final Map<String, dynamic> prefill;

  /// dob, gender, valid_till, vehicle_classes — shown read-only.
  final Map<String, dynamic> extra;

  /// The raw model output, passed straight through on submit (A5).
  final Map<String, dynamic> ocrPayload;

  /// Storage path of the captured image, so an admin can eyeball the original
  /// during approval (A6). '' when the upload did not land — never null.
  final String idDocPath;

  const IdScanResult({
    required this.docType,
    required this.docTypeLabel,
    required this.confidence,
    required this.prefill,
    required this.extra,
    required this.ocrPayload,
    required this.idDocPath,
  });
}

/// The scan control. Drop it above any delivery-partner form.
///
/// [onScanned] fires once per successful read; the parent copies `prefill` into
/// its controllers and keeps `ocrPayload` + `idDocPath` for its submit call.
class DeliveryIdScanCard extends StatefulWidget {
  final void Function(IdScanResult) onScanned;

  const DeliveryIdScanCard({super.key, required this.onScanned});

  @override
  State<DeliveryIdScanCard> createState() => _DeliveryIdScanCardState();
}

class _DeliveryIdScanCardState extends State<DeliveryIdScanCard> {
  bool _busy = false;

  /// The last result, so the chip + read-only detail block can be shown.
  IdScanResult? _last;

  /// A4 — the refusal to print. `_errTitle` is '' when the backend sent no
  /// title; both are printed verbatim and never replaced with a Dart sentence.
  String _errTitle = '';
  String _errMessage = '';

  // ── A2: capture ───────────────────────────────────────────────────────────

  /// The camera. On Android this launches the ML Kit Document Scanner (auto
  /// edge-detect/deskew/crop/cleanup; front/back + multiple licences in one
  /// session). On web Chrome, or any device without the Play Services scanner
  /// module, it falls back to the original capture intent unchanged; when no
  /// camera is available the picker simply returns null and the form stays
  /// typeable. Each scanned page runs the SAME _scan() OCR + upload as before.
  Future<void> _fromCamera() async {
    try {
      await captureDocument(
        scan: () => scanDocuments(pageLimit: 5), // front/back + multiple licences
        cameraFallback: () async {
          final picked = await ImagePicker().pickImage(
              source: ImageSource.camera, imageQuality: 85, maxWidth: 1800);
          if (picked == null) return null;
          return (name: picked.name, bytes: await picked.readAsBytes());
        },
        handlePage: (page) =>
            _scan(page.bytes, _mimeFor(page.name), page.name),
      );
    } catch (e) {
      RenderLog.write('c630_scan_camera_err', e.toString());
    }
  }

  /// #259's lesson: on web PWA the native chooser is reliable through
  /// FilePicker(withData: true) where image_picker's gallery source is not.
  Future<void> _fromFile() async {
    try {
      final res = await FilePicker.pickFiles(type: FileType.image, withData: true);
      if (res == null || res.files.isEmpty) return;
      final f = res.files.first;
      final bytes = f.bytes;
      if (bytes == null) return;
      await _scan(bytes, _mimeFor(f.name), f.name);
    } catch (e) {
      RenderLog.write('c630_scan_file_err', e.toString());
    }
  }

  String _mimeFor(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.png')) return 'image/png';
    if (n.endsWith('.webp')) return 'image/webp';
    if (n.endsWith('.heic')) return 'image/heic';
    return 'image/jpeg';
  }

  String _extFor(String mime) {
    if (mime.contains('png')) return 'png';
    if (mime.contains('webp')) return 'webp';
    if (mime.contains('heic')) return 'heic';
    return 'jpg';
  }

  // ── A6: keep the original for the approving admin ─────────────────────────

  /// Uploads to `partner-docs` and returns the object path, or '' — never null,
  /// so the submitted payload never carries one.
  Future<String> _upload(Uint8List bytes, String mime) async {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id ?? 'anon';
      final path =
          'ids/${uid}_${DateTime.now().millisecondsSinceEpoch}.${_extFor(mime)}';
      await Supabase.instance.client.storage.from('partner-docs').uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(contentType: mime, upsert: true),
          );
      return path;
    } catch (e) {
      // A failed upload must not block the scan: the fields still fill in and
      // the partner can still submit. Only the admin's "compare the card"
      // convenience is lost, and id_doc_path is then honestly empty.
      RenderLog.write('c630_scan_upload_err', e.toString());
      return '';
    }
  }

  // ── A2/A3/A4: the call ────────────────────────────────────────────────────

  Future<void> _scan(Uint8List bytes, String mime, String name) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _errTitle = '';
      _errMessage = '';
    });
    try {
      // The upload and the read are independent; the read is what fills fields.
      final docPath = await _upload(bytes, mime);

      final res = await Supabase.instance.client.functions.invoke(
        'delivery-id-ocr',
        body: {
          'image_base64': base64Encode(bytes),
          'mime_type': mime,
        },
      );
      if (!mounted) return;
      _apply(res.data, docPath);
    } on FunctionException catch (e) {
      if (!mounted) return;
      // Non-2xx still carries the backend's own body — print that, not a
      // sentence invented here.
      _apply(e.details, '');
    } catch (e) {
      if (!mounted) return;
      RenderLog.write('c630_scan_err', e.toString());
      setState(() {
        _errTitle = '';
        _errMessage = e.toString();
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, dynamic> _map(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  void _apply(dynamic data, String docPath) {
    final m = _map(data);

    if (m['ok'] == true) {
      final out = IdScanResult(
        docType: m['doc_type']?.toString() ?? '',
        docTypeLabel: m['doc_type_label']?.toString() ?? '',
        confidence: m['confidence']?.toString() ?? '',
        prefill: _map(m['prefill']),
        extra: _map(m['extra']),
        ocrPayload: _map(m['ocr_payload']),
        idDocPath: docPath,
      );
      setState(() {
        _last = out;
        _errTitle = '';
        _errMessage = '';
      });
      RenderLog.write('c631_delivery_onboarding',
          'scan_ok;type=${out.docType};conf=${out.confidence};'
          'fields=${out.prefill.values.where((v) => (v?.toString() ?? '').isNotEmpty).length};'
          'doc_path=${docPath.isNotEmpty}');
      widget.onScanned(out);
      return;
    }

    // A4 — three shapes, all printed as the backend phrased them.
    final err = m['error']?.toString() ?? '';
    final title = m['title']?.toString() ?? '';
    final message = m['message']?.toString() ?? '';

    setState(() {
      if (err == 'not_an_id') {
        // Verbatim title + message.
        _errTitle = title;
        _errMessage = message;
      } else if (err == 'unparseable') {
        _errTitle = '';
        _errMessage = _ui('dlv_scan_unreadable');
      } else {
        // Anything else: show it, and the form stays usable underneath.
        _errTitle = title;
        _errMessage = message.isNotEmpty ? message : err;
      }
    });
    RenderLog.write('c631_delivery_onboarding', 'scan_err;$err');
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final last = _last;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.badge_outlined, size: 18, color: _kGreen),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_ui('dlv_scan_id'),
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700, color: _kText)),
          ),
        ]),
        const SizedBox(height: 4),
        Text(_ui('dlv_scan_editable'),
            style: TextStyle(fontSize: 13, color: _kSub)),
        const SizedBox(height: 12),

        if (_busy)
          Row(children: [
            const SizedBox(
                width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Text(_ui('dlv_scan_reading'),
                style: TextStyle(fontSize: 13, color: _kSub)),
          ])
        else
          Row(children: [
            Expanded(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: _fromCamera,
                icon: const Icon(Icons.photo_camera_outlined, size: 18),
                label: Text(last == null ? _ui('dlv_scan_camera') : _ui('dlv_scan_again'),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: _kText,
                  side: BorderSide(color: _kBorder),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: _fromFile,
                icon: const Icon(Icons.image_outlined, size: 18),
                label: Text(_ui('dlv_scan_gallery'),
                    style: const TextStyle(fontSize: 13)),
              ),
            ),
          ]),

        // A4 — the refusal, printed as received.
        if (_errTitle.isNotEmpty || _errMessage.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFEE2E2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (_errTitle.isNotEmpty)
                Text(_errTitle,
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700, color: _kBad)),
              if (_errMessage.isNotEmpty) ...[
                if (_errTitle.isNotEmpty) const SizedBox(height: 2),
                Text(_errMessage,
                    style: const TextStyle(fontSize: 13, color: Color(0xFF991B1B))),
              ],
            ]),
          ),
        ],

        // A3 — what the scan believed, as a small chip.
        if (last != null) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (last.docTypeLabel.isNotEmpty)
              _chip(last.docTypeLabel, const Color(0xFFE1F5EE), const Color(0xFF0F6E56)),
            if (last.confidence.isNotEmpty)
              _chip(last.confidence, const Color(0xFFEFF6FF), const Color(0xFF1E40AF)),
            if (last.idDocPath.isNotEmpty)
              _chip(_ui('dlv_view_id'), const Color(0xFFF5F6F8), _kSub),
          ]),

          // A3 — read-only detail the form has no field for.
          if (_details(last).isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_ui('dlv_scan_details'),
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700, color: _kSub)),
            const SizedBox(height: 6),
            for (final d in _details(last))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(
                    width: 120,
                    child: Text(d.$1, style: TextStyle(fontSize: 13, color: _kSub)),
                  ),
                  Expanded(
                    child: Text(d.$2,
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w500, color: _kText)),
                  ),
                ]),
              ),
          ],
        ],
      ]),
    );
  }

  /// The `extra` block, label from the lookup table and value from the scan.
  /// Empty values are dropped rather than shown as blank rows.
  List<(String, String)> _details(IdScanResult r) {
    final out = <(String, String)>[];
    void add(String labelKey, String key) {
      final v = r.extra[key]?.toString() ?? '';
      if (v.trim().isNotEmpty) out.add((_ui(labelKey), v));
    }

    add('dlv_scan_dob', 'dob');
    add('dlv_scan_gender', 'gender');
    add('dlv_scan_valid_till', 'valid_till');
    add('dlv_scan_vehicle_classes', 'vehicle_classes');
    return out;
  }

  Widget _chip(String text, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Text(text,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: fg)),
      );
}
