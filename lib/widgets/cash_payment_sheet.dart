import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class CashPaymentSheet extends StatefulWidget {
  final String orderId;
  final VoidCallback onSuccess;
  const CashPaymentSheet({super.key, required this.orderId, required this.onSuccess});

  @override
  State<CashPaymentSheet> createState() => _CashPaymentSheetState();
}

class _CashPaymentSheetState extends State<CashPaymentSheet> {
  final TextEditingController _amountCtrl = TextEditingController();
  final TextEditingController _collectedByCtrl = TextEditingController();
  Uint8List? _fileBytes;
  String? _fileMime;
  double? _lat;
  double? _lng;
  bool _locating = false;
  bool _submitting = false;
  String? _error;
  String? _locationLabel;

  bool get _canSubmit {
    final amount = double.tryParse(_amountCtrl.text.trim()) ?? 0.0;
    return amount > 0 &&
        _collectedByCtrl.text.trim().isNotEmpty &&
        _fileBytes != null &&
        _lat != null &&
        _lng != null &&
        !_submitting;
  }

  @override
  void initState() {
    super.initState();
    _amountCtrl.addListener(() => setState(() {}));
    _collectedByCtrl.addListener(() => setState(() {}));
    _requestLocation();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _collectedByCtrl.dispose();
    super.dispose();
  }

  Future<void> _requestLocation() async {
    if (!mounted) return;
    setState(() { _locating = true; _error = null; });
    try {
      final svcEnabled = await Geolocator.isLocationServiceEnabled();
      if (!svcEnabled) {
        if (!mounted) return;
        setState(() {
          _locating = false;
          _error = 'Location services disabled — enable GPS and retry';
        });
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        if (!mounted) return;
        setState(() {
          _locating = false;
          _error = 'Location permission denied — required for cash collection';
        });
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 15),
        ),
      );
      if (!mounted) return;
      setState(() {
        _lat = pos.latitude;
        _lng = pos.longitude;
        _locating = false;
        _locationLabel =
            '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}';
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _locating = false; _error = 'Could not get location — tap retry'; });
    }
  }

  Future<void> _pickFile() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    final mime = picked.mimeType ?? 'image/jpeg';
    if (!mounted) return;
    setState(() { _fileBytes = bytes; _fileMime = mime; });
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() { _submitting = true; _error = null; });
    try {
      final client = Supabase.instance.client;
      final mime = _fileMime ?? 'image/jpeg';
      final String ext;
      if (mime.contains('png')) {
        ext = 'png';
      } else if (mime.contains('webp')) {
        ext = 'webp';
      } else {
        ext = 'jpg';
      }
      final filename = 'cash_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final path = 'cash_payments/$filename';
      await client.storage.from('whatsapp-media').uploadBinary(
        path,
        _fileBytes!,
        fileOptions: FileOptions(contentType: mime, upsert: true),
      );
      final result = await client.rpc('admin_record_cash_payment', params: {
        'p_order_id':    widget.orderId,
        'p_amount':      double.parse(_amountCtrl.text.trim()),
        'p_collected_by': _collectedByCtrl.text.trim(),
        'p_file_path':   path,
        'p_lat':         _lat,
        'p_lng':         _lng,
      });
      final res = Map<String, dynamic>.from(result as Map? ?? {});
      if (res['ok'] == true) {
        if (!mounted) return;
        Navigator.pop(context);
        widget.onSuccess();
      } else {
        final errMsg = res['error'] as String? ?? 'Unknown error';
        if (!mounted) return;
        setState(() { _error = errMsg; _submitting = false; });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _submitting = false; });
    }
  }

  String _missingFields() {
    final missing = <String>[];
    if ((double.tryParse(_amountCtrl.text.trim()) ?? 0.0) <= 0) missing.add('amount');
    if (_collectedByCtrl.text.trim().isEmpty) missing.add('received by');
    if (_fileBytes == null) missing.add('file');
    if (_lat == null) missing.add('location');
    if (missing.isEmpty) return '';
    return 'Required: ${missing.join(', ')}';
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      padding: EdgeInsets.fromLTRB(16, 16, 16, mediaQuery.viewInsets.bottom + 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(children: [
              const Text('💵 Cash Received',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF111827))),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => Navigator.pop(context),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ]),
            const Divider(height: 16),
            const SizedBox(height: 4),

            // Amount
            const Text('Amount ₹',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF424242))),
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
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
            ),
            const SizedBox(height: 16),

            // Received by
            const Text('Received by',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF424242))),
            const SizedBox(height: 6),
            TextField(
              controller: _collectedByCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                hintText: 'Staff name',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
            ),
            const SizedBox(height: 16),

            // File upload
            const Text('Upload File',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF424242))),
            const SizedBox(height: 6),
            if (_fileBytes == null)
              SizedBox(
                width: double.infinity,
                height: 44,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.attach_file, size: 18),
                  label: const Text('Choose Photo / File'),
                  onPressed: _pickFile,
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              )
            else
              GestureDetector(
                onTap: _pickFile,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Stack(children: [
                    Image.memory(_fileBytes!,
                        height: 130, width: double.infinity, fit: BoxFit.cover),
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text('Change',
                            style: TextStyle(
                                color: Colors.white, fontSize: 11)),
                      ),
                    ),
                  ]),
                ),
              ),
            const SizedBox(height: 16),

            // Location
            const Text('Location',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF424242))),
            const SizedBox(height: 6),
            if (_locating)
              const Row(children: [
                SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 8),
                Text('Getting location…',
                    style: TextStyle(fontSize: 13, color: Color(0xFF757575))),
              ])
            else if (_lat != null)
              Row(children: [
                const Icon(Icons.location_on,
                    color: Color(0xFF2E7D32), size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('Location captured ✓\n${_locationLabel ?? ''}',
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF2E7D32))),
                ),
              ])
            else
              Row(children: [
                const Icon(Icons.location_off,
                    color: Color(0xFFD32F2F), size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(_error ?? 'Location required',
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFFD32F2F))),
                ),
                TextButton(
                  onPressed: _requestLocation,
                  child: const Text('Retry'),
                ),
              ]),
            const SizedBox(height: 20),

            // Submit button
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _canSubmit ? _submit : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _canSubmit
                      ? const Color(0xFF2E7D32)
                      : Colors.grey.shade300,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.grey.shade300,
                  disabledForegroundColor: Colors.grey.shade500,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  elevation: _canSubmit ? 2 : 0,
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2.5))
                    : const Text('💵  Collect Cash',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 8),
            if (!_canSubmit && !_submitting)
              Center(
                child: Text(_missingFields(),
                    style: TextStyle(
                        fontSize: 11, color: Colors.grey.shade500)),
              ),

            // Submit error (not location error — that shows inline above)
            if (_error != null && _lat != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFFDC2626))),
              ),
          ],
        ),
      ),
    );
  }
}
