// lib/widgets/upi_pay_sheet.dart — CHANGE #336
// UPI Pay Sheet: QR code + copy + save + intent fallback.
// Replaces direct launchUrl('upi://...') which PhonePe/GPay block for P2P VPAs.
// ignore_for_file: use_build_context_synchronously
import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/render_log.dart';

/// Canonical UPI URI builder — single source of truth.
/// All call sites must go through this; never hand-build upi:// strings.
Uri buildUpiUri({
  required String vpa,
  required String payeeName,
  required double amount,
  required String note,
}) {
  final safeNote = note
      .replaceAll(RegExp(r'[^A-Za-z0-9 ._\-]'), '')
      .trim();
  final truncNote =
      safeNote.length > 50 ? safeNote.substring(0, 50) : safeNote;
  return Uri(
    scheme: 'upi',
    host: 'pay',
    queryParameters: {
      'pa': vpa,
      'pn': payeeName,
      'am': amount.toStringAsFixed(2),
      'cu': 'INR',
      'tn': truncNote,
    },
  );
}

/// Show the UPI pay sheet. Call instead of launchUrl('upi://...').
Future<void> showUpiPaySheet(
  BuildContext ctx, {
  required String vpa,
  required String payeeName,
  required double amount,
  required String note,
}) async {
  RenderLog.write(
      'c336_sheet_open', 'vpa=$vpa;am=${amount.toStringAsFixed(2)}');
  await showModalBottomSheet<void>(
    context: ctx,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _UpiPaySheet(
      vpa: vpa,
      payeeName: payeeName,
      amount: amount,
      note: note,
    ),
  );
}

class _UpiPaySheet extends StatefulWidget {
  final String vpa;
  final String payeeName;
  final double amount;
  final String note;

  const _UpiPaySheet({
    required this.vpa,
    required this.payeeName,
    required this.amount,
    required this.note,
  });

  @override
  State<_UpiPaySheet> createState() => _UpiPaySheetState();
}

class _UpiPaySheetState extends State<_UpiPaySheet> {
  bool _savingQr = false;
  late final Uri _uri;
  late final String _amtDisplay;
  late final String _filename;

  @override
  void initState() {
    super.initState();
    _uri = buildUpiUri(
      vpa: widget.vpa,
      payeeName: widget.payeeName,
      amount: widget.amount,
      note: widget.note,
    );
    _amtDisplay = widget.amount.toStringAsFixed(2);
    final slug = widget.note
        .replaceAll(RegExp(r'[^A-Za-z0-9._\-]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .toLowerCase();
    _filename = 'upi_${slug.isEmpty ? 'pay' : slug}.png';
    RenderLog.write('c336_qr_render', 'uri_len=${_uri.toString().length}');
  }

  void _copy(String value, String label, String logKey) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text('$label copied'),
      duration: const Duration(seconds: 1),
    ));
    RenderLog.write(logKey, 'v=$value');
  }

  Future<void> _saveQr() async {
    setState(() => _savingQr = true);
    try {
      final painter = QrPainter(
        data: _uri.toString(),
        version: QrVersions.auto,
        errorCorrectionLevel: QrErrorCorrectLevel.M,
      );
      final byteData = await painter.toImageData(1024);
      if (byteData == null) return;
      final bytes = byteData.buffer.asUint8List();
      final b64 = base64Encode(bytes);
      html.AnchorElement(href: 'data:image/png;base64,$b64')
          ..setAttribute('download', _filename)
          ..click();
      RenderLog.write('c336_saveqr', 'file=$_filename;bytes=${bytes.length}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text('QR save failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _savingQr = false);
    }
  }

  Future<void> _openIntent() async {
    RenderLog.write('c336_intent_fallback', 'vpa=${widget.vpa}');
    try {
      await launchUrl(_uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Widget _copyRow(String label, String value, String logKey) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 11, color: Color(0xFF9CA3AF))),
            const SizedBox(height: 2),
            SelectableText(value,
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF111827))),
          ]),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints:
              const BoxConstraints(minWidth: 36, minHeight: 36),
          icon: const Icon(Icons.copy, size: 18, color: Color(0xFF2E7D32)),
          onPressed: () => _copy(value, label, logKey),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final amtLabel = widget.amount == widget.amount.truncateToDouble()
        ? '₹${widget.amount.toInt()}'
        : '₹$_amtDisplay';

    return Container(
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.92),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 8),
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
              color: const Color(0xFFD1D5DB),
              borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            Expanded(
              child: Text(
                'Pay $amtLabel — ${widget.payeeName}',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => Navigator.of(context).pop(),
              visualDensity: VisualDensity.compact,
            ),
          ]),
        ),
        const SizedBox(height: 4),
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 32 + bottom),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border:
                          Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: QrImageView(
                      data: _uri.toString(),
                      version: QrVersions.auto,
                      size: 220,
                      errorCorrectionLevel: QrErrorCorrectLevel.M,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                _copyRow('UPI ID', widget.vpa, 'c336_copy_vpa'),
                _copyRow('Amount', _amtDisplay, 'c336_copy_amt'),
                if (widget.note.isNotEmpty)
                  _copyRow('Note', widget.note, 'c336_copy_note'),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _savingQr ? null : _saveQr,
                  icon: _savingQr
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.download_outlined, size: 18),
                  label: Text(_savingQr ? 'Saving…' : 'Save QR',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1B7A43),
                    minimumSize: const Size(double.infinity, 46),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F6F8),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Same phone: Save QR → open PhonePe/GPay scanner → tap gallery icon → pick QR.',
                        style: TextStyle(
                            fontSize: 12, color: Color(0xFF6B7280)),
                      ),
                      SizedBox(height: 4),
                      Text(
                        "Ya UPI ID copy karke app me 'To UPI ID' me paste karo.",
                        style: TextStyle(
                            fontSize: 12, color: Color(0xFF6B7280)),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Dusre phone se: QR seedha scan karo.',
                        style: TextStyle(
                            fontSize: 12, color: Color(0xFF6B7280)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _openIntent,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF6B7280),
                    minimumSize: const Size(double.infinity, 40),
                  ),
                  child: const Text(
                    'Open UPI app directly (may be declined)',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}
