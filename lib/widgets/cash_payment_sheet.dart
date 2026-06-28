// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'fullscreen_image.dart';
import '../utils/render_log.dart';

class CashPaymentSheet extends StatefulWidget {
  final String orderId;
  final VoidCallback onSuccess;

  const CashPaymentSheet({
    super.key,
    required this.orderId,
    required this.onSuccess,
  });

  @override
  State<CashPaymentSheet> createState() => _CashPaymentSheetState();
}

class _CashPaymentSheetState extends State<CashPaymentSheet> {
  final _amountCtrl = TextEditingController();
  final _collectedByCtrl = TextEditingController();
  Uint8List? _fileBytes;
  String? _fileDataUrl;
  String? _fileMime;
  String? _viewType;
  double? _lat;
  double? _lng;
  bool _locating = false;
  bool _submitting = false;
  double _uploadProgress = 0.0;
  String? _error;
  String? _locError;
  String? _locationLabel;

  // CHANGE #243 — selfie verification state
  bool _selfieVerifying = false;
  bool _selfieVerified  = false;
  String? _selfieError;

  bool get _canSubmit {
    final amt = double.tryParse(_amountCtrl.text.trim()) ?? 0;
    return amt > 0 &&
        _collectedByCtrl.text.trim().isNotEmpty &&
        _fileBytes != null &&
        _selfieVerified &&          // must pass Gemini selfie check
        !_selfieVerifying &&        // not mid-check
        _lat != null &&
        _lng != null &&
        !_submitting;
  }

  @override
  void initState() {
    super.initState();
    _amountCtrl.addListener(() => setState(() {}));
    _collectedByCtrl.addListener(() => setState(() {}));
    try { RenderLog.write('c243_selfie_check_wired', 'on_pick=true'); } catch (_) {}
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _collectedByCtrl.dispose();
    super.dispose();
  }

  void _pickFile() {
    final input = html.FileUploadInputElement();
    input.accept = 'image/*';
    input.multiple = false;
    input.click();

    input.onChange.listen((_) async {
      final files = input.files;
      if (files == null || files.isEmpty) return;
      final file = files.first;

      // Non-image guard
      final mime = file.type.isNotEmpty ? file.type : 'image/jpeg';
      if (!mime.startsWith('image/')) {
        if (mounted) {
          setState(() {
            _selfieError = 'Please upload a selfie photo (image).';
            _selfieVerified = false;
            _fileBytes = null;
            _fileDataUrl = null;
            _fileMime = null;
            _viewType = null;
          });
        }
        return;
      }

      // Read file
      final reader = html.FileReader();
      reader.readAsDataUrl(file);
      await reader.onLoad.first;
      final dataUrl = reader.result as String;
      final comma = dataUrl.indexOf(',');
      final b64 = dataUrl.substring(comma + 1);
      final bytes = base64Decode(b64);

      // Register preview
      final vt = 'cash-preview-${DateTime.now().millisecondsSinceEpoch}';
      final capturedContext = context;
      ui_web.platformViewRegistry.registerViewFactory(vt, (int viewId) {
        final img = html.ImageElement()
          ..src = dataUrl
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.objectFit = 'cover'
          ..style.borderRadius = '10px'
          ..style.cursor = 'pointer';
        img.onClick.listen((_) => openFullscreenImage(capturedContext, dataUrl));
        return img;
      });

      if (!mounted) return;
      setState(() {
        _fileBytes = bytes;
        _fileDataUrl = dataUrl;
        _fileMime = mime;
        _viewType = vt;
        _selfieVerifying = true;
        _selfieVerified = false;
        _selfieError = null;
      });

      // Verify on pick — sends to Gemini via verify-selfie edge function
      await _verifySelfie(bytes, mime, b64);
    });
  }

