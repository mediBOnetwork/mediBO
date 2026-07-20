// CHANGE #465: shared Download / WhatsApp / Share actions for an uploaded
// customer bill (storage bucket+path), plus the WhatsApp number picker popup.
// Used by both the customer Bill tab and the admin Customer Orders card so
// "admin gets the same actions the customer has" is one implementation, not
// two copies. (orders_screen.dart's own #462-era _BillActionButton /
// _WaNumberPicker / _BillActionsRow, which operate on the OLD computed-invoice
// PDF flow, are left untouched — they back _ComputedInvoiceTab, kept
// unreferenced per the #463 product decision.)
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pharma_b2b/utils/toast.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/bill_mime.dart';
import '../utils/download_bytes.dart';

class UploadedBillActionsRow extends StatefulWidget {
  final String orderId;
  final String bucket;
  final String path;
  final String fileName;
  const UploadedBillActionsRow({
    super.key,
    required this.orderId,
    required this.bucket,
    required this.path,
    required this.fileName,
  });

  @override
  State<UploadedBillActionsRow> createState() => _UploadedBillActionsRowState();
}

class _UploadedBillActionsRowState extends State<UploadedBillActionsRow> {
  bool _downloading = false;
  bool _sharing = false;
  OverlayEntry? _waPopupEntry;

  @override
  void dispose() {
    _waPopupEntry?.remove();
    _waPopupEntry = null;
    super.dispose();
  }

  Future<({List<int> bytes, String filename})?> _fetchBillFile() async {
    try {
      final bytes = await Supabase.instance.client.storage.from(widget.bucket).download(widget.path);
      return (bytes: bytes, filename: widget.fileName);
    } catch (_) {
      if (mounted) showToast(context, 'Could not load the bill.', isError: true);
      return null;
    }
  }

  // ① Download — straight from storage, no re-render, no account picker.
  Future<void> _download() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    final file = await _fetchBillFile();
    if (mounted) setState(() => _downloading = false);
    if (file == null) return;
    downloadBytes(file.bytes, file.filename, mimeFromBillName(file.filename));
  }

  // ③ Share — native OS share sheet with the SAME uploaded file as Download.
  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    final file = await _fetchBillFile();
    if (file == null) {
      if (mounted) setState(() => _sharing = false);
      return;
    }
    final mime = mimeFromBillName(file.filename);
    final result = await shareBytes(file.bytes, file.filename, mime);
    if (mounted) setState(() => _sharing = false);
    if (result == null) downloadBytes(file.bytes, file.filename, mime);
  }

  // ② Send Bill to WhatsApp — mini floating popup anchored near this button.
  void _showWaPopup(BuildContext buttonContext) {
    _waPopupEntry?.remove();
    _waPopupEntry = null;
    final box = buttonContext.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final topLeft = box.localToGlobal(Offset.zero);
    final screenW = MediaQuery.of(buttonContext).size.width;
    const popupW = 260.0;
    final left = (topLeft.dx + box.size.width / 2 - popupW / 2)
        .clamp(12.0, math.max(12.0, screenW - popupW - 12.0))
        .toDouble();
    final top = topLeft.dy + box.size.height + 6;

    void dismiss() {
      _waPopupEntry?.remove();
      _waPopupEntry = null;
    }

    _waPopupEntry = OverlayEntry(builder: (_) => Stack(children: [
      Positioned.fill(
        child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: dismiss),
      ),
      Positioned(
        top: top,
        left: left,
        width: popupW,
        child: Material(
          borderRadius: BorderRadius.circular(12),
          elevation: 8,
          color: Colors.white,
          child: WaNumberPicker(
            orderId: widget.orderId,
            onDismiss: dismiss,
            onResult: (message, isError) {
              if (mounted) showToast(context, message, isError: isError);
            },
          ),
        ),
      ),
    ]));
    Overlay.of(buttonContext).insert(_waPopupEntry!);
  }

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        child: BillActionButton(
          icon: Icons.download_outlined,
          label: _downloading ? 'Downloading…' : 'Download',
          enabled: !_downloading,
          loading: _downloading,
          onTap: _download,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Builder(builder: (btnContext) => BillActionButton(
              icon: Icons.chat_bubble_outline,
              label: 'WhatsApp',
              enabled: true,
              onTap: () => _showWaPopup(btnContext),
            )),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: BillActionButton(
          icon: Icons.share_outlined,
          label: _sharing ? 'Sharing…' : 'Share',
          enabled: !_sharing,
          loading: _sharing,
          onTap: _share,
        ),
      ),
    ]);
  }
}

class BillActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final bool loading;
  final VoidCallback onTap;
  const BillActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.enabled,
    this.loading = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = enabled ? const Color(0xFF1B7A43) : const Color(0xFF9CA3AF);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? const Color(0xFFE8F5E9) : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: enabled ? const Color(0xFF1B7A43) : const Color(0xFFE5E7EB)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (loading)
            SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: color))
          else
            Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
          ),
        ]),
      ),
    );
  }
}

// Numbers come back from customer_bill_numbers already sorted
// last_used desc nulls last, so index 0 is the most recent — badge it as
// "last used" only when it actually has a last_used timestamp (an all-null
// list is just alphabetical fallback order, not a real "most recent").
class WaNumberPicker extends StatefulWidget {
  final String orderId;
  final VoidCallback onDismiss;
  final void Function(String message, bool isError) onResult;
  const WaNumberPicker({super.key, required this.orderId, required this.onDismiss, required this.onResult});

  @override
  State<WaNumberPicker> createState() => _WaNumberPickerState();
}

class _WaNumberPickerState extends State<WaNumberPicker> {
  List<Map<String, dynamic>>? _numbers;
  String? _error;
  String? _sendingPhone;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final raw = await Supabase.instance.client
          .rpc('customer_bill_numbers', params: {'p_order_id': widget.orderId});
      final list = (raw is List ? raw : const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (mounted) setState(() => _numbers = list);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load numbers.');
    }
  }

  Future<void> _send(String phone) async {
    if (_sendingPhone != null) return;
    setState(() => _sendingPhone = phone);
    String message;
    bool isError;
    try {
      final raw = await Supabase.instance.client.rpc('send_customer_bill_wa',
          params: {'p_order_id': widget.orderId, 'p_phone': phone});
      final res = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      if (res['status'] == 'queued') {
        message = 'Bill sent to $phone on WhatsApp';
        isError = false;
      } else if (res['error'] == 'no_bill_uploaded') {
        message = 'Upload a bill first';
        isError = true;
      } else if (res['error'] == 'bill_not_ready') {
        message = 'Bill not ready yet';
        isError = true;
      } else if (res['error'] == 'bad_phone') {
        message = 'Invalid number';
        isError = true;
      } else {
        message = 'Could not send the bill';
        isError = true;
      }
    } catch (_) {
      message = 'Could not send the bill';
      isError = true;
    }
    widget.onDismiss();
    widget.onResult(message, isError);
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 280),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text('Send bill to',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
          ),
          const SizedBox(height: 4),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: const TextStyle(fontSize: 12, color: Colors.red)),
            )
          else if (_numbers == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                  child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else if (_numbers!.isEmpty)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('No saved number', style: TextStyle(fontSize: 12.5, color: Color(0xFF6B7280))),
            )
          else
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: _numbers!.asMap().entries.map((e) {
                    final idx = e.key;
                    final phone = e.value['phone']?.toString() ?? '';
                    final lastUsed = e.value['last_used'];
                    final isLastUsed = idx == 0 && lastUsed != null;
                    final busy = _sendingPhone == phone;
                    return InkWell(
                      onTap: _sendingPhone == null ? () => _send(phone) : null,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                        child: Row(children: [
                          const Icon(Icons.chat_bubble, size: 16, color: Color(0xFF1B7A43)),
                          const SizedBox(width: 8),
                          Expanded(
                              child: Text(phone,
                                  style: const TextStyle(fontSize: 13.5, color: Color(0xFF111827)))),
                          if (isLastUsed)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                  color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(4)),
                              child: const Text('last used',
                                  style: TextStyle(
                                      fontSize: 9.5, color: Color(0xFF1B7A43), fontWeight: FontWeight.w600)),
                            ),
                          if (busy) ...[
                            const SizedBox(width: 8),
                            const SizedBox(
                                width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                          ],
                        ]),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
