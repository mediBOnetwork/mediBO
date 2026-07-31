// lib/screens/delivery/delivery_proof_sheet.dart — CHANGE #629 (PART C)
//
// THE THREE WAYS TO COMPLETE A DELIVERY, plus failed and partial.
//
// C — "All three are geo-stamped — always pass the device's current
// p_lat / p_lng." Every one of the five write RPCs below takes its coordinates
// from _fix(), which asks the device at the moment of the tap. There is no path
// through this file that completes a delivery without attempting a fix first.
//
// Nothing is decided here:
//   • whether a photo is required          -> the RPC answers `photo_required`
//   • what an OTP failure means            -> no_otp / expired / wrong_otp, and
//                                             the message is printed verbatim
//   • who scanned a QR (rider vs customer) -> delivery_scan_qr works it out and
//                                             records qr_agent / qr_customer
//   • the fail reasons                     -> delivery_fail_reason_list()
//   • whether a failure is reattempted     -> the response says so, and its
//                                             sentence is shown as-is
// Static chrome comes from the copy catalog (FulfillLookups.ui), so the wording
// of this sheet is a table UPDATE, never a rebuild.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../fulfill/fulfill_lookups.dart';
import '../../services/device_location.dart';
import '../../utils/render_log.dart';

Color get _kGreen => FulfillLookups.instance.color('c_ff1b7a43', const Color(0xFF1B7A43));
Color get _kBorder => FulfillLookups.instance.color('c_ffe5e7eb', const Color(0xFFE5E7EB));
Color get _kText => FulfillLookups.instance.color('c_ff111827', const Color(0xFF111827));
Color get _kSub => FulfillLookups.instance.color('c_ff6b7280', const Color(0xFF6B7280));
Color get _kBad => FulfillLookups.instance.color('c_ffb42318', const Color(0xFFB42318));

String _ui(String k) => FulfillLookups.instance.ui(k);

/// Opens the completion sheet for one stop. Returns true when anything was
/// written (delivered / failed / partial) so the caller can reload from the
/// backend rather than patching its own copy of the row.
Future<bool> showDeliveryProofSheet(
  BuildContext context, {
  required Map<String, dynamic> stop,
}) async {
  final changed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _DeliveryProofSheet(stop: stop),
  );
  return changed ?? false;
}

class _DeliveryProofSheet extends StatefulWidget {
  final Map<String, dynamic> stop;
  const _DeliveryProofSheet({required this.stop});

  @override
  State<_DeliveryProofSheet> createState() => _DeliveryProofSheetState();
}

class _DeliveryProofSheetState extends State<_DeliveryProofSheet> {
  // 0 = QR, 1 = OTP, 2 = Photo
  int _method = 0;
  bool _busy = false;

  /// The backend's last ok:false payload — title/message shown verbatim.
  String _errTitle = '';
  String _errMessage = '';

  final _otpCtrl = TextEditingController();
  final _receiverCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final _deliveredQtyCtrl = TextEditingController();
  final _returnedQtyCtrl = TextEditingController();

  bool _otpSent = false;
  Uint8List? _photoBytes;
  String _photoMime = 'image/jpeg';

  List<Map<String, dynamic>> _failReasons = const [];
  bool _showOther = false;

  String get _deliveryId => widget.stop['delivery_id']?.toString() ?? '';

  @override
  void initState() {
    super.initState();
    _otpSent = (widget.stop['otp_sent'] as bool?) ?? false;
    _loadFailReasons();
  }