  Future<void> _verifySelfie(Uint8List bytes, String mime, String b64) async {
    try {
      final supabase = Supabase.instance.client;
      final res = await supabase.functions
          .invoke(
            'verify-selfie',
            body: {'image_base64': b64, 'mime_type': mime},
          )
          .timeout(const Duration(seconds: 25));

      final data = res.data;
      final Map<String, dynamic> map = data is Map
          ? Map<String, dynamic>.from(data)
          : <String, dynamic>{};
      final human = map['human'] == true;

      if (!mounted) return;
      setState(() {
        _selfieVerifying = false;
        if (human) {
          _selfieVerified = true;
          _selfieError = null;
          try { RenderLog.write('c243_selfie_pass', 'human=true'); } catch (_) {}
        } else {
          _selfieVerified = false;
          _selfieError = 'No human selfie detected. Please upload a selfie.';
          // Clear the file so it is never submitted
          _fileBytes = null;
          _fileDataUrl = null;
          _fileMime = null;
          _viewType = null;
          try {
            RenderLog.write('c243_selfie_fail',
                'reason=${map['reason'] ?? 'none'}');
          } catch (_) {}
        }
      });
    } catch (e) {
      // Network / timeout / 500 → treat as non-human, require retry
      if (!mounted) return;
      setState(() {
        _selfieVerifying = false;
        _selfieVerified = false;
        _selfieError = 'Verification failed. Please try again.';
        _fileBytes = null;
        _fileDataUrl = null;
        _fileMime = null;
        _viewType = null;
      });
      try { RenderLog.write('c243_selfie_fail', 'reason=error:$e'); } catch (_) {}
    }
  }

  Future<void> _requestLocation() async {
    setState(() { _locating = true; _locError = null; });
    try {
      final completer = Completer<html.Geoposition>();
      html.window.navigator.geolocation
          .getCurrentPosition(enableHighAccuracy: false, timeout: const Duration(seconds: 20))
          .then((pos) { if (!completer.isCompleted) completer.complete(pos); })
          .catchError((e) { if (!completer.isCompleted) completer.completeError(e); });

      final pos = await completer.future.timeout(
        const Duration(seconds: 25),
        onTimeout: () => throw TimeoutException('Location timed out'),
      );

      final lat = pos.coords?.latitude?.toDouble();
      final lng = pos.coords?.longitude?.toDouble();
      if (lat == null || lng == null) throw Exception('No coordinates returned');

      if (mounted) {
        setState(() {
          _lat = lat;
          _lng = lng;
          _locating = false;
          _locError = null;
          _locationLabel = '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _locating = false;
          _locError = 'Could not get location. Allow location in browser and tap retry.';
        });
      }
    }
  }

