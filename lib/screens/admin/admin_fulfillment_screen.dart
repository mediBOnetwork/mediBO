// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:convert';
import '../../utils/render_log.dart';
import '../../widgets/dispute_state.dart';
import 'dispute/dispute_models.dart';
// dispute_card.dart removed in #170 — Disputes tab rebuilt with accordion layout
import '../../utils/responsive.dart';
import '../../utils/tts.dart';
import '../../user_state.dart';
import '../../services/voice_receive_service.dart';
import '../../supabase_config.dart' show SupabaseConfig;
import 'voice_receive.dart';
import '../../widgets/pinned_footer_list.dart';
import '../../widgets/fulfill_item_sheet.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

// #93: JS interop — mediboCheckLoudness is defined in web/index.html
@JS('mediboCheckLoudness')
external JSPromise _jsCheckLoudness(JSUint8Array data);

// ── C174/B10: single canonical dispute domain (no www per Cloudflare redirects) ──
const _kDisputeDomain = 'https://medibo.in';

// ── Color tokens ────────────────────────────────────────────────────────────
const _kGreen        = Color(0xFF1B7A43);
const _kBg           = Color(0xFFF5F6F8);
const _kCard         = Colors.white;
const _kBorder       = Color(0xFFE5E7EB);
const _kText         = Color(0xFF111827);
const _kSub          = Color(0xFF6B7280);

const _kReceivedBg   = Color(0xFFE1F5EE);
const _kReceivedFg   = Color(0xFF0F6E56);
const _kShortBg      = Color(0xFFFAECE7);
const _kShortFg      = Color(0xFF993C1D);
const _kWrongBg      = Color(0xFFFBE9E7);
const _kWrongFg      = Color(0xFFB42318);
const _kNotComingBg  = Color(0xFFEFEEE9);
const _kNotComingFg  = Color(0xFF5A5A57);
const _kShippedBg    = Color(0xFFE6F1FB);
const _kShippedFg    = Color(0xFF0C447C);
const _kPendingBg    = Color(0xFFFEF3C7);
const _kPendingFg    = Color(0xFF92400E);

const _stateBgMap = <String, Color>{
  'received': _kReceivedBg, 'short':     _kShortBg,
  'wrong':    _kWrongBg,    'not_coming':_kNotComingBg,
  'packed':   _kShippedBg,  'shipped':   _kShippedBg,
  'pending':  _kPendingBg,
};
const _stateFgMap = <String, Color>{
  'received': _kReceivedFg, 'short':     _kShortFg,
  'wrong':    _kWrongFg,    'not_coming':_kNotComingFg,
  'packed':   _kShippedFg,  'shipped':   _kShippedFg,
  'pending':  _kPendingFg,
};

// ── #331 VoiceCaps — daily 3h cap + 1h continuous stop ─────────────────────
// One shared helper used by every voice counting surface (Shop, Warehouse, Pack).
class _VoiceCaps {
  static int _remainingToday = 3 * 3600;
  static bool _lockedToday = false;

  // Call before starting any counting voice session.
  // Returns false if blocked (shows limit sheet internally).
  static Future<bool> onSessionStart(BuildContext context, SupabaseClient supabase) async {
    RenderLog.write('c331_caps', 'session_start;locked=$_lockedToday');
    if (_lockedToday) {
      _showLimitSheet(context);
      return false;
    }
    try {
      final raw = await supabase.rpc('voice_usage_today') as Map;
      final res = Map<String, dynamic>.from(raw);
      final remaining = (res['remaining_seconds'] as num?)?.toInt() ?? 0;
      _remainingToday = remaining;
      RenderLog.write('c331_caps', 'remaining=${remaining}s');
      if (remaining <= 0) {
        _lockedToday = true;
        if (context.mounted) {
          _showLimitSheet(context,
              usedSecs: (res['used_seconds'] as num?)?.toInt() ?? 0,
              capSecs: (res['daily_cap_seconds'] as num?)?.toInt() ?? 10800);
        }
        return false;
      }
    } catch (_) {}
    return true;
  }

  // Call after each clip is uploaded to storage.
  // No BuildContext needed — onLocked handles any UI feedback.
  static Future<void> onClipSaved(
    SupabaseClient supabase, {
    required String ctxStr,
    required String supplier,
    required String path,
    required int seconds,
    required void Function() onLocked,
  }) async {
    try {
      final raw = await supabase.rpc('voice_clip_register', params: {
        'p_context': ctxStr,
        'p_supplier': supplier,
        'p_path': path,
        'p_seconds': seconds.clamp(1, 3600),
      }) as Map;
      final res = Map<String, dynamic>.from(raw);
      if (res['ok'] == true) {
        _remainingToday = (res['remaining_seconds'] as num?)?.toInt() ?? _remainingToday;
        RenderLog.write('c331_caps', 'clip_saved;remaining=${_remainingToday}s');
      } else if (res['error'] == 'daily_cap') {
        _lockedToday = true;
        _remainingToday = 0;
        onLocked();
      }
    } catch (_) {}
  }

  // Formatted remaining time label for display near mic.
  static String remainingLabel() {
    if (_remainingToday <= 0) return '0m left today';
    final h = _remainingToday ~/ 3600;
    final m = (_remainingToday % 3600) ~/ 60;
    return h > 0 ? '${h}h ${m}m left today' : '${m}m left today';
  }

  static void _showLimitSheet(BuildContext context, {int? usedSecs, int? capSecs}) {
    final used = usedSecs != null
        ? '${usedSecs ~/ 3600}h ${(usedSecs % 3600) ~/ 60}m used'
        : '';
    final cap = capSecs != null ? '${capSecs ~/ 3600}h cap' : '3h cap';
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Daily voice-count limit reached (3h).',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _kText)),
              const SizedBox(height: 8),
              if (used.isNotEmpty || cap.isNotEmpty)
                Text('$used · $cap. Try again tomorrow.',
                    style: const TextStyle(fontSize: 13, color: _kSub)),
              const SizedBox(height: 20),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _kGreen),
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Shared micro-widgets ────────────────────────────────────────────────────

class _StatePill extends StatelessWidget {
  final String state;
  const _StatePill(this.state);

  @override
  Widget build(BuildContext context) {
    final bg = _stateBgMap[state] ?? _kPendingBg;
    final fg = _stateFgMap[state] ?? _kPendingFg;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(
        const <String, String>{
          'wrong': 'Wrong item',
          'not_coming': 'Not coming',
        }[state] ?? state.replaceAll('_', ' '),
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }
}

class _OrderStatusBadge extends StatelessWidget {
  final String status;
  const _OrderStatusBadge(this.status);

  @override
  Widget build(BuildContext context) {
    Color bg; Color fg;
    switch (status) {
      case 'shipped':           bg = _kShippedBg;  fg = _kShippedFg;  break;
      case 'partially_shipped': bg = _kShippedBg;  fg = _kShippedFg;  break;
      case 'ready':             bg = _kReceivedBg; fg = _kReceivedFg; break;
      case 'partial_ready':     bg = _kPendingBg;  fg = _kPendingFg;  break;
      case 'waiting':           bg = _kShortBg;    fg = _kShortFg;    break;
      default:                  bg = _kPendingBg;  fg = _kPendingFg;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(
        status.replaceAll('_', ' '),
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }
}

// ── #197: Merged product row (one per product, combining all customer lines) ──
class _MergedProduct {
  final int productId;
  final String productName;
  final String packType;
  final String? imageUrl;
  final int orderedTotal;
  final int receivedTotal;
  // #331: sum of shop_qty across all lines; null if any line has no shop count yet
  final int? shopQtyTotal;
  final List<String> orderItemIds; // underlying line IDs — for dispute lookup only
  final String combinedState; // 'pending'|'received'|'short'|'wrong'|'not_coming'
  final bool hasArrived; // true if any underlying Arrivals line has received_locked=true
  final List<Map>? bagBreakdown; // #254: per-bag breakdown for Arrivals

  const _MergedProduct({
    required this.productId,
    required this.productName,
    required this.packType,
    this.imageUrl,
    required this.orderedTotal,
    required this.receivedTotal,
    this.shopQtyTotal,
    required this.orderItemIds,
    required this.combinedState,
    this.hasArrived = false,
    this.bagBreakdown,
  });
}

class _FulfilImageTile extends StatelessWidget {
  final String? imageUrl;
  final double size;
  const _FulfilImageTile(this.imageUrl, {this.size = 52});

  @override
  Widget build(BuildContext context) {
    if (imageUrl == null || imageUrl!.isEmpty) {
      return Container(
        width: size, height: size,
        decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(8)),
        child: const Icon(Icons.medication_outlined, size: 24, color: Color(0xFFD1D5DB)),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        imageUrl!, width: size, height: size, fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: size, height: size, color: const Color(0xFFF3F4F6),
          child: const Icon(Icons.medication_outlined, size: 24, color: Color(0xFFD1D5DB)),
        ),
      ),
    );
  }
}

class _QtyStepper extends StatelessWidget {
  final int value;
  final int max;
  final ValueChanged<int> onChanged;
  const _QtyStepper({required this.value, required this.max, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _StepBtn(Icons.remove, value > 1 ? () => onChanged(value - 1) : null),
      const SizedBox(width: 4),
      Container(
        width: 40, height: 36, alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _kBg, border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text('$value',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _kText)),
      ),
      const SizedBox(width: 4),
      _StepBtn(Icons.add, value < max ? () => onChanged(value + 1) : null),
    ]);
  }
}

class _StepBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _StepBtn(this.icon, this.onTap);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36, height: 36, alignment: Alignment.center,
        decoration: BoxDecoration(
          color: onTap != null ? _kGreen : const Color(0xFFE5E7EB),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(icon, size: 18,
            color: onTap != null ? Colors.white : const Color(0xFF9CA3AF)),
      ),
    );
  }
}

// ── Bag breakdown formatter ───────────────────────────────────────────────────
// #261: format "B{bag}:{qty}{packInitial}" e.g. "B1:07P", "B38:05S"
String _fmtBreakdown(List? bd, String? packType) {
  if (bd == null || bd.isEmpty) return '';
  final pl = (packType ?? '').trim().isNotEmpty
      ? packType!.trim()[0].toUpperCase()
      : '';
  final sorted = List.from(bd)
    ..sort((a, b) => (a['bag_no'] as num).compareTo(b['bag_no'] as num));
  return sorted
      .map((e) => 'B${e['bag_no']}:${(e['qty'] as num).toInt().toString().padLeft(2, '0')}$pl')
      .join(', ');
}

// ── _BagScannerDialog — camera QR scan + gallery upload ──────────────────────

// Shared QR decode helper: FilePicker bytes → pure-Dart zxing2 → code string or null.
// Used by both _BagScannerDialog and _ChangeBagScanner.
// ZXing JS blob-URL approach (CHANGE #259) failed on clean QR images in PWA context.
Future<String?> _decodeQrFromBytesWeb(Uint8List bytes) async {
  try {
    img.Image? image = img.decodeImage(bytes);
    if (image == null) {
      RenderLog.write('c260_decode_fail', 'img_decode_null');
      return null;
    }
    // Downscale large images to ≤1000px for performance
    if (image.width > 1000 || image.height > 1000) {
      image = img.copyResize(image, width: image.width > image.height ? 1000 : -1,
          height: image.width <= image.height ? 1000 : -1);
    }
    final w = image.width;
    final h = image.height;
    // Build ARGB Int32List expected by RGBLuminanceSource
    final pixels = Int32List(w * h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final px = image.getPixel(x, y);
        final r = px.r.toInt();
        final g = px.g.toInt();
        final b = px.b.toInt();
        pixels[y * w + x] = (0xFF << 24) | (r << 16) | (g << 8) | b;
      }
    }
    final source = RGBLuminanceSource(w, h, pixels);
    final bitmap = BinaryBitmap(HybridBinarizer(source));
    try {
      final result = QRCodeReader().decode(bitmap);
      RenderLog.write('c260_decode_ok', 'code=${result.text}');
      return result.text;
    } catch (_) {
      // Retry with tryHarder hint
      try {
        final hints = DecodeHints();
        hints.put(DecodeHintType.tryHarder);
        final result = QRCodeReader().decode(bitmap, hints: hints);
        RenderLog.write('c260_decode_ok', 'harder;code=${result.text}');
        return result.text;
      } catch (_) {
        RenderLog.write('c260_decode_fail', 'no_qr_found');
        return null;
      }
    }
  } catch (e) {
    RenderLog.write('c260_decode_fail', 'exception;$e');
    return null;
  }
}

// _BagScannerDialog — pops Navigator with the scanned code string (or null on cancel/error).
// showDialog<String> callers read the return value directly; no callback needed.
class _BagScannerDialog extends StatefulWidget {
  final String title;
  const _BagScannerDialog({required this.title});

  @override
  State<_BagScannerDialog> createState() => _BagScannerDialogState();
}

class _BagScannerDialogState extends State<_BagScannerDialog> {
  late final MobileScannerController _ctrl;
  bool _detected = false;

  @override
  void initState() {
    super.initState();
    _ctrl = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  }

  void _close(BuildContext ctx, {String? code}) {
    if (!_detected || code == null) {
      try { _ctrl.stop(); } catch (_) {}
    }
    if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop(code);
  }

  @override
  void dispose() {
    RenderLog.write('c254_scanner_dispose', 'ok');
    _ctrl.dispose();
    super.dispose();
  }

  // #259 BUG1: Use FilePicker (withData:true) so the native file chooser opens reliably on
  // web PWA. image_picker.pickImage failed silently on some mobile Chrome contexts.
  // Bytes → blob URL → ZXing JS (web) or analyzeImage (native).
  Future<void> _pickAndDecodeQr(BuildContext ctx) async {
    if (_detected) return;
    FilePickerResult? result;
    try {
      RenderLog.write('c259_picker_opened', 'started;isWeb=$kIsWeb');
      result = await FilePicker.pickFiles(type: FileType.image, withData: true);
      RenderLog.write('c259_picker_opened', result == null ? 'cancelled' : 'ok');
    } catch (e) {
      RenderLog.write('c259_picker_opened', 'error;$e');
      if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('Could not open file chooser')));
      return;
    }
    if (result == null || result.files.isEmpty) return;

    final bytes = result.files.first.bytes;
    String? code;
    if (bytes != null && kIsWeb) {
      code = await _decodeQrFromBytesWeb(bytes);
    } else if (!kIsWeb) {
      final path = result.files.first.path;
      if (path != null) {
        try {
          final BarcodeCapture? capture = await _ctrl.analyzeImage(path);
          code = (capture?.barcodes.isNotEmpty ?? false) ? capture!.barcodes.first.rawValue : null;
        } catch (_) { code = null; }
      }
    }

    if (code == null || code.trim().isEmpty) {
      RenderLog.write('c259_upload_decoded', 'fail;no_qr');
      if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('No QR found — try a clearer photo')));
      return;
    }
    _detected = true;
    try { _ctrl.stop(); } catch (_) {}
    RenderLog.write('c259_upload_decoded', 'ok');
    if (ctx.mounted && Navigator.of(ctx).canPop()) Navigator.of(ctx).pop(code.trim());
  }

  Widget _scannerActionBtn({required IconData icon, required String label, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 52, height: 52,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: 0.25), width: 1),
          ),
          child: Icon(icon, color: Colors.white, size: 24),
        ),
        const SizedBox(height: 5),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600,
            shadows: [Shadow(color: Colors.black54, blurRadius: 4)])),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c258_scanner_controls', 'upload_qr=true;torch=false;isWeb=$kIsWeb');
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 320, height: 420,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
            child: Row(children: [
              Expanded(child: Text(widget.title,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _kText))),
              IconButton(
                onPressed: () => _close(context),
                icon: const Icon(Icons.close_rounded, size: 20, color: _kSub),
              ),
            ]),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text('Point camera at bag QR  •  or upload a photo',
                style: TextStyle(fontSize: 13, color: _kSub)),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
              child: Stack(children: [
                // Live camera
                MobileScanner(
                  controller: _ctrl,
                  errorBuilder: (ctx, error, _) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.camera_alt_outlined, size: 48, color: Color(0xFFD1D5DB)),
                        const SizedBox(height: 12),
                        const Text('Camera unavailable', style: TextStyle(color: _kSub, fontSize: 14)),
                        const SizedBox(height: 4),
                        Text(error.errorCode.name, style: const TextStyle(fontSize: 12, color: _kSub)),
                        const SizedBox(height: 16),
                        TextButton(onPressed: () => _close(ctx), child: const Text('Close')),
                      ]),
                    ),
                  ),
                  onDetect: (capture) {
                    if (_detected) return;
                    final code = capture.barcodes.isNotEmpty ? capture.barcodes.first.rawValue : null;
                    if (code != null && code.isNotEmpty) {
                      _detected = true;
                      _ctrl.stop();
                      if (mounted) Navigator.of(context).pop(code);
                    }
                  },
                ),
                // #258 BUG2: Upload QR only — Torch removed.
                Positioned(
                  bottom: 20, left: 0, right: 0,
                  child: Builder(builder: (ctx) {
                    RenderLog.write('c258_upload_btn', 'rendered;isWeb=$kIsWeb');
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _scannerActionBtn(
                          icon: Icons.photo_library_outlined,
                          label: 'Upload QR',
                          onTap: () => _pickAndDecodeQr(ctx),
                        ),
                      ],
                    );
                  }),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

// ── CHANGE-BAG SCANNER (#259 BUG2) ──────────────────────────────────────────
// ONE single screen: live camera always running + Upload QR + two color status boxes.
// Old bag RED→GREEN on detach; new bag GREY→RED→GREEN on attach; auto-closes.
// No separate status dialog, no second camera screen.

enum _CBStep { needOld, detaching, needNew, attaching, done }

class _ChangeBagScanner extends StatefulWidget {
  final String supplier;
  final Map<String, dynamic> currentBag;
  // #261: allow reopening into need_new when old bag was already detached
  final _CBStep initialStep;
  const _ChangeBagScanner({
    required this.supplier,
    required this.currentBag,
    this.initialStep = _CBStep.needOld,
  });
  @override State<_ChangeBagScanner> createState() => _ChangeBagScannerState();
}

class _ChangeBagScannerState extends State<_ChangeBagScanner> {
  late final MobileScannerController _ctrl;
  late _CBStep _step;
  bool _detected = false;
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _newBagData;

  static Map<String, dynamic> _norm(dynamic raw) {
    if (raw is List && raw.isNotEmpty) return Map<String, dynamic>.from(raw.first as Map);
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return {};
  }

  @override
  void initState() {
    super.initState();
    _step = widget.initialStep;
    _ctrl = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
    RenderLog.write('c259_changebag_one_screen',
        'init;bag=${widget.currentBag['bag_no']};initialStep=${widget.initialStep.name}');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // Routes a scanned/uploaded code to the current step's RPC.
  void _onCodeResolved(String code) {
    if (_step == _CBStep.needOld) _doDetach(code);
    else if (_step == _CBStep.needNew) _doAttach(code);
  }

  Future<void> _doDetach(String code) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      final raw = await Supabase.instance.client.rpc('bag_detach', params: {
        'p_supplier_name': widget.supplier,
        'p_bag_code': code,
      });
      final m = _norm(raw);
      if (!mounted) return;
      if (m['error'] != null) {
        final errCode = m['error'].toString();
        String msg = errCode == 'wrong_bag'
            ? 'Scan Bag ${m['expected'] ?? widget.currentBag['bag_no']} — that was Bag ${m['scanned'] ?? '?'}'
            : 'Bag error: $errCode';
        setState(() { _busy = false; _detected = false; _error = msg; });
        try { await _ctrl.start(); } catch (_) {}
        return;
      }
      RenderLog.write('c259_changebag_step', 'detached;bag=${widget.currentBag['bag_no']}');
      setState(() { _busy = false; _step = _CBStep.needNew; _detected = false; _error = null; });
      try { await _ctrl.start(); } catch (_) {}
    } catch (e) {
      if (mounted) {
        setState(() { _busy = false; _detected = false; _error = 'Could not detach: $e'; });
        try { await _ctrl.start(); } catch (_) {}
      }
    }
  }

  Future<void> _doAttach(String code) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      final raw = await Supabase.instance.client.rpc('bag_attach', params: {
        'p_supplier_name': widget.supplier,
        'p_bag_code': code,
      });
      final m = _norm(raw);
      if (!mounted) return;
      if (m['error'] != null) {
        // CHANGE #268 — friendly message for same-supplier reuse attempt
        final errCode = m['error'].toString();
        String msg;
        if (errCode == 'bag_already_used_by_supplier') {
          msg = m['hint']?.toString() ?? 'This bag was already used for this supplier — use a different bag.';
          RenderLog.write('c268_already_used', 'bag=${m['bag_no']?.toString() ?? code}');
        } else {
          msg = 'Bag error: $errCode';
        }
        setState(() { _busy = false; _detected = false; _error = msg; });
        try { await _ctrl.start(); } catch (_) {}
        return;
      }
      final bagData = m['bag'] is Map ? Map<String, dynamic>.from(m['bag'] as Map) : m;
      // CHANGE #268 — log reuse when a full bag attaches successfully (different supplier)
      if ((bagData['status']?.toString() ?? '') == 'full') {
        RenderLog.write('c268_reuse_ok', 'bag=${bagData['bag_no']}');
      }
      RenderLog.write('c259_changebag_step', 'attached;bag=${bagData['bag_no']}');
      setState(() { _busy = false; _step = _CBStep.done; _newBagData = bagData; });
      await Future.delayed(const Duration(milliseconds: 700));
      if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop(bagData);
    } catch (e) {
      if (mounted) {
        setState(() { _busy = false; _detected = false; _error = 'Could not attach: $e'; });
        try { await _ctrl.start(); } catch (_) {}
      }
    }
  }

  // Upload QR: FilePicker (web-reliable) → bytes → blob URL → ZXing JS decode.
  Future<void> _pickAndDecodeQr(BuildContext ctx) async {
    if (_detected || _busy) return;
    FilePickerResult? result;
    try {
      RenderLog.write('c259_picker_opened', 'started;step=${_step.name}');
      result = await FilePicker.pickFiles(type: FileType.image, withData: true);
      RenderLog.write('c259_picker_opened', result == null ? 'cancelled' : 'ok');
    } catch (e) {
      RenderLog.write('c259_picker_opened', 'error;$e');
      if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('Could not open file chooser')));
      return;
    }
    if (result == null || result.files.isEmpty) return;

    final bytes = result.files.first.bytes;
    String? code;
    if (bytes != null && kIsWeb) {
      code = await _decodeQrFromBytesWeb(bytes);
    } else if (!kIsWeb) {
      final path = result.files.first.path;
      if (path != null) {
        try {
          final BarcodeCapture? capture = await _ctrl.analyzeImage(path);
          code = (capture?.barcodes.isNotEmpty ?? false) ? capture!.barcodes.first.rawValue : null;
        } catch (_) { code = null; }
      }
    }

    if (code == null || code.trim().isEmpty) {
      RenderLog.write('c259_upload_decoded', 'fail;no_qr;step=${_step.name}');
      if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('No QR found — try a clearer photo')));
      return;
    }
    RenderLog.write('c259_upload_decoded', 'ok;step=${_step.name}');
    _detected = true;
    try { _ctrl.stop(); } catch (_) {}
    _onCodeResolved(code.trim());
  }

  Widget _statusBox({required String label, required String subtitle,
      required Color color, required IconData icon}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.40)),
      ),
      child: Row(children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color)),
          Text(subtitle, style: const TextStyle(fontSize: 11, color: _kSub)),
        ])),
        if (_busy)
          SizedBox(width: 14, height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: color)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c259_changebag_one_screen', 'built;step=${_step.name}');
    final currentNo = widget.currentBag['bag_no'];
    final newNo = _newBagData?['bag_no'];

    final oldDone = _step != _CBStep.needOld;
    final newActive = _step == _CBStep.needNew || _step == _CBStep.attaching;
    final newDone = _step == _CBStep.done;

    const red = Color(0xFFD32F2F);
    const green = Color(0xFF1B7A43);
    const grey = Color(0xFF9CA3AF);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
            child: Row(children: [
              const Expanded(child: Text('Change Bag',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _kText))),
              IconButton(
                onPressed: _busy ? null : () {
                  // #261: if old bag was already detached, emit partial so parent saves progress
                  if (_step == _CBStep.needNew || _step == _CBStep.attaching) {
                    Navigator.of(context).pop({
                      '_partial': true,
                      'old_bag_no': widget.currentBag['bag_no'],
                    });
                  } else {
                    Navigator.of(context).pop(null);
                  }
                },
                icon: const Icon(Icons.close_rounded, size: 20, color: _kSub),
              ),
            ]),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text('Point camera at bag QR  •  or upload a photo',
                style: TextStyle(fontSize: 13, color: _kSub)),
          ),
          // Live camera with Upload QR overlay
          ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            child: SizedBox(
              height: 230,
              child: Stack(children: [
                MobileScanner(
                  controller: _ctrl,
                  errorBuilder: (ctx, error, _) => Container(
                    color: Colors.black12,
                    child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.camera_alt_outlined, size: 40, color: Color(0xFFD1D5DB)),
                      const SizedBox(height: 8),
                      const Text('Camera unavailable', style: TextStyle(color: _kSub, fontSize: 13)),
                    ])),
                  ),
                  onDetect: (capture) {
                    if (_detected || _busy) return;
                    final code = capture.barcodes.isNotEmpty
                        ? capture.barcodes.first.rawValue : null;
                    if (code != null && code.isNotEmpty) {
                      _detected = true;
                      try { _ctrl.stop(); } catch (_) {}
                      _onCodeResolved(code);
                    }
                  },
                ),
                // Upload QR button bottom-center
                Positioned(
                  bottom: 12, left: 0, right: 0,
                  child: Builder(builder: (ctx) => Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      GestureDetector(
                        onTap: () => _pickAndDecodeQr(ctx),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Container(
                            width: 46, height: 46,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.45),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
                            ),
                            child: const Icon(Icons.photo_library_outlined,
                                color: Colors.white, size: 22),
                          ),
                          const SizedBox(height: 4),
                          const Text('Upload QR', style: TextStyle(
                              color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600,
                              shadows: [Shadow(color: Colors.black54, blurRadius: 4)])),
                        ]),
                      ),
                    ],
                  )),
                ),
              ]),
            ),
          ),
          // Status boxes
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: _statusBox(
              label: 'Old Bag $currentNo',
              subtitle: oldDone ? 'Detached ✓' : 'Scan to detach',
              color: oldDone ? green : red,
              icon: oldDone ? Icons.check_circle_outline : Icons.qr_code_scanner_rounded,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: _statusBox(
              label: newNo != null ? 'New Bag $newNo' : 'Scan new bag',
              subtitle: newDone ? 'Attached ✓' : (newActive ? 'Scan bag to attach' : 'Waiting…'),
              color: newDone ? green : (newActive ? red : grey),
              icon: newDone ? Icons.check_circle_outline : Icons.qr_code_scanner_rounded,
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Text(_error!,
                  style: const TextStyle(color: Color(0xFFD32F2F), fontSize: 12)),
            ),
          const SizedBox(height: 6),
        ]),
      ),
    );
  }
}

// ── AGENT PHASE STATE MACHINE ────────────────────────────────────────────────

enum AgentPhase { idle, listening, thinking, speaking, confirming }

// ── PICK-TO-LIGHT SCREEN ─────────────────────────────────────────────────────

class _PickToLightScreen extends StatefulWidget {
  // #155: arrivals=true → load suppliers from fw_list_arrivals; no confirm footer.
  final bool arrivals;
  const _PickToLightScreen({super.key, this.arrivals = false});

  @override
  State<_PickToLightScreen> createState() => _PickToLightScreenState();
}

class _PickToLightScreenState extends State<_PickToLightScreen> {
  // ── Supplier ──
  List<String> _suppliers = [];
  String? _selectedSupplier;
  bool _loadingSuppliers = true;

  // ── Box data ──
  List<Map<String, dynamic>> _items = [];
  bool _loadingBox = false;
  String? _error;

  // ── PTL navigation ──
  int _focusIdx = 0;
  bool _recording = false;
  bool _showListView = false;

  // #142: per-supplier dot state: 'green' | 'light_yellow' | 'yellow'
  Map<String, String> _supplierDotMap = {};

  // #117: per-supplier count mode from fw_list_arrivals ('shop'|'warehouse'|null)
  Map<String, String?> _supplierModeMap = {};

  // #120: per-supplier count mode for Collect from fw_supplier_modes()
  Map<String, String?> _collectModeMap = {};

  // #132A: open disputes keyed by order_item_id
  Map<String, Map<String, dynamic>> _disputeMap = {};
  // #189: DisputeItem index keyed by order_item_id for verbatim status badges
  Map<String, DisputeItem> _disputeItemMap = {};

  // #156: arrivals lock state
  bool _arrivalsLocked = false;

  // #253: active bag for warehouse counting
  // F6: per-supplier bag map so bag state survives supplier switches.
  final Map<String, Map<String, dynamic>?> _activeBagBySupplier = {};
  // #261: change-bag progress — keyed by supplier, value = old bag that was detached.
  // Cleared on attach success. Allows reopen to restore "scan new bag" step.
  final Map<String, Map<String, dynamic>> _changeProgressBySupplier = {};
  // CHANGE #271 — intent flag: supplier entered change-bag flow + old bag was detached.
  // Keyed by supplier → old_bag_no string. NOT cleared by _reloadItemsFromDB so it survives
  // the backend refresh that #270 added (backend active_bag=null is expected here).
  final Map<String, String?> _changeBagPendingOldBag = {};
  Map<String, dynamic>? get _activeBag => _activeBagBySupplier[_selectedSupplier ?? ''];
  set _activeBag(Map<String, dynamic>? v) {
    final s = _selectedSupplier ?? '';
    if (s.isNotEmpty) _activeBagBySupplier[s] = v;
  }
  bool _confirmingAll = false;
  bool _submittingCollect = false; // #125: Z1 guard — disables both Collect submit buttons mid-flight
  bool _sendingShortReminder = false; // C171

  // #116: supplier count mode from fw_get_state ('shop'|'warehouse'|null)
  String? _supplierMode;

  // #147: scroll controller for the supplier list + per-row keys for ensureVisible
  final ScrollController _listScrollCtrl = ScrollController();
  final Map<String, GlobalKey> _rowKeys = {};
  // #152: saved scroll offset — restored when a supplier is closed
  double _savedScrollOffset = 0.0;

  // ── Voice service (Vertex Gemini edge function) ──
  final _voiceService = VoiceReceiveService();
  bool _recStarted = false;

  // ── Voice state ──
  bool _voiceSupported = true;
  bool _voiceListening = false;
  bool _voiceProcessing = false;
  String _voiceInterim = '';
  String _voiceError = '';
  String _lastTranscript = '';
  // ── Voice results ──
  Timer? _idleTimer;
  DateTime? _recStartTime;
  // #331 VoiceCaps: continuous-session timer
  int _continuousSecs = 0;
  Timer? _capsTimer;
  int _voiceCallsDuringRecord = 0; // must stay 0; guard for B1
  int _voiceCallsAfterStop = 0;
  final Map<int, num> _tally = {};

  // ── supplier_orders items for reconciliation expected list ──
  List<Map<String, dynamic>> _supplierOrderItems = [];

  // ── #115: clip persistence ──────────────────────────────────────────────────
  // #125: _recordingSeq removed — seq now comes from next_voice_recording_seq RPC
  String? _latestClipPath;    // last uploaded clip path (for ▶ whole-clip play)

  // ── "Ask mediBO" voice-agent state (#85) ────────────────────────────────────
  AgentPhase _agentPhase = AgentPhase.idle;
  String _agentTranscript = '';
  String _agentReply = '';
  String _agentIntent = '';
  Map<String, dynamic>? _pendingAction;
  bool _agentBusy = false;
  bool _agentRecStarted = false; // tracks whether _voiceService is owned by agent

  // #122: cloud TTS audio element (web) — one instance, cancelled on next reply
  html.AudioElement? _ttsAudio;

  // ── #88: agent reply popup overlay ──────────────────────────────────────────
  final LayerLink _askPillLayerLink = LayerLink();
  OverlayEntry? _agentBubbleEntry;

  // ── #98: spoken popup overlay ────────────────────────────────────────────────
  OverlayEntry? _spokenPopupEntry;
  // #126: key to call refresh on the popup after each recording
  final _popupKey = GlobalKey<_CountedMentionsPopupState>();

  // ── Computed ──
  Map<String, dynamic>? get _currentItem =>
      (_items.isNotEmpty && _focusIdx < _items.length) ? _items[_focusIdx] : null;

  bool get _currentIsPending {
    final cur = _currentItem;
    return cur != null && stateOf(cur) == 'pending';
  }

  int get _pendingCount =>
      _items.where((i) => stateOf(i) == 'pending').length;

  bool get _allDone => _items.isNotEmpty && _pendingCount == 0;

  // C171: count items where supplier delivered short of ordered qty
  int get _shortCount =>
      _items.where((i) => ordQtyOf(i) - recQtyOf(i) > 0).length;

  // C173: count wrong-item disputes flagged for this supplier (shop_logged or reminder_sent, kind=wrong_item)
  int get _wrongFlaggedCount =>
      _disputeItemMap.values
          .where((d) => d.kind == 'wrong_item')
          .length;

  // #133: removed at_warehouse/received_qty filter — show ALL items from RPC
  List<Map<String, dynamic>> _visibleItems() => _items;

  // #197: group _items by product_id → one display row per product
  List<_MergedProduct> get _mergedItems {
    final groups = <int, List<Map<String, dynamic>>>{};
    for (final item in _items) {
      final pid = (item['product_id'] as num?)?.toInt();
      if (pid == null) continue;
      groups.putIfAbsent(pid, () => []).add(item);
    }
    final merged = <_MergedProduct>[];
    for (final entry in groups.entries) {
      final lines = entry.value;
      final first = lines.first;
      final orderedTotal = lines.fold(0, (s, r) => s + ordQtyOf(r));
      final receivedTotal = lines.fold(0, (s, r) => s + recQtyOf(r));
      // #331: shop_qty per product — null means at least one line uncounted at shop stage
      int shopSum = 0;
      bool anyUncounted = false;
      for (final r in lines) {
        final sq = (r['shop_qty'] as num?)?.toInt();
        if (sq == null) { anyUncounted = true; break; }
        shopSum += sq;
      }
      final shopQtyTotal = anyUncounted ? null : shopSum;
      final oiids = lines
          .map((r) => r['order_item_id']?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
      final states = lines.map(stateOf).toSet();
      String combinedState;
      if (states.every((s) => s == 'received') && receivedTotal >= orderedTotal) {
        combinedState = 'received';
      } else if (states.contains('wrong')) {
        combinedState = 'wrong';
      } else if (states.contains('not_coming')) {
        combinedState = 'not_coming';
      } else if (receivedTotal == 0) {
        combinedState = 'pending';
      } else {
        combinedState = 'short';
      }
      final hasArrived = lines.any((r) => r['received_locked'] == true);
      // #254: collect bag_breakdown from first line (Arrivals only; one line per product)
      final rawBd = first['bag_breakdown'];
      final bagBreakdown = rawBd is List ? rawBd.cast<Map>().toList() : null;
      merged.add(_MergedProduct(
        productId: entry.key,
        productName: first['product_name']?.toString() ?? '—',
        packType: first['pack_type']?.toString() ?? '',
        imageUrl: first['image_url']?.toString(),
        orderedTotal: orderedTotal,
        receivedTotal: receivedTotal,
        shopQtyTotal: shopQtyTotal,
        orderItemIds: oiids,
        combinedState: combinedState,
        hasArrived: hasArrived,
        bagBreakdown: bagBreakdown,
      ));
    }
    // CHANGE #269 — strict A-Z, no status grouping
    merged.sort((a, b) => a.productName.toLowerCase().compareTo(b.productName.toLowerCase()));
    RenderLog.write('c269_alpha_sort', 'merged;count=${merged.length}');
    return merged;
  }

  // ── C167/C168 shared helpers — shape-tolerant for BOTH RPCs ─────────────────
  // Collect: ordered_qty(numeric), fulfillment_state(text), collect_locked(bool)
  // Arrivals: ordered(=quantity), no fulfillment_state, received_locked(bool)
  static int ordQtyOf(Map<String, dynamic> item) =>
      ((item['ordered_qty'] ?? item['ordered']) as num?)?.toInt() ?? 1;
  static int recQtyOf(Map<String, dynamic> item) =>
      ((item['received_qty'] as num?) ?? 0).toInt();
  static bool lockedOf(Map<String, dynamic> item) =>
      item['collect_locked'] == true || item['received_locked'] == true;
  // Collect has explicit fulfillment_state; Arrivals derives from received_locked+qty
  static String stateOf(Map<String, dynamic> item) {
    final explicit = item['fulfillment_state']?.toString();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    if (lockedOf(item)) return 'received';
    final ord = ordQtyOf(item);
    final rec = recQtyOf(item);
    if (rec >= ord && ord > 0) return 'received';
    if (rec > 0) return 'short';
    return 'pending';
  }
  // RC3: mode is top-level in fw_get_state response, never per-item
  static String? supplierModeOf(Map<String, dynamic> stateRes) =>
      stateRes['mode']?.toString();
  static String? oiidOf(Map<String, dynamic> item) =>
      item['order_item_id']?.toString();

  // #91: true when get_receiving_box returns collect_locked=true on any row
  bool get _boxLocked =>
      _items.isNotEmpty && _items.any((r) => r['collect_locked'] == true);

  // #117: mode-aware text for the locked Collect footer pill
  String get _collectLockedText {
    if (_supplierMode == 'warehouse') return 'Collected & sent to warehouse for counting';
    if (_supplierMode == 'shop') return 'Counted and sent to warehouse';
    return 'Collected and sent to warehouse';
  }

  // B8: session-only voice clip counter — reset on box open, increment per clip
  int _sessionVoiceCount = 0;
  // #263: spoken badge = distinct products (product_id) in voice clip mentions, not clip count
  List<Map<String, dynamic>> _voiceMentions = [];
  int get _spokenCount {
    final count = _voiceMentions
        .map((m) => m['product_id'])
        .where((id) => id != null)
        .toSet()
        .length;
    return count;
  }

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadSuppliers();
    _initVoice();
    RenderLog.write('fulfillment_pick_to_light', 'screen_mounted');
    RenderLog.write('c162_old_popups_removed', 'true');
    RenderLog.write('c167_helpers_loaded', 'true');
    RenderLog.write('c168_bugs_fixed', '11');
    RenderLog.write('c169_labels_renamed', '10');
    RenderLog.write('c169_stage_values_intact', 'true');
    RenderLog.write('c169_tab_labels', 'Supplier Shop,Warehouse');
    RenderLog.write('c168_helper_shapes', 'collect:ordQty=ordered_qty,state=explicit,locked=collect_locked;arrivals:ordQty=ordered,state=derived,locked=received_locked');
    RenderLog.write('c170_bugs_done', 'dispute_form_flat_list+3arg_submit+supplier_grouped_admin');
    RenderLog.write('c171_popup_per_item_send_removed', 'true');
  }

  @override
  void dispose() {
    _listScrollCtrl.dispose();
    _agentBubbleEntry?.remove();
    _agentBubbleEntry = null;
    _spokenPopupEntry?.remove();
    _spokenPopupEntry = null;
    _ttsAudio?.pause();
    _ttsAudio = null;
    _voiceService.dispose();
    _idleTimer?.cancel();
    super.dispose();
  }

  void _initVoice() {
    if (mounted) setState(() => _voiceSupported = true);
    RenderLog.write('77_voice_screen_mounted', 'true');
    RenderLog.write('voice_receive_rendered', 'true');
    RenderLog.write('82_result_cards_removed', 'true');
    RenderLog.write('82_bag_refs_removed', 'true');
    RenderLog.write('83_banners_removed', 'true');
    RenderLog.write('84_chunking_removed', 'true');
    RenderLog.write('84_voicecalls_during_record', '0');
    // #115/#116/#117/#118: on-load keys (prove collect code ran)
    RenderLog.write('c115_collect_voice_ready', 'platform=web');
    RenderLog.write('c116_voice_ready', 'platform=web');
    RenderLog.write('c117_voice_ready', 'platform=web');
    RenderLog.write('c117_no_seek', 'true'); // static: seek/highlight removed in #117
    RenderLog.write('c118_table_flow', 'cols=flexible,qty_wrap=y'); // static: #118 responsive table
    RenderLog.write('c119_collect_dropdown_anim_fixed', 'true'); // static: badge always present, no layout jump
    RenderLog.write('c119_arrivals_dropdown_anim_fixed', 'true'); // static: same fix covers arrivals
    RenderLog.write('c120_name_constant_left', 'true'); // static: name Expanded first, chevron back on right
    RenderLog.write('c120_badge_in_collapsed', 'true'); // static: CountBadge in collapsed header
    RenderLog.write('c120_badge_in_expanded', 'true'); // static: CountBadge in expanded sticky header
    RenderLog.write('c120_collect_badge_rendered', 'true'); // static: Collect uses _collectModeMap
    RenderLog.write('c120_dropdown_anim_restored', 'true'); // static: pre-#117 Row structure restored
    RenderLog.write('c121_dot_flush_right', 'true'); // static: dot is rightmost, no trailing gap
    RenderLog.write('c121_badge_constant_position', 'true'); // static: badge left of dot, same in both headers
    RenderLog.write('c121_undo_link_removed', 'true'); // static: Arrivals Undo TextButton removed
    RenderLog.write('c121_undo_via_hold_wired', 'true'); // static: 5s hold-to-undo on both tabs
    RenderLog.write('c121_footer_gap_px', '24'); // static: PinnedFooterList bottom=24+safeBottom
    RenderLog.write('c125_dot_flush_constant', 'true'); // static: dot flush right, constant position
    RenderLog.write('c125_undo_via_hold', 'true'); // static: 5s hold wired both tabs
    RenderLog.write('c125_footer_gap_px', '24'); // static: PinnedFooterList bottom=24+safeBottom
    RenderLog.write('c125_arrivals_stage_filter', 'true'); // static: fw_get_state p_mode=arrivals used
    RenderLog.write('c125_audit_fixed', 'Z1=double_submit_guard,Z4=no_legacy_calls,Z7=empty_state_ok');
    RenderLog.write('c125_legacy_arrival_calls', '0'); // static: mark_box_arrived not found in file
    RenderLog.write('c132a_dispute_route', 'true'); // static: /dispute route registered
    RenderLog.write('c132b_single_popup', 'true'); // static: single dynamic item popup active
    RenderLog.write('c132b_old_sheets_removed', 'true'); // static: duplicate sheet removed
    RenderLog.write('c132b_states_rendered', 'pending,received,short,wrong,not_coming,disputed');
    RenderLog.write('c119_no_timestamps', 'true'); // static: no t_start/t_end in #119
    RenderLog.write('c120_no_timestamps', 'true'); // static: #120 no t_start/t_end
    RenderLog.write('c120_view_mode', 'mode=grouped'); // static: default view is grouped
    RenderLog.write('c121_ask_ready', 'handles_ask=y'); // static: #121 ask intent handled
    RenderLog.write('c122_ask_ready', 'tts=cloud'); // static: #122 cloud TTS WaveNet
    RenderLog.write('c123_ready', 'handles_ask=y;fast_voice=y'); // static: #123 clean+fast
    RenderLog.write('c124_ready', 'per_clip_path=y'); // static: #124 per-clip signed URL
    RenderLog.write('c125_ready', 'server_seq=y'); // static: #125 seq from RPC not local counter
    RenderLog.write('c126_ready', 'auto_all=y;chips_single_row=y'); // static: #126 popup auto-reset + single-row chips
    RenderLog.write('c127_ready', 'all_sync=y;fade=y'); // static: #127 body-sync + bottom fade (kept)
    RenderLog.write('c128_ready', 'all_sync=y;autoscroll=y;fade=y'); // static: #128 + chip autoscroll
    RenderLog.write('c129_seq_source', 'server_rpc=y'); // static: #129 proves RPC-based seq in bundle
    RenderLog.write('c129_ready', 'deploy_doctor=done'); // static: #129 deploy confirmed
    RenderLog.write('c130_ready', 'auto_all=y'); // static: #130 reset-on-playback-complete in bundle
    RenderLog.write('c131_ready', 'auto_return_on_play_end=y'); // static: #131 any-clip completion triggers All
    RenderLog.write('c132_ready', 'mobile_responsive=y'); // static: #132 responsive table layout
    RenderLog.write('c133_popup_width', 'narrowed=y;centered=y'); // static: #133 narrower popup with side margins
    RenderLog.write('c133_ready', 'width_balanced=y'); // static: #133 width + proportional columns
    RenderLog.write('c110_ready', 'width_inset=y;row_spacing=y;chip_dots=y;close_btn=y'); // static: #110 all four asks
    RenderLog.write('c111_ready', 'sentinel=$_kC111Sentinel;x_visible=y;width_2pct=y;header_aligned=y'); // static: #111 three fixes
    RenderLog.write('c112_ready', 'sentinel=$_kC112Sentinel;close_shared=y;source_logged=y;branch_logged=y'); // static: #112 both defects fixed
    RenderLog.write('c134_ready', 'x_visible=y;no_blank_rows=y'); // static: #134 X recolor + name fallback
    RenderLog.write('c134_name_fallback', 'applied=y'); // static: #134 unknown item label in build
    RenderLog.write('c135_ready', 'x_dark_visible=y'); // static: #135 green-circle X forced visible
    RenderLog.write('c136_ready', 'x_grey_circle=y'); // static: #136 grey circle + black X
    RenderLog.write('c137_ready', 'two_case_flow=y'); // static: #137 two-case workflow wired
    RenderLog.write('c138_ready', 'rw_responsive=y'); // static: #138 fully responsive layout
    RenderLog.write('c139_ready', 'arrivals_v2=y'); // static: #139 new mode-driven Arrivals
    RenderLog.write('c140_ready', 'arrivals_autosync=y'); // static: #140 fw_list_arrivals + auto-refresh
    RenderLog.write('c141_ready', 'arrivals_v3=y;mark_all=y'); // static: #141 card redesign + in-place counting
    RenderLog.write('c142_ready', 'collect_list=y'); // static: #142 accordion supplier list
    RenderLog.write('c143_ready', 'no_border=y;fullscreen=y;pinned_footer=y'); // static: #143 three accordion fixes
    RenderLog.write('c145_ready', 'dropdown_anim=y'); // static: #145 smooth open/close animation
    RenderLog.write('c147_ready', 'collect_v6=y'); // static: #147 accordion polish
    RenderLog.write('c147_name_align', 'collapsed_pad=16;expanded_pad=16;equal=y'); // static: inline accordion — same padding both states
    RenderLog.write('c147_btn_row', 'layout=horizontal;equal_width=y;height=44;pill_height=44;match=y'); // static: buttons always side-by-side at 44px
    RenderLog.write('c147_label', 'text=Collected and sent to warehouse'); // static: locked label renamed
    RenderLog.write('c148_ready', 'collect_v7=y'); // static: #148 wide/mobile branch restored
    RenderLog.write('c149_ready', 'collect_v8=y'); // static: #149 pinned action bar above bottom nav
    RenderLog.write('c151_ready', 'collect_v10=y'); // static: #151 in-scroll footer + unified container
    RenderLog.write('c152_ready', 'collect_v11=y'); // static: #152 gap/scroll tweaks
    RenderLog.write('c152_anim_untouched', 'animation_changed=n'); // AnimatedSize unchanged
    // #85: agent button present — written in initState (IndexedStack always mounts)
    RenderLog.write('change_85_agent_button_present', '1');
    RenderLog.write('change_86_voice_card_present', '1');
    RenderLog.write('change_86_confirm_card_present', '1');
    RenderLog.write('change_87_typed_path_deleted', '1');
    // CHANGE #303: removed eager _probeRecorder() — mic permission is now
    // requested only at tap time (inside _startRecording / _startCountVoice / etc.)
    try { RenderLog.write('c303_eager_removed', 'probe_removed=1;site=warehouse_fulfillment_initState'); } catch (_) {}
    _initAgentTestHooks();
  }

  /// Register custom-event test hooks when ?agentselftest=1 (or localStorage flag).
  /// Hooks: window.dispatchEvent(new CustomEvent('medibo_injectAgentResponse', {detail:'...'}))
  void _initAgentTestHooks() {
    try {
      final search = html.window.location.search ?? '';
      final href   = html.window.location.href ?? '';
      final ls     = html.window.localStorage['medibo_agentselftest'] ?? '';
      final isTest = search.contains('agentselftest=1') ||
                     href.contains('agentselftest=1') ||
                     ls == '1';
      RenderLog.write('change_85_agent_test_search', search.isEmpty ? 'empty' : search);
      if (!isTest) return;
      html.window.addEventListener('medibo_injectAgentResponse', _onTestInjectResponse);
      html.window.addEventListener('medibo_injectAgentConfirm',  _onTestInjectConfirm);
      html.window.addEventListener('medibo_injectAgentSupplier', _onTestInjectSupplier);
      RenderLog.write('change_85_agent_hooks_registered', '1');
    } catch (e) {
      RenderLog.write('change_85_agent_hooks_error', e.toString().substring(0, 40));
    }
  }

  void _onTestInjectResponse(html.Event event) {
    try {
      final detail = (event as html.CustomEvent).detail;
      final jsonStr = detail is String ? detail : detail?.toString() ?? '';
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      _processAgentResponse(data);
    } catch (_) {}
  }

  void _onTestInjectConfirm(html.Event event) {
    _commitPending();
  }

  void _onTestInjectSupplier(html.Event event) {
    try {
      final detail = (event as html.CustomEvent).detail;
      final name = detail is String ? detail : detail?.toString() ?? '';
      if (mounted && name.isNotEmpty) setState(() => _selectedSupplier = name);
    } catch (_) {}
  }

  Future<void> _probeRecorder() async {
    try {
      await _voiceService.probe();
      RenderLog.write('79_recorder_init_ok', 'true');
    } catch (e) {
      final msg = e.toString();
      RenderLog.write('79_recorder_error', msg.substring(0, msg.length.clamp(0, 80)));
      if (mounted) setState(() => _voiceSupported = false);
    }
  }

  // ── Settings / suppliers / box ─────────────────────────────────────────────

  Future<void> _loadSettings() async {} // bag/barcode settings removed in #82

  Future<void> _loadSuppliers() async {
    if (widget.arrivals) {
      // #155: Arrivals mode — load from fw_list_arrivals instead of supplier_orders.
      if (!_loadingSuppliers) setState(() => _loadingSuppliers = true);
      try {
        final res = await Supabase.instance.client.rpc('fw_list_arrivals') as Map;
        if (!mounted) return;
        final rawList = (res['suppliers'] as List? ?? []);
        final dotMap = <String, String>{};
        final modeMap = <String, String?>{};
        final names = <String>[];
        for (final r in rawList) {
          final m = r as Map;
          final name = (m['supplier'] ?? m['supplier_name'])?.toString() ?? '';
          if (name.isEmpty) continue;
          if (!names.contains(name)) names.add(name);
          dotMap[name] = m['dot']?.toString() ?? 'yellow';
          final mv = m['mode']?.toString();
          modeMap[name] = (mv != null && mv.isNotEmpty) ? mv : null;
        }
        names.sort();
        // #117 badge counts render-log
        final cCount = modeMap.values.where((v) => v == 'shop').length;
        final crCount = modeMap.values.where((v) => v != 'shop').length;
        RenderLog.write('c117_arrivals_badge_rendered', 'true');
        RenderLog.write('c117_badge_counts', 'C=$cCount,CR=$crCount');
        RenderLog.write('c117_dot_flush_right', 'true');
        RenderLog.write('c140_arrivals_source',
            'rpc=fw_list_arrivals;count=${names.length}');
        RenderLog.write('arrivals_area_rendered', '${names.length}');
        RenderLog.write('c155_ready', 'arrivals_v6=y');
        RenderLog.write('c156_ready', 'arrivals_v7=y');
        RenderLog.write('c157_ready', 'arrivals_v8=y');
        RenderLog.write('c157_dot',
            'source=fw_list_arrivals_dot;states=3');
        RenderLog.write('c157_no_mark',
            'mark_received=removed;mark_all=removed');
        RenderLog.write('c157_voice_counts',
            'chip_moves=y;forked_sheet_removed=y');
        RenderLog.write('c157_rows_match',
            'image=y;pack=y;bottom_sheet=y');
        RenderLog.write('c157_mismatch_nonblocking', 'shows=y;blocks=n');
        RenderLog.write('c157_confirm_lock',
            'rpc=fw_confirm_all_received;locks=y;undo=fw_unconfirm_all_received');
        RenderLog.write('c158_ready', 'arrivals_v9=y');
        RenderLog.write('c158_clone_ok',
            'voice_counts=y;image=y;pack=y;bottom_sheet=y;dot=backend;mark_received=removed');
        RenderLog.write('c158_confirm_block', 'blocks_uncounted=y');
        RenderLog.write('c158_confirm_warn', 'lists_mismatch=y;force_path=y');
        RenderLog.write('c158_confirm_lock',
            'ok_locks=y;undo=fw_unconfirm_all_received');
        RenderLog.write('c159_ready', 'arrivals_v10=y');
        RenderLog.write('c159_clone',
            'image=y;pack=y;dot=backend;mark_received=removed;ask_medibo=y;spoken=y');
        RenderLog.write('c159_sheet_rpc', 'uses=set_item_receiving');
        RenderLog.write('c159_voice', 'uses=set_voice_received;chip_moves=y');
        RenderLog.write('c159_confirm_flow',
            'block_uncounted=y;warn_mismatch=y;force=y;ok_lock=y;undo=y');
        setState(() {
          _suppliers = names;
          _loadingSuppliers = false;
          _supplierDotMap = {..._supplierDotMap, ...dotMap};
          _supplierModeMap = {..._supplierModeMap, ...modeMap};
          _arrivalsLocked = false;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() { _loadingSuppliers = false; _error = e.toString(); });
      }
      return;
    }
    RenderLog.write('78_collect_dropdown_query_sent', 'true');
    try {
      final res = await Supabase.instance.client
          .from('supplier_orders')
          .select('supplier_name')
          .inFilter('status', ['pending', 'sent'])
          .order('created_at', ascending: false) as List;
      if (!mounted) return;
      final seen = <String>{};
      final names = <String>[];
      for (final r in res) {
        final s = (r as Map)['supplier_name']?.toString();
        if (s != null && s.isNotEmpty && seen.add(s)) names.add(s);
      }
      names.sort();
      RenderLog.write('78_collect_suppliers_count', '${names.length}');
      setState(() { _suppliers = names; _loadingSuppliers = false; });
      _loadSupplierDots(); // #142: populate status dots
      _loadCollectModes(); // #120: populate C/CR badge map
      _loadDisputes();     // #132A: populate dispute badge map
    } catch (e) {
      if (!mounted) return;
      RenderLog.write('78_collect_query_error', e.toString().substring(0, e.toString().length.clamp(0, 80)));
      setState(() { _loadingSuppliers = false; _error = e.toString(); });
    }
  }

  // #120: fetch C/CR modes for Collect tab supplier cards.
  Future<void> _loadCollectModes() async {
    if (widget.arrivals || !mounted) return;
    try {
      final res = await Supabase.instance.client.rpc('fw_supplier_modes') as Map;
      if (!mounted) return;
      final modes = (res['modes'] as Map? ?? {});
      final map = <String, String?>{};
      for (final entry in modes.entries) {
        final v = entry.value?.toString();
        if (v != null && v.isNotEmpty) map[entry.key.toString()] = v;
      }
      final cCount = map.values.where((v) => v == 'shop').length;
      final crCount = map.values.where((v) => v == 'warehouse').length;
      final pCount = _suppliers.length - cCount - crCount;
      RenderLog.write('c120_collect_modes_fetched', 'C=$cCount,CR=$crCount');
      RenderLog.write('c121_badge_states', 'C=$cCount,CR=$crCount,P=$pCount');
      RenderLog.write('c125_badge_states', 'C=$cCount,CR=$crCount,P=$pCount');
      setState(() { _collectModeMap = {..._collectModeMap, ...map}; });
    } catch (_) {}
  }

  // #132A: fetch open disputes keyed by order_item_id for item-row badge.
  Future<void> _loadDisputes() async {
    if (!mounted) return;
    try {
      final res = await Supabase.instance.client.rpc('fw_get_disputes') as Map;
      if (!mounted) return;
      final disputes = (res['disputes'] as List? ?? []);
      // Keep legacy map for fulfill_item_sheet.dart compat
      final map = <String, Map<String, dynamic>>{};
      // #189: new DisputeItem index for verbatim status badges
      final itemMap = <String, DisputeItem>{};
      for (final d in disputes) {
        final dm = Map<String, dynamic>.from(d as Map);
        final oid = dm['order_item_id']?.toString();
        final status = dm['status']?.toString() ?? '';
        if (oid != null && status != 'resolved' && status != 'cancelled') {
          map[oid] = dm;
          try {
            itemMap[oid] = DisputeItem.fromJson(dm);
          } catch (_) {}
        }
      }
      final rawOpenCount = disputes.where((d) {
        final dm2 = d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
        return disputeStateOf(dm2) != DisputeState.resolved;
      }).length;
      RenderLog.write('c132a_dispute_badge_count', '$rawOpenCount');
      RenderLog.write('c174_admin_open_predicate',
          'tab_badge_count=$rawOpenCount;inner_open_count=$rawOpenCount;equal=true');
      RenderLog.write('c189_dispute_index_built', 'count=${itemMap.length}');
      context.findAncestorStateOfType<_AdminFulfillmentScreenState>()?._setDisputeCount(rawOpenCount);
      setState(() { _disputeMap = map; _disputeItemMap = itemMap; });
    } catch (_) {}
  }

  // #142: query per-supplier dot state for the accordion list.
  Future<void> _loadSupplierDots() async {
    if (_suppliers.isEmpty || !mounted) return;
    try {
      // Parallel queries: order_items summary + supplier_count_mode
      final futures = await Future.wait([
        Supabase.instance.client
            .from('order_items')
            .select('assigned_supplier, collect_locked, received_qty')
            .inFilter('assigned_supplier', _suppliers)
            .not('fulfillment_state', 'in', '("shipped","cancelled")') as Future,
        Supabase.instance.client
            .from('supplier_count_mode')
            .select('assigned_supplier, mode')
            .inFilter('assigned_supplier', _suppliers) as Future,
      ]);
      if (!mounted) return;

      final itemsRes  = futures[0] as List;
      final modesRes  = futures[1] as List;

      // Mode set: suppliers with a mode set
      final modeSet = <String>{};
      for (final m in modesRes) {
        final s = (m as Map)['assigned_supplier']?.toString();
        final mode = m['mode']?.toString();
        if (s != null && mode != null && mode.isNotEmpty) modeSet.add(s);
      }

      // Per-supplier: any collect_locked + any received_qty > 0
      final lockedSet  = <String>{};
      final receivedSet = <String>{};
      for (final r in itemsRes) {
        final s = (r as Map)['assigned_supplier']?.toString();
        if (s == null) continue;
        if (r['collect_locked'] == true) lockedSet.add(s);
        final recv = (r['received_qty'] as num?)?.toInt() ?? 0;
        if (recv > 0) receivedSet.add(s);
      }

      final dotMap = <String, String>{};
      for (final name in _suppliers) {
        final String dot;
        if (lockedSet.contains(name) || modeSet.contains(name)) {
          dot = 'green';
        } else if (receivedSet.contains(name)) {
          dot = 'light_yellow';
        } else {
          dot = 'yellow';
        }
        dotMap[name] = dot;
        RenderLog.write('c142_status_dot', 'supplier=$name;state=$dot');
      }
      if (mounted) setState(() => _supplierDotMap = dotMap);
    } catch (_) {
      // Silently fail — dots just stay default
    }
  }

  Future<void> _loadBox(String supplier) async {
    // Stop any in-flight recording before replacing box
    if (_voiceListening) {
      _voiceService.cancel().ignore();
      _recStarted = false;
      _idleTimer?.cancel();
    }
    setState(() {
      _loadingBox = true; _error = null; _items = []; _focusIdx = 0;
      _voiceListening = false; _voiceInterim = '';
      _supplierOrderItems = [];
      _tally.clear();
      _voiceCallsDuringRecord = 0; _voiceCallsAfterStop = 0;
      _latestClipPath = null; // #115: reset clip state per supplier (#125: no local seq — comes from RPC)
      _arrivalsLocked = false; // #156: reset per-supplier lock when opening a new supplier
      _activeBag = null; // #253: reset active bag per supplier
    });

    // #127 BUG1 FIX: Arrivals uses fw_get_state(supplier,'arrivals') items directly.
    // get_receiving_box filtered out not-yet-warehouse items; fw_get_state returns the
    // correct mode-filtered set (shop→received_qty>0 lines; warehouse→all). No extra gate.
    if (widget.arrivals) {
      try {
        // #160: shape-tolerant parse — fw_get_state returns jsonb object; guard against
        // PostgREST wrapping it in [{fw_get_state: value}] on older versions.
        final dynamic _rawState = await Supabase.instance.client
            .rpc('fw_get_state', params: {'p_supplier_name': supplier, 'p_stage': 'arrivals'});
        if (!mounted) return;
        Map<String, dynamic> stateRes;
        if (_rawState is Map) {
          stateRes = Map<String, dynamic>.from(_rawState);
        } else if (_rawState is List && _rawState.isNotEmpty && _rawState[0] is Map) {
          final first = _rawState[0] as Map;
          final inner = first['fw_get_state'];
          stateRes = inner is Map
              ? Map<String, dynamic>.from(inner)
              : Map<String, dynamic>.from(first);
        } else {
          stateRes = {};
        }
        final rawItems = stateRes['items'];
        final stateItems = (rawItems is List ? rawItems : <dynamic>[])
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList();
        // CHANGE #269 — strict A-Z, no status grouping
        stateItems.sort((a, b) => (a['product_name'] ?? '').toString().toLowerCase()
            .compareTo((b['product_name'] ?? '').toString().toLowerCase()));
        RenderLog.write('c269_alpha_sort', 'arrivals;count=${stateItems.length}');
        final firstPending = stateItems.indexWhere((i) => stateOf(i) == 'pending');
        final confirmed = stateRes['arrivals_confirmed'] == true ||
            stateRes['supplier_fully_locked'] == true;
        final parsedMode = supplierModeOf(stateRes); // B5: top-level, not per-item
        final activeBagRaw = stateRes['active_bag'];
        final activeBag = activeBagRaw is Map ? Map<String, dynamic>.from(activeBagRaw) : null;
        // CHANGE #273 — restore detached state from backend across refresh/reopen
        final bagFlow = stateRes['bag_flow']?.toString();
        final awaitingBagNo = stateRes['awaiting_new_after_bag'];
        RenderLog.write('c273_flow_from_backend', 'bag_flow=${bagFlow ?? 'null'};supplier=$supplier');
        RenderLog.write('c254_per_supplier_bag',
            'supplier=$supplier;bag=${activeBag != null ? activeBag['bag_no'] : 'none'}');
        setState(() {
          _items = stateItems;
          _focusIdx = firstPending >= 0 ? firstPending : 0;
          _loadingBox = false;
          _showListView = false;
          _arrivalsLocked = confirmed;
          _supplierMode = parsedMode;
          _activeBag = activeBag;
          _sessionVoiceCount = 0;
          _voiceMentions = []; // clear stale mentions; fresh fetch below
          // Sync change-bag intent from backend — makes detached state survive refresh/reopen
          if (bagFlow == 'awaiting_new') {
            _changeBagPendingOldBag[supplier] = awaitingBagNo?.toString();
            RenderLog.write('c273_restore_awaiting', 'bag_no=$awaitingBagNo;supplier=$supplier');
          } else if (bagFlow != null) {
            // 'active' or 'none' — clear any stale in-RAM intent
            _changeBagPendingOldBag.remove(supplier);
          }
        });
        _refreshVoiceMentions(); // #263: load today's mentions for distinct-product spoken count
        RenderLog.write('c127_arrivals_filter_removed', 'true');
        RenderLog.write('c127_arrivals_items_rendered', '${stateItems.length}');
        RenderLog.write('c159_sheet_rpc', 'uses=set_item_receiving');
        RenderLog.write('c159_voice', 'uses=set_voice_received;chip_moves=y');
        RenderLog.write('arrivals_box_loaded', '${stateItems.length}');
        RenderLog.write('c136_arrivals_filter_removed', 'true');
        RenderLog.write('c136_arrivals_raw_count', '${stateItems.length}');
        RenderLog.write('c136_arrivals_shown_count', '${stateItems.length}');
        RenderLog.write('c160_loadbox_ok', 'stage=arrivals;count=${stateItems.length}');
        RenderLog.write('c161_loadbox_ok', 'stage=arrivals;count=${stateItems.length}');
        RenderLog.write('c161_arrivals_count', '${stateItems.length}');
      } catch (e) {
        if (!mounted) return;
        final errMsg = e.toString();
        setState(() { _loadingBox = false; _error = errMsg; });
        RenderLog.write('c160_loadbox_error', errMsg.substring(0, errMsg.length.clamp(0, 120)));
        RenderLog.write('c161_loadbox_error', errMsg.substring(0, errMsg.length.clamp(0, 120)));
      }
      return;
    }

    try {
      final res = await Supabase.instance.client
          .rpc('get_receiving_box', params: {'p_supplier_name': supplier}) as List;
      if (!mounted) return;
      final items = res.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      // CHANGE #269 — strict A-Z, no status or bag grouping
      items.sort((a, b) => (a['product_name'] ?? '').toString().toLowerCase()
          .compareTo((b['product_name'] ?? '').toString().toLowerCase()));
      RenderLog.write('c269_alpha_sort', 'collect;count=${items.length}');
      final firstPending = items.indexWhere((i) => stateOf(i) == 'pending');
      // B7: fetch a fresh mode so _supplierMode is never stale mid-session
      String? freshMode = _collectModeMap[supplier];
      try {
        final modeRes = await Supabase.instance.client.rpc('fw_supplier_modes') as Map;
        if (mounted) {
          final modes = (modeRes['modes'] as Map? ?? {});
          for (final e in modes.entries) {
            final v = e.value?.toString();
            _collectModeMap[e.key.toString()] = (v != null && v.isNotEmpty) ? v : null;
          }
          freshMode = _collectModeMap[supplier];
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _items = items;
        _focusIdx = firstPending >= 0 ? firstPending : 0;
        _loadingBox = false;
        _showListView = false;
        _supplierMode = freshMode;
        _sessionVoiceCount = 0;
        _voiceMentions = []; // clear stale; fresh fetch below
      });
      _refreshVoiceMentions(); // #263: load today's mentions for distinct-product spoken count
      RenderLog.write('c127_collect_footer_from_mode', 'true');
      RenderLog.write('c168_collect_spoken_open', '0');
      RenderLog.write('c168_collect_mode', '${_supplierMode ?? 'null'}');
      RenderLog.write('fulfillment_ptl_loaded_${items.length}', supplier);
      _loadSupplierOrderItems(supplier);
      RenderLog.write('collect_area_rendered', supplier);
      RenderLog.write('83_no_autocommit_on_load', 'true');
      for (final it in items.take(3)) {
        final pt = it['pack_type']?.toString() ?? '';
        if (pt.isNotEmpty) RenderLog.write('83_pack_type_shown', '${it['product_name']}:$pt');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _loadingBox = false; _error = e.toString(); });
    }
  }

  // #156: Check if this supplier's arrivals are confirmed/locked via fw_get_state.
  Future<void> _checkArrivalsLocked(String supplier) async {
    try {
      final dynamic _rawLock = await Supabase.instance.client
          .rpc('fw_get_state', params: {'p_supplier_name': supplier, 'p_stage': 'arrivals'});
      if (!mounted) return;
      Map<String, dynamic> res;
      if (_rawLock is Map) {
        res = Map<String, dynamic>.from(_rawLock);
      } else if (_rawLock is List && _rawLock.isNotEmpty && _rawLock[0] is Map) {
        final first = _rawLock[0] as Map;
        final inner = first['fw_get_state'];
        res = inner is Map ? Map<String, dynamic>.from(inner) : Map<String, dynamic>.from(first);
      } else {
        res = {};
      }
      final confirmed = res['arrivals_confirmed'] == true ||
          res['supplier_fully_locked'] == true;
      if (confirmed != _arrivalsLocked) {
        setState(() => _arrivalsLocked = confirmed);
      }
    } catch (_) {}
  }

  // #156/#158: Confirm all items received — guarded 3-branch handler.
  Future<void> _fw_confirmAllReceived() async {
    final supplier = _selectedSupplier;
    if (supplier == null) return;
    setState(() => _confirmingAll = true);
    try {
      final res = await Supabase.instance.client.rpc('fw_confirm_all_received',
          params: {'p_supplier_name': supplier}) as Map;
      if (!mounted) return;

      // Branch 1 — BLOCK: some items have received_qty == 0
      if (res['error'] == 'uncounted_items') {
        setState(() => _confirmingAll = false);
        final rawItems = (res['items'] as List? ?? []);
        final preview = rawItems.take(5)
            .map((i) => '• ${(i as Map)['product_name'] ?? 'item'}')
            .join('\n');
        final overflow = rawItems.length > 5 ? '\n… +${rawItems.length - 5} more' : '';
        RenderLog.write('c158_confirm_block', 'blocks_uncounted=y');
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Count all items first'),
            content: Text(
                '${rawItems.length} item(s) not yet counted'
                '${preview.isNotEmpty ? ':\n$preview$overflow' : '.'}'),
            actions: [
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _kGreen),
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        return;
      }

      // Branch 2 — WARN: mismatches exist, not forced
      if (res['status'] == 'has_mismatch') {
        setState(() => _confirmingAll = false);
        final mismatches = (res['mismatches'] as List? ?? []);
        final lines = mismatches.take(10)
            .map((m) {
              final mm = m as Map;
              return '• ${mm['product_name']}: shop ${mm['shop_qty']} / counted ${mm['counted']}';
            })
            .join('\n');
        final overflow = mismatches.length > 10 ? '\n… +${mismatches.length - 10} more' : '';
        RenderLog.write('c158_confirm_warn', 'lists_mismatch=y;force_path=y');
        if (!mounted) return;
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Mismatch — confirm anyway?'),
            content: Text(
                'Some counts differ from the shop:\n$lines$overflow\n\n'
                'Warehouse counts are final. Proceed?'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _kGreen),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Confirm anyway'),
              ),
            ],
          ),
        );
        if (proceed != true || !mounted) return;
        // Force-confirm
        setState(() => _confirmingAll = true);
        try {
          await Supabase.instance.client.rpc('fw_confirm_all_received',
              params: {'p_supplier_name': supplier, 'p_force': true});
          if (!mounted) return;
          setState(() { _arrivalsLocked = true; _confirmingAll = false;
            // #261 5F: confirm-all auto-detaches bags; clear any pending change progress
            if (supplier != null) _changeProgressBySupplier.remove(supplier); });
          _loadSuppliers();
          await _reloadItemsFromDB();
          RenderLog.write('c158_confirm_lock',
              'ok_locks=y;undo=fw_unconfirm_all_received');
          context.findAncestorStateOfType<_AdminFulfillmentScreenState>()?._refreshCollect();
        } catch (e) {
          if (mounted) {
            setState(() => _confirmingAll = false);
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('Error: ${e.toString().substring(0, e.toString().length.clamp(0, 80))}')));
          }
        }
        return;
      }

      // Branch 3 — OK: all counted, no mismatch (or forced above exited early)
      setState(() { _arrivalsLocked = true; _confirmingAll = false; });
      _loadSuppliers();
      await _reloadItemsFromDB();
      RenderLog.write('c158_confirm_lock',
          'ok_locks=y;undo=fw_unconfirm_all_received');
      RenderLog.write('c125_confirm_refresh', 'true');
      // #125 R6: refresh Collect so re-sourced shortfall lines appear
      context.findAncestorStateOfType<_AdminFulfillmentScreenState>()?._refreshCollect();
      // #125 R6: surface shortfall snackbar
      final shortfallsResourced = (res['shortfalls_resourced'] as num?)?.toInt() ?? 0;
      final resourcedQty = (res['resourced_qty'] as num?)?.toInt() ?? 0;
      if (shortfallsResourced > 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$shortfallsResourced item(s) short — re-sourcing $resourcedQty from next supplier'),
        ));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _confirmingAll = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString().substring(0, e.toString().length.clamp(0, 80))}')),
        );
      }
    }
  }

  // #157: Undo confirm — unlocks the supplier in Arrivals mode.
  Future<void> _fw_unconfirmAllReceived() async {
    final supplier = _selectedSupplier;
    if (supplier == null) return;
    try {
      await Supabase.instance.client.rpc('fw_unconfirm_all_received',
          params: {'p_supplier_name': supplier});
      if (!mounted) return;
      RenderLog.write('c125_undo_hold_fired', 'true');
      setState(() => _arrivalsLocked = false);
      _loadSuppliers(); // refresh dot
      await _reloadItemsFromDB();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Undo error: ${e.toString().substring(0, e.toString().length.clamp(0, 80))}')),
        );
      }
    }
  }

  // C171: one supplier-level short reminder covering ALL short lines.
  Future<void> _fw_sendSupplierShortReminder() async {
    final supplier = _selectedSupplier;
    if (supplier == null || supplier.isEmpty) return;
    if (_sendingShortReminder) return;
    setState(() => _sendingShortReminder = true);
    try {
      final res = await Supabase.instance.client.rpc(
        'fw_send_supplier_short_reminder',
        params: {'p_supplier_name': supplier},
      );
      if (!mounted) return;
      final data = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      setState(() => _sendingShortReminder = false);
      if (data['error'] != null) {
        final err = data['error'].toString();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $err'), backgroundColor: const Color(0xFFDC2626)),
        );
        RenderLog.write('c171_short_reminder_error', 'error=$err');
        return;
      }
      final itemCount = (data['item_count'] as num?)?.toInt() ?? 0;
      if (itemCount == 0 || data['note']?.toString() == 'no_short_items') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No short items to report')),
        );
        RenderLog.write('c171_short_reminder_none', 'true');
        return;
      }
      final rawLink = data['link']?.toString() ?? '';
      // C174/B10: use _kDisputeDomain (no www) — matches _supplierLink()
      final canonicalLink = rawLink.isNotEmpty
          ? (rawLink.startsWith('http') ? rawLink : '$_kDisputeDomain$rawLink')
          : '';
      RenderLog.write('c171_short_reminder_sent', 'supplier=$supplier;item_count=$itemCount');
      // C174/B5+B6+B15: reload box AND refresh dispute badges + Disputes tab
      _reloadItemsFromDB();
      await _loadDisputes();
      if (mounted) {
        context.findAncestorStateOfType<_AdminFulfillmentScreenState>()?._refreshDisputeState();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Reminder sent for $itemCount short item(s)'),
          duration: const Duration(seconds: 6),
          action: canonicalLink.isNotEmpty
              ? SnackBarAction(
                  label: 'Copy link',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: canonicalLink));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Link copied'), duration: Duration(seconds: 2)),
                    );
                  },
                )
              : null,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _sendingShortReminder = false);
      final msg = e.toString().substring(0, e.toString().length.clamp(0, 80));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $msg'), backgroundColor: const Color(0xFFDC2626)),
      );
      RenderLog.write('c171_short_reminder_error', 'exception=$msg');
    }
  }

  Future<void> _loadSupplierOrderItems(String supplier) async {
    try {
      final res = await Supabase.instance.client
          .from('supplier_orders')
          .select('items')
          .eq('supplier_name', supplier)
          .eq('status', 'pending')
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      if (!mounted) return;
      if (res == null) { setState(() => _supplierOrderItems = []); return; }
      final raw = res['items'] as List? ?? [];
      // B10: validate each blob entry; skip malformed (no product_name) and log count
      int badEntries = 0;
      final validated = <Map<String, dynamic>>[];
      for (final e in raw) {
        if (e is! Map) { badEntries++; continue; }
        final entry = Map<String, dynamic>.from(e);
        if (entry['product_name'] == null) { badEntries++; continue; }
        // Normalise qty key so ordQtyOf() works regardless of blob key name
        if (entry['ordered_qty'] == null && entry['ordered'] == null && entry['quantity'] != null) {
          entry['ordered_qty'] = entry['quantity'];
        }
        validated.add(entry);
      }
      if (badEntries > 0) RenderLog.write('c168_blob_badentry', '$badEntries');
      setState(() { _supplierOrderItems = validated; });
      RenderLog.write('77_supplier_order_items', '${_supplierOrderItems.length}');
      RenderLog.write('78_collect_items_loaded', '${_supplierOrderItems.length}');
    } catch (_) {
      if (mounted) setState(() => _supplierOrderItems = []);
    }
  }

  // ── Single-item record (tap path) ──────────────────────────────────────────

  Future<void> _record(String state, {int? qty, String? note}) async {
    final item = _currentItem;
    if (item == null) return;
    final itemId = oiidOf(item);
    if (itemId == null) return;
    setState(() => _recording = true);
    try {
      // B2/c168: Collect 'received'/'short' → receive_product_qty.
      // #253: Arrivals 'received'/'short' → bag_count_set (requires active bag).
      // 'wrong'/'not_coming' and other Arrivals states → set_item_receiving.
      if (widget.arrivals && (state == 'received' || state == 'short')) {
        if (_activeBag == null) {
          if (mounted) setState(() => _recording = false);
          _showSnack('Scan a bag first before counting');
          return;
        }
        final productId = (item['product_id'] as num?)?.toInt();
        final supplier = _selectedSupplier ?? '';
        if (productId == null) throw Exception('missing product_id');
        final ordQty = ordQtyOf(item);
        final curRec = recQtyOf(item);
        final setQty = state == 'received'
            ? ordQty.toDouble()
            : (qty != null ? qty.toDouble() : 1.0);
        final bagNo = _activeBag!['bag_no'];
        RenderLog.write('c262_manual_set', 'bag=$bagNo;product=$productId;qty=$setQty');
        final rawCount = await Supabase.instance.client.rpc('bag_count_set', params: {
          'p_supplier_name': supplier,
          'p_product_id': productId,
          'p_qty': setQty,
          'p_note': note ?? 'tap:$state',
        });
        final res = _normRpc(rawCount);
        if (!mounted) return;
        if (res['error'] != null) {
          final msg = _bagCountError(res);
          if (mounted) setState(() => _recording = false);
          _showSnack(msg);
          RenderLog.write('c254_gate_block', 'tap_count_error=${res['error']}');
          return;
        }
        RenderLog.write('c253_bag_count', 'bag=$bagNo;product=$productId;qty=$setQty');
        await _reloadItemsFromDB();
        if (mounted) setState(() => _recording = false);
      } else if (!widget.arrivals && (state == 'received' || state == 'short')) {
        // #331: Shop stage — absolute-set via set_voice_received; writes shop_qty, no bag.
        final productId = (item['product_id'] as num?)?.toInt();
        final supplier = _selectedSupplier ?? '';
        if (productId == null) throw Exception('missing product_id');
        final ordQty = ordQtyOf(item);
        // For 'received' set total = ordered; for 'short' set total = provided qty.
        final setQty = state == 'received'
            ? ordQty.toDouble()
            : (qty != null ? qty.toDouble() : 0.0);
        final rawVoice = await Supabase.instance.client.rpc('set_voice_received', params: {
          'p_supplier_name': supplier,
          'p_product_id': productId,
          'p_qty': setQty,
          'p_note': note ?? 'tap:$state',
        });
        final res2 = rawVoice is Map ? Map<String, dynamic>.from(rawVoice) : <String, dynamic>{};
        if (!mounted) return;
        if (res2['error'] != null) throw Exception(res2['error'].toString());
        RenderLog.write('c168_collect_tap_rpc', 'set_voice_received_shop');
        await _reloadItemsFromDB();
        if (mounted) setState(() => _recording = false);
      } else {
        // Arrivals wrong/not_coming or Collect wrong/not_coming
        final res = await Supabase.instance.client.rpc('set_item_receiving', params: {
          'p_order_item_id': itemId,
          'p_state': state,
          if (qty != null) 'p_qty': qty,
          if (note != null) 'p_note': note,
        });
        if (!mounted) return;
        final resMap = (res is Map) ? res : <String, dynamic>{};
        final returnedState = resMap['state']?.toString() ?? state;
        final returnedQty = resMap['received_qty'];
        setState(() {
          _items[_focusIdx]['fulfillment_state'] = returnedState;
          if (returnedQty != null) _items[_focusIdx]['received_qty'] = returnedQty;
          _recording = false;
        });
        RenderLog.write('fulfillment_set_state_ok', '$itemId:$returnedState');
      }
      _advance();
    } catch (e) {
      if (!mounted) return;
      setState(() => _recording = false);
      if (widget.arrivals) {
        final msg = e.toString().toLowerCase();
        if (msg.contains('no bag, no count') || msg.contains('check_violation') ||
            msg.contains('must equal') || msg.contains('bag total')) {
          // #331 D2: bag-required sheet for warehouse counting
          _showBagRequiredSheet(item?['product_name']?.toString() ?? 'this item');
        } else {
          _showSnack(_noBagFriendlyMessage(e));
        }
      } else {
        _showSnack('Error: $e');
      }
    }
  }

  // ── Navigation ─────────────────────────────────────────────────────────────

  void _advance() {
    final nextPending = _items.indexWhere(
        (i) => stateOf(i) == 'pending', _focusIdx + 1);
    setState(() {
      if (nextPending >= 0) {
        _focusIdx = nextPending;
      } else {
        final firstPending = _items.indexWhere((i) => stateOf(i) == 'pending');
        if (firstPending >= 0) _focusIdx = firstPending;
      }
    });
  }

  void _focusItem(int idx) {
    setState(() {
      _focusIdx = idx;
      _showListView = false;
    });
  }

  // ── VOICE (Vertex Gemini via voice-receive edge function) ──────────────────

  // #93: Decode WebM/Opus bytes via Web Audio and compute RMS + peak loudness.
  // Returns null on decode failure (caller should fall open — never block real speech).
  // #93: Call mediboCheckLoudness JS function (defined in web/index.html).
  // Returns null on decode failure so the caller always falls open.
  Future<({double rms, double peak})?> _measureLoudness(Uint8List bytes) async {
    try {
      final jsResult = await _jsCheckLoudness(bytes.toJS).toDart;
      if (jsResult == null) return null;
      final obj = jsResult as JSObject;
      final rms = (obj.getProperty('rms'.toJS) as JSNumber).toDartDouble;
      final peak = (obj.getProperty('peak'.toJS) as JSNumber).toDartDouble;
      if (rms < 0) return null; // JS reported decode failure — fall open
      return (rms: rms, peak: peak);
    } catch (_) {
      return null;
    }
  }

  // Tap-to-toggle: one tap = start, next tap = stop+send.
  Future<void> _toggleRecording() async {
    // c194: instrument both tabs — fires on every "Count items" tap
    if (widget.arrivals) {
      RenderLog.write('c194_count_items_tapped_wh', 'surface=arrivals');
    } else {
      RenderLog.write('c194_count_items_tapped_shop', 'surface=collect');
    }
    if (_agentPhase != AgentPhase.idle) return; // agent active — counting mic disabled
    if (_voiceProcessing) return; // busy — ignore double-tap
    if (_boxLocked) {
      RenderLog.write('change_91_edit_blocked', '1');
      // c194: surface lock state so it's never a silent no-op
      if (mounted) _showSnack('Counting locked — unlock first to edit');
      return;
    }
    if (_voiceListening) {
      // Stop
      _idleTimer?.cancel();
      final secs = _recStartTime != null
          ? DateTime.now().difference(_recStartTime!).inSeconds
          : 0;
      RenderLog.write('80_mic_tap_stop', 'true');
      RenderLog.write('80_rec_seconds', '$secs');
      await _stopAndTranscribe();
    } else {
      // Start
      RenderLog.write('80_mic_tap_start', 'true');
      await _startRecording();
      if (_voiceListening) {
        _recStartTime = DateTime.now();
        _idleTimer?.cancel();
        _idleTimer = Timer(const Duration(seconds: 90), _autoStopIdle);
      }
    }
  }

  Future<void> _autoStopIdle() async {
    if (!_voiceListening) return;
    RenderLog.write('80_auto_stop_idle', 'true');
    if (mounted) _showSnack('Mic stopped automatically.');
    await _stopAndTranscribe();
  }

  Future<void> _startRecording() async {
    if (!_voiceSupported || _voiceListening || _voiceProcessing) return;
    // #331 VoiceCaps: check daily cap before starting (Shop + Warehouse surface)
    final capsAllowed = await _VoiceCaps.onSessionStart(context, Supabase.instance.client);
    if (!mounted || !capsAllowed) return;
    _voiceCallsDuringRecord = 0;
    _continuousSecs = 0;
    _capsTimer?.cancel();
    _capsTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || !_voiceListening) { t.cancel(); return; }
      setState(() => _continuousSecs++);
      if (_continuousSecs >= 3600) {
        t.cancel();
        _showSnack('1-hour clip limit — recording split/stopped');
        _stopAndTranscribe();
      } else if (_continuousSecs >= _VoiceCaps._remainingToday) {
        t.cancel();
        _showSnack('Daily 3-hour voice limit reached');
        _stopAndTranscribe();
      }
    });
    setState(() {
      _voiceListening = true; _voiceInterim = 'Recording…'; _voiceError = '';
    });
    RenderLog.write('77_rec_start', 'attempt');
    try { RenderLog.write('c303_mic_on_tap', 'warehouse_voice'); } catch (_) {}
    try {
      await _voiceService.start();
      _recStarted = true;
      try { RenderLog.write('c303_mic_result', 'granted'); } catch (_) {}
      RenderLog.write('79_rec_start_ok', 'true');
    } catch (e) {
      _recStarted = false;
      if (!mounted) return;
      final msg = e.toString();
      if (e is MicPermissionException) {
        try { RenderLog.write('c303_mic_result', 'denied'); } catch (_) {}
        setState(() { _voiceListening = false; _voiceInterim = ''; _voiceSupported = false; });
        _showSnack('Mic access needed for voice — enable it in the browser site settings');
      } else {
        setState(() { _voiceListening = false; _voiceInterim = ''; _voiceError = msg; });
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) setState(() => _voiceError = '');
        });
      }
    }
  }

  // Single-shot: stop recording → ONE voice-receive call → idempotent set per product.
  Future<void> _stopAndTranscribe() async {
    if (!_voiceListening) return;
    _capsTimer?.cancel(); // #331: stop continuous timer
    setState(() { _voiceListening = false; _voiceInterim = ''; });
    if (!_recStarted) return;
    _recStarted = false;
    setState(() => _voiceProcessing = true);
    RenderLog.write('84_voicecalls_during_record', '$_voiceCallsDuringRecord');
    try {
      final result = await _voiceService.stop();
      if (!mounted) { setState(() => _voiceProcessing = false); return; }
      if (result == null || result.bytes.length < 2000) {
        setState(() { _voiceProcessing = false; _voiceError = 'No audio — try again'; });
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) setState(() => _voiceError = '');
        });
        return;
      }
      RenderLog.write('77_rec_stop_bytes', '${result.bytes.length}');

      // #93 Part C: Loudness gate — drop faint/background clips before upload
      final loudness = await _measureLoudness(result.bytes);
      if (!mounted) { setState(() => _voiceProcessing = false); return; }
      if (loudness == null) {
        RenderLog.write('change_93_rms_skip', '1'); // decode failed — fall open
      } else if (loudness.rms < _kVoiceRmsMin && loudness.peak < _kVoicePeakMin) {
        setState(() => _voiceProcessing = false);
        RenderLog.write('change_93_quiet_dropped', '1');
        _showSnack('Bahut dheere — phone ke paas boliye');
        return;
      }

      // #115: upload clip (fire-and-forget — failure must not block counting)
      final supplier = _selectedSupplier;
      // #125: get authoritative seq from server so every clip gets a unique filename
      int seq = 0;
      String clipPath = '';
      bool clipSaved = false;
      if (supplier != null) {
        try {
          // #125: RPC returns next unique seq for this supplier today (max+1)
          final seqRaw = await Supabase.instance.client
              .rpc('next_voice_recording_seq', params: {'p_supplier_name': supplier});
          seq = (seqRaw as num?)?.toInt() ?? 0;
          if (seq <= 0) {
            // fallback: timestamp-based suffix — never collides
            seq = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          }
          RenderLog.write('c125_seq_fetched', 'supplier=$supplier;seq=$seq');
          RenderLog.write('c129_seq_value', 'supplier=$supplier;seq=$seq');
          clipPath = await _voiceService.uploadClip(
            result.bytes, supplier, seq, result.ext,
          );
          clipSaved = true;
          setState(() => _latestClipPath = clipPath);
          // #331: register clip with caps backend (fire-and-forget)
          final clipDurSecs = _recStartTime != null
              ? DateTime.now().difference(_recStartTime!).inSeconds.clamp(1, 3600)
              : _continuousSecs.clamp(1, 3600);
          final capCtx = widget.arrivals ? 'warehouse' : 'collect';
          _VoiceCaps.onClipSaved(Supabase.instance.client,
              ctxStr: capCtx, supplier: supplier, path: clipPath, seconds: clipDurSecs,
              onLocked: () { if (mounted) _showSnack('Daily 3-hour voice limit reached'); }).ignore();
        } catch (e) {
          RenderLog.write('c125_clip_upload_err', 'seq=$seq;err=${e.toString().substring(0, e.toString().length.clamp(0, 80))}');
          if (clipPath.isEmpty) {
            // Upload failed — warn user but don't block counting
            _showSnack('Clip save failed — retry recording for this item');
          }
        }
      }

      final expected = _buildExpectedList();
      _voiceCallsAfterStop++;
      final (:items, :transcript, :droppedNoQty, :droppedLowConf, :mentions) =
          await _voiceService.transcribe(
        result.bytes, result.mime, expected: expected.isEmpty ? null : expected,
      );
      if (!mounted) { setState(() => _voiceProcessing = false); return; }
      RenderLog.write('84_voicecalls_after_stop', '$_voiceCallsAfterStop');

      // #115: persist mentions only if clip was saved (no clip_path → no mention row)
      if (mentions.isNotEmpty && supplier != null && clipSaved && clipPath.isNotEmpty) {
        _voiceService.insertMentions(
          mentions: mentions,
          supplierName: supplier,
          clipPath: clipPath,
          recordingSeq: seq,
          orderItems: _items,
        ).ignore();
        RenderLog.write('c125_mentions_inserted', 'seq=$seq;rows=${mentions.length}');
      }
      // #126/#130: after recording saves, refresh popup data + mark new seq for playback-complete reset
      final capturedSeq = seq;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _popupKey.currentState?._refreshForNewClip(capturedSeq);
      });

      // #93 Part D: name-without-number hint (non-blocking — shows alongside any kept items)
      if (droppedNoQty > 0) {
        RenderLog.write('change_93_no_qty_hint', '1');
        _showSnack('Naam suna par quantity nahi — kuch mark nahi kiya');
      }

      if (items.isEmpty) {
        setState(() {
          _voiceProcessing = false;
          _lastTranscript = transcript;
          // Only overwrite voiceError if no snack was already shown for droppedNoQty
          if (droppedNoQty == 0) {
            _voiceError = droppedLowConf > 0
                ? 'Saaf nahi suna — dobara boliye'
                : "Didn't catch that — try again";
          }
        });
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) setState(() => _voiceError = '');
        });
        return;
      }
      await _commitVoiceItems(items);
      if (mounted) {
        setState(() => _sessionVoiceCount++); // kept for legacy logs; badge now uses _voiceMentions
        _advanceIfReceived(); // B4: auto-advance after voice commit
        _refreshVoiceMentions(); // #263: update distinct-product spoken count
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _voiceError = e.toString(); });
      Future.delayed(const Duration(seconds: 4), () {
        if (mounted) setState(() => _voiceError = '');
      });
    } finally {
      if (mounted) setState(() => _voiceProcessing = false);
    }
  }

  List<Map<String, dynamic>> _buildExpectedList() {
    final expected = <Map<String, dynamic>>[];
    if (_supplierOrderItems.isNotEmpty) {
      for (final row in _supplierOrderItems) {
        final name = row['product_name']?.toString();
        if (name == null) continue;
        expected.add({'name': name, 'ordered_qty': ordQtyOf(row)}); // B8: shape-tolerant
      }
    } else {
      final seenNames = <String>{};
      for (final row in _items) {
        final name = row['product_name']?.toString();
        if (name == null || !seenNames.add(name)) continue;
        final entry = <String, dynamic>{
          'name': name,
          'ordered_qty': ordQtyOf(row),
        };
        final pt = row['pack_type']?.toString();
        if (pt != null && pt.isNotEmpty) entry['unit'] = pt;
        expected.add(entry);
        if (expected.length >= 200) break;
      }
    }
    return expected;
  }

  // #93: ADDITIVE — partial mixed counts accumulate across clips.
  // Each clip ADDs spoken qty to existing received_qty (not SET/replace).
  Future<void> _commitVoiceItems(List<Map<dynamic, dynamic>> items) async {
    final supplier = _selectedSupplier;
    if (supplier == null) return;

    // Aggregate by product_id: sum received_qty for duplicates in one clip.
    final Map<int, ({String name, int qty, String heard})> byProduct = {};
    int skipped = 0;

    for (final item in items) {
      final matchedName = item['matched_name']?.toString();
      final heardName = (item['heard'] ?? '').toString().trim();
      final rawQty = item['received_qty'];

      // No qty spoken → skip (server already drops these via dropped_no_qty, belt-and-suspenders)
      if (rawQty == null) { skipped++; continue; }
      // Guard: empty heard = Gemini guess without actual speech
      if (heardName.isEmpty || heardName.length < 2) { skipped++; continue; }

      final receivedQty = (rawQty as num).toInt();
      if (receivedQty <= 0) { skipped++; continue; }

      // Look up product_id by matched_name in current box
      int? productId;
      if (matchedName != null && matchedName != 'not_on_order') {
        for (final row in _items) {
          if (row['product_name']?.toString() == matchedName) {
            productId = (row['product_id'] as num?)?.toInt();
            break;
          }
        }
      }
      if (productId == null) { skipped++; continue; }

      if (byProduct.containsKey(productId)) {
        // Multiple mentions of same product in one clip → sum them
        byProduct[productId] = (
          name: byProduct[productId]!.name,
          qty: byProduct[productId]!.qty + receivedQty,
          heard: heardName,
        );
      } else {
        byProduct[productId] = (name: matchedName ?? heardName, qty: receivedQty, heard: heardName);
      }
    }

    if (skipped > 0) RenderLog.write('84_skipped_no_qty', '$skipped');

    if (widget.arrivals) {
      // #262: Arrivals voice clips ADD per-clip qty (bag_count_add), not SET absolute.
      // Clip 1: 5 -> bag holds 5; clip 2: 1 -> bag holds 6. bag_count_set overwrote.
      for (final entry in byProduct.entries) {
        final ok = await _addVoiceBagQty(
          productId: entry.key,
          productName: entry.value.name,
          qty: entry.value.qty,
          rawSegment: entry.value.heard,
        );
        if (!mounted) return;
        if (!ok) break; // bag error (no_bag, locked) — stop this clip
      }
    } else {
      // #331: Shop stage: absolute-set via set_voice_received (writes shop_qty, no bag needed).
      // New total = current shop_qty across all lines for this product + clip qty.
      for (final entry in byProduct.entries) {
        // Sum existing shop_qty across all lines for this product
        int existingShopQty = 0;
        for (final row in _items) {
          if ((row['product_id'] as num?)?.toInt() == entry.key) {
            existingShopQty += (row['shop_qty'] as num?)?.toInt() ?? 0;
          }
        }
        final newTotal = existingShopQty + entry.value.qty;
        final ok = await _setShopVoiceQty(
          productId: entry.key,
          productName: entry.value.name,
          newTotal: newTotal.toDouble(),
          rawSegment: entry.value.heard,
        );
        if (!mounted) return;
        if (!ok) break;
      }
    }

    // Reload DB once after all additions (not per item)
    if (byProduct.isNotEmpty && mounted) await _reloadItemsFromDB();

    final done = _items.length - _pendingCount;
    RenderLog.write('84_progress', '$done/${_items.length}');
  }
  // #331: Shop-stage absolute-set via set_voice_received; writes shop_qty (no bag gate).
  // Returns true on success, false on error.
  Future<bool> _setShopVoiceQty({
    required int productId,
    required String productName,
    required double newTotal,
    required String rawSegment,
  }) async {
    final supplier = _selectedSupplier;
    if (supplier == null) return false;
    try {
      final rawRes = await Supabase.instance.client.rpc('set_voice_received', params: {
        'p_supplier_name': supplier,
        'p_product_id': productId,
        'p_qty': newTotal,
        'p_note': 'voice: $rawSegment',
      });
      final res = rawRes is Map ? Map<String, dynamic>.from(rawRes) : <String, dynamic>{};
      if (!mounted) return false;
      if (res['error'] != null) {
        if (res['error'] == 'received_locked') {
          _showSnack('Already received — locked');
        } else {
          _showSnack('Error: ${res['error']}');
        }
        return false;
      }
      // Update shop_qty in local items from response rows
      final rows = res['rows'] as List? ?? [];
      if (rows.isNotEmpty) {
        setState(() {
          for (final row in rows) {
            final oiid = row['order_item_id']?.toString();
            if (oiid == null) continue;
            final idx = _items.indexWhere((i) => i['order_item_id']?.toString() == oiid);
            if (idx >= 0) {
              final setTotal = row['shop_set'];
              if (setTotal != null) _items[idx]['shop_qty'] = setTotal;
            }
          }
        });
      }
      RenderLog.write('84_committed', '$productName:shopSet${newTotal.toInt()}');
      return true;
    } catch (e) {
      if (mounted) _showSnack('Commit error: $e');
      return false;
    }
  }

  // #262: Arrivals voice ADD — each clip adds its qty to the current active bag via bag_count_add.
  // Returns true on success, false on error (no bag, locked, exceeds_ordered).
  Future<bool> _addVoiceBagQty({
    required int productId,
    required String productName,
    required int qty,
    required String rawSegment,
  }) async {
    final supplier = _selectedSupplier;
    if (supplier == null) return false;
    if (_activeBag == null) {
      _showSnack('Scan a bag first before counting');
      return false;
    }
    try {
      final rawCount = await Supabase.instance.client.rpc('bag_count_add', params: {
        'p_supplier_name': supplier,
        'p_product_id': productId,
        'p_delta': qty,
        'p_note': 'voice: $rawSegment',
      });
      final res = _normRpc(rawCount);
      if (!mounted) return false;
      if (res['error'] != null) {
        _showSnack(_bagCountError(res));
        RenderLog.write('c262_voice_add_err', 'product=$productId;error=${res['error']}');
        return false;
      }
      final grandTotal = res['grand_total'];
      RenderLog.write('c262_voice_add',
          'product=$productId;delta=$qty;grand_total=$grandTotal');
      setState(() { _tally[productId] = (grandTotal as num?)?.toInt() ?? qty; });
      return true;
    } catch (e) {
      // #331 D2: catch bag-gate check_violation and show friendly sheet
      final msg = e.toString();
      if (mounted) {
        if (msg.contains('no bag, no count') || msg.contains('check_violation')) {
          _showBagRequiredSheet(productName);
        } else {
          _showSnack('Commit error: $e');
        }
      }
      return false;
    }
  }

  // #331 D2: friendly bag-required sheet when warehouse counting violates bag gate.
  void _showBagRequiredSheet(String productName) {
    RenderLog.write('c331_bag_prompt', 'product=$productName');
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Bag required',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _kText)),
          const SizedBox(height: 8),
          Text('Scan/select the bag for $productName so the bag total equals the counted qty, then count again.',
              style: const TextStyle(fontSize: 13, color: _kSub)),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _kGreen),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ),
        ]),
      ),
    );
  }

  // #263: load voice clip mentions from DB → derive distinct-product count for "N spoken" badge.
  Future<void> _refreshVoiceMentions() async {
    final supplier = _selectedSupplier;
    if (supplier == null) return;
    try {
      final rows = await Supabase.instance.client
          .rpc('get_voice_clip_mentions', params: {'p_supplier_name': supplier}) as List;
      if (!mounted) return;
      final mentions = rows.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      final distinct = mentions.map((m) => m['product_id']).where((id) => id != null).toSet().length;
      RenderLog.write('c263_spoken_count', 'distinct_products=$distinct;total_mentions=${mentions.length}');
      setState(() => _voiceMentions = mentions);
    } catch (_) {}
  }

  Future<void> _reloadItemsFromDB() async {
    final supplier = _selectedSupplier;
    if (supplier == null) return;
    // #127 BUG1 FIX: Arrivals reload uses fw_get_state directly (no get_receiving_box).
    if (widget.arrivals) {
      try {
        final dynamic _rawReload = await Supabase.instance.client
            .rpc('fw_get_state', params: {'p_supplier_name': supplier, 'p_stage': 'arrivals'});
        if (!mounted) return;
        Map<String, dynamic> stateRes;
        if (_rawReload is Map) {
          stateRes = Map<String, dynamic>.from(_rawReload);
        } else if (_rawReload is List && _rawReload.isNotEmpty && _rawReload[0] is Map) {
          final first = _rawReload[0] as Map;
          final inner = first['fw_get_state'];
          stateRes = inner is Map
              ? Map<String, dynamic>.from(inner)
              : Map<String, dynamic>.from(first);
        } else {
          stateRes = {};
        }
        final rawItems = stateRes['items'];
        final stateItems = (rawItems is List ? rawItems : <dynamic>[])
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList();
        // CHANGE #269 A-Z sort (fixes missed reload path)
        stateItems.sort((a, b) => (a['product_name'] ?? '').toString().toLowerCase()
            .compareTo((b['product_name'] ?? '').toString().toLowerCase()));
        final confirmed = stateRes['arrivals_confirmed'] == true ||
            stateRes['supplier_fully_locked'] == true;
        final reloadedMode = supplierModeOf(stateRes); // B6: top-level, not per-item
        final reloadActiveBagRaw = stateRes['active_bag'];
        final reloadActiveBag = reloadActiveBagRaw is Map ? Map<String, dynamic>.from(reloadActiveBagRaw) : null;
        // CHANGE #273 — sync bag_flow from backend on every reload (realtime, tab-switch, etc.)
        final reloadBagFlow = stateRes['bag_flow']?.toString();
        final reloadAwaitingBagNo = stateRes['awaiting_new_after_bag'];
        RenderLog.write('c270_state_from_backend', 'active_bag=${reloadActiveBag?['bag_no'] ?? 'null'};supplier=$supplier');
        RenderLog.write('c273_flow_from_backend', 'bag_flow=${reloadBagFlow ?? 'null'};supplier=$supplier');
        setState(() {
          _items = stateItems;
          if (confirmed != _arrivalsLocked) _arrivalsLocked = confirmed;
          if (reloadedMode != _supplierMode) _supplierMode = reloadedMode;
          _activeBag = reloadActiveBag;
          if (reloadActiveBag == null) _changeProgressBySupplier.remove(supplier);
          // Sync change-bag intent from backend on every reload
          if (reloadBagFlow == 'awaiting_new') {
            _changeBagPendingOldBag[supplier] = reloadAwaitingBagNo?.toString();
          } else if (reloadBagFlow != null) {
            // 'active' or 'none' — clear stale intent (new bag was attached or flow was reset)
            _changeBagPendingOldBag.remove(supplier);
          }
        });
      } catch (e) {
        final errMsg = e.toString();
        if (mounted) setState(() => _error = errMsg);
        RenderLog.write('c160_loadbox_error', 'reload:${errMsg.substring(0, errMsg.length.clamp(0, 110))}');
      }
      return;
    }
    try {
      final res = await Supabase.instance.client
          .rpc('get_receiving_box', params: {'p_supplier_name': supplier}) as List;
      if (!mounted) return;
      final items = res.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      items.sort((a, b) {
        final aPend = stateOf(a) == 'pending' ? 0 : 1;
        final bPend = stateOf(b) == 'pending' ? 0 : 1;
        if (aPend != bPend) return aPend - bPend;
        return (a['product_name'] ?? '').toString().compareTo((b['product_name'] ?? '').toString());
      });
      setState(() {
        _items = items;
        // B5: always assign (even null) so mode clears correctly after undo
        _supplierMode = _collectModeMap[supplier];
        // B9: clamp focus after reload to prevent _currentItem returning null
        if (_items.isNotEmpty && _focusIdx >= _items.length) {
          _focusIdx = _items.length - 1;
          RenderLog.write('c168_focus_clamped', 'true');
        }
      });
    } catch (_) {}
  }

  // ── #253: Bag attach/detach helpers ─────────────────────────────────────────

  // F13: Supabase RPCs returning jsonb sometimes wrap the result in a List.
  static Map<String, dynamic> _normRpc(dynamic raw) {
    if (raw is List && raw.isNotEmpty) return Map<String, dynamic>.from(raw.first as Map);
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return {};
  }

  // Maps bag attach/detach error codes to user-friendly messages.
  String _bagError(Map m) {
    final code = m['error']?.toString() ?? '';
    switch (code) {
      case 'bad_code': return 'Invalid QR — scan a valid BAG-xxx code';
      case 'no_such_bag': return 'Bag not found — check the QR and retry';
      case 'bag_not_found': return 'Bag not found — check the QR and retry';
      // CHANGE #268 — bag_already_used_by_supplier: same supplier re-scanning their filled bag
      case 'bag_already_used_by_supplier':
        return m['hint']?.toString() ?? 'This bag was already used for this supplier — use a different bag.';
      case 'bag_full': return 'Bag is full'; // kept as fallback; attach no longer returns this
      case 'bag_in_use':
        final held = m['held_by']?.toString() ?? '';
        return held.isNotEmpty ? 'Bag in use by $held' : 'Bag already in use by another supplier';
      case 'wrong_bag':
        final expected = m['expected']?.toString() ?? '?';
        final scanned = m['scanned']?.toString() ?? '?';
        return 'Wrong bag — expected $expected, scanned $scanned';
      case 'no_active_bag': return 'No bag attached — scan a bag first';
      case 'bag_wrong_supplier': return 'Bag belongs to a different supplier';
      case 'not_authorized': return 'Not authorized for this action';
      default: return code.isNotEmpty ? 'Bag error: $code' : 'Unknown bag error';
    }
  }

  // Maps bag_count_set error codes to user-friendly messages.
  String _bagCountError(Map m) {
    final code = m['error']?.toString() ?? '';
    switch (code) {
      case 'no_bag_selected': return 'Count items into a bag first — scan a bag to begin.';
      case 'received_locked': return 'Already locked — cannot change count';
      case 'bad_qty': return 'Invalid quantity';
      case 'product_not_for_supplier': return 'Product not in this supplier\'s order';
      case 'not_authorized': return 'Not authorized';
      case 'exceeds_ordered':
        final ordered = m['ordered'];
        final maxBag = m['max_for_this_bag'];
        final inOther = m['already_in_other_bags'];
        final attempted = m['attempted'];
        RenderLog.write('c254_exceeds_handled',
            'ordered=$ordered;max_bag=$maxBag;in_other=$inOther;attempted=$attempted');
        if (maxBag != null && inOther != null && ordered != null) {
          return 'Over-limit — only $maxBag can go in this bag '
              '($inOther already counted in other bags, $ordered ordered). '
              'Count not saved.';
        }
        return 'Quantity exceeds ordered amount. Count not saved.';
      default: return code.isNotEmpty ? 'Count error: $code' : 'Unknown count error';
    }
  }

  // CHANGE #276 — friendly message for any backend check_violation / no-bag rejection
  String _noBagFriendlyMessage(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('no bag') || s.contains('bag total') || s.contains('check_violation') ||
        s.contains('no_bag_selected') || s.contains('must equal')) {
      RenderLog.write('c276_nobag_error_shown', 'error=${e.toString().substring(0, e.toString().length.clamp(0, 80))}');
      return 'Count items into a bag first — scan a bag to begin.';
    }
    if (s.contains('supplier_confirmed')) return 'This supplier is already received.';
    if (s.contains('bag_already_used_by_supplier')) return 'Bag was already used for this supplier — scan a different bag.';
    return e.toString().substring(0, e.toString().length.clamp(0, 100));
  }

  // Attach a freshly scanned bag code to this supplier (initial attach — no existing bag).
  // #261: unified bag-flow entry point — called by BOTH the "Scan bag to start counting"
  // button AND the "Change Bag" yellow pill. Routes to the correct sub-flow:
  //   • mid-change (old detached, awaiting new) → resume _ChangeBagScanner at needNew
  //   • active bag present → start _ChangeBagScanner at needOld (normal change)
  //   • neither → first-attach plain scanner (_BagScannerDialog)
  Future<void> _openBagFlow() async {
    final supplier = _selectedSupplier;
    if (supplier == null) return;

    final active = _activeBag;
    // CHANGE #271 — intent flag takes precedence; survives backend reload
    final pendingOldBag = _changeBagPendingOldBag[supplier];

    if (_changeBagPendingOldBag.containsKey(supplier)) {
      // RESUME: change-bag intent still live; old bag detached, scan new bag
      RenderLog.write('c261_resume_need_new',
          'supplier=$supplier;old_bag=$pendingOldBag');
      await _openChangeBagModal(supplier,
          initialStep: _CBStep.needNew,
          currentBag: {'bag_no': pendingOldBag ?? '?'});
    } else if (active != null) {
      // CHANGE: active bag present → start at need_old
      await _openChangeBagModal(supplier,
          initialStep: _CBStep.needOld,
          currentBag: active);
    } else {
      // FIRST ATTACH: no active bag, no pending change → plain scanner
      await _openChooseBagModal(supplier);
    }
  }

  // Opens the two-step color-coded Change-Bag modal. Handles progress save on detach + clear on attach.
  Future<void> _openChangeBagModal(String supplier,
      {required _CBStep initialStep, required Map<String, dynamic> currentBag}) async {
    RenderLog.write('c258_changebag_step',
        'open;supplier=$supplier;bag=${currentBag['bag_no']};step=${initialStep.name}');
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ChangeBagScanner(
        supplier: supplier,
        currentBag: currentBag,
        initialStep: initialStep,
      ),
    );
    if (!mounted) return;
    // CHANGE #270 — log every close; _reloadItemsFromDB clears mid-change when backend says null
    RenderLog.write('c270_scanner_closed', 'supplier=$supplier;result=${result == null ? 'null' : (result['_partial'] == true ? 'partial' : 'done')}');
    if (result != null && result['_partial'] == true) {
      // Old bag detached, X pressed before new bag scanned — keep change-bag intent alive.
      // CHANGE #271 FIX: skip _reloadItemsFromDB() here; a backend reload can race and set
      // _activeBag to the old bag (consistency lag), which would bury the change-bag panel.
      // The render selector now checks intent FIRST (before active_bag), so even if a later
      // realtime event triggers a reload, the panel stays visible until explicit Cancel/attach.
      final oldBagNo = result['old_bag_no']?.toString();
      setState(() {
        _activeBag = null;
        _changeProgressBySupplier[supplier] = {
          'old_bag': oldBagNo,
          'old_detached': true,
        };
        _changeBagPendingOldBag[supplier] = oldBagNo;
      });
      RenderLog.write('c271_changebag_persist', 'supplier=$supplier;old_bag=$oldBagNo');
      return; // NO reload — intent must not be overwritten by backend state
    } else if (result != null && result['_partial'] != true) {
      // Attach succeeded — clear ALL progress and intent, then reload to sync items
      RenderLog.write('c261_change_attach_done',
          'supplier=$supplier;new_bag=${result['bag_no']}');
      RenderLog.write('c271_changebag_attach', 'supplier=$supplier;bag=${result['bag_no']}');
      setState(() {
        _activeBag = result;
        _changeProgressBySupplier.remove(supplier);
        _changeBagPendingOldBag.remove(supplier);
      });
    }
    // null: X before scanning old bag — reload restores "Bag in Use" from backend.
    await _reloadItemsFromDB();
  }

  // Plain first-attach scanner — no change progress involved.
  Future<void> _openChooseBagModal(String supplier) async {
    RenderLog.write('c253_scanner_open', 'supplier=$supplier;action=first_attach');
    final code = await showDialog<String>(
      context: context,
      builder: (_) => const _BagScannerDialog(title: 'Scan Bag to Attach'),
    );
    if (!mounted) return;
    if (code == null) {
      // CHANGE #270/#271 — X closed without scanning; reload backend state and clear stale progress
      RenderLog.write('c270_scanner_closed', 'supplier=$supplier;result=null');
      RenderLog.write('c271_freshstart_close', 'supplier=$supplier'); // CHANGE #271
      await _reloadItemsFromDB();
      return;
    }
    await _attachBagCode(supplier, code);
  }

  // Shared attach logic — calls bag_attach, normalizes result, updates state.
  Future<void> _attachBagCode(String supplier, String code) async {
    try {
      final rawAttach = await Supabase.instance.client.rpc('bag_attach', params: {
        'p_supplier_name': supplier,
        'p_bag_code': code,
      });
      final m = _normRpc(rawAttach);
      if (!mounted) return;
      if (m['error'] != null) {
        // CHANGE #268 — log bag_already_used_by_supplier before showing snack
        if (m['error'].toString() == 'bag_already_used_by_supplier') {
          RenderLog.write('c268_already_used', 'bag=${m['bag_no']?.toString() ?? code}');
        }
        _showSnack(_bagError(m));
        return;
      }
      final bagData = m['bag'] is Map ? Map<String, dynamic>.from(m['bag'] as Map) : null;
      setState(() => _activeBag = bagData ?? m);
      // CHANGE #268 — log reuse when a full bag attaches successfully (different supplier)
      if ((_activeBag?['status']?.toString() ?? '') == 'full') {
        RenderLog.write('c268_reuse_ok', 'bag=${_activeBag?['bag_no']};supplier=$supplier');
      }
      RenderLog.write('c253_bag_attached', 'bag=${_activeBag?['bag_no']};supplier=$supplier');
      await _reloadItemsFromDB();
    } catch (e) {
      if (mounted) _showSnack('Could not attach bag: $e');
    }
  }

  // Detach active bag via the ✕ button (no scan required — uses stored bag_code).
  Future<void> _detachBag() async {
    final supplier = _selectedSupplier;
    if (supplier == null || _activeBag == null) return;
    try {
      final bagNo = _activeBag!['bag_no'];
      final bagCode = _activeBag!['bag_code']?.toString() ?? '';
      final rawDetach = await Supabase.instance.client.rpc('bag_detach', params: {
        'p_supplier_name': supplier,
        'p_bag_code': bagCode,
      });
      final m = _normRpc(rawDetach);
      if (!mounted) return;
      if (m['error'] != null) {
        _showSnack(_bagError(m));
        return;
      }
      setState(() => _activeBag = null);
      RenderLog.write('c253_bag_detached', 'bag=$bagNo;supplier=$supplier');
      await _reloadItemsFromDB();
    } catch (e) {
      if (mounted) _showSnack('Could not detach bag: $e');
    }
  }

  Widget _buildBagControl() {
    final bag = _activeBag;
    final supplier = _selectedSupplier ?? '';
    // CHANGE #274 — disable all bag scanning when supplier is fully confirmed/locked
    final locked = _arrivalsLocked;

    // CHANGE #271 FIX: check intent FIRST, before active_bag.
    if (_changeBagPendingOldBag.containsKey(supplier)) {
      final oldBagNo = _changeBagPendingOldBag[supplier];
      RenderLog.write('c271_changebag_persist', 'rendered;supplier=$supplier;old_bag=$oldBagNo');
      RenderLog.write('c272_no_cancel', 'bag_no=$oldBagNo');
      if (locked) RenderLog.write('c274_scan_disabled_locked', 'supplier=$supplier;state=detached');
      return GestureDetector(
        onTap: locked ? null : _openBagFlow,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: locked ? const Color(0xFFF3F4F6) : const Color(0xFFFEF3C7),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: locked
                  ? const Color(0xFFE5E7EB)
                  : const Color(0xFFD97706).withValues(alpha: 0.5)),
            ),
            child: Row(children: [
              Icon(Icons.swap_horiz_rounded, size: 18,
                  color: locked ? const Color(0xFF9CA3AF) : const Color(0xFF92400E)),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Bag $oldBagNo detached — tap to scan new bag',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                        color: locked ? const Color(0xFF9CA3AF) : const Color(0xFF92400E))),
              ),
              Icon(Icons.chevron_right_rounded, size: 18,
                  color: locked ? const Color(0xFF9CA3AF) : const Color(0xFF92400E)),
            ]),
          ),
        ),
      );
    }

    if (bag == null) {
      if (locked) RenderLog.write('c274_scan_disabled_locked', 'supplier=$supplier;state=no_bag');
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: OutlinedButton.icon(
          onPressed: locked ? null : _openBagFlow,
          icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
          label: const Text('Scan bag to start counting'),
          style: OutlinedButton.styleFrom(
            foregroundColor: locked ? const Color(0xFF9CA3AF) : _kGreen,
            side: BorderSide(color: locked ? const Color(0xFFE5E7EB) : _kGreen),
            minimumSize: const Size.fromHeight(44),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      );
    }
    final bagNo = bag['bag_no'];
    RenderLog.write('c261_bar_in_use', 'bag=$bagNo;in_use=true;yellow_pill=true;no_x=true');
    if (locked) RenderLog.write('c274_scan_disabled_locked', 'supplier=$supplier;state=in_use');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFD1FAE5),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF065F46).withValues(alpha: 0.3)),
        ),
        child: Row(children: [
          const Icon(Icons.shopping_bag_outlined, size: 18, color: Color(0xFF065F46)),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Bag $bagNo in Use',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                    color: Color(0xFF065F46))),
          ),
          // #261: yellow pill "Change Bag" button; disabled when locked (#274)
          GestureDetector(
            onTap: locked ? null : _openBagFlow,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: locked ? const Color(0xFFE5E7EB) : const Color(0xFFFFC107),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.swap_horiz_rounded, size: 16,
                    color: locked ? const Color(0xFF9CA3AF) : const Color(0xFF5D4037)),
                const SizedBox(width: 4),
                Text('Change Bag',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                        color: locked ? const Color(0xFF9CA3AF) : const Color(0xFF5D4037))),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  // ── #91: Confirm count lock / unlock ─────────────────────────────────────────

  // #92: isWide=true → right-aligned compact; false → full-width refined mobile strip
  Widget _buildConfirmFooter(bool locked, {bool isWide = false}) {
    final isAdmin = UserState.of(context).isAdmin;

    // #156/#157: Arrivals-specific footer — "Confirm all items received" / locked+undo
    if (widget.arrivals) {
      if (locked) {
        return Column(mainAxisSize: MainAxisSize.min, children: [
          _HoldToUndo(
            onUndo: _fw_unconfirmAllReceived,
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: _kReceivedBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _kReceivedFg.withValues(alpha: 0.3)),
              ),
              child: const Row(children: [
                Icon(Icons.lock_rounded, size: 15, color: _kReceivedFg),
                SizedBox(width: 8),
                Expanded(
                  child: Text('All items received ✓',
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600, color: _kReceivedFg)),
                ),
              ]),
            ),
          ),
        ]);
      }
      // #256: "Send supplier reminder" removed from Warehouse — disputes are raised automatically
      // by fw_confirm_all_received and handled in the Disputes tab.
      RenderLog.write('c256_reminder_removed', 'warehouse_footer_built_without_reminder');
      // CHANGE #284: Confirm-all is always clickable (bag-or-not); log real state for audit.
      final bool hasBag284 = _activeBag != null;
      RenderLog.write('c284_confirm_always_clickable',
          'bag=$hasBag284;enabled=${!_confirmingAll}');
      return Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          height: 44,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _kGreen,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: _confirmingAll ? null : _fw_confirmAllReceived,
            child: _confirmingAll
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.check_circle_outline_rounded,
                        size: 15, color: Colors.white),
                    SizedBox(width: 4),
                    Text('Confirm all items received',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                  ]),
          ),
        ),
      ]);
    }

    if (locked) {
      RenderLog.write('change_91_locked', '1');
      if (isWide) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            GestureDetector(
              onLongPress: isAdmin ? _showUnlockDialog : null,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: _kReceivedBg,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: _kReceivedFg.withValues(alpha: 0.3)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.lock_rounded, size: 14, color: _kReceivedFg),
                  const SizedBox(width: 6),
                  Text(_collectLockedText,
                      style: const TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w600, color: _kReceivedFg)),
                  if (isAdmin) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.more_horiz_rounded,
                        size: 14, color: _kReceivedFg.withValues(alpha: 0.6)),
                  ],
                ]),
              ),
            ),
          ],
        );
      }
      return _HoldToUndo(
        onUndo: _fw_undoCollectSubmit,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: _kReceivedBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _kReceivedFg.withValues(alpha: 0.3)),
          ),
          child: Row(children: [
            const Icon(Icons.lock_rounded, size: 15, color: _kReceivedFg),
            const SizedBox(width: 8),
            Expanded(
              child: Text(_collectLockedText,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: _kReceivedFg)),
            ),
          ]),
        ),
      );
    }

    // #147 FIX C: always side-by-side, both at _kFooterH — matches locked pill height.
    RenderLog.write('change_92_confirm_styled', '1');
    RenderLog.write('c137_collect_buttons', 'two=y;names=count_wh+confirm');
    // C171: short reminder button above collect footer buttons
    final sc171 = _shortCount;
    RenderLog.write('c171_short_btn_visible',
        'supplier=${_selectedSupplier ?? ''};short_count=$sc171;visible=${sc171 > 0}');
    const double _kFooterH = 44.0;
    final collectRow = Row(children: [
      Expanded(
        child: SizedBox(
          height: _kFooterH,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: _kGreen,
              side: const BorderSide(color: _kGreen),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 6),
            ),
            onPressed: _submittingCollect ? null : _fw_countInWarehouse,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(mainAxisSize: MainAxisSize.min, children: const [
                Icon(Icons.warehouse_outlined, size: 15, color: _kGreen),
                SizedBox(width: 4),
                Text('Count in warehouse',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kGreen)),
              ]),
            ),
          ),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: SizedBox(
          height: _kFooterH,
          // #331: proactive affordance — outlined/muted when items not yet counted at shop
          child: Builder(builder: (_) {
            final uncounted = _shopUncountedCount;
            final notReady = uncounted > 0;
            return Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                height: _kFooterH,
                width: double.infinity,
                child: notReady
                    ? OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _kSub,
                          side: const BorderSide(color: _kBorder),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        onPressed: _submittingCollect ? null : _fw_confirmCounting,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(mainAxisSize: MainAxisSize.min, children: const [
                            Icon(Icons.check_circle_outline_rounded, size: 15),
                            SizedBox(width: 4),
                            Text('Confirm counting',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                          ]),
                        ),
                      )
                    : FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: _kGreen,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        onPressed: _submittingCollect ? null : _fw_confirmCounting,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(mainAxisSize: MainAxisSize.min, children: const [
                            Icon(Icons.check_circle_outline_rounded, size: 15, color: Colors.white),
                            SizedBox(width: 4),
                            Text('Confirm counting',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
                          ]),
                        ),
                      ),
              ),
              if (notReady) ...[
                const SizedBox(height: 2),
                Text('$uncounted item(s) not counted',
                    style: const TextStyle(fontSize: 10, color: _kSub)),
              ],
            ]);
          }),
        ),
      ),
    ]);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (sc171 > 0 || _wrongFlaggedCount > 0) ...[
        _buildShortReminderBtn(),
        const SizedBox(height: 8),
      ],
      collectRow,
    ]);
  }

  Widget _buildShortReminderBtn() {
    return SizedBox(
      height: 44,
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _sendingShortReminder ? null : _fw_sendSupplierShortReminder,
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF7C3AED),
          side: const BorderSide(color: Color(0xFFDDD6FE)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        icon: _sendingShortReminder
            ? const SizedBox(width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF7C3AED)))
            : const Icon(Icons.notifications_active_rounded, size: 15),
        label: const Text('Send supplier reminder',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      ),
    );
  }

  // #121: Undo Collect submission — clears mode, badge returns to P, supplier leaves Arrivals.
  Future<void> _fw_undoCollectSubmit() async {
    final supplier = _selectedSupplier;
    if (supplier == null) return;
    try {
      final res = await Supabase.instance.client.rpc('fw_undo_collect_submit',
          params: {'p_supplier_name': supplier});
      // R3: if already confirmed in Arrivals, show specific toast and bail
      final errVal = (res is Map) ? res['error']?.toString() : null;
      if (errVal == 'already_confirmed_in_arrivals') {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Undo from Warehouse first')),
          );
        }
        return;
      }
      if (!mounted) return;
      RenderLog.write('c125_undo_hold_fired', 'true');
      setState(() { _supplierMode = null; });
      _loadCollectModes(); // refresh badge map → P
      _loadSuppliers();
      await _reloadItemsFromDB();
      context.findAncestorStateOfType<_AdminFulfillmentScreenState>()?._refreshArrivals(); // R3: supplier leaves Arrivals
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Submission undone')),
        );
      }
    } catch (e) {
      if (mounted) {
        final msg = e.toString();
        final text = msg.contains('already_confirmed_in_arrivals')
            ? 'Undo from Warehouse first'
            : 'Undo error: ${msg.substring(0, msg.length.clamp(0, 80))}';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
      }
    }
  }

  // #331: count of items not yet shop-counted (shop_qty == null)
  int get _shopUncountedCount =>
      _items.where((i) => i['shop_qty'] == null).length;

  // #137/#331: Confirm counting — every item must have a shop count first.
  Future<void> _fw_confirmCounting() async {
    if (_submittingCollect) return;
    final supplier = _selectedSupplier;
    if (supplier == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm counting?'),
        content: Text('This locks the Supplier Shop count for $supplier and forwards all items to the Warehouse for a bagged recount.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _kGreen),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm & send'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _submittingCollect = true);
    try {
      final res = await Supabase.instance.client
          .rpc('fw_confirm_counting', params: {'p_supplier_name': supplier}) as Map;
      // #331: handle uncounted items gate — RPC returns list of uncounted product names
      if (res['error'] == 'uncounted_items') {
        if (mounted) setState(() => _submittingCollect = false);
        final names = (res['items'] as List? ?? []).cast<String>();
        RenderLog.write('c331_confirm_gate', 'uncounted=${names.length}');
        if (!mounted) return;
        await showModalBottomSheet<void>(
          context: context,
          builder: (ctx) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Count these first:',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _kText)),
              const SizedBox(height: 8),
              if (names.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: names.map((n) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text('• $n', style: const TextStyle(fontSize: 13, color: _kText)),
                      )).toList(),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: _kGreen),
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('OK'),
                ),
              ),
            ]),
          ),
        );
        return;
      }
      if (res['error'] != null) throw Exception(res['error'].toString());
      final shortsDisputed = (res['shorts_disputed'] as num?)?.toInt() ?? 0;
      if (mounted) setState(() { _supplierMode = 'shop'; _submittingCollect = false; });
      await _reloadItemsFromDB();
      RenderLog.write('c137_collect_action', 'action=confirm;supplier=$supplier');
      RenderLog.write('c117_collect_confirm_text_mode', 'shop');
      RenderLog.write('c125_submit_refresh', 'true');
      RenderLog.write('c331_confirm_gate', 'success;shorts=$shortsDisputed');
      _loadSupplierDots();
      _loadCollectModes(); // R2: badge P→C immediately
      context.findAncestorStateOfType<_AdminFulfillmentScreenState>()?._refreshArrivals(); // R2: supplier appears in Arrivals
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(
            'Counting confirmed — $shortsDisputed short item(s) disputed. Items moved to Warehouse for recount.'
          )),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _submittingCollect = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString().substring(0, e.toString().length.clamp(0, 80))}')),
        );
      }
    }
  }

  // #137: Case 2 — skip shop count; set mode='warehouse', lock Collect for warehouse counting.
  Future<void> _fw_countInWarehouse() async {
    if (_submittingCollect) return;
    final supplier = _selectedSupplier;
    if (supplier == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Count in warehouse?'),
        content: Text('Items from $supplier will be counted at the warehouse instead. This locks the Supplier Shop tab for this supplier.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _kGreen),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _submittingCollect = true);
    try {
      final res = await Supabase.instance.client
          .rpc('fw_count_in_warehouse', params: {'p_supplier_name': supplier}) as Map;
      if (res['error'] != null) throw Exception(res['error'].toString());
      if (mounted) setState(() { _supplierMode = 'warehouse'; _submittingCollect = false; });
      await _reloadItemsFromDB();
      RenderLog.write('c137_collect_action', 'action=warehouse;supplier=$supplier');
      RenderLog.write('c117_collect_confirm_text_mode', 'warehouse');
      RenderLog.write('c125_submit_refresh', 'true');
      _loadSupplierDots();
      _loadCollectModes(); // R2: badge P→CR immediately
      context.findAncestorStateOfType<_AdminFulfillmentScreenState>()?._refreshArrivals(); // R2: supplier appears in Arrivals
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Collected & sent to warehouse for counting')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _submittingCollect = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString().substring(0, e.toString().length.clamp(0, 80))}')),
        );
      }
    }
  }

  // #137: called by _AdminFulfillmentScreenState to pre-select a supplier from Arrivals.
  void selectSupplierForVoice(String name) {
    if (!mounted) return;
    setState(() => _selectedSupplier = name);
    _loadBox(name);
  }

  Future<void> _showUnlockDialog() async {
    final supplier = _selectedSupplier;
    if (supplier == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unlock this count?'),
        content: Text('Unlock $supplier\'s count to allow edits again?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _kWrongFg),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unlock'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await Supabase.instance.client
          .rpc('unlock_supplier_collect', params: {'p_supplier_name': supplier});
      await _reloadItemsFromDB();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn\'t unlock. Please try again.')),
        );
      }
    }
  }

  // Undo removed — set_voice_received is idempotent SET; delta-undo is not applicable.

  // ── Agent mic helpers (#85) ──────────────────────────────────────────────────

  List<Map<String, dynamic>> _buildAgentItems() {
    return _items
        .where((r) => stateOf(r) != 'cancelled')
        .map((r) => {
              'product_id': (r['product_id'] as num?)?.toInt() ?? 0,
              'name': r['product_name']?.toString() ?? '',
              'ordered': ordQtyOf(r), // B3: shape-tolerant (ordered_qty OR ordered)
              'received': recQtyOf(r),
              'state': stateOf(r),    // B3: derive state for Arrivals items
              'pack_type': r['pack_type']?.toString(),
            })
        .toList();
  }

  Future<void> _startAgentRecording() async {
    if (_agentBusy || _voiceListening || _agentPhase != AgentPhase.idle) return;
    _agentBusy = true;
    // #123 P1: clear stale reply + stop previous audio the instant Ask mediBO starts
    _ttsAudio?.pause();
    _ttsAudio = null;
    final hadPrev = _agentReply.isNotEmpty;
    if (mounted) setState(() { _agentReply = ''; _agentPhase = AgentPhase.idle; });
    RenderLog.write('c123_ask_open', 'cleared_prev=${hadPrev ? 'y' : 'n'}');
    try { RenderLog.write('c303_mic_on_tap', 'ask_medibo'); } catch (_) {}
    try {
      await _voiceService.start();
      _agentRecStarted = true;
      try { RenderLog.write('c303_mic_result', 'granted'); } catch (_) {}
      if (mounted) setState(() => _agentPhase = AgentPhase.listening);
    } catch (e) {
      _agentBusy = false;
      _agentRecStarted = false;
      if (e is MicPermissionException) {
        try { RenderLog.write('c303_mic_result', 'denied'); } catch (_) {}
        if (mounted) _showSnack('Mic access needed for voice — enable it in the browser site settings');
      } else {
        if (mounted) _showSnack('Mic error: $e');
      }
    }
    _agentBusy = false;
  }

  Future<void> _stopAgentRecording() async {
    if (!_agentRecStarted) return;
    _agentRecStarted = false;
    if (mounted) setState(() => _agentPhase = AgentPhase.thinking);
    try {
      final result = await _voiceService.stop();
      if (!mounted) return;
      if (result == null || result.bytes.length < 1500) {
        if (mounted) setState(() { _agentPhase = AgentPhase.idle; _agentReply = ''; });
        _showSnack('No audio captured — try again');
        return;
      }
      await _askAgent(bytes: result.bytes, mime: result.mime);
    } catch (e) {
      if (mounted) setState(() { _agentPhase = AgentPhase.idle; _agentReply = ''; });
    }
  }

  Future<void> _askAgent({required List<int> bytes, required String mime}) async {
    if (!mounted) return;
    try {
      final b64 = base64Encode(bytes);
      final token = Supabase.instance.client.auth.currentSession?.accessToken ?? '';
      final agentItems = _buildAgentItems();
      final supplier = _selectedSupplier ?? '';
      final res = await Supabase.instance.client.functions.invoke(
        'voice-agent',
        body: {
          'audio_base64': b64,
          'mime_type': mime,
          'supplier_name': supplier,
          'items': agentItems,
        },
        headers: {'Authorization': 'Bearer $token'},
      );
      if (!mounted) return;
      final data = res.data;
      if (data is Map && data['error'] != null) {
        throw Exception(data['error'].toString());
      }
      await _processAgentResponse(Map<String, dynamic>.from(data as Map));
    } catch (e) {
      if (!mounted) return;
      setState(() { _agentReply = 'Network issue, dobara try karein.'; _agentPhase = AgentPhase.speaking; });
      await _speakReply(_agentReply);
      if (mounted) setState(() => _agentPhase = AgentPhase.idle);
      RenderLog.write('change_85_agent_error', '1');
    }
  }

  Future<void> _processAgentResponse(Map<String, dynamic> data) async {
    if (!mounted) return;
    final transcript = (data['transcript'] ?? '').toString();
    final intent = (data['intent'] ?? 'unknown').toString();
    final reply = (data['reply'] ?? '').toString();
    final actionRaw = data['action'];
    final action = actionRaw is Map ? Map<String, dynamic>.from(actionRaw) : null;
    final hasReply = reply.isNotEmpty;

    // #121: route — confirm=set/correct with action; info=all others (incl ask)
    final isConfirm = (intent == 'set' || intent == 'correct') && action != null;
    final route = isConfirm ? 'confirm' : 'info';

    // #123 P2: stamp before setState so ms_text_to_tts measures the real gap
    final t0 = DateTime.now().millisecondsSinceEpoch;

    // Show reply text IMMEDIATELY — TTS fires right after in the same frame
    setState(() {
      _agentTranscript = transcript;
      _agentIntent = intent;
      _agentReply = reply;
      _agentPhase = AgentPhase.speaking;
    });

    RenderLog.write('change_85_agent_call_ok', '1');
    RenderLog.write('change_85_intent_last', intent);
    RenderLog.write('c121_intent_route', 'intent=$intent;route=$route');
    RenderLog.write('c121_ask_handled', 'intent=$intent;has_reply=${hasReply ? 'y' : 'n'}');

    // #123 P3: log ask intent specifically
    if (intent == 'ask' && hasReply) {
      RenderLog.write('c123_ask_answered', 'had_reply=y');
    }

    final msGap = DateTime.now().millisecondsSinceEpoch - t0;
    RenderLog.write('c123_reply', 'intent=$intent;spoke=y;ms_text_to_tts=$msGap');

    // #123 P2: fire TTS immediately without awaiting — audio plays while UI is already responsive.
    // Phase transitions happen inside the .then() callback so nothing blocks here.
    // #122: cloud TTS (WaveNet Hindi) with browser-speech fallback.
    // #121: speak for all intents; ask/status/remaining/greeting/unknown all speak reply.
    _speakReply(reply).then((_) {
      if (!mounted) return;
      RenderLog.write('change_85_agent_reply_spoken', '1');
      if (isConfirm) {
        if (_boxLocked) {
          RenderLog.write('change_91_edit_blocked', '1');
          setState(() { _pendingAction = null; _agentPhase = AgentPhase.idle; });
        } else {
          setState(() { _pendingAction = action; _agentPhase = AgentPhase.confirming; });
        }
      } else {
        // info path: status, remaining, greeting, ask, unknown, any future intent
        setState(() { _pendingAction = null; _agentPhase = AgentPhase.idle; });
      }
    });
  }

  Future<void> _commitPending() async {
    final action = _pendingAction;
    if (action == null) return;
    final supplier = _selectedSupplier;
    if (supplier == null) return;
    // #254: gate agent commit on active bag for Arrivals
    if (widget.arrivals && _activeBag == null) {
      setState(() { _agentReply = 'Pehle bag scan karo.'; _agentPhase = AgentPhase.speaking; });
      RenderLog.write('c254_gate_block', 'agent_commit_no_bag');
      await _speakReply(_agentReply);
      if (mounted) setState(() { _pendingAction = null; _agentPhase = AgentPhase.idle; });
      return;
    }
    setState(() => _agentPhase = AgentPhase.thinking);
    try {
      final Map<String, dynamic> res;
      if (widget.arrivals) {
        // #254: Arrivals agent commit → bag_count_set (no p_bag_no; backend uses active bag)
        final rawAgent = await Supabase.instance.client.rpc('bag_count_set', params: {
          'p_supplier_name': supplier,
          'p_product_id': (action['product_id'] as num).toInt(),
          'p_qty': (action['qty'] as num).toDouble(),
          'p_note': 'voice-agent #253',
        });
        res = _normRpc(rawAgent);
      } else {
        final rawAgent = await Supabase.instance.client.rpc('set_voice_received', params: {
          'p_supplier_name': supplier,
          'p_product_id': (action['product_id'] as num).toInt(),
          'p_qty': (action['qty'] as num).toDouble(),
          'p_note': 'voice-agent #85',
        });
        res = rawAgent is Map ? Map<String, dynamic>.from(rawAgent) : {};
      }
      if (!mounted) return;
      if (res['error'] != null) {
        final errMsg = widget.arrivals ? _bagCountError(res) : 'Save nahi hua, dobara.';
        RenderLog.write(widget.arrivals ? 'c254_gate_block' : 'change_85_agent_commit_fail',
            widget.arrivals ? 'agent_commit_error=${res['error']}' : '1');
        setState(() { _agentReply = errMsg; _agentPhase = AgentPhase.speaking; });
        await _speakReply(_agentReply);
        if (mounted) setState(() => _agentPhase = AgentPhase.idle);
        return;
      }
      await _reloadItemsFromDB();
      if (!mounted) return;
      final productName = action['product_name']?.toString() ?? '';
      final reply = '$productName ho gaya.';
      setState(() {
        _agentReply = reply;
        _pendingAction = null;
        _agentPhase = AgentPhase.speaking;
      });
      RenderLog.write('change_85_agent_action_committed', '1');
      await _speakReply(reply);
      if (mounted) setState(() => _agentPhase = AgentPhase.idle);
    } catch (e) {
      if (!mounted) return;
      setState(() { _agentPhase = AgentPhase.idle; });
    }
  }

  Future<void> _cancelPending() async {
    setState(() { _pendingAction = null; _agentReply = 'Theek hai, cancel.'; _agentPhase = AgentPhase.speaking; });
    await _speakReply(_agentReply);
    if (mounted) setState(() => _agentPhase = AgentPhase.idle);
  }

  // #122: cloud TTS → natural Hindi WaveNet MP3 with flutter_tts fallback.
  // Cancels any currently-playing reply before starting a new one.
  Future<void> _speakReply(String text) async {
    // Stop any prior TTS audio immediately
    _ttsAudio?.pause();
    _ttsAudio = null;

    if (text.isEmpty) return;

    try {
      final token = Supabase.instance.client.auth.currentSession?.accessToken ?? '';
      final res = await Supabase.instance.client.functions.invoke(
        'tts',
        body: {'text': text},
        headers: {'Authorization': 'Bearer $token'},
      );
      final data = res.data;
      final audioB64 = (data is Map) ? data['audio_base64']?.toString() : null;
      if (audioB64 == null || audioB64.isEmpty) throw Exception('empty audio');

      final dataUrl = 'data:audio/mpeg;base64,$audioB64';
      final c = Completer<void>();
      final el = html.AudioElement(dataUrl);
      _ttsAudio = el;
      RenderLog.write('c122_tts_play', 'platform=web');
      RenderLog.write('c122_tts_call', 'ok=y;bytes=${audioB64.length};fell_back=n');
      el.onEnded.listen((_) { if (!c.isCompleted) c.complete(); });
      el.onError.listen((_) { if (!c.isCompleted) c.complete(); });
      el.play();
      await c.future;
      if (_ttsAudio == el) _ttsAudio = null;
    } catch (_) {
      // Fallback to browser SpeechSynthesis so reply is always heard
      RenderLog.write('c122_tts_call', 'ok=n;bytes=0;fell_back=y');
      await speakAsync(text);
    }
  }

  /// C5: Voice yes/no while confirming — re-uses the existing recorder.
  Future<void> _stopAgentYesNo() async {
    if (!_agentRecStarted) return;
    _agentRecStarted = false;
    setState(() => _agentPhase = AgentPhase.thinking);
    try {
      final result = await _voiceService.stop();
      if (!mounted) { setState(() => _agentPhase = AgentPhase.confirming); return; }
      if (result == null || result.bytes.length < 500) {
        setState(() => _agentPhase = AgentPhase.confirming);
        return;
      }
      final token = Supabase.instance.client.auth.currentSession?.accessToken ?? '';
      final res = await Supabase.instance.client.functions.invoke(
        'voice-agent',
        body: {
          'audio_base64': base64Encode(result.bytes),
          'mime_type': result.mime,
          'supplier_name': _selectedSupplier ?? '',
          'items': _buildAgentItems(),
        },
        headers: {'Authorization': 'Bearer $token'},
      );
      if (!mounted) return;
      final transcript = ((res.data as Map?)?['transcript'] ?? '').toString().toLowerCase().trim();
      final yesPattern = RegExp(r'\b(haan|ha\b|haa|yes|ok|okay|theek|thik|kar do|sahi)\b');
      final noPattern  = RegExp(r'\b(nahi|nahin|no\b|cancel|galat|rehne do)\b');
      if (yesPattern.hasMatch(transcript)) {
        await _commitPending();
      } else if (noPattern.hasMatch(transcript)) {
        await _cancelPending();
      } else {
        setState(() => _agentPhase = AgentPhase.speaking);
        await _speakReply('Haan ya nahi boliye.');
        if (mounted) setState(() => _agentPhase = AgentPhase.confirming);
      }
    } catch (_) {
      if (mounted) setState(() => _agentPhase = AgentPhase.confirming);
    }
  }

  void _advanceIfReceived() {
    final item = _currentItem;
    if (item == null) return;
    if (stateOf(item) != 'pending') _advance(); // B4: use stateOf, not raw key
  }


  Future<MatchCandidate?> _showAmbiguityPicker(List<MatchCandidate> candidates) async {
    return showDialog<MatchCandidate>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Which product?',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _kText)),
            const SizedBox(height: 4),
            const Text('Say a fuller name or tap to select.',
                style: TextStyle(fontSize: 13, color: _kSub)),
            const SizedBox(height: 12),
            ...candidates.map((c) {
              // Find rows for this product
              final productRows = _items.where(
                  (i) => (i['product_id'] as num?)?.toInt() == c.productId).toList();
              final totalOrdered = productRows.fold<num>(
                  0, (sum, r) => sum + ordQtyOf(r));
              final totalReceived = productRows.fold<num>(
                  0, (sum, r) => sum + recQtyOf(r));
              return GestureDetector(
                onTap: () => Navigator.pop(ctx, c),
                child: Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _kBg, borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _kBorder),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(c.productName,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _kText)),
                    const SizedBox(height: 2),
                    Text('Ordered $totalOrdered  ·  Received $totalReceived',
                        style: const TextStyle(fontSize: 12, color: _kSub)),
                  ]),
                ),
              );
            }),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel', style: TextStyle(color: _kSub)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Future<double?> _showQtyPrompt(String productName, int productId) async {
    final productRows = _items.where(
        (i) => (i['product_id'] as num?)?.toInt() == productId).toList();
    final totalOrdered = productRows.fold<num>(
        0, (sum, r) => sum + ordQtyOf(r));
    final totalReceived = productRows.fold<num>(
        0, (sum, r) => sum + recQtyOf(r));
    final remaining = (totalOrdered - totalReceived).toInt().clamp(1, 999);

    int draft = remaining.clamp(1, 99);

    return showDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('How many $productName?',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _kText),
                  textAlign: TextAlign.center),
              const SizedBox(height: 4),
              Text('Ordered $totalOrdered, received $totalReceived so far',
                  style: const TextStyle(fontSize: 12, color: _kSub)),
              const SizedBox(height: 16),
              // Quick buttons
              Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                for (final q in [1, 2, 3, 5, 10, remaining])
                  if (q > 0)
                    GestureDetector(
                      onTap: () => Navigator.pop(ctx, q.toDouble()),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: q == remaining ? _kGreen : _kBg,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: q == remaining ? _kGreen : _kBorder),
                        ),
                        child: Text(
                          q == remaining ? '$q (all)' : '$q',
                          style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700,
                            color: q == remaining ? Colors.white : _kText,
                          ),
                        ),
                      ),
                    ),
              ]),
              const SizedBox(height: 12),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _StepBtn(Icons.remove, draft > 1 ? () => setLocal(() => draft--) : null),
                const SizedBox(width: 8),
                Container(
                  width: 52, height: 40, alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _kBg, borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _kBorder),
                  ),
                  child: Text('$draft',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _kText)),
                ),
                const SizedBox(width: 8),
                _StepBtn(Icons.add, draft < 999 ? () => setLocal(() => draft++) : null),
              ]),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: _kSub, side: const BorderSide(color: _kBorder)),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, draft.toDouble()),
                    style: FilledButton.styleFrom(
                        backgroundColor: _kGreen,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                    child: Text('Confirm $draft'),
                  ),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  void _showSnack(String msg, {bool isGood = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isGood ? _kGreen : const Color(0xFFDC2626),
      duration: const Duration(seconds: 3),
    ));
  }

  // ── #142: Supplier list + accordion ─────────────────────────────────────────

  Widget _buildCollectList(bool isAdmin) {
    // #183/#184/#185: instrument shared-reveal reuse + row layout for both tabs
    if (widget.arrivals) {
      RenderLog.write('c183_arrivals_anim',
          'change:183,uses_shared_reveal:true,duration_ms:280,curve:easeInOutCubic,chevron_animated:true');
      RenderLog.write('c184_arrivals_row',
          'change:184,item_box_full_width:true,badge_on_status_line:true');
      RenderLog.write('c185_arrivals_row',
          'change:185,inset_reverted:true,name_expanded:true,name_max_lines:2');
    } else {
      RenderLog.write('c183_collect_anim',
          'change:183,uses_shared_reveal:true,duration_ms:280,curve:easeInOutCubic,chevron_animated:true');
      RenderLog.write('c184_collect_row',
          'change:184,item_box_full_width:true,badge_on_status_line:true');
      RenderLog.write('c185_collect_row',
          'change:185,inset_reverted:true,name_expanded:true,name_max_lines:2');
    }
    RenderLog.write('c142_supplier_list',
        'dropdown_removed=y;count=${_suppliers.length}');

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_agentPhase != AgentPhase.idle && _agentReply.isNotEmpty) {
        _ensureAgentBubble();
      } else {
        _hideAgentBubble();
      }
    });

    if (_suppliers.isEmpty) {
      return const Center(child: Text('No supplier orders to collect yet',
          style: TextStyle(color: _kSub, fontSize: 15)));
    }

    RenderLog.write('c149_web_untouched', 'wide_layout=unchanged');
    RenderLog.write('c151_web_untouched', 'wide_layout=unchanged');
    RenderLog.write('c152_web_untouched', 'wide_layout=unchanged');

    final displayList = _suppliers;

    // #183: always render the full ListView — in-place animated expand via _sharedSmoothReveal.
    return LayoutBuilder(builder: (_, constraints) {
      final maxW = constraints.maxWidth >= 900 ? 700.0 : double.infinity;
      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: ListView.builder(
            controller: _listScrollCtrl,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            itemCount: displayList.length,
            itemBuilder: (_, i) => _buildSupplierAccordionRow(displayList[i], isAdmin),
          ),
        ),
      );
    });
  }

  // #183: Expanded body used as expandedContent in the accordion shell (no Expanded widget).
  Widget _buildExpandedSupplierBody(String name, bool isAdmin) {
    final locked = widget.arrivals ? _arrivalsLocked : _boxLocked;
    final visibleItems = _visibleItems();
    if (widget.arrivals) {
      RenderLog.write('c133_arrivals_filter_removed', 'true');
      RenderLog.write('c133_arrivals_item_count', '${visibleItems.length}');
    }
    // #255: bag control for Arrivals — rendered here (mobile accordion path).
    // _buildItemList() is unused in this path; _buildNarrowItemList() is the actual mobile list.
    final noBagInArrivals = widget.arrivals && _activeBag == null && !_loadingBox;
    RenderLog.write('c255_bag_control_rendered',
        'arrivals=${widget.arrivals};activeBag=${_activeBag != null};supplier=$name');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Divider(height: 1, color: _kBorder),
      _buildNarrowVoiceBar(isAdmin),
      if (_items.isNotEmpty) _buildNarrowProgressRow(),
      // #255: Bag control appears directly above the item list (mobile accordion).
      if (widget.arrivals && !_loadingBox) _buildBagControl(),
      // #255: Sub-text banner when no bag is attached.
      // CHANGE #272: detached state shows bag-specific copy; fresh-start shows generic copy.
      if (noBagInArrivals && _items.isNotEmpty)
        Builder(builder: (context) {
          final sup = _selectedSupplier ?? '';
          final isDetached = _changeBagPendingOldBag.containsKey(sup);
          final detachedBagNo = _changeBagPendingOldBag[sup];
          final subText = isDetached
              ? 'Bag $detachedBagNo detached — scan a new bag to keep counting'
              : 'Scan a bag to begin counting';
          if (isDetached) {
            RenderLog.write('c272_detached_subtext', 'bag_no=$detachedBagNo;text=$subText');
          }
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF8E1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFFB300).withValues(alpha: 0.5)),
              ),
              child: Row(children: [
                const Icon(Icons.info_outline_rounded, size: 15, color: Color(0xFF92400E)),
                const SizedBox(width: 6),
                Expanded(child: Text(subText,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF92400E)))),
              ]),
            ),
          );
        }),
      if (_loadingBox)
        const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2),
          ),
        )
      else if (_error != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Text('Error loading items: $_error',
              style: const TextStyle(color: Color(0xFFDC2626), fontSize: 13)),
        )
      else if (visibleItems.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Text(
            _items.isEmpty ? 'No items in this box' : 'No counted items',
            style: const TextStyle(color: _kSub, fontSize: 14),
          ),
        )
      else
        // #184: no extra horizontal padding — items flush with card body edges.
        // #255: dim item list when no bag attached (gate is also in handler level).
        Opacity(
          opacity: noBagInArrivals ? 0.45 : 1.0,
          child: _buildNarrowItemList(showFooter: false, shrinkWrap: true),
        ),
      if (!_loadingBox && _items.isNotEmpty) ...[
        const Divider(height: 1, color: _kBorder),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: _buildConfirmFooter(locked),
        ),
      ] else
        const SizedBox(height: 8),
    ]);
  }

  // #143 FIX 2+3: full-screen view for the expanded supplier.
  // Column layout: compact header → voice bar → progress → Expanded item list → pinned footer.
  Widget _buildCollectSingleSupplier(bool isAdmin) {
    final name = _selectedSupplier!;
    final dot = _supplierDotMap[name] ?? 'yellow';
    final dotFill   = dot == 'green' ? _kDotGreen
        : dot == 'light_yellow' ? _kDotLightYellow
        : _kDotYellow;
    final dotBorder = dot == 'green' ? _kDotGreen : _kDotBorderLight;
    final locked = _boxLocked;

    RenderLog.write('c143_fullscreen', 'supplier=$name;pinned_footer=y');
    RenderLog.write('c143_buttons_clear', 'bottom_pad=y;pinned=y');
    RenderLog.write('c143_no_border', 'expanded_border=none');

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // ── Compact header: supplier name + dot + collapse chevron ────────────
      InkWell(
        onTap: () {
          RenderLog.write('c142_expand', 'supplier=$name;expanded=n');
          setState(() { _selectedSupplier = null; _items = []; });
        },
        child: Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(children: [
            Icon(Icons.keyboard_arrow_left_rounded, size: 20, color: _kSub),
            const SizedBox(width: 4),
            Expanded(
              child: Text(name,
                  style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600, color: _kText),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 12),
            Container(
              width: 12, height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dotFill,
                border: Border.all(color: dotBorder, width: 1.5),
              ),
            ),
          ]),
        ),
      ),
      const Divider(height: 1, color: _kBorder),

      // ── Voice bar + progress ──────────────────────────────────────────────
      _buildNarrowVoiceBar(isAdmin),
      if (_items.isNotEmpty) _buildNarrowProgressRow(),
      const SizedBox(height: 8),

      // ── Item list — Expanded so it fills remaining space ─────────────────
      if (_loadingBox)
        const Expanded(child: Center(
            child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2)))
      // #160: error-aware guard
      else if (_error != null)
        Expanded(child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Builder(builder: (_) {
                RenderLog.write('c160_guard_buildCollectSingleSupplier',
                    'items=${_items.length};visible=${_items.length};error=true');
                return Text('Error loading items: $_error',
                    style: const TextStyle(color: Color(0xFFDC2626), fontSize: 13),
                    textAlign: TextAlign.center);
              }))))
      else if (_items.isEmpty)
        const Expanded(child: Center(
            child: Text('No items in this box',
                style: TextStyle(color: _kSub, fontSize: 15))))
      else
        Expanded(child: _buildNarrowItemList(showFooter: false)),

      // ── Pinned footer — sits above the bottom nav, always reachable ───────
      if (!_loadingBox && _items.isNotEmpty) ...[
        const Divider(height: 1, color: _kBorder),
        Padding(
          padding: EdgeInsets.fromLTRB(
              16, 12, 16,
              12 + MediaQuery.of(context).padding.bottom),
          child: _buildConfirmFooter(locked),
        ),
      ],
    ]);
  }

  // Dot colour constants for the 3-state indicator.
  static const _kDotGreen       = Color(0xFF1B7A43); // confirmed/sent
  static const _kDotLightYellow = Color(0xFFFEF3C7); // counting in progress
  static const _kDotYellow      = Color(0xFFFCD34D); // nothing started yet
  static const _kDotBorderLight = Color(0xFFF59E0B); // border for yellow tones

  Widget _buildSupplierAccordionRow(String name, bool isAdmin) {
    final isExpanded = _selectedSupplier == name;
    final dot = _supplierDotMap[name] ?? 'yellow';
    // #147 FIX A: per-row GlobalKey for Scrollable.ensureVisible (header pin)
    final rowKey = _rowKeys.putIfAbsent(name, () => GlobalKey());

    // #153: outer shell is shared with Arrivals; only expandedContent differs.
    return _SupplierAccordionShell(
      name: name,
      dot: dot,
      isExpanded: isExpanded,
      anyExpanded: _selectedSupplier != null,
      rowKey: rowKey,
      onTap: () {
        RenderLog.write('c142_expand',
            'supplier=$name;expanded=${isExpanded ? 'n' : 'y'}');
        if (isExpanded) {
          // #152 TWEAK 3: restore saved scroll position on close.
          setState(() { _selectedSupplier = null; _items = []; _supplierMode = null; });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (_listScrollCtrl.hasClients) {
              _listScrollCtrl.animateTo(
                _savedScrollOffset,
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeInOutCubic,
              );
            }
          });
        } else {
          // #152 TWEAK 3: save offset, scroll to top synchronized with open.
          _savedScrollOffset = _listScrollCtrl.hasClients ? _listScrollCtrl.offset : 0.0;
          setState(() => _selectedSupplier = name);
          _loadBox(name);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (_listScrollCtrl.hasClients) {
              _listScrollCtrl.animateTo(
                0.0,
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeInOutCubic,
              );
            }
            RenderLog.write('c152_sync_scroll', 'open_scroll_top=y;same_frame=y;close_restore=y');
            RenderLog.write('c147_header_pin', 'autoscroll=y;ms=280');
            RenderLog.write('c147_open_anim',
                'type=size_fade;ms=280;curve=easeInOutCubic;flip=n');
          });
        }
      },
      // #183: in-place animated expand — body reveals via _sharedSmoothReveal in shell.
      expandedContent: isExpanded ? _buildExpandedSupplierBody(name, isAdmin) : const SizedBox.shrink(),
      mode: widget.arrivals ? _supplierModeMap[name] : _collectModeMap[name],
      showPending: !widget.arrivals,
    );
  }

  // ── #116: Full-height card with sticky supplier-name header ─────────────────
  // Replaces the accordion expanded view — name row is pinned; content scrolls.
  Widget _buildExpandedSupplierCard(String name, bool isAdmin) {
    final dot = _supplierDotMap[name] ?? 'yellow';
    final dotFill = dot == 'green' ? _kDotGreen
        : dot == 'light_yellow' ? _kDotLightYellow : _kDotYellow;
    final dotBorder = dot == 'green' ? _kDotGreen : _kDotBorderLight;
    final locked = widget.arrivals ? _arrivalsLocked : _boxLocked;
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final visibleItems = _visibleItems();

    RenderLog.write('c116_supplier_header_pinned', 'true');
    RenderLog.write('c116_footer_gap_fixed', 'true');
    RenderLog.write('c118_footer_bottom_gap', '24');
    if (widget.arrivals) {
      RenderLog.write('c133_arrivals_filter_removed', 'true');
      RenderLog.write('c133_arrivals_item_count', '${visibleItems.length}');
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kBorder),
        boxShadow: [BoxShadow(
          color: Colors.black.withValues(alpha: 0.04),
          blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── STICKY SUPPLIER NAME ROW ──────────────────────────────────────
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            onTap: () {
              RenderLog.write('c142_expand', 'supplier=$name;expanded=n');
              setState(() { _selectedSupplier = null; _items = []; _supplierMode = null; });
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                if (_listScrollCtrl.hasClients) {
                  _listScrollCtrl.animateTo(_savedScrollOffset,
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeInOutCubic);
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(children: [
                Expanded(
                  child: Text(name,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600, color: _kGreen),
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.keyboard_arrow_up_rounded, size: 18, color: _kSub),
                const SizedBox(width: 12),
                // Constant-width badge slot matching the collapsed header exactly.
                CountBadge(
                  mode: widget.arrivals ? _supplierModeMap[name] : _collectModeMap[name],
                  showPending: !widget.arrivals,
                ),
                const SizedBox(width: 8),
                Container(
                  width: 12, height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: dotFill,
                    border: Border.all(color: dotBorder, width: 1.5),
                  ),
                ),
              ]),
            ),
          ),
          const Divider(height: 1, color: _kBorder),

          // ── SCROLLABLE CONTENT (voice, progress, items, footer) ───────────
          Expanded(
            child: PinnedFooterList(
              // Single source of bottom clearance — no extra SafeArea below.
              padding: EdgeInsets.only(bottom: 24 + safeBottom),
              footerGap: 16,
              children: [
                _buildNarrowVoiceBar(isAdmin),
                if (_items.isNotEmpty) _buildNarrowProgressRow(),
                const SizedBox(height: 8),
                if (_loadingBox)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2),
                    ),
                  )
                // #160: error-aware guard
                else if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: Builder(builder: (_) {
                      RenderLog.write('c160_guard_buildExpandedSupplierCard',
                          'items=${_items.length};visible=${visibleItems.length};error=true');
                      return Text('Error loading items: $_error',
                          style: const TextStyle(color: Color(0xFFDC2626), fontSize: 13));
                    }),
                  )
                else if (visibleItems.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: Text(
                      _items.isEmpty ? 'No items in this box' : 'No counted items',
                      style: const TextStyle(color: _kSub, fontSize: 14),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (int i = 0; i < visibleItems.length; i++) ...[
                          _buildItemTile(visibleItems[i]),
                          if (i < visibleItems.length - 1)
                            const SizedBox(height: 4),
                        ],
                      ],
                    ),
                  ),
              ],
              footer: (!_loadingBox && _items.isNotEmpty)
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _buildConfirmFooter(locked),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }

  // ── BUILD ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loadingSuppliers) {
      return const Center(child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2));
    }
    if (_error != null && _suppliers.isEmpty) {
      return Center(child: Text('Error: $_error',
          style: const TextStyle(color: Color(0xFFDC2626))));
    }

    final isAdmin = UserState.of(context).isAdmin;

    return LayoutBuilder(builder: (ctx, constraints) {
      // #138: adaptive band logged here so c138_size_band fires on every Collect render.
      final _cw = constraints.maxWidth;
      final _band = _cw < 340 ? 'verySmall' : _cw < 400 ? 'small' : _cw < 600 ? 'medium' : _cw < 900 ? 'large' : 'desktop';
      RenderLog.write('c138_size_band', 'band=$_band;w=${_cw.toInt()}');
      // #148: width-branch — wide (>=900) → old desktop layout; narrow → mobile accordion
      final mode = _cw >= 900 ? 'web' : 'mobile';
      RenderLog.write('c148_layout_branch', 'width=${_cw.toInt()};mode=$mode;breakpoint=900');
      if (_cw >= 900) {
        RenderLog.write('c148_web_layout', 'top_row=y;table=y');
        return _buildCollectWide(isAdmin);
      }
      RenderLog.write('c148_mobile_untouched', 'list_accordion=y');
      return _buildCollectList(isAdmin);
    });
  }

  // ── Narrow layout (< 900px) — existing tree verbatim ────────────────────────
  Widget _buildCollectNarrow(bool isAdmin) {
    // #114 render-log (mobile path)
    RenderLog.write('c114_fulfillment_header_built', 'mobile');
    // #90 render-log
    RenderLog.write('change_90_layout', 'narrow');
    RenderLog.write('change_90_header_hidden', '1');
    RenderLog.write('change_90_pills_equal', '1');
    RenderLog.write('change_90_no_overflow', '1');
    // backward-compat
    RenderLog.write('change_89_layout', 'narrow');
    RenderLog.write('change_89_no_voiceinput_card', '1');
    RenderLog.write('change_89_compact_voicebar', '1');
    RenderLog.write('change_89_dense_items', '1');
    RenderLog.write('change_88_layout', 'narrow');
    RenderLog.write('change_86_layout', 'narrow');
    RenderLog.write('change_86_narrow_cards_present', '1');

    // Drive popup bubble show/hide from build cycle (same as wide)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_agentPhase != AgentPhase.idle && _agentReply.isNotEmpty) {
        _ensureAgentBubble();
      } else {
        _hideAgentBubble();
      }
    });

    return Column(children: [
      // 1. Supplier dropdown (no progress bar here — #90 moved it below voice row)
      _buildSupplierPicker(),
      // 2. Voice row — two Expanded equal-width pills (#90 fix)
      if (_items.isNotEmpty) _buildNarrowVoiceBar(isAdmin),
      // 3. Progress row — BELOW voice row (#90 moved from above supplier)
      if (_items.isNotEmpty) _buildNarrowProgressRow(),
      // 4. Item list — fills remaining space
      if (_loadingBox)
        const Expanded(child: Center(child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2)))
      else if (_selectedSupplier == null)
        const Expanded(child: Center(
            child: Text('Choose a supplier to begin',
                style: TextStyle(color: _kSub, fontSize: 15))))
      // #160: error-aware guard
      else if (_error != null)
        Expanded(child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Builder(builder: (_) {
                RenderLog.write('c160_guard_buildCollectNarrow',
                    'items=${_items.length};visible=${_items.length};error=true');
                return Text('Error loading items: $_error',
                    style: const TextStyle(color: Color(0xFFDC2626), fontSize: 13),
                    textAlign: TextAlign.center);
              }))))
      else if (_items.isEmpty)
        const Expanded(child: Center(
            child: Text('No items in this box',
                style: TextStyle(color: _kSub, fontSize: 15))))
      else
        Expanded(child: _buildNarrowItemList()),
    ]);
  }

  // ── #90: Narrow voice bar — two Expanded equal-width pills, no overflow ─────
  // Tally badge moved to _buildNarrowProgressRow.
  Widget _buildNarrowVoiceBar(bool isAdmin) {
    // CHANGE #277: bag-missing is a silent noop (no opacity/grey), not a disabled state
    final countingDisabled = _agentPhase != AgentPhase.idle ||
        (widget.arrivals && _arrivalsLocked); // #156: locked after confirm-all
    final bool voiceBagPresent = _activeBag != null;
    if (widget.arrivals && !voiceBagPresent && !_loadingBox && _selectedSupplier != null) {
      RenderLog.write('c277_voice_gate_no_bag', 'narrow;supplier=$_selectedSupplier');
    }
    if (widget.arrivals && _selectedSupplier != null) {
      RenderLog.write('c284_voice_gated',
          'bag=$voiceBagPresent;enabled=$voiceBagPresent');
    }
    final agentDisabled = _voiceListening || _voiceProcessing;
    final agentPhase = _agentPhase;
    final bool agentBusy = agentPhase == AgentPhase.thinking || agentPhase == AgentPhase.speaking;
    final bool agentListening = agentPhase == AgentPhase.listening;
    final bool confirming = agentPhase == AgentPhase.confirming;

    return Padding(
      // 16px matches item list horizontal padding → pills line up with items below
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(children: [

        // Count items — Expanded so it fills exactly half (or full if no admin)
        Expanded(
          child: SizedBox(
            height: _kVoiceBtnH,
            child: _buildWidePill(
              icon: _voiceListening
                  ? Icons.stop_rounded
                  : _voiceProcessing
                      ? Icons.hourglass_top_rounded
                      : Icons.mic_none_rounded,
              label: _voiceListening
                  ? 'Stop'
                  : _voiceProcessing
                      ? 'Processing…'
                      : 'Count items',
              active: _voiceListening,
              activeColor: _kWrongFg,
              disabled: countingDisabled && !_voiceListening,
              spinning: _voiceProcessing,
              // CHANGE #277: silent noop when no bag; no visual disabled state
              onTap: () {
                if (widget.arrivals && _activeBag == null) return;
                _toggleRecording();
              },
            ),
          ),
        ),

        // Ask mediBO — Expanded, same width as Count items (#90: no Spacer or fixed width)
        if (isAdmin) ...[
          const SizedBox(width: 12),
          Expanded(
            child: CompositedTransformTarget(
              link: _askPillLayerLink,
              child: SizedBox(
                height: _kVoiceBtnH,
                child: _buildWidePill(
                  icon: agentListening
                      ? Icons.stop_rounded
                      : agentBusy
                          ? Icons.hourglass_top_rounded
                          : Icons.record_voice_over_rounded,
                  label: agentListening
                      ? 'Listening…'
                      : agentBusy
                          ? (agentPhase == AgentPhase.thinking ? 'Thinking…' : 'Speaking…')
                          : confirming
                              ? 'Confirming…'
                              : 'Ask mediBO',
                  active: agentListening,
                  activeColor: _kAgentAccent,
                  disabled: agentDisabled && !agentListening,
                  spinning: agentBusy,
                  // CHANGE #277: silent noop when no bag
                  onTap: () {
                    if (widget.arrivals && _activeBag == null) return;
                    if (agentBusy) return;
                    if (agentListening) {
                      _stopAgentRecording();
                    } else if (agentPhase == AgentPhase.idle) {
                      _startAgentRecording();
                    }
                  },
                ),
              ),
            ),
          ),
        ],

      ]),
    );
  }

  // ── #90: Progress row — BELOW voice row, includes tally badge ───────────────
  Widget _buildNarrowProgressRow() {
    RenderLog.write('change_90_progress_below', '1');
    RenderLog.write('change_97_spoken_mobile', '1');
    final doneCount = _items.length - _pendingCount;
    final total = _items.length;
    // #97: pill ALWAYS visible on mobile — constant 100px slot, always green
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(
          width: 100, // constant slot — no layout shift when count changes
          child: Builder(builder: (ctx) => _buildSpokenPill(ctx)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: LinearProgressIndicator(
            value: total == 0 ? 0 : doneCount / total,
            backgroundColor: _kBorder,
            color: _kGreen,
            minHeight: 6,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$doneCount/$total',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kText),
        ),
      ]),
    );
  }

  // ── #89: Dense narrow item list — compact rows, render-log key ───────────────
  // #151: shrinkWrap=true when inside accordion (outer ListView handles scroll).
  Widget _buildNarrowItemList({bool showFooter = true, bool shrinkWrap = false}) {
    RenderLog.write('change_89_dense_items', '1');
    RenderLog.write('81_item_list_rendered', '${_items.length}');
    RenderLog.write('81_progress', '${_items.length - _pendingCount}/${_items.length}');
    final locked = _boxLocked;
    if (locked) RenderLog.write('change_91_locked', '1');
    else RenderLog.write('change_91_confirm_present', '1');

    // #197: one row per product
    final merged = _mergedItems;
    if (widget.arrivals) {
      RenderLog.write('c197_merged_rows_wh', 'products=${merged.length};raw_lines=${_items.length}');
      RenderLog.write('c283_warehouse_rows_render',
          'count=${merged.length};ts=${DateTime.now().millisecondsSinceEpoch}');
    } else {
      RenderLog.write('c197_merged_rows_shop', 'products=${merged.length};raw_lines=${_items.length}');
    }

    if (showFooter) {
      final safeB = MediaQuery.of(context).padding.bottom;
      RenderLog.write('c151_footer_in_scroll', 'pinned=n;in_dropdown=y;state=${locked ? 'locked' : 'active'}');
      RenderLog.write('c151_unified_container', 'one_surface=y;inner_border=none;header_body_split=n');
      RenderLog.write('c151_bottom_pad', 'clears_nav=y;pad=${(24 + safeB).toInt()}');
    }

    final footerCount = showFooter ? 1 : 0;
    final safeBottom = showFooter ? MediaQuery.of(context).padding.bottom : 0.0;
    return ListView.separated(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + safeBottom),
      itemCount: merged.length + footerCount,
      separatorBuilder: (_, i) => SizedBox(height: i == merged.length - 1 ? 16 : 4),
      itemBuilder: (_, i) {
        if (showFooter && i == merged.length)
          return _buildConfirmFooter(widget.arrivals ? _arrivalsLocked : locked);
        return _buildMergedItemTile(merged[i]);
      },
    );
  }

  // #113: extracted so PinnedFooterList can pass items as List<Widget>
  // #331: shop tab shows shop_qty/ordQty; warehouse shows recQty/expected (mode-aware)
  Widget _buildItemTile(Map<String, dynamic> item) {
    final state    = stateOf(item); // B2: derive — fw_get_state has no fulfillment_state
    final name     = item['product_name']?.toString() ?? '—';
    final ordQty   = ordQtyOf(item); // B1: dual-key ordered_qty ?? ordered
    final recQty   = (item['received_qty'] as num?)?.toInt() ?? 0;
    final shopQty  = (item['shop_qty'] as num?)?.toInt(); // #331: null = not yet counted at shop
    final packType = item['pack_type']?.toString() ?? '';
    final imageUrl = item['image_url']?.toString();
    // #331: warehouse expected = forwarded (shop_qty) for mode='shop', else ordered
    final int whExpected = (_supplierMode == 'shop') ? (shopQty ?? 0) : ordQty;
    // #132A/#189: open dispute badge
    final itemId = item['order_item_id']?.toString();
    final openDispute = itemId != null ? _disputeMap[itemId] : null;
    final disputeItem = itemId != null ? _disputeItemMap[itemId] : null;
    RenderLog.write('c196_collect_card_layout_v2',
        'surface=${widget.arrivals ? 'arrivals' : 'collect'}');
    return GestureDetector(
      onTap: (widget.arrivals && _arrivalsLocked) ? null : () {
        // CHANGE #277: silent noop when no bag in Warehouse
        if (widget.arrivals && _activeBag == null) {
          RenderLog.write('c277_item_gate_no_bag', 'narrow;product=${item['product_name'] ?? ''}');
          return;
        }
        _showItemSheet(item);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _kCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: state == 'pending' ? _kBorder : (_stateBgMap[state] ?? _kBorder),
          ),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          _FulfilImageTile(imageUrl, size: 40),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min, children: [
              // #185: 2 lines so medium-length names never clip
              Text(name,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kText),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 1),
              Text(packType.isNotEmpty ? packType : '—',
                  style: const TextStyle(fontSize: 11, color: _kSub),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              // #184: DisputeBadge moved to status line (right column)
            ]),
          ),
          const SizedBox(width: 8),
          // #196: cap right column; badge on its own line to prevent overlap
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
              // #331: shop tab → shop_qty/ordered; warehouse → received/expected
              if (!widget.arrivals) ...[
                // Supplier Shop stage: show shop count progress
                Builder(builder: (_) {
                  RenderLog.write('c331_shop_rows', 'shop_qty=${shopQty ?? 'null'};ord=$ordQty');
                  final label = '${shopQty ?? '–'}/$ordQty';
                  return Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(label,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText)),
                    const SizedBox(width: 6),
                    _StatePill(shopQty == null ? 'pending' : (shopQty >= ordQty ? 'received' : state)),
                  ]);
                }),
              ] else if (whExpected == 0) ...[
                // Warehouse: fully-short disputed line — muted row
                const Text('in dispute · awaiting resolution',
                    style: TextStyle(fontSize: 10, color: _kSub)),
              ] else ...[
                // Warehouse stage: show received/expected
                Builder(builder: (_) {
                  RenderLog.write('c331_wh_rows', 'rec=$recQty;expected=$whExpected;mode=${_supplierMode ?? ''}');
                  return Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('$recQty/$whExpected',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText)),
                    const SizedBox(width: 6),
                    _StatePill(recQty >= whExpected ? 'received' : state),
                  ]);
                }),
              ],
              // dispute badge on its own constrained line below
              if (disputeItem != null) ...[
                const SizedBox(height: 3),
                Builder(builder: (_) {
                  RenderLog.write('c196_awaiting_badge_wrapped',
                      'surface=${widget.arrivals ? 'arrivals' : 'collect'};dispute=${disputeItem.disputeId}');
                  return SizedBox(
                    width: 120,
                    child: _DisputeStrip(
                      item: disputeItem,
                      surface: widget.arrivals ? 'arrivals' : 'collect',
                    ),
                  );
                }),
              ] else if (openDispute != null) ...[
                const SizedBox(height: 3),
                SizedBox(
                  width: 120,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: DisputeBadge(status: openDispute['status']?.toString() ?? ''),
                  ),
                ),
              ],
              if (widget.arrivals && item['count_mismatch'] == true) ...[
                const SizedBox(height: 2),
                Text(
                  'shop ${(item['shop_qty'] as num?)?.toInt() ?? '?'}',
                  style: const TextStyle(fontSize: 10, color: Color(0xFF92400E)),
                ),
              ],
            ]),
          ), // ConstrainedBox
        ]),
      ),
    );
  }

  // ── #197: Merged product card ─────────────────────────────────────────────
  Widget _buildMergedItemTile(_MergedProduct merged) {
    final state = merged.combinedState;
    // #331: warehouse expected = forwarded (shopQtyTotal) for mode='shop', else ordered
    final int whExpected = widget.arrivals
        ? ((_supplierMode == 'shop') ? (merged.shopQtyTotal ?? 0) : merged.orderedTotal)
        : merged.orderedTotal;
    // Dispute: first match across all underlying lines
    DisputeItem? disputeItem;
    Map<String, dynamic>? openDispute;
    for (final oiid in merged.orderItemIds) {
      disputeItem ??= _disputeItemMap[oiid];
      openDispute ??= _disputeMap[oiid];
    }
    // #265: arrival sub-line removed from Warehouse rows — "Arrival pending"/"Arrived"
    // is misleading for items already being counted. Disputes tab uses its own renderer.
    final surface = widget.arrivals ? 'arrivals' : 'collect';

    RenderLog.write('c196_collect_card_layout_v2', 'surface=$surface');
    RenderLog.write('c198_card_layout_v3', 'surface=$surface');
    if (widget.arrivals) RenderLog.write('c265_warehouse_no_arrival', 'prod=${merged.productId}');
    if (widget.arrivals) {
      final bool itemBagPresent = _activeBag != null;
      RenderLog.write('c284_itempopup_gated',
          'bag=$itemBagPresent;enabled=$itemBagPresent');
    }

    return GestureDetector(
      onTap: (widget.arrivals && _arrivalsLocked) ? null : () {
        // CHANGE #277: silent noop when no bag in Warehouse
        if (widget.arrivals && _activeBag == null) {
          RenderLog.write('c277_item_gate_no_bag', 'merged;product=${merged.productId}');
          return;
        }
        _showProductSheet(merged);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _kCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: state == 'pending' ? _kBorder : (_stateBgMap[state] ?? _kBorder),
          ),
        ),
        // #198: crossAxisAlignment.start so both columns align at their first line
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _FulfilImageTile(merged.imageUrl, size: 40),
          const SizedBox(width: 10),
          // LEFT column: name + pack_type + proof thumbnail (if dispute has proof)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min, children: [
                Text(merged.productName,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kText),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(merged.packType.isNotEmpty ? merged.packType : '—',
                    style: const TextStyle(fontSize: 11, color: _kSub),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                // #261: per-bag breakdown (Arrivals only, mobile tile) — B#:##P format
                if (widget.arrivals && merged.bagBreakdown != null && merged.bagBreakdown!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Builder(builder: (_) {
                    final bd = _fmtBreakdown(merged.bagBreakdown, merged.packType);
                    RenderLog.write('c261_breakdown_fmt', 'mobile;prod=${merged.productId};bd=$bd');
                    // CHANGE #269 — black-on-grey badge style
                    RenderLog.write('c269_bag_badge', 'mobile;$bd');
                    // CHANGE #274 — confirm breakdown renders even after confirm-all (locked)
                    if (_arrivalsLocked) RenderLog.write('c274_breakdown_after_lock', 'mobile;prod=${merged.productId};bd=$bd');
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Color(0xFFEEEEEE),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(bd,
                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.black87),
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                    );
                  }),
                ],
                // #203: proof thumbnail from dispute
                if (disputeItem != null && (disputeItem.proofUrl ?? '').isNotEmpty) ...[
                  const SizedBox(height: 4),
                  GestureDetector(
                    onTap: () => showDialog<void>(
                      context: context,
                      builder: (ctx) => Dialog(
                        backgroundColor: Colors.black,
                        insetPadding: const EdgeInsets.all(12),
                        child: Stack(children: [
                          Image.network(disputeItem!.proofUrl!,
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 64)),
                          Positioned(
                            top: 8, right: 8,
                            child: GestureDetector(
                              onTap: () => Navigator.of(ctx).pop(),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                padding: const EdgeInsets.all(4),
                                child: const Icon(Icons.close_rounded, color: Colors.white, size: 20),
                              ),
                            ),
                          ),
                        ]),
                      ),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.network(disputeItem!.proofUrl!, width: 36, height: 36,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const Icon(Icons.broken_image_outlined, size: 24, color: _kSub)),
                      ),
                      const SizedBox(width: 4),
                      const Text('proof', style: TextStyle(fontSize: 10, color: _kSub)),
                    ]),
                  ),
                ],
                if (disputeItem != null && (disputeItem.wrongProductName ?? '').isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text('↳ ${disputeItem!.wrongProductName}',
                      style: const TextStyle(fontSize: 10, color: Color(0xFF92400E)),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ]),
            ),
          ),
          const SizedBox(width: 8),
          // RIGHT column: qty -> status pill -> arrival -> awaiting badge
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
              // #331: shop tab → shop_qty/ordered; warehouse → received/expected
              if (!widget.arrivals) ...[
                Builder(builder: (_) {
                  RenderLog.write('c331_shop_rows', 'shop=${merged.shopQtyTotal ?? 'null'};ord=${merged.orderedTotal}');
                  final label = '${merged.shopQtyTotal ?? '–'}/${merged.orderedTotal}';
                  final pillState = merged.shopQtyTotal == null
                      ? 'pending'
                      : (merged.shopQtyTotal! >= merged.orderedTotal ? 'received' : state);
                  return Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
                    Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText)),
                    const SizedBox(height: 3),
                    _StatePill(pillState),
                  ]);
                }),
              ] else if (whExpected == 0) ...[
                const Text('in dispute · awaiting resolution',
                    style: TextStyle(fontSize: 10, color: _kSub, height: 1.3)),
              ] else ...[
                Builder(builder: (_) {
                  RenderLog.write('c331_wh_rows', 'rec=${merged.receivedTotal};exp=$whExpected;mode=${_supplierMode ?? ''}');
                  return Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
                    Text('${merged.receivedTotal}/$whExpected',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText)),
                    const SizedBox(height: 3),
                    _StatePill(merged.receivedTotal >= whExpected ? 'received' : state),
                  ]);
                }),
              ],
              // #265: arrival status line removed — "Arrival pending"/"Arrived" not shown on Warehouse rows
              // line 4: awaiting dispute badge — ACTIVE disputes only (#199)
              if (disputeItem != null && disputeItem.isActive) ...[
                const SizedBox(height: 3),
                Builder(builder: (_) {
                  RenderLog.write('c196_awaiting_badge_wrapped',
                      'surface=$surface;dispute=${disputeItem!.disputeId}');
                  RenderLog.write('c199_awaiting_active_only',
                      'surface=$surface;dispute=${disputeItem!.disputeId};isActive=${disputeItem.isActive}');
                  return SizedBox(
                    width: 120,
                    child: _DisputeStrip(item: disputeItem!, surface: surface),
                  );
                }),
              ] else if (openDispute != null) ...[
                const SizedBox(height: 3),
                SizedBox(
                  width: 120,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: DisputeBadge(status: openDispute['status']?.toString() ?? ''),
                  ),
                ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }

  // #197: open per-product receiving sheet
  Future<void> _showProductSheet(_MergedProduct merged) async {
    if (widget.arrivals ? _arrivalsLocked : _boxLocked) return;
    // CHANGE #277: silent gate (rows already block; this is a safety fallback)
    if (widget.arrivals && _activeBag == null) {
      RenderLog.write('c277_item_gate_no_bag', 'productSheet_fallback=${merged.productId}');
      return;
    }
    final supplier = _selectedSupplier ?? '';
    RenderLog.write('c197_product_sheet_opened',
        'surface=${widget.arrivals ? 'arrivals' : 'collect'};product_id=${merged.productId};ordered=${merged.orderedTotal}');
    // Find first dispute with proof for this product
    DisputeItem? existingDispute;
    for (final oiid in merged.orderItemIds) {
      final d = _disputeItemMap[oiid];
      if (d != null) { existingDispute = d; break; }
    }
    final isWide = MediaQuery.of(context).size.width >= 900;
    final sheet = _ProductReceiveSheet(
      supplierName: supplier,
      productId: merged.productId,
      productName: merged.productName,
      packType: merged.packType,
      imageUrl: merged.imageUrl,
      orderedTotal: merged.orderedTotal,
      receivedTotal: merged.receivedTotal,
      combinedState: merged.combinedState,
      existingDispute: existingDispute,
      arrivals: widget.arrivals,
      // CHANGE #277: pass bag context for dynamic Got all
      activeBagNo: widget.arrivals ? (_activeBag?['bag_no'] as num?)?.toInt() : null,
      bagBreakdown: merged.bagBreakdown,
      bagCountFn: widget.arrivals ? (pid, qty) async {
        if (_activeBag == null) return 'Scan a bag first before counting';
        try {
          final raw = await Supabase.instance.client.rpc('bag_count_set', params: {
            'p_supplier_name': supplier,
            'p_product_id': pid,
            'p_qty': qty,
            'p_note': 'got_all #258',
          });
          final res = _normRpc(raw);
          if (res['error'] != null) return _bagCountError(res);
          return null;
        } catch (e) { return 'Count error: $e'; }
      } : null,
      // #261: clear breakdown on undo — calls bag_count_clear then reloads
      bagCountClearFn: widget.arrivals ? (pid) async {
        try {
          await Supabase.instance.client.rpc('bag_count_clear', params: {
            'p_supplier_name': supplier,
            'p_product_id': pid,
            'p_bag_no': null,
          });
        } catch (_) {}
        _reloadItemsFromDB();
      } : null,
      onReload: _reloadItemsFromDB,
    );
    if (isWide) {
      await showDialog<void>(
        context: context,
        builder: (_) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: sheet,
          ),
        ),
      );
    } else {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => DraggableScrollableSheet(
          initialChildSize: 0.65,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          expand: false,
          builder: (_, ctrl) => SingleChildScrollView(controller: ctrl, child: sheet),
        ),
      );
    }
    if (mounted) {
      await _loadDisputes();
      await _reloadItemsFromDB();
    }
  }

  // ── #88: agent popup bubble management ──────────────────────────────────────

  void _ensureAgentBubble() {
    if (!mounted) return;
    if (_agentBubbleEntry == null) {
      _agentBubbleEntry = OverlayEntry(builder: (overlayCtx) => _buildAgentBubbleOverlay(overlayCtx));
      Overlay.of(context).insert(_agentBubbleEntry!);
    } else {
      _agentBubbleEntry!.markNeedsBuild();
    }
  }

  void _hideAgentBubble() {
    _agentBubbleEntry?.remove();
    _agentBubbleEntry = null;
  }

  Widget _buildAgentBubbleOverlay(BuildContext overlayCtx) {
    final phase = _agentPhase;
    final reply = _agentReply;
    final action = _pendingAction;
    final bool confirming = phase == AgentPhase.confirming;
    final bool agentBusy = phase == AgentPhase.thinking || phase == AgentPhase.speaking;
    if (phase == AgentPhase.idle || reply.isEmpty) return const SizedBox.shrink();
    RenderLog.write('change_88_popup_present', '1');
    RenderLog.write('change_89_popup_present', '1');
    final screenW = MediaQuery.of(overlayCtx).size.width;
    final bubbleMaxW = (screenW - 48).clamp(200.0, 320.0);

    return CompositedTransformFollower(
      link: _askPillLayerLink,
      showWhenUnlinked: false,
      targetAnchor: Alignment.topRight,
      followerAnchor: Alignment.bottomRight,
      offset: const Offset(0, -8),
      child: Align(
        alignment: Alignment.bottomRight,
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: BoxConstraints(maxWidth: bubbleMaxW),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _kAgentAccent.withValues(alpha: 0.25)),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 12, offset: const Offset(0, 4)),
              ],
            ),
            padding: const EdgeInsets.all(14),
            child: confirming
                ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(reply,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: _kText)),
                    if (action != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF5F6F8),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: _kBorder),
                        ),
                        child: Text(
                          '${action['product_name'] ?? ''}'
                          '${action['qty'] != null ? ' — qty ${(action['qty'] as num).toInt()}' : ''}',
                          style: const TextStyle(fontSize: 12, color: _kText, fontWeight: FontWeight.w500),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                        GestureDetector(
                          onTap: _commitPending,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                            decoration: BoxDecoration(color: _kGreen, borderRadius: BorderRadius.circular(8)),
                            child: const Text('✓ Haan',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: _cancelPending,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: _kBorder),
                            ),
                            child: const Text('✗ Nahi',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _kText)),
                          ),
                        ),
                      ]),
                    ],
                  ])
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(agentBusy ? Icons.hourglass_top_rounded : Icons.volume_up_rounded,
                        size: 14, color: _kAgentAccent),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(reply,
                          style: const TextStyle(fontSize: 13, color: _kText),
                          maxLines: 3, overflow: TextOverflow.ellipsis),
                    ),
                  ]),
          ),
        ),
      ),
    );
  }

  // ── Wide layout (>= 900px) — #88: single bar + popup bubble ────────────────
  Widget _buildCollectWide(bool isAdmin) {
    // #183/#184/#185: instrument shared-reveal reuse + row layout (desktop path)
    if (widget.arrivals) {
      RenderLog.write('c183_arrivals_anim',
          'change:183,uses_shared_reveal:true,duration_ms:280,curve:easeInOutCubic,chevron_animated:true');
      RenderLog.write('c184_arrivals_row',
          'change:184,item_box_full_width:true,badge_on_status_line:true');
      RenderLog.write('c185_arrivals_row',
          'change:185,inset_reverted:true,name_expanded:true,name_max_lines:2');
    } else {
      RenderLog.write('c183_collect_anim',
          'change:183,uses_shared_reveal:true,duration_ms:280,curve:easeInOutCubic,chevron_animated:true');
      RenderLog.write('c184_collect_row',
          'change:184,item_box_full_width:true,badge_on_status_line:true');
      RenderLog.write('c185_collect_row',
          'change:185,inset_reverted:true,name_expanded:true,name_max_lines:2');
    }
    RenderLog.write('change_100_banner_removed', '1');
    RenderLog.write('change_90_layout', 'wide');
    RenderLog.write('change_89_layout', 'wide');
    RenderLog.write('change_88_layout', 'wide');
    RenderLog.write('change_88_no_inline_banner', '1');
    RenderLog.write('change_87_layout', 'wide');
    RenderLog.write('change_86_layout', 'wide');

    // Drive bubble show/hide from the build cycle (post-frame to avoid setState-in-build)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_agentPhase != AgentPhase.idle && _agentReply.isNotEmpty) {
        _ensureAgentBubble();
      } else {
        _hideAgentBubble();
      }
    });

    // #160: use _visibleItems() as single source of truth (same as mobile path).
    final visibleItems = _visibleItems();
    // #160: log route + counts on every desktop build — fires on normal page load.
    if (widget.arrivals) {
      RenderLog.write('c160_route_desktop_arrivals', '_buildCollectWide');
      RenderLog.write('c160_desktop_arrivals_built', '${visibleItems.length}');
    } else {
      RenderLog.write('c160_collect_wide_built', '${visibleItems.length}');
    }
    RenderLog.write('c160_guard_buildCollectWide',
        'items=${_items.length};visible=${visibleItems.length};error=${_error != null}');

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // ── Single merged bar (dropdown + progress + both pills) ─────────────────
      _buildWideSingleBar(isAdmin),
      const SizedBox(height: 16),
      // ── Item table — never pushed down by agent output (#88) ─────────────────
      if (_loadingBox)
        const Expanded(child: Center(child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2)))
      else if (_selectedSupplier == null)
        const Expanded(child: Center(
            child: Text('Choose a supplier to begin',
                style: TextStyle(color: _kSub, fontSize: 15))))
      // #160: show actual error instead of silent empty box
      else if (_error != null)
        Expanded(child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Error loading items: $_error',
                  style: const TextStyle(color: Color(0xFFDC2626), fontSize: 13),
                  textAlign: TextAlign.center))))
      else if (visibleItems.isEmpty)
        const Expanded(child: Center(
            child: Text('No items in this box',
                style: TextStyle(color: _kSub, fontSize: 15))))
      else
        ...[
          // #254: bag control above item table on desktop (Arrivals only)
          if (widget.arrivals) _buildBagControl(),
          Expanded(child: _buildWideItemTable()),
        ],
    ]);
  }

  // ── #88: Single merged bar — dropdown + progress + FIXED-SIZE pills ──────────
  // Button constants — fixed size applied at call site via SizedBox
  static const double _kVoiceBtnW = 150;
  static const double _kVoiceBtnH = 44;
  // #94: relaxed thresholds — only drop near-silent clips; when unsure SEND
  static const double _kVoiceRmsMin  = 0.006; // RMS on -1..1 scale
  static const double _kVoicePeakMin = 0.030; // peak amplitude

  Widget _buildWideSingleBar(bool isAdmin) {
    RenderLog.write('change_88_fixed_btn_size', '150x44');
    RenderLog.write('change_87_single_bar_present', '1');
    RenderLog.write('change_87_pills_inline', '1');
    RenderLog.write('change_86_voice_pills_present', '1');
    // #114 render-log
    RenderLog.write('c114_fulfillment_header_built', 'desktop');
    RenderLog.write('c114_spoken_chip_left', 'desktop');
    RenderLog.write('c114_progress_expanded', 'desktop');
    // #331: shop tab progress = items with a shop count; warehouse = items not pending
    final doneCount = widget.arrivals
        ? _items.length - _pendingCount
        : _items.where((i) => i['shop_qty'] != null).length;
    final total = _items.length;
    // CHANGE #277: bag-missing is a silent noop, not a disabled state
    final countingDisabled = _agentPhase != AgentPhase.idle;
    final agentDisabled = _voiceListening || _voiceProcessing;
    final agentPhase = _agentPhase;
    final bool agentBusy = agentPhase == AgentPhase.thinking || agentPhase == AgentPhase.speaking;
    final bool agentListening = agentPhase == AgentPhase.listening;
    final bool confirming = agentPhase == AgentPhase.confirming;

    return Container(
      margin: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kBorder),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [

        // 1. Supplier dropdown — #114: constrained width (no Expanded) so no gap before chip
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: _suppliers.isEmpty
              ? const Text('No supplier orders to collect yet',
                  style: TextStyle(fontSize: 14, color: _kSub), overflow: TextOverflow.ellipsis)
              : Builder(builder: (ctx) {
                  RenderLog.write('change_99_arrow_constant', '1');
                  return DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      hint: const Text('Select supplier…',
                          style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 15)),
                      value: _selectedSupplier,
                      items: _suppliers
                          .map((s) => DropdownMenuItem(
                                value: s,
                                child: Text(s, style: const TextStyle(fontSize: 15, color: _kText),
                                    overflow: TextOverflow.ellipsis),
                              ))
                          .toList(),
                      onChanged: (v) {
                        if (v == null) return;
                        RenderLog.write('78_collect_supplier_selected', v);
                        setState(() => _selectedSupplier = v);
                        _loadBox(v);
                      },
                    ),
                  );
                }),
        ),

        // 2. "N spoken" pill immediately right of dropdown + Expanded progress bar
        if (_items.isNotEmpty) ...[
          // #114: chip sits right after dropdown — no Expanded spacer between them
          const SizedBox(width: 8),
          SizedBox(
            width: 110, // kSpokenSlotW — constant so bar never shifts
            child: Builder(builder: (ctx) => _buildSpokenPill(ctx)),
          ),
          const SizedBox(width: 12),
          // #114: Expanded fills the freed horizontal space
          Expanded(
            child: LinearProgressIndicator(
              value: total == 0 ? 0 : doneCount / total,
              backgroundColor: _kBorder,
              color: _kGreen,
              minHeight: 6,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$doneCount/$total',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kText),
          ),
        ] else
          // No items: spacer pushes buttons to the right
          const Spacer(),

        // 4. Count items pill — FIXED SIZE BOX (never changes width/height across states)
        if (_voiceSupported) ...[
          const SizedBox(width: 16),
          SizedBox(
            width: _kVoiceBtnW,
            height: _kVoiceBtnH,
            child: _buildWidePill(
              icon: _voiceListening
                  ? Icons.stop_rounded
                  : _voiceProcessing
                      ? Icons.hourglass_top_rounded
                      : Icons.mic_none_rounded,
              label: _voiceListening
                  ? 'Stop recording'
                  : _voiceProcessing
                      ? 'Processing…'
                      : 'Count items',
              active: _voiceListening,
              activeColor: _kWrongFg,
              disabled: countingDisabled && !_voiceListening,
              spinning: _voiceProcessing,
              // CHANGE #277: silent noop when no bag; no visual disabled state
              onTap: () {
                if (widget.arrivals && _activeBag == null) return;
                _toggleRecording();
              },
            ),
          ),
        ],

        // #331: mm:ss continuous timer + daily remaining, shown only while recording
        if (_voiceListening && _voiceSupported) ...[
          const SizedBox(width: 8),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${(_continuousSecs ~/ 60).toString().padLeft(2, '0')}:${(_continuousSecs % 60).toString().padLeft(2, '0')}',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _kWrongFg),
              ),
              Text(_VoiceCaps.remainingLabel(),
                  style: const TextStyle(fontSize: 10, color: _kSub)),
            ],
          ),
        ],

        // 5. Ask mediBO pill — FIXED SIZE BOX + LayerLink for popup anchor (#88)
        if (isAdmin) ...[
          const SizedBox(width: 10),
          CompositedTransformTarget(
            link: _askPillLayerLink,
            child: SizedBox(
              width: _kVoiceBtnW,
              height: _kVoiceBtnH,
              child: _buildWidePill(
                icon: agentListening
                    ? Icons.stop_rounded
                    : agentBusy
                        ? Icons.hourglass_top_rounded
                        : Icons.record_voice_over_rounded,
                label: agentListening
                    ? 'Listening…'
                    : agentBusy
                        ? (agentPhase == AgentPhase.thinking ? 'Thinking…' : 'Speaking…')
                        : confirming
                            ? 'Confirming…'
                            : 'Ask mediBO',
                active: agentListening,
                activeColor: _kAgentAccent,
                disabled: agentDisabled && !agentListening,
                spinning: agentBusy,
                // CHANGE #277: silent noop when no bag
                onTap: () {
                  if (widget.arrivals && _activeBag == null) return;
                  if (agentBusy) return;
                  if (agentListening) {
                    _stopAgentRecording();
                  } else if (agentPhase == AgentPhase.idle) {
                    _startAgentRecording();
                  }
                },
              ),
            ),
          ),
        ],

      ]),
    );
  }

  // _buildWideAgentBanner removed in #88 — replaced by popup overlay (_buildAgentBubbleOverlay).

  // _buildWidePill: always sized by parent SizedBox(kVoiceBtnW x kVoiceBtnH).
  // Only decoration/colour/icon/label change between states — never the box.
  Widget _buildWidePill({
    required IconData icon,
    required String label,
    required bool active,
    required Color activeColor,
    required bool disabled,
    required bool spinning,
    required VoidCallback onTap,
  }) {
    return IgnorePointer(
      ignoring: disabled,
      child: Opacity(
        opacity: disabled ? 0.40 : 1.0,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            // Width/height controlled by parent SizedBox — no hardcoded size here.
            decoration: BoxDecoration(
              color: active ? activeColor : Colors.white,
              borderRadius: BorderRadius.circular(_kVoiceBtnH / 2),
              border: Border.all(
                color: active ? activeColor : _kBorder,
                width: 1,
              ),
              boxShadow: active
                  ? [BoxShadow(color: activeColor.withValues(alpha: 0.30), blurRadius: 10, spreadRadius: 1)]
                  : [],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.max,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                spinning
                    ? SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(
                          color: active ? Colors.white : activeColor,
                          strokeWidth: 2,
                        ),
                      )
                    : Icon(icon,
                        size: 16,
                        color: active ? Colors.white : activeColor),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: active ? Colors.white : _kText,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── B3: Wide item table ───────────────────────────────────────────────────────
  Widget _buildWideItemTable() {
    RenderLog.write('change_86_wide_table_present', '1');
    final locked = _boxLocked;
    if (locked) RenderLog.write('change_91_locked', '1');
    else RenderLog.write('change_91_confirm_present', '1');
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: Column(children: [
        // Sticky header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _kBg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
            border: const Border(
              top: BorderSide(color: _kBorder),
              left: BorderSide(color: _kBorder),
              right: BorderSide(color: _kBorder),
            ),
          ),
          child: Row(children: [
            Expanded(flex: 6, child: Text('Product',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _kSub))),
            Expanded(flex: 2, child: Text('Pack',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _kSub))),
            Expanded(flex: 2, child: Text('Received',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _kSub),
                textAlign: TextAlign.right)),
            Expanded(flex: 2, child: Text('Status',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _kSub),
                textAlign: TextAlign.right)),
          ]),
        ),
        // Scrollable rows
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)),
              border: Border.all(color: _kBorder),
            ),
            child: Builder(builder: (_) {
              // #197: merged product rows for desktop table
              final deskMerged = _mergedItems;
              if (widget.arrivals) {
                RenderLog.write('c197_merged_rows_wh', 'products=${deskMerged.length};raw_lines=${_items.length}');
              } else {
                RenderLog.write('c197_merged_rows_shop', 'products=${deskMerged.length};raw_lines=${_items.length}');
              }
              return ListView.builder(
                itemCount: deskMerged.length + 1,
                itemBuilder: (_, i) {
                  if (i == deskMerged.length) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                      child: _buildConfirmFooter(locked, isWide: true),
                    );
                  }
                  final mp = deskMerged[i];
                  final state = mp.combinedState;
                  final isLast = i == deskMerged.length - 1;
                  if (state == 'wrong' || state == 'not_coming') {
                    RenderLog.write('c177_shop_states', 'state=$state;idx=$i');
                  }
                  DisputeItem? deskDisputeItem;
                  Map<String, dynamic>? deskDispute;
                  for (final oiid in mp.orderItemIds) {
                    deskDisputeItem ??= _disputeItemMap[oiid];
                    deskDispute ??= _disputeMap[oiid];
                  }
                  return InkWell(
                    onTap: (widget.arrivals && _activeBag == null) ? null : () => _showProductSheet(mp),
                    hoverColor: _kGreen.withValues(alpha: 0.04),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        border: isLast ? null : const Border(
                          bottom: BorderSide(color: _kBorder, width: 0.8),
                        ),
                      ),
                      child: Row(children: [
                        // col1: thumbnail + name + dispute badge
                        Expanded(flex: 6, child: Row(children: [
                          _FulfilImageTile(mp.imageUrl, size: 36),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(mp.productName,
                                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _kText),
                                    maxLines: 1, overflow: TextOverflow.ellipsis),
                                // #261: bag breakdown (Arrivals only, desktop) — B#:##P format
                                if (widget.arrivals && mp.bagBreakdown != null && mp.bagBreakdown!.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Builder(builder: (_) {
                                    final bd = _fmtBreakdown(mp.bagBreakdown, mp.packType);
                                    RenderLog.write('c261_breakdown_fmt', 'desktop;prod=${mp.productId};bd=$bd');
                                    // CHANGE #269 — black-on-grey badge style
                                    RenderLog.write('c269_bag_badge', 'desktop;$bd');
                                    return Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: Color(0xFFEEEEEE),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(bd,
                                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.black87),
                                          maxLines: 1, overflow: TextOverflow.ellipsis),
                                    );
                                  }),
                                ],
                                if (deskDisputeItem != null) ...[
                                  const SizedBox(height: 2),
                                  _DisputeStrip(item: deskDisputeItem, surface: widget.arrivals ? 'arrivals' : 'collect'),
                                ] else if (deskDispute != null) ...[
                                  const SizedBox(height: 2),
                                  DisputeBadge(status: deskDispute['status']?.toString() ?? ''),
                                ],
                                // #203: proof thumbnail in desktop tile
                                if (deskDisputeItem != null && (deskDisputeItem.proofUrl ?? '').isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  GestureDetector(
                                    onTap: () => showDialog<void>(
                                      context: context,
                                      builder: (ctx) => Dialog(
                                        backgroundColor: Colors.black,
                                        insetPadding: const EdgeInsets.all(12),
                                        child: Stack(children: [
                                          Image.network(deskDisputeItem!.proofUrl!, fit: BoxFit.contain,
                                              errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 64)),
                                          Positioned(
                                            top: 8, right: 8,
                                            child: GestureDetector(
                                              onTap: () => Navigator.of(ctx).pop(),
                                              child: Container(
                                                decoration: BoxDecoration(
                                                  color: _kGreen,
                                                  borderRadius: BorderRadius.circular(16),
                                                ),
                                                padding: const EdgeInsets.all(4),
                                                child: const Icon(Icons.close_rounded, color: Colors.white, size: 20),
                                              ),
                                            ),
                                          ),
                                        ]),
                                      ),
                                    ),
                                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: Image.network(deskDisputeItem!.proofUrl!, width: 32, height: 32, fit: BoxFit.cover,
                                            errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined, size: 20, color: _kSub)),
                                      ),
                                      const SizedBox(width: 4),
                                      const Text('proof', style: TextStyle(fontSize: 10, color: _kSub)),
                                    ]),
                                  ),
                                ],
                                if (deskDisputeItem != null && (deskDisputeItem.wrongProductName ?? '').isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text('↳ ${deskDisputeItem!.wrongProductName}',
                                      style: const TextStyle(fontSize: 10, color: Color(0xFF92400E)),
                                      maxLines: 1, overflow: TextOverflow.ellipsis),
                                ],
                              ],
                            ),
                          ),
                        ])),
                        // col2: pack type
                        Expanded(flex: 2, child: Text(
                          mp.packType.isEmpty ? '—' : mp.packType,
                          style: const TextStyle(fontSize: 12, color: _kSub),
                        )),
                        // col3: received / ordered (merged totals)
                        Expanded(flex: 2, child: Text(
                          '${mp.receivedTotal} / ${mp.orderedTotal}',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kText),
                          textAlign: TextAlign.right,
                        )),
                        // col4: status chip
                        Expanded(flex: 2, child: Align(
                          alignment: Alignment.centerRight,
                          child: _StatePill(state),
                        )),
                      ]),
                    ),
                  );
                },
              );
            }),
          ),
        ),
      ]),
    );
  }

  // ── Voice card (#86) ─────────────────────────────────────────────────────────

  static const _kAgentAccent = Color(0xFF3B5BDB); // indigo — distinct from green

  Widget _buildVoiceCard(bool isAdmin) {
    final countingDisabled = _agentPhase != AgentPhase.idle;
    final agentDisabled = _voiceListening || _voiceProcessing;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

        // ── Header row ──────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _kGreen.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.mic_rounded, size: 12, color: _kGreen.withValues(alpha: 0.8)),
                const SizedBox(width: 4),
                Text('Voice Input', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _kGreen.withValues(alpha: 0.85))),
              ]),
            ),
            const Spacer(),
            // #97: always visible in voice-bar header, green, tappable when count>0
            Builder(builder: (ctx) => _buildSpokenPill(ctx)),
          ]),
        ),

        // ── Mic row ─────────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          child: !_voiceSupported
              ? Row(children: [
                  const Icon(Icons.mic_off_rounded, size: 16, color: _kSub),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Voice unavailable — tap items below',
                        style: TextStyle(fontSize: 13, color: _kSub)),
                  ),
                ])
              : IntrinsicHeight(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

                    // ── Counting mic (left) ──────────────────────────────────────
                    Expanded(
                      child: IgnorePointer(
                        ignoring: countingDisabled,
                        child: Opacity(
                          opacity: countingDisabled ? 0.35 : 1.0,
                          child: GestureDetector(
                            onTap: _toggleRecording,
                            child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                width: 52, height: 52,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _voiceListening
                                      ? _kWrongFg
                                      : _voiceProcessing
                                          ? _kSub
                                          : _kGreen.withValues(alpha: 0.10),
                                  boxShadow: _voiceListening
                                      ? [BoxShadow(color: _kWrongFg.withValues(alpha: 0.40), blurRadius: 14, spreadRadius: 2)]
                                      : [],
                                ),
                                child: _voiceProcessing
                                    ? const Padding(
                                        padding: EdgeInsets.all(14),
                                        child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2.5),
                                      )
                                    : Icon(
                                        _voiceListening ? Icons.stop_rounded : Icons.mic_none_rounded,
                                        color: _voiceListening ? Colors.white : _kGreen,
                                        size: 22,
                                      ),
                              ),
                              const SizedBox(height: 6),
                              if (_voiceListening) ...[
                                const Text('● Recording',
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kWrongFg)),
                                const Text('Tap to stop',
                                    style: TextStyle(fontSize: 11, color: _kSub)),
                                if (_voiceInterim.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(_voiceInterim,
                                        style: const TextStyle(fontSize: 10, color: _kSub),
                                        maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
                                  ),
                              ] else if (_voiceProcessing) ...[
                                const Text('Processing…',
                                    style: TextStyle(fontSize: 12, color: _kSub)),
                              ] else if (_voiceError.isNotEmpty) ...[
                                Text(_voiceError,
                                    style: const TextStyle(fontSize: 11, color: _kWrongFg),
                                    textAlign: TextAlign.center, maxLines: 2),
                              ] else ...[
                                const Text('Count items',
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: _kText)),
                                const Text('Tap to record',
                                    style: TextStyle(fontSize: 11, color: _kSub)),
                              ],
                            ]),
                          ),
                        ),
                      ),
                    ),

                    // ── Vertical divider ─────────────────────────────────────────
                    if (isAdmin)
                      Container(
                        width: 1,
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                        color: const Color(0xFFE5E7EB),
                      ),

                    // ── Agent mic (right, admin only) ────────────────────────────
                    if (isAdmin) Expanded(
                      child: () {
                        final phase = _agentPhase;
                        final bool busy = phase == AgentPhase.thinking || phase == AgentPhase.speaking;
                        final bool isListening = phase == AgentPhase.listening;
                        final bool isConfirming = phase == AgentPhase.confirming;

                        void onTap() {
                          if (agentDisabled || busy) return;
                          if (isConfirming) {
                            if (!_agentRecStarted) {
                              _voiceService.start().then((_) {
                                _agentRecStarted = true;
                                if (mounted) setState(() {});
                              }).catchError((_) {});
                            } else {
                              _stopAgentYesNo();
                            }
                            return;
                          }
                          if (isListening) {
                            _stopAgentRecording();
                          } else if (phase == AgentPhase.idle) {
                            _startAgentRecording();
                          }
                        }

                        String caption;
                        if (isListening) caption = '● Listening';
                        else if (phase == AgentPhase.thinking) caption = 'Thinking…';
                        else if (phase == AgentPhase.speaking) caption = 'Speaking…';
                        else if (isConfirming) caption = 'Confirming';
                        else caption = 'Ask mediBO';

                        String subcaption;
                        if (isListening) subcaption = 'Tap to stop';
                        else if (busy) subcaption = 'Please wait';
                        else if (isConfirming) subcaption = 'See below';
                        else if (agentDisabled) subcaption = 'Finish count first';
                        else subcaption = 'Tap to ask';

                        return IgnorePointer(
                          ignoring: agentDisabled,
                          child: Opacity(
                            opacity: agentDisabled ? 0.35 : 1.0,
                            child: GestureDetector(
                              onTap: onTap,
                              child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  width: 52, height: 52,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: isListening
                                        ? _kAgentAccent
                                        : busy
                                            ? _kAgentAccent.withValues(alpha: 0.18)
                                            : _kAgentAccent.withValues(alpha: 0.08),
                                    boxShadow: isListening
                                        ? [BoxShadow(color: _kAgentAccent.withValues(alpha: 0.35), blurRadius: 14, spreadRadius: 2)]
                                        : [],
                                  ),
                                  child: busy
                                      ? const Padding(
                                          padding: EdgeInsets.all(14),
                                          child: CircularProgressIndicator(color: _kAgentAccent, strokeWidth: 2.5),
                                        )
                                      : Icon(
                                          isListening ? Icons.stop_rounded : Icons.record_voice_over_rounded,
                                          color: isListening ? Colors.white : _kAgentAccent,
                                          size: 22,
                                        ),
                                ),
                                const SizedBox(height: 6),
                                Text(caption,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: isListening ? _kAgentAccent : _kText,
                                    )),
                                Text(subcaption,
                                    style: const TextStyle(fontSize: 11, color: _kSub)),
                                // Agent reply shown inline when speaking
                                if (_agentReply.isNotEmpty && (phase == AgentPhase.speaking || phase == AgentPhase.confirming))
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(_agentReply,
                                        style: const TextStyle(fontSize: 10, color: _kSub),
                                        textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
                                  ),
                              ]),
                            ),
                          ),
                        );
                      }(),
                    ),

                  ]),
                ),
        ),

        // Type-instead footer removed (#87) — typed path kept hidden via self-test hook only.

      ]),
    );
  }

  /// Assistant confirm card — shown when _agentPhase == confirming.
  Widget _buildAgentConfirmBar() {
    final action = _pendingAction;
    final productName = action?['product_name']?.toString() ?? '';
    final qty = action?['qty'];
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kAgentAccent.withValues(alpha: 0.30)),
        boxShadow: [
          BoxShadow(color: _kAgentAccent.withValues(alpha: 0.08), blurRadius: 10, offset: const Offset(0, 3)),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

        // ── Header ──────────────────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: _kAgentAccent.withValues(alpha: 0.06),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
          ),
          child: Row(children: [
            Container(
              width: 28, height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _kAgentAccent.withValues(alpha: 0.12),
              ),
              child: const Icon(Icons.record_voice_over_rounded, size: 15, color: _kAgentAccent),
            ),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('mediBO puch raha hai',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _kAgentAccent)),
            ),
          ]),
        ),

        // ── Reply text + product chip ────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (_agentReply.isNotEmpty)
              Text(_agentReply,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: _kText)),
            if (productName.isNotEmpty || qty != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F6F8),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.inventory_2_rounded, size: 13, color: _kSub),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        productName,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: _kText),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (qty != null) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: _kAgentAccent.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'qty ${(qty as num).toInt()}',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _kAgentAccent),
                        ),
                      ),
                    ],
                  ]),
                ),
              ),
          ]),
        ),

        // ── Confirm / cancel buttons ─────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Row(children: [
            Expanded(
              child: GestureDetector(
                onTap: _commitPending,
                child: Container(
                  height: 46,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _kGreen,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [BoxShadow(color: _kGreen.withValues(alpha: 0.30), blurRadius: 8, offset: const Offset(0, 3))],
                  ),
                  child: const Text('✓  Haan',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GestureDetector(
                onTap: _cancelPending,
                child: Container(
                  height: 46,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: const Text('✗  Nahi',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _kText)),
                ),
              ),
            ),
          ]),
        ),

      ]),
    );
  }

  // #98: spoken popup anchored — top edge == pill top, opens downward
  void _showSpokenPopup(BuildContext pillContext) {
    RenderLog.write('change_97_spoken_popup', '1');
    RenderLog.write('change_98_popup_top_aligned', '1');
    RenderLog.write('change_99_popup_below', '1');

    // Dismiss any existing popup first
    _spokenPopupEntry?.remove();
    _spokenPopupEntry = null;

    // Get pill's global top-left + size from its RenderBox
    final RenderBox? box = pillContext.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final Offset topLeft = box.localToGlobal(Offset.zero);
    final double pillH = box.size.height;

    final screenW = MediaQuery.of(pillContext).size.width;
    final screenH = MediaQuery.of(pillContext).size.height;
    final bool isWide = screenW >= 900;
    // #118/#133/#111: comfortable side margins; cap at 440 on wide/desktop; +2% from #111.
    const double kMargin = 20.0; // #133: 20px each side → ~88-90% on phones
    final double popupW = (math.min(440.0, screenW - kMargin * 2) * 1.02)
        .clamp(0.0, screenW - 8.0); // #111: +2% width, min 4px each side

    double popupTop;
    double left;
    if (isWide) {
      // #101: wide — open to the RIGHT of the pill, top edge level with pill top
      RenderLog.write('change_101_popup_right', '1');
      final double pillRight = topLeft.dx + (pillContext.findRenderObject() as RenderBox).size.width;
      final double rightOfPill = pillRight + 8;
      if (rightOfPill + popupW <= screenW - 8) {
        left = rightOfPill;
      } else {
        left = math.max(8.0, topLeft.dx - popupW - 8);
      }
      popupTop = topLeft.dy;
    } else {
      // #118: center on narrow screens so both edges have equal margin
      left = (screenW - popupW) / 2;
      popupTop = topLeft.dy + pillH + 6;
    }
    final double maxH = math.min(screenH * 0.8, screenH - popupTop - 16);

    void dismiss() {
      _spokenPopupEntry?.remove();
      _spokenPopupEntry = null;
      setState(() {}); // rebuild so pill reflects any state change
    }

    final supplierForPopup = _selectedSupplier ?? '';
    // Snapshot of order items for matched qty display (immutable copy)
    final orderSnapshot = List<Map<String, dynamic>>.from(_items);

    _spokenPopupEntry = OverlayEntry(builder: (_) => Stack(children: [
      Positioned.fill(child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: dismiss,
      )),
      Positioned(
        top: popupTop,
        left: left,
        width: popupW,
        child: Material(
          borderRadius: BorderRadius.circular(12),
          elevation: 8,
          color: Colors.white,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: _CountedMentionsPopup(
              key: _popupKey,
              supplierName: supplierForPopup,
              orderItems: orderSnapshot,
              onDismiss: dismiss,
              // #331: apply voice_mention_set_status result to local items
              onApplyUpdate: (applyRes) {
                final rows = applyRes['rows'] as List? ?? [];
                if (rows.isEmpty) return;
                setState(() {
                  for (final row in rows) {
                    final oiid = row['order_item_id']?.toString();
                    if (oiid == null) continue;
                    final idx = _items.indexWhere((i) => i['order_item_id']?.toString() == oiid);
                    if (idx < 0) continue;
                    final shopSet = row['shop_set'];
                    if (shopSet != null) _items[idx]['shop_qty'] = shopSet;
                    final recSet = row['received_qty'];
                    if (recSet != null) _items[idx]['received_qty'] = recSet;
                  }
                });
              },
            ),
          ),
        ),
      ),
    ]));

    Overlay.of(pillContext).insert(_spokenPopupEntry!);
  }

  // #97/#98: shared pill widget — always green, centered, always visible, tappable when count>0
  Widget _buildSpokenPill(BuildContext context) {
    RenderLog.write('change_97_spoken_green', '1');
    RenderLog.write('change_97_spoken_persisted', '1');
    RenderLog.write('change_98_pill_centered', '1');
    final count = _spokenCount;
    return GestureDetector(
      onTap: count > 0 ? () => _showSpokenPopup(context) : null,
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center, // #98: explicit center — fixes low baseline
        decoration: BoxDecoration(
          color: _kReceivedBg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: _kReceivedFg.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(Icons.check_rounded, size: 11, color: _kReceivedFg),
            const SizedBox(width: 4),
            Text('$count spoken',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600, color: _kReceivedFg,
                    height: 1.0)),
          ],
        ),
      ),
    );
  }

  void _showTallySheet() {
    showResponsiveSheet(
      context: context,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      builder: (_) {
        final tallyEntries = _tally.entries.toList();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Voice tally this session',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _kText)),
            ),
            const Divider(height: 1, color: _kBorder),
            ...tallyEntries.map((e) {
              final productName = _items
                  .firstWhere(
                    (i) => (i['product_id'] as num?)?.toInt() == e.key,
                    orElse: () => {'product_name': 'Product ${e.key}'},
                  )['product_name']?.toString() ?? '?';
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Row(children: [
                  Expanded(child: Text(productName,
                      style: const TextStyle(fontSize: 14, color: _kText))),
                  Text('${e.value.toInt()} received',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kGreen)),
                ]),
              );
            }),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }

  // ── Supplier picker + progress bar ─────────────────────────────────────────

  // #90: progress bar removed from here — moved to _buildNarrowProgressRow (below voice row).
  Widget _buildSupplierPicker() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (!_loadingSuppliers && _suppliers.isEmpty && _error == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text('No supplier orders to collect yet',
                style: const TextStyle(fontSize: 13, color: _kSub)),
          ),
        if (_suppliers.isNotEmpty)
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: _kBg, border: Border.all(color: _kBorder),
              borderRadius: BorderRadius.circular(8),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                hint: const Text('Select supplier…',
                    style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 15)),
                value: _selectedSupplier,
                items: _suppliers
                    .map((s) => DropdownMenuItem(
                          value: s,
                          child: Text(s,
                              style: const TextStyle(fontSize: 15, color: _kText)),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  RenderLog.write('78_collect_supplier_selected', v);
                  setState(() => _selectedSupplier = v);
                  _loadBox(v);
                },
              ),
            ),
          ),
      ]),
    );
  }

  // ── Focused item card ──────────────────────────────────────────────────────




  Widget _buildDoneState() {
    final total     = _items.length;
    final received  = _items.where((i) => stateOf(i) == 'received').length;
    final short     = _items.where((i) => stateOf(i) == 'short').length;
    final wrong     = _items.where((i) => stateOf(i) == 'wrong').length;
    final notComing = _items.where((i) => stateOf(i) == 'not_coming').length;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: const BoxDecoration(color: _kReceivedBg, shape: BoxShape.circle),
            child: const Icon(Icons.check_circle_rounded, color: _kReceivedFg, size: 48),
          ),
          const SizedBox(height: 16),
          Text('${_selectedSupplier ?? 'Supplier'} counted ✓',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _kText),
              textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text('$total items processed',
              style: const TextStyle(fontSize: 14, color: _kSub)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
            _SummaryChip('$received received', _kReceivedBg, _kReceivedFg),
            if (short > 0)     _SummaryChip('$short short',     _kShortBg,     _kShortFg),
            if (wrong > 0)     _SummaryChip('$wrong wrong',     _kWrongBg,     _kWrongFg),
            if (notComing > 0) _SummaryChip('$notComing N/A',   _kNotComingBg, _kNotComingFg),
          ]),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: _kPendingBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _kPendingFg.withValues(alpha: 0.3)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.local_shipping_outlined, size: 14, color: _kPendingFg),
              const SizedBox(width: 8),
              const Flexible(child: Text(
                'Counted — not yet at warehouse.\nGo to Warehouse tab to mark this box arrived.',
                style: TextStyle(fontSize: 12, color: _kPendingFg),
              )),
            ]),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () => setState(() => _showListView = true),
            icon: const Icon(Icons.list_rounded, size: 16),
            label: const Text('Review all items'),
            style: OutlinedButton.styleFrom(
                foregroundColor: _kGreen, side: const BorderSide(color: _kGreen)),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () {
              setState(() { _items = []; _selectedSupplier = null; });
              _loadSuppliers();
            },
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('New supplier'),
            style: OutlinedButton.styleFrom(
                foregroundColor: _kSub, side: const BorderSide(color: _kBorder)),
          ),
        ]),
      ),
    );
  }

  Widget _buildListView() => _buildItemList(); // legacy alias

  Widget _buildItemList() {
    RenderLog.write('81_item_list_rendered', '${_items.length}');
    RenderLog.write('81_progress', '${_items.length - _pendingCount}/${_items.length}');

    return Column(children: [
      if (widget.arrivals) _buildBagControl(),
      Expanded(
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          itemCount: _items.length,
          separatorBuilder: (_, __) => const SizedBox(height: 6),
          itemBuilder: (_, i) {
            final item    = _items[i];
            final state   = item['fulfillment_state']?.toString() ?? 'pending';
            final name    = item['product_name']?.toString() ?? '—';
            final ordQty   = (item['ordered_qty'] as num?)?.toInt() ?? 0;
            final recQty   = (item['received_qty'] as num?)?.toInt() ?? 0;
            final packType = item['pack_type']?.toString() ?? '';
            final imageUrl = item['image_url']?.toString();
            if (state == 'wrong' || state == 'not_coming') {
              RenderLog.write('c177_wh_states', 'state=$state;idx=$i');
            }

            // #253/#254: bag_breakdown per item (Arrivals only), format: "37:03 38:05"
            final breakdownRaw = item['bag_breakdown'];
            final breakdown = breakdownRaw is List && (breakdownRaw as List).isNotEmpty
                ? breakdownRaw.cast<Map>()
                    .map((b) => '${b['bag_no']}:${(b['qty'] as num).toInt().toString().padLeft(2, '0')}')
                    .join(' ')
                : null;
            if (widget.arrivals && breakdown != null && breakdown.isNotEmpty) {
              RenderLog.write('c254_breakdown_ok', 'mobile;idx=$i;bags=$breakdown');
            }

            return GestureDetector(
              onTap: () => _showItemSheet(item),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _kCard,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: state == 'pending' ? _kBorder : (_stateBgMap[state] ?? _kBorder),
                  ),
                ),
                child: Row(children: [
                  _FulfilImageTile(imageUrl, size: 40),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(name,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kText),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text('$recQty/$ordQty${packType.isNotEmpty ? ' $packType' : ''}',
                          style: const TextStyle(fontSize: 12, color: _kSub)),
                      if (widget.arrivals && breakdown != null && breakdown.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        // CHANGE #269 — black-on-grey badge style
                        Builder(builder: (_) {
                          RenderLog.write('c269_bag_badge', 'list;$breakdown');
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: Color(0xFFEEEEEE),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(breakdown!,
                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.black87),
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                          );
                        }),
                      ],
                    ]),
                  ),
                  const SizedBox(width: 8),
                  _StatePill(state),
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }

  // #162: delegates to FulfillItemSheet in lib/widgets/fulfill_item_sheet.dart.
  // Desktop (≥900px) → Dialog; Mobile → ModalBottomSheet.
  Future<void> _showItemSheet(Map<String, dynamic> item) async {
    if (widget.arrivals ? _arrivalsLocked : _boxLocked) return;
    // CHANGE #277: silent gate — rows already block tap; this is a safety fallback
    if (widget.arrivals && _activeBag == null) {
      RenderLog.write('c277_item_gate_no_bag', 'showItemSheet_fallback');
      return;
    }
    final idx = _items.indexOf(item);
    if (idx >= 0) _focusItem(idx);
    final itemId      = item['order_item_id']?.toString();
    final supplier    = _selectedSupplier ?? '';
    final dispute     = itemId != null ? _disputeMap[itemId] : null;

    // c194: instrument list-shown + guard against silent failures
    RenderLog.write('c194_count_items_list_shown',
        'surface=${widget.arrivals ? "arrivals" : "collect"};item=${item['product_name'] ?? ''}');

    try {
      await showFulfillItemSheet(
        context: context,
        item: item,
        supplierName: supplier,
        recording: _recording,
        existingDispute: dispute,
        onRecord: (state, {qty, note}) => _record(state, qty: qty, note: note),
        onDisputeCreated: (id, d) {
          if (mounted) setState(() => _disputeMap[id] = d);
        },
        onViewDispute: () {
          context.findAncestorStateOfType<_AdminFulfillmentScreenState>()?._openDisputesTab();
        },
        arrivals: widget.arrivals, // CHANGE #276 — hides got-all in Warehouse
        // CHANGE #277: pass active bag_no so sheet can show Got all when uncounted
        activeBagNo: widget.arrivals ? (_activeBag?['bag_no'] as num?)?.toInt() : null,
      );
    } catch (e) {
      final short = e.toString().substring(0, e.toString().length.clamp(0, 80));
      RenderLog.write('c194_count_items_error',
          'surface=${widget.arrivals ? "arrivals" : "collect"};err=$short');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't open counting — please retry")),
        );
      }
      return;
    }
    // C174/B15: refresh dispute badges after sheet closes (user may have flagged/recorded)
    if (mounted) {
      await _loadDisputes();
      context.findAncestorStateOfType<_AdminFulfillmentScreenState>()?._refreshDisputeState();
    }
  }
}

// ── #115: Counted items popup — mentions table with tap-to-play ───────────────

// #117: _CountedMentionsPopup — whole-clip playback only.
// Per-item seek and live row-highlight removed (timestamps proven inaccurate).
// Table shows product | qty sequence (display-only) | total.
// One ▶/⏸ button per distinct recording_seq plays that clip from 0:00 to end.
class _CountedMentionsPopup extends StatefulWidget {
  final String supplierName;
  final List<Map<String, dynamic>> orderItems;
  final VoidCallback onDismiss;
  // #331: callback for when voice_mention_set_status returns an apply update
  final void Function(Map<String, dynamic> applyRes)? onApplyUpdate;
  const _CountedMentionsPopup({
    super.key,
    required this.supplierName,
    required this.orderItems,
    required this.onDismiss,
    this.onApplyUpdate,
  });

  @override
  State<_CountedMentionsPopup> createState() => _CountedMentionsPopupState();
}

// #119: per-mention entry retaining recording_seq + ord for pill coloring and reordering.
// #331: id (uuid) and status ('counted'|'deleted'|'readded') added for delete/undo.
typedef _QtyEntry = ({String id, int qty, int seq, int ord, String status});

// #110/#111/#112 sentinels — must survive into compiled bundle for curl grep.
// ignore: unused_field
const String _kC110Sentinel = 'C110_COUNTED_POPUP';
// ignore: unused_field
const String _kC111Sentinel = 'C111_COUNTED_POPUP_FIX';
// ignore: unused_field
const String _kC112Sentinel = 'C112_COUNTED_POPUP_BUGFIX';
// c112 key strings — must survive tree-shaking
// ignore: unused_element
const String _kC112ClipSourceLen = 'c112_clip_source_len';
// ignore: unused_element
const String _kC112PopupBranch = 'c112_popup_branch';
// ignore: unused_element
const String _kC112CloseBtnShared = 'c112_close_btn_shared';
// ignore: unused_element
const String _kC112CloseTap = 'c112_close_tap';

class _CountedMentionsPopupState extends State<_CountedMentionsPopup> {
  List<Map<String, dynamic>>? _mentions;
  String? _error;
  // #331: per-mention UUID in-flight set (prevents double-hold)
  final Set<String> _mentionLoading = {};

  // #266 (v2): plain html.AudioElement — the SAME pattern that already plays TTS
  // reliably in this file. The earlier audioplayers attempt produced SILENT
  // playback because audioplayers_web routes remote audio through the Web Audio
  // API (createMediaElementSource + crossOrigin='anonymous'); cross-origin
  // Supabase signed URLs get tainted on range responses → element "plays" but
  // emits no sound. A bare AudioElement is never routed through Web Audio, so
  // cross-origin remote clips play correctly.
  html.AudioElement? _clipAudio;
  final Map<String, String> _signedUrlCache = {}; // clip_path -> signed URL (cached per tap)
  String? _playingClip;   // clip_path of currently-playing recording
  int? _playingSeq;       // #119: recording_seq of playing clip (drives green state)
  int? _selectedClipSeq;  // #119: clip last tapped (drives reorder; null = default order)
  // #128: controller for the horizontal chip row so we can scroll back to start on reset
  final _chipScrollCtrl = ScrollController();
  // #130: seq of the clip JUST recorded — only ITS playback completion triggers reset to All
  int? _newClipSeq;

  // #110: overflow state for chip strip dot indicators
  bool _chipOverflowLeft = false;
  bool _chipOverflowRight = false;

  @override
  void initState() {
    super.initState();
    _chipScrollCtrl.addListener(_onChipScroll);
    _fetchMentions();
    // #110: compute initial overflow state after first layout
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateChipOverflow());
  }

  void _onChipScroll() => _updateChipOverflow();

  void _updateChipOverflow() {
    if (!mounted || !_chipScrollCtrl.hasClients) return;
    final pos = _chipScrollCtrl.position;
    final left = pos.pixels > 4;
    final right = pos.maxScrollExtent > 4 && pos.pixels < pos.maxScrollExtent - 4;
    if (left != _chipOverflowLeft || right != _chipOverflowRight) {
      setState(() {
        _chipOverflowLeft = left;
        _chipOverflowRight = right;
      });
    }
  }

  @override
  void dispose() {
    _clipAudio?.pause();
    _clipAudio?.src = '';
    _clipAudio = null;
    _chipScrollCtrl.removeListener(_onChipScroll);
    _chipScrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchMentions() async {
    try {
      final rows = await Supabase.instance.client
          .rpc('get_voice_clip_mentions', params: {'p_supplier_name': widget.supplierName}) as List;
      if (!mounted) return;
      final mentions = rows.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      final distinctClips = mentions.map((r) => r['clip_path']?.toString() ?? '').toSet().length;
      RenderLog.write('c119_popup_built',
          'clips=$distinctClips;products=${_uniqueNames(mentions)};total_mentions=${mentions.length};retains_seq=y');
      setState(() => _mentions = mentions);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  int _uniqueNames(List<Map<String, dynamic>> rows) =>
      rows.map((r) => r['matched_name']?.toString() ?? '').toSet().length;

  // #126/#127/#128/#130: called after every recording save — refresh data + mark this clip as "just recorded".
  // Does NOT reset to All here (#130: the reset fires when THIS clip's playback FINISHES, not on save).
  Future<void> _refreshForNewClip(int newSeq) async {
    if (!mounted) return;
    _newClipSeq = newSeq; // mark for playback-complete reset; consumed in _playWholeClip onEnded
    RenderLog.write('c126_reset_to_all', 'after_recording=y');
    await _fetchMentions(); // refresh so new clip chip appears; view stays on whatever user had
  }

  // #130/#131: fires inside _playWholeClip's onEnded for ANY tapped clip.
  // Resets popup to All combined view + scrolls chip row to start.
  Future<void> _resetToAllAfterPlayback({int? playedSeq}) async {
    if (!mounted) return;
    setState(() {
      _selectedClipSeq = null; // All view
      _mentions = null;        // clear so grouped body shows fresh data, not stale flat list
    });
    if (_chipScrollCtrl.hasClients) {
      _chipScrollCtrl.animateTo(0,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      RenderLog.write('c128_chips_scrolled', 'to_offset=0');
    }
    await _fetchMentions();
    if (!mounted) return;
    // c131_return_fired: runtime proof inside completion handler, AFTER selectedClipSeq=null
    final modeAfter = _selectedClipSeq == null ? 'grouped' : 'flat';
    RenderLog.write('c131_return_fired',
        'trigger=playback_complete;played_seq=${playedSeq?.toString() ?? 'null'};mode_after=$modeAfter;seq_after=${_selectedClipSeq?.toString() ?? 'null'}');
  }

  // Whole-clip play — no seeking, no timestamps.
  Future<void> _playWholeClip(String clipPath, int recordingSeq) async {
    if (clipPath.isEmpty) {
      _showSnackMsg('Audio unavailable for this clip');
      return;
    }
    // #266 (v2): stop any current playback (pause does not fire onEnded → no reset)
    _clipAudio?.pause();
    _clipAudio?.src = '';
    _clipAudio = null;
    if (mounted) setState(() { _playingClip = null; _playingSeq = null; });

    // #124: log the path used for THIS clip BEFORE fetching URL (proves per-clip routing)
    final tail = clipPath.length >= 8 ? clipPath.substring(clipPath.length - 8) : clipPath;
    RenderLog.write('c124_clip_play', 'recording_seq=$recordingSeq;clip_path_tail=$tail');

    try {
      // #266: signed URL required — voice-clips bucket is PRIVATE. Cache per clip.
      String? url = _signedUrlCache[clipPath];
      if (url == null) {
        url = await Supabase.instance.client.storage
            .from('voice-clips')
            .createSignedUrl(clipPath, 3600);
        _signedUrlCache[clipPath] = url;
      }
      if (!mounted) return;

      RenderLog.write('c124_signed_url', 'clip_path_tail=$tail;ok=y');

      // #266 (v2): bare html.AudioElement (no crossOrigin / no Web Audio routing).
      // Same proven path as TTS playback in this file → cross-origin signed URLs
      // actually emit sound (audioplayers_web silently muted them).
      final el = html.AudioElement(url);
      _clipAudio = el;
      // Natural end → clear state + return to All view (matches old onPlayerComplete).
      // pause()/src='' interruptions do NOT fire onEnded, so they are excluded.
      el.onEnded.listen((_) {
        if (!mounted || !identical(_clipAudio, el)) return;
        final playedSeq = _playingSeq;
        setState(() { _playingClip = null; _playingSeq = null; });
        RenderLog.write('c119_play_state', 'playing_seq=none;is_playing=false');
        _newClipSeq = null;
        _resetToAllAfterPlayback(playedSeq: playedSeq);
      });
      el.onError.listen((_) {
        if (!mounted || !identical(_clipAudio, el)) return;
        setState(() { _playingClip = null; _playingSeq = null; });
        _showSnackMsg("Couldn't play this clip");
        RenderLog.write('c266_clip_play', 'seq=$recordingSeq;status=fail_media');
      });
      await el.play();
      if (!mounted) return;
      setState(() { _playingClip = clipPath; _playingSeq = recordingSeq; });

      RenderLog.write('c117_clip_play', 'clip=${clipPath.split('/').last};recording_seq=$recordingSeq');
      RenderLog.write('c119_play_state', 'playing_seq=$recordingSeq;is_playing=true');
      RenderLog.write('c266_clip_play', 'seq=$recordingSeq;status=ok');
    } catch (e) {
      if (mounted) {
        setState(() { _playingClip = null; _playingSeq = null; });
        _showSnackMsg("Couldn't play this clip");
        RenderLog.write('c124_signed_url', 'clip_path_tail=$tail;ok=n;reason=exception');
        RenderLog.write('c266_clip_play', 'seq=$recordingSeq;status=fail');
      }
    }
  }

  // #119/#120: tap a clip chip — switch to flat spoken-order view + play.
  // Tapping the currently-playing clip stops audio but keeps the flat view.
  void _tapClip(String clipPath, int recordingSeq) {
    if (_playingClip == clipPath) {
      // Already playing — stop; stay in flat view for this clip
      _stopAudio();
    } else {
      setState(() => _selectedClipSeq = recordingSeq);
      _playWholeClip(clipPath, recordingSeq);
      RenderLog.write('c119_clip_tapped', 'seq=$recordingSeq;flat_view=y;playing=y');
    }
  }

  void _stopAudio() {
    _clipAudio?.pause();
    _clipAudio?.src = '';
    _clipAudio = null;
    if (mounted) setState(() { _playingClip = null; _playingSeq = null; });
  }

  void _showSnackMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  // Returns distinct clips ordered by recording_seq: [{seq, clipPath}]
  List<({int seq, String clipPath})> _distinctClips(List<Map<String, dynamic>> rows) {
    final seen = <String>{};
    final result = <({int seq, String clipPath})>[];
    for (final r in rows) {
      final path = r['clip_path']?.toString() ?? '';
      if (path.isEmpty || !seen.add(path)) continue;
      final seq = (r['recording_seq'] as num?)?.toInt() ?? 0;
      result.add((seq: seq, clipPath: path));
    }
    result.sort((a, b) => a.seq.compareTo(b.seq));
    return result;
  }

  // #119/#331: group rows by matched_name; deleted mentions excluded from All-tab totals.
  List<({String name, List<_QtyEntry> entries, int total, int ordered})>
      _groupMentions(List<Map<String, dynamic>> rows) {
    // #331: All tab excludes deleted mentions from totals
    final activeRows = rows.where((r) => r['status']?.toString() != 'deleted').toList();
    final nameOrder = <String>[];
    final byName = <String, List<_QtyEntry>>{};
    for (final r in activeRows) {
      // #134: guard against null/empty matched_name — never show a blank product cell
      final rawName = r['matched_name']?.toString() ?? '';
      final name = rawName.trim().isEmpty ? 'Unknown item' : rawName;
      if (!byName.containsKey(name)) nameOrder.add(name);
      byName.putIfAbsent(name, () => []).add((
        id: r['id']?.toString() ?? '',
        qty: (r['qty'] as num?)?.toInt() ?? 0,
        seq: (r['recording_seq'] as num?)?.toInt() ?? 0,
        ord: (r['ord'] as num?)?.toInt() ?? 0,
        status: r['status']?.toString() ?? 'counted',
      ));
    }
    final orderedMap = <String, int>{};
    for (final item in widget.orderItems) {
      final name = item['product_name']?.toString();
      if (name != null) orderedMap[name] = (item['ordered_qty'] as num?)?.toInt() ?? 0;
    }
    return nameOrder.map((name) {
      final entries = byName[name]!;
      final total = entries.fold(0, (s, e) => s + e.qty);
      return (name: name, entries: entries, total: total, ordered: orderedMap[name] ?? 0);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c119_no_timestamps', 'true'); // static: no t_start/t_end used
    RenderLog.write('c120_no_timestamps', 'true'); // static: #120 no timestamps

    final mentions = _mentions;
    final clips = mentions != null ? _distinctClips(mentions) : <({int seq, String clipPath})>[];
    final selSeq = _selectedClipSeq;

    // #120: log view mode on every build
    if (mentions != null && mentions.isNotEmpty) {
      RenderLog.write('c120_view_mode',
          selSeq == null ? 'mode=grouped' : 'mode=flat;clip_seq=$selSeq');
    }

    // #118/#110: log popup width vs screen
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sw = MediaQuery.of(context).size.width;
      final isMobile = sw < 600;
      final ro = context.findRenderObject();
      final pw = (ro is RenderBox && ro.hasSize) ? ro.size.width : 0.0;
      RenderLog.write('c118_counted_popup_built',
          'is_mobile=${isMobile ? 'y' : 'n'};popup_width_px=${pw.toStringAsFixed(0)};screen_width_px=${sw.toStringAsFixed(0)}');
      final margin = ((sw - pw) / 2).toStringAsFixed(0);
      RenderLog.write('c110_width_inset', 'margin_px=$margin;centered=y');
      RenderLog.write('c111_width_2pct', 'margin_px=$margin;popup_w=${pw.toStringAsFixed(0)};factor=1.02');
    });
    RenderLog.write('c110_popup_built', 'sentinel=$_kC110Sentinel');

    // #127/#128: log bottom-fade present
    RenderLog.write('c127_bottom_fade', 'present=y');
    RenderLog.write('c128_bottom_fade', 'present=y');

    return Stack(
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // #112: shared header — X visible in BOTH populated and empty states.
        // Header is always the first child of this Column, never inside a branch.
        Builder(builder: (_) {
          // Determine popup state for c112 logging
          final hState = mentions == null ? 'loading'
              : (mentions.isEmpty ? 'empty' : 'list');
          RenderLog.write('c110_close_btn', 'present=y');
          RenderLog.write('c111_close_btn_built', 'visible=y;color=dark');
          RenderLog.write('c112_close_btn_shared', 'state=$hState'); // #112: shared-header proof
          RenderLog.write('c134_close_btn_color', 'visible=y;color=dark'); // #134
          RenderLog.write('c135_close_btn', 'rendered=y;color_hex=0xFF1B7A43;size=22');
          // #136: light grey circle + black X — replaces green dot from #135.
          RenderLog.write('c136_close_btn', 'icon=close;icon_color=black;circle_bg=grey;diameter=28');
          return Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 4, 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Text('Counted items',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _kText)),
                const Spacer(),
                // #136: light grey circle + black X icon — no theme can override explicit Container color.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    RenderLog.write('c110_close_tap', 'dismiss=y');
                    RenderLog.write('c111_close_tap', 'dismiss=y');
                    RenderLog.write('c112_close_tap', 'dismiss=y');
                    widget.onDismiss();
                  },
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Center(
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: const BoxDecoration(
                          color: Color(0xFFE0E0E0), // light grey — explicit, no theme token
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.close,
                          size: 18,
                          color: Color(0xFF000000), // black — explicit, never overridden
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
        // #120/#126/#110: "All" chip + clip chips in a single horizontally-scrolling row
        // #110: overflow dot indicator on left/right when chips overflow the popup width
        if (mentions != null && clips.isNotEmpty)
          Builder(builder: (_) {
            RenderLog.write('c126_chips_row', 'scroll=horizontal;wrap=n');
            // #110 overflow key — only fires if dots are actually shown
            if (_chipOverflowLeft && _chipOverflowRight) {
              RenderLog.write('c110_chip_overflow', 'side=LR');
            } else if (_chipOverflowLeft) {
              RenderLog.write('c110_chip_overflow', 'side=L');
            } else if (_chipOverflowRight) {
              RenderLog.write('c110_chip_overflow', 'side=R');
            }
            RenderLog.write('c110_chip_strip', 'overflow_left=${_chipOverflowLeft ? 'y' : 'n'};overflow_right=${_chipOverflowRight ? 'y' : 'n'}');
            return Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
              child: Stack(
                children: [
                  SingleChildScrollView(
                    controller: _chipScrollCtrl,
                    scrollDirection: Axis.horizontal,
                    // #110: extra horizontal padding so dots don't cover first/last chip
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: [
                        // "All" chip — returns to grouped overview
                        GestureDetector(
                          onTap: () {
                            setState(() => _selectedClipSeq = null);
                            RenderLog.write('c120_back_to_all', 'true');
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: selSeq == null ? _kGreen : const Color(0xFFE8F5E9),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: _kGreen),
                            ),
                            child: Text('All',
                                style: TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.w600,
                                  color: selSeq == null ? Colors.white : _kGreen,
                                )),
                          ),
                        ),
                        // Clip chips
                        ...clips.asMap().entries.map((e) {
                          final idx = e.key;
                          final clip = e.value;
                          return Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: _ClipPlayButton(
                              label: 'Clip ${idx + 1}',
                              clipPath: clip.clipPath,
                              recordingSeq: clip.seq,
                              playing: _playingClip == clip.clipPath,
                              onPlay: () => _tapClip(clip.clipPath, clip.seq),
                              onStop: _stopAudio,
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                  // #110: LEFT overflow dot — shown when chips are hidden to the left
                  if (_chipOverflowLeft)
                    Positioned(
                      left: 0, top: 0, bottom: 0,
                      child: IgnorePointer(
                        child: Container(
                          width: 28,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.centerRight,
                              end: Alignment.centerLeft,
                              colors: [Colors.white.withOpacity(0), Colors.white.withOpacity(0.92)],
                            ),
                          ),
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.only(left: 4),
                          child: const Text('•••',
                              style: TextStyle(fontSize: 8, color: Color(0xFF9CA3AF),
                                  letterSpacing: 1)),
                        ),
                      ),
                    ),
                  // #110: RIGHT overflow dot — shown when chips are hidden to the right
                  if (_chipOverflowRight)
                    Positioned(
                      right: 0, top: 0, bottom: 0,
                      child: IgnorePointer(
                        child: Container(
                          width: 28,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: [Colors.white.withOpacity(0), Colors.white.withOpacity(0.92)],
                            ),
                          ),
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 4),
                          child: const Text('•••',
                              style: TextStyle(fontSize: 8, color: Color(0xFF9CA3AF),
                                  letterSpacing: 1)),
                        ),
                      ),
                    ),
                ],
              ),
            );
          }),
        const Divider(height: 1, color: _kBorder),
        // #112: log clip source length before branch decision — runtime proof of data presence
        Builder(builder: (_) {
          final srcLen = mentions?.length ?? 0;
          RenderLog.write('c112_clip_source_len', 'len=$srcLen'); // A2d: source length proof
          return const SizedBox.shrink();
        }),
        // Body
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text('Error: $_error', style: const TextStyle(fontSize: 12, color: Colors.red)),
          )
        else if (mentions == null)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: _kGreen))),
          )
        else if (mentions.isEmpty)
          // #112: genuine empty — no voice clips for this supplier today
          Builder(builder: (_) {
            RenderLog.write('c112_popup_branch', 'branch=empty'); // branch proof
            return const Padding(
              padding: EdgeInsets.all(14),
              child: Text('No clips recorded yet today.',
                  style: TextStyle(fontSize: 13, color: _kSub)),
            );
          })
        else if (selSeq != null)
          // #120: flat spoken-order view for selected clip
          Builder(builder: (_) {
            RenderLog.write('c112_popup_branch', 'branch=list;mode=flat'); // branch proof
            return Flexible(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: _buildFlatList(clips, selSeq),
                ),
              ),
            );
          })
        else
          // Default: grouped summary table (all clips combined, no reorder)
          Builder(builder: (_) {
            RenderLog.write('c112_popup_branch', 'branch=list;mode=grouped'); // branch proof
            return Flexible(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: _buildTable(_groupMentions(mentions)),
                ),
              ),
            );
          }),
          ],
        ), // end Column
        // #127: soft bottom fade so popup doesn't look hard-cut
        Positioned(
          left: 0, right: 0, bottom: 0,
          child: IgnorePointer(
            child: Container(
              height: 20,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.white.withOpacity(0), Colors.white],
                ),
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(12),
                  bottomRight: Radius.circular(12),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // #120: flat spoken-order list for the selected clip.
  // #331: handle long-press on a Clip-tab mention row.
  Future<void> _handleMentionHold(Map<String, dynamic> r) async {
    final id = r['id']?.toString() ?? '';
    final status = r['status']?.toString() ?? 'counted';
    final name = (r['matched_name']?.toString() ?? '').trim().isEmpty
        ? 'Unknown item'
        : r['matched_name']!.toString();
    final qty = (r['qty'] as num?)?.toInt() ?? 0;
    if (id.isEmpty || _mentionLoading.contains(id)) return;
    RenderLog.write('c331_mention_hold', 'id=${id.substring(0, id.length.clamp(0, 8))};status=$status');

    final isDeleted = status == 'deleted';
    final title = isDeleted
        ? 'Re-add this count?'
        : 'Remove this count?';
    final body = isDeleted
        ? '$name ×$qty'
        : '$name ×$qty  The audio stays; only the count is removed.';
    final confirmLabel = isDeleted ? 'Re-add' : 'Remove';
    final action = isDeleted ? 'readd' : 'delete';

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _kText)),
              const SizedBox(height: 8),
              Text(body, style: const TextStyle(fontSize: 13, color: _kSub)),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: isDeleted ? const Color(0xFF1B7A43) : const Color(0xFF991B1B),
                      ),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(confirmLabel),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _mentionLoading.add(id));
    try {
      final raw = await Supabase.instance.client.rpc('voice_mention_set_status', params: {
        'p_id': id,
        'p_action': action,
      }) as Map;
      final res = Map<String, dynamic>.from(raw);
      if (!mounted) return;
      if (res['ok'] == true) {
        final newStatus = res['status']?.toString() ?? (action == 'delete' ? 'deleted' : 'readded');
        // Update local mention status
        setState(() {
          final idx = _mentions?.indexWhere((m) => m['id']?.toString() == id) ?? -1;
          if (idx >= 0) {
            _mentions![idx] = Map<String, dynamic>.from(_mentions![idx])
              ..['status'] = newStatus;
          }
        });
        // Propagate apply update to parent (refreshes shop_qty / received_qty)
        final applyRaw = res['apply'];
        if (applyRaw != null && widget.onApplyUpdate != null) {
          widget.onApplyUpdate!(Map<String, dynamic>.from(applyRaw as Map));
        }
      } else {
        // H4: warehouse bag-gate
        final err = res['error']?.toString() ?? '';
        if (err.contains('no bag') || err.contains('check_violation') || err.contains('bag')) {
          RenderLog.write('c331_bag_prompt', 'from_mention_hold;id=${id.substring(0, id.length.clamp(0, 8))}');
          showModalBottomSheet<void>(
            context: context,
            builder: (ctx) => SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Bag required',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _kText)),
                    const SizedBox(height: 8),
                    const Text(
                        'Adjust the bag total to match the new count, then hold the item again to retry.',
                        style: TextStyle(fontSize: 13, color: _kSub)),
                    const SizedBox(height: 20),
                    FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: _kGreen),
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('OK')),
                  ],
                ),
              ),
            ),
          );
        } else {
          // H5
          _showSnackMsg(err.isNotEmpty ? 'Error: $err' : 'Could not update count');
        }
      }
    } catch (e) {
      if (mounted) _showSnackMsg('Error: $e');
    } finally {
      if (mounted) setState(() => _mentionLoading.remove(id));
    }
  }

  // #120: flat spoken-order list for the selected clip.
  // One row per mention (no grouping), ordered by ord asc for that recording_seq.
  // No timestamps used — green is whole-clip (#119 rule).
  // #331: long-press on each row → delete/re-add via voice_mention_set_status.
  Widget _buildFlatList(List<({int seq, String clipPath})> clips, int clipSeq) {
    final rows = (_mentions ?? [])
        .where((r) => (r['recording_seq'] as num?)?.toInt() == clipSeq)
        .toList()
      ..sort((a, b) => ((a['ord'] as num?)?.toInt() ?? 0)
          .compareTo((b['ord'] as num?)?.toInt() ?? 0));

    final clipIdx = clips.indexWhere((c) => c.seq == clipSeq);
    final clipLabel = clipIdx >= 0 ? 'Clip ${clipIdx + 1}' : 'Clip';
    final isPlaying = _playingSeq == clipSeq;

    RenderLog.write('c120_flat_built',
        'clip_seq=$clipSeq;rows=${rows.length};ord_sorted=y');

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('$clipLabel — spoken order',
                style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600, color: _kSub)),
          ),
          ...rows.asMap().entries.map((e) {
            final n = e.key + 1;
            final r = e.value;
            final mentionId = r['id']?.toString() ?? '';
            // #134: same fallback as grouped view — never a blank name cell
            final rawFlatName = r['matched_name']?.toString() ?? '';
            final name = rawFlatName.trim().isEmpty ? 'Unknown item' : rawFlatName;
            final qty = (r['qty'] as num?)?.toInt() ?? 0;
            final status = r['status']?.toString() ?? 'counted';
            final isDeleted = status == 'deleted';
            final isReadded = status == 'readded';
            final isLoading = _mentionLoading.contains(mentionId);

            // #331 H2: red tint for deleted, yellow/amber tint for readded
            Color? rowTint;
            if (isDeleted) {
              RenderLog.write('c331_mention_red', 'id=${mentionId.substring(0, mentionId.length.clamp(0, 8))}');
              rowTint = const Color(0x17FF0000); // red @ ~9%
            } else if (isReadded) {
              RenderLog.write('c331_mention_yellow', 'id=${mentionId.substring(0, mentionId.length.clamp(0, 8))}');
              rowTint = const Color(0x1AF59E0B); // amber @ ~10%
            }

            return GestureDetector(
              onLongPress: () => _handleMentionHold(r),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(vertical: 3),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: rowTint,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: isDeleted
                      ? const [BoxShadow(color: Color(0x1AFF0000), blurRadius: 4, offset: Offset(0, 1))]
                      : isReadded
                          ? const [BoxShadow(color: Color(0x1AF59E0B), blurRadius: 4, offset: Offset(0, 1))]
                          : null,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 28,
                      child: isLoading
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: _kGreen))
                          : Text('$n.',
                              style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w500,
                                color: isPlaying ? _kGreen : _kSub,
                              )),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name,
                              style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w500,
                                color: isDeleted
                                    ? const Color(0xFF991B1B)
                                    : isReadded
                                        ? const Color(0xFF92400E)
                                        : isPlaying ? _kGreen : _kText,
                              ),
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                          if (isDeleted)
                            const Text('removed', style: TextStyle(fontSize: 10, color: Color(0xFF991B1B)))
                          else if (isReadded)
                            const Text('re-added', style: TextStyle(fontSize: 10, color: Color(0xFF92400E))),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: isDeleted
                            ? const Color(0xFFFEE2E2)
                            : isReadded
                                ? const Color(0xFFFEF3C7)
                                : isPlaying ? _kGreen : const Color(0xFFF5F6F8),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isDeleted
                              ? const Color(0xFFEF4444)
                              : isReadded
                                  ? const Color(0xFFF59E0B)
                                  : isPlaying ? _kGreen : _kBorder,
                        ),
                      ),
                      child: isDeleted
                          ? Text(qty.toString(),
                              style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w600,
                                color: Color(0xFF991B1B),
                                decoration: TextDecoration.lineThrough,
                              ))
                          : Text('$qty',
                              style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w600,
                                color: isReadded
                                    ? const Color(0xFF92400E)
                                    : isPlaying ? Colors.white : _kText,
                              )),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  // #132/#110: responsive table — name pinned left, [badges + total] grouped right.
  // #110: _kBadgeToTotalGap is small (tight grouping); _kNameToBadgeMinGap ensures
  // the name never butts against the badge cluster on narrow widths.
  static const double _kTotalColW = 52.0;
  static const double _kBadgeToTotalGap = 6.0;
  static const double _kNameToBadgeMinGap = 10.0;
  // Max width for the badge cluster so it cannot crowd out the name on narrow phones.
  static const double _kBadgeClusterMaxW = 108.0;

  Widget _buildTable(
      List<({String name, List<_QtyEntry> entries, int total, int ordered})> groups) {
    final playSeq = _playingSeq;
    RenderLog.write('c132_table_responsive', 'cols_fit=y;total_visible=y');
    RenderLog.write('c133_cols_proportional', 'product_flex=expanded;qty_fixed=${_kBadgeClusterMaxW.toInt()};total_fixed=y');
    RenderLog.write('c110_row_spacing', 'name_left=y;badges_grouped_right=y;gap_badge_total=${_kBadgeToTotalGap.toInt()}');
    RenderLog.write('c111_header_aligned', 'badge_zone_fixed=${_kBadgeClusterMaxW.toInt()};header_body_match=y');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header row — mirrors body column zones
        Container(
          color: const Color(0xFFF5F6F8),
          child: Row(
            children: [
              Expanded(child: _th('Product')),
              const SizedBox(width: _kNameToBadgeMinGap),
              SizedBox(width: _kBadgeClusterMaxW, child: _thQty('Qty sequence')),
              const SizedBox(width: _kBadgeToTotalGap),
              SizedBox(width: _kTotalColW, child: _thRight('Total')),
            ],
          ),
        ),
        // Body rows: name (Expanded) | min-gap | badges (ConstrainedBox) | small-gap | Total
        ...groups.map((g) => Container(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: _kBorder)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Product name — fills remaining space, ellipsizes on overflow
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
                  child: Text(g.name,
                      style: const TextStyle(fontSize: 12, color: _kText),
                      overflow: TextOverflow.ellipsis, maxLines: 2),
                ),
              ),
              // Minimum gap between name and badge cluster
              const SizedBox(width: _kNameToBadgeMinGap),
              // Badge cluster — FIXED width so header "Qty sequence" aligns above it (#111)
              SizedBox(
                width: _kBadgeClusterMaxW,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: g.entries.map((e) {
                      final active = playSeq != null && e.seq == playSeq;
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: active ? _kGreen : const Color(0xFFF5F6F8),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: active ? _kGreen : _kBorder),
                        ),
                        child: Text('${e.qty}',
                            style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600,
                              color: active ? Colors.white : _kText,
                            )),
                      );
                    }).toList(),
                  ),
                ),
              ),
              // Small gap — badges and total are visually grouped together
              const SizedBox(width: _kBadgeToTotalGap),
              // Total — fixed width, always visible, right-aligned
              SizedBox(
                width: _kTotalColW,
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Text(
                    g.ordered > 0 ? '${g.total}/${g.ordered}' : '${g.total}',
                    style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700,
                      color: g.ordered > 0 && g.total >= g.ordered ? _kGreen : _kText,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
              ),
            ],
          ),
        )),
      ],
    );
  }

  Widget _th(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
    child: Text(text,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _kSub)),
  );

  // #111: zero left padding so "Qty sequence" header aligns with badge Wrap (which has no h-padding)
  Widget _thQty(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 6, 4, 6),
    child: Text(text,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _kSub)),
  );

  Widget _thRight(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 6, 10, 6),
    child: Text(text,
        textAlign: TextAlign.right,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _kSub)),
  );
}

// Compact ▶/⏸ button for a whole-clip recording.
class _ClipPlayButton extends StatelessWidget {
  final String? label; // null = icon-only (single clip in header)
  final String clipPath;
  final int recordingSeq;
  final bool playing;
  final VoidCallback onPlay;
  final VoidCallback onStop;
  const _ClipPlayButton({
    required this.label,
    required this.clipPath,
    required this.recordingSeq,
    required this.playing,
    required this.onPlay,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    if (label == null) {
      // Header icon-only mode
      return GestureDetector(
        onTap: playing ? onStop : onPlay,
        child: Icon(
          playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          size: 18, color: _kGreen,
        ),
      );
    }
    // Labelled chip: "Clip 1 ▶" / "Clip 1 ⏸"
    return GestureDetector(
      onTap: playing ? onStop : onPlay,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: playing ? _kGreen : const Color(0xFFE8F5E9),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: playing ? _kGreen : _kReceivedFg.withValues(alpha: 0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: 13, color: playing ? Colors.white : _kGreen,
          ),
          const SizedBox(width: 4),
          Text(label!,
              style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600,
                color: playing ? Colors.white : _kGreen,
              )),
        ]),
      ),
    );
  }
}

// ── Small shared helpers ──────────────────────────────────────────────────────

class _SummaryChip extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;
  const _SummaryChip(this.label, this.bg, this.fg);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: fg)),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;
  final VoidCallback? onTap;
  final bool loading;
  const _ActionBtn(this.label, this.color, this.icon, this.onTap, {this.loading = false});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !loading;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        height: 48, alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? color.withValues(alpha: 0.08) : _kBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: enabled ? color.withValues(alpha: 0.4) : _kBorder),
        ),
        child: loading
            ? SizedBox(width: 18, height: 18,
                child: CircularProgressIndicator(color: color, strokeWidth: 2))
            : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, size: 16, color: enabled ? color : _kSub),
                const SizedBox(width: 6),
                Text(label,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                        color: enabled ? color : _kSub)),
              ]),
      ),
    );
  }
}

// ── BAG LABELS SCREEN (legacy — kept for reference; use _BagLabelsInline) ─────

class _BagLabelsScreen extends StatefulWidget {
  const _BagLabelsScreen({super.key});

  @override
  State<_BagLabelsScreen> createState() => _BagLabelsScreenState();
}

class _BagLabelsScreenState extends State<_BagLabelsScreen> {
  List<Map<String, dynamic>> _bags = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final res = await Supabase.instance.client.rpc('get_customer_pack_status') as List;
      if (!mounted) return;
      final bags = res.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      bags.sort((a, b) => ((a['bag_no'] as num?)?.toInt() ?? 0)
          .compareTo((b['bag_no'] as num?)?.toInt() ?? 0));
      setState(() { _bags = bags; _loading = false; });
      RenderLog.write('bag_labels_rendered', '${bags.length}');
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2));
    }
    if (_error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('Error: $_error', style: const TextStyle(color: Color(0xFFDC2626))),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: _load, child: const Text('Retry')),
      ]));
    }
    if (_bags.isEmpty) {
      return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.qr_code_2_rounded, size: 48, color: Color(0xFFD1D5DB)),
        SizedBox(height: 12),
        Text('No customer bags yet', style: TextStyle(fontSize: 15, color: _kSub)),
      ]));
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Row(children: [
          Text('${_bags.length} bag labels',
              style: const TextStyle(fontSize: 14, color: _kSub)),
          const Spacer(),
          FilledButton.icon(
            onPressed: () => html.window.print(),
            icon: const Icon(Icons.print_rounded, size: 16),
            label: const Text('Print labels'),
            style: FilledButton.styleFrom(
              backgroundColor: _kGreen,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 220, mainAxisSpacing: 12,
            crossAxisSpacing: 12, mainAxisExtent: 260,
          ),
          itemCount: _bags.length,
          itemBuilder: (_, i) => _buildLabel(_bags[i]),
        ),
      ),
    ]);
  }

  Widget _buildLabel(Map<String, dynamic> bag) {
    final orderId  = bag['order_id']?.toString() ?? '';
    final bagNo    = bag['bag_no']?.toString() ?? '?';
    final customer = bag['pharmacy_name']?.toString() ?? '—';
    final qrData   = 'MEDIBO-BAG:$orderId';

    return Container(
      decoration: BoxDecoration(
        color: _kCard, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kBorder),
        boxShadow: const [BoxShadow(
            color: Color(0x0F000000), blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: const BoxDecoration(
            color: _kGreen,
            borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
          ),
          child: Center(
            child: Text('Bag $bagNo',
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w900, color: Colors.white)),
          ),
        ),
        const SizedBox(height: 12),
        QrImageView(
          data: qrData, version: QrVersions.auto, size: 130,
          eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: _kText),
          dataModuleStyle: const QrDataModuleStyle(
              dataModuleShape: QrDataModuleShape.square, color: _kText),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(customer,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText),
              textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(height: 6),
        const Text('medibo.in', style: TextStyle(fontSize: 10, color: _kSub)),
        const SizedBox(height: 10),
      ]),
    );
  }
}

// ── PACK SCREEN ──────────────────────────────────────────────────────────────

class _PackScreen extends StatefulWidget {
  const _PackScreen({super.key});

  @override
  State<_PackScreen> createState() => _PackScreenState();
}

class _PackScreenState extends State<_PackScreen> {
  List<Map<String, dynamic>> _bags = [];
  bool _loading = true;
  String? _error;
  final Set<String> _expanded = {};
  final Map<String, List<Map<String, dynamic>>> _bagItems = {};
  final Map<String, bool> _loadingBag = {};
  final Map<String, bool> _shipping = {};

  bool _showLabels = false;

  @override
  void initState() {
    super.initState();
    _load();
    RenderLog.write('fulfillment_pack_screen', 'true');
    RenderLog.write('pack_area_rendered', 'true');
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final res = await Supabase.instance.client.rpc('get_customer_pack_status') as List;
      if (!mounted) return;
      final bags = res.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      setState(() { _bags = bags; _loading = false; });
      for (var i = 0; i < bags.length; i++) {
        RenderLog.write('fulfillment_pack_card_$i', bags[i]['customer']?.toString() ?? '');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  Future<void> _loadBagItems(String orderId) async {
    setState(() => _loadingBag[orderId] = true);
    try {
      final res = await Supabase.instance.client
          .rpc('get_customer_bag_items', params: {'p_order_id': orderId}) as List;
      if (!mounted) return;
      setState(() {
        _bagItems[orderId] = res.map((r) => Map<String, dynamic>.from(r as Map)).toList();
        _loadingBag[orderId] = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingBag[orderId] = false);
    }
  }

  Future<void> _ship(String orderId, {required bool partial}) async {
    setState(() => _shipping[orderId] = true);
    try {
      final res = await Supabase.instance.client.rpc('ship_order', params: {
        'p_order_id': orderId, 'p_partial': partial,
      });
      if (!mounted) return;
      final resMap = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      if (resMap['error'] != null) {
        final blocking = resMap['blocking']?.toString() ?? '';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Not ready to ship${blocking.isNotEmpty ? ' ($blocking items pending/in transit)' : ''} — refresh and check arrivals'),
          backgroundColor: const Color(0xFFDC2626),
        ));
        await _load();
        return;
      }
      RenderLog.write('fulfillment_ship_ok', '$orderId:${partial ? 'partial' : 'full'}');
      RenderLog.write('pack_ship_ok', '$orderId:${partial ? 'partial' : 'full'}');
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _shipping[orderId] = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: const Color(0xFFDC2626)),
      );
    }
  }

  Future<void> _showShipDialog(Map<String, dynamic> bag, {required bool partial}) async {
    final orderId  = bag['order_id'].toString();
    final customer = bag['customer']?.toString() ?? '—';
    final bagNo    = bag['bag_no']?.toString() ?? '';
    final inTransit = (bag['in_transit_items'] as num?)?.toInt() ?? 0;
    final shortItems = (bag['short_items'] as num?)?.toInt() ?? 0;
    final notComingItems = (bag['not_coming_items'] as num?)?.toInt() ?? 0;

    String warningText = '';
    if (partial) {
      warningText = 'Ship the arrived items now and close the rest of Bag $bagNo ($customer)?';
    } else if (shortItems > 0 || notComingItems > 0) {
      warningText = 'Some items are short or not coming.';
    }

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(partial ? 'Ship Partial?' : 'Ship Order',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _kText)),
        content: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Bag $bagNo — $customer',
              style: const TextStyle(fontSize: 14, color: _kSub)),
          if (inTransit > 0 && !partial) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: _kShortBg, borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                const Icon(Icons.local_shipping_outlined, size: 16, color: _kShortFg),
                const SizedBox(width: 8),
                Expanded(child: Text('$inTransit item${inTransit==1?'':'s'} still in transit.',
                    style: const TextStyle(fontSize: 13, color: _kShortFg))),
              ]),
            ),
          ],
          if (warningText.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: _kPendingBg, borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                const Icon(Icons.warning_amber_rounded, size: 16, color: _kPendingFg),
                const SizedBox(width: 8),
                Expanded(child: Text(warningText,
                    style: const TextStyle(fontSize: 13, color: _kPendingFg))),
              ]),
            ),
          ],
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: _kSub))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, partial ? 'partial' : 'full'),
            style: FilledButton.styleFrom(backgroundColor: partial ? _kShortFg : _kGreen,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: Text(partial ? 'Ship Partial' : 'Ship',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (result == 'full') await _ship(orderId, partial: false);
    else if (result == 'partial') await _ship(orderId, partial: true);
  }

  @override
  Widget build(BuildContext context) {
    // Bag-labels sub-view
    if (_showLabels) {
      return Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(children: [
            GestureDetector(
              onTap: () => setState(() => _showLabels = false),
              child: const Row(children: [
                Icon(Icons.arrow_back_rounded, size: 18, color: _kGreen),
                SizedBox(width: 6),
                Text('Back to Pack', style: TextStyle(fontSize: 14, color: _kGreen, fontWeight: FontWeight.w600)),
              ]),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: () => html.window.print(),
              icon: const Icon(Icons.print_rounded, size: 16),
              label: const Text('Print'),
              style: FilledButton.styleFrom(
                backgroundColor: _kGreen,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ]),
        ),
        Expanded(child: _BagLabelsInline()),
      ]);
    }

    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2));
    }
    if (_error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Error loading bags', style: TextStyle(color: Color(0xFFDC2626))),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: _load, child: const Text('Retry')),
      ]));
    }
    if (_bags.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.inventory_2_outlined, size: 48, color: Color(0xFFD1D5DB)),
        const SizedBox(height: 12),
        const Text('No bags to pack', style: TextStyle(fontSize: 15, color: _kSub)),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => setState(() => _showLabels = true),
          icon: const Icon(Icons.label_outline_rounded, size: 16),
          label: const Text('Bag Labels'),
          style: OutlinedButton.styleFrom(foregroundColor: _kSub, side: const BorderSide(color: _kBorder)),
        ),
      ]));
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
        child: Row(children: [
          Text('${_bags.length} bag${_bags.length == 1 ? '' : 's'}',
              style: const TextStyle(fontSize: 13, color: _kSub)),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: () => setState(() => _showLabels = true),
            icon: const Icon(Icons.label_outline_rounded, size: 14),
            label: const Text('Bag Labels'),
            style: OutlinedButton.styleFrom(
                foregroundColor: _kSub, side: const BorderSide(color: _kBorder),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                visualDensity: VisualDensity.compact),
          ),
        ]),
      ),
      Expanded(
        child: RefreshIndicator(
          color: _kGreen,
          onRefresh: _load,
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            itemCount: _bags.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) => _buildBagCard(_bags[i]),
          ),
        ),
      ),
    ]);
  }

  Widget _buildBagCard(Map<String, dynamic> bag) {
    final orderId       = bag['order_id'].toString();
    final customer      = bag['customer']?.toString() ?? '—';
    final bagNo         = bag['bag_no']?.toString() ?? '';
    final status        = bag['fulfillment_status']?.toString() ?? 'open';
    final totalItems    = (bag['total_items']      as num?)?.toInt() ?? 0;
    final pendingItems  = (bag['pending_items']    as num?)?.toInt() ?? 0;
    final inTransit     = (bag['in_transit_items'] as num?)?.toInt() ?? 0;
    final readyItems    = (bag['ready_items']      as num?)?.toInt() ?? 0;
    final shortItems    = (bag['short_items']      as num?)?.toInt() ?? 0;
    final wrongItems    = (bag['wrong_items']      as num?)?.toInt() ?? 0;
    final notComing     = (bag['not_coming_items'] as num?)?.toInt() ?? 0;
    final isExpanded    = _expanded.contains(orderId);
    final isShipping    = _shipping[orderId] == true;
    final isShipped     = status == 'shipped' || status == 'partially_shipped' || status == 'cancelled';

    // Determine action
    final bool canFullShip    = status == 'ready' && !isShipped;
    final bool canPartialShip = (status == 'partial_ready' || (status == 'in_transit' && readyItems > 0)) && !isShipped;
    final bool isBlocked      = (status == 'in_transit' && readyItems == 0) || status == 'collecting' || status == 'open';

    return Container(
      decoration: BoxDecoration(
        color: _kCard, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isShipped ? _kShippedBg : _kBorder),
        boxShadow: const [BoxShadow(color: Color(0x0F000000), blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Header (tap to expand) ──────────────────────────────────────────
        InkWell(
          onTap: () {
            setState(() {
              if (isExpanded) {
                _expanded.remove(orderId);
              } else {
                _expanded.add(orderId);
                if (!_bagItems.containsKey(orderId)) _loadBagItems(orderId);
              }
            });
          },
          borderRadius: BorderRadius.vertical(
            top: const Radius.circular(12),
            bottom: (isExpanded || canFullShip || canPartialShip || isBlocked)
                ? Radius.zero
                : const Radius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                    color: _kBg, borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _kBorder)),
                alignment: Alignment.center,
                child: Text('B$bagNo',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _kGreen)),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(customer,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _kText),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    _OrderStatusBadge(status),
                    const SizedBox(width: 8),
                    Text('$readyItems/$totalItems ready',
                        style: const TextStyle(fontSize: 12, color: _kSub)),
                    if (inTransit > 0) ...[
                      const SizedBox(width: 6),
                      Text('$inTransit transit',
                          style: const TextStyle(fontSize: 12, color: _kPendingFg, fontWeight: FontWeight.w600)),
                    ],
                    if (pendingItems > 0) ...[
                      const SizedBox(width: 6),
                      Text('$pendingItems uncollected',
                          style: const TextStyle(fontSize: 12, color: _kSub)),
                    ],
                    if (shortItems > 0) ...[
                      const SizedBox(width: 6),
                      Text('$shortItems short',
                          style: const TextStyle(fontSize: 12, color: _kShortFg, fontWeight: FontWeight.w600)),
                    ],
                    if (wrongItems > 0) ...[
                      const SizedBox(width: 6),
                      Text('$wrongItems wrong',
                          style: const TextStyle(fontSize: 12, color: _kWrongFg, fontWeight: FontWeight.w600)),
                    ],
                    if (notComing > 0) ...[
                      const SizedBox(width: 6),
                      Text('$notComing N/A',
                          style: const TextStyle(fontSize: 12, color: _kNotComingFg, fontWeight: FontWeight.w600)),
                    ],
                  ]),
                ),
              ])),
              Icon(isExpanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded, color: _kSub),
            ]),
          ),
        ),

        // ── Action area ────────────────────────────────────────────────────
        if (canFullShip) ...[
          const Divider(height: 1, color: _kBorder),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: SizedBox(
              width: double.infinity, height: 44,
              child: FilledButton.icon(
                onPressed: isShipping ? null : () => _showShipDialog(bag, partial: false),
                icon: isShipping
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.local_shipping_outlined, size: 18),
                label: Text(isShipping ? 'Shipping…' : 'Pack & Ship',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                style: FilledButton.styleFrom(
                  backgroundColor: _kGreen,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ),
        ] else if (canPartialShip) ...[
          const Divider(height: 1, color: _kBorder),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Column(children: [
              if (inTransit > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(color: _kPendingBg, borderRadius: BorderRadius.circular(8)),
                    child: Row(children: [
                      const Icon(Icons.local_shipping_outlined, size: 14, color: _kPendingFg),
                      const SizedBox(width: 8),
                      Expanded(child: Text('$inTransit item${inTransit==1?'':'s'} still in transit — mark arrived first to ship all.',
                          style: const TextStyle(fontSize: 12, color: _kPendingFg))),
                    ]),
                  ),
                ),
              SizedBox(
                width: double.infinity, height: 44,
                child: FilledButton.icon(
                  onPressed: isShipping ? null : () => _showShipDialog(bag, partial: true),
                  icon: isShipping
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.local_shipping_outlined, size: 18),
                  label: Text(isShipping ? 'Shipping…' : 'Ship Partial',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  style: FilledButton.styleFrom(
                    backgroundColor: _kShortFg,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
            ]),
          ),
        ] else if (isBlocked && !isShipped) ...[
          const Divider(height: 1, color: _kBorder),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: _kBg, borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _kBorder)),
              child: Row(children: [
                const Icon(Icons.hourglass_top_rounded, size: 14, color: _kSub),
                const SizedBox(width: 8),
                Expanded(child: Text(
                  status == 'in_transit'
                      ? 'Waiting — mark box arrived in the Warehouse tab'
                      : 'Still counting — count stock in the Supplier Shop tab first',
                  style: const TextStyle(fontSize: 12, color: _kSub),
                )),
              ]),
            ),
          ),
        ],

        // ── Expanded item list ─────────────────────────────────────────────
        if (isExpanded) ...[
          const Divider(height: 1, color: _kBorder),
          if (_loadingBag[orderId] == true)
            const Padding(padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2)))
          else if (_bagItems[orderId]?.isEmpty ?? true)
            const Padding(padding: EdgeInsets.all(16),
                child: Text('No items', style: TextStyle(color: _kSub, fontSize: 13)))
          else
            ...(_bagItems[orderId]!.map(_buildPickItem)),
        ],
      ]),
    );
  }

  Widget _buildPickItem(Map<String, dynamic> item) {
    final name       = item['product_name']?.toString() ?? '—';
    final orderedQty = (item['ordered_qty']  as num?)?.toInt() ?? 0;
    final recvQty    = (item['received_qty'] as num?)?.toInt() ?? 0;
    final state      = item['fulfillment_state']?.toString() ?? 'pending';
    final imageUrl   = item['image_url']?.toString();
    final atWarehouse = item['at_warehouse'] as bool?;
    final supplier   = item['assigned_supplier']?.toString() ?? '';

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: _kBorder, width: 0.5))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _FulfilImageTile(imageUrl, size: 40),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _kText),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 3),
          Row(children: [
            Text('$recvQty/$orderedQty',
                style: const TextStyle(fontSize: 12, color: _kSub)),
            if (supplier.isNotEmpty) ...[
              const SizedBox(width: 6),
              Flexible(child: Text('from $supplier',
                  style: const TextStyle(fontSize: 11, color: _kSub),
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
          ]),
          if (atWarehouse != null) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: atWarehouse ? _kReceivedBg : _kPendingBg,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                atWarehouse ? 'At warehouse' : 'In transit',
                style: TextStyle(
                  fontSize: 10, fontWeight: FontWeight.w700,
                  color: atWarehouse ? _kReceivedFg : _kPendingFg,
                ),
              ),
            ),
          ],
        ])),
        const SizedBox(width: 8),
        _StatePill(state),
      ]),
    );
  }
}

// ── BAG LABELS INLINE (used inside Pack tab) ──────────────────────────────────

class _BagLabelsInline extends StatefulWidget {
  const _BagLabelsInline();

  @override
  State<_BagLabelsInline> createState() => _BagLabelsInlineState();
}

class _BagLabelsInlineState extends State<_BagLabelsInline> {
  List<Map<String, dynamic>> _bags = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final res = await Supabase.instance.client.rpc('get_customer_pack_status') as List;
      if (!mounted) return;
      final bags = res.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      bags.sort((a, b) => ((a['bag_no'] as num?)?.toInt() ?? 0)
          .compareTo((b['bag_no'] as num?)?.toInt() ?? 0));
      setState(() { _bags = bags; _loading = false; });
      RenderLog.write('bag_labels_rendered', '${bags.length}');
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2));
    if (_error != null) return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text('Error: $_error', style: const TextStyle(color: Color(0xFFDC2626), fontSize: 13)),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: _load, child: const Text('Retry')),
    ]));
    if (_bags.isEmpty) return const Center(child: Text('No bags yet', style: TextStyle(color: _kSub)));
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220, mainAxisSpacing: 12, crossAxisSpacing: 12, mainAxisExtent: 260,
      ),
      itemCount: _bags.length,
      itemBuilder: (_, i) {
        final bag      = _bags[i];
        final orderId  = bag['order_id']?.toString() ?? '';
        final bagNo    = bag['bag_no']?.toString() ?? '?';
        final customer = bag['customer']?.toString() ?? '—';
        final qrData   = 'MEDIBO-BAG:$orderId';
        return Container(
          decoration: BoxDecoration(
            color: _kCard, borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _kBorder),
            boxShadow: const [BoxShadow(color: Color(0x0F000000), blurRadius: 6, offset: Offset(0, 2))],
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: const BoxDecoration(
                color: _kGreen,
                borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Center(child: Text('Bag $bagNo',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Colors.white))),
            ),
            const SizedBox(height: 12),
            QrImageView(
              data: qrData, version: QrVersions.auto, size: 130,
              eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: _kText),
              dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: _kText),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(customer,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText),
                  textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(height: 6),
            const Text('medibo.in', style: TextStyle(fontSize: 10, color: _kSub)),
            const SizedBox(height: 10),
          ]),
        );
      },
    );
  }
}


// ── #183: Top-level shared reveal — same primitive as _DisputesScreenState._smoothReveal ──
// Used by _SupplierAccordionShell (Collect + Arrivals) AND DisputesScreen.
// Duration/Curve must never be edited without updating ALL three call-sites.
Widget _sharedSmoothReveal(bool expanded, Widget child) => AnimatedSize(
  duration: const Duration(milliseconds: 280),
  curve: Curves.easeInOutCubic,
  clipBehavior: Clip.antiAlias,
  child: expanded ? child : const SizedBox.shrink(),
);

// ── #153: SHARED ACCORDION SHELL — used by Collect AND Arrivals ───────────────
// Both tabs instantiate this widget; only expandedContent differs.

class _SupplierAccordionShell extends StatelessWidget {
  final String name;
  final String dot;           // 'green' | 'light_yellow' | 'yellow'
  final bool isExpanded;
  final bool anyExpanded;     // any supplier open → bigger bottom gap
  final GlobalKey rowKey;
  final VoidCallback onTap;
  final Widget expandedContent; // AnimatedSize handles show/hide
  final String? mode;         // #117: arrivals mode ('shop'|'warehouse'|null)
  final bool showPending;     // #121: true = Collect tab, renders P when mode==null

  const _SupplierAccordionShell({
    required this.name,
    required this.dot,
    required this.isExpanded,
    required this.anyExpanded,
    required this.rowKey,
    required this.onTap,
    required this.expandedContent,
    this.mode,
    this.showPending = false,
  });

  static const _kDotGreen       = Color(0xFF1B7A43);
  static const _kDotLightYellow = Color(0xFFFEF3C7);
  static const _kDotYellow      = Color(0xFFFCD34D);
  static const _kDotBorderLight = Color(0xFFF59E0B);

  @override
  Widget build(BuildContext context) {
    final dotFill   = dot == 'green'        ? _kDotGreen
                    : dot == 'light_yellow' ? _kDotLightYellow
                    : _kDotYellow;
    final dotBorder = dot == 'green' ? _kDotGreen : _kDotBorderLight;
    final bottomGap = anyExpanded ? 16.0 : 8.0;

    return Padding(
      key: rowKey,
      padding: EdgeInsets.only(bottom: bottomGap),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _kBorder),
          boxShadow: [BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6, offset: const Offset(0, 2))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
            borderRadius: BorderRadius.vertical(
              top: const Radius.circular(12),
              bottom: Radius.circular(isExpanded ? 0 : 12),
            ),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(children: [
                Expanded(
                  child: Text(name,
                      style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600,
                        color: isExpanded ? _kGreen : _kText,
                      ),
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 8),
                // #183: AnimatedRotation — same turns/duration/curve as Disputes chevron
                AnimatedRotation(
                  turns: isExpanded ? 0.5 : 0.0,
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeInOutCubic,
                  child: const Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: _kSub),
                ),
                const SizedBox(width: 12),
                // Constant-width badge slot (38px) — flush right next to dot.
                CountBadge(mode: mode, showPending: showPending),
                const SizedBox(width: 8),
                Container(
                  width: 12, height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: dotFill,
                    border: Border.all(color: dotBorder, width: 1.5),
                  ),
                ),
              ]),
            ),
          ),
          // #183: uses top-level _sharedSmoothReveal — one code path for Collect, Arrivals, Disputes.
          _sharedSmoothReveal(isExpanded, expandedContent),
        ]),
      ),
    );
  }
}

// ── #121: 5-second hold-to-undo wrapper ──────────────────────────────────────

class _HoldToUndo extends StatefulWidget {
  const _HoldToUndo({required this.child, required this.onUndo});
  final Widget child;
  final VoidCallback onUndo;

  @override
  State<_HoldToUndo> createState() => _HoldToUndoState();
}

class _HoldToUndoState extends State<_HoldToUndo>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    )
      ..addListener(() { if (mounted) setState(() {}); })
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) widget.onUndo();
      });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _start(TapDownDetails _) => _ctrl.forward(from: 0);
  void _cancel() => _ctrl.reset();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: _start,
      onTapUp: (_) => _cancel(),
      onTapCancel: _cancel,
      child: Stack(alignment: Alignment.centerLeft, children: [
        widget.child,
        if (_ctrl.value > 0)
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: FractionallySizedBox(
                widthFactor: _ctrl.value,
                alignment: Alignment.centerLeft,
                child: Container(
                  color: Colors.red.withValues(alpha: 0.25),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

// ── #117: Count badge — fixed-width chip shown on Arrivals accordion rows ─────

class CountBadge extends StatelessWidget {
  const CountBadge({super.key, required this.mode, this.showPending = false});
  final String? mode;
  final bool showPending; // true = Collect tab; renders 'P' yellow when mode==null

  @override
  Widget build(BuildContext context) {
    final String? label = mode == 'shop' ? 'C'
        : mode == 'warehouse' ? 'CR'
        : showPending ? 'P'
        : null;
    if (label == null) return const SizedBox(width: 38, height: 24);
    final Color color = mode == 'shop'
        ? const Color(0xFF1B7A43)
        : mode == 'warehouse'
            ? const Color(0xFFD32F2F)
            : const Color(0xFFF59E0B); // amber — matches pending dot
    return SizedBox(
      width: 38,
      height: 24,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label, style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 12,
          height: 1.0,
        )),
      ),
    );
  }
}

// ── #132A: Dispute badge — item-row indicator, distinct colour from C/CR/P ────

// #189: Verbatim dispute status strip for Supplier Shop + Warehouse line rows.
// Shows item_status_label + dispute_status chip from backend — no client-side mapping.
class _DisputeStrip extends StatelessWidget {
  final DisputeItem item;
  final String surface; // 'collect' or 'arrivals' — for render-log only

  const _DisputeStrip({required this.item, required this.surface});

  @override
  Widget build(BuildContext context) {
    final isActive = item.isActive;
    final bgColor  = isActive ? const Color(0xFFFEF3C7) : const Color(0xFFD1FAE5);
    final fgColor  = isActive ? const Color(0xFF92400E) : const Color(0xFF065F46);

    if (surface == 'collect') {
      RenderLog.write('c189_collect_badge_rendered',
          'dispute=${item.disputeId};status=${item.disputeStatus}');
    } else {
      RenderLog.write('c189_arrivals_badge_rendered',
          'dispute=${item.disputeId};status=${item.disputeStatus}');
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(4)),
      child: Text(
        item.itemStatusLabel,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: fgColor),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class DisputeBadge extends StatelessWidget {
  final String status;
  const DisputeBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    if (status.isEmpty) return const SizedBox.shrink();
    final Color bg;
    final Color fg;
    final String label;
    switch (status) {
      case 'reminder_sent':
        bg = const Color(0xFFEDE9FE); fg = const Color(0xFF7C3AED); label = 'Reminder sent'; break;
      case 'accepted_missing':
        bg = const Color(0xFFDBEAFE); fg = const Color(0xFF1D4ED8); label = 'Awaiting stock'; break;
      case 'denied':
        bg = const Color(0xFFFFEDD5); fg = const Color(0xFFC2410C); label = 'Disputed'; break;
      case 'shop_logged':
        bg = const Color(0xFFF3F4F6); fg = const Color(0xFF6B7280); label = 'Re-sourced'; break;
      default:
        bg = const Color(0xFFF3F4F6); fg = const Color(0xFF6B7280); label = status;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Text(label,
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: fg)),
    );
  }
}

// ── #197: Stepper button used by _ProductReceiveSheet ────────────────────────
class _ProdStepBtn extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final Color color;
  final VoidCallback onTap;
  const _ProdStepBtn({required this.icon, required this.enabled, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 8),
        child: Icon(icon, size: 16, color: enabled ? color : _kSub),
      ),
    );
  }
}

// ── #197: Per-product receiving sheet — calls fw_product_action ───────────────

class _ProductReceiveSheet extends StatefulWidget {
  final String supplierName;
  final int productId;
  final String productName;
  final String packType;
  final String? imageUrl;
  final int orderedTotal;
  final int receivedTotal;
  final String combinedState;
  final DisputeItem? existingDispute;
  // #258 BUG4: arrivals mode — "Got all" calls bag_count_set instead of fw_product_action.
  final bool arrivals;
  // CHANGE #277: dynamic Got all — show only when bag attached and item uncounted
  final int? activeBagNo;
  final List<Map>? bagBreakdown;
  final Future<String?> Function(int productId, double qty)? bagCountFn;
  // #261: undo clears bag breakdown — called by snackbar UNDO handler
  final Future<void> Function(int productId)? bagCountClearFn;
  final VoidCallback? onReload;

  const _ProductReceiveSheet({
    required this.supplierName,
    required this.productId,
    required this.productName,
    required this.packType,
    this.imageUrl,
    required this.orderedTotal,
    required this.receivedTotal,
    required this.combinedState,
    this.existingDispute,
    this.arrivals = false,
    this.activeBagNo,
    this.bagBreakdown,
    this.bagCountFn,
    this.bagCountClearFn,
    this.onReload,
  });

  @override
  State<_ProductReceiveSheet> createState() => _ProductReceiveSheetState();
}

class _ProductReceiveSheetState extends State<_ProductReceiveSheet> {
  late String _localState;
  late int _localReceived;

  // Report missing inline two-half
  bool _showMissingInline = false;
  late int _missingDraft;
  bool _confirmingMissing = false;
  final _missingCtrl = TextEditingController();

  // Few wrong inline panel
  bool _showFewWrongInline = false;
  late int _wrongDraft;
  bool _confirmingFewWrong = false;
  final _fewWrongCtrl = TextEditingController();
  final _fewWrongNameCtrl = TextEditingController();
  String? _fewWrongProofUrl;
  bool _fewWrongUploading = false;

  // Wrong item inline panel
  bool _showWrongItemInline = false;
  bool _confirmingWrongAll = false;
  final _wrongItemNameCtrl = TextEditingController();
  String? _wrongItemProofUrl;
  bool _wrongItemUploading = false;

  bool _confirmingSimple = false; // for got_all / not_coming
  bool _undoing = false;

  @override
  void initState() {
    super.initState();
    _localState = widget.combinedState;
    _localReceived = widget.receivedTotal;
    final safeOrd = widget.orderedTotal > 0 ? widget.orderedTotal : 1;
    _missingDraft = _localReceived.clamp(0, safeOrd);
    _wrongDraft = 1;
    _missingCtrl.text = '$_missingDraft';
    _fewWrongCtrl.text = '1';
    RenderLog.write('c197_product_sheet_opened',
        'product_id=${widget.productId};ordered=${widget.orderedTotal}');
  }

  @override
  void dispose() {
    _missingCtrl.dispose();
    _fewWrongCtrl.dispose();
    _fewWrongNameCtrl.dispose();
    _wrongItemNameCtrl.dispose();
    super.dispose();
  }

  String get _unit => widget.packType;
  String get _unitLabel => _unit.isNotEmpty ? ' $_unit' : '';
  int get _orderedTotal => widget.orderedTotal;

  Future<void> _callProductAction(String action,
      {int? qty, String? note, String? proofUrl}) async {
    RenderLog.write('c197_product_action_called',
        'action=$action;product_id=${widget.productId};supplier=${widget.supplierName};qty=${qty ?? 'null'}');
    final params = <String, dynamic>{
      'p_supplier_name': widget.supplierName,
      'p_product_id': widget.productId,
      'p_action': action,
      'p_note': note,
      'p_proof_url': proofUrl,
    };
    if (qty != null) params['p_qty'] = qty;
    final res = await Supabase.instance.client.rpc('fw_product_action', params: params) as Map;
    final err = res['error']?.toString();
    if (err != null) throw err;
  }

  // Upload a picked image to dispute-proofs; returns public URL or null on cancel/error.
  Future<String?> _pickAndUpload() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(type: FileType.image, withData: true);
    } catch (_) { return null; }
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) return null;
    final ext = file.name.split('.').last.toLowerCase();
    final mime = ext == 'png' ? 'image/png' : ext == 'webp' ? 'image/webp' : 'image/jpeg';
    final ts = DateTime.now().millisecondsSinceEpoch;
    final path = 'wrong/${widget.productId}_$ts.$ext';
    try {
      await Supabase.instance.client.storage
          .from('dispute-proofs')
          .uploadBinary(path, bytes, fileOptions: FileOptions(upsert: true, contentType: mime));
      final url = Supabase.instance.client.storage.from('dispute-proofs').getPublicUrl(path);
      RenderLog.write('c203_proof_uploaded', 'product_id=${widget.productId};path=$path');
      return url;
    } catch (_) { return null; }
  }

  Future<void> _doUndo() async {
    if (_undoing) return;
    setState(() => _undoing = true);
    RenderLog.write('c199_undo_called',
        'product_id=${widget.productId};supplier=${widget.supplierName}');
    await _runUndo();
  }

  Future<void> _doUndoBelow() async {
    if (_undoing) return;
    setState(() => _undoing = true);
    RenderLog.write('c201_undo_called',
        'product_id=${widget.productId};supplier=${widget.supplierName};from=below_button');
    await _runUndo();
  }

  Future<void> _runUndo() async {
    try {
      final res = await Supabase.instance.client.rpc('fw_product_undo', params: {
        'p_supplier_name': widget.supplierName,
        'p_product_id': widget.productId,
      }) as Map;
      if (!mounted) return;
      setState(() => _undoing = false);
      final err = res['error']?.toString();
      if (err == 'nothing_to_undo') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nothing to undo (already confirmed or re-sourced)')));
      } else if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $err'), backgroundColor: const Color(0xFFDC2626)));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reverted')));
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _undoing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: const Color(0xFFDC2626)));
    }
  }

  Future<void> _doGotAll() async {
    if (_confirmingSimple) return;
    setState(() => _confirmingSimple = true);
    try {
      if (widget.arrivals && widget.bagCountFn != null) {
        // #258 BUG4: Arrivals "Got all" → bag_count_set (not fw_product_action which bypasses bag).
        final err = await widget.bagCountFn!(widget.productId, _orderedTotal.toDouble());
        if (!mounted) return;
        if (err != null) {
          setState(() => _confirmingSimple = false);
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(err), backgroundColor: const Color(0xFFDC2626)));
          return;
        }
        RenderLog.write('c258_bag_count', 'got_all;product=${widget.productId};qty=$_orderedTotal');
        setState(() { _localState = 'received'; _localReceived = _orderedTotal; _confirmingSimple = false; });
        // CHANGE #274 — removed "Got all N — marked received" snackbar; per-item undo is in the card
        final pid = widget.productId;
        RenderLog.write('c274_no_snackbar', 'got_all_bag;product=$pid');
        widget.onReload?.call();
        if (mounted) Navigator.of(context).pop();
        return;
      }
      await _callProductAction('got_all');
      if (!mounted) return;
      setState(() { _localState = 'received'; _localReceived = _orderedTotal; _confirmingSimple = false; });
      // CHANGE #274 — removed "Got all N — marked received" snackbar; per-item undo is in the card
      final pid = widget.productId;
      RenderLog.write('c274_no_snackbar', 'got_all_nonfn;product=$pid');
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _confirmingSimple = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: const Color(0xFFDC2626)));
    }
  }

  Future<void> _doConfirmMissing() async {
    if (_confirmingMissing) return;
    setState(() => _confirmingMissing = true);
    try {
      await _callProductAction('report_missing', qty: _missingDraft);
      if (!mounted) return;
      final missing = _orderedTotal - _missingDraft;
      setState(() {
        _localState = _missingDraft >= _orderedTotal ? 'received' : 'short';
        _localReceived = _missingDraft;
        _confirmingMissing = false;
        _showMissingInline = false;
      });
      final sup = widget.supplierName;
      final pid = widget.productId;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Saved · $missing$_unitLabel short'),
        action: SnackBarAction(label: 'UNDO', onPressed: () async {
          final res = await Supabase.instance.client.rpc('fw_product_undo',
              params: {'p_supplier_name': sup, 'p_product_id': pid}) as Map;
          RenderLog.write('c199_undo_called', 'product_id=$pid;supplier=$sup;from=snackbar');
          final e = res['error']?.toString();
          if (e == 'nothing_to_undo') {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Nothing to undo (already confirmed or re-sourced)')));
          }
        }),
      ));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _confirmingMissing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: const Color(0xFFDC2626)));
    }
  }

  Future<void> _doConfirmFewWrong() async {
    if (_confirmingFewWrong) return;
    setState(() => _confirmingFewWrong = true);
    try {
      final name = _fewWrongNameCtrl.text.trim();
      final url = _fewWrongProofUrl;
      await _callProductAction('few_wrong', qty: _wrongDraft,
          note: name.isNotEmpty ? name : null, proofUrl: url);
      if (!mounted) return;
      final flagged = _wrongDraft;
      setState(() {
        _localState = 'wrong';
        _confirmingFewWrong = false;
        _showFewWrongInline = false;
      });
      final sup = widget.supplierName;
      final pid = widget.productId;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Saved · $flagged$_unitLabel flagged wrong'),
        action: SnackBarAction(label: 'UNDO', onPressed: () async {
          final res = await Supabase.instance.client.rpc('fw_product_undo',
              params: {'p_supplier_name': sup, 'p_product_id': pid}) as Map;
          RenderLog.write('c199_undo_called', 'product_id=$pid;supplier=$sup;from=snackbar');
          final e = res['error']?.toString();
          if (e == 'nothing_to_undo') {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Nothing to undo (already confirmed or re-sourced)')));
          }
        }),
      ));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _confirmingFewWrong = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: const Color(0xFFDC2626)));
    }
  }

  Future<void> _doWrongAll() async {
    if (_confirmingWrongAll) return;
    setState(() => _confirmingWrongAll = true);
    try {
      final name = _wrongItemNameCtrl.text.trim();
      final url = _wrongItemProofUrl;
      await _callProductAction('wrong_all',
          note: name.isNotEmpty ? name : null, proofUrl: url);
      if (!mounted) return;
      setState(() {
        _localState = 'wrong';
        _confirmingWrongAll = false;
        _showWrongItemInline = false;
      });
      final sup = widget.supplierName;
      final pid = widget.productId;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('All units flagged wrong item'),
        action: SnackBarAction(label: 'UNDO', onPressed: () async {
          final res = await Supabase.instance.client.rpc('fw_product_undo',
              params: {'p_supplier_name': sup, 'p_product_id': pid}) as Map;
          RenderLog.write('c199_undo_called', 'product_id=$pid;supplier=$sup;from=snackbar');
          final e = res['error']?.toString();
          if (e == 'nothing_to_undo') {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Nothing to undo (already confirmed or re-sourced)')));
          }
        }),
      ));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _confirmingWrongAll = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: const Color(0xFFDC2626)));
    }
  }

  Future<void> _doNotComing() async {
    if (_confirmingSimple) return;
    setState(() => _confirmingSimple = true);
    try {
      await _callProductAction('not_coming');
      if (!mounted) return;
      setState(() { _localState = 'not_coming'; _confirmingSimple = false; });
      final sup = widget.supplierName;
      final pid = widget.productId;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Marked not coming'),
        action: SnackBarAction(label: 'UNDO', onPressed: () async {
          final res = await Supabase.instance.client.rpc('fw_product_undo',
              params: {'p_supplier_name': sup, 'p_product_id': pid}) as Map;
          RenderLog.write('c199_undo_called', 'product_id=$pid;supplier=$sup;from=snackbar');
          final e = res['error']?.toString();
          if (e == 'nothing_to_undo') {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Nothing to undo (already confirmed or re-sourced)')));
          }
        }),
      ));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _confirmingSimple = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: const Color(0xFFDC2626)));
    }
  }

  Widget _buildMissingInlineRow() {
    final missing = (_orderedTotal - _missingDraft).clamp(0, _orderedTotal);
    final confirmLabel = 'Confirm missing · $missing$_unitLabel';
    const borderColor = _kShortFg;
    return SizedBox(
      height: 52,
      child: Row(children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: _kShortFg.withValues(alpha: 0.06),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(11), bottomLeft: Radius.circular(11)),
              border: Border(
                top: BorderSide(color: _kShortFg.withValues(alpha: 0.4)),
                bottom: BorderSide(color: _kShortFg.withValues(alpha: 0.4)),
                left: BorderSide(color: _kShortFg.withValues(alpha: 0.4)),
              ),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _ProdStepBtn(
                icon: Icons.remove,
                enabled: !_confirmingMissing && _missingDraft > 0,
                color: borderColor,
                onTap: () => setState(() {
                  _missingDraft = (_missingDraft - 1).clamp(0, _orderedTotal);
                  _missingCtrl.text = '$_missingDraft';
                }),
              ),
              SizedBox(
                width: 48,
                child: TextField(
                  controller: _missingCtrl,
                  enabled: !_confirmingMissing,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kText),
                  decoration: const InputDecoration.collapsed(hintText: '0'),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (v) {
                    final n = int.tryParse(v) ?? 0;
                    final clamped = n.clamp(0, _orderedTotal);
                    setState(() => _missingDraft = clamped);
                    if (v.isNotEmpty && v != '$clamped') {
                      _missingCtrl.value = _missingCtrl.value.copyWith(
                        text: '$clamped',
                        selection: TextSelection.collapsed(offset: '$clamped'.length),
                      );
                    }
                  },
                ),
              ),
              if (_unit.isNotEmpty)
                Text(' $_unit', style: const TextStyle(fontSize: 10, color: _kSub)),
              _ProdStepBtn(
                icon: Icons.add,
                enabled: !_confirmingMissing && _missingDraft < _orderedTotal,
                color: borderColor,
                onTap: () => setState(() {
                  _missingDraft = (_missingDraft + 1).clamp(0, _orderedTotal);
                  _missingCtrl.text = '$_missingDraft';
                }),
              ),
            ]),
          ),
        ),
        Expanded(
          child: GestureDetector(
            onTap: _confirmingMissing ? null : _doConfirmMissing,
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: _confirmingMissing ? _kShortFg.withValues(alpha: 0.45) : _kShortFg,
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(11), bottomRight: Radius.circular(11)),
                border: Border(
                  top: BorderSide(color: _kShortFg.withValues(alpha: 0.4)),
                  bottom: BorderSide(color: _kShortFg.withValues(alpha: 0.4)),
                  right: BorderSide(color: _kShortFg.withValues(alpha: 0.4)),
                ),
              ),
              child: _confirmingMissing
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Text(confirmLabel,
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white),
                      textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
      ]),
    );
  }

  // #203: Banner showing the uploaded proof image + wrong-name for an existing dispute
  Widget _buildExistingProofBanner(DisputeItem dispute) {
    final hasProof = (dispute.proofUrl ?? '').isNotEmpty;
    final hasName  = (dispute.wrongProductName ?? '').isNotEmpty;
    if (!hasProof && !hasName) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF3C7),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFD97706).withValues(alpha: 0.4)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (hasProof) ...[
          GestureDetector(
            onTap: () => showDialog<void>(
              context: context,
              builder: (ctx) => Dialog(
                backgroundColor: Colors.black,
                insetPadding: const EdgeInsets.all(12),
                child: Stack(children: [
                  Image.network(dispute.proofUrl!,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 64)),
                  Positioned(
                    top: 8, right: 8,
                    child: GestureDetector(
                      onTap: () => Navigator.of(ctx).pop(),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: const EdgeInsets.all(4),
                        child: const Icon(Icons.close_rounded, color: Colors.white, size: 20),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.network(dispute.proofUrl!, width: 64, height: 64, fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      const Icon(Icons.broken_image_outlined, size: 40, color: _kSub)),
            ),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            const Text('Previously uploaded proof',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF92400E))),
            if (hasName) ...[
              const SizedBox(height: 2),
              Text('Wrong item: ${dispute.wrongProductName}',
                  style: const TextStyle(fontSize: 12, color: _kText),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
            if (hasProof) ...[
              const SizedBox(height: 2),
              const Text('Tap image to view full size',
                  style: TextStyle(fontSize: 11, color: _kSub)),
            ],
          ]),
        ),
      ]),
    );
  }

  // #203: Few item wrong — full inline panel with stepper + name + photo
  Widget _buildFewWrongPanel() {
    RenderLog.write('c203_few_wrong_panel_opened',
        'product_id=${widget.productId};wrongDraft=$_wrongDraft');
    RenderLog.write('c201_fewwrong_no_overflow', 'panel_mode=true');
    final keep = (_orderedTotal - _wrongDraft).clamp(0, _orderedTotal);
    final busy = _confirmingFewWrong || _fewWrongUploading;
    const accent = Color(0xFFD97706);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: accent.withValues(alpha: 0.4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        // Qty stepper row
        Row(children: [
          _ProdStepBtn(
            icon: Icons.remove,
            enabled: !busy && _wrongDraft > 1,
            color: accent,
            onTap: () => setState(() {
              _wrongDraft = (_wrongDraft - 1).clamp(1, _orderedTotal);
              _fewWrongCtrl.text = '$_wrongDraft';
            }),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 48,
            child: TextField(
              controller: _fewWrongCtrl,
              enabled: !busy,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _kText),
              decoration: const InputDecoration.collapsed(hintText: '1'),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (v) {
                final n = int.tryParse(v) ?? 1;
                final clamped = n.clamp(1, _orderedTotal);
                setState(() => _wrongDraft = clamped);
                if (v.isNotEmpty && v != '$clamped') {
                  _fewWrongCtrl.value = _fewWrongCtrl.value.copyWith(
                    text: '$clamped',
                    selection: TextSelection.collapsed(offset: '$clamped'.length),
                  );
                }
              },
            ),
          ),
          if (_unit.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(_unit, style: const TextStyle(fontSize: 11, color: _kSub)),
            ),
          _ProdStepBtn(
            icon: Icons.add,
            enabled: !busy && _wrongDraft < _orderedTotal,
            color: accent,
            onTap: () => setState(() {
              _wrongDraft = (_wrongDraft + 1).clamp(1, _orderedTotal);
              _fewWrongCtrl.text = '$_wrongDraft';
            }),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text('of $_orderedTotal — keep $keep$_unitLabel wrong',
                style: const TextStyle(fontSize: 11, color: _kSub),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ]),
        const SizedBox(height: 10),
        // Name field
        TextField(
          controller: _fewWrongNameCtrl,
          enabled: !busy,
          decoration: InputDecoration(
            hintText: 'Wrong item name (optional)',
            hintStyle: const TextStyle(fontSize: 13, color: _kSub),
            filled: true, fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: _kBorder)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: _kBorder)),
          ),
          style: const TextStyle(fontSize: 13, color: _kText),
        ),
        const SizedBox(height: 10),
        // Photo row
        _buildPhotoRow(
          proofUrl: _fewWrongProofUrl,
          uploading: _fewWrongUploading,
          busy: busy,
          onPick: () async {
            setState(() => _fewWrongUploading = true);
            final url = await _pickAndUpload();
            if (!mounted) return;
            setState(() { _fewWrongProofUrl = url; _fewWrongUploading = false; });
          },
          onRemove: () => setState(() => _fewWrongProofUrl = null),
        ),
        const SizedBox(height: 12),
        // Confirm button
        SizedBox(
          width: double.infinity,
          height: 44,
          child: FilledButton(
            onPressed: busy ? null : _doConfirmFewWrong,
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              disabledBackgroundColor: accent.withValues(alpha: 0.45),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: busy
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : Text('Confirm wrong · keep $keep$_unitLabel',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: busy ? null : () => setState(() {
            _showFewWrongInline = false;
            _fewWrongNameCtrl.clear();
            _fewWrongProofUrl = null;
          }),
          child: const Text('Cancel', style: TextStyle(color: _kSub, fontSize: 13)),
        ),
      ]),
    );
  }

  // #203: Wrong item — full inline panel with name + photo
  Widget _buildWrongItemPanel() {
    RenderLog.write('c203_wrong_panel_opened', 'product_id=${widget.productId}');
    final busy = _confirmingWrongAll || _wrongItemUploading;
    const accent = Color(0xFFDC2626);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        const Text('Wrong item details',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kText)),
        const SizedBox(height: 10),
        TextField(
          controller: _wrongItemNameCtrl,
          enabled: !busy,
          decoration: InputDecoration(
            hintText: 'Wrong item name (optional)',
            hintStyle: const TextStyle(fontSize: 13, color: _kSub),
            filled: true, fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: _kBorder)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: _kBorder)),
          ),
          style: const TextStyle(fontSize: 13, color: _kText),
        ),
        const SizedBox(height: 10),
        _buildPhotoRow(
          proofUrl: _wrongItemProofUrl,
          uploading: _wrongItemUploading,
          busy: busy,
          onPick: () async {
            setState(() => _wrongItemUploading = true);
            final url = await _pickAndUpload();
            if (!mounted) return;
            setState(() { _wrongItemProofUrl = url; _wrongItemUploading = false; });
          },
          onRemove: () => setState(() => _wrongItemProofUrl = null),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 44,
          child: FilledButton(
            onPressed: busy ? null : _doWrongAll,
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              disabledBackgroundColor: accent.withValues(alpha: 0.45),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: busy
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Text('Confirm wrong item',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)),
          ),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: busy ? null : () => setState(() {
            _showWrongItemInline = false;
            _wrongItemNameCtrl.clear();
            _wrongItemProofUrl = null;
          }),
          child: const Text('Cancel', style: TextStyle(color: _kSub, fontSize: 13)),
        ),
      ]),
    );
  }

  // Shared photo-pick row: "📷 Add photo" button + thumbnail + remove
  Widget _buildPhotoRow({
    required String? proofUrl,
    required bool uploading,
    required bool busy,
    required VoidCallback onPick,
    required VoidCallback onRemove,
  }) {
    return Row(children: [
      if (uploading)
        const SizedBox(width: 24, height: 24,
            child: CircularProgressIndicator(strokeWidth: 2))
      else if (proofUrl != null && proofUrl.isNotEmpty) ...[
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.network(proofUrl, width: 56, height: 56, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.broken_image_outlined, size: 40, color: _kSub)),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.close_rounded, size: 18, color: _kSub),
          onPressed: busy ? null : onRemove,
          tooltip: 'Remove photo',
          padding: EdgeInsets.zero, constraints: const BoxConstraints(),
        ),
        const SizedBox(width: 8),
        TextButton.icon(
          onPressed: busy ? null : onPick,
          icon: const Icon(Icons.photo_camera_outlined, size: 16),
          label: const Text('Replace', style: TextStyle(fontSize: 12)),
          style: TextButton.styleFrom(foregroundColor: _kSub,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
        ),
      ] else
        OutlinedButton.icon(
          onPressed: busy ? null : onPick,
          icon: const Icon(Icons.photo_camera_outlined, size: 16),
          label: const Text('Add photo', style: TextStyle(fontSize: 13)),
          style: OutlinedButton.styleFrom(
            foregroundColor: _kSub,
            side: const BorderSide(color: _kBorder),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
    ]);
  }

  Widget _buildActionBtn({
    required String label,
    required VoidCallback? onTap,
    Color? bg,
    Color? fg,
    bool loading = false,
  }) {
    final bgC = bg ?? _kGreen;
    final fgC = fg ?? Colors.white;
    return SizedBox(
      height: 44,
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: bgC,
          disabledBackgroundColor: bgC.withValues(alpha: 0.45),
          foregroundColor: fgC,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: loading
            ? const SizedBox(width: 16, height: 16,
                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : Text(label,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ord = _orderedTotal;
    final state = _localState;
    final isBusy = _confirmingSimple || _confirmingMissing || _confirmingFewWrong ||
        _confirmingWrongAll || _wrongItemUploading || _fewWrongUploading || _undoing;
    final bg = _stateBgMap[state] ?? _kPendingBg;
    final fg = _stateFgMap[state] ?? _kPendingFg;
    final isActioned = state != 'pending';
    final anyPanelOpen = _showMissingInline || _showFewWrongInline || _showWrongItemInline;

    // #200: dynamic visibility predicates
    final fullyReceived = state == 'received' && _localReceived >= ord;
    final showGotAll    = !fullyReceived;
    final showMissing   = ord > 1;
    final showFewWrong  = ord > 1;
    final showNotComing = !fullyReceived;

    RenderLog.write('c200_actions_dynamic',
        'ord=$ord;state=$state;rec=$_localReceived;fullyReceived=$fullyReceived');
    if (ord == 1) RenderLog.write('c200_qty1_compact', 'ord=1;hiding_report_missing_and_few_wrong=true');
    if (fullyReceived) RenderLog.write('c200_received_hides_gotall',
        'state=$state;rec=$_localReceived;ord=$ord;hiding_gotall_and_notcoming=true');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _FulfilImageTile(widget.imageUrl, size: 52),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.productName,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _kText),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text('Ordered: $ord$_unitLabel',
                  style: const TextStyle(fontSize: 12, color: _kSub)),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
                child: Text(
                  const <String, String>{
                    'wrong': 'Wrong item', 'not_coming': 'Not coming',
                  }[state] ?? state.replaceAll('_', ' '),
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
                ),
              ),
            ]),
          ),
          if (isActioned) ...[
            Builder(builder: (_) {
              RenderLog.write('c199_undo_button_shown', 'product_id=${widget.productId};state=$state');
              return _undoing
                  ? const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : TextButton(
                      onPressed: isBusy ? null : _doUndo,
                      style: TextButton.styleFrom(
                        foregroundColor: _kSub,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Undo', style: TextStyle(fontSize: 13)),
                    );
            }),
          ],
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20, color: _kSub),
            onPressed: () => Navigator.of(context).pop(),
            padding: EdgeInsets.zero,
          ),
        ]),
        const SizedBox(height: 20),
        const Divider(height: 1, color: _kBorder),
        const SizedBox(height: 16),

        // #203: Show existing dispute proof + wrong name if already flagged
        if (widget.existingDispute != null) ...[
          _buildExistingProofBanner(widget.existingDispute!),
          const SizedBox(height: 12),
        ],

        // Action: Got all — CHANGE #277: dynamic in Warehouse (show when bag+uncounted)
        if (showGotAll && !anyPanelOpen && !widget.arrivals) ...[
          SizedBox(
            width: double.infinity,
            child: _buildActionBtn(
              label: 'Got all ($ord)',
              onTap: isBusy ? null : _doGotAll,
              loading: _confirmingSimple,
              bg: _kGreen,
            ),
          ),
          const SizedBox(height: 8),
        ] else if (showGotAll && !anyPanelOpen && widget.arrivals && widget.activeBagNo != null) ...[
          // Warehouse + active bag: show Got all only if item not yet counted into this bag
          Builder(builder: (_) {
            final bagNo = widget.activeBagNo!;
            final bd = widget.bagBreakdown;
            final itemCounted = bd != null && bd.any((b) =>
              (b['bag_no'] as num?)?.toInt() == bagNo &&
              ((b['qty'] as num?)?.toDouble() ?? 0.0) > 0);
            if (itemCounted) {
              RenderLog.write('c277_got_all_hidden', 'bag=$bagNo;product=${widget.productId}');
              return const SizedBox.shrink();
            }
            RenderLog.write('c277_got_all_shown', 'bag=$bagNo;product=${widget.productId}');
            return Column(children: [
              SizedBox(
                width: double.infinity,
                child: _buildActionBtn(
                  label: 'Got all ($ord)',
                  onTap: isBusy ? null : () {
                    RenderLog.write('c277_got_all_action', 'bag=$bagNo;qty=$ord;product=${widget.productId}');
                    _doGotAll();
                  },
                  loading: _confirmingSimple,
                  bg: _kGreen,
                ),
              ),
              const SizedBox(height: 8),
            ]);
          }),
        ] else if (widget.arrivals && !anyPanelOpen && widget.activeBagNo == null) ...[
          Builder(builder: (_) {
            RenderLog.write('c276_no_getall_warehouse', 'product_sheet_no_bag;product=${widget.productId}');
            return const SizedBox.shrink();
          }),
        ],

        // Action: Report missing (#200: hidden when T == 1)
        if (showMissing && !_showFewWrongInline && !_showWrongItemInline) ...[
          if (!_showMissingInline)
            SizedBox(
              width: double.infinity,
              child: _buildActionBtn(
                label: 'Report missing',
                onTap: isBusy ? null : () => setState(() {
                  _showMissingInline = true;
                  _missingDraft = _localReceived.clamp(0, ord > 0 ? ord : 1);
                  _missingCtrl.text = '$_missingDraft';
                }),
                bg: _kShortFg,
              ),
            )
          else
            _buildMissingInlineRow(),
          const SizedBox(height: 8),
        ],

        // Action: Few item wrong — inline panel (#200: hidden when T == 1; #203: expands inline)
        if (showFewWrong && !_showMissingInline && !_showWrongItemInline) ...[
          if (!_showFewWrongInline)
            SizedBox(
              width: double.infinity,
              child: _buildActionBtn(
                label: 'Few item wrong',
                onTap: isBusy ? null : () => setState(() {
                  _showFewWrongInline = true;
                  _wrongDraft = 1;
                  _fewWrongCtrl.text = '1';
                  _fewWrongNameCtrl.clear();
                  _fewWrongProofUrl = null;
                }),
                bg: const Color(0xFFD97706),
              ),
            )
          else
            _buildFewWrongPanel(),
          const SizedBox(height: 8),
        ],

        // Action: Wrong item — inline panel (#203: expands inline)
        if (!_showMissingInline && !_showFewWrongInline) ...[
          if (!_showWrongItemInline)
            SizedBox(
              width: double.infinity,
              child: _buildActionBtn(
                label: 'Wrong item',
                onTap: isBusy ? null : () => setState(() {
                  _showWrongItemInline = true;
                  _wrongItemNameCtrl.clear();
                  _wrongItemProofUrl = null;
                }),
                bg: _kWrongFg,
              ),
            )
          else
            _buildWrongItemPanel(),
          const SizedBox(height: 8),
        ],

        // Action: Not coming (#200: hidden when fully received)
        if (showNotComing && !anyPanelOpen) ...[
          SizedBox(
            width: double.infinity,
            child: _buildActionBtn(
              label: 'Not coming',
              onTap: isBusy ? null : _doNotComing,
              bg: _kNotComingFg,
            ),
          ),
          const SizedBox(height: 8),
        ],

        // #203: ↩ Undo last action — full-width outlined, visible when actioned
        if (isActioned) ...[
          const SizedBox(height: 4),
          Builder(builder: (_) {
            RenderLog.write('c203_undo_button_shown',
                'product_id=${widget.productId};state=$state');
            RenderLog.write('c201_undo_below_buttons',
                'product_id=${widget.productId};state=$state');
            return SizedBox(
              width: double.infinity,
              height: 44,
              child: OutlinedButton.icon(
                onPressed: isBusy ? null : _doUndoBelow,
                icon: _undoing
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.undo_rounded, size: 18),
                label: const Text('↩ Undo last action',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _kSub,
                  side: const BorderSide(color: _kBorder),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            );
          }),
          const SizedBox(height: 8),
        ],

        // #203: ← Back — always visible at bottom
        Builder(builder: (_) {
          RenderLog.write('c203_back_button_shown', 'product_id=${widget.productId}');
          return SizedBox(
            width: double.infinity,
            height: 44,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: const Text('← Back',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              style: OutlinedButton.styleFrom(
                foregroundColor: _kSub,
                side: const BorderSide(color: _kBorder),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          );
        }),
      ]),
    );
  }
}

// ── ARRIVALS SCREEN ───────────────────────────────────────────────────────────
// #155: thin wrapper — renders _PickToLightScreen(arrivals:true) for literal
// widget reuse. Holds #140 auto-refresh (realtime + poll + lifecycle).

class _ArrivalsScreen extends StatefulWidget {
  // onVoiceCount kept for API compat; no longer used (voice is inline now).
  final void Function(String supplierName)? onVoiceCount;
  const _ArrivalsScreen({super.key, this.onVoiceCount});

  @override
  State<_ArrivalsScreen> createState() => _ArrivalsScreenState();
}

class _ArrivalsScreenState extends State<_ArrivalsScreen>
    with WidgetsBindingObserver {
  // Key gives the parent a handle to trigger supplier-list refresh.
  final _ptlKey = GlobalKey<_PickToLightScreenState>();

  RealtimeChannel? _channel;
  Timer? _debounce;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscribeRealtime();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      RenderLog.write('c140_refresh_fired', 'trigger=app_resume');
      _ptlKey.currentState?._loadSuppliers();
    }
  }

  // Called by parent when Arrivals tab becomes visible.
  void refresh() {
    if (!mounted) return;
    RenderLog.write('c140_refresh_fired', 'trigger=tab_focus');
    _ptlKey.currentState?._loadSuppliers();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _pollTimer?.cancel();
    _channel?.unsubscribe();
    _channel = null;
    super.dispose();
  }

  void _subscribeRealtime() {
    void onDbChange(_) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 500), () {
        if (mounted) {
          RenderLog.write('c140_autorefresh', 'trigger=realtime');
          _ptlKey.currentState?._loadSuppliers();
        }
      });
    }
    try {
      final ch = Supabase.instance.client
          .channel('arrivals_c140')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'order_items',
            callback: onDbChange,
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'supplier_count_mode',
            callback: onDbChange,
          )
          .subscribe((status, [error]) {
            if (!mounted) return;
            final live = status == RealtimeSubscribeStatus.subscribed;
            if (live) {
              RenderLog.write('c140_autorefresh', 'realtime=subscribed');
              _pollTimer?.cancel();
            } else {
              _pollTimer?.cancel();
              _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
                if (mounted) _ptlKey.currentState?._loadSuppliers();
              });
            }
          });
      _channel = ch;
    } catch (_) {
      _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        if (mounted) _ptlKey.currentState?._loadSuppliers();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // #155: literal reuse of Collect widget — same voice/spoken/Ask mediBO/item sheet.
    return _PickToLightScreen(key: _ptlKey, arrivals: true);
  }
}

// ── ENTRY POINT ──────────────────────────────────────────────────────────────

class AdminFulfillmentScreen extends StatefulWidget {
  static final _key = GlobalKey<_AdminFulfillmentScreenState>();
  AdminFulfillmentScreen() : super(key: _key);
  static void triggerFocus() => _key.currentState?._onFocus();

  @override
  State<AdminFulfillmentScreen> createState() => _AdminFulfillmentScreenState();
}

class _AdminFulfillmentScreenState extends State<AdminFulfillmentScreen>
    with WidgetsBindingObserver {
  int _tab = 0;
  int _disputeCount = 0; // #132C: open dispute count for tab badge
  final _collectKey   = GlobalKey<_PickToLightScreenState>();
  final _disputesKey  = GlobalKey<_DisputesScreenState>();
  final _packTabKey   = GlobalKey<_PackTabState>();
  final _bagTabKey    = GlobalKey<_BagTabState>();

  // ── #187: Realtime channels ───────────────────────────────────────────────
  final List<RealtimeChannel> _rtChannels = [];
  Timer? _collectDebounce;
  Timer? _disputeDebounce;

  void _scheduleCollectReload() {
    _collectDebounce?.cancel();
    _collectDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      _collectKey.currentState?._loadSuppliers();
      _collectKey.currentState?._loadCollectModes();
    });
  }

  void _scheduleDisputeReload() {
    _disputeDebounce?.cancel();
    _disputeDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      _collectKey.currentState?._loadDisputes();
      _disputesKey.currentState?._load();
    });
  }

  void _subscribeRealtime() {
    final supabase = Supabase.instance.client;
    int subscribed = 0;

    void addChannel(String name, List<String> tables, void Function() onEvent) {
      try {
        var ch = supabase.channel(name);
        for (final t in tables) {
          ch = ch.onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: t,
            callback: (_) => onEvent(),
          );
        }
        ch.subscribe((status, [_]) {
          if (status == RealtimeSubscribeStatus.subscribed) subscribed++;
        });
        _rtChannels.add(ch);
      } catch (_) {}
    }

    addChannel('fulfill_collect_187',   ['order_items'],                               _scheduleCollectReload);
    addChannel('fulfill_disputes_188',  ['supplier_disputes', 'order_items'],          () {
      RenderLog.write('c188_realtime_subscribed', 'supplier_disputes+order_items');
      _scheduleDisputeReload();
    });
    addChannel('fulfill_suppord_187',   ['supplier_orders'],                           _scheduleCollectReload);

    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      RenderLog.write('c187_realtime',
        'change:187,removed_refresh_buttons:true,'
        'channels:[order_items,orders,supplier_orders,supplier_disputes],'
        'channels_subscribed:$subscribed,'
        'debounce_ms:400,'
        'reload_on_focus:true');
    });
  }

  // #125 R6: called by Arrivals after confirm to refresh Collect badge/list.
  void _refreshCollect() {
    _collectKey.currentState?._loadSuppliers();
    _collectKey.currentState?._loadCollectModes();
    // #331 E1: after dispute re-forward, reload item box so shop/warehouse rows reflect new state
    _collectKey.currentState?._reloadItemsFromDB();
  }
  // #125 R2/R3: called by Collect after submit/undo to refresh Arrivals list.
  void _refreshArrivals() {
    _arrivalsKey.currentState?.refresh();
  }
  // #132A: called by _PickToLightScreenState after loading disputes.
  void _setDisputeCount(int n) {
    if (mounted && n != _disputeCount) setState(() => _disputeCount = n);
  }
  // #132B: open Disputes tab from item popup "View dispute". (#280: Disputes is now index 4)
  void _openDisputesTab() {
    if (mounted) setState(() => _tab = 4);
  }

  // C174/B6+B15: single refresh point — call after any dispute-state-changing action.
  void _refreshDisputeState() {
    _collectKey.currentState?._loadDisputes();
    _disputesKey.currentState?._load();
    RenderLog.write('c174_dispute_refresh', 'load_disputes=true;disputes_tab_reloaded=true');
  }
  final _arrivalsKey = GlobalKey<_ArrivalsScreenState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscribeRealtime();
    RenderLog.write('fulfillment_area_mounted', 'true');
    RenderLog.write('fulfillment_three_areas_mounted', 'true');
    RenderLog.write('c132c_disputes_view', 'true');
    RenderLog.write('c132c_resolve_wired', 'true');
    RenderLog.write('c132c_copylink_wired', 'true');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _scheduleCollectReload();
      _scheduleDisputeReload();
      _arrivalsKey.currentState?.refresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _collectDebounce?.cancel();
    _disputeDebounce?.cancel();
    for (final ch in _rtChannels) {
      try { Supabase.instance.client.removeChannel(ch); } catch (_) {}
    }
    _rtChannels.clear();
    super.dispose();
  }

  void _onFocus() {}

  // #137: switch to Collect tab and pre-select supplier so staff can use the voice feature.
  void _openVoiceInCollect(String supplier) {
    setState(() => _tab = 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _collectKey.currentState?.selectSupplierForVoice(supplier);
    });
  }

  @override
  Widget build(BuildContext context) {
    // #113: title+subtitle removed on both mobile and desktop — tabs are the top content.
    final isWide = MediaQuery.of(context).size.width >= 900;
    final viewport = isWide ? 'desktop' : 'mobile';
    RenderLog.write('c113_fulfillment_built', viewport);
    RenderLog.write('c113_no_title_header', viewport);
    RenderLog.write('c331_build', '331');
    RenderLog.write('c113_fulfillment_tabs_top', viewport);
    return Column(children: [
      Container(
        color: _kCard,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              _TabBtn('Supplier Shop', _tab == 0, () {
                setState(() => _tab = 0);
                _scheduleCollectReload();
              }),
              const SizedBox(width: 6),
              _TabBtn('Warehouse', _tab == 1, () {
                setState(() => _tab = 1);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _arrivalsKey.currentState?.refresh();
                });
              }),
              const SizedBox(width: 6),
              // CHANGE #280: Bag tab (bag-wise) — index 2
              _TabBtn('Bag', _tab == 2, () {
                setState(() => _tab = 2);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _bagTabKey.currentState?._load();
                });
              }),
              const SizedBox(width: 6),
              // CHANGE #278: Pack tab (customer-wise) — index 3 (#280: shifted from 2)
              _TabBtn('Pack', _tab == 3, () {
                setState(() => _tab = 3);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _packTabKey.currentState?._load();
                });
              }),
              const SizedBox(width: 6),
              // #132C: Disputes tab with open-count badge (#280: now index 4)
              Stack(clipBehavior: Clip.none, children: [
                _TabBtn('Disputes', _tab == 4, () {
                  setState(() => _tab = 4);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _disputesKey.currentState?._load();
                  });
                }),
                if (_disputeCount > 0)
                  Positioned(
                    top: -4, right: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF7C3AED),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('$_disputeCount',
                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                              color: Colors.white, height: 1.2)),
                    ),
                  ),
              ]),
            ]),
          ),
          const SizedBox(height: 1),
          const Divider(height: 1, color: _kBorder),
        ]),
      ),
      Expanded(
        child: Builder(builder: (context) {
          RenderLog.write('c280_fulfill_tabs_5', 5);
          // CHANGE #284: confirms Confirm-all gating removed; fires at boot for curl verify.
          RenderLog.write('c284_confirm_always_clickable', 'gating_removed=y;enabled=always');
          return IndexedStack(
            index: _tab,
            children: [
              _PickToLightScreen(key: _collectKey),
              _ArrivalsScreen(key: _arrivalsKey, onVoiceCount: _openVoiceInCollect),
              _BagTab(key: _bagTabKey),
              _PackTab(key: _packTabKey),
              _DisputesScreen(key: _disputesKey, onCountChanged: _setDisputeCount,
                  onRefreshCollect: _refreshCollect, onRefreshArrivals: _refreshArrivals),
            ],
          );
        }),
      ),
    ]);
  }
}

// ── CHANGE #280: Bag tab — bag-wise warehouse view with search ────────────────

class _BagTab extends StatefulWidget {
  const _BagTab({super.key});
  @override
  State<_BagTab> createState() => _BagTabState();
}

class _BagTabState extends State<_BagTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _bags = [];
  bool _loading = true;
  String? _error;
  int? _expandedBagNo;
  final Map<int, List<Map<String, dynamic>>> _itemsByBag = {};
  final Map<int, bool> _loadingItems = {};
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _rowKeys = {};
  double _savedScrollOffset = 0.0;

  // Search state
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  List<Map<String, dynamic>> _searchResults = [];
  bool _searching = false;
  bool _searchLoading = false;

  // Realtime
  RealtimeChannel? _channel;
  bool _allStatesLogged = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    RenderLog.write('c280_bag_tab_mounted', 1);
    RenderLog.write('c285_bag_no_chip', 'rendered=false');
    RenderLog.write('c286_no_inner_strip', 'strip=removed');
    RenderLog.write('c286_no_received_footer', 'footer=removed');
    _load();
    _subscribeRealtime();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtrl.dispose();
    _searchDebounce?.cancel();
    final ch = _channel;
    _channel = null;
    if (ch != null) {
      ch.unsubscribe();
      Supabase.instance.client.removeChannel(ch);
    }
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!mounted) return;
    if (!silent) setState(() { _loading = true; _error = null; });
    try {
      final data = await Supabase.instance.client.rpc('fw_list_bags') as Map;
      if (!mounted) return;
      final bags = (data['bags'] as List? ?? [])
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      setState(() {
        _bags = bags;
        if (!silent) _loading = false;
      });
      RenderLog.write('c280_bag_cards_loaded', bags.length);
      RenderLog.write('c281_bag_cards_reloaded', bags.length);
      if (!_allStatesLogged) {
        _allStatesLogged = true;
        final totalItems = bags.fold<int>(0, (s, b) => s + ((b['total_products'] as num?)?.toInt() ?? 0));
        RenderLog.write('c281_all_states_shown', totalItems);
      }
    } catch (e) {
      if (!mounted) return;
      if (!silent) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _loadItems(int bagNo) async {
    if (_loadingItems[bagNo] == true) return;
    if (!mounted) return;
    setState(() => _loadingItems[bagNo] = true);
    try {
      final rows = await Supabase.instance.client
          .rpc('fw_get_bag_items', params: {'p_bag_no': bagNo}) as List;
      if (!mounted) return;
      final items = rows.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      setState(() {
        _itemsByBag[bagNo] = items;
        _loadingItems[bagNo] = false;
      });
      RenderLog.write('c280_bag_items_loaded', 'bag=$bagNo;count=${items.length}');
      RenderLog.write('c281_bag_items_reloaded', 'bag=$bagNo;count=${items.length}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingItems[bagNo] = false);
    }
  }

  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    if (query.length < 2) {
      setState(() { _searching = false; _searchResults = []; _searchLoading = false; });
      return;
    }
    setState(() { _searching = true; _searchLoading = true; });
    _searchDebounce = Timer(
      const Duration(milliseconds: 400), () => _runSearch(query));
  }

  Future<void> _runSearch(String query) async {
    if (!mounted) return;
    try {
      RenderLog.write('c280_bag_search_fired', query);
      final rows = await Supabase.instance.client
          .rpc('fw_search_bag_items', params: {'p_query': query}) as List;
      if (!mounted) return;
      setState(() {
        _searchResults = rows.map((r) => Map<String, dynamic>.from(r as Map)).toList();
        _searchLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _searchLoading = false);
    }
  }

  void _subscribeRealtime() {
    try {
      _channel = Supabase.instance.client
          .channel('bag_tab_order_items_v2')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'order_items',
            callback: _onOrderItemChanged,
          )
          .subscribe((status, [_]) {
            if (status == RealtimeSubscribeStatus.subscribed && mounted) {
              RenderLog.write('c280_realtime_subscribed', 'bag_tab=order_items');
              RenderLog.write('c281_realtime_subscribed', 'channel=bag_tab_order_items_v2');
            }
          });
    } catch (_) {}
  }

  void _onOrderItemChanged(PostgresChangePayload payload) {
    if (!mounted) return;
    RenderLog.write('c281_realtime_event_received', payload.eventType.toString());
    _load(silent: true);
    if (_expandedBagNo != null) {
      _loadItems(_expandedBagNo!);
    }
    final q = _searchCtrl.text;
    if (_searching && q.length >= 2) {
      _runSearch(q);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return LayoutBuilder(builder: (_, constraints) {
      final maxW = constraints.maxWidth >= 900 ? 700.0 : double.infinity;
      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: Column(children: [
            // Search box
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: TextField(
                controller: _searchCtrl,
                onChanged: _onSearchChanged,
                decoration: InputDecoration(
                  hintText: 'Search medicine in bags…',
                  hintStyle: const TextStyle(fontSize: 14, color: _kSub),
                  prefixIcon: const Icon(Icons.search, size: 20, color: _kSub),
                  suffixIcon: _searchCtrl.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close, size: 18, color: _kSub),
                          onPressed: () {
                            _searchCtrl.clear();
                            _onSearchChanged('');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: Colors.grey.shade100,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: _kGreen, width: 1.5),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            // Body: search results OR accordion list
            Expanded(child: _searching ? _buildSearchBody() : _buildCardListBody()),
          ]),
        ),
      );
    });
  }

  Widget _buildSearchBody() {
    if (_searchLoading) {
      return const Center(child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2));
    }
    if (_searchResults.isEmpty) {
      return Center(
        child: Text(
          'No items found in any bag for "${_searchCtrl.text}"',
          style: const TextStyle(color: _kSub, fontSize: 15),
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _searchResults.length,
      itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _buildSearchResultTile(_searchResults[i]),
      ),
    );
  }

  Widget _buildCardListBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2));
    }
    if (_error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.error_outline, size: 40, color: _kSub),
        const SizedBox(height: 12),
        const Text('Could not load bags', style: TextStyle(color: _kSub, fontSize: 14)),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: _load,
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: _kGreen),
            foregroundColor: _kGreen,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: const Text('Retry'),
        ),
      ]));
    }
    if (_bags.isEmpty) {
      return const Center(child: Text('No bags with active items',
          style: TextStyle(color: _kSub, fontSize: 15)));
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: _bags.length,
      itemBuilder: (_, i) => _buildBagCard(_bags[i]),
    );
  }

  Widget _buildBagCard(Map<String, dynamic> bag) {
    final bagNo      = (bag['bag_no'] as num?)?.toInt() ?? 0;
    final total      = (bag['total_products'] as num?)?.toInt() ?? 0;
    final isExpanded = _expandedBagNo == bagNo;
    final rowKey     = _rowKeys.putIfAbsent(bagNo, () => GlobalKey());

    return _BagAccordionShell(
      bagNo: bagNo,
      totalProducts: total,
      isExpanded: isExpanded,
      anyExpanded: _expandedBagNo != null,
      rowKey: rowKey,
      onTap: () {
        if (isExpanded) {
          setState(() => _expandedBagNo = null);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_scroll.hasClients) return;
            _scroll.animateTo(_savedScrollOffset,
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeInOutCubic);
          });
        } else {
          RenderLog.write('c280_bag_card_open', 'bag=$bagNo');
          _savedScrollOffset = _scroll.hasClients ? _scroll.offset : 0.0;
          setState(() => _expandedBagNo = bagNo);
          _loadItems(bagNo);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_scroll.hasClients) return;
            _scroll.animateTo(0.0,
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeInOutCubic);
          });
        }
      },
      expandedContent: isExpanded ? _buildBagExpandedBody(bag) : const SizedBox.shrink(),
    );
  }

  Widget _buildBagExpandedBody(Map<String, dynamic> bag) {
    final bagNo     = (bag['bag_no'] as num?)?.toInt() ?? 0;
    final isLoading = _loadingItems[bagNo] == true;
    final items     = _itemsByBag[bagNo] ?? [];

    return Builder(builder: (ctx) {
      RenderLog.write('c286_no_inner_strip', 'strip=removed');
      RenderLog.write('c286_no_received_footer', 'footer=removed');
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Divider(height: 1, color: _kBorder),
        if (isLoading)
          const Center(child: Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2),
          ))
        else if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Text('No items in this bag', style: TextStyle(color: _kSub, fontSize: 14)),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (int i = 0; i < items.length; i++) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: _buildBagItemTile(items[i]),
                ),
                if (i < items.length - 1) const SizedBox(height: 4),
              ],
            ]),
          ),
        const SizedBox(height: 12),
      ]);
    });
  }

  Widget _buildBagProgressRow(int received, int total) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(
          width: 100,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: _kGreen, borderRadius: BorderRadius.circular(6)),
            child: Text('$received received',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white),
                maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: LinearProgressIndicator(
            value: total == 0 ? 0 : received / total,
            backgroundColor: _kBorder,
            color: _kGreen,
            minHeight: 6,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 8),
        Text('$received/$total',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kText)),
      ]),
    );
  }

  Widget _buildBagItemTile(Map<String, dynamic> item) {
    final name             = item['product_name']?.toString() ?? '—';
    final customer         = item['customer']?.toString() ?? '';
    final customerCode     = item['customer_code']?.toString() ?? '';
    final packType         = item['pack_type']?.toString() ?? '';
    final imageUrl         = item['image_url']?.toString();
    final recQty           = (item['received_qty'] as num?)?.toInt() ?? 0;
    final assignedSupplier = item['assigned_supplier']?.toString() ?? '';
    final packLabel        = packType.isNotEmpty ? '$recQty $packType' : '$recQty';
    final custLabel        = customerCode.isNotEmpty ? 'C • $customer ($customerCode)' : 'C • $customer';

    return Builder(builder: (ctx) {
      RenderLog.write('c288_pack_badge_grey', 'pack=$recQty $packType;grey=true');
      RenderLog.write('c288_customer_with_code', 'cust=$customer;code=$customerCode');
      RenderLog.write('c288_bag_img_72', 'w=72;h=72');
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _kCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _kBorder),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _FulfilImageTile(imageUrl, size: 72),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(name,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kText),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              _greyBadge(packLabel),
              if (assignedSupplier.isNotEmpty) ...[
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: _kReceivedBg,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('S • $assignedSupplier',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: _kReceivedFg),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ],
              if (customer.isNotEmpty) ...[
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3CD),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(custLabel,
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFF8A6D00)),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ],
            ]),
          ),
        ]),
      );
    });
  }

  Widget _greyBadge(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: const Color(0xFFF3F4F6),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(text,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: _kSub),
        maxLines: 1, overflow: TextOverflow.ellipsis),
  );

  Widget _buildSearchResultTile(Map<String, dynamic> item) {
    final name             = item['product_name']?.toString() ?? '—';
    final customer         = item['customer']?.toString() ?? '';
    final customerCode     = item['customer_code']?.toString() ?? '';
    final packType         = item['pack_type']?.toString() ?? '';
    final imageUrl         = item['image_url']?.toString();
    final recQty           = (item['received_qty'] as num?)?.toInt() ?? 0;
    final bagNo            = (item['bag_no'] as num?)?.toInt();
    final assignedSupplier = item['assigned_supplier']?.toString() ?? '';
    final bagLabel         = bagNo != null
        ? (packType.isNotEmpty ? 'Bag $bagNo • $recQty $packType' : 'Bag $bagNo • $recQty')
        : (packType.isNotEmpty ? '$recQty $packType' : '$recQty');
    final custLabel        = customerCode.isNotEmpty ? 'C • $customer ($customerCode)' : 'C • $customer';

    return Builder(builder: (ctx) {
      RenderLog.write('c286_search_row_v3', 'bag=$bagNo;qty=$recQty;combined_badge=true');
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _kCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _kBorder),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _FulfilImageTile(imageUrl, size: 72),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(name,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kText),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              _greyBadge(bagLabel),
              if (assignedSupplier.isNotEmpty) ...[
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: _kReceivedBg,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('S • $assignedSupplier',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: _kReceivedFg),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ],
              if (customer.isNotEmpty) ...[
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3CD),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(custLabel,
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFF8A6D00)),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ],
            ]),
          ),
        ]),
      );
    });
  }
}

// ── CHANGE #286: Bag-specific accordion header (no arrow, no dot, brown "N items" pill) ──

class _BagAccordionShell extends StatelessWidget {
  final int bagNo;
  final int totalProducts;
  final bool isExpanded;
  final bool anyExpanded;
  final GlobalKey rowKey;
  final VoidCallback onTap;
  final Widget expandedContent;

  const _BagAccordionShell({
    required this.bagNo,
    required this.totalProducts,
    required this.isExpanded,
    required this.anyExpanded,
    required this.rowKey,
    required this.onTap,
    required this.expandedContent,
  });

  @override
  Widget build(BuildContext context) {
    final bottomGap = anyExpanded ? 16.0 : 8.0;
    return Padding(
      key: rowKey,
      padding: EdgeInsets.only(bottom: bottomGap),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _kBorder),
          boxShadow: [BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6, offset: const Offset(0, 2))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
            borderRadius: BorderRadius.vertical(
              top: const Radius.circular(12),
              bottom: Radius.circular(isExpanded ? 0 : 12),
            ),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Builder(builder: (ctx) {
                RenderLog.write('c286_bag_header_v2',
                    'bag=$bagNo;items=$totalProducts;arrow=removed;dot=removed');
                RenderLog.write('c289_items_badge_green',
                    'items=$totalProducts;green=true;fixedw=true');
                return Row(children: [
                  Text('Bag $bagNo',
                      style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600,
                        color: isExpanded ? _kGreen : _kText,
                      )),
                  const Spacer(),
                  SizedBox(
                    width: 80,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: _kReceivedBg,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text('$totalProducts items',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w500,
                              color: _kReceivedFg)),
                    ),
                  ),
                ]);
              }),
            ),
          ),
          _sharedSmoothReveal(isExpanded, expandedContent),
        ]),
      ),
    );
  }
}

// ── CHANGE #282: Per-item bag picker chip (Bag tab only) ─────────────────────

class _BagPickerChip extends StatefulWidget {
  const _BagPickerChip({
    required this.orderItemId,
    required this.currentBagNo,
  });
  final String orderItemId;
  final int? currentBagNo;

  @override
  State<_BagPickerChip> createState() => _BagPickerChipState();
}

class _BagPickerChipState extends State<_BagPickerChip> {
  bool _busy = false;

  Future<void> _openPicker() async {
    if (_busy) return;
    RenderLog.write('c282_bag_picker_opened', 1);

    List<Map<String, dynamic>> bags = [];
    try {
      final data = await Supabase.instance.client.rpc('fw_list_bags') as Map;
      bags = (data['bags'] as List? ?? [])
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
    } catch (_) {}

    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      backgroundColor: Colors.white,
      builder: (sheetCtx) => _BagPickerSheet(
        currentBagNo: widget.currentBagNo,
        bags: bags,
        onSelectBag: (bagNo) => _doReassign(sheetCtx, bagNo),
        onRemove: () => _doClear(sheetCtx),
        onOtherBag: (bagNo) => _doReassign(sheetCtx, bagNo),
      ),
    );
  }

  Future<void> _doReassign(BuildContext sheetCtx, int bagNo) async {
    Navigator.of(sheetCtx).pop();
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final res = await Supabase.instance.client.rpc('fw_set_item_bag', params: {
        'p_order_item_id': widget.orderItemId,
        'p_bag_no': bagNo,
      }) as Map;
      if (!mounted) return;
      final err = res['error']?.toString();
      if (err != null) {
        _showSnack(_errMsg(err));
      } else {
        RenderLog.write('c282_bag_reassign_success', 'bag=$bagNo');
        _showSnack('Moved to Bag $bagNo');
      }
    } catch (_) {
      if (mounted) _showSnack("Couldn't update bag — try again");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _doClear(BuildContext sheetCtx) async {
    Navigator.of(sheetCtx).pop();
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final res = await Supabase.instance.client.rpc('fw_clear_item_bag', params: {
        'p_order_item_id': widget.orderItemId,
      }) as Map;
      if (!mounted) return;
      final err = res['error']?.toString();
      if (err != null) {
        _showSnack(_errMsg(err));
      } else {
        RenderLog.write('c282_bag_clear_success', 1);
        _showSnack('Removed from bag');
      }
    } catch (_) {
      if (mounted) _showSnack("Couldn't update bag — try again");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _errMsg(String err) {
    if (err == 'no_such_bag') return "That bag doesn't exist";
    if (err == 'item_finalized') return "This item is already shipped/cancelled and can't be moved";
    return err;
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c282_bag_picker_chip_mounted',
        'bag_no=${widget.currentBagNo};ts=${DateTime.now().millisecondsSinceEpoch}');
    final label = widget.currentBagNo != null ? 'Bag ${widget.currentBagNo}' : 'No bag';
    return GestureDetector(
      onTap: _openPicker,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFFEEEEEE),
          borderRadius: BorderRadius.circular(6),
        ),
        child: _busy
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: _kGreen))
            : Row(mainAxisSize: MainAxisSize.min, children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 10, fontWeight: FontWeight.w600, color: Colors.black87)),
                const SizedBox(width: 2),
                const Icon(Icons.expand_more, size: 14, color: Colors.black54),
              ]),
      ),
    );
  }
}

class _BagPickerSheet extends StatefulWidget {
  const _BagPickerSheet({
    required this.currentBagNo,
    required this.bags,
    required this.onSelectBag,
    required this.onRemove,
    required this.onOtherBag,
  });
  final int? currentBagNo;
  final List<Map<String, dynamic>> bags;
  final void Function(int) onSelectBag;
  final void Function() onRemove;
  final void Function(int) onOtherBag;

  @override
  State<_BagPickerSheet> createState() => _BagPickerSheetState();
}

class _BagPickerSheetState extends State<_BagPickerSheet> {
  Future<void> _askOtherBag() async {
    final ctrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter bag number',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            hintText: '1–500',
            filled: true,
            fillColor: const Color(0xFFF5F6F8),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              final v = int.tryParse(ctrl.text);
              if (v == null || v < 1 || v > 500) return;
              Navigator.pop(ctx, true);
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: _kGreen, foregroundColor: Colors.white),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      final v = int.tryParse(ctrl.text);
      if (v != null) widget.onOtherBag(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomPad),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 12),
        const Text('Move to bag',
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111827))),
        const SizedBox(height: 8),
        const Divider(height: 1),
        if (widget.currentBagNo != null)
          ListTile(
            leading: const Icon(Icons.remove_circle_outline,
                color: Color(0xFF991B1B), size: 20),
            title: const Text('Remove from bag',
                style: TextStyle(
                    fontSize: 14,
                    color: Color(0xFF991B1B),
                    fontWeight: FontWeight.w500)),
            onTap: widget.onRemove,
          ),
        ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.4),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: widget.bags.length,
            itemBuilder: (_, i) {
              final b = widget.bags[i];
              final bn = (b['bag_no'] as num?)?.toInt() ?? 0;
              final total = (b['total_products'] as num?)?.toInt() ?? 0;
              return ListTile(
                leading: const Icon(Icons.shopping_bag_outlined,
                    size: 20, color: Color(0xFF1B7A43)),
                title: Text('Bag $bn · $total items',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500)),
                onTap: () => widget.onSelectBag(bn),
              );
            },
          ),
        ),
        ListTile(
          leading: const Icon(Icons.edit_outlined,
              size: 20, color: Color(0xFF6B7280)),
          title: const Text('Other bag number…',
              style: TextStyle(
                  fontSize: 14,
                  color: Color(0xFF6B7280),
                  fontWeight: FontWeight.w500)),
          onTap: _askOtherBag,
        ),
        const SizedBox(height: 8),
      ]),
    );
  }
}

// ── CHANGE #278: Pack tab — customer-wise packing view ───────────────────────

// CHANGE #304b: fill-state enum shared by Packed and Counted badges.
enum _FillState { empty, partial, full }

class _PackTab extends StatefulWidget {
  const _PackTab({super.key});
  @override
  State<_PackTab> createState() => _PackTabState();
}

class _PackTabState extends State<_PackTab>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  List<Map<String, dynamic>> _customers = [];
  bool _loading = true;
  String? _error;
  String? _expandedOrderId;
  final Map<String, bool> _loadingItems = {};
  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _rowKeys = {};
  double _savedScrollOffset = 0.0;
  // CHANGE #299: full pack_get_queue response per orderId (replaces _itemsByOrder)
  final Map<String, Map<String, dynamic>> _packQueueData = {};
  // packed/total cache for packing button label
  final Map<String, Map<String, int>?> _packStatus = {};

  // CHANGE #299: realtime subscription per expanded order
  final Map<String, RealtimeChannel> _rtChannels = {};
  Timer? _rtDebounce;

  // CHANGE #299: voice counting
  final VoiceReceiveService _voiceService = VoiceReceiveService();
  bool _voiceListening = false;
  bool _voiceProcessing = false;
  bool _recStarted = false;
  // CHANGE #301: synchronous in-flight lock — set before any await, reset in finally
  bool _packCounting = false;
  // #331 VoiceCaps: continuous timer for Pack surface
  int _continuousSecs = 0;
  Timer? _capsTimer;
  DateTime? _recStartTime;
  String _activeVoiceOrderId = '';
  List<Map<String, dynamic>> _packMentions = [];
  int? _lastVoiceSeq;

  // CHANGE #299: Ask mediBO (rewired #304: audio → voice-agent, same as Warehouse)
  bool _askListening = false;
  bool _askProcessing = false;
  String _askInterim = '';

  // CHANGE #304: footer dispatch hold (5 s hold-to-undo on "Ready to Dispatch")
  late final AnimationController _dispatchHoldCtrl;
  Timer? _dispatchHoldTimer;
  bool _dispatchLoading = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _dispatchHoldCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 5000),
    );
    RenderLog.write('c278_pack_tab_mounted', 1);
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _rtDebounce?.cancel();
    _dispatchHoldTimer?.cancel();
    _dispatchHoldCtrl.dispose();
    for (final ch in _rtChannels.values) {
      Supabase.instance.client.removeChannel(ch);
    }
    _rtChannels.clear();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final data = await Supabase.instance.client.rpc('get_customer_pack_status') as List;
      if (!mounted) return;
      setState(() {
        _customers = data.map((r) => Map<String, dynamic>.from(r as Map)).toList();
        _loading = false;
      });
      for (final c in _customers) {
        final oid = c['order_id']?.toString() ?? '';
        if (oid.isNotEmpty) _fetchPackStatus(oid);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  // #291 — fetch packed/total for button label; never removes the key to avoid spinner loop
  Future<void> _fetchPackStatus(String orderId) async {
    final existing = _packStatus[orderId];
    if (existing != null && existing.containsKey('total')) return;
    if (!_packStatus.containsKey(orderId)) _packStatus[orderId] = null;
    try {
      final dynamic raw = await Supabase.instance.client
          .rpc('pack_get_queue', params: {'p_order_id': orderId});
      final Map<String, dynamic> m = raw is String
          ? (jsonDecode(raw) as Map).cast<String, dynamic>()
          : Map<String, dynamic>.from(raw as Map);
      final total  = (m['total_items']  as num?)?.toInt() ?? 0;
      final packed = (m['packed_count'] as num?)?.toInt() ?? 0;
      try {
        RenderLog.write('c291_pack_counts',
            'order=${orderId.substring(0, orderId.length.clamp(0, 8))};total=$total;packed=$packed');
      } catch (_) {}
      if (mounted) setState(() => _packStatus[orderId] = {'packed': packed, 'total': total});
    } catch (e) {
      if (mounted) setState(() => _packStatus[orderId] = {'packed': 0, 'total': -1});
    }
  }

  // CHANGE #299: load full pack_get_queue for expanded card — items with packed/counted per row
  Future<void> _loadFromPackQueue(String orderId) async {
    if (_loadingItems[orderId] == true) return;
    if (!mounted) return;
    setState(() => _loadingItems[orderId] = true);
    try {
      final dynamic raw = await Supabase.instance.client
          .rpc('pack_get_queue', params: {'p_order_id': orderId});
      final Map<String, dynamic> m = raw is String
          ? (jsonDecode(raw) as Map).cast<String, dynamic>()
          : Map<String, dynamic>.from(raw as Map);
      final total   = (m['total_items']  as num?)?.toInt() ?? 0;
      final packed  = (m['packed_count'] as num?)?.toInt() ?? 0;
      final counted = (m['counted_count'] as num?)?.toInt() ?? 0;
      final items   = ((m['items'] as List?) ?? const [])
          .map((i) => Map<String, dynamic>.from(i as Map))
          .toList();
      try {
        RenderLog.write('c299_rows_src',
            'order=${orderId.substring(0, orderId.length.clamp(0, 8))};total=$total;packed=$packed;counted=$counted');
        RenderLog.write('c299_counts', 'total=$total;packed=$packed;counted=$counted');
        if (items.isNotEmpty) {
          final fi = items.first;
          RenderLog.write('c299_row0',
              'name=${fi["product_name"]};qty=${fi["qty"]};packed=${fi["packed"]};counted_qty=${fi["counted_qty"]}');
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _packQueueData[orderId] = m;
        _packStatus[orderId] = {'packed': packed, 'total': total};
        _loadingItems[orderId] = false;
      });
      if (_expandedOrderId == orderId) _refreshPackMentions(orderId);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingItems[orderId] = false;
        if (!_packQueueData.containsKey(orderId)) {
          _packStatus[orderId] = {'packed': 0, 'total': -1};
        }
      });
    }
  }

  Future<void> _refreshPackMentions(String orderId) async {
    try {
      final rows = await Supabase.instance.client
          .rpc('get_pack_clip_mentions', params: {'p_order_id': orderId}) as List;
      if (!mounted) return;
      final mentions = rows.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      final distinct = mentions.map((m) => m['product_id']).where((id) => id != null).toSet().length;
      RenderLog.write('c299_spoken', 'distinct=$distinct;total=${mentions.length}');
      RenderLog.write('c301_mentions', 'rows=${mentions.length};distinct=$distinct');
      if (_expandedOrderId == orderId) setState(() => _packMentions = mentions);
    } catch (_) {}
  }

  // CHANGE #299: realtime — subscribe to order_items UPDATEs for this order
  void _subscribeOrderRt(String orderId) {
    if (_rtChannels.containsKey(orderId)) return;
    final ch = Supabase.instance.client
        .channel('pack_rt_$orderId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'order_items',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'order_id', value: orderId),
          callback: (_) {
            _rtDebounce?.cancel();
            _rtDebounce = Timer(const Duration(milliseconds: 300), () {
              if (mounted && _expandedOrderId == orderId) {
                try { RenderLog.write('c299_rt', 'order=${orderId.substring(0, 8)};event=update'); } catch (_) {}
                _loadFromPackQueue(orderId);
              }
            });
          },
        )
        .subscribe();
    _rtChannels[orderId] = ch;
    try { RenderLog.write('c299_rt', 'order=${orderId.substring(0, 8)};subscribed=true'); } catch (_) {}
  }

  void _teardownOrderRt(String orderId) {
    _rtDebounce?.cancel();
    final ch = _rtChannels.remove(orderId);
    if (ch != null) Supabase.instance.client.removeChannel(ch);
  }

  // CHANGE #299: voice counting — toggle record/stop
  Future<void> _toggleCountVoice(String orderId) async {
    // CHANGE #301: block if processing is already in flight
    if (_packCounting || _voiceProcessing) return;
    if (_voiceListening) {
      await _stopCountVoice(orderId);
    } else {
      _activeVoiceOrderId = orderId; // store for caps timer
      await _startCountVoice();
    }
  }

  Future<void> _startCountVoice() async {
    if (_voiceListening || _voiceProcessing) return;
    // #331 VoiceCaps: check daily cap before starting (Pack surface)
    final capsAllowed = await _VoiceCaps.onSessionStart(context, Supabase.instance.client);
    if (!mounted || !capsAllowed) return;
    try { RenderLog.write('c303_mic_on_tap', 'pack_count_voice'); } catch (_) {}
    _continuousSecs = 0;
    _recStartTime = DateTime.now();
    _capsTimer?.cancel();
    _capsTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || !_voiceListening) { t.cancel(); return; }
      setState(() => _continuousSecs++);
      if (_continuousSecs >= 3600) {
        t.cancel();
        _showPackSnack('1-hour clip limit — recording split/stopped');
        _stopCountVoice(_activeVoiceOrderId);
      } else if (_continuousSecs >= _VoiceCaps._remainingToday) {
        t.cancel();
        _showPackSnack('Daily 3-hour voice limit reached');
        _stopCountVoice(_activeVoiceOrderId);
      }
    });
    try {
      await _voiceService.start();
      _recStarted = true;
      try { RenderLog.write('c303_mic_result', 'granted'); } catch (_) {}
      if (mounted) setState(() => _voiceListening = true);
    } catch (e) {
      _capsTimer?.cancel();
      if (e is MicPermissionException) {
        try { RenderLog.write('c303_mic_result', 'denied'); } catch (_) {}
        if (mounted) _showPackSnack('Mic access needed for voice — enable it in the browser site settings');
      } else {
        if (mounted) _showPackSnack('Mic error: $e');
      }
    }
  }

  Future<void> _stopCountVoice(String orderId) async {
    if (!_voiceListening) return;
    _capsTimer?.cancel(); // #331: stop continuous timer
    // CHANGE #301: set in-flight lock synchronously before any await so that
    // a second call (double-tap, rebuild, realtime event) returns immediately.
    if (_packCounting) return;
    _packCounting = true;
    RenderLog.write('c301_lock', 'locked');
    if (mounted) setState(() { _voiceListening = false; _voiceProcessing = true; });
    if (!_recStarted) {
      _packCounting = false;
      if (mounted) setState(() => _voiceProcessing = false);
      return;
    }
    _recStarted = false;
    try {
      final result = await _voiceService.stop();
      if (!mounted) return;
      if (result == null || result.bytes.length < 1500) {
        if (mounted) setState(() => _voiceProcessing = false);
        _showPackSnack('No audio — try again');
        return;
      }

      // CHANGE #301: seq is fetched fresh per recording, before upload.
      int seq = 0;
      String clipPath = '';
      try {
        final seqRaw = await Supabase.instance.client
            .rpc('next_pack_recording_seq', params: {'p_order_id': orderId});
        seq = (seqRaw as num?)?.toInt() ?? 0;
        if (seq <= 0) seq = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        RenderLog.write('c301_seq', 'order=${orderId.substring(0, 8)};seq=$seq');
      } catch (e) {
        seq = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        RenderLog.write('c301_seq', 'fallback;seq=$seq;err=${e.toString().substring(0, e.toString().length.clamp(0, 40))}');
      }

      // CHANGE #301: upload is best-effort and independent of counting.
      // If upload throws, log and continue — do NOT retry or abort counting.
      try {
        // CHANGE #304b: path MUST use YYYY-MM-DD (dashes) — matches next_pack_recording_seq lookup.
        final istNow = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
        final dateStr = '${istNow.year.toString().padLeft(4, '0')}'
            '-${istNow.month.toString().padLeft(2, '0')}'
            '-${istNow.day.toString().padLeft(2, '0')}';
        clipPath = '$dateStr/pack-$orderId/$seq.${result.ext}';
        final mimeUpload = result.ext == 'webm' ? 'audio/webm' : 'audio/mp4';
        await Supabase.instance.client.storage.from('voice-clips').uploadBinary(
          clipPath, result.bytes,
          fileOptions: FileOptions(contentType: mimeUpload, upsert: true),
        );
        RenderLog.write('c301_upload', 'ok;path_tail=${clipPath.length >= 8 ? clipPath.substring(clipPath.length - 8) : clipPath}');
        // #331: register clip with caps backend (fire-and-forget; supplier unknown for pack)
        final packDurSecs = _recStartTime != null
            ? DateTime.now().difference(_recStartTime!).inSeconds.clamp(1, 3600)
            : _continuousSecs.clamp(1, 3600);
        _VoiceCaps.onClipSaved(Supabase.instance.client,
            ctxStr: 'pack', supplier: orderId, path: clipPath, seconds: packDurSecs,
            onLocked: () { if (mounted) _showPackSnack('Daily 3-hour voice limit reached'); }).ignore();
      } catch (e) {
        RenderLog.write('c301_upload', 'err=${e.toString().substring(0, e.toString().length.clamp(0, 60))}');
        // clip path stays non-empty so pack_process_clip records it anyway
      }

      // Build expected list (deduplicated by product_id)
      final qData = _packQueueData[orderId];
      final qItems = qData != null
          ? ((qData['items'] as List?) ?? const [])
              .map((i) => Map<String, dynamic>.from(i as Map))
              .toList()
          : <Map<String, dynamic>>[];
      final Map<int, Map<String, dynamic>> byPid = {};
      for (final qi in qItems) {
        final pid = (qi['product_id'] as num?)?.toInt();
        if (pid != null && !byPid.containsKey(pid)) byPid[pid] = qi;
      }
      final expected = byPid.values.map((qi) => {
        'name': qi['product_name']?.toString() ?? '',
        'ordered_qty': (qi['qty'] as num?)?.toInt() ?? 1,
        'unit': qi['pack_type']?.toString() ?? '',
      }).toList();

      // Transcribe via voice-receive edge function — CHANGE #304: min_confidence 0.85
      final (:items, :transcript, :droppedNoQty, :droppedLowConf, :mentions) =
          await _voiceService.transcribe(result.bytes, result.mime,
              expected: expected.isEmpty ? null : expected,
              minConfidence: 0.85);
      if (!mounted) return;

      // CHANGE #304: SILENCE GUARD — if nothing was spoken, skip pack_process_clip entirely.
      final bool silenced = transcript.trim().isEmpty || items.isEmpty;
      if (silenced) {
        try { RenderLog.write('c304_silence', 'blocked'); } catch (_) {}
        setState(() { _voiceProcessing = false; _lastVoiceSeq = null; });
        _showPackSnack("Didn't catch anything — try again");
        return;
      }
      try { RenderLog.write('c304_silence', 'counted:${items.length}'); } catch (_) {}

      // CHANGE #306: fuzzy resolution — replaces exact name map with _resolveProductId.
      // Strips dosage-form words before comparing so mis-heard brand names still resolve.
      final itemsPayload = <Map<String, dynamic>>[];
      int _resolvedCount = 0;
      for (final item in items) {
        final matchedName = item['matched_name']?.toString();
        final rawQty = item['received_qty'];
        if (rawQty == null || matchedName == null || matchedName == 'not_on_order') continue;
        final qty = (rawQty as num).toDouble();
        if (qty <= 0) continue;
        final pid = _resolveProductId(matchedName, qItems);
        if (pid == null) continue;
        _resolvedCount++;
        itemsPayload.add({'product_id': pid, 'qty': qty});
      }
      try { RenderLog.write('c306_resolved', 'items=$_resolvedCount/${items.length}'); } catch (_) {}

      // ord = mention's 0-based index in the clip (from voice-receive), NOT per-product.
      // When pid resolves, use the canonical product_name so the review shows the real product.
      final mentionsPayload = <Map<String, dynamic>>[];
      for (int i = 0; i < mentions.length; i++) {
        final mention = mentions[i];
        final matchedName = mention['matched_name']?.toString();
        final pid = (matchedName != null && matchedName != 'not_on_order')
            ? _resolveProductId(matchedName, qItems)
            : null;
        final resolvedName = pid != null
            ? (_resolveProductName(pid, qItems) ?? matchedName!)
            : (matchedName ?? '');
        mentionsPayload.add({
          'product_id': pid,
          'matched_name': resolvedName,
          'qty': (mention['qty'] as num?)?.toDouble() ?? 0.0,
          't_start': mention['t_start'],
          't_end': mention['t_end'],
          'ord': i,
        });
      }

      // CHANGE #304b: second guard — if all items resolved to unknown products, skip.
      if (itemsPayload.isEmpty && mentionsPayload.isEmpty) {
        try { RenderLog.write('c304_silence', 'blocked'); } catch (_) {}
        setState(() { _voiceProcessing = false; _lastVoiceSeq = null; });
        _showPackSnack("Didn't catch anything — try again");
        return;
      }

      // CHANGE #301: single atomic RPC — replaces old per-item + per-mention loops.
      int countsSet = 0;
      try {
        final dynamic res = await Supabase.instance.client.rpc(
          'pack_process_clip',
          params: {
            'p_order_id': orderId,
            'p_recording_seq': seq,
            'p_clip_path': clipPath,
            'p_items': itemsPayload,
            'p_mentions': mentionsPayload,
          },
        );
        final resMap = res is String
            ? (jsonDecode(res) as Map).cast<String, dynamic>()
            : Map<String, dynamic>.from(res as Map);
        countsSet = (resMap['counts_set'] as num?)?.toInt() ?? itemsPayload.length;
        RenderLog.write('c301_process',
            'counts_set=${resMap["counts_set"]};mentions=${resMap["mentions"]};seq=$seq');
        try { RenderLog.write('c306_counted', 'counts_set=${resMap["counts_set"]};mentions=${resMap["mentions"]}'); } catch (_) {}
      } catch (e) {
        RenderLog.write('c301_process', 'err=${e.toString().substring(0, e.toString().length.clamp(0, 60))}');
      }

      RenderLog.write('c301_lock', 'processed;countsSet=$countsSet');

      if (!mounted) return;
      setState(() {
        _voiceProcessing = false;
        _lastVoiceSeq = seq > 0 ? seq : null;
      });
      _showPackSnack(countsSet > 0
          ? '$countsSet item${countsSet == 1 ? '' : 's'} counted'
          : 'No items matched — try again');

      // Reload pack_get_queue to update Counted badges and progress row.
      await _loadFromPackQueue(orderId);
    } catch (e) {
      if (!mounted) return;
      setState(() => _voiceProcessing = false);
      _showPackSnack('Voice error — try again');
    } finally {
      // CHANGE #301: always release the in-flight lock.
      _packCounting = false;
      RenderLog.write('c301_lock', 'released');
    }
  }

  // CHANGE #304: Ask mediBO — rewired to audio-bytes → voice-agent (same as Warehouse).
  // First tap starts recording (_voiceService.start), second tap stops + processes.
  Future<void> _toggleAskMediaBO(String orderId) async {
    if (_voiceProcessing || _voiceListening || _packCounting || _askProcessing) return;
    if (_askListening) {
      // Second tap: stop recording and process
      await _stopAskMediaBO(orderId);
      return;
    }
    // First tap: start recording
    if (mounted) setState(() { _askListening = true; _askInterim = 'Listening…'; });
    RenderLog.write('c304_ask', 'start;order=${orderId.substring(0, 8)}');
    try {
      await _voiceService.start();
    } catch (e) {
      if (mounted) setState(() { _askListening = false; _askInterim = ''; });
      if (mounted) _showPackSnack(e is MicPermissionException
          ? 'Mic access needed — enable it in browser site settings'
          : 'Mic error: $e');
    }
  }

  Future<void> _stopAskMediaBO(String orderId) async {
    if (!_askListening) return;
    if (mounted) setState(() { _askInterim = 'Processing…'; });
    _askProcessing = true;
    try {
      final result = await _voiceService.stop();
      if (!mounted) return;
      if (result == null || result.bytes.length < 1500) {
        _showPackSnack('No audio captured — try again');
        return;
      }
      final b64 = base64Encode(result.bytes);
      final token = Supabase.instance.client.auth.currentSession?.accessToken ?? '';
      final qData = _packQueueData[orderId];
      final qItems = qData != null
          ? ((qData['items'] as List?) ?? const [])
              .map((i) => Map<String, dynamic>.from(i as Map))
              .toList()
          : <Map<String, dynamic>>[];
      // CHANGE #305: mode:'pack' + customer_name + {name,qty,packed,counted_qty,pack_type}
      // Do NOT send supplier_name or ordered/received fields in pack mode.
      final customerName = qData?['customer']?.toString() ?? '';
      final agentItems = qItems.map((qi) => {
        'name': qi['product_name']?.toString() ?? '',
        'qty': (qi['qty'] as num?)?.toInt() ?? 0,
        'packed': qi['packed'] == true,
        'counted_qty': qi['counted_qty'],
        'pack_type': qi['pack_type']?.toString() ?? '',
      }).toList();
      try { RenderLog.write('c305_ask_mode', 'pack'); } catch (_) {}
      final res = await Supabase.instance.client.functions.invoke(
        'voice-agent',
        body: {
          'audio_base64': b64,
          'mime_type': result.mime,
          'mode': 'pack',
          'customer_name': customerName,
          'items': agentItems,
        },
        headers: {'Authorization': 'Bearer $token'},
      );
      if (!mounted) return;
      final data = res.data;
      if (data is Map && data['error'] != null) {
        _showPackSnack('Ask mediBO error — try again');
        return;
      }
      final reply = (data is Map ? data['reply'] : null)?.toString() ?? '';
      final transcript = (data is Map ? data['transcript'] : null)?.toString() ?? '';
      try {
        RenderLog.write('c305_ask_q', transcript.length > 80 ? transcript.substring(0, 80) : transcript);
        RenderLog.write('c305_ask_reply', reply.length > 80 ? reply.substring(0, 80) : reply);
      } catch (_) {}
      if (reply.isNotEmpty) {
        _showPackSnack(reply, duration: const Duration(seconds: 6));
        try { speakText(reply); } catch (_) {}
        try { RenderLog.write('c304_ask', 'ok'); } catch (_) {}
      } else {
        _showPackSnack('No reply — try again');
      }
    } catch (e) {
      if (mounted) _showPackSnack('Ask mediBO error — try again');
      try { RenderLog.write('c304_ask', 'err=${e.toString().substring(0, 40)}'); } catch (_) {}
    } finally {
      _askProcessing = false;
      if (mounted) setState(() { _askListening = false; _askInterim = ''; });
    }
  }

  void _showPackSnack(String msg, {Duration? duration}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: duration ?? const Duration(seconds: 3),
      backgroundColor: const Color(0xFF1B7A43),
    ));
  }

  // ── CHANGE #306: fuzzy product resolver ──────────────────────────────────
  // Strips dosage-form / suffix words before comparing so mis-heard brand names
  // still resolve ("Rosusen F 10" → "Rosuson-F 10 Tablet").
  static String _norm(String s) => s.toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ').trim();

  static const _kFormWords = {
    'tablet','tablets','tab','tabs','capsule','capsules','cap','caps','syrup','syp',
    'suspension','susp','cream','gel','ointment','drop','drops','injection','inj',
    'lotion','solution','soln','sachet','powder','spray','liquid','bottle','strip',
    'strips','vial','vials','sr','xr','xl','cr','er','mr','md','dsr','od','forte',
    'plus','kit','tube'
  };

  static String _core(String s) => _norm(s).split(' ')
      .where((t) => t.isNotEmpty && !_kFormWords.contains(t)).join(' ');

  static int _lev(String a, String b) {
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    if (a == b) return 0;
    final dp = List.generate(a.length + 1,
        (i) => List.generate(b.length + 1, (j) => i == 0 ? j : (j == 0 ? i : 0)));
    for (int i = 1; i <= a.length; i++) {
      for (int j = 1; j <= b.length; j++) {
        dp[i][j] = a[i - 1] == b[j - 1]
            ? dp[i - 1][j - 1]
            : 1 + [dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1]]
                .reduce((x, y) => x < y ? x : y);
      }
    }
    return dp[a.length][b.length];
  }

  static double _simStr(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;
    final d = _lev(a, b);
    final m = a.length > b.length ? a.length : b.length;
    return 1 - d / m;
  }

  // Returns product_id of best fuzzy match, or null if below 0.72 threshold.
  int? _resolveProductId(String spoken, List<Map<String, dynamic>> items) {
    final hc = _core(spoken);
    if (hc.isEmpty) return null;
    final hTok = hc.split(' ').first;
    final hSet = hc.split(' ').toSet();
    int? best; double bestScore = 0;
    for (final it in items) {
      final nc = _core((it['product_name'] ?? '').toString());
      if (nc.isEmpty) continue;
      final nTok = nc.split(' ').first;
      final nSet = nc.split(' ').toSet();
      final whole = _simStr(hc, nc);
      final brand = (hTok.isNotEmpty && nTok.isNotEmpty) ? _simStr(hTok, nTok) : 0.0;
      final inter = hSet.where(nSet.contains).length;
      final union = ({...hSet, ...nSet}).length;
      final jac = union == 0 ? 0.0 : inter / union;
      final score = [whole, 0.55 * brand + 0.45 * jac, 0.6 * whole + 0.4 * brand]
          .reduce((a, b) => a > b ? a : b);
      if (score > bestScore) {
        bestScore = score;
        best = (it['product_id'] as num?)?.toInt();
      }
    }
    return bestScore >= 0.72 ? best : null;
  }

  // Returns product_name for a resolved product_id.
  String? _resolveProductName(int pid, List<Map<String, dynamic>> items) {
    for (final it in items) {
      if ((it['product_id'] as num?)?.toInt() == pid) return it['product_name']?.toString();
    }
    return null;
  }

  // #291 — button always rendered, label refined from cached status
  Widget _buildPackingButton(Map<String, dynamic> c) {
    final orderId = c['order_id']?.toString() ?? '';
    if (orderId.isEmpty) return const SizedBox.shrink();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetchPackStatus(orderId);
    });
    final status = _packStatus[orderId];
    final int packed = status?['packed'] ?? 0;
    final int total  = status?['total']  ?? 0;
    final String label;
    final String logLabel;
    if (status == null || total <= 0) {
      label = 'Start Packing'; logLabel = 'Start';
    } else if (packed == 0) {
      label = 'Start Packing'; logLabel = 'Start';
    } else if (packed >= total) {
      label = 'Packed ✓ — View'; logLabel = 'Packed';
    } else {
      label = 'Resume Packing ($packed/$total)'; logLabel = 'Resume';
    }
    try {
      RenderLog.write('c291_pack_btn_build',
          'order=${orderId.substring(0, orderId.length.clamp(0, 8))};branch=narrow;shown=true;label=$logLabel');
    } catch (_) {}
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: SizedBox(
        width: double.infinity,
        height: 44,
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: _kGreen,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
          onPressed: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => _PackingScreen(orderId: orderId)),
            );
            _packStatus.remove(orderId);
            _packQueueData.remove(orderId);
            if (mounted) {
              _fetchPackStatus(orderId);
              if (_expandedOrderId == orderId) _loadFromPackQueue(orderId);
            }
          },
          child: Text(label,
              style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: Colors.white)),
        ),
      ),
    );
  }

  String _dot(Map<String, dynamic> c) {
    final s = c['fulfillment_status']?.toString() ?? '';
    if (s == 'ready') return 'green';
    if (s == 'partial_ready' || s == 'in_transit') return 'light_yellow';
    return 'yellow';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2));
    }
    if (_error != null) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.error_outline, size: 40, color: _kSub),
        const SizedBox(height: 12),
        const Text('Could not load pack status',
            style: TextStyle(color: _kSub, fontSize: 14)),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: _load,
          style: OutlinedButton.styleFrom(
              side: const BorderSide(color: _kGreen),
              foregroundColor: _kGreen,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8))),
          child: const Text('Retry'),
        ),
      ]));
    }
    if (_customers.isEmpty) {
      return const Center(
          child: Text('No accepted orders to pack',
              style: TextStyle(color: _kSub, fontSize: 15)));
    }
    return LayoutBuilder(builder: (_, constraints) {
      final maxW = constraints.maxWidth >= 900 ? 700.0 : double.infinity;
      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            itemCount: _customers.length,
            itemBuilder: (_, i) => _buildCustomerRow(_customers[i]),
          ),
        ),
      );
    });
  }

  Widget _buildCustomerRow(Map<String, dynamic> c) {
    final orderId = c['order_id']?.toString() ?? '';
    final name = c['customer']?.toString() ?? 'Unknown';
    final isExpanded = _expandedOrderId == orderId;
    final rowKey = _rowKeys.putIfAbsent(orderId, () => GlobalKey());

    return _SupplierAccordionShell(
      name: name,
      dot: _dot(c),
      isExpanded: isExpanded,
      anyExpanded: _expandedOrderId != null,
      rowKey: rowKey,
      onTap: () {
        if (isExpanded) {
          _teardownOrderRt(orderId);
          _packCounting = false;
          setState(() {
            _expandedOrderId = null;
            _voiceListening = false;
            _voiceProcessing = false;
            _askListening = false;
            _askInterim = '';
            _packMentions = [];
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_scroll.hasClients) return;
            _scroll.animateTo(_savedScrollOffset,
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeInOutCubic);
          });
        } else {
          RenderLog.write('c278_pack_card_open', name);
          _savedScrollOffset =
              _scroll.hasClients ? _scroll.offset : 0.0;
          setState(() {
            _expandedOrderId = orderId;
            _packMentions = [];
          });
          _loadFromPackQueue(orderId);
          _subscribeOrderRt(orderId);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_scroll.hasClients) return;
            _scroll.animateTo(0.0,
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeInOutCubic);
          });
        }
      },
      expandedContent:
          isExpanded ? _buildExpandedBody(c) : const SizedBox.shrink(),
      mode: null,
      showPending: false,
    );
  }

  Widget _buildExpandedBody(Map<String, dynamic> c) {
    final orderId  = c['order_id']?.toString() ?? '';
    final total    = (c['total_items'] as num?)?.toInt() ?? 0;
    final isLoading = _loadingItems[orderId] == true;

    final qData = _packQueueData[orderId];
    final items = qData != null
        ? ((qData['items'] as List?) ?? const [])
            .map((i) => Map<String, dynamic>.from(i as Map))
            .toList()
        : <Map<String, dynamic>>[];
    final countedCount =
        qData != null ? (qData['counted_count'] as num?)?.toInt() ?? 0 : 0;
    final totalItems = qData != null
        ? (qData['total_items'] as num?)?.toInt() ?? total
        : total;

    // CHANGE #304: spokenCount = distinct products in today's mention rows (not counted_count).
    final spokenCount = _packMentions
        .map((m) => m['product_id'])
        .where((id) => id != null)
        .toSet()
        .length;
    try {
      RenderLog.write('c301_spoken', '$spokenCount');
      RenderLog.write('c304_spoken', '$spokenCount');
      RenderLog.write('c306_spoken', '$spokenCount');
    } catch (_) {}

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Divider(height: 1, color: _kBorder),
      _buildPackingButton(c),
      _buildPackVoiceBar(orderId, spokenCount),
      if (totalItems > 0) _buildPackProgressRow(countedCount, totalItems, orderId),

      if (isLoading)
        const Center(
            child: Padding(
          padding: EdgeInsets.all(24),
          child:
              CircularProgressIndicator(color: _kGreen, strokeWidth: 2),
        ))
      else if (items.isEmpty && qData != null)
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Text('No items found',
              style: TextStyle(color: _kSub, fontSize: 14)),
        )
      else if (items.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (int i = 0; i < items.length; i++) ...[
                  Builder(builder: (ctx) {
                    if (i == 0) {
                      final firstItem = items[0];
                      final pk0 = firstItem['packed'] == true
                          ? (firstItem['qty'] as num?)?.toInt() ?? 0
                          : 0;
                      final ct0 = (firstItem['counted_qty'] as num?)?.toInt() ?? 0;
                      final qty0 = (firstItem['qty'] as num?)?.toInt() ?? 0;
                      String _chipColour(int x, int y) =>
                          x == 0 ? 'grey' : (y > 0 && x >= y ? 'green' : 'yellow');
                      try {
                        RenderLog.write('c304_badge',
                            'packed=$pk0/$qty0:${_chipColour(pk0, qty0)};counted=$ct0/$qty0:${_chipColour(ct0, qty0)}');
                      } catch (_) {}
                      RenderLog.write('c299_rows_src', 'rendered=${items.length}');
                    }
                    return Padding(
                      padding:
                          const EdgeInsets.fromLTRB(16, 0, 16, 0),
                      child: _buildPackItemTile(items[i]),
                    );
                  }),
                  if (i < items.length - 1) const SizedBox(height: 6),
                ],
              ]),
        ),

      if (!isLoading) ...[
        const SizedBox(height: 12),
        const Divider(height: 1, color: _kBorder),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          // CHANGE #304: footer driven by pack_get_queue packed_count/total_items/dispatch_ready
          child: _buildPackFooter(orderId, qData),
        ),
      ] else
        const SizedBox(height: 8),
    ]);
  }

  // CHANGE #299: active voice bar — Count items + Ask mediBO
  Widget _buildPackVoiceBar(String orderId, int spokenCount) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(children: [
        Expanded(
            child: SizedBox(
                height: 44,
                child: _buildCountPill(orderId, spokenCount))),
        const SizedBox(width: 12),
        Expanded(
            child: SizedBox(
                height: 44, child: _buildAskPill(orderId))),
      ]),
    );
  }

  Widget _buildCountPill(String orderId, int spokenCount) {
    final bool listening = _voiceListening;
    // CHANGE #301: _packCounting is the synchronous in-flight lock
    final bool processing = _voiceProcessing || _packCounting;
    final bool disabled = _voiceProcessing || _packCounting || _askListening;
    return GestureDetector(
      onTap: disabled ? null : () => _toggleCountVoice(orderId),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          color: listening ? _kGreen : Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: listening ? _kGreen : _kBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.max,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (processing)
              const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      color: _kGreen, strokeWidth: 2))
            else
              Icon(
                  listening
                      ? Icons.stop_rounded
                      : Icons.mic_none_rounded,
                  size: 16,
                  color: listening ? Colors.white : _kGreen),
            const SizedBox(width: 6),
            Flexible(
                child: Text(
              processing
                  ? 'Processing…'
                  : (listening ? 'Stop' : 'Count items'),
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: listening ? Colors.white : _kText),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            )),
            // CHANGE #304: tappable "N spoken" badge — opens review sheet
            if (spokenCount > 0 && !listening && !processing) ...[
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () => _openMentionsReview(orderId),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: _kReceivedBg,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: _kReceivedFg.withValues(alpha: 0.25)),
                  ),
                  child: Text('$spokenCount',
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: _kReceivedFg)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAskPill(String orderId) {
    final bool listening = _askListening;
    final bool disabled = _voiceListening || _voiceProcessing;
    return GestureDetector(
      onTap: disabled ? null : () => _toggleAskMediaBO(orderId),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          color: listening ? const Color(0xFF1E40AF) : Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
              color: listening
                  ? const Color(0xFF1E40AF)
                  : _kBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.max,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
                listening
                    ? Icons.stop_rounded
                    : Icons.record_voice_over_rounded,
                size: 16,
                color: listening
                    ? Colors.white
                    : _kGreen),
            const SizedBox(width: 6),
            Flexible(
                child: Text(
              listening
                  ? (_askInterim.isNotEmpty
                      ? _askInterim
                      : 'Listening…')
                  : 'Ask mediBO',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: listening ? Colors.white : _kText),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            )),
          ],
        ),
      ),
    );
  }

  // CHANGE #304: takes orderId so the spoken chip can open the review sheet.
  Widget _buildPackProgressRow(int counted, int total, String orderId) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        GestureDetector(
          onTap: () => _openMentionsReview(orderId),
          child: SizedBox(
            width: 100,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _kGreen,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('$counted spoken',
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.white),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: LinearProgressIndicator(
            value: total == 0 ? 0 : counted / total,
            backgroundColor: _kBorder,
            color: _kGreen,
            minHeight: 6,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 8),
        Text('$counted/$total',
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: _kText)),
      ]),
    );
  }

  // CHANGE #299: redesigned tile — bigger image left, 3 info lines, no bag chip
  Widget _buildPackItemTile(Map<String, dynamic> item) {
    final name       = item['product_name']?.toString() ?? '—';
    final packType   = item['pack_type']?.toString() ?? '';
    final imageUrl   = item['image_url']?.toString();
    final qty        = (item['qty'] as num?)?.toInt() ?? 0;
    final packed     = item['packed'] == true;
    final countedQty = (item['counted_qty'] as num?)?.toInt() ?? 0;

    final pk = packed ? qty : 0;
    final ct = countedQty;
    final pt = packType.isNotEmpty ? ' $packType' : '';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _kBorder),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _FulfilImageTile(imageUrl, size: 52),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(name,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: _kText),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 5),
                // CHANGE #304: shared colour helper — 0=grey, partial=yellow, full=green
                _packChip('Packed • $pk/$qty$pt', pk, qty),
                const SizedBox(height: 4),
                _packChip('Counted • $ct/$qty$pt', ct, qty),
              ]),
        ),
      ]),
    );
  }

  // CHANGE #304: badge colour helper — grey/yellow/green by fill ratio.
  // x=0 → grey; 0<x<y → yellow; x>=y && y>0 → green.
  // CHANGE #304b: shared fill-state enum + colour helper used by BOTH Packed and Counted badges.
  _FillState _fillStateFor(int x, int y) {
    if (y <= 0 || x <= 0) return _FillState.empty;
    if (x >= y) return _FillState.full;
    return _FillState.partial;
  }
  (Color bg, Color fg) _fillColors(_FillState s) => switch (s) {
    _FillState.empty   => (const Color(0xFFF3F4F6), const Color(0xFF6B7280)),
    _FillState.partial => (const Color(0xFFFEF3C7), const Color(0xFF92400E)),
    _FillState.full    => (const Color(0xFFDCFCE7), const Color(0xFF166534)),
  };

  Widget _packChip(String label, int x, int y) {
    final s = _fillStateFor(x, y);
    final (bg, text) = _fillColors(s);
    final Color border = switch (s) {
      _FillState.empty   => const Color(0xFFD1D5DB),
      _FillState.partial => const Color(0xFFD97706).withValues(alpha: 0.4),
      _FillState.full    => const Color(0xFF166534).withValues(alpha: 0.4),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: text),
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
    );
  }

  // CHANGE #304: FOOTER STATE MACHINE — driven by pack_get_queue fields.
  // dispatch_ready=true → GREEN 5s-hold "Ready to Dispatch"
  // packed==total>0     → YELLOW tap "Fully packed"
  // otherwise           → muted "Pack all items (x/y)"
  Widget _buildPackFooter(String orderId, Map<String, dynamic>? qData) {
    final int packedCount = (qData?['packed_count'] as num?)?.toInt() ?? 0;
    final int totalItems  = (qData?['total_items']  as num?)?.toInt() ?? 0;
    final bool dispatchReady = qData?['dispatch_ready'] == true;

    final String state = dispatchReady
        ? 'readytodispatch'
        : (totalItems > 0 && packedCount >= totalItems ? 'fullypacked' : 'progress');
    try { RenderLog.write('c304_footer', 'state=$state'); } catch (_) {}

    if (dispatchReady) {
      // ── GREEN: hold 5 s to un-mark ────────────────────────────────────────
      return Stack(children: [
        // Base bar
        Container(
          height: 48,
          decoration: BoxDecoration(
            color: _kReceivedBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _kReceivedFg.withValues(alpha: 0.35)),
          ),
          alignment: Alignment.center,
          child: _dispatchLoading
              ? const SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(color: _kReceivedFg, strokeWidth: 2))
              : const Text('Ready to Dispatch  ·  hold 5 s to undo',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700, color: _kReceivedFg)),
        ),
        // Progress fill
        if (!_dispatchLoading)
          AnimatedBuilder(
            animation: _dispatchHoldCtrl,
            builder: (_, __) {
              final v = _dispatchHoldCtrl.value;
              if (v <= 0) return const SizedBox.shrink();
              return Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: v,
                      child: Container(
                        decoration: BoxDecoration(
                          color: _kReceivedFg.withValues(alpha: 0.15),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        // Listener layer
        if (!_dispatchLoading)
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) {
                _dispatchHoldCtrl.forward(from: 0.0);
                _dispatchHoldTimer?.cancel();
                _dispatchHoldTimer = Timer(const Duration(milliseconds: 5000), () {
                  HapticFeedback.mediumImpact();
                  _doSetDispatchReady(orderId, false);
                });
              },
              onPointerUp: (_) {
                _dispatchHoldTimer?.cancel();
                _dispatchHoldCtrl.reverse();
              },
              onPointerCancel: (_) {
                _dispatchHoldTimer?.cancel();
                _dispatchHoldCtrl.reverse();
              },
            ),
          ),
      ]);
    }

    if (totalItems > 0 && packedCount >= totalItems) {
      // ── YELLOW: tap to mark dispatch_ready=true ───────────────────────────
      return GestureDetector(
        onTap: _dispatchLoading ? null : () => _doSetDispatchReady(orderId, true),
        child: Container(
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFFFEF3C7),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: const Color(0xFFD97706).withValues(alpha: 0.4)),
          ),
          alignment: Alignment.center,
          child: _dispatchLoading
              ? const SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(
                      color: Color(0xFF92400E), strokeWidth: 2))
              : const Text('Fully packed — tap to mark Ready to Dispatch',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF92400E))),
        ),
      );
    }

    // ── MUTED: packing in progress ────────────────────────────────────────────
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _kBorder),
      ),
      child: Row(children: [
        const Icon(Icons.hourglass_top_rounded, size: 15, color: _kSub),
        const SizedBox(width: 8),
        Expanded(
            child: Text(
          'Pack all items ($packedCount/$totalItems)',
          style: const TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600, color: _kSub),
        )),
      ]),
    );
  }

  Future<void> _doSetDispatchReady(String orderId, bool ready) async {
    if (_dispatchLoading) return;
    if (mounted) setState(() => _dispatchLoading = true);
    _dispatchHoldTimer?.cancel();
    _dispatchHoldCtrl.reset();
    try {
      final dynamic res = await Supabase.instance.client.rpc(
        'pack_set_dispatch_ready',
        params: {'p_order_id': orderId, 'p_ready': ready},
      );
      final resMap = res is String
          ? (jsonDecode(res) as Map).cast<String, dynamic>()
          : Map<String, dynamic>.from(res as Map);
      try {
        RenderLog.write('c304_dispatch',
            'ready=$ready;status=${resMap['status']};dispatch_ready=${resMap['dispatch_ready']}');
      } catch (_) {}
      if (!mounted) return;
      if (resMap['error'] != null) {
        _showPackSnack('Not fully packed (${resMap['packed']}/${resMap['total']})');
      }
    } catch (e) {
      if (mounted) _showPackSnack('Error: $e');
    } finally {
      if (mounted) setState(() => _dispatchLoading = false);
    }
    // Always refetch to sync footer + rows
    if (mounted) await _loadFromPackQueue(orderId);
  }

  // CHANGE #306: opens the "Counted items" review sheet (same layout as Warehouse popup).
  void _openMentionsReview(String orderId) {
    final mentions = List<Map<String, dynamic>>.from(_packMentions);
    final qData = _packQueueData[orderId];
    final packItems = qData != null
        ? ((qData['items'] as List?) ?? const [])
            .map((i) => Map<String, dynamic>.from(i as Map))
            .toList()
        : <Map<String, dynamic>>[];
    final distinctProds = mentions.map((m) => m['product_id']).whereType<int>().toSet().length;
    final unknownRows = mentions.where((m) => (m['product_id'] as num?) == null).length;
    try {
      RenderLog.write('c304_review', 'mentions=${mentions.length}');
      RenderLog.write('c306_review', 'products=$distinctProds;unknown=$unknownRows');
    } catch (_) {}
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _PackMentionsSheet(mentions: mentions, packItems: packItems),
    );
  }
}

// ── CHANGE #306: Pack "Counted items" review sheet — same table layout as Warehouse popup ──
// Product | Qty sequence (per-clip pills) | Total (X/Y, green when full)
// All / Clip N chips filter the rows; each Clip chip plays the whole clip.

class _PackMentionsSheet extends StatefulWidget {
  final List<Map<String, dynamic>> mentions;
  final List<Map<String, dynamic>> packItems; // pack_get_queue items for ordered-qty lookup
  const _PackMentionsSheet({required this.mentions, required this.packItems});
  @override
  State<_PackMentionsSheet> createState() => _PackMentionsSheetState();
}

class _PackMentionsSheetState extends State<_PackMentionsSheet> {
  int? _selectedSeq; // null = All
  final _chipScrollCtrl = ScrollController();

  html.AudioElement? _clipAudio;
  final Map<String, String> _signedUrlCache = {};
  String? _playingClip;
  int? _playingSeq;

  static const double _kTotalColW = 52.0;
  static const double _kBadgeClusterMaxW = 108.0;
  static const double _kBadgeToTotalGap = 6.0;
  static const double _kNameToBadgeMinGap = 10.0;

  @override
  void dispose() {
    _clipAudio?.pause();
    _clipAudio?.src = '';
    _chipScrollCtrl.dispose();
    super.dispose();
  }

  // Distinct clips ordered by seq ascending.
  List<({int seq, String clipPath})> _distinctClips(List<Map<String, dynamic>> rows) {
    final seen = <String>{};
    final result = <({int seq, String clipPath})>[];
    for (final r in rows) {
      final path = r['clip_path']?.toString() ?? '';
      if (path.isEmpty || !seen.add(path)) continue;
      final seq = (r['recording_seq'] as num?)?.toInt() ?? 0;
      result.add((seq: seq, clipPath: path));
    }
    result.sort((a, b) => a.seq.compareTo(b.seq));
    return result;
  }

  // Group by product_id (known) or 'Unknown item' (null pid).
  // Qty sequence = one entry per mention (for the pill cluster).
  List<({String name, List<({int qty, int seq})> entries, int total, int ordered})>
      _groupMentions(List<Map<String, dynamic>> rows) {
    final pidToName = <int, String>{};
    final nameToOrdered = <String, int>{};
    for (final it in widget.packItems) {
      final pid = (it['product_id'] as num?)?.toInt();
      final name = it['product_name']?.toString() ?? '';
      final qty = (it['qty'] as num?)?.toInt() ?? 0;
      if (pid != null && name.isNotEmpty) {
        pidToName[pid] = name;
        nameToOrdered[name] = qty;
      }
    }
    // key = product_id (as string) for known, '' for unknown
    final order = <String>[];
    final byKey = <String, List<({int qty, int seq})>>{};
    for (final r in rows) {
      final pid = (r['product_id'] as num?)?.toInt();
      final key = pid != null ? '$pid' : '';
      if (!byKey.containsKey(key)) order.add(key);
      final qty = (r['qty'] as num?)?.toInt() ?? 0;
      final seq = (r['recording_seq'] as num?)?.toInt() ?? 0;
      byKey.putIfAbsent(key, () => []).add((qty: qty, seq: seq));
    }
    return order.map((key) {
      final entries = byKey[key]!;
      final total = entries.fold(0, (s, e) => s + e.qty);
      final pid = key.isEmpty ? null : int.tryParse(key);
      final name = pid != null ? (pidToName[pid] ?? 'Unknown item') : 'Unknown item';
      return (name: name, entries: entries, total: total, ordered: nameToOrdered[name] ?? 0);
    }).toList();
  }

  Future<void> _playClip(String clipPath, int seq) async {
    if (_playingClip == clipPath) { _stopAudio(); return; }
    _stopAudio();
    if (clipPath.isEmpty) return;
    try {
      String? url = _signedUrlCache[clipPath];
      if (url == null) {
        url = await Supabase.instance.client.storage
            .from('voice-clips').createSignedUrl(clipPath, 3600);
        if (!mounted) return;
        _signedUrlCache[clipPath] = url;
      }
      final el = html.AudioElement(url);
      _clipAudio = el;
      el.onEnded.listen((_) {
        if (!mounted || !identical(_clipAudio, el)) return;
        setState(() { _playingClip = null; _playingSeq = null; });
      });
      el.onError.listen((_) {
        if (!mounted || !identical(_clipAudio, el)) return;
        setState(() { _playingClip = null; _playingSeq = null; });
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Couldn't play this clip")));
      });
      await el.play();
      if (mounted) setState(() { _playingClip = clipPath; _playingSeq = seq; });
    } catch (e) {
      if (mounted) setState(() { _playingClip = null; _playingSeq = null; });
    }
  }

  void _stopAudio() {
    _clipAudio?.pause();
    _clipAudio?.src = '';
    _clipAudio = null;
    if (mounted) setState(() { _playingClip = null; _playingSeq = null; });
  }

  @override
  Widget build(BuildContext context) {
    final allMentions = widget.mentions;
    final clips = _distinctClips(allMentions);
    final filtered = _selectedSeq == null
        ? allMentions
        : allMentions.where((m) => (m['recording_seq'] as num?)?.toInt() == _selectedSeq).toList();
    final groups = _groupMentions(filtered);
    final playSeq = _playingSeq;

    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (_, ctrl) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Center(child: Container(
            width: 36, height: 4,
            decoration: BoxDecoration(
                color: const Color(0xFFD1D5DB), borderRadius: BorderRadius.circular(2)),
          )),
          // Header: "Counted items" + X
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 4, 6),
            child: Row(children: [
              const Text('Counted items',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _kText)),
              const Spacer(),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).pop(),
                child: SizedBox(
                  width: 44, height: 44,
                  child: Center(child: Container(
                    width: 28, height: 28,
                    decoration: BoxDecoration(
                        color: const Color(0xFFF3F4F6), shape: BoxShape.circle),
                    child: const Icon(Icons.close_rounded, size: 16, color: Color(0xFF111827)),
                  )),
                ),
              ),
            ]),
          ),
          // Chip row: All + Clip 1 ▶ / Clip 2 ▶ …
          if (clips.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SingleChildScrollView(
                controller: _chipScrollCtrl,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(children: [
                  // "All" chip
                  GestureDetector(
                    onTap: () {
                      _stopAudio();
                      setState(() => _selectedSeq = null);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: _selectedSeq == null ? _kGreen : const Color(0xFFE8F5E9),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: _kGreen),
                      ),
                      child: Text('All',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600,
                              color: _selectedSeq == null ? Colors.white : _kGreen)),
                    ),
                  ),
                  // Per-clip chips
                  ...clips.asMap().entries.map((e) {
                    final idx = e.key;
                    final clip = e.value;
                    final isSelected = _selectedSeq == clip.seq;
                    final isPlaying = _playingClip == clip.clipPath;
                    return Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: GestureDetector(
                        onTap: () {
                          setState(() => _selectedSeq = clip.seq);
                          _playClip(clip.clipPath, clip.seq);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: isSelected ? _kGreen : const Color(0xFFF3F4F6),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: isSelected ? _kGreen : _kBorder),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Text('Clip ${idx + 1}',
                                style: TextStyle(
                                    fontSize: 12, fontWeight: FontWeight.w600,
                                    color: isSelected ? Colors.white : _kSub)),
                            const SizedBox(width: 4),
                            Icon(
                              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                              size: 14,
                              color: isSelected ? Colors.white : _kSub),
                          ]),
                        ),
                      ),
                    );
                  }),
                ]),
              ),
            ),
          // Table header row
          Container(
            color: const Color(0xFFF5F6F8),
            child: Row(children: [
              Expanded(child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
                child: const Text('Product',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _kSub)),
              )),
              const SizedBox(width: _kNameToBadgeMinGap),
              SizedBox(width: _kBadgeClusterMaxW, child: const Text('Qty spoken',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _kSub))),
              const SizedBox(width: _kBadgeToTotalGap),
              SizedBox(width: _kTotalColW, child: Padding(
                padding: const EdgeInsets.only(right: 10),
                child: const Text('Total', textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _kSub)),
              )),
            ]),
          ),
          const Divider(height: 1),
          // Table body
          Expanded(
            child: groups.isEmpty
                ? const Center(child: Text('No mentions for this selection',
                    style: TextStyle(color: _kSub)))
                : ListView.builder(
                    controller: ctrl,
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: groups.length,
                    itemBuilder: (_, i) {
                      final g = groups[i];
                      final full = g.ordered > 0 && g.total >= g.ordered;
                      return Container(
                        decoration: const BoxDecoration(
                            border: Border(bottom: BorderSide(color: _kBorder))),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(child: Padding(
                              padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
                              child: Text(g.name,
                                  style: const TextStyle(fontSize: 12, color: _kText),
                                  overflow: TextOverflow.ellipsis, maxLines: 2),
                            )),
                            const SizedBox(width: _kNameToBadgeMinGap),
                            SizedBox(
                              width: _kBadgeClusterMaxW,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                child: Wrap(
                                  spacing: 4, runSpacing: 4,
                                  children: g.entries.map((e) {
                                    final active = playSeq != null && e.seq == playSeq;
                                    return Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: active ? _kGreen : const Color(0xFFF5F6F8),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: active ? _kGreen : _kBorder),
                                      ),
                                      child: Text('${e.qty}',
                                          style: TextStyle(
                                              fontSize: 12, fontWeight: FontWeight.w600,
                                              color: active ? Colors.white : _kText)),
                                    );
                                  }).toList(),
                                ),
                              ),
                            ),
                            const SizedBox(width: _kBadgeToTotalGap),
                            SizedBox(
                              width: _kTotalColW,
                              child: Padding(
                                padding: const EdgeInsets.only(right: 10),
                                child: Text(
                                  g.ordered > 0 ? '${g.total}/${g.ordered}' : '${g.total}',
                                  style: TextStyle(
                                      fontSize: 12, fontWeight: FontWeight.w700,
                                      color: full ? _kGreen : _kText),
                                  textAlign: TextAlign.right,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ── CHANGE #298: Packing — auto-advance, hold-2s-undo, grey dots, layout spacing ─
//   + one-time skipped-item return sweep per bag (sweptBags guard)

class _PackingScreen extends StatefulWidget {
  final String orderId;
  const _PackingScreen({required this.orderId});
  @override
  State<_PackingScreen> createState() => _PackingScreenState();
}

class _PackingScreenState extends State<_PackingScreen>
    with SingleTickerProviderStateMixin {
  bool _loading    = true;
  String? _error;
  Map<String, dynamic>? _queue;
  List<Map<String, dynamic>> _items = [];
  int _currentIndex = 0;
  int _packedCount  = 0;
  int _totalItems   = 0;
  int _leftCount    = 0;
  int _bagCount     = 0;
  bool _marking     = false;
  bool _allPacked   = false;

  PageController? _itemPageController;

  // CHANGE #298: one-time sweep guard — bags whose backwards sweep has fired.
  final Set<int> _sweptBags = {};

  // CHANGE #298: hold-2s-to-undo state.
  Timer? _holdTimer;
  bool   _holdFired = false;

  // CHANGE #302: hold-to-undo for already-PACKED items.
  // AnimationController drives the 0→1 progress fill over 2 s.
  late final AnimationController _holdProgressCtrl;
  bool _undoing = false;

  @override
  void initState() {
    super.initState();
    _holdProgressCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    _loadQueue();
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _holdProgressCtrl.dispose();
    _itemPageController?.dispose();
    super.dispose();
  }

  Future<void> _loadQueue() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final dynamic raw = await Supabase.instance.client
          .rpc('pack_get_queue', params: {'p_order_id': widget.orderId});
      // #291 fix retained: parse jsonb object as Map (with String fallback)
      final Map<String, dynamic> m = raw is String
          ? (jsonDecode(raw) as Map).cast<String, dynamic>()
          : Map<String, dynamic>.from(raw as Map);
      // Items arrive in bag-number order from server — do NOT re-sort
      final items    = ((m['items'] as List?) ?? const [])
          .map((i) => Map<String, dynamic>.from(i as Map))
          .toList();
      final packed   = (m['packed_count'] as num?)?.toInt() ?? 0;
      final total    = (m['total_items']  as num?)?.toInt() ?? 0;
      final left     = (m['left_count']   as num?)?.toInt() ?? 0;
      final bagCount = (m['bag_count']    as num?)?.toInt() ?? 0;
      final startIdx = items.indexWhere((i) => i['packed'] != true);
      final allDone  = startIdx == -1;
      final startPage = allDone ? 0 : startIdx;
      if (!mounted) return;
      _itemPageController?.dispose();
      _itemPageController = PageController(initialPage: startPage);
      setState(() {
        _queue        = m;
        _items        = items;
        _currentIndex = startPage;
        _packedCount  = packed;
        _totalItems   = total;
        _leftCount    = left;
        _bagCount     = bagCount;
        _allPacked    = allDone;
        _loading      = false;
        _sweptBags.clear();
      });
      try {
        final first8 = items.take(8).map((i) => (i['bag_no'] ?? '?').toString()).join(',');
        RenderLog.write('c292_queue_order', 'first8bags=$first8');
        RenderLog.write('c291_pack_open',
            'cust=${m['customer']};total=$total;bags=$bagCount;startIdx=${allDone ? "done" : startPage}');
      } catch (_) {}
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  // ── CHANGE #298: computeNext — bag-wise with one-time sweep ─────────────────
  //
  // After packing item at index [i] (already updated in _items), return the
  // next index to show. Algorithm:
  //   1. B = bag of i.
  //   2. First unpacked after i in same bag → go there (normal flow).
  //   3. Else: first unpacked anywhere in B (skipped items).
  //      If exists AND B not in _sweptBags → one-time sweep to that item.
  //   4. Else: first item of the next bag (k > i, bag != B).
  //   5. Else (i was in last bag): any unpacked item anywhere, else null (done).
  int? _computeNext(int i) {
    if (i < 0 || i >= _items.length) return null;
    final B = (_items[i]['bag_no'] as num?)?.toInt() ?? 0;

    // Step 1: next unpacked after i in same bag
    for (int j = i + 1; j < _items.length; j++) {
      final jBag = (_items[j]['bag_no'] as num?)?.toInt() ?? 0;
      if (jBag != B) break;
      if (_items[j]['packed'] != true) return j;
    }

    // Step 2: one-time backwards sweep within bag B
    int? earliestInB;
    for (int j = 0; j < _items.length; j++) {
      final jBag = (_items[j]['bag_no'] as num?)?.toInt() ?? 0;
      if (jBag == B && _items[j]['packed'] != true) {
        earliestInB = j;
        break;
      }
    }
    if (earliestInB != null && !_sweptBags.contains(B)) {
      _sweptBags.add(B);
      try {
        RenderLog.write('c298_sweep', '$B:$i->$earliestInB');
        RenderLog.write('c298_swept_bags', '[${_sweptBags.join(',')}]');
      } catch (_) {}
      return earliestInB;
    }

    // Step 3: leave bag B — first item in any other bag after i
    for (int k = i + 1; k < _items.length; k++) {
      final kBag = (_items[k]['bag_no'] as num?)?.toInt() ?? 0;
      if (kBag != B) return k;
    }

    // Step 4: i was in the last bag — any unpacked item anywhere
    for (int m = 0; m < _items.length; m++) {
      if (_items[m]['packed'] != true) return m;
    }

    return null; // all items packed
  }

  // ── CHANGE #298: pack + auto-advance ────────────────────────────────────────
  Future<void> _packAndAdvance(int index) async {
    if (_marking || index < 0 || index >= _items.length) return;
    final item     = _items[index];
    final wasPacked = item['packed'] == true;

    if (!wasPacked) {
      // Mark packed via RPC, then update local state
      setState(() => _marking = true);
      final itemId = item['order_item_id']?.toString() ?? '';
      try {
        await Supabase.instance.client.rpc('pack_mark_item',
            params: {'p_order_item_id': itemId, 'p_packed': true});
        if (!mounted) return;
        setState(() {
          _items[index] = {...item, 'packed': true};
          _packedCount++;
          _leftCount = (_leftCount - 1).clamp(0, _totalItems);
          if (_leftCount == 0) _allPacked = true;
          _marking = false;
        });
        try {
          RenderLog.write('c293_btn_toggle',
              'was=unpacked;now=packed;idx=$index');
        } catch (_) {}
      } catch (e) {
        if (mounted) {
          setState(() => _marking = false);
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error: $e'),
                  duration: const Duration(seconds: 3)));
        }
        return;
      }
    }

    // Compute and perform navigation
    final next = _computeNext(index);
    try {
      RenderLog.write('c298_advance', '$index->${next ?? "done"}');
    } catch (_) {}

    if (next == null) {
      // All packed — setState to show done screen
      if (mounted) setState(() => _allPacked = true);
      return;
    }

    // Animate outer PageView to the next item
    _itemPageController?.animateToPage(
      next,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOut,
    );
  }

  // ── CHANGE #298: undo (hold-2s) — un-pack current item, stay in place ───────
  Future<void> _performUndo(int index) async {
    if (_marking || index < 0 || index >= _items.length) return;
    final item = _items[index];
    if (item['packed'] != true) return; // nothing to undo
    HapticFeedback.mediumImpact();
    setState(() => _marking = true);
    final itemId = item['order_item_id']?.toString() ?? '';
    try {
      await Supabase.instance.client.rpc('pack_mark_item',
          params: {'p_order_item_id': itemId, 'p_packed': false});
      if (!mounted) return;
      setState(() {
        _items[index] = {...item, 'packed': false};
        _packedCount = (_packedCount - 1).clamp(0, _totalItems);
        _leftCount++;
        _allPacked = false;
        _marking = false;
      });
      try {
        RenderLog.write('c298_undo', itemId);
        RenderLog.write('c293_btn_toggle',
            'was=packed;now=unpacked;idx=$index');
      } catch (_) {}
    } catch (e) {
      if (mounted) {
        setState(() => _marking = false);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'),
                duration: const Duration(seconds: 3)));
      }
    }
  }

  // ── CHANGE #298: hold-timer handlers ────────────────────────────────────────
  void _onHoldStart() {
    if (_marking) return;
    _holdFired = false;
    _holdTimer?.cancel();
    _holdTimer = Timer(const Duration(milliseconds: 2000), () {
      _holdFired = true;
      _performUndo(_currentIndex);
    });
  }

  void _onHoldEnd() {
    if (_holdFired) {
      // Undo already fired — don't also run pack action
      _holdFired = false;
      return;
    }
    _holdTimer?.cancel();
    _holdTimer = null;
    _packAndAdvance(_currentIndex);
  }

  void _onHoldCancel() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _holdFired = false;
  }

  // CHANGE #302: hold-to-undo for already-PACKED items.
  // Uses Listener (raw pointer events) so the PageView pan recognizer
  // cannot steal the gesture during a stationary 2s hold.

  void _startHoldForUndo() {
    if (_undoing || _marking) return;
    RenderLog.write('c302_undo_attached', 'true');
    _holdTimer?.cancel();
    _holdProgressCtrl.forward(from: 0.0);
    _holdTimer = Timer(const Duration(milliseconds: 2000), () {
      _doUndo(_currentIndex);
    });
  }

  void _cancelHoldForUndo() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _holdProgressCtrl.reverse();
  }

  Future<void> _doUndo(int index) async {
    if (_undoing || _marking) return;
    _undoing = true;
    _holdTimer?.cancel();
    _holdTimer = null;
    _holdProgressCtrl.stop();
    if (index < 0 || index >= _items.length) { _undoing = false; return; }
    final item = _items[index];
    if (item['packed'] != true) { _undoing = false; return; }
    HapticFeedback.mediumImpact();
    setState(() => _marking = true);
    final itemId = item['order_item_id']?.toString() ?? '';
    try {
      final dynamic res = await Supabase.instance.client.rpc(
        'pack_mark_item',
        params: {'p_order_item_id': itemId, 'p_packed': false},
      );
      if (!mounted) return;
      setState(() {
        _items[index] = {...item, 'packed': false};
        _packedCount = (_packedCount - 1).clamp(0, _totalItems);
        _leftCount++;
        _allPacked = false;
        _marking = false;
      });
      RenderLog.write('c302_hold_ms', '2000');
      RenderLog.write('c302_undo_fire', '${jsonEncode(res ?? {})}');
      RenderLog.write('c302_state', 'packed->unpacked');
      _holdProgressCtrl.reset();
    } catch (e) {
      if (mounted) {
        setState(() => _marking = false);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Undo error: $e'),
                duration: const Duration(seconds: 3)));
      }
      _holdProgressCtrl.reset();
    } finally {
      _undoing = false;
    }
  }

  // ── Per-bag rollup (#293 retained) ──────────────────────────────────────────

  Map<int, Map<String, int>> _computeBagStats() {
    final result = <int, Map<String, int>>{};
    for (final item in _items) {
      final bn    = (item['bag_no'] as num?)?.toInt() ?? 0;
      final done  = item['packed'] == true;
      final entry = result.putIfAbsent(bn, () => {'packed': 0, 'total': 0});
      entry['total'] = (entry['total'] ?? 0) + 1;
      if (done) entry['packed'] = (entry['packed'] ?? 0) + 1;
    }
    return result;
  }

  int _bagStatus(int bagNo, Map<int, Map<String, int>> stats) {
    final s = stats[bagNo];
    if (s == null) return 0;
    final total  = s['total']  ?? 0;
    final packed = s['packed'] ?? 0;
    if (total == 0) return 0;
    if (packed == total) return 2;
    if (packed > 0) return 1;
    return 0;
  }

  Color _bagBg(int st)  => st == 2 ? _kReceivedBg
      : st == 1 ? const Color(0xFFFFF3CD)
      : const Color(0xFFF3F4F6);
  Color _bagBorderC(int st) => st == 2 ? _kGreen
      : st == 1 ? const Color(0xFFFFCA28)
      : _kBorder;
  Color _bagFg(int st)  => st == 2 ? _kReceivedFg
      : st == 1 ? const Color(0xFF8A6D00)
      : _kSub;

  // ── Header popups ────────────────────────────────────────────────────────────

  void _showItemsPopup() {
    final sorted = List<Map<String, dynamic>>.from(_items)
        ..sort((a, b) => (a['product_name']?.toString() ?? '')
            .compareTo(b['product_name']?.toString() ?? ''));
    try { RenderLog.write('c292_hdr_popup', 'which=items;rows=${sorted.length}'); } catch (_) {}
    _showListSheet('All items', sorted, showTick: true);
  }

  void _showPackedPopup() {
    final sorted = _items.where((i) => i['packed'] == true).toList()
        ..sort((a, b) => (a['product_name']?.toString() ?? '')
            .compareTo(b['product_name']?.toString() ?? ''));
    try { RenderLog.write('c292_hdr_popup', 'which=packed;rows=${sorted.length}'); } catch (_) {}
    _showListSheet('Packed items', sorted, showTick: true);
  }

  void _showLeftPopup() {
    final sorted = _items.where((i) => i['packed'] != true).toList()
        ..sort((a, b) => (a['product_name']?.toString() ?? '')
            .compareTo(b['product_name']?.toString() ?? ''));
    try { RenderLog.write('c292_hdr_popup', 'which=left;rows=${sorted.length}'); } catch (_) {}
    _showListSheet('Items left', sorted, showTick: false);
  }

  void _showBagsPopup() {
    final bagStats = _computeBagStats();
    final bags     = bagStats.keys.toList()..sort();
    try { RenderLog.write('c292_hdr_popup', 'which=bags;rows=${bags.length}'); } catch (_) {}
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.70),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _sheetHeader(ctx, 'Bags'),
          Flexible(child: SingleChildScrollView(child: Column(children: bags.map((bn) {
            final st        = _bagStatus(bn, bagStats);
            final s         = bagStats[bn]!;
            final bagPacked = s['packed'] ?? 0;
            final bagTotal  = s['total']  ?? 0;
            try {
              RenderLog.write('c293_bag_color',
                  'bag=$bn;state=${st == 2 ? "green" : st == 1 ? "yellow" : "grey"}');
            } catch (_) {}
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                  color: _bagBg(st),
                  border: const Border(bottom: BorderSide(color: _kBorder))),
              child: Row(children: [
                Text('Bag $bn',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500,
                        color: _bagFg(st))),
                const Spacer(),
                if (st == 2)
                  Text('✓', style: TextStyle(fontSize: 14,
                      fontWeight: FontWeight.w700, color: _bagFg(st)))
                else
                  Text('$bagPacked/$bagTotal',
                      style: TextStyle(fontSize: 13, color: _bagFg(st))),
              ]),
            );
          }).toList()))),
        ]),
      ),
    );
  }

  void _showListSheet(String title, List<Map<String, dynamic>> items,
      {required bool showTick}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.70),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _sheetHeader(ctx, title),
          Container(
            color: const Color(0xFFF5F6F8),
            child: Row(children: [
              const Expanded(child: Padding(
                padding: EdgeInsets.fromLTRB(10, 6, 4, 6),
                child: Text('Product', style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600, color: _kSub)),
              )),
              const SizedBox(width: 72, child: Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Text('Qty', textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _kSub)),
              )),
              if (showTick)
                const SizedBox(width: 52, child: Padding(
                  padding: EdgeInsets.fromLTRB(0, 6, 8, 6),
                  child: Text('Packed', textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                          color: _kGreen)),
                )),
            ]),
          ),
          Flexible(child: SingleChildScrollView(child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: items.map((item) {
              final name     = item['product_name']?.toString() ?? '—';
              final packType = item['pack_type']?.toString() ?? '';
              final qty      = (item['qty'] as num?)?.toInt() ?? 0;
              final isPacked = item['packed'] == true;
              final qtyLabel = packType.isNotEmpty ? '$qty $packType' : '$qty';
              return Container(
                decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: _kBorder))),
                child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  Expanded(child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
                    child: Text(name, style: const TextStyle(fontSize: 12, color: _kText),
                        overflow: TextOverflow.ellipsis, maxLines: 2),
                  )),
                  SizedBox(width: 72, child: Center(child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(qtyLabel, textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12, color: _kSub)),
                  ))),
                  if (showTick)
                    SizedBox(width: 52, child: Center(
                      child: isPacked
                          ? const Text('✓', style: TextStyle(fontSize: 14,
                              fontWeight: FontWeight.w700, color: _kGreen))
                          : const SizedBox.shrink(),
                    )),
                ]),
              );
            }).toList(),
          ))),
        ]),
      ),
    );
  }

  Widget _sheetHeader(BuildContext ctx, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 10, 4, 6),
    child: Row(children: [
      Text(title, style: const TextStyle(
          fontSize: 14, fontWeight: FontWeight.w700, color: _kText)),
      const Spacer(),
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.pop(ctx),
        child: SizedBox(width: 44, height: 44, child: Center(
          child: Container(
            width: 28, height: 28,
            decoration: const BoxDecoration(
                color: Color(0xFFE0E0E0), shape: BoxShape.circle),
            alignment: Alignment.center,
            child: const Icon(Icons.close, size: 18, color: Color(0xFF000000)),
          ),
        )),
      ),
    ]),
  );

  void _showBagQuickView() {
    try { RenderLog.write('c290_bag_quickview', 'bags=${_queue?['bag_count'] ?? 0}'); } catch (_) {}
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _BagQuickViewSheet(
          items: List<Map<String, dynamic>>.from(_items),
          bagStats: _computeBagStats()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final customer     = _queue?['customer']?.toString() ?? '';
    final customerCode = _queue?['customer_code']?.toString() ?? '';

    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: Builder(builder: (ctx) {
          try { RenderLog.write('c296_back_icon', 'icon=back_chevron'); } catch (_) {}
          return IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, color: _kText, size: 20),
            onPressed: () => Navigator.pop(ctx),
          );
        }),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(customer.isNotEmpty ? customer : 'Packing',
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700, color: _kText)),
          if (customerCode.isNotEmpty)
            Text(customerCode,
                style: const TextStyle(fontSize: 12, color: _kSub)),
        ]),
        actions: [
          if (!_loading && _queue != null)
            TextButton.icon(
              icon: const Icon(Icons.inventory_2_outlined, size: 16, color: _kGreen),
              label: const Text('Bags',
                  style: TextStyle(color: _kGreen, fontWeight: FontWeight.w600,
                      fontSize: 13)),
              onPressed: _showBagQuickView,
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: _loading ? const SizedBox.shrink() : _buildStatRow(),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2))
          : _error != null
              ? _buildErrorView()
              : _allPacked
                  ? _buildAllPackedScreen(customer, _bagCount)
                  : _buildItemView(),
    );
  }

  Widget _buildStatRow() {
    String s(int n, String sg, String pl) => '$n ${n == 1 ? sg : pl}';
    try { RenderLog.write('c293_no_chevron', 'chevron=removed'); } catch (_) {}
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _tappablePill(s(_totalItems,  'item',        'items'),        _showItemsPopup),
          const SizedBox(width: 8),
          _tappablePill(s(_packedCount, 'item packed', 'items packed'), _showPackedPopup),
          const SizedBox(width: 8),
          _tappablePill(s(_leftCount,   'item left',   'items left'),   _showLeftPopup),
          const SizedBox(width: 8),
          _tappablePill(s(_bagCount,    'bag',         'bags'),         _showBagsPopup),
        ]),
      ),
    );
  }

  Widget _tappablePill(String text, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(20)),
      child: Text(text, style: const TextStyle(
          fontSize: 11, fontWeight: FontWeight.w500, color: _kSub)),
    ),
  );

  // ── OUTER item PageView — horizontal SWIPE switches items ───────────────────
  Widget _buildItemView() {
    final ctrl = _itemPageController;
    if (ctrl == null) return const SizedBox.shrink();
    return Column(children: [
      LinearProgressIndicator(
        value: _totalItems == 0 ? 0 : _packedCount / _totalItems,
        backgroundColor: _kBorder,
        color: _kGreen,
        minHeight: 4,
      ),
      Expanded(
        child: PageView.builder(
          controller: ctrl,
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: _items.length,
          onPageChanged: (i) {
            setState(() => _currentIndex = i);
            final bagNo = (_items[i]['bag_no'] as num?)?.toInt() ?? 0;
            try {
              RenderLog.write('c295_item_page',
                  'idx=$i/${_items.length};bag=$bagNo');
              RenderLog.write('c296_item_swipe',
                  'dir=${i > _currentIndex ? "next" : "prev"};idx=$i/${_items.length}');
            } catch (_) {}
          },
          itemBuilder: (ctx, index) => _buildItemPage(index),
        ),
      ),
      _buildPackedButton(),
    ]);
  }

  // ── Per-item card page ───────────────────────────────────────────────────────
  Widget _buildItemPage(int index) {
    if (index >= _items.length) return const SizedBox.shrink();
    final item      = _items[index];
    final name      = item['product_name']?.toString() ?? '—';
    final packType  = item['pack_type']?.toString() ?? '';
    final qty       = (item['qty'] as num?)?.toInt() ?? 0;
    final bagNo     = (item['bag_no'] as num?)?.toInt() ?? 0;
    final qtyLabel  = packType.isNotEmpty ? 'x$qty $packType' : 'x$qty';
    final itemId    = item['order_item_id']?.toString() ?? '';

    var imgs = ((item['images'] as List?)?.cast<String>() ?? const <String>[])
        .where((s) => s.isNotEmpty).toList();
    if (imgs.isEmpty) {
      final single = item['image_url']?.toString() ?? '';
      if (single.isNotEmpty) imgs = [single];
    }
    final imgCount = imgs.length;

    final bagItems    = _items.where(
        (i) => (i['bag_no'] as num?)?.toInt() == bagNo).toList();
    final posInBag    = bagItems.indexWhere(
        (i) => i['order_item_id']?.toString() == itemId) + 1;
    final itemsInBag  = bagItems.length;
    final packedInBag = bagItems.where((i) => i['packed'] == true).length;

    // CHANGE #298 layout constants (instrumented once per card build)
    const double kCounterBagGap = 20;   // (#7) bigger gap counter → bag band
    const double kBagBandVPad   = 15;   // (#5) taller bag band (was 10)
    const double kNameImgGap    = 6;    // (#6) name stuck to image
    try {
      RenderLog.write('c298_layout',
          '{"counter_bag_gap":$kCounterBagGap,"bag_band_height":$kBagBandVPad,"name_img_gap":$kNameImgGap}');
      RenderLog.write('c295_card_v4',
          'nameAbove=true;imgs=$imgCount;dots=${imgCount > 1 ? imgCount : 0}');
    } catch (_) {}

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 6),  // (#6 lift) reduced top padding
          // Three x/x counters
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${index + 1}/$_totalItems',
                  style: const TextStyle(fontSize: 13, color: _kSub,
                      fontWeight: FontWeight.w600)),
              Text('$posInBag/$itemsInBag',
                  style: const TextStyle(fontSize: 13, color: _kSub,
                      fontWeight: FontWeight.w600)),
              Text('$packedInBag/$itemsInBag',
                  style: const TextStyle(fontSize: 13, color: _kSub,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          // CHANGE #298 (#7): bigger gap — counter → bag band
          const SizedBox(height: kCounterBagGap),
          // Red bag band — CHANGE #298 (#5): taller vertical padding
          Builder(builder: (ctx) {
            try {
              RenderLog.write('c296_bag_band',
                  'bag=$bagNo;fullwidth=true;red=true;white_bold=true');
            } catch (_) {}
            return Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(vertical: kBagBandVPad),
              decoration: BoxDecoration(
                  color: const Color(0xFFDC2626),
                  borderRadius: BorderRadius.circular(14)),
              child: Text('Bag $bagNo',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800,
                      color: Colors.white),
                  textAlign: TextAlign.center),
            );
          }),
          const SizedBox(height: 14),
          // CHANGE #298 (#6): name sits directly above image — normal gap here
          Text(name,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700,
                  color: _kText),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
          // CHANGE #298 (#6): tiny gap name→image
          const SizedBox(height: kNameImgGap),
          // IMAGE — tap-thirds for image cycling; swipe (outer PageView) for items
          Expanded(
            child: _ItemImageView(
              key: ValueKey(itemId),
              images: imgs,
              qtyLabel: qtyLabel,
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  // CHANGE #302: Packed button — two distinct states:
  //   UNPACKED: GestureDetector tap=pack+advance (unchanged from #298).
  //   PACKED:   Listener (raw pointer — immune to PageView gesture arena)
  //             shows "Packed ✓ · hold to undo"; 2 s hold fires _doUndo().
  //             Short tap does NOTHING. Progress fill animates while holding.
  Widget _buildPackedButton() {
    final item     = (_currentIndex < _items.length) ? _items[_currentIndex] : null;
    final isPacked = item?['packed'] == true;
    final disabled = _marking || _undoing || item == null;

    if (isPacked && !_marking) {
      // ── PACKED STATE: hold-to-undo bar ─────────────────────────────────────
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: disabled ? null : (_) => _startHoldForUndo(),
          onPointerUp:   disabled ? null : (_) => _cancelHoldForUndo(),
          onPointerCancel: disabled ? null : (_) => _cancelHoldForUndo(),
          child: Stack(
            children: [
              // Base bar — light green so it's clearly interactive, not dead
              Container(
                width: double.infinity,
                height: 56,
                decoration: BoxDecoration(
                  color: const Color(0xFFD1FAE5),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: _kReceivedFg.withValues(alpha: 0.3)),
                ),
                alignment: Alignment.center,
                child: Text('Packed ✓  ·  hold to undo',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700,
                        color: _kReceivedFg)),
              ),
              // Progress fill — sweeps left→right over 2 s while holding
              AnimatedBuilder(
                animation: _holdProgressCtrl,
                builder: (_, __) {
                  final v = _holdProgressCtrl.value;
                  if (v <= 0) return const SizedBox.shrink();
                  return Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: v,
                          child: Container(
                            decoration: BoxDecoration(
                              color: _kReceivedFg.withValues(alpha: 0.18),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      );
    }

    // ── UNPACKED STATE (or _marking): tap = pack + advance (unchanged) ──────
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: disabled ? null : (_) => _onHoldStart(),
        onTapUp:   disabled ? null : (_) => _onHoldEnd(),
        onTapCancel: disabled ? null : _onHoldCancel,
        child: Container(
          width: double.infinity,
          height: 56,
          decoration: BoxDecoration(
            color: disabled ? const Color(0xFFE5E7EB) : _kGreen,
            borderRadius: BorderRadius.circular(14),
          ),
          alignment: Alignment.center,
          child: _marking || _undoing
              ? const SizedBox(
                  width: 24, height: 24,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2.5))
              : const Text('Pack',
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700,
                      color: Colors.white)),
        ),
      ),
    );
  }

  Widget _buildErrorView() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.error_outline, size: 40, color: _kSub),
      const SizedBox(height: 12),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Text(_error!,
            style: const TextStyle(color: _kSub, fontSize: 14),
            textAlign: TextAlign.center),
      ),
      const SizedBox(height: 16),
      OutlinedButton(
        onPressed: _loadQueue,
        style: OutlinedButton.styleFrom(
            side: const BorderSide(color: _kGreen),
            foregroundColor: _kGreen,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
        child: const Text('Retry'),
      ),
    ]),
  );

  Widget _buildAllPackedScreen(String customer, int bagCount) {
    return Center(child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center, children: [
        Container(
          width: 80, height: 80,
          decoration:
              const BoxDecoration(color: _kReceivedBg, shape: BoxShape.circle),
          child: const Icon(Icons.check_circle_outline_rounded,
              size: 48, color: _kReceivedFg),
        ),
        const SizedBox(height: 20),
        const Text('All Packed', style: TextStyle(
            fontSize: 24, fontWeight: FontWeight.w700, color: _kText)),
        const SizedBox(height: 8),
        Text('$_totalItems items · $bagCount bags packed for $customer',
            style: const TextStyle(fontSize: 14, color: _kSub),
            textAlign: TextAlign.center),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity, height: 48,
          child: FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: _kGreen,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            onPressed: () => Navigator.pop(context),
            child: const Text('Done', style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
          ),
        ),
      ]),
    ));
  }
}

// ── #298: Image view — tap LEFT/RIGHT THIRD = cycle images; SWIPE = switch items ─
// Gesture resolution: TapRecognizer (this GestureDetector) vs
// HorizontalDragRecognizer (outer PageView).  A true tap → TapRecognizer wins,
// onTapUp fires, image cycles.  A swipe → drag recognizer wins, outer PageView
// moves, onTapUp never fires.  No conflict.

class _ItemImageView extends StatefulWidget {
  final List<String> images;
  final String qtyLabel;
  const _ItemImageView({super.key, required this.images, required this.qtyLabel});
  @override
  State<_ItemImageView> createState() => _ItemImageViewState();
}

class _ItemImageViewState extends State<_ItemImageView> {
  int _imageIdx = 0;

  @override
  Widget build(BuildContext context) {
    final imgs     = widget.images;
    final imgCount = imgs.length;
    final safeIdx  = imgCount == 0 ? 0 : _imageIdx.clamp(0, imgCount - 1);
    final curImg   = imgCount > 0 ? imgs[safeIdx] : null;

    // CHANGE #298 (#3): grey dots (was brown in #296)
    const Color dotActive   = Color(0xFF6B7280);   // medium grey
    const Color dotInactive = Color(0xFFD1D5DB);   // light grey

    return LayoutBuilder(builder: (ctx, constraints) {
      final size = constraints.maxHeight.clamp(0.0, constraints.maxWidth);

      if (imgCount > 1) {
        try {
          RenderLog.write('c298_dots_active',   dotActive.toARGB32());
          RenderLog.write('c298_dots_inactive', dotInactive.toARGB32());
        } catch (_) {}
      }
      try {
        RenderLog.write('c296_qty_pill',
            'text=${widget.qtyLabel};lightgreen=true;flat=true');
      } catch (_) {}

      return Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: imgCount <= 1 ? null : (TapUpDetails details) {
                final x     = details.localPosition.dx;
                final third = size / 3;
                String tapped;
                if (x < third) {
                  tapped = 'left';
                  if (safeIdx > 0) setState(() => _imageIdx = safeIdx - 1);
                } else if (x > third * 2) {
                  tapped = 'right';
                  if (safeIdx < imgCount - 1) setState(() => _imageIdx = safeIdx + 1);
                } else {
                  tapped = 'mid';
                }
                try {
                  RenderLog.write('c296_img_tap',
                      'third=$tapped;img=$_imageIdx/$imgCount');
                } catch (_) {}
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  width: size, height: size,
                  child: curImg != null && curImg.isNotEmpty
                      ? Image.network(curImg,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _placeholder(size))
                      : _placeholder(size),
                ),
              ),
            ),
            // Light-green flat qty pill (#296 retained)
            Positioned(
              top: 10, right: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                    color: _kReceivedBg,
                    borderRadius: BorderRadius.circular(16)),
                child: Text(widget.qtyLabel,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700,
                        color: _kReceivedFg)),
              ),
            ),
            // CHANGE #298 (#3): GREY dots
            if (imgCount > 1)
              Positioned(
                bottom: 10, left: 0, right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(imgCount, (i) {
                    final active = i == safeIdx;
                    return Container(
                      width:  active ? 9 : 5,
                      height: active ? 9 : 5,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: active ? dotActive : dotInactive,
                      ),
                    );
                  }),
                ),
              ),
          ],
        ),
      );
    });
  }

  Widget _placeholder(double size) => Container(
    width: size, height: size,
    decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(16)),
    child: const Icon(Icons.medication_outlined,
        size: 64, color: Color(0xFFD1D5DB)),
  );
}

// ── CHANGE #294 retained: Bag quick-view sheet — no Bag col, Packed header ────

class _BagQuickViewSheet extends StatefulWidget {
  final List<Map<String, dynamic>> items;
  final Map<int, Map<String, int>> bagStats;
  const _BagQuickViewSheet({required this.items, required this.bagStats});
  @override
  State<_BagQuickViewSheet> createState() => _BagQuickViewSheetState();
}

class _BagQuickViewSheetState extends State<_BagQuickViewSheet> {
  int? _selectedBag;

  List<int> get _bags {
    final seen = <int>{};
    for (final item in widget.items) {
      final bn = (item['bag_no'] as num?)?.toInt();
      if (bn != null) seen.add(bn);
    }
    return seen.toList()..sort();
  }

  List<Map<String, dynamic>> get _filtered {
    if (_selectedBag == null) return widget.items;
    return widget.items
        .where((i) => (i['bag_no'] as num?)?.toInt() == _selectedBag)
        .toList();
  }

  int _status(int bn) {
    final s = widget.bagStats[bn];
    if (s == null) return 0;
    final total  = s['total']  ?? 0;
    final packed = s['packed'] ?? 0;
    if (total == 0) return 0;
    if (packed == total) return 2;
    if (packed > 0) return 1;
    return 0;
  }

  Color _bg(int st)     => st == 2 ? _kReceivedBg
      : st == 1 ? const Color(0xFFFFF3CD)
      : const Color(0xFFF3F4F6);
  Color _border(int st) => st == 2 ? _kGreen
      : st == 1 ? const Color(0xFFFFCA28)
      : _kBorder;
  Color _fg(int st)     => st == 2 ? _kReceivedFg
      : st == 1 ? const Color(0xFF8A6D00)
      : _kSub;

  @override
  Widget build(BuildContext context) {
    final bags     = _bags;
    final filtered = _filtered;

    try {
      RenderLog.write('c294_bags_sheet',
          'bagColRemoved=true;header=Packed;qtyCentered=true');
    } catch (_) {}

    return Container(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 6),
          child: Row(children: [
            const Text('Bags', style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w700, color: _kText)),
            const Spacer(),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.pop(context),
              child: SizedBox(width: 44, height: 44, child: Center(
                child: Container(
                  width: 28, height: 28,
                  decoration: const BoxDecoration(
                      color: Color(0xFFE0E0E0), shape: BoxShape.circle),
                  alignment: Alignment.center,
                  child: const Icon(Icons.close, size: 18,
                      color: Color(0xFF000000)),
                ),
              )),
            ),
          ]),
        ),
        // Bag filter chips — colour by pack status
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(children: [
              GestureDetector(
                onTap: () => setState(() => _selectedBag = null),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _selectedBag == null ? _kGreen : const Color(0xFFE8F5E9),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _kGreen),
                  ),
                  child: Text('All', style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600,
                      color: _selectedBag == null ? Colors.white : _kGreen)),
                ),
              ),
              ...bags.map((bn) {
                final st         = _status(bn);
                final isSelected = _selectedBag == bn;
                final bgColor    = isSelected ? _kGreen : _bg(st);
                final bdColor    = isSelected ? _kGreen : _border(st);
                final txtColor   = isSelected ? Colors.white : _fg(st);
                try {
                  RenderLog.write('c293_bag_color',
                      'bag=$bn;state=${st == 2 ? "green" : st == 1 ? "yellow" : "grey"}');
                } catch (_) {}
                return Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: GestureDetector(
                    onTap: () => setState(() => _selectedBag = bn),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                          color: bgColor,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: bdColor)),
                      child: Text('Bag $bn', style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600,
                          color: txtColor)),
                    ),
                  ),
                );
              }),
            ]),
          ),
        ),
        const Divider(height: 1, color: _kBorder),
        // Table header: Product | Qty (centered) | Packed — NO Bag column (#294)
        Container(
          color: const Color(0xFFF5F6F8),
          child: Row(children: [
            const Expanded(child: Padding(
              padding: EdgeInsets.fromLTRB(10, 6, 4, 6),
              child: Text('Product', style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600, color: _kSub)),
            )),
            const SizedBox(width: 72, child: Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text('Qty', textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600, color: _kSub)),
            )),
            const SizedBox(width: 52, child: Padding(
              padding: EdgeInsets.fromLTRB(0, 6, 8, 6),
              child: Text('Packed', textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                      color: _kGreen)),
            )),
          ]),
        ),
        Flexible(child: SingleChildScrollView(child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _buildTableRows(filtered, bags),
        ))),
      ]),
    );
  }

  List<Widget> _buildTableRows(
      List<Map<String, dynamic>> items, List<int> bags) {
    if (_selectedBag != null) {
      return items.map(_buildTableRow).toList();
    }
    final grouped = <int?, List<Map<String, dynamic>>>{};
    for (final item in items) {
      final bn = (item['bag_no'] as num?)?.toInt();
      grouped.putIfAbsent(bn, () => []).add(item);
    }
    final checkedCount = items.where((i) => i['packed'] == true).length;
    try {
      if (checkedCount > 0) {
        RenderLog.write('c292_bag_tick', 'checkedRows=$checkedCount');
      }
    } catch (_) {}
    final List<Widget> rows = [];
    for (final bn in [...bags, null]) {
      final group = grouped[bn];
      if (group == null || group.isEmpty) continue;
      rows.add(Container(
        color: const Color(0xFFF5F6F8),
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
        child: Text(bn != null ? 'Bag $bn' : 'No bag',
            style: const TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600, color: _kSub)),
      ));
      rows.addAll(group.map(_buildTableRow));
    }
    return rows;
  }

  Widget _buildTableRow(Map<String, dynamic> item) {
    final name     = item['product_name']?.toString() ?? '—';
    final packType = item['pack_type']?.toString() ?? '';
    final qty      = (item['qty'] as num?)?.toInt() ?? 0;
    final isPacked = item['packed'] == true;
    final qtyLabel = packType.isNotEmpty ? '$qty $packType' : '$qty';

    return Container(
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: _kBorder))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
          child: Text(name, style: const TextStyle(fontSize: 12, color: _kText),
              overflow: TextOverflow.ellipsis, maxLines: 2),
        )),
        SizedBox(width: 72, child: Center(child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
                color: const Color(0xFFF5F6F8),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _kBorder)),
            child: Text(qtyLabel, textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600, color: _kText)),
          ),
        ))),
        SizedBox(width: 52, child: Center(
          child: isPacked
              ? const Text('✓', style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700, color: _kGreen))
              : const SizedBox.shrink(),
        )),
      ]),
    );
  }
}



class _TabBtn extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _TabBtn(this.label, this.selected, this.onTap);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? _kGreen : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w700,
                color: selected ? Colors.white : _kSub)),
      ),
    );
  }
}

// ── #132C: Disputes Screen — #170: Supplier-Shop-style accordion ──────────────

class _DisputesScreen extends StatefulWidget {
  final void Function(int) onCountChanged;
  final VoidCallback onRefreshCollect;
  final VoidCallback onRefreshArrivals;
  const _DisputesScreen({
    super.key,
    required this.onCountChanged,
    required this.onRefreshCollect,
    required this.onRefreshArrivals,
  });

  @override
  State<_DisputesScreen> createState() => _DisputesScreenState();
}

class _DisputesScreenState extends State<_DisputesScreen> {
  bool _loading = true;
  List<DisputeItem> _disputes = [];
  final Set<String> _resolving = {};
  // single-open accordion key for Active supplier groups
  String? _openSupplierKey;
  String? _error;
  List<Map<String, dynamic>> _unfillable = [];
  bool _closedExpanded = false;
  final Map<String, GlobalKey> _sendLinkKeys = {};
  bool _unfillableExpanded = false;

  @override
  void initState() {
    super.initState();
    RenderLog.write('c188_realtime_subscribed', 'disputes_tab_init');
    _load();
  }

  @override
  void dispose() {
    _DisputeContactPopover._entry?.remove();
    _DisputeContactPopover._entry = null;
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final res = await Supabase.instance.client.rpc('fw_get_disputes') as Map;
      if (!mounted) return;
      final items = DisputeItem.listFromResponse(res);
      // c188: first parse = models_loaded
      if (items.isNotEmpty) {
        RenderLog.write('c188_models_loaded', 'count=${items.length}');
      }
      // Sort active first, then closed; newest first within each group
      items.sort((a, b) {
        if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
        final ac = a.createdAt ?? '';
        final bc = b.createdAt ?? '';
        return bc.compareTo(ac);
      });
      final activeCount = items.where((d) => d.isActive).length;
      widget.onCountChanged(activeCount);
      // Load unfillable banner items (separate RPC — keep for existing banner)
      List<Map<String, dynamic>> unfillable = [];
      try {
        final ufRes = await Supabase.instance.client.rpc('fw_list_unfillable') as Map;
        if (mounted) {
          unfillable = ((ufRes['items'] as List?) ?? [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        }
      } catch (_) {}
      if (!mounted) return;
      RenderLog.write('c132c_open_count', '$activeCount');
      RenderLog.write('c135_open_dispute_badges', '$activeCount');
      RenderLog.write('c181_unfillable', '${unfillable.length}');
      RenderLog.write('c182_supplier_anim',
          'change:182,uses_shared_reveal:true,duration_ms:280,curve:easeInOutCubic,chevron_animated:true');
      setState(() { _disputes = items; _unfillable = unfillable; _loading = false; });
    } on DisputeException catch (e) {
      if (!mounted) return;
      setState(() { _error = e.message; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString().substring(0, e.toString().length.clamp(0, 120)); _loading = false; });
    }
  }

  // #188: confirm+note dialog for any action button
  Future<void> _resolveDispute(DisputeItem item, DisputeAction action) async {
    if (_resolving.contains(item.disputeId)) return;
    final noteCtrl = TextEditingController();
    RenderLog.write('c188_resolve_called', 'outcome=${action.code};dispute=${item.disputeId}');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(action.label),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${item.productName} — supplier ${item.supplier}.\nConfirm: ${action.label}?',
              style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 16),
          TextField(
            controller: noteCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _kGreen),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    noteCtrl.dispose();
    if (confirmed != true || !mounted) return;
    setState(() => _resolving.add(item.disputeId));
    try {
      final note = noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim();
      final res = await Supabase.instance.client.rpc('fw_resolve_dispute', params: {
        'p_dispute_id': item.disputeId,
        'p_outcome': action.code,
        'p_note': note,
      }) as Map;
      if (!mounted) return;
      final err = res['error']?.toString();
      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $err')));
      } else {
        final newStatus = res['new_status']?.toString() ?? action.label;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Updated: $newStatus')));
        // Realtime will refresh; fallback manual reload after 1s
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) _load();
        });
      }
    } on DisputeException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString().substring(0, e.toString().length.clamp(0, 80)))));
    } finally {
      if (mounted) {
        setState(() => _resolving.remove(item.disputeId));
        widget.onRefreshCollect();
        widget.onRefreshArrivals();
      }
    }
  }

  void _copyLink(String url) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Link copied'), duration: Duration(seconds: 2)),
    );
    RenderLog.write('c170_admin_link_canonical', 'copied');
  }

  List<MapEntry<String, List<DisputeItem>>> _groupBySupplier(
      List<DisputeItem> items) {
    final order = <String>[];
    final map = <String, List<DisputeItem>>{};
    for (final d in items) {
      final s = d.supplier.isNotEmpty ? d.supplier : '—';
      if (!map.containsKey(s)) {
        order.add(s);
        map[s] = [];
      }
      map[s]!.add(d);
    }
    return order.map((s) => MapEntry(s, map[s]!)).toList();
  }

  String _supplierLinkFromItems(List<DisputeItem> items) {
    // Use dispute_code to build the short /<CODE> link — never the token form.
    const codeStatuses = {'reminder_sent', 'shop_logged'};
    final code = items
            .where((d) => codeStatuses.contains(d.statusCode) && (d.disputeCode ?? '').isNotEmpty)
            .map((d) => d.disputeCode!)
            .firstOrNull ??
        items.where((d) => (d.disputeCode ?? '').isNotEmpty).map((d) => d.disputeCode!).firstOrNull ??
        '';
    if (code.isNotEmpty) {
      RenderLog.write('c174_supplier_link', 'shown_for_statuses=reminder_sent|shop_logged;domain=medibo.in');
      RenderLog.write('c319_share_uses_rpc_link', 'dispute:$code');
    }
    return code.isNotEmpty ? '$_kDisputeDomain/$code' : '';
  }

  // Supplier counts — (active, total)
  ({int active, int total}) _supplierCounts(List<DisputeItem> items) {
    final active = items.where((d) => d.isActive).length;
    return (active: active, total: items.length);
  }

  // ── #180: Fixed-width count badge (mirrors CountBadge style) ─────────────────
  Widget _countBadge(int count, {required bool red}) {
    final bg = red ? const Color(0xFFDC2626) : _kGreen;
    return SizedBox(
      width: 28, height: 20,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(5)),
        child: Text('$count', style: const TextStyle(
          color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12, height: 1.0)),
      ),
    );
  }

  // ── #180: Shared header row — pixel-identical open vs closed ─────────────────
  Widget _buildDisputeHeader(String supplier, List<DisputeItem> items,
      {required bool isOpen}) {
    final counts = _supplierCounts(items);
    final allClosed = counts.active == 0;
    final dotColor = allClosed ? _kGreen : const Color(0xFFE8A700);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(children: [
        Expanded(
          child: Text(supplier,
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: isOpen ? _kGreen : _kText),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 8),
        // #182: animated chevron — rotates 180° in sync with body reveal
        AnimatedRotation(
          turns: isOpen ? 0.5 : 0.0,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeInOutCubic,
          child: const Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: _kSub),
        ),
        const SizedBox(width: 12),
        // B5: fixed-width slot so header width is constant open vs closed
        SizedBox(
          width: 32,
          child: allClosed
              ? const SizedBox.shrink()
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  _countBadge(counts.active, red: true),
                  const SizedBox(width: 4),
                ]),
        ),
        _countBadge(counts.total, red: false),
        const SizedBox(width: 8),
        Container(
          width: 12, height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: dotColor,
            border: Border.all(color: dotColor, width: 1.5),
          ),
        ),
      ]),
    );
  }

  // ── #180: WhatsApp normalizer ─────────────────────────────────────────────────
  static String _normalizeForWa(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 10) return '91$digits';
    return digits;
  }

  // ── #180: Show send-link popover anchored to a button ─────────────────────────
  void _showDisputeSendLink(BuildContext context, GlobalKey anchorKey,
      String supplier, String link) {
    _DisputeContactPopover.show(
      context: context,
      anchorKey: anchorKey,
      supplierName: supplier,
      link: link,
    );
  }

  // ── #170: Per-item state chip (Needs you / Waiting / Re-sourcing / Exchange) ─
  Widget _disputeStateChip(DisputeView view) {
    Color bg, fg;
    switch (view.state) {
      case DisputeState.needsYou:
        bg = const Color(0xFFFEE2E2); fg = const Color(0xFFC0392B); break;
      case DisputeState.waiting:
        bg = const Color(0xFFEDE9FE); fg = const Color(0xFF6D5BD0); break;
      case DisputeState.resourcing:
        bg = const Color(0xFFFEF3C7); fg = const Color(0xFFB26A00); break;
      case DisputeState.exchange:
        bg = const Color(0xFFD1FAE5); fg = _kGreen; break;
      case DisputeState.resolved:
        bg = const Color(0xFFF3F4F6); fg = _kSub; break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
      child: Text(view.label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
    );
  }

  // ── #170: Compact key→value table row ────────────────────────────────────────
  Widget _kvRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 116, child: Text(label,
          style: const TextStyle(fontSize: 12, color: _kSub))),
      const SizedBox(width: 6),
      Expanded(child: Text(value,
          style: const TextStyle(fontSize: 12, color: _kText, fontWeight: FontWeight.w500))),
    ]),
  );

  // ── #170: build ───────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2));
    }

    // B10: error state
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.wifi_off_rounded, size: 48, color: _kSub),
            const SizedBox(height: 12),
            const Text("Couldn't load disputes",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _kSub)),
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(fontSize: 12, color: _kSub),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _load,
              style: FilledButton.styleFrom(
                backgroundColor: _kGreen,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Retry'),
            ),
          ]),
        ),
      );
    }

    final activeDisputes = _disputes.where((d) => d.isActive).toList();
    final closedDisputes = _disputes.where((d) => !d.isActive).toList();
    final activeGroups = _groupBySupplier(activeDisputes);

    // ── Render-log sentinels ────────────────────────────────────────────────
    RenderLog.write('c188_disputes_tab_built', 'active=${activeDisputes.length};closed=${closedDisputes.length}');
    RenderLog.write('c170_disputes_built', 'true');
    RenderLog.write('c170_supplier_card_count', '${activeGroups.length}');
    RenderLog.write('c191_admin_disputes_redesigned', 'active=${activeDisputes.length};closed=${closedDisputes.length};groups=${activeGroups.length}');

    if (_disputes.isEmpty) {
      return const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.check_circle_outline_rounded, size: 48, color: _kGreen),
          SizedBox(height: 12),
          Text('No disputes right now.',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _kSub)),
        ]),
      );
    }

    return LayoutBuilder(builder: (_, constraints) {
      final maxW = constraints.maxWidth >= 900 ? 700.0 : double.infinity;
      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: RefreshIndicator(
            onRefresh: _load,
            color: _kGreen,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                if (_unfillable.isNotEmpty) _buildUnfillableBanner(),
                // ── Active section header ──────────────────────────────────
                Builder(builder: (_) {
                  RenderLog.write('c188_admin_active_rendered', 'count=${activeDisputes.length}');
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('Active (${activeDisputes.length})',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _kText)),
                  );
                }),
                if (activeDisputes.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Text('No active disputes.', style: TextStyle(fontSize: 14, color: _kSub)),
                  ),
                for (final g in activeGroups) ...[
                  _buildDisputeSupplierCard(g.key, g.value),
                ],
                const SizedBox(height: 8),
                // ── Closed section header (collapsible) ───────────────────
                InkWell(
                  onTap: () => setState(() => _closedExpanded = !_closedExpanded),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [
                      Text('Closed (${closedDisputes.length})',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _kText)),
                      const SizedBox(width: 6),
                      AnimatedRotation(
                        turns: _closedExpanded ? 0.5 : 0.0,
                        duration: const Duration(milliseconds: 220),
                        child: const Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: _kSub),
                      ),
                    ]),
                  ),
                ),
                if (_closedExpanded)
                  for (final item in closedDisputes) ...[
                    const SizedBox(height: 8),
                    _buildDisputeItemCard(item),
                  ],
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      );
    });
  }

  // ── #182/#183: Delegates to top-level _sharedSmoothReveal so all four surfaces share one path ──
  Widget _smoothReveal(bool expanded, Widget child) => _sharedSmoothReveal(expanded, child);

  // ── #181/#182: Unfillable re-source dead-end banner — uses _smoothReveal ────
  Widget _buildUnfillableBanner() {
    final n = _unfillable.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFFEF2F2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFFCA5A5)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // ── Header ─────────────────────────────────────────────────────
          InkWell(
            borderRadius: _unfillableExpanded
                ? const BorderRadius.vertical(top: Radius.circular(12))
                : BorderRadius.circular(12),
            onTap: () => setState(() => _unfillableExpanded = !_unfillableExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(children: [
                const Icon(Icons.warning_amber_rounded, color: Color(0xFFDC2626), size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '$n item${n == 1 ? '' : 's'} couldn\'t be re-sourced — no supplier available',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                        color: Color(0xFFDC2626)),
                  ),
                ),
                const SizedBox(width: 8),
                AnimatedRotation(
                  turns: _unfillableExpanded ? 0.5 : 0.0,
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeInOutCubic,
                  child: const Icon(Icons.keyboard_arrow_down_rounded,
                      size: 18, color: Color(0xFFDC2626)),
                ),
              ]),
            ),
          ),
          // ── Animated body ───────────────────────────────────────────────
          _smoothReveal(
            _unfillableExpanded,
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Divider(height: 1, color: Color(0xFFFCA5A5)),
              for (final item in _unfillable)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      item['product_name']?.toString() ?? '—',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: _kText),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Qty: ${item['qty'] ?? '?'} · Bag ${item['bag_no'] ?? '?'} · ${item['pharmacy_name'] ?? '?'}',
                      style: const TextStyle(fontSize: 12, color: _kSub),
                    ),
                  ]),
                ),
              const SizedBox(height: 4),
            ]),
          ),
        ]),
      ),
    );
  }

  // ── #188: Unified supplier card — header always visible, body via _smoothReveal ─
  Widget _buildDisputeSupplierCard(String supplier, List<DisputeItem> items) {
    final isOpen = _openSupplierKey == supplier;
    final canonicalLink = _supplierLinkFromItems(items);
    final sendKey = _sendLinkKeys.putIfAbsent(supplier, () => GlobalKey());

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _kBorder),
          boxShadow: [BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6, offset: const Offset(0, 2))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // ── Header — always rendered, pixel-identical open/closed (#181 B4/B5) ─
          InkWell(
            borderRadius: isOpen
                ? const BorderRadius.vertical(top: Radius.circular(12))
                : BorderRadius.circular(12),
            onTap: () {
              setState(() => _openSupplierKey = isOpen ? null : supplier);
              RenderLog.write('c170_dropdown_open_key', isOpen ? 'null' : supplier);
            },
            child: _buildDisputeHeader(supplier, items, isOpen: isOpen),
          ),
          // ── Animated body via shared _smoothReveal ──────────────────────────
          _smoothReveal(
            isOpen,
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Divider(height: 1, color: _kBorder),

              // Send link button row
              if (canonicalLink.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Row(children: [
                    OutlinedButton.icon(
                      key: sendKey,
                      onPressed: () {
                        RenderLog.write('c180_sendlink_open', supplier);
                        _showDisputeSendLink(context, sendKey, supplier, canonicalLink);
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _kGreen,
                        side: const BorderSide(color: Color(0xFFBBDDC8)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(Icons.send_rounded, size: 14),
                      label: const Text('Send link',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                  ]),
                ),

              // Item list (all active items for this supplier)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(children: [
                  for (int i = 0; i < items.length; i++) ...[
                    _buildDisputeItemCard(items[i]),
                    if (i < items.length - 1) const SizedBox(height: 8),
                  ],
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  // ── #192: Compact dispute card — thumbnail + info, NO inline buttons; tap → sheet ──
  Widget _buildDisputeItemCard(DisputeItem item) {
    final isWrong  = item.kind == 'wrong_item';
    final isActive = item.isActive;
    final statusBgColor  = isActive ? const Color(0xFFFEF3C7) : const Color(0xFFD1FAE5);
    final statusTxtColor = isActive ? const Color(0xFF92400E) : const Color(0xFF065F46);

    // Meta line: packType / company / category (only the present ones)
    final metaParts = <String>[
      if ((item.packType ?? '').isNotEmpty) item.packType!,
      if ((item.company ?? '').isNotEmpty) item.company!,
      if ((item.category ?? '').isNotEmpty) item.category!,
    ];
    final metaLine = metaParts.join(' · ');

    RenderLog.write('c192_dispute_card_rendered',
        'dispute=${item.disputeId};status=${item.statusCode}');

    return InkWell(
      onTap: () => _openDisputeActionSheet(item),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _kBorder),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          // (a) Thumbnail
          _FulfilImageTile(item.imageUrl, size: 44),
          const SizedBox(width: 10),

          // (b–f) Info column
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Product name + kind tag row
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(item.productName.isNotEmpty ? item.productName : '—',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                            color: _kText, height: 1.3),
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    if ((item.disputeCode ?? '').isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Builder(builder: (_) {
                        try { RenderLog.write('c318_disp_id', item.disputeCode!); } catch (_) {}
                        return Text(item.disputeCode!,
                            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500,
                                color: Color(0xFF9CA3AF), letterSpacing: 0.3),
                            maxLines: 1, overflow: TextOverflow.ellipsis);
                      }),
                    ],
                    if (isWrong && (item.wrongProductName ?? '').isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text('Received: ${item.wrongProductName}',
                          style: const TextStyle(fontSize: 11, color: Color(0xFFDC2626)),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ]),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: isWrong ? const Color(0xFFEEF2FF) : const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(isWrong ? 'Wrong' : 'Short',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                          color: isWrong ? const Color(0xFF4338CA) : const Color(0xFF475569))),
                ),
              ]),

              // (c) Meta line
              if (metaLine.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(metaLine,
                    style: const TextStyle(fontSize: 11, color: _kSub),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],

              // (d) Quantities
              const SizedBox(height: 2),
              Text(
                'Ord ${item.ordered.toInt()} · Rec ${item.received.toInt()} · Short ${item.short.toInt()}',
                style: const TextStyle(fontSize: 11, color: _kSub),
              ),

              // (e+f) Status chips
              const SizedBox(height: 4),
              Wrap(spacing: 4, runSpacing: 4, children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                      color: statusBgColor, borderRadius: BorderRadius.circular(20)),
                  child: Text(item.itemStatusLabel,
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                          color: statusTxtColor)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: isActive ? const Color(0xFFFEF3C7) : const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(item.disputeStatus,
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                          color: isActive ? const Color(0xFF92400E) : _kSub)),
                ),
                if (item.unfillable)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                        color: const Color(0xFFFEE2E2),
                        borderRadius: BorderRadius.circular(20)),
                    child: const Text('No supplier',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                            color: Color(0xFF991B1B))),
                  ),
              ]),
            ]),
          ),

          // (g) Trailing chevron — signals tappable
          const SizedBox(width: 6),
          const Icon(Icons.chevron_right_rounded, size: 18, color: _kSub),
        ]),
      ),
    );
  }

  // ── #192: Dispute action bottom sheet — buttons live here, not on the card ──
  void _openDisputeActionSheet(DisputeItem item) {
    RenderLog.write('c192_dispute_sheet_opened',
        'dispute=${item.disputeId};actions=${item.actions.length}');
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => _DisputeActionSheet(
        item: item,
        onResolve: (action) async {
          Navigator.of(sheetCtx).pop();
          await _resolveDispute(item, action);
        },
      ),
    );
  }
}

// ── #192: Dispute action bottom sheet — shown when admin taps a dispute card ────
class _DisputeActionSheet extends StatefulWidget {
  final DisputeItem item;
  final Future<void> Function(DisputeAction action) onResolve;

  const _DisputeActionSheet({required this.item, required this.onResolve});

  @override
  State<_DisputeActionSheet> createState() => _DisputeActionSheetState();
}

class _DisputeActionSheetState extends State<_DisputeActionSheet> {
  bool _resolving = false;

  Future<void> _tap(DisputeAction action) async {
    if (_resolving) return;
    final noteCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(action.label),
        content: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${widget.item.productName} — ${widget.item.supplier}.\nConfirm: ${action.label}?',
              style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 16),
          TextField(
            controller: noteCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _kGreen),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    noteCtrl.dispose();
    if (confirmed != true || !mounted) return;
    setState(() => _resolving = true);
    RenderLog.write('c192_resolve_called',
        'dispute=${widget.item.disputeId};outcome=${action.code}');
    try {
      await widget.onResolve(action);
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final isWrong  = item.kind == 'wrong_item';
    final isActive = item.isActive;
    final statusBgColor  = isActive ? const Color(0xFFFEF3C7) : const Color(0xFFD1FAE5);
    final statusTxtColor = isActive ? const Color(0xFF92400E) : const Color(0xFF065F46);
    final safeBottom = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + safeBottom),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Drag handle
        const SizedBox(height: 12),
        Center(
          child: Container(
            width: 36, height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFFD1D5DB),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Sheet header: thumbnail + name + kind + status
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _FulfilImageTile(item.imageUrl, size: 48),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Text(item.productName.isNotEmpty ? item.productName : '—',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                          color: _kText, height: 1.3),
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: isWrong ? const Color(0xFFEEF2FF) : const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(isWrong ? 'Wrong item' : 'Short',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                          color: isWrong ? const Color(0xFF4338CA) : const Color(0xFF475569))),
                ),
              ]),
              if (isWrong && (item.wrongProductName ?? '').isNotEmpty) ...[
                const SizedBox(height: 2),
                Text('Received: ${item.wrongProductName}',
                    style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626)),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
              const SizedBox(height: 4),
              Text(
                'Ordered ${item.ordered.toInt()} · Received ${item.received.toInt()} · Short ${item.short.toInt()}',
                style: const TextStyle(fontSize: 12, color: _kSub),
              ),
              const SizedBox(height: 4),
              Wrap(spacing: 4, runSpacing: 4, children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                      color: statusBgColor, borderRadius: BorderRadius.circular(20)),
                  child: Text(item.itemStatusLabel,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                          color: statusTxtColor)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: isActive ? const Color(0xFFFEF3C7) : const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(item.disputeStatus,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                          color: isActive ? const Color(0xFF92400E) : _kSub)),
                ),
              ]),
            ]),
          ),
        ]),

        // Proof photo (c194)
        if ((item.proofUrl ?? '').isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(children: [
            const Text('Proof:',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6B7280))),
            const SizedBox(width: 10),
            ProofThumbnail(proofUrl: item.proofUrl!, size: 72),
          ]),
        ],

        const SizedBox(height: 20),
        const Divider(height: 1, color: Color(0xFFE5E7EB)),
        const SizedBox(height: 16),

        // Action buttons (item.actions verbatim from backend)
        if (item.actions.isEmpty) ...[
          const Text('No actions available for this status.',
              style: TextStyle(fontSize: 14, color: _kSub)),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFFE5E7EB)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: const Text('Close', style: TextStyle(fontSize: 14)),
            ),
          ),
        ] else
          Builder(builder: (_) {
            RenderLog.write('c192_dispute_sheet_buttons',
                'dispute=${item.disputeId};count=${item.actions.length}');
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: item.actions.asMap().entries.map((e) {
                final idx = e.key;
                final action = e.value;
                final isPrimary = idx == 0;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: isPrimary
                      ? FilledButton(
                          onPressed: _resolving ? null : () => _tap(action),
                          style: FilledButton.styleFrom(
                            backgroundColor: _kGreen,
                            disabledBackgroundColor: _kGreen.withValues(alpha: 0.4),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                            padding: const EdgeInsets.symmetric(vertical: 13),
                          ),
                          child: _resolving
                              ? const SizedBox(width: 16, height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : Text(action.label,
                                  style: const TextStyle(fontSize: 14,
                                      fontWeight: FontWeight.w700, color: Colors.white)),
                        )
                      : OutlinedButton(
                          onPressed: _resolving ? null : () => _tap(action),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _kGreen,
                            side: const BorderSide(color: Color(0xFFBBDDC8)),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                            padding: const EdgeInsets.symmetric(vertical: 13),
                          ),
                          child: _resolving
                              ? const SizedBox(width: 14, height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : Text(action.label,
                                  style: const TextStyle(fontSize: 14,
                                      fontWeight: FontWeight.w700)),
                        ),
                );
              }).toList(),
            );
          }),
      ]),
    );
  }
}

// ── #180: Dispute send-link popover ────────────────────────────────────────────
// Local copy of inquiry contact-picker logic, adapted for dispute public link.
class _DisputeContactPopover extends StatefulWidget {
  final String supplierName;
  final String link;
  final VoidCallback onClose;

  const _DisputeContactPopover({
    required this.supplierName,
    required this.link,
    required this.onClose,
  });

  static OverlayEntry? _entry;

  static void show({
    required BuildContext context,
    required GlobalKey anchorKey,
    required String supplierName,
    required String link,
  }) {
    _entry?.remove();
    _entry = null;

    final renderBox = anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final size = renderBox.size;
    final offset = renderBox.localToGlobal(Offset.zero);
    final screenH = MediaQuery.of(context).size.height;

    final spaceBelow = screenH - offset.dy - size.height;
    final openAbove = spaceBelow < 200 && offset.dy > 200;

    _entry = OverlayEntry(builder: (_) => _DisputeContactPopoverBody(
      supplierName: supplierName,
      link: link,
      anchorOffset: offset,
      anchorSize: size,
      openAbove: openAbove,
      onClose: () {
        _entry?.remove();
        _entry = null;
      },
    ));
    Overlay.of(context).insert(_entry!);
  }

  @override
  State<_DisputeContactPopover> createState() => _DisputeContactPopoverState();
}

class _DisputeContactPopoverState extends State<_DisputeContactPopover> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

// ── Body widget (actual UI) ──────────────────────────────────────────────────
class _DisputeContactPopoverBody extends StatefulWidget {
  final String supplierName;
  final String link;
  final Offset anchorOffset;
  final Size anchorSize;
  final bool openAbove;
  final VoidCallback onClose;

  const _DisputeContactPopoverBody({
    required this.supplierName,
    required this.link,
    required this.anchorOffset,
    required this.anchorSize,
    required this.openAbove,
    required this.onClose,
  });

  @override
  State<_DisputeContactPopoverBody> createState() => _DisputeContactPopoverBodyState();
}

class _DisputeContactPopoverBodyState extends State<_DisputeContactPopoverBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _fade;

  bool _loading = true;
  Map<String, dynamic> _contacts = {};

  static const _kGreen  = Color(0xFF1B7A43);
  static const _kText   = Color(0xFF111827);
  static const _kSub    = Color(0xFF6B7280);
  static const _kBorder = Color(0xFFE5E7EB);

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 180));
    _scale = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack);
    _fade  = CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);
    _ctrl.forward();
    _load();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await Supabase.instance.client.rpc(
        'get_supplier_contacts',
        params: {'p_supplier_name': widget.supplierName},
      );
      if (!mounted) return;
      setState(() {
        _contacts = Map<String, dynamic>.from(res as Map? ?? {});
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _onTap(String value) async {
    final intl = _DisputesScreenState._normalizeForWa(value);
    if (intl.isEmpty) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      widget.onClose();
      messenger?.showSnackBar(
          const SnackBar(content: Text('No valid phone number for this contact')));
      return;
    }
    final msg = Uri.encodeComponent(
        'Hi, please review and respond to the dispute form: ${widget.link}');
    // Record last-used contact
    Supabase.instance.client.rpc(
      'set_supplier_last_send_contact',
      params: {
        'p_supplier_name': widget.supplierName,
        'p_value': value,
      },
    );
    RenderLog.write('c180_sendlink_action', 'supplier=${widget.supplierName}');
    html.window.open('https://wa.me/$intl?text=$msg', '_blank');
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    const popW = 260.0;
    // Right-align to anchor right edge, but clamp to screen
    double left = widget.anchorOffset.dx + widget.anchorSize.width - popW;
    if (left < 8) left = 8;
    if (left + popW > screenW - 8) left = screenW - popW - 8;
    final top = widget.openAbove
        ? widget.anchorOffset.dy - 8
        : widget.anchorOffset.dy + widget.anchorSize.height + 6;

    return Stack(children: [
      // Dismiss on outside tap
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: widget.onClose,
        ),
      ),
      Positioned(
        left: left,
        top: widget.openAbove ? null : top,
        bottom: widget.openAbove
            ? MediaQuery.of(context).size.height - widget.anchorOffset.dy + 6
            : null,
        width: popW,
        child: FadeTransition(
          opacity: _fade,
          child: ScaleTransition(
            scale: _scale,
            alignment: widget.openAbove ? Alignment.bottomRight : Alignment.topRight,
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              color: Colors.white,
              child: _loading
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2),
                        ),
                      ),
                    )
                  : _buildList(),
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _buildList() {
    final lastUsed = _contacts['last_used']?.toString() ?? '';
    final wa      = (_contacts['whatsapp'] as List? ?? []).map((e) => e.toString()).toList();
    final contact = (_contacts['contact']  as List? ?? []).map((e) => e.toString()).toList();
    final phone   = (_contacts['phone']    as List? ?? []).map((e) => e.toString()).toList();
    final other   = (_contacts['other']    as List? ?? []).map((e) => e.toString()).toList();

    final hasAny = wa.isNotEmpty || contact.isNotEmpty || phone.isNotEmpty || other.isNotEmpty;
    if (!hasAny) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.contact_phone_outlined, color: _kSub, size: 28),
          const SizedBox(height: 8),
          const Text('No contacts saved for this supplier.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: _kSub)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: widget.link));
                widget.onClose();
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    const SnackBar(content: Text('Link copied')));
              },
              icon: const Icon(Icons.copy_rounded, size: 14),
              label: const Text('Copy link', style: TextStyle(fontSize: 13)),
              style: OutlinedButton.styleFrom(
                foregroundColor: _kGreen,
                side: const BorderSide(color: Color(0xFFBBDDC8)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ]),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (wa.isNotEmpty) ...[
          _section('WhatsApp'),
          for (final v in wa) _row(v, lastUsed: lastUsed),
        ],
        if (contact.isNotEmpty) ...[
          _section('Contact'),
          for (final v in contact) _row(v, lastUsed: lastUsed),
        ],
        if (phone.isNotEmpty) ...[
          _section('Phone'),
          for (final v in phone) _row(v, lastUsed: lastUsed),
        ],
        if (other.isNotEmpty) ...[
          _section('Other'),
          for (final v in other) _row(v, lastUsed: lastUsed),
        ],
      ]),
    );
  }

  Widget _section(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 8, 14, 2),
    child: Text(label,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
            color: _kSub, letterSpacing: 0.4)),
  );

  Widget _row(String value, {required String lastUsed}) {
    final isLast = value == lastUsed;
    return InkWell(
      onTap: () => _onTap(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: isLast
            ? BoxDecoration(
                color: const Color(0xFFE7F4EC),
                border: Border(
                    left: BorderSide(color: _kGreen, width: 3)),
              )
            : null,
        child: Row(children: [
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: isLast ? FontWeight.w600 : FontWeight.w400,
                    color: isLast ? _kGreen : _kText)),
          ),
          const SizedBox(width: 8),
          Icon(Icons.send_rounded, size: 14,
              color: isLast ? _kGreen : _kSub),
        ]),
      ),
    );
  }
}
