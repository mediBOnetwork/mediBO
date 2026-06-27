import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  String? _fileMime;
  double? _lat;
  double? _lng;
  bool _locating = false;
  bool _submitting = false;
  String? _error;
  String? _locError;
  String? _locationLabel;

  bool get _canSubmit {
    final amt = double.tryParse(_amountCtrl.text.trim()) ?? 0;
    return amt > 0 &&
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
    // Do NOT auto-request location on init — causes silent failure on mobile PWA
    // User must tap the location button explicitly
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _collectedByCtrl.dispose();
    super.dispose();
  }

  Future<void> _requestLocation() async {
    setState(() {
      _locating = true;
      _locError = null;
    });
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() {
          _locating = false;
          _locError = 'GPS is off. Enable location and tap again.';
        });
        return;
      }
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever ||
          perm == LocationPermission.denied) {
        setState(() {
          _locating = false;
          _locError = 'Location permission denied. Allow in browser/app settings.';
        });
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 20),
        ),
      );
      setState(() {
        _lat = pos.latitude;
        _lng = pos.longitude;
        _locating = false;
        _locError = null;
        _locationLabel =
            '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}';
      });
    } catch (e) {
      setState(() {
        _locating = false;
        _locError = 'Could not get location. Tap to retry.';
      });
    }
  }

  Future<void> _pickFile() async {
    try {
      // image_picker on Flutter Web uses input[type=file] which requires
      // being called directly from a button onPressed with no prior awaits.
      // This method is called directly from button onPressed — do not add
      // any await before calling pickImage.
      final picker = ImagePicker();
      final XFile? picked = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1920,
        maxHeight: 1920,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final mime = picked.mimeType ?? 'image/jpeg';
      if (mounted) {
        setState(() {
          _fileBytes = bytes;
          _fileMime = mime;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not open file picker: ${e.toString()}';
        });
      }
    }
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final supabase = Supabase.instance.client;

      final ext = (_fileMime ?? '').contains('png')
          ? 'png'
          : (_fileMime ?? '').contains('webp')
              ? 'webp'
              : 'jpg';
      final filename = 'cash_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final path = 'cash_payments/$filename';

      await supabase.storage.from('whatsapp-media').uploadBinary(
            path,
            _fileBytes!,
            fileOptions: FileOptions(
              contentType: _fileMime ?? 'image/jpeg',
              upsert: true,
            ),
          );

      final res = await supabase.rpc('admin_record_cash_payment', params: {
        'p_order_id': widget.orderId,
        'p_amount': double.parse(_amountCtrl.text.trim()),
        'p_collected_by': _collectedByCtrl.text.trim(),
        'p_file_path': path,
        'p_lat': _lat,
        'p_lng': _lng,
      });

      final result = Map<String, dynamic>.from(res as Map);
      if (result['ok'] == true) {
        if (mounted) {
          Navigator.pop(context);
          widget.onSuccess();
        }
      } else {
        setState(() {
          _error = result['error']?.toString() ?? 'Submission failed';
          _submitting = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _submitting = false;
      });
    }
  }

  String _missingText() {
    final m = <String>[];
    final amt = double.tryParse(_amountCtrl.text.trim()) ?? 0;
    if (amt <= 0) m.add('amount');
    if (_collectedByCtrl.text.trim().isEmpty) m.add('received by');
    if (_fileBytes == null) m.add('file');
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
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('\u{1F4B5}', style: TextStyle(fontSize: 20)),
                const SizedBox(width: 8),
                const Text(
                  'Cash Received',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const Divider(),
            const SizedBox(height: 8),

            // AMOUNT
            const Text('Amount (₹)',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF424242))),
            const SizedBox(height: 6),
            TextField(
              controller: _amountCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
              ],
              decoration: InputDecoration(
                prefixText: '₹ ',
                hintText: '0.00',
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 12),
              ),
            ),
            const SizedBox(height: 16),

            // RECEIVED BY
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
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 12),
              ),
            ),
            const SizedBox(height: 16),

            // UPLOAD FILE
            const Text('Upload File',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF424242))),
            const SizedBox(height: 6),
            if (_fileBytes == null)
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: _pickFile,
                  icon: const Icon(Icons.attach_file),
                  label: const Text('Choose Photo / File'),
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
                  child: Stack(
                    children: [
                      Image.memory(
                        _fileBytes!,
                        height: 130,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          child: const Text('Change',
                              style: TextStyle(
                                  color: Colors.white, fontSize: 11)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 16),

            // LOCATION
            const Text('Location',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF424242))),
            const SizedBox(height: 6),
            if (_lat != null)
              Row(
                children: [
                  const Icon(Icons.location_on,
                      color: Color(0xFF2E7D32), size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Location captured ✓\n$_locationLabel',
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF2E7D32)),
                    ),
                  ),
                  TextButton(
                    onPressed: _requestLocation,
                    child: const Text('Refresh',
                        style: TextStyle(fontSize: 12)),
                  ),
                ],
              )
            else if (_locating)
              const Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('Getting location...',
                      style: TextStyle(
                          fontSize: 13, color: Color(0xFF757575))),
                ],
              )
            else
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _requestLocation,
                  icon: const Icon(Icons.location_on, size: 16),
                  label: Text(
                    _locError != null
                        ? 'Retry: $_locError'
                        : 'Tap to capture location',
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
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
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
              ),
            const SizedBox(height: 20),

            // ERROR
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!,
                    style: const TextStyle(
                        color: Color(0xFFD32F2F), fontSize: 12)),
              ),

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
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  elevation: _canSubmit ? 2 : 0,
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2.5),
                      )
                    : const Text(
                        '\u{1F4B5}  Collect Cash',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700),
                      ),
              ),
            ),
            const SizedBox(height: 8),
            if (!_canSubmit && !_submitting)
              Center(
                child: Text(
                  _missingText(),
                  style: TextStyle(
                      fontSize: 11, color: Colors.grey.shade500),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