  Future<void> _submit() async {
    // Belt-and-suspenders: never submit without a verified selfie
    if (!_selfieVerified) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Upload a verified selfie first')),
      );
      return;
    }
    if (!_canSubmit) return;
    setState(() { _submitting = true; _error = null; _uploadProgress = 0.1; });
    try {
      final supabase = Supabase.instance.client;
      final mime = _fileMime ?? 'image/jpeg';
      final ext = mime.contains('png') ? 'png' : mime.contains('webp') ? 'webp' : 'jpg';
      final filename = 'cash_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final path = 'cash_payments/$filename';

      setState(() { _uploadProgress = 0.3; });
      await supabase.storage.from('whatsapp-media').uploadBinary(
        path, _fileBytes!,
        fileOptions: FileOptions(contentType: mime, upsert: true),
      );

      setState(() { _uploadProgress = 0.7; });
      final res = await supabase.rpc('admin_record_cash_payment', params: {
        'p_order_id': widget.orderId,
        'p_amount': double.parse(_amountCtrl.text.trim()),
        'p_collected_by': _collectedByCtrl.text.trim(),
        'p_file_path': path,
        'p_lat': _lat,
        'p_lng': _lng,
      });

      setState(() { _uploadProgress = 1.0; });
      final result = Map<String, dynamic>.from(res as Map);
      if (result['ok'] == true) {
        if (mounted) { Navigator.pop(context); widget.onSuccess(); }
      } else {
        setState(() {
          _error = result['error']?.toString() ?? 'Submission failed';
          _submitting = false;
          _uploadProgress = 0.0;
        });
      }
    } catch (e) {
      setState(() { _error = e.toString(); _submitting = false; _uploadProgress = 0.0; });
    }
  }

  String _missingText() {
    final m = <String>[];
    final amt = double.tryParse(_amountCtrl.text.trim()) ?? 0;
    if (amt <= 0) m.add('amount');
    if (_collectedByCtrl.text.trim().isEmpty) m.add('received by');
    if (_fileBytes == null || !_selfieVerified) m.add('verified selfie');
    if (_lat == null) m.add('location');
    if (m.isEmpty) return '';
    return 'Required: ${m.join(', ')}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(
        left: 16, right: 16, top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(children: [
              const Text('\u{1F4B5}', style: TextStyle(fontSize: 20)),
              const SizedBox(width: 8),
              const Text('Cash Received',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ]),
            const Divider(),
            const SizedBox(height: 8),

            // AMOUNT
            const Text('Amount (₹)',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF424242))),
            const SizedBox(height: 6),
            TextField(
              controller: _amountCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
              ],
              decoration: InputDecoration(
                prefixText: '₹ ',
                hintText: '0.00',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
            ),
            const SizedBox(height: 16),

            // RECEIVED BY
            const Text('Received by',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF424242))),
            const SizedBox(height: 6),
            TextField(
              controller: _collectedByCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                hintText: 'Staff name',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
            ),
            const SizedBox(height: 16),

            // FILE UPLOAD + SELFIE VERIFICATION
            const Text('Upload Selfie',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF424242))),
            const SizedBox(height: 6),

            // Verifying state: spinner + message
            if (_selfieVerifying) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF8E1),
                  border: Border.all(color: const Color(0xFFFFB300)),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Row(children: [
                  SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFF8F00))),
                  SizedBox(width: 10),
                  Text('Verifying selfie…',
                      style: TextStyle(fontSize: 13, color: Color(0xFF6D4C00))),
                ]),
              ),
            ] else if (_selfieVerified && _fileBytes != null) ...[
              // Verified: show image with green badge + Change option
              SizedBox(
                height: 130,
                width: double.infinity,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _viewType != null
                          ? HtmlElementView(viewType: _viewType!)
                          : Container(color: Colors.grey.shade200),
                      // Green verified badge
                      Positioned(
                        top: 6, left: 6,
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF2E7D32),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          child: const Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.check_circle, color: Colors.white, size: 13),
                            SizedBox(width: 4),
                            Text('Selfie verified ✓',
                                style: TextStyle(color: Colors.white, fontSize: 11,
                                    fontWeight: FontWeight.w600)),
                          ]),
                        ),
                      ),
                      // Change badge
                      Positioned(
                        top: 6, right: 6,
                        child: GestureDetector(
                          onTap: _pickFile,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            child: const Text('Change',
                                style: TextStyle(color: Colors.white, fontSize: 11)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ] else ...[
              // Idle or rejected state: upload button
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: _pickFile,
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: Text(_selfieError != null ? 'Re-upload selfie' : 'Choose Photo / File'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _selfieError != null
                        ? const Color(0xFFD32F2F)
                        : null,
                    side: _selfieError != null
                        ? const BorderSide(color: Color(0xFFD32F2F))
                        : null,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              // Error message
              if (_selfieError != null) ...[
                const SizedBox(height: 6),
                Text(_selfieError!,
                    style: const TextStyle(fontSize: 12, color: Color(0xFFD32F2F))),
              ],
            ],
            const SizedBox(height: 16),

            // LOCATION
            const Text('Location',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF424242))),
            const SizedBox(height: 6),
            if (_lat != null)
              Row(children: [
                const Icon(Icons.location_on, color: Color(0xFF2E7D32), size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('Location captured ✓\n$_locationLabel',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF2E7D32))),
                ),
                TextButton(
                  onPressed: _requestLocation,
                  child: const Text('Refresh', style: TextStyle(fontSize: 12)),
                ),
              ])
            else if (_locating)
              const Row(children: [
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 8),
                Text('Getting location...', style: TextStyle(fontSize: 13, color: Color(0xFF757575))),
              ])
            else
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _requestLocation,
                  icon: const Icon(Icons.my_location, size: 16),
                  label: Text(
                    _locError ?? 'Tap to capture location',
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _locError != null
                        ? const Color(0xFFD32F2F)
                        : const Color(0xFF1565C0),
                    side: BorderSide(
                      color: _locError != null
                          ? const Color(0xFFD32F2F)
                          : const Color(0xFF1565C0),
                    ),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                ),
              ),

            // SUBMIT ERROR
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Color(0xFFD32F2F), fontSize: 12)),
            ],

            const SizedBox(height: 20),

            // SUBMIT BUTTON
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _canSubmit ? _submit : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2E7D32),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.grey.shade300,
                  disabledForegroundColor: Colors.grey.shade500,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: _canSubmit ? 2 : 0,
                ),
                child: _submitting
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 22, height: 22,
                            child: CircularProgressIndicator(
                              value: _uploadProgress > 0 ? _uploadProgress : null,
                              color: Colors.white,
                              strokeWidth: 2.5,
                              backgroundColor: Colors.white24,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            '${(_uploadProgress * 100).toInt()}%',
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                          ),
                        ],
                      )
                    : const Text('\u{1F4B5}  Collect Cash',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 8),
            if (!_canSubmit && !_submitting)
              Center(
                child: Text(
                  _missingText(),
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  textAlign: TextAlign.center,
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
