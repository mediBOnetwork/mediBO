// lib/widgets/cust_pay_panel.dart — CHANGE #468
// Customer-facing Payment tab. Every string on screen comes from
// customer_order_payment_panel() except: the top-box Total/Due currency
// formatting (remaining.bill_total/due are raw numbers) and the pre-bill
// progress-bar fill (a 0.75×MRP estimate, never displayed as text).
// ignore_for_file: use_build_context_synchronously
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/bill_mime.dart';
import '../utils/download_bytes.dart';
import '../utils/render_log.dart';
import '../utils/safe_parse.dart';
import '../utils/toast.dart';
import 'sup_pay_panel.dart' show C330CopyRow;
import 'upi_pay_sheet.dart' show buildUpiUri;

class CustPayPanel extends StatefulWidget {
  final String orderId;
  final String orderCode;
  const CustPayPanel({super.key, required this.orderId, required this.orderCode});

  @override
  State<CustPayPanel> createState() => _CustPayPanelState();
}

class _CustPayPanelState extends State<CustPayPanel> {
  Map<String, dynamic>? _panel;
  bool _loading = true;
  String? _error;
  bool _uploading = false;
  int _chip = 0; // 0 = Payment Info; i+1 = payments[i]

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final res = await Supabase.instance.client.rpc(
        'customer_order_payment_panel',
        params: {'p_order_id': widget.orderId},
      );
      final panel = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      final totals = Map<String, dynamic>.from(panel['totals'] as Map? ?? {});
      final remaining = Map<String, dynamic>.from(panel['remaining'] as Map? ?? {});
      final ready = remaining['ready'] == true;
      final payments = (panel['payments'] as List?) ?? [];
      RenderLog.write('c468_total', ready ? _currency(remaining['bill_total']) : 'Updating soon');
      RenderLog.write('c468_due', ready ? _currency(remaining['due']) : 'Updating soon');
      RenderLog.write('c468_paid', totals['paid_label']?.toString() ?? '');
      RenderLog.write('c468_chip_count', 1 + payments.length);
      RenderLog.write('c468_remaining_ready', ready);
      RenderLog.write('c468_remaining_can_pay', remaining['can_pay'] == true);
      RenderLog.write('c468_can_respond', panel['can_respond'] == true);
      setState(() {
        _panel = panel;
        _loading = false;
        if (_chip > payments.length) _chip = 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = 'Could not load payment details.'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _panel == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43))),
      );
    }
    if (_error != null && _panel == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(_error!, style: const TextStyle(color: Colors.red)),
      );
    }
    final panel = _panel;
    if (panel == null) return const SizedBox.shrink();

    final totals = Map<String, dynamic>.from(panel['totals'] as Map? ?? {});
    final advance = Map<String, dynamic>.from(panel['advance'] as Map? ?? {});
    final remaining = Map<String, dynamic>.from(panel['remaining'] as Map? ?? {});
    final upi = Map<String, dynamic>.from(panel['upi'] as Map? ?? {});
    final payments = ((panel['payments'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final ready = remaining['ready'] == true;

    final totalText = ready ? _currency(remaining['bill_total']) : 'Updating soon';
    final dueText = ready ? _currency(remaining['due']) : 'Updating soon';
    final paidText = totals['paid_label']?.toString() ?? '';

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // ── Top boxes: Total | Paid | Due — equal thirds, no gap ─────────────
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: const Color(0xFFF9FAFB), borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          Expanded(child: _statLine('Total', totalText)),
          Expanded(child: _statLine('Paid', paidText)),
          Expanded(child: _statLine('Due', dueText)),
        ]),
      ),
      const SizedBox(height: 12),
      // ── Chip row: Payment Info + one per payment ──────────────────────────
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _CustPayChip(label: 'Payment Info', selected: _chip == 0, onTap: () => setState(() => _chip = 0)),
          for (var i = 0; i < payments.length; i++) ...[
            const SizedBox(width: 6),
            _CustPayChip(
              label: payments[i]['amount_label']?.toString() ?? '',
              selected: _chip == i + 1,
              tone: payments[i]['status_tone']?.toString(),
              onTap: () => setState(() => _chip = i + 1),
            ),
          ],
        ]),
      ),
      const SizedBox(height: 12),
      if (_chip == 0)
        _buildInfoTab(advance, remaining, totals, upi)
      else if (_chip - 1 < payments.length)
        _CustPaymentDetailCard(payment: payments[_chip - 1]),
    ]);
  }

  Widget _statLine(String label, String value) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 10.5, color: Color(0xFF9CA3AF))),
      Text(value,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
    ]);
  }

  // ── "Payment Info" chip content: Advance / Remaining Balance / Upload+Download ──
  Widget _buildInfoTab(
    Map<String, dynamic> advance,
    Map<String, dynamic> remaining,
    Map<String, dynamic> totals,
    Map<String, dynamic> upi,
  ) {
    final advPaid = safeParseDouble(advance['paid']);
    final advRequired = safeParseDouble(advance['required']);
    final advDue = (advRequired - advPaid) < 0 ? 0.0 : (advRequired - advPaid);
    final advPayLabel = advance['pay_label']?.toString() ?? 'Pay Advance';

    final ready = remaining['ready'] == true;
    final canPay = remaining['can_pay'] == true;
    final remPayLabel = remaining['pay_label']?.toString() ?? 'Pay Remaining';

    String remHeadline;
    String remSub;
    double remFill;
    if (ready) {
      remHeadline = remaining['value']?.toString() ?? '';
      remSub = remaining['sub']?.toString() ?? '';
      remFill = (safeParseInt(remaining['pct'])).clamp(0, 100) / 100;
    } else {
      remHeadline = 'Updating soon';
      remSub = '';
      final paidNum = _stripCurrencyLabel(totals['paid_label']?.toString() ?? '');
      final mrpNum = _stripCurrencyLabel(totals['total_label']?.toString() ?? '');
      remFill = mrpNum > 0 ? ((paidNum * 100 / (0.75 * mrpNum)).clamp(0, 100)) / 100 : 0.0;
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _CustStatCard(
        label: 'Advance',
        headline: advance['value']?.toString() ?? '',
        sub: '',
        fill: (safeParseInt(advance['pct'])).clamp(0, 100) / 100,
        barColor: const Color(0xFF1B7A43),
      ),
      _payButton(label: advPayLabel, onPressed: () => _openPaySheet(upi, advDue, advPayLabel)),
      const SizedBox(height: 16),
      _CustStatCard(
        label: 'Remaining Balance',
        headline: remHeadline,
        sub: remSub,
        fill: remFill,
        barColor: const Color(0xFF1B7A43),
      ),
      _payButton(
        label: remPayLabel,
        onPressed: (ready && canPay) ? () => _openPaySheet(upi, remaining['due'], remPayLabel) : null,
        tooltip: remPayLabel,
      ),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: _uploadButton()),
        const SizedBox(width: 10),
        Expanded(child: _downloadQrButton(upi)),
      ]),
    ]);
  }

  Widget _payButton({required String label, required VoidCallback? onPressed, String? tooltip}) {
    final button = SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF1B7A43),
          disabledBackgroundColor: const Color(0xFFE5E7EB),
          foregroundColor: Colors.white,
          disabledForegroundColor: const Color(0xFF9CA3AF),
          minimumSize: const Size(double.infinity, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Text(label),
      ),
    );
    if (onPressed != null || tooltip == null || tooltip.isEmpty) return button;
    return Tooltip(message: tooltip, child: button);
  }

  Widget _uploadButton() {
    return OutlinedButton(
      onPressed: _uploading ? null : _uploadScreenshot,
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: Color(0xFF1B7A43)),
        foregroundColor: const Color(0xFF1B7A43),
        disabledForegroundColor: const Color(0xFF9CA3AF),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        minimumSize: const Size(double.infinity, 40),
      ),
      child: _uploading
          ? const Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
              SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43))),
              SizedBox(width: 8),
              Text('Uploading…', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ])
          : const Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.upload_outlined, size: 16),
              SizedBox(width: 6),
              Flexible(
                child: Text('Upload Screenshot',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
              ),
            ]),
    );
  }

  Widget _downloadQrButton(Map<String, dynamic> upi) {
    return OutlinedButton(
      onPressed: () => _downloadQr(upi),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: Color(0xFF1B7A43)),
        foregroundColor: const Color(0xFF1B7A43),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        minimumSize: const Size(double.infinity, 40),
      ),
      child: const Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.qr_code_2_outlined, size: 16),
        SizedBox(width: 6),
        Flexible(
          child: Text('Download QR',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
        ),
      ]),
    );
  }

  // ── Pay Advance / Pay Remaining — QR built fresh with the live amount ────
  Future<void> _openPaySheet(Map<String, dynamic> upi, dynamic amountRaw, String payLabel) async {
    final vpa = upi['vpa']?.toString() ?? '';
    final name = upi['name']?.toString() ?? '';
    if (vpa.isEmpty) return;
    final uri = buildUpiUri(
      vpa: vpa,
      payeeName: name,
      amount: safeParseDouble(amountRaw),
      note: widget.orderCode,
    );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _CustPaySheet(qrData: uri.toString(), vpa: vpa, bankingName: name, payLabel: payLabel),
    );
  }

  // ── Download QR — static payload, no amount, saved directly ──────────────
  Future<void> _downloadQr(Map<String, dynamic> upi) async {
    final payload = upi['qr_payload']?.toString();
    final vpa = upi['vpa']?.toString() ?? '';
    final name = upi['name']?.toString() ?? '';
    if (payload == null || payload.isEmpty) return;
    try {
      final bytes = await _buildQrDownloadImage(qrPayload: payload, vpa: vpa, bankingName: name);
      downloadBytes(bytes, 'mediBO_payment_QR.png', 'image/png');
      RenderLog.write('c468_download_qr', 1);
    } catch (_) {
      if (mounted) showToast(context, 'Could not generate the QR image.', isError: true);
    }
  }

  // ── Upload screenshot — one tap: gallery → base64 → Gemini-verified edge fn ──
  Future<void> _uploadScreenshot() async {
    if (_uploading) return;
    XFile? img;
    try {
      img = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 90);
    } catch (_) {
      return;
    }
    if (img == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final bytes = await img.readAsBytes();
      final res = await Supabase.instance.client.functions.invoke(
        'customer-payment-upload',
        body: {
          'order_id': widget.orderId,
          'file_base64': base64Encode(bytes),
          'mime': mimeFromBillName(img.name),
          'filename': img.name,
        },
      );
      final data = res.data;
      final map = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
      final ok = map['ok'] == true;
      final message = map['message']?.toString() ?? (ok ? 'Payment recorded.' : 'Could not verify the screenshot.');
      if (!mounted) return;
      showToast(context, message, isError: !ok);
      if (ok) await _load();
    } catch (_) {
      if (mounted) showToast(context, 'Upload failed. Try again.', isError: true);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }
}

