// lib/widgets/cust_pay_panel.dart — CHANGE #468
// Customer-facing Payment tab. Every string on screen comes from
// customer_order_payment_panel() except: the top-box Total/Due currency
// formatting (remaining.bill_total/due are raw numbers) and the pre-bill
// progress-bar fill (a 0.75×MRP estimate, never displayed as text).
// ignore_for_file: use_build_context_synchronously
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/bill_mime.dart';
import '../utils/download_bytes.dart';
import '../utils/payment_proof.dart';
import '../utils/render_log.dart';
import '../utils/safe_parse.dart';
import '../utils/toast.dart';
import 'fullscreen_image.dart';
import 'native_signed_image.dart';
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
      final display = Map<String, dynamic>.from(panel['display'] as Map? ?? {});
      final totals = Map<String, dynamic>.from(panel['totals'] as Map? ?? {});
      final remaining = Map<String, dynamic>.from(panel['remaining'] as Map? ?? {});
      final ready = remaining['ready'] == true;
      final payments = (panel['payments'] as List?) ?? [];
      // CHANGE #480 — totals now come verbatim from backend display.* (which
      // already carry the "Awaiting bill" pending text); no client-side literal.
      RenderLog.write('c468_total', display['total']?.toString() ?? '');
      RenderLog.write('c468_due', display['due']?.toString() ?? '');
      RenderLog.write('c468_paid', display['paid']?.toString() ?? totals['paid_label']?.toString() ?? '');
      RenderLog.write('c468_chip_count', 1 + payments.length);
      RenderLog.write('c468_remaining_ready', ready);
      RenderLog.write('c468_remaining_can_pay', remaining['can_pay'] == true);
      RenderLog.write('c468_can_respond', panel['can_respond'] == true);
      RenderLog.write('c474_build', 1);
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

    final display = Map<String, dynamic>.from(panel['display'] as Map? ?? {});
    final totals = Map<String, dynamic>.from(panel['totals'] as Map? ?? {});
    final advance = Map<String, dynamic>.from(panel['advance'] as Map? ?? {});
    final remaining = Map<String, dynamic>.from(panel['remaining'] as Map? ?? {});
    final upi = Map<String, dynamic>.from(panel['upi'] as Map? ?? {});
    final payments = ((panel['payments'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    // CHANGE #480 — print backend strings verbatim. display.* already contain
    // the "Awaiting bill" pending text when the bill is unconfirmed; we never
    // compute or hardcode that literal here. Fallback: pending_label else '—'.
    String disp(String key) {
      final v = display[key]?.toString();
      if (v != null && v.isNotEmpty) return v;
      final pending = display['pending_label']?.toString();
      return (pending != null && pending.isNotEmpty) ? pending : '—';
    }

    final totalText = disp('total');
    final dueText = disp('due');
    final paidText = disp('paid');

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
        _buildInfoTab(advance, remaining, totals, upi, display)
      else if (_chip - 1 < payments.length)
        _CustPaymentDetailCard(
          key: ValueKey(payments[_chip - 1]['id']?.toString() ?? _chip),
          payment: payments[_chip - 1],
        ),
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
    Map<String, dynamic> display,
  ) {
    final advPaid = safeParseDouble(advance['paid']);
    final advRequired = safeParseDouble(advance['required']);
    final advDue = (advRequired - advPaid) < 0 ? 0.0 : (advRequired - advPaid);
    final advPayLabel = advance['pay_label']?.toString() ?? 'Pay Advance';

    final ready = remaining['ready'] == true;
    final remPayLabel = remaining['pay_label']?.toString() ?? 'Pay Remaining';

    // CHANGE #480 — Remaining headline reads backend display.remaining verbatim
    // (carries "Awaiting bill" until the bill is imported). No client literal.
    final remHeadline = display['remaining']?.toString().isNotEmpty == true
        ? display['remaining'].toString()
        : (display['pending_label']?.toString() ?? '—');
    final remSub = remaining['sub']?.toString() ?? '';
    double remFill;
    if (ready) {
      remFill = (safeParseInt(remaining['pct'])).clamp(0, 100) / 100;
    } else {
      final paidNum = _stripCurrencyLabel(totals['paid_label']?.toString() ?? '');
      final mrpNum = _stripCurrencyLabel(totals['total_label']?.toString() ?? '');
      remFill = mrpNum > 0 ? ((paidNum * 100 / (0.75 * mrpNum)).clamp(0, 100)) / 100 : 0.0;
    }

    // CHANGE #480 — advance/remaining badges are fully backend-owned now:
    // label/tone/clickable come verbatim from advance.badge_* / remaining.badge_*.
    // No client-side computation of these labels or colours.
    RenderLog.write('c480_pay_badges_bound', 1);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _CustStatCard(
        label: 'Advance',
        headline: advance['value']?.toString() ?? '',
        sub: '',
        fill: (safeParseInt(advance['pct'])).clamp(0, 100) / 100,
        barColor: const Color(0xFF1B7A43),
        badge: _backendBadge(
          label: advance['badge_label']?.toString() ?? '',
          tone: advance['badge_tone']?.toString() ?? 'yellow',
          clickable: advance['badge_clickable'] == true,
          onTap: () => _openPaySheet(upi, advDue, advPayLabel, 'advance'),
        ),
      ),
      const SizedBox(height: 16),
      _CustStatCard(
        label: 'Remaining Balance',
        headline: remHeadline,
        sub: remSub,
        fill: remFill,
        barColor: const Color(0xFF1B7A43),
        badge: _backendBadge(
          label: remaining['badge_label']?.toString() ?? '',
          tone: remaining['badge_tone']?.toString() ?? 'grey',
          clickable: remaining['badge_clickable'] == true,
          onTap: () => _openPaySheet(upi, remaining['due'], remPayLabel, 'remaining'),
        ),
      ),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: _uploadButton()),
        const SizedBox(width: 10),
        Expanded(child: _downloadQrButton(upi)),
      ]),
    ]);
  }

  // CHANGE #480 — single backend-driven badge. Text, colour and tap-ability
  // all come verbatim from the RPC's badge_label / badge_tone / badge_clickable.
  // tone: 'green' = paid/done, 'yellow' = action pending, 'grey' = disabled.
  // A non-clickable badge renders as a static chip (no GestureDetector).
  Widget _backendBadge({
    required String label,
    required String tone,
    required bool clickable,
    required VoidCallback onTap,
  }) {
    final (Color bg, Color fg) = switch (tone) {
      'green' => (const Color(0xFFD1FAE5), const Color(0xFF065F46)),
      'yellow' => (const Color(0xFFFEF3C7), const Color(0xFF92400E)),
      _ => (const Color(0xFFF3F4F6), const Color(0xFF9CA3AF)), // grey / disabled
    };
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
      child: Text(label,
          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: fg)),
    );
    if (!clickable) return chip;
    return GestureDetector(onTap: onTap, child: chip);
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
  // kind = 'advance' | 'remaining' — carried into the sheet so the WhatsApp
  // "send QR" action can tell the backend which QR (advance vs remaining) to send.
  Future<void> _openPaySheet(
      Map<String, dynamic> upi, dynamic amountRaw, String payLabel, String kind) async {
    final vpa = upi['vpa']?.toString() ?? '';
    final name = upi['name']?.toString() ?? '';
    if (vpa.isEmpty) return;
    final amount = safeParseDouble(amountRaw);
    final uri = buildUpiUri(
      vpa: vpa,
      payeeName: name,
      amount: amount,
      note: widget.orderCode,
    );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => CustPaySheet(
        qrData: uri.toString(),
        vpa: vpa,
        bankingName: name,
        payLabel: payLabel,
        orderId: widget.orderId,
        amount: amount,
        kind: kind,
      ),
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

// Still used by the top-level static "Download QR" button (main Payment tab,
// generic no-amount QR) — the pay-popup's own Download QR no longer composes
// an image client-side at all (CHANGE #486): it downloads the backend's
// rendered image via payment-qr-image, avoiding the duplicated-amount bug
// that came from combining the backend's own amount text with a locally
// composed label.
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
  final Widget? badge;
  const _CustStatCard({
    required this.label,
    required this.headline,
    required this.sub,
    required this.fill,
    required this.barColor,
    this.badge,
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
        Row(children: [
          Expanded(
            child: Text(label,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFF9CA3AF))),
          ),
          ?badge,
        ]),
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

// Public (not `_`-prefixed) so test/pay_popup_test.dart can pump it directly
// with fake fetchWaNumbers/sendQr/fetchQrImage/downloadSink — the real
// Supabase RPCs/edge function and dart:html download stay the defaults in
// production.
class CustPaySheet extends StatefulWidget {
  final String qrData;
  final String vpa;
  final String bankingName;
  final String payLabel;
  final String orderId;
  final double amount;
  final String kind; // 'advance' | 'remaining'
  final Future<dynamic> Function(String orderId)? fetchWaNumbers;
  final Future<Map<String, dynamic>> Function(String orderId, String phone, double amount, String kind)? sendQr;
  // CHANGE #486: max backend — the QR image is rendered server-side by the
  // payment-qr-image edge function; the app only requests it and downloads
  // the returned url. Replaces the old client-side RepaintBoundary/toImage
  // composition (which duplicated the amount already burned into the image).
  final Future<Map<String, dynamic>> Function(String orderId, double amount, String kind)? fetchQrImage;
  final void Function(String url, String filename)? downloadSink;
  const CustPaySheet({
    super.key,
    required this.qrData,
    required this.vpa,
    required this.bankingName,
    required this.payLabel,
    required this.orderId,
    required this.amount,
    required this.kind,
    this.fetchWaNumbers,
    this.sendQr,
    this.fetchQrImage,
    this.downloadSink,
  });

  @override
  State<CustPaySheet> createState() => _CustPaySheetState();
}

class _CustPaySheetState extends State<CustPaySheet> {
  final LayerLink _waButtonLink = LayerLink();
  OverlayEntry? _waPopupEntry;
  bool _downloadingQr = false;

  @override
  void dispose() {
    _waPopupEntry?.remove();
    _waPopupEntry = null;
    super.dispose();
  }

  Future<Map<String, dynamic>> _invokeQrImage() async {
    final res = await Supabase.instance.client.functions.invoke('payment-qr-image', body: {
      'order_id': widget.orderId,
      'amount': widget.amount,
      'kind': widget.kind,
    });
    final data = res.data;
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  // Download — the backend renders this sheet's live amount (advance/
  // remaining) into the QR image and returns a signed url; the app just
  // requests it and downloads it, it never composes the image itself.
  Future<void> _downloadSheetQr() async {
    if (_downloadingQr) return;
    setState(() => _downloadingQr = true);
    try {
      final res = widget.fetchQrImage != null
          ? await widget.fetchQrImage!(widget.orderId, widget.amount, widget.kind)
          : await _invokeQrImage();
      final url = res['url']?.toString();
      if (url == null || url.isEmpty) throw Exception('payment-qr-image returned no url');
      final filename = res['filename']?.toString() ?? 'mediBO-pay-${widget.amount}.jpg';
      final sink = widget.downloadSink ?? downloadUrl;
      sink(url, filename);
      RenderLog.write('c486_paypopup_qr_backend', 1);
    } catch (_) {
      if (mounted) showToast(context, 'Could not download the QR image.', isError: true);
    } finally {
      if (mounted) setState(() => _downloadingQr = false);
    }
  }

  // WhatsApp — mini popup anchored DIRECTLY ABOVE the button via
  // CompositedTransformTarget/Follower + LayerLink (CHANGE #488). The
  // earlier plain localToGlobal/Positioned-in-Overlay math (#482) assumed
  // the Overlay's own coordinate origin was the screen's global (0,0),
  // which broke to a screen-centred-looking popup wherever that assumption
  // didn't hold — LayerLink tracks the button's actual transform layer
  // directly, so it can't drift off like that regardless of nesting.
  // Horizontal screen-edge clamping (Follower has no notion of screen
  // bounds itself) is done via the offset, computed in the OVERLAY's own
  // coordinate space so it lines up with where Positioned.fill paints.
  void _showWaPopup(BuildContext buttonContext) {
    _waPopupEntry?.remove();
    _waPopupEntry = null;
    final box = buttonContext.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;

    final overlayState = Overlay.of(buttonContext);
    final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
    const popupW = 260.0;
    var dx = 0.0;
    if (overlayBox != null) {
      final buttonLeftInOverlay = box.localToGlobal(Offset.zero, ancestor: overlayBox).dx;
      final desiredLeft = buttonLeftInOverlay + box.size.width / 2 - popupW / 2;
      final clampedLeft =
          desiredLeft.clamp(12.0, math.max(12.0, overlayBox.size.width - popupW - 12.0));
      dx = clampedLeft - buttonLeftInOverlay;
    }

    void dismiss() {
      _waPopupEntry?.remove();
      _waPopupEntry = null;
    }

    RenderLog.write('c488_paypopup_wa_layerlink', 1);
    _waPopupEntry = OverlayEntry(builder: (_) => Stack(children: [
      Positioned.fill(
        child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: dismiss),
      ),
      CompositedTransformFollower(
        key: const Key('payQrWaPopupAnchor'),
        link: _waButtonLink,
        showWhenUnlinked: false,
        targetAnchor: Alignment.topLeft,
        followerAnchor: Alignment.bottomLeft,
        offset: Offset(dx, -6),
        child: Material(
          borderRadius: BorderRadius.circular(12),
          elevation: 8,
          color: Colors.white,
          child: SizedBox(
            width: popupW,
            child: PayQrWaPicker(
              orderId: widget.orderId,
              amount: widget.amount,
              kind: widget.kind,
              fetchWaNumbers: widget.fetchWaNumbers,
              sendQr: widget.sendQr,
            ),
          ),
        ),
      ),
    ]));
    Overlay.of(buttonContext).insert(_waPopupEntry!);
  }

  Widget _sheetActionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool loading = false,
  }) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: Color(0xFF1B7A43)),
        foregroundColor: const Color(0xFF1B7A43),
        disabledForegroundColor: const Color(0xFF9CA3AF),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        minimumSize: const Size(double.infinity, 44),
      ),
      child: loading
          ? const Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
              SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43))),
            ])
          : Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 16),
              const SizedBox(width: 6),
              Flexible(
                child: Text(label,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis),
              ),
            ]),
    );
  }

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
              child: Text('${widget.payLabel} — mediBO',
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
                    data: widget.qrData,
                    version: QrVersions.auto,
                    size: 220,
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              C330CopyRow(label: 'UPI ID', value: widget.vpa),
              C330CopyRow(label: 'Banking Name', value: widget.bankingName),
              const SizedBox(height: 4),
              // ── Download QR (this sheet's live amount) · WhatsApp (mini
              // floating popup anchored to this button, listing saved numbers) ──
              Row(children: [
                Expanded(
                  child: _sheetActionButton(
                    icon: Icons.qr_code_2_outlined,
                    label: 'Download QR',
                    loading: _downloadingQr,
                    onTap: _downloadingQr ? null : _downloadSheetQr,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: CompositedTransformTarget(
                    link: _waButtonLink,
                    child: Builder(
                      builder: (btnContext) => _sheetActionButton(
                        icon: Icons.chat_bubble_outline,
                        label: 'WhatsApp',
                        onTap: () => _showWaPopup(btnContext),
                      ),
                    ),
                  ),
                ),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ── WhatsApp mini-popup: pick a saved number → backend renders & sends the QR ──
// Sends via send_payment_qr_wa(p_order_id, p_phone, p_amount, p_kind). The backend
// does the entire send (renders the amount's QR image + WhatsApps it + records
// last-used) — there is NO wa.me/share fallback. On success we re-fetch the number
// list so the "last used" badge moves to the number just used.
// Public so test/pay_popup_test.dart can pump it with fake fetchWaNumbers/sendQr.
class PayQrWaPicker extends StatefulWidget {
  final String orderId;
  final double amount;
  final String kind; // 'advance' | 'remaining'
  final Future<dynamic> Function(String orderId)? fetchWaNumbers;
  final Future<Map<String, dynamic>> Function(String orderId, String phone, double amount, String kind)? sendQr;
  const PayQrWaPicker({
    super.key,
    required this.orderId,
    required this.amount,
    required this.kind,
    this.fetchWaNumbers,
    this.sendQr,
  });

  @override
  State<PayQrWaPicker> createState() => _PayQrWaPickerState();
}

class _PayQrWaPickerState extends State<PayQrWaPicker> {
  List<Map<String, dynamic>>? _numbers;
  String? _error;
  String? _sendingPhone; // row currently in-flight
  String? _sentPhone;    // row that just succeeded → "Sent to WhatsApp ✓"
  String? _errorPhone;   // row that just failed → "Couldn't send — try again"

  @override
  void initState() {
    super.initState();
    _load();
  }

  // CHANGE #484 fix: the RPC returns {"numbers": [...]} (a Map), not a bare
  // List — the old `raw is List` check was always false against the real
  // shape, so the list stayed empty and showed "No saved number" even when
  // the backend had a number. Handle both shapes defensively.
  static List<Map<String, dynamic>> _parseNumbers(dynamic raw) {
    final dynamic list = raw is Map ? raw['numbers'] : raw;
    return (list is List ? list : const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<void> _load() async {
    try {
      final dynamic raw = widget.fetchWaNumbers != null
          ? await widget.fetchWaNumbers!(widget.orderId)
          : await Supabase.instance.client
              .rpc('customer_order_wa_numbers', params: {'p_order_id': widget.orderId});
      final list = _parseNumbers(raw);
      if (mounted) setState(() { _numbers = list; _error = null; });
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load numbers.');
    }
  }

  Future<void> _send(String phone) async {
    if (_sendingPhone != null) return;
    // Render-log the wired tap-to-send (was a no-op before CHANGE #481).
    RenderLog.write('c481_payqr_send_wired',
        'kind=${widget.kind};amt=${widget.amount};phone=$phone');
    setState(() { _sendingPhone = phone; _sentPhone = null; _errorPhone = null; });
    try {
      final Map<String, dynamic> res = widget.sendQr != null
          ? await widget.sendQr!(widget.orderId, phone, widget.amount, widget.kind)
          : await _rpcSendQr(phone);
      if (!mounted) return;
      if (res['status'] == 'queued') {
        setState(() { _sendingPhone = null; _sentPhone = phone; });
        await _load(); // refresh so the "last used" badge moves to this number
      } else {
        setState(() { _sendingPhone = null; _errorPhone = phone; });
      }
    } catch (_) {
      if (mounted) setState(() { _sendingPhone = null; _errorPhone = phone; });
    }
  }

  Future<Map<String, dynamic>> _rpcSendQr(String phone) async {
    final raw = await Supabase.instance.client.rpc('send_payment_qr_wa', params: {
      'p_order_id': widget.orderId,
      'p_phone': phone,
      'p_amount': widget.amount,
      'p_kind': widget.kind,
    });
    return raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 300),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text('Send QR to',
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
                    children: _numbers!.map((e) {
                      final phone = e['phone']?.toString() ?? '';
                      // CHANGE #486: the backend now composes the row text
                      // (plain "8357881873" for the WhatsApp number, "<num> ·
                      // Phone" for extras) — show it verbatim, don't rebuild
                      // it from phone+label in the app.
                      final display = e['display']?.toString() ?? phone;
                      // last_used is a per-row boolean from this RPC (unlike
                      // the sibling customer_bill_numbers/last-timestamp
                      // shape) — compare with `== true`, not `!= null`.
                      final isLastUsed = e['last_used'] == true;
                      final busy = _sendingPhone == phone;
                      final sent = _sentPhone == phone;
                      final failed = _errorPhone == phone;
                      return InkWell(
                        onTap: _sendingPhone == null ? () => _send(phone) : null,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                          child: Row(children: [
                            const Icon(Icons.chat_bubble, size: 16, color: Color(0xFF1B7A43)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(display,
                                    style: const TextStyle(fontSize: 13.5, color: Color(0xFF111827))),
                                if (sent)
                                  const Padding(
                                    padding: EdgeInsets.only(top: 2),
                                    child: Text('Sent to WhatsApp ✓',
                                        style: TextStyle(fontSize: 11, color: Color(0xFF1B7A43), fontWeight: FontWeight.w600)),
                                  )
                                else if (failed)
                                  const Padding(
                                    padding: EdgeInsets.only(top: 2),
                                    child: Text("Couldn't send — try again",
                                        style: TextStyle(fontSize: 11, color: Color(0xFFDC2626), fontWeight: FontWeight.w600)),
                                  ),
                              ]),
                            ),
                            if (isLastUsed && !busy)
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
      ),
    );
  }
}

// ── Payment detail card — shown when a payment chip is selected ────────────

class _CustPaymentDetailCard extends StatelessWidget {
  final Map<String, dynamic> payment;
  const _CustPaymentDetailCard({super.key, required this.payment});

  @override
  Widget build(BuildContext context) {
    final statusLabel = payment['status_label']?.toString() ?? '';
    final statusTone = payment['status_tone']?.toString() ?? 'pending';
    // CHANGE #480 — mirror the admin View-Payment card exactly: status pill on
    // the left, Cash/Online mode badge on the right, then method-specific rows.
    final isCash = (payment['method']?.toString() ?? 'online') == 'cash';
    final modeLabel = payment['method_label']?.toString().isNotEmpty == true
        ? payment['method_label'].toString()
        : (isCash ? 'Cash' : 'Online');

    final path = payment['screenshot']?.toString() ?? '';

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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: isCash ? const Color(0xFFF3F4F6) : const Color(0xFFE8F5E9),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(modeLabel,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isCash ? const Color(0xFF374151) : const Color(0xFF1B5E20))),
          ),
        ]),
        const SizedBox(height: 10),
        // ── Detail rows — same fields & order as admin's _OrderPaymentPanel ──
        if (isCash) ...[
          C330CopyRow(label: 'Amount', value: payment['amount_label']?.toString()),
          C330CopyRow(label: 'Received by', value: payment['collected_by']?.toString()),
          C330CopyRow(label: 'Location', value: payment['location']?.toString()),
          _viewInMapsRow(context, payment['location']?.toString()),
          C330CopyRow(label: 'Received at', value: payment['paid_label']?.toString()),
        ] else ...[
          C330CopyRow(label: 'Amount', value: payment['amount_label']?.toString()),
          C330CopyRow(label: 'Payee', value: payment['payee_name']?.toString()),
          C330CopyRow(label: 'App', value: payment['app']?.toString()),
          C330CopyRow(label: 'UTR', value: payment['utr']?.toString()),
          C330CopyRow(label: 'Txn', value: payment['txn_id']?.toString()),
          C330CopyRow(label: 'Paid', value: payment['paid_label']?.toString()),
        ],
        if (path.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _PaymentProofImage(
              bucket: resolvePaymentProofBucket(payment['bucket']?.toString(), path),
              path: path,
            ),
          ),
      ]),
    );
  }

  // ── "View in Maps" — opens Google Maps search for the collected location ──
  Widget _viewInMapsRow(BuildContext context, String? location) {
    final loc = (location ?? '').trim();
    if (loc.isEmpty) return const SizedBox.shrink();
    final mapsUrl =
        'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(loc)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: () {
          try {
            launchUrl(Uri.parse(mapsUrl), webOnlyWindowName: '_blank');
          } catch (_) {}
        },
        borderRadius: BorderRadius.circular(8),
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.location_on, size: 18, color: Color(0xFF1A73E8)),
            SizedBox(width: 6),
            Text('View in Maps',
                style: TextStyle(
                    color: Color(0xFF1A73E8), fontWeight: FontWeight.w600, fontSize: 14)),
          ]),
        ),
      ),
    );
  }
}