  @override
  void dispose() {
    _otpCtrl.dispose();
    _receiverCtrl.dispose();
    _noteCtrl.dispose();
    _deliveredQtyCtrl.dispose();
    _returnedQtyCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadFailReasons() async {
    try {
      final res = await Supabase.instance.client.rpc('delivery_fail_reason_list');
      if (!mounted) return;
      if (res is List) {
        setState(() => _failReasons =
            res.map((e) => Map<String, dynamic>.from(e as Map)).toList());
      }
    } catch (_) {
      // Leave the list empty — the "could not deliver" section simply shows no
      // reasons rather than inventing any.
    }
  }

  /// The geo-stamp. Every completion path calls this immediately before its RPC.
  Future<DeviceFix?> _fix() => DeviceLocation.current();

  void _showError(Map res) {
    setState(() {
      _errTitle = res['title']?.toString() ?? '';
      _errMessage = res['message']?.toString() ?? '';
    });
  }

  void _clearError() {
    if (_errTitle.isNotEmpty || _errMessage.isNotEmpty) {
      setState(() {
        _errTitle = '';
        _errMessage = '';
      });
    }
  }

  /// Closes the sheet on a successful write, surfacing the backend's own
  /// sentence to the screen behind it.
  void _done(Map res) {
    RenderLog.write('c629_delivery_completed', res['method']?.toString() ?? 'ok');
    final msg = res['message']?.toString() ?? '';
    Navigator.of(context).pop(true);
    if (msg.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  // ── C1: QR — one token, both directions ───────────────────────────────────
  bool _qrHandling = false;

  Future<void> _onQrDetect(BarcodeCapture capture) async {
    if (_qrHandling || _busy) return;
    final raw = capture.barcodes
        .map((b) => b.rawValue ?? '')
        .firstWhere((v) => v.isNotEmpty, orElse: () => '');
    if (raw.isEmpty) return;

    _qrHandling = true;
    setState(() => _busy = true);
    _clearError();
    try {
      // The QR may be the bare token or the full https://medibo.in/track/<token>
      // link printed on the parcel. The backend matches on the token, so the
      // last path segment is what is sent; it is not validated here.
      final token = raw.contains('/') ? raw.split('/').where((s) => s.isNotEmpty).last : raw;
      final fix = await _fix();
      final res = await Supabase.instance.client.rpc('delivery_scan_qr', params: {
        'p_token': token.split('?').first,
        'p_lat': fix?.lat,
        'p_lng': fix?.lng,
      });
      if (!mounted) return;
      if (res is Map && res['ok'] == true) {
        _done(res);
        return;
      }
      if (res is Map) _showError(res);
    } catch (_) {
      // Network failure — leave the scanner open, no invented message.
    } finally {
      if (mounted) setState(() => _busy = false);
      _qrHandling = false;
    }
  }

  // ── C2: OTP ───────────────────────────────────────────────────────────────
  Future<void> _sendOtp() async {
    if (_busy) return;
    setState(() => _busy = true);
    _clearError();
    try {
      final res = await Supabase.instance.client
          .rpc('delivery_send_otp', params: {'p_delivery_id': _deliveryId});
      if (!mounted) return;
      if (res is Map && res['ok'] == true) {
        setState(() => _otpSent = true);
        final msg = res['message']?.toString() ?? '';
        if (msg.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        }
      } else if (res is Map) {
        _showError(res);
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyOtp() async {
    if (_busy) return;
    setState(() => _busy = true);
    _clearError();
    try {
      final fix = await _fix();
      final res = await Supabase.instance.client.rpc('delivery_verify_otp', params: {
        'p_delivery_id': _deliveryId,
        'p_code': _otpCtrl.text.trim(),
        'p_lat': fix?.lat,
        'p_lng': fix?.lng,
        'p_receiver': _receiverCtrl.text.trim(),
      });
      if (!mounted) return;
      if (res is Map && res['ok'] == true) {
        _done(res);
        return;
      }
      // no_otp / expired / wrong_otp — each carries its own message.
      if (res is Map) _showError(res);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── C3: PHOTO ─────────────────────────────────────────────────────────────
  Future<void> _takePhoto() async {
    try {
      final picked = await ImagePicker()
          .pickImage(source: ImageSource.camera, imageQuality: 70, maxWidth: 1600);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      setState(() {
        _photoBytes = bytes;
        _photoMime = picked.mimeType ?? 'image/jpeg';
      });
    } catch (_) {
      // No camera / cancelled — the RPC still owns the "photo required" answer.
    }
  }

  /// Uploads to the private delivery-proofs bucket and returns the object path,
  /// or null. The path is opaque to the app; the backend stores it verbatim.
  Future<String?> _uploadPhoto() async {
    final bytes = _photoBytes;
    if (bytes == null) return null;
    try {
      final ext = _photoMime.contains('png')
          ? 'png'
          : _photoMime.contains('webp')
              ? 'webp'
              : 'jpg';
      final path =
          'proofs/${_deliveryId}_${DateTime.now().millisecondsSinceEpoch}.$ext';
      await Supabase.instance.client.storage.from('delivery-proofs').uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(contentType: _photoMime, upsert: true),
          );
      return path;
    } catch (_) {
      return null;
    }
  }

  Future<void> _completeWithPhoto() async {
    if (_busy) return;
    setState(() => _busy = true);
    _clearError();
    try {
      final photoPath = await _uploadPhoto();
      final fix = await _fix();
      final res = await Supabase.instance.client.rpc('delivery_mark_delivered', params: {
        'p_delivery_id': _deliveryId,
        'p_photo_path': photoPath,
        'p_receiver': _receiverCtrl.text.trim(),
        'p_lat': fix?.lat,
        'p_lng': fix?.lng,
      });
      if (!mounted) return;
      if (res is Map && res['ok'] == true) {
        _done(res);
        return;
      }
      // photo_required comes back with its own title + message.
      if (res is Map) _showError(res);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── C4: FAILED ────────────────────────────────────────────────────────────
  Future<void> _fail(String reasonCode) async {
    if (_busy) return;
    setState(() => _busy = true);
    _clearError();
    try {
      final fix = await _fix();
      final res = await Supabase.instance.client.rpc('delivery_fail', params: {
        'p_delivery_id': _deliveryId,
        'p_reason_code': reasonCode,
        'p_note': _noteCtrl.text.trim(),
        'p_lat': fix?.lat,
        'p_lng': fix?.lng,
      });
      if (!mounted) return;
      if (res is Map && res['ok'] == true) {
        // The response's own sentence says whether it is reattempted tomorrow.
        _done(res);
        return;
      }
      if (res is Map) _showError(res);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── C5: PARTIAL ───────────────────────────────────────────────────────────
  Future<void> _partial() async {
    if (_busy) return;
    setState(() => _busy = true);
    _clearError();
    try {
      final photoPath = await _uploadPhoto();
      final fix = await _fix();
      final res = await Supabase.instance.client.rpc('delivery_partial', params: {
        'p_delivery_id': _deliveryId,
        'p_delivered_qty': int.tryParse(_deliveredQtyCtrl.text.trim()) ?? 0,
        'p_returned_qty': int.tryParse(_returnedQtyCtrl.text.trim()) ?? 0,
        'p_note': _noteCtrl.text.trim(),
        'p_lat': fix?.lat,
        'p_lng': fix?.lng,
        'p_photo': photoPath,
        'p_receiver': _receiverCtrl.text.trim(),
      });
      if (!mounted) return;
      if (res is Map && res['ok'] == true) {
        _done(res);
        return;
      }
      if (res is Map) _showError(res);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scrollCtrl) => SingleChildScrollView(
          controller: scrollCtrl,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: _kBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                widget.stop['pharmacy_name']?.toString() ?? '',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _kText),
              ),
              const SizedBox(height: 2),
              Text(_ui('dlv_proof_title'),
                  style: TextStyle(fontSize: 12.5, color: _kSub)),
              const SizedBox(height: 14),

              _methodTabs(),
              const SizedBox(height: 14),

              if (_errTitle.isNotEmpty || _errMessage.isNotEmpty) _errorBox(),

              if (_method == 0) _qrBody(),
              if (_method == 1) _otpBody(),
              if (_method == 2) _photoBody(),

              const SizedBox(height: 18),
              Divider(height: 1, color: _kBorder),
              const SizedBox(height: 10),

              InkWell(
                onTap: () => setState(() => _showOther = !_showOther),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(children: [
                    Text(_ui('dlv_more_options'),
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700, color: _kSub)),
                    const Spacer(),
                    Icon(_showOther ? Icons.expand_less : Icons.expand_more, color: _kSub),
                  ]),
                ),
              ),
              if (_showOther) _otherOutcomes(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _methodTabs() {
    Widget tab(int i, String key) {
      final sel = _method == i;
      return Expanded(
        child: GestureDetector(
          onTap: () {
            _clearError();
            setState(() => _method = i);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: sel ? _kGreen : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: sel ? _kGreen : _kBorder),
            ),
            child: Text(
              _ui(key),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: sel ? Colors.white : _kSub,
              ),
            ),
          ),
        ),
      );
    }

    return Row(children: [
      tab(0, 'dlv_method_qr'),
      const SizedBox(width: 8),
      tab(1, 'dlv_method_otp'),
      const SizedBox(width: 8),
      tab(2, 'dlv_method_photo'),
    ]);
  }

  Widget _errorBox() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFBE9E7),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_errTitle.isNotEmpty)
          Text(_errTitle,
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: _kBad)),
        if (_errMessage.isNotEmpty)
          Text(_errMessage, style: TextStyle(fontSize: 12.5, color: _kBad)),
      ]),
    );
  }