// ── Currency / parsing helpers ──────────────────────────────────────────────

String _currency(dynamic v) {
  final d = safeParseDouble(v);
  return d == d.truncateToDouble() ? '₹${d.toInt()}' : '₹${d.toStringAsFixed(2)}';
}

double _stripCurrencyLabel(String s) {
  final cleaned = s.replaceAll(RegExp(r'[^0-9.]'), '');
  return double.tryParse(cleaned) ?? 0.0;
}

Color _toneColor(String tone) => switch (tone) {
      'ok' => const Color(0xFF16A34A),
      'bad' => const Color(0xFFDC2626),
      _ => const Color(0xFFD97706),
    };

Color _toneBg(String? tone) => switch (tone) {
      null => const Color(0xFFF3F4F6),
      'ok' => const Color(0xFFD1FAE5),
      'bad' => const Color(0xFFFEE2E2),
      _ => const Color(0xFFFEF3C7),
    };

// ── QR + text composite for "Download QR" (dart:ui canvas, no widget tree) ──

Future<Uint8List> _buildQrDownloadImage({
  required String qrPayload,
  required String vpa,
  required String bankingName,
}) async {
  const width = 480.0;
  const padding = 32.0;
  const qrSize = 320.0;

  final qrImage = await QrPainter(
    data: qrPayload,
    version: QrVersions.auto,
    errorCorrectionLevel: QrErrorCorrectLevel.M,
  ).toImage(qrSize);

  TextPainter layout(String text, {double size = 16, FontWeight weight = FontWeight.w500}) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: size, fontWeight: weight, color: const Color(0xFF111827)),
      ),
      textDirection: TextDirection.ltr,
    );
    painter.layout(maxWidth: width - padding * 2);
    return painter;
  }

  final title = layout('mediBO payment QR', size: 18, weight: FontWeight.w700);
  final upiLine = layout('UPI ID: $vpa');
  final nameLine = layout('Banking Name: $bankingName');

  final height = padding + title.height + 16 + qrSize + 20 + upiLine.height + 10 + nameLine.height + padding;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width, height));
  canvas.drawRect(Rect.fromLTWH(0, 0, width, height), Paint()..color = Colors.white);

  double y = padding;
  title.paint(canvas, Offset((width - title.width) / 2, y));
  y += title.height + 16;

  canvas.drawImageRect(
    qrImage,
    Rect.fromLTWH(0, 0, qrImage.width.toDouble(), qrImage.height.toDouble()),
    Rect.fromLTWH((width - qrSize) / 2, y, qrSize, qrSize),
    Paint(),
  );
  y += qrSize + 20;

  upiLine.paint(canvas, Offset((width - upiLine.width) / 2, y));
  y += upiLine.height + 10;
  nameLine.paint(canvas, Offset((width - nameLine.width) / 2, y));

  final picture = recorder.endRecording();
  final image = await picture.toImage(width.toInt(), height.round());
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  return byteData!.buffer.asUint8List();
}