// ── Proof image — signed URL, bounded (never an unbounded spinner) ─────────

class _PaymentProofImage extends StatefulWidget {
  final String bucket;
  final String path;
  const _PaymentProofImage({required this.bucket, required this.path});

  @override
  State<_PaymentProofImage> createState() => _PaymentProofImageState();
}

class _PaymentProofImageState extends State<_PaymentProofImage> {
  String? _url;
  bool _error = false;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    RenderLog.write('c474_pay_img_widget', 1);
    _load();
  }

  Future<void> _load() async {
    try {
      final url = await Supabase.instance.client.storage
          .from(widget.bucket)
          .createSignedUrl(widget.path, 3600)
          .timeout(const Duration(seconds: 8));
      if (mounted) setState(() { _url = url; _error = false; _attempt++; });
    } catch (e) {
      RenderLog.write('c474_cust_sign_err_msg', 'bucket=${widget.bucket};path=${widget.path};err=$e');
      if (mounted) setState(() => _error = true);
    }
  }

  void _retry() {
    setState(() { _error = false; _url = null; });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final box = BoxDecoration(
      color: const Color(0xFFF3F4F6),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: const Color(0xFFE5E7EB)),
    );
    if (_error) {
      return GestureDetector(
        onTap: _retry,
        child: Container(
          width: double.infinity, height: 120,
          decoration: box,
          child: const Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.refresh, size: 20, color: Color(0xFF9CA3AF)),
              SizedBox(height: 4),
              Text("Couldn't load proof — tap to retry",
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF6B7280)), textAlign: TextAlign.center),
            ]),
          ),
        ),
      );
    }
    final url = _url;
    if (url == null) {
      return Container(
        width: double.infinity, height: 120,
        decoration: box,
        child: const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    // CHANGE #480 — proof preview enlarged to match the admin card: a portrait
    // 4:3 estimate off the available width, clamped to 60% of screen height so
    // the selfie/screenshot is clearly readable (was a fixed 140 px).
    RenderLog.write('c480_pay_card_photo', 1);
    return LayoutBuilder(builder: (lCtx, constraints) {
      final w = constraints.maxWidth;
      final maxH = MediaQuery.of(lCtx).size.height * 0.6;
      final h = (w * 1.33).clamp(240.0, maxH);
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: double.infinity,
          height: h,
          child: NativeSignedImage(
            key: ValueKey('${widget.bucket}/${widget.path}/$_attempt'),
            url: url,
            cacheKey: '${widget.bucket}-${widget.path.hashCode}-$_attempt',
            onTap: () => openFullscreenImage(context, url),
            onError: () {
              if (mounted && !_error) setState(() => _error = true);
            },
          ),
        ),
      );
    });
  }
}