  Widget _qrBody() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(_ui('dlv_qr_hint'), style: TextStyle(fontSize: 12.5, color: _kSub)),
      const SizedBox(height: 10),
      ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 260,
          child: MobileScanner(
            onDetect: _onQrDetect,
            errorBuilder: (context, error, child) => Container(
              color: const Color(0xFFF3F4F6),
              alignment: Alignment.center,
              padding: const EdgeInsets.all(16),
              child: Text(_ui('dlv_qr_denied'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, color: _kSub)),
            ),
          ),
        ),
      ),
      if (_busy) const Padding(
        padding: EdgeInsets.only(top: 12),
        child: LinearProgressIndicator(minHeight: 2),
      ),
    ]);
  }

  Widget _otpBody() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      OutlinedButton(
        onPressed: _busy ? null : _sendOtp,
        child: Text(_otpSent ? _ui('dlv_otp_resend') : _ui('dlv_otp_send')),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _otpCtrl,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: _ui('dlv_otp_code'),
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
      const SizedBox(height: 10),
      _receiverField(),
      const SizedBox(height: 12),
      _primaryButton(_ui('dlv_otp_verify'), _verifyOtp),
    ]);
  }

  Widget _photoBody() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_photoBytes != null)
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.memory(_photoBytes!, height: 190, fit: BoxFit.cover),
        ),
      if (_photoBytes != null) const SizedBox(height: 10),
      OutlinedButton.icon(
        onPressed: _busy ? null : _takePhoto,
        icon: const Icon(Icons.photo_camera_outlined, size: 18),
        label: Text(_photoBytes == null ? _ui('dlv_photo_take') : _ui('dlv_photo_retake')),
      ),
      const SizedBox(height: 10),
      _receiverField(),
      const SizedBox(height: 12),
      _primaryButton(_ui('dlv_photo_complete'), _completeWithPhoto),
    ]);
  }

  Widget _receiverField() {
    return TextField(
      controller: _receiverCtrl,
      decoration: InputDecoration(
        labelText: _ui('dlv_receiver'),
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  Widget _primaryButton(String label, VoidCallback onTap) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: _kGreen,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      onPressed: _busy ? null : onTap,
      child: _busy
          ? const SizedBox(
              width: 18, height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }

  Widget _otherOutcomes() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 6),
      TextField(
        controller: _noteCtrl,
        decoration: InputDecoration(
          labelText: _ui('dlv_fail_note'),
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
      const SizedBox(height: 12),

      // C4 — reasons and their labels are the backend's list, in its order.
      Text(_ui('dlv_failed'),
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _kText)),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final r in _failReasons)
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: _kBad,
                side: BorderSide(color: _kBorder),
                visualDensity: VisualDensity.compact,
              ),
              onPressed: _busy ? null : () => _fail(r['code']?.toString() ?? ''),
              child: Text(r['label']?.toString() ?? '',
                  style: const TextStyle(fontSize: 12.5)),
            ),
        ],
      ),

      const SizedBox(height: 18),
      Text(_ui('dlv_partial'),
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _kText)),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _deliveredQtyCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: _ui('dlv_partial_delivered'),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            controller: _returnedQtyCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: _ui('dlv_partial_returned'),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
      ]),
      const SizedBox(height: 10),
      // A partial handover must be photographed — the RPC enforces it and says
      // so; this button just makes the photo reachable from here too.
      OutlinedButton.icon(
        onPressed: _busy ? null : _takePhoto,
        icon: const Icon(Icons.photo_camera_outlined, size: 18),
        label: Text(_photoBytes == null ? _ui('dlv_photo_take') : _ui('dlv_photo_retake')),
      ),
      const SizedBox(height: 10),
      _primaryButton(_ui('dlv_partial_submit'), _partial),
      const SizedBox(height: 8),
    ]);
  }
}