// ── Chip ───────────────────────────────────────────────────────────────────

class _CustPayChip extends StatelessWidget {
  final String label;
  final bool selected;
  final String? tone;
  final VoidCallback onTap;
  const _CustPayChip({required this.label, required this.selected, this.tone, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final solid = tone == null ? const Color(0xFF1B7A43) : _toneColor(tone!);
    final bg = selected ? solid : _toneBg(tone);
    final fg = selected ? Colors.white : (tone == null ? const Color(0xFF374151) : _toneColor(tone!));
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: fg)),
      ),
    );
  }
}

// ── Stat card ────────────────────────────────────────────────────────────────

class _CustStatCard extends StatelessWidget {
  final String label;
  final String headline;
  final String sub;
  final double fill;
  final Color barColor;
  const _CustStatCard({
    required this.label,
    required this.headline,
    required this.sub,
    required this.fill,
    required this.barColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFF9CA3AF))),
        const SizedBox(height: 4),
        Text(headline, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        if (sub.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(sub, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
        ],
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: fill,
            minHeight: 10,
            backgroundColor: const Color(0xFFF3F4F6),
            color: barColor,
          ),
        ),
      ]),
    );
  }
}

// ── Pay sheet — QR + UPI ID + Banking Name only, no amount line, no hint ────

class _CustPaySheet extends StatelessWidget {
  final String qrData;
  final String vpa;
  final String bankingName;
  final String payLabel;
  const _CustPaySheet({
    required this.qrData,
    required this.vpa,
    required this.bankingName,
    required this.payLabel,
  });

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.92),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 8),
        Container(
          width: 40, height: 4,
          decoration: BoxDecoration(color: const Color(0xFFD1D5DB), borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            Expanded(
              child: Text('$payLabel — mediBO',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => Navigator.of(context).pop(),
              visualDensity: VisualDensity.compact,
            ),
          ]),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 32 + bottom),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: QrImageView(
                    data: qrData,
                    version: QrVersions.auto,
                    size: 220,
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              C330CopyRow(label: 'UPI ID', value: vpa),
              C330CopyRow(label: 'Banking Name', value: bankingName),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ── Payment detail card — shown when a payment chip is selected ────────────

class _CustPaymentDetailCard extends StatelessWidget {
  final Map<String, dynamic> payment;
  const _CustPaymentDetailCard({required this.payment});

  @override
  Widget build(BuildContext context) {
    final statusLabel = payment['status_label']?.toString() ?? '';
    final statusTone = payment['status_tone']?.toString() ?? 'pending';
    final methodLabel = payment['method_label']?.toString() ?? '';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: _toneBg(statusTone), borderRadius: BorderRadius.circular(12)),
            child: Text(statusLabel,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _toneColor(statusTone))),
          ),
          const Spacer(),
          if (methodLabel.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(12)),
              child: Text(methodLabel,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF374151))),
            ),
        ]),
        const SizedBox(height: 10),
        C330CopyRow(label: 'Amount', value: payment['amount_label']?.toString()),
        C330CopyRow(label: 'When', value: payment['when_label']?.toString()),
        C330CopyRow(label: 'UTR', value: payment['utr']?.toString()),
        C330CopyRow(label: 'App', value: payment['app']?.toString()),
      ]),
    );
  }
}
