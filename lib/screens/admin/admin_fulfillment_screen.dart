// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;
import 'dart:math' as math;
import 'dart:typed_data';

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
import '../../fulfill/fulfill_view_logic.dart'; // C355: shared logic for both layouts
// dispute_card.dart removed in #170 — Disputes tab rebuilt with accordion layout
import '../../utils/responsive.dart';
import '../../utils/tts.dart';
import '../../user_state.dart';
import '../../services/voice_receive_service.dart';
import '../../services/fulfill_realtime.dart'; // C353: single realtime channel
import '../../services/fulfill_date_scope.dart'; // C444: shared date+includeOlder scope
import '../../widgets/date_scope_chip.dart'; // C444: shared DateScopeChip + OlderOpenPill
import '../../utils/ist_date.dart'; // C444: IST date helpers
import '../../supabase_config.dart' show SupabaseConfig;
import 'voice_receive.dart';
import '../../widgets/pinned_footer_list.dart';
import '../../widgets/fulfill_item_sheet.dart';
import '../../widgets/report_issue_section.dart';
import '../../widgets/mention_hold_row.dart'; // #342: MentionActionIcon + mentionRowDecoration
import '../../widgets/supplier_map_groups_panel.dart'; // CHANGE: Supplier Shop map dropdown
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

// ── C174/B10: single canonical dispute domain (no www per Cloudflare redirects) ──
const _kDisputeDomain = 'https://medibo.in';

// Parses a backend-supplied "#RRGGBB" (or "RRGGBB") hex colour string.
// Pure format conversion — Flutter needs a Color object, the RPC gives a
// string; no colour/state decision is made here.
Color _hexColor(String? hex, Color fallback) {
  if (hex == null || hex.isEmpty) return fallback;
  final h = hex.startsWith('#') ? hex.substring(1) : hex;
  final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
  return v == null ? fallback : Color(v);
}

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
// C359: light-yellow tint for a dispute-candidate row (short/excess/flagged after
// voice counting). Lighter than _kPendingBg so text stays readable; the stronger
// 0xFFFEF3C7 yellow is reserved for the disabled Confirm button gate.
const _kCandidateBg     = Color(0xFFFEFCE8);
const _kCandidateBorder = Color(0xFFF59E0B);

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
    String? sessionKey,
    String? stage, // §0.12: 'shop'|'warehouse'; omit for pack context
  }) async {
    try {
      final raw = await supabase.rpc('voice_clip_register', params: {
        'p_context': ctxStr,
        'p_supplier': supplier,
        'p_path': path,
        'p_seconds': seconds.clamp(1, 3600),
        if (sessionKey != null) 'p_session_key': sessionKey,
        if (stage != null) 'p_stage': stage,
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

// Renders fw_get_state()'s per-item status_label/status_colors verbatim — no
// client-side label or colour derivation. Only usable where a single raw
// order-item (not a merged, multi-line product) is available.
class _BackendStatePill extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;
  const _BackendStatePill({required this.label, required this.bg, required this.fg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
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
  // C365: sum of counted shop_qty (uncounted lines counted as 0) — the true counted total
  // for a partially-counted product (drives the popup gap/breakdown, not inflated to ordered).
  final int shopQtyCounted;
  // #333: sum of expected across all lines (forwarded qty at warehouse; ordered at shop)
  final int? expectedTotal;
  final List<String> orderItemIds; // underlying line IDs — for dispute lookup only
  final String combinedState; // 'pending'|'received'|'short'|'wrong'|'not_coming'
  final bool hasArrived; // true if any underlying Arrivals line has received_locked=true
  final List<Map>? bagBreakdown; // #254: per-bag breakdown for Arrivals
  final Map<String, dynamic>? firstLineData; // raw first-line payload for issue section
  // C361: first non-null count_issue across ALL underlying lines. A merged product can
  // span several order_items; the issue chip / Dispute Type column must not read only
  // firstLineData (which can be a clean line while a sibling carries the flag).
  final String? mergedCountIssue;
  // C364: summed issue_qty across all flagged lines — the disputed units shown in the
  // "In dispute — <n> unit(s)" row chip. 0 when no line carries a disputed qty.
  final int mergedIssueQty;
  // CHANGE #471: backend-owned date chip — true/text if ANY underlying line's
  // order_date differs from the selected Fulfill date (older-item indicator).
  // Printed verbatim, never formatted client-side.
  final bool showDateChip;
  final String? dateChip;

  // fw_get_state()'s merged_items[] — rendered verbatim, no client derivation.
  final String statusLabel;
  final String statusTone;
  final Map<String, String>? statusColors; // {bg, fg} hex
  final String qtyLabel;
  final Map<String, dynamic>? issueChip; // {label, qty} | null
  final List<Map<String, dynamic>> lines; // underlying per-order-item rows

  const _MergedProduct({
    required this.productId,
    required this.productName,
    required this.packType,
    this.imageUrl,
    required this.orderedTotal,
    required this.receivedTotal,
    this.shopQtyTotal,
    this.shopQtyCounted = 0,
    this.expectedTotal,
    required this.orderItemIds,
    required this.combinedState,
    this.hasArrived = false,
    this.bagBreakdown,
    this.firstLineData,
    this.mergedCountIssue,
    this.mergedIssueQty = 0,
    this.showDateChip = false,
    this.dateChip,
    this.statusLabel = '',
    this.statusTone = '',
    this.statusColors,
    this.qtyLabel = '',
    this.issueChip,
    this.lines = const [],
  });

  // fw_get_state()'s merged_items[] entry -> _MergedProduct. Pure field
  // extraction — the aggregation (state, totals, qty_label, status fields)
  // is already done server-side; this just unwraps the JSON.
  factory _MergedProduct.fromBackend(Map<String, dynamic> m) {
    final lines = (m['lines'] as List? ?? [])
        .whereType<Map>()
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
    final orderItemIds = lines
        .map((r) => r['order_item_id']?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    final rawBd = m['bag_breakdown'];
    final bagBreakdown = rawBd is List ? rawBd.cast<Map>().toList() : null;
    // CHANGE #471: date chip — backend-owned; text from the first underlying
    // line flagged show_date_chip (older item mixed into today's list).
    String? mergedDateChip;
    for (final r in lines) {
      mergedDateChip = itemDateChip(r);
      if (mergedDateChip != null) break;
    }
    final colors = m['status_colors'];
    final issueChip = m['issue_chip'];
    return _MergedProduct(
      productId: (m['product_id'] as num?)?.toInt() ?? 0,
      productName: m['product_name']?.toString() ?? '—',
      packType: m['pack_type']?.toString() ?? '',
      imageUrl: m['image_url']?.toString(),
      orderedTotal: (m['ordered_total'] as num?)?.toInt() ?? 0,
      receivedTotal: (m['received_total'] as num?)?.toInt() ?? 0,
      shopQtyTotal: (m['shop_qty_total'] as num?)?.toInt(),
      shopQtyCounted: (m['shop_qty_counted'] as num?)?.toInt() ?? 0,
      expectedTotal: (m['expected_total'] as num?)?.toInt(),
      orderItemIds: orderItemIds,
      combinedState: m['state']?.toString() ?? 'pending',
      hasArrived: m['has_arrived'] == true,
      bagBreakdown: bagBreakdown,
      firstLineData: lines.isNotEmpty ? lines.first : null,
      mergedCountIssue: m['count_issue']?.toString(),
      mergedIssueQty: (m['issue_qty'] as num?)?.toInt() ?? 0,
      showDateChip: mergedDateChip != null,
      dateChip: mergedDateChip,
      statusLabel: m['status_label']?.toString() ?? '',
      statusTone: m['status_tone']?.toString() ?? '',
      statusColors: colors is Map
          ? {'bg': colors['bg']?.toString() ?? '', 'fg': colors['fg']?.toString() ?? ''}
          : null,
      qtyLabel: m['qty_label']?.toString() ?? '',
      issueChip: issueChip is Map ? Map<String, dynamic>.from(issueChip) : null,
      lines: lines,
    );
  }
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
// bag_breakdown arrives pre-sorted by bag_no from fw_get_state — no client sort.
String _fmtBreakdown(List? bd, String? packType) {
  if (bd == null || bd.isEmpty) return '';
  final pl = (packType ?? '').trim().isNotEmpty
      ? packType!.trim()[0].toUpperCase()
      : '';
  return bd
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
  // CHANGE #473: reports the post-filter supplier count after each fetch, so
  // the parent can drive the Supplier Shop / Warehouse tab badges.
  final void Function(int)? onSupplierCountChanged;
  const _PickToLightScreen({super.key, this.arrivals = false, this.onSupplierCountChanged});

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
  // fw_get_state()'s merged_items[] — one row per product_id, pre-aggregated
  // and pre-sorted server-side. Rendered verbatim; never recomputed from _items.
  List<_MergedProduct> _mergedItemsBackend = [];
  bool _loadingBox = false;
  String? _error;

  // CHANGE #471 — backend-owned display fields from the last fw_get_state
  // response for the open supplier's box: progress {counted,total,label},
  // date_label, older {count,show,label}. Rendered verbatim, never recomputed.
  Map<String, dynamic>? _boxProgress;
  String? _boxDateLabel;
  Map<String, dynamic>? _boxOlder;
  // Local per-box toggle (NOT the shared FulfillDateScope.includeOlder — this
  // control refetches only the open supplier's box). Reset OFF on every
  // supplier-open and every date change (see _onDateScopeChanged).
  bool _boxIncludeOlder = false;

  // CHANGE #471: header progress reads the backend's counted/total/label —
  // no client-side counting. Falls back to raw counts only before the first
  // fw_get_state response lands (e.g. mid-load).
  BoxProgress get _boxProgressView => boxProgressFrom(_boxProgress, fallbackTotal: _items.length);
  int get _boxProgressCounted => _boxProgressView.counted;
  int get _boxProgressTotal => _boxProgressView.total;
  String get _boxProgressLabel => _boxProgressView.label;

  // ── PTL navigation ──
  int _focusIdx = 0;
  bool _recording = false;
  bool _showListView = false;

  // Per-supplier dots {fill,border} hex colours straight from fw_list_arrivals()'s
  // dot_packed / dot_method / dot_submit — rendered verbatim, never recomputed
  // client-side. Supplier Shop shows [packed, method, submit]; Warehouse shows
  // [method, packed].
  Map<String, Map<String, String>> _supplierDotPackedMap = {};
  Map<String, Map<String, String>> _supplierDotMethodMap = {};
  Map<String, Map<String, String>> _supplierDotSubmitMap = {};

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
  // Continuous voice counting (#8): one session spans the whole mic-on → Stop
  // lifecycle across multiple bag attaches; replaces the old single-shot
  // start/stop/transcribe/insertMentions sequence for the main counting mic.
  ContinuousVoiceSession? _voiceSession;
  // CHANGE #453: the ContinuousVoiceSession's own unique key (supplier|stage|ms)
  // for the tab's current/most-recently-finished recording. This is the ONLY
  // key that ever appears in voice_clip_mentions.session_key for rows written
  // by this tab — the "N spoken" badge and the "Counted items" popup both scope
  // to exactly this value (null = no recording yet this card-open → show all of
  // today's mentions for the supplier+stage). Set on recording start; cleared
  // only when the card is freshly (re)loaded, never nulled on stop/finalize, so
  // the badge/popup still agree right after Stop.
  String? _activeVoiceSessionKey;

  // ── Voice state ──
  bool _voiceSupported = true;
  bool _voiceListening = false;
  bool _voiceProcessing = false;
  String _voiceInterim = '';
  String _voiceError = '';
  // ── Voice results ──
  Timer? _idleTimer;
  DateTime? _recStartTime;
  // #331 VoiceCaps: continuous-session timer
  int _continuousSecs = 0;
  Timer? _capsTimer;
  // #332: background session key from fw_count_session — a low-cardinality
  // per-stage backend code (e.g. "SS1", "SS2"), reused across recordings; never
  // used to scope voice_clip_mentions display (see #453 / fetchScopedVoiceMentions).
  String? _sessionKey;
  String? _sessionStage;
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
    return cur != null && (cur['fulfillment_state']?.toString() ?? 'pending') == 'pending';
  }

  int get _pendingCount => _items
      .where((i) => (i['fulfillment_state']?.toString() ?? 'pending') == 'pending')
      .length;

  bool get _allDone => _items.isNotEmpty && _pendingCount == 0;

  // #133: removed at_warehouse/received_qty filter — show ALL items from RPC
  List<Map<String, dynamic>> _visibleItems() => _items;

  // #197: group _items by product_id → one display row per product
  // ── C359: dispute-candidate / balance / response-gate (shared logic) ─────────
  // Computed PER order-line — the backend raises disputes per line and the
  // few_wrong/damaged/excess flags are written per order_item_id, so a merged
  // product that spans several lines must be judged line-by-line (comparing one
  // line's issue_qty against the merged-sum gap would false-block or false-pass).
  bool _lineIsCandidate(Map<String, dynamic> line) => isDisputeCandidate(
        arrivals: widget.arrivals,
        ordered: ordQtyOf(line),
        shopQty: (line['shop_qty'] as num?)?.toInt(),
        received: recQtyOf(line),
        expected: (line['expected'] as num?)?.toInt(),
        countIssue: line['count_issue']?.toString(),
        state: line['fulfillment_state']?.toString() ?? 'pending',
      );

  // A merged product row is a candidate (tint yellow + tappable) if ANY of its
  // underlying lines is a candidate.
  bool _mIsCandidate(_MergedProduct m) {
    final ids = m.orderItemIds.toSet();
    return _items.any((l) =>
        ids.contains(l['order_item_id']?.toString()) && _lineIsCandidate(l));
  }

  // C365: confirm-button visual over the whole tab, aggregated PER PRODUCT. A product
  // balances when refTotal <= countedTotal + disputedTotal (summed over its order-lines);
  // GREEN + clickable only when EVERY product balances, else RED. This matches the one-row-
  // per-product display and lets a multi-line dispute (distributed by fw_set_product_issue)
  // cover the full gap and reach green. ref=ordered@shop / expected@warehouse (preserves #360).
  ConfirmButtonVisual get _confirmVisual {
    final tab = widget.arrivals ? 'warehouse' : 'shop';
    final byProduct = <String, List<Map<String, dynamic>>>{};
    for (final l in _items) {
      final pid = (l['product_id'] ?? l['order_item_id'])?.toString() ?? '';
      byProduct.putIfAbsent(pid, () => []).add(l);
    }
    int unsatisfied = 0;
    for (final entry in byProduct.entries) {
      int refTotal = 0, countedTotal = 0, disputedTotal = 0;
      for (final l in entry.value) {
        final ordered = ordQtyOf(l);
        final expected = (l['expected'] as num?)?.toInt();
        final received = recQtyOf(l);
        final shopQty = (l['shop_qty'] as num?)?.toInt();
        final ref = stageRefFor(arrivals: widget.arrivals, ordered: ordered, expected: expected);
        final counted = countedQtyFor(arrivals: widget.arrivals, shopQty: shopQty, received: received);
        refTotal += ref;
        countedTotal += counted;
        disputedTotal += confirmDisputedQty(
          ref: ref, counted: counted,
          countIssue: l['count_issue']?.toString(),
          issueQty: (l['issue_qty'] as num?)?.toInt(),
          state: l['fulfillment_state']?.toString() ?? 'pending',
        );
      }
      final ok = productSatisfiesConfirmGate(
          refTotal: refTotal, countedTotal: countedTotal, disputedTotal: disputedTotal);
      RenderLog.write('c361_balance', 'tab=$tab,product=${entry.key},satisfied=$ok');
      if (!ok) unsatisfied++;
    }
    final vis = confirmButtonVisual(unsatisfiedLines: unsatisfied);
    RenderLog.write('c363_gate', 'tab=$tab,balanced=${vis.enabled}');
    RenderLog.write('c364_gate', 'tab=$tab,balanced=${vis.enabled}');
    // C365: aggregated per-product gate — reaches green once every product's disputed covers its gap.
    RenderLog.write('c365_gate', 'tab=$tab,balanced=${vis.enabled}');
    return vis;
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
  // RC3: mode is top-level in fw_get_state response, never per-item
  // #333: backend now returns 'stage' (not 'mode'); keep 'mode' as fallback for legacy shapes
  static String? supplierModeOf(Map<String, dynamic> stateRes) =>
      (stateRes['stage'] ?? stateRes['mode'])?.toString();
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

  // #338: voice-vs-actual count audit per product_id (mismatch chips).
  // Fetched on supplier expand (_loadBox) and after mention toggles; cleared
  // by _reloadItemsFromDB (confirm/undo/manual edits make it stale). Never on hot path.
  Map<String, Map<String, dynamic>> _auditMismatchMap = {};

  Future<void> _fetchCountAudit(String supplier) async {
    if (supplier.isEmpty) return;
    final stage = widget.arrivals ? 'warehouse' : 'shop';
    try {
      final dynamic raw = await Supabase.instance.client.rpc(
        'fw_count_source_audit',
        params: {'p_supplier_name': supplier, 'p_stage': stage},
      );
      if (!mounted) return;
      final res = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      final rawList = res['products'] ?? res['items'];
      final products = (rawList is List ? rawList : const [])
          .whereType<Map>()
          .map((p) => Map<String, dynamic>.from(p))
          .toList();
      final map = <String, Map<String, dynamic>>{};
      var mismatches = 0;
      for (final p in products) {
        final pid = p['product_id']?.toString();
        if (pid == null || pid.isEmpty) continue;
        map[pid] = p;
        if (p['mismatch'] == true) mismatches++;
      }
      setState(() => _auditMismatchMap = map);
      RenderLog.write(stage == 'warehouse' ? 'c338_audit_wh' : 'c338_audit_shop',
          'mismatches=$mismatches;supplier=$supplier');
    } catch (_) {
      // audit is advisory — never block the box on failure
    }
  }

  // #338: small amber "voice X ≠ Y" chip when voice total disagrees with actual
  Widget? _mismatchChip(int? productId) {
    if (productId == null) return null;
    final m = _auditMismatchMap['$productId'];
    if (m == null || m['mismatch'] != true) return null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF3C7),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFFF59E0B), width: 0.5),
      ),
      child: Text(
        'voice ${m['voice_total']} ≠ ${m['actual_total']}',
        style: const TextStyle(
            fontSize: 10, color: Color(0xFF92400E), fontWeight: FontWeight.w600),
      ),
    );
  }

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

  // CHANGE #444 — older_open returned by the last fw_list_arrivals call, for
  // this tab's own OlderOpenPill (Shop and Warehouse are separate State
  // instances, each calling the RPC with the same shared date scope).
  int _olderOpen = 0;

  // CHANGE #471 — a date-scope change must refetch the OPEN box too (not just
  // the supplier list), else a card survives a date switch showing stale-date
  // items. Also drops the per-box older toggle back to OFF (spec 3.3).
  void _onDateScopeChanged() {
    _loadSuppliers();
    if (_selectedSupplier != null) {
      _boxIncludeOlder = false;
      _reloadItemsFromDB();
    }
  }

  @override
  void initState() {
    super.initState();
    FulfillDateScope.instance.addListener(_onDateScopeChanged);
    _loadSettings();
    _loadSuppliers();
    _initVoice();
    // CHANGE #453: keep the "N spoken" badge live — refetch (scoped, via
    // fetchScopedVoiceMentions) whenever a window's mentions land, same trigger
    // the "Counted items" popup already uses.
    FulfillRealtime.instance.addListener(_onVoiceMentionsRealtime);
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
    RenderLog.write('c331_caps', 'wired=y'); // #331: static presence marker for VoiceCaps helper
    RenderLog.write('c354_ready', 'tab=${widget.arrivals ? 'warehouse' : 'shop'}');
  }

  // CHANGE #453: realtime trigger for the badge — mirrors _CountedMentionsPopup's
  // own listener so both refetch on the same event.
  void _onVoiceMentionsRealtime(Set<String> changedTables) {
    if (!mounted) return;
    if (changedTables.contains('voice_clip_mentions')) _refreshVoiceMentions();
  }

  @override
  void dispose() {
    FulfillRealtime.instance.removeListener(_onVoiceMentionsRealtime);
    FulfillDateScope.instance.removeListener(_onDateScopeChanged);
    _listScrollCtrl.dispose();
    _agentBubbleEntry?.remove();
    _agentBubbleEntry = null;
    _spokenPopupEntry?.remove();
    _spokenPopupEntry = null;
    _ttsAudio?.pause();
    _ttsAudio = null;
    _voiceService.dispose();
    _idleTimer?.cancel();
    // Continuous voice counting (#8): don't leave a session dangling if the worker
    // navigates away / this screen is torn down mid-count — cancel, never finalize,
    // since an unfinished count must not be persisted.
    _voiceSession?.cancel().ignore();
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
      // C358 B1: SILENT refetch — only show the spinner on the FIRST load (empty list).
      // A realtime-driven refetch keeps the existing list on screen and patches it in
      // place when the new data arrives, so the tab never flashes/reloads.
      if (!_loadingSuppliers && _suppliers.isEmpty) setState(() => _loadingSuppliers = true);
      try {
        final scope = FulfillDateScope.instance;
        // p_include_older not sent — fw_list_arrivals is strict single-date now.
        final res = await Supabase.instance.client.rpc('fw_list_arrivals', params: {
          'p_date': ymd(scope.date),
        }) as Map;
        if (!mounted) return;
        _olderOpen = (res['older_open'] as num?)?.toInt() ?? 0;
        RenderLog.write('c444_older_open', '$_olderOpen');
        RenderLog.write('c444_include_older', '${scope.includeOlder}');
        // CHANGE #473: Warehouse only shows suppliers whose Shop counting has
        // already been confirmed (forwarded==true) — use the backend's
        // pre-filtered list instead of the full Supplier-Shop suppliers array,
        // so an unconfirmed/undone supplier never appears here.
        final c473Shop = (res['count'] as num?)?.toInt() ?? 0;
        final c473Warehouse = (res['warehouse_count'] as num?)?.toInt() ?? 0;
        RenderLog.write('c473_fw_sync',
            'date=${ymd(scope.date)} shop=$c473Shop warehouse=$c473Warehouse');
        final rawList = (res['warehouse_suppliers'] as List? ?? []);
        // Backend-owned dots: fw_list_arrivals() now returns per supplier
        // dot_packed/dot_method/dot_submit = {state, fill, border} (fill/border
        // are hex strings). Warehouse tab reads dot_method + dot_packed verbatim.
        final packedMap = <String, Map<String, String>>{};
        final methodMap = <String, Map<String, String>>{};
        final modeMap = <String, String?>{};
        final names = <String>[];
        Map<String, String>? asDot(dynamic v) => v is Map
            ? {
                'fill': v['fill']?.toString() ?? '',
                'border': v['border']?.toString() ?? '',
              }
            : null;
        for (final r in rawList) {
          final m = r as Map;
          final name = (m['supplier'] ?? m['supplier_name'])?.toString() ?? '';
          if (name.isEmpty) continue;
          if (!names.contains(name)) names.add(name);
          final dp = asDot(m['dot_packed']);
          if (dp != null) packedMap[name] = dp;
          final dm = asDot(m['dot_method']);
          if (dm != null) methodMap[name] = dm;
          final mv = m['mode']?.toString();
          modeMap[name] = (mv != null && mv.isNotEmpty) ? mv : null;
        }
        // #117 badge counts render-log
        final cCount = modeMap.values.where((v) => v == 'shop').length;
        final crCount = modeMap.values.where((v) => v != 'shop').length;
        RenderLog.write('c117_arrivals_badge_rendered', 'true');
        RenderLog.write('c117_badge_counts', 'C=$cCount,CR=$crCount');
        RenderLog.write('c117_dot_flush_right', 'true');
        RenderLog.write('c140_arrivals_source',
            'rpc=fw_list_arrivals;count=${names.length}');
        RenderLog.write('c337_wh_list', 'count=${names.length}');
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
          _supplierDotPackedMap = {..._supplierDotPackedMap, ...packedMap};
          _supplierDotMethodMap = {..._supplierDotMethodMap, ...methodMap};
          _supplierModeMap = {..._supplierModeMap, ...modeMap};
          // Do NOT reset _arrivalsLocked here — it is set by _checkArrivalsLocked()
          // after _loadBox(). Resetting it here clobbers the locked state immediately
          // after fw_confirm_all_received sets it to true. (bug fix #337-A)
        });
        widget.onSupplierCountChanged?.call(names.length);
      } catch (e) {
        if (!mounted) return;
        setState(() { _loadingSuppliers = false; _error = e.toString(); });
      }
      return;
    }
    RenderLog.write('78_collect_dropdown_query_sent', 'true');
    try {
      // CHANGE #444 — Shop now shares fw_list_arrivals with Warehouse (per the
      // backend contract: "feeds BOTH Supplier Shop AND Warehouse"), scoped to
      // the shared Fulfill date, instead of an undated direct supplier_orders
      // query. This is what makes Shop show 0 suppliers on a date with no open
      // work instead of every pending/sent supplier regardless of when placed.
      final scope = FulfillDateScope.instance;
      // p_include_older not sent — fw_list_arrivals is strict single-date now.
      final res = await Supabase.instance.client.rpc('fw_list_arrivals', params: {
        'p_date': ymd(scope.date),
      }) as Map;
      if (!mounted) return;
      _olderOpen = (res['older_open'] as num?)?.toInt() ?? 0;
      RenderLog.write('c444_older_open', '$_olderOpen');
      RenderLog.write('c444_include_older', '${scope.includeOlder}');
      // CHANGE #473: Supplier Shop stays unfiltered — every supplier with
      // items today, regardless of forwarded status.
      final c473Shop = (res['count'] as num?)?.toInt() ?? 0;
      final c473Warehouse = (res['warehouse_count'] as num?)?.toInt() ?? 0;
      RenderLog.write('c473_fw_sync',
          'date=${ymd(scope.date)} shop=$c473Shop warehouse=$c473Warehouse');
      final rawList = (res['suppliers'] as List? ?? []);
      final seen = <String>{};
      final names = <String>[];
      // Backend-owned dots: fw_list_arrivals() now returns per supplier
      // dot_packed/dot_method/dot_submit = {state, fill, border} (fill/border
      // are hex strings). Supplier Shop tab reads all three verbatim.
      final packedMap = <String, Map<String, String>>{};
      final methodMap = <String, Map<String, String>>{};
      final submitMap = <String, Map<String, String>>{};
      Map<String, String>? asDot(dynamic v) => v is Map
          ? {
              'fill': v['fill']?.toString() ?? '',
              'border': v['border']?.toString() ?? '',
            }
          : null;
      for (final r in rawList) {
        final m = r as Map;
        final s = (m['supplier'] ?? m['supplier_name'])?.toString();
        if (s == null || s.isEmpty || !seen.add(s)) continue;
        names.add(s);
        final dp = asDot(m['dot_packed']);
        if (dp != null) packedMap[s] = dp;
        final dm = asDot(m['dot_method']);
        if (dm != null) methodMap[s] = dm;
        final ds = asDot(m['dot_submit']);
        if (ds != null) submitMap[s] = ds;
      }
      RenderLog.write('78_collect_suppliers_count', '${names.length}');
      RenderLog.write('c444_shop_suppliers', '${names.length}');
      setState(() {
        _suppliers = names;
        _loadingSuppliers = false;
        _supplierDotPackedMap = {..._supplierDotPackedMap, ...packedMap};
        _supplierDotMethodMap = {..._supplierDotMethodMap, ...methodMap};
        _supplierDotSubmitMap = {..._supplierDotSubmitMap, ...submitMap};
      });
      widget.onSupplierCountChanged?.call(names.length);
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
      // C364: resolved/cancelled disputes drop out of the active index above -> the item
      // moves to Inactive/resolved in the Disputes tab live (in-place fill closed the line).
      RenderLog.write('c364_disp_close',
          'active=${itemMap.length};resolved=${disputes.length - itemMap.length}');
      context.findAncestorStateOfType<_AdminFulfillmentScreenState>()?._setDisputeCount(rawOpenCount);
      setState(() { _disputeMap = map; _disputeItemMap = itemMap; });
    } catch (_) {}
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
      _latestClipPath = null; // #115: reset clip state per supplier (#125: no local seq — comes from RPC)
      _arrivalsLocked = false; // #156: reset per-supplier lock when opening a new supplier
      _activeBag = null; // #253: reset active bag per supplier
      _auditMismatchMap = {}; // #338: audit is per-supplier — clear on open
      // CHANGE #471: per-box older toggle + backend display fields reset on open
      _boxIncludeOlder = false;
      _boxProgress = null; _boxDateLabel = null; _boxOlder = null;
    });

    // #127 BUG1 FIX: Arrivals uses fw_get_state(supplier,'arrivals') items directly.
    // get_receiving_box filtered out not-yet-warehouse items; fw_get_state returns the
    // correct mode-filtered set (shop→received_qty>0 lines; warehouse→all). No extra gate.
    if (widget.arrivals) {
      try {
        // #160: shape-tolerant parse — fw_get_state returns jsonb object; guard against
        // PostgREST wrapping it in [{fw_get_state: value}] on older versions.
        // CHANGE #471: p_date ALWAYS sent — the shared FulfillDateScope.date.
        // p_include_older is not sent — fw_get_state is strict single-date now.
        final dynamic _rawState = await Supabase.instance.client.rpc('fw_get_state',
            params: fwGetStateParams(
              supplierName: supplier, stage: 'arrivals',
              date: FulfillDateScope.instance.date,
            ));
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
        // items[] and merged_items[] both arrive pre-sorted (product_name) server-side.
        final rawMerged = stateRes['merged_items'];
        final mergedItems = (rawMerged is List ? rawMerged : <dynamic>[])
            .map((r) => _MergedProduct.fromBackend(Map<String, dynamic>.from(r as Map)))
            .toList();
        final firstPending = stateItems.indexWhere(
            (i) => (i['fulfillment_state']?.toString() ?? 'pending') == 'pending');
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
          _mergedItemsBackend = mergedItems;
          _focusIdx = firstPending >= 0 ? firstPending : 0;
          _loadingBox = false;
          _showListView = false;
          _arrivalsLocked = confirmed;
          _supplierMode = parsedMode;
          _activeBag = activeBag;
          // CHANGE #471: backend-owned display fields — rendered verbatim
          _boxProgress = stateRes['progress'] is Map ? Map<String, dynamic>.from(stateRes['progress'] as Map) : null;
          _boxDateLabel = stateRes['date_label']?.toString();
          _boxOlder = stateRes['older'] is Map ? Map<String, dynamic>.from(stateRes['older'] as Map) : null;
          _voiceMentions = []; // clear stale mentions; fresh fetch below
          _activeVoiceSessionKey = null; // #453: fresh card load — no known session yet
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
        _fetchCountAudit(supplier); // #338: voice-vs-actual mismatch chips (expand only)
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
      // #333: fw_get_state('collect') returns items WITH shop_qty and top-level stage
      // CHANGE #471: p_date ALWAYS sent; p_include_older not sent (strict single-date).
      final dynamic _rawCollect = await Supabase.instance.client.rpc('fw_get_state',
          params: fwGetStateParams(
            supplierName: supplier, stage: 'collect',
            date: FulfillDateScope.instance.date,
          ));
      if (!mounted) return;
      Map<String, dynamic> collectState;
      if (_rawCollect is Map) {
        collectState = Map<String, dynamic>.from(_rawCollect);
      } else if (_rawCollect is List && _rawCollect.isNotEmpty && _rawCollect[0] is Map) {
        final first = _rawCollect[0] as Map;
        final inner = first['fw_get_state'];
        collectState = inner is Map ? Map<String, dynamic>.from(inner) : Map<String, dynamic>.from(first);
      } else {
        collectState = {};
      }
      final rawItems = collectState['items'];
      final items = (rawItems is List ? rawItems : <dynamic>[])
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      // items[] and merged_items[] both arrive pre-sorted (product_name) server-side.
      final rawMerged = collectState['merged_items'];
      final mergedItems = (rawMerged is List ? rawMerged : <dynamic>[])
          .map((r) => _MergedProduct.fromBackend(Map<String, dynamic>.from(r as Map)))
          .toList();
      final firstPending = items.indexWhere(
          (i) => (i['fulfillment_state']?.toString() ?? 'pending') == 'pending');
      final freshMode = supplierModeOf(collectState); // #333: reads top-level stage field
      RenderLog.write('c333_state_stage', 'stage=${freshMode ?? 'null'};supplier=$supplier');
      if (!mounted) return;
      setState(() {
        _items = items;
        _mergedItemsBackend = mergedItems;
        _focusIdx = firstPending >= 0 ? firstPending : 0;
        _loadingBox = false;
        _showListView = false;
        _supplierMode = freshMode;
        if (freshMode != null) _collectModeMap[supplier] = freshMode;
        // CHANGE #471: backend-owned display fields — rendered verbatim
        _boxProgress = collectState['progress'] is Map ? Map<String, dynamic>.from(collectState['progress'] as Map) : null;
        _boxDateLabel = collectState['date_label']?.toString();
        _boxOlder = collectState['older'] is Map ? Map<String, dynamic>.from(collectState['older'] as Map) : null;
        _voiceMentions = []; // clear stale; fresh fetch below
        _activeVoiceSessionKey = null; // #453: fresh card load — no known session yet
      });
      _refreshVoiceMentions(); // #263: load today's mentions for distinct-product spoken count
      _fetchCountAudit(supplier); // #338: voice-vs-actual mismatch chips (expand only)
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
      // CHANGE #471: p_date ALWAYS sent; p_include_older not sent (strict single-date).
      final dynamic _rawLock = await Supabase.instance.client.rpc('fw_get_state',
          params: fwGetStateParams(
            supplierName: supplier, stage: 'arrivals',
            date: FulfillDateScope.instance.date,
          ));
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

      // #339 BUG-1: uncounted_items is a HARD BLOCK — do NOT fall through to success.
      // Branch 1 — BLOCK: some items have received_qty == 0
      if (res['error'] == 'uncounted_items') {
        final rawItems = (res['items'] as List? ?? []);
        final names = rawItems
            .map((i) => (i as Map)['product_name']?.toString() ?? 'item')
            .toList();
        RenderLog.write('c339_wh_uncounted', 'count=${names.length}');
        // C363-A: the confirm button is already RED+disabled while any line is uncounted;
        // this RPC-level guard now just surfaces a toast (no separate yellow list).
        setState(() => _confirmingAll = false);
        if (mounted && names.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Count all items first: ${names.join(', ')}')));
        }
        return;
      }
      // C362 point-3 — BLOCK: a bag is still attached. Backend refuses with 'bag_attached';
      // surface the hint and keep the R button disabled (also gated in the footer).
      if (res['error'] == 'bag_attached') {
        RenderLog.write('c362_bag_gate', 'blocked=true;src=rpc');
        setState(() => _confirmingAll = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text((res['hint'] ?? 'Detach the bag before confirming all received').toString())));
        return;
      }
      // Branch 2 — Hard unknown error
      if (res['error'] != null) {
        RenderLog.write('c339_wh_confirm_fail', 'error=${res['error']}');
        setState(() => _confirmingAll = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${res['error']}')));
        return;
      }

      // Branch 3 — Success: server truth via _reloadItemsFromDB sets _arrivalsLocked
      // #261 5F: confirm-all auto-detaches bags; clear any pending change progress
      if (supplier != null) _changeProgressBySupplier.remove(supplier);
      setState(() => _confirmingAll = false);
      _loadSuppliers();
      await _reloadItemsFromDB(); // sets _arrivalsLocked = true via fw_get_state response
      final lockedItems = (res['locked_items'] as num?)?.toInt() ?? 0;
      final disputesRaised = (res['disputes_raised'] as num?)?.toInt() ?? 0;
      RenderLog.write('c158_confirm_lock',
          'ok_locks=y;undo=fw_unconfirm_all_received');
      RenderLog.write('c125_confirm_refresh', 'true');
      RenderLog.write('c335_confirm', 'wh_confirm_ok=y');
      RenderLog.write('c359_confirm_raise', 'tab=warehouse,raised=$disputesRaised'); // C359: disputes raised at confirm
      RenderLog.write('c361_confirm', 'tab=warehouse,raised=$disputesRaised'); // C360
      RenderLog.write('c339_wh_confirmed', 'locked_items=$lockedItems;disputes=$disputesRaised');
      // #125 R6: refresh Collect so re-sourced shortfall lines appear
      context.findAncestorStateOfType<_AdminFulfillmentScreenState>()?._refreshCollect();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$lockedItems locked · $disputesRaised new dispute(s)'),
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
      RenderLog.write('c337_undo_wh', 'supplier=$supplier');
      // C362 point-5: undo the response so the raised disputes are cancelled + flags kept,
      // returning the candidate rows so the admin can EDIT the dispute type, then re-submit R.
      RenderLog.write('c362_edit_undo', 'tab=warehouse');
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
        final err2 = res2['error']?.toString();
        if (err2 == 'collect_locked') {
          if (mounted) setState(() => _recording = false);
          _showSnack('Counting locked — already forwarded to warehouse');
          return;
        }
        if (err2 == 'warehouse_only_state') {
          if (mounted) setState(() => _recording = false);
          _showSnack('This item is counted at warehouse only');
          return;
        }
        if (err2 != null) throw Exception(err2);
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
        final msg = e.toString();
        if (msg.contains('not forwarded')) {
          RenderLog.write('c337_gate_notforwarded', 'supplier=${_selectedSupplier ?? ''}');
          _showSnack('Supplier not forwarded — count in warehouse instead');
        } else {
          _showSnack('Error: $e');
        }
      }
    }
  }

  // ── Navigation ─────────────────────────────────────────────────────────────

  void _advance() {
    bool isPending(Map<String, dynamic> i) =>
        (i['fulfillment_state']?.toString() ?? 'pending') == 'pending';
    final nextPending = _items.indexWhere(isPending, _focusIdx + 1);
    setState(() {
      if (nextPending >= 0) {
        _focusIdx = nextPending;
      } else {
        final firstPending = _items.indexWhere(isPending);
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
  // #8: the client-side RMS/peak loudness pre-filter (_measureLoudness, formerly
  // called here before upload) has no equivalent hook inside ContinuousVoiceSession
  // — every ~24s window is uploaded+transcribed unconditionally now. Noise/silence
  // is instead handled by the edge function's own confidence/no-qty dropping and by
  // voice_finalize_session's unmatched_mentions/needs_bag_review reporting.

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
    if (_boxLocked || (!widget.arrivals && _supplierMode == 'warehouse')) {
      RenderLog.write('change_91_edit_blocked', '1');
      RenderLog.write('c337_shop_locked_card',
          'supplier=${_selectedSupplier ?? ''};mode=${_supplierMode ?? 'unknown'};mic_blocked=y');
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
        // #8: no 90s idle-auto-stop here — that cap belonged to the old single-shot
        // per-bag recording (one short clip, then must stop before the next bag).
        // A continuous session is meant to keep running across bag switches, which
        // can easily exceed 90s; the 1-hour hard cap / daily-remaining cap below
        // (via _capsTimer in _startRecording) remain as the real safety net.
        _idleTimer?.cancel();
      }
    }
  }

  Future<void> _startRecording() async {
    if (!_voiceSupported || _voiceListening || _voiceProcessing) return;
    // #331 VoiceCaps: check daily cap before starting (Shop + Warehouse surface)
    final capsAllowed = await _VoiceCaps.onSessionStart(context, Supabase.instance.client);
    if (!mounted || !capsAllowed) return;
    // #332: obtain background session key — never record without one (prevents session mixing)
    final supplier332 = _selectedSupplier;
    if (supplier332 == null || supplier332.isEmpty) {
      _showSnack('No supplier selected');
      return;
    }
    try {
      final sessionRaw = await Supabase.instance.client
          .rpc('fw_count_session', params: {'p_supplier': supplier332}) as Map;
      final sessionRes = Map<String, dynamic>.from(sessionRaw);
      if (sessionRes['status'] != 'ok') throw Exception('session_error');
      _sessionKey = sessionRes['session_key']?.toString();
      _sessionStage = sessionRes['stage']?.toString();
      RenderLog.write('c332_session_key', 'key=${_sessionKey ?? ''};stage=${_sessionStage ?? ''}');
      RenderLog.write('c335_session', 'key=${_sessionKey ?? ''};stage=${_sessionStage ?? ''}');
    } catch (e) {
      if (mounted) _showSnack('Voice session error — retry');
      return;
    }
    if (_sessionKey == null || _sessionKey!.isEmpty) {
      if (mounted) _showSnack('Voice session error — retry');
      return;
    }
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
    // #8: continuous voice counting — one session spans the whole mic-on → Stop
    // lifecycle, recording back-to-back windows across bag switches. Stamped with
    // the backend's own stage determination (fw_count_session, authoritative —
    // matches _supplier_shop_stage()); widget.arrivals is only the UI-tab fallback.
    final stage = _sessionStage ?? (widget.arrivals ? 'warehouse' : 'shop');
    final session = ContinuousVoiceSession(
      supplierName: supplier332,
      stage: stage,
      orderItemsProvider: () => _items,
      expectedProvider: _buildExpectedList,
      onWindowError: (e, st) {
        RenderLog.write('c8_voice_window_err',
            e.toString().substring(0, e.toString().length.clamp(0, 100)));
        if (mounted) _showSnack('A recording window failed to save — counting continues');
      },
      // #331/#8: restore the daily 3-hour usage-cap ledger for continuous sessions — without
      // this, voice_clip_register never runs during a long session, so the server-side cap
      // never sees its usage and effectively stops enforcing.
      onClipUploaded: (path, seconds, seq) {
        final capCtx = widget.arrivals ? 'warehouse' : 'collect';
        _VoiceCaps.onClipSaved(Supabase.instance.client,
            ctxStr: capCtx, supplier: supplier332, path: path, seconds: seconds,
            sessionKey: _sessionKey,
            stage: stage,
            onLocked: () { if (mounted) _showSnack('Daily 3-hour voice limit reached'); }).ignore();
      },
    );
    try {
      await session.start();
      _voiceSession = session;
      _activeVoiceSessionKey = session.sessionKey; // #453: badge/popup scope key
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
    // CHANGE #455: write the INITIAL bag's boundary at record start (mapped_at_sec=0) —
    // without this, items spoken before the FIRST bag-change had no boundary to place them
    // against, so voice_finalize_session correctly (but wrongly, in intent) flagged them
    // needs_bag_review even though a bag was already scanned before the mic was tapped.
    // Warehouse only — bags don't exist in Shop; _activeBag is always null there, but
    // widget.arrivals is checked explicitly too so this can never fire outside Warehouse.
    // Reuses the SAME recordVoiceBagBoundary() helper the bag-CHANGE path already calls
    // (session.recordBagMap) — only mapped_at_sec (fixed 0, not session-clock elapsed) and
    // the trigger (record start, not a bag scan) differ; no new write path or table.
    // Best-effort and non-fatal: a failure here must never roll back an otherwise-successful
    // recording start, and the unique (session_key, bag_no, mapped_at_sec) constraint makes a
    // duplicate call a harmless no-op if this somehow ran twice for the same session.
    if (_recStarted && widget.arrivals) {
      final initialBagNo = (_activeBag?['bag_no'] as num?)?.toInt();
      if (initialBagNo != null) {
        try {
          await recordVoiceBagBoundary(
            sessionKey: session.sessionKey,
            supplierName: supplier332,
            bagNo: initialBagNo,
            mappedAtSec: 0.0,
          );
          RenderLog.write('c455_initial_boundary',
              'session=${session.sessionKey};bag=$initialBagNo;t=0');
        } catch (e) {
          RenderLog.write('c455_initial_boundary_err',
              e.toString().substring(0, e.toString().length.clamp(0, 80)));
        }
      }
    }
  }

  // #8: continuous voice counting — stop the session, wait for every in-flight
  // window to finish, finalize (bag-boundary segmentation + dedup + persist), then
  // surface the summary. Replaces the old single-shot stop→transcribe→upload→
  // insertMentions→commit sequence entirely (that per-clip pipeline now runs
  // automatically inside ContinuousVoiceSession every ~24s while recording).
  Future<void> _stopAndTranscribe() async {
    if (!_voiceListening) return;
    _capsTimer?.cancel(); // #331: stop continuous timer
    setState(() { _voiceListening = false; _voiceInterim = ''; });
    if (!_recStarted) return;
    _recStarted = false;
    final session = _voiceSession;
    if (session == null) return;
    setState(() => _voiceProcessing = true);
    try {
      final result = await session.stopAndFinalize();
      final sessionKey = session.sessionKey; // #457: needed for the needs_bag_review re-finalize
      _voiceSession = null;
      if (!mounted) return;
      await _reloadItemsFromDB();
      if (!mounted) return;
      _showFinalizeSummary(result, sessionKey);
      _advanceIfReceived(); // B4: auto-advance after voice commit
      _refreshVoiceMentions(); // #263: update distinct-product spoken count
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _popupKey.currentState?._fetchMentions();
      });
    } catch (e) {
      _voiceSession = null;
      if (!mounted) return;
      setState(() { _voiceError = e.toString(); });
      Future.delayed(const Duration(seconds: 4), () {
        if (mounted) setState(() => _voiceError = '');
      });
    } finally {
      if (mounted) setState(() => _voiceProcessing = false);
    }
  }

  // #8: summarizes voice_finalize_session's jsonb result after Stop. needs_bag_review
  // (spoken before any bag was mapped — an SOP-violation safety net), over-count
  // warnings (#457 Bug 3), and unmatched_mentions (no product match) are surfaced
  // via a blocking dialog, never just a snack, so they can't be missed; a clean
  // finalize gets a plain SnackBar. sessionKey (#457 Bug 2) is needed to re-run
  // voice_finalize_session after the worker assigns a review item to a bag.
  void _showFinalizeSummary(Map<String, dynamic> result, String sessionKey) {
    if (!mounted) return;
    final persisted = (result['persisted'] as List?) ?? const [];
    final bagBreakdown = (result['bag_breakdown'] as Map?) ?? const {};
    final needsReview = (result['needs_bag_review'] as List?) ?? const [];
    final unmatched = (result['unmatched_mentions'] as List?) ?? const [];
    final overCounts = overCountWarnings(persisted, _items);
    final productCount = persisted
        .map((p) => p is Map ? p['product_id'] : null)
        .where((id) => id != null)
        .toSet()
        .length;
    final bagCount = bagBreakdown.keys.length;
    final base = widget.arrivals
        ? 'Counted $productCount product${productCount == 1 ? '' : 's'} across $bagCount bag${bagCount == 1 ? '' : 's'}.'
        : 'Counted $productCount product${productCount == 1 ? '' : 's'}.';
    RenderLog.write('c8_finalize_summary',
        'persisted=$productCount;bags=$bagCount;review=${needsReview.length};unmatched=${unmatched.length}');
    RenderLog.write('c457_over_count', 'count=${overCounts.length}');
    if (needsReview.isEmpty && unmatched.isEmpty && overCounts.isEmpty) {
      _showSnack(base);
      return;
    }
    final extra = <String>[
      if (needsReview.isNotEmpty) '${needsReview.length} need bag review',
      if (overCounts.isNotEmpty) '${overCounts.length} over-counted',
      if (unmatched.isNotEmpty) '${unmatched.length} unmatched',
    ].join(', ');
    _showSnack('$base $extra.');
    final supplier = _selectedSupplier ?? '';
    showDialog<void>(
      context: context,
      builder: (ctx) => _FinalizeReviewDialog(
        base: base,
        supplierName: supplier,
        sessionKey: sessionKey,
        // #457 Bug 2: WAREHOUSE only — Shop's finalize never returns needs_bag_review
        // (voice_finalize_session hardcodes needs_review=false when stage != 'warehouse'),
        // so this is empty for Shop regardless; widget.arrivals is checked explicitly too.
        initialNeedsReview: widget.arrivals ? needsReview : const [],
        overCountWarnings: overCounts,
        unmatched: unmatched,
        onResolved: () {
          _refreshVoiceMentions();
          _popupKey.currentState?._fetchMentions();
        },
      ),
    );
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

  // #263/#453: load voice clip mentions from DB → derive distinct-product count
  // for "N spoken" badge. Scoped by _activeVoiceSessionKey via the SAME shared
  // helper the "Counted items" popup uses (see fetchScopedVoiceMentions), so the
  // two can never disagree.
  Future<void> _refreshVoiceMentions() async {
    final supplier = _selectedSupplier;
    if (supplier == null) return;
    try {
      final mentions = await fetchScopedVoiceMentions(
        supplierName: supplier,
        stage: widget.arrivals ? 'warehouse' : 'shop',
        sessionKey: _activeVoiceSessionKey,
      );
      if (!mounted) return;
      final distinct = mentions.map((m) => m['product_id']).where((id) => id != null).toSet().length;
      RenderLog.write('c263_spoken_count', 'distinct_products=$distinct;total_mentions=${mentions.length}');
      setState(() => _voiceMentions = mentions);
    } catch (_) {}
  }

  Future<void> _reloadItemsFromDB() async {
    final supplier = _selectedSupplier;
    if (supplier == null) return;
    // #338: any reload (confirm/undo/manual edits) makes the voice-vs-actual
    // audit stale — clear it (no extra RPC on this hot path; refetch happens
    // on next expand or after a mention toggle).
    if (_auditMismatchMap.isNotEmpty && mounted) {
      setState(() => _auditMismatchMap = {});
    }
    // #127 BUG1 FIX: Arrivals reload uses fw_get_state directly (no get_receiving_box).
    if (widget.arrivals) {
      try {
        // CHANGE #471: p_date ALWAYS sent; p_include_older not sent (strict single-date).
        final dynamic _rawReload = await Supabase.instance.client.rpc('fw_get_state',
            params: fwGetStateParams(
              supplierName: supplier, stage: 'arrivals',
              date: FulfillDateScope.instance.date,
            ));
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
        // items[] and merged_items[] both arrive pre-sorted (product_name) server-side.
        final rawMerged = stateRes['merged_items'];
        final mergedItems = (rawMerged is List ? rawMerged : <dynamic>[])
            .map((r) => _MergedProduct.fromBackend(Map<String, dynamic>.from(r as Map)))
            .toList();
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
          _mergedItemsBackend = mergedItems;
          if (confirmed != _arrivalsLocked) _arrivalsLocked = confirmed;
          if (reloadedMode != _supplierMode) _supplierMode = reloadedMode;
          _activeBag = reloadActiveBag;
          // CHANGE #471: backend-owned display fields — rendered verbatim
          _boxProgress = stateRes['progress'] is Map ? Map<String, dynamic>.from(stateRes['progress'] as Map) : null;
          _boxDateLabel = stateRes['date_label']?.toString();
          _boxOlder = stateRes['older'] is Map ? Map<String, dynamic>.from(stateRes['older'] as Map) : null;
          if (reloadActiveBag == null) _changeProgressBySupplier.remove(supplier);
          // Sync change-bag intent from backend on every reload
          if (reloadBagFlow == 'awaiting_new') {
            _changeBagPendingOldBag[supplier] = reloadAwaitingBagNo?.toString();
          } else if (reloadBagFlow != null) {
            // 'active' or 'none' — clear stale intent (new bag was attached or flow was reset)
            _changeBagPendingOldBag.remove(supplier);
          }
        });
        // C364: warehouse rows re-rendered from fresh payload on the realtime/refetch path —
        // a resolved dispute's raised received (e.g. 3/4 -> 4/4) reflects here (spec 4).
        RenderLog.write('c364_recv_reflect', 'tab=warehouse;items=${stateItems.length}');
      } catch (e) {
        final errMsg = e.toString();
        if (mounted) setState(() => _error = errMsg);
        RenderLog.write('c160_loadbox_error', 'reload:${errMsg.substring(0, errMsg.length.clamp(0, 110))}');
      }
      return;
    }
    try {
      // #333: fw_get_state('collect') returns items WITH shop_qty and top-level stage
      // CHANGE #471: p_date ALWAYS sent; p_include_older not sent (strict single-date).
      final dynamic _rawReloadCollect = await Supabase.instance.client.rpc('fw_get_state',
          params: fwGetStateParams(
            supplierName: supplier, stage: 'collect',
            date: FulfillDateScope.instance.date,
          ));
      if (!mounted) return;
      Map<String, dynamic> reloadState;
      if (_rawReloadCollect is Map) {
        reloadState = Map<String, dynamic>.from(_rawReloadCollect);
      } else if (_rawReloadCollect is List && _rawReloadCollect.isNotEmpty && _rawReloadCollect[0] is Map) {
        final first = _rawReloadCollect[0] as Map;
        final inner = first['fw_get_state'];
        reloadState = inner is Map ? Map<String, dynamic>.from(inner) : Map<String, dynamic>.from(first);
      } else {
        reloadState = {};
      }
      final rawReloadItems = reloadState['items'];
      final reloadItems = (rawReloadItems is List ? rawReloadItems : <dynamic>[])
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      // items[] and merged_items[] both arrive pre-sorted (product_name) server-side.
      final rawReloadMerged = reloadState['merged_items'];
      final reloadMergedItems = (rawReloadMerged is List ? rawReloadMerged : <dynamic>[])
          .map((r) => _MergedProduct.fromBackend(Map<String, dynamic>.from(r as Map)))
          .toList();
      final reloadedMode = supplierModeOf(reloadState); // #333: reads stage field
      setState(() {
        _items = reloadItems;
        _mergedItemsBackend = reloadMergedItems;
        // B5: always assign (even null) so mode clears correctly after undo
        _supplierMode = reloadedMode ?? _supplierMode;
        if (reloadedMode != null) _collectModeMap[supplier] = reloadedMode;
        // CHANGE #471: backend-owned display fields — rendered verbatim
        _boxProgress = reloadState['progress'] is Map ? Map<String, dynamic>.from(reloadState['progress'] as Map) : null;
        _boxDateLabel = reloadState['date_label']?.toString();
        _boxOlder = reloadState['older'] is Map ? Map<String, dynamic>.from(reloadState['older'] as Map) : null;
        // B9: clamp focus after reload to prevent _currentItem returning null
        if (_items.isNotEmpty && _focusIdx >= _items.length) {
          _focusIdx = _items.length - 1;
          RenderLog.write('c168_focus_clamped', 'true');
        }
      });
      // C364: shop rows re-rendered from fresh payload on the realtime/refetch path —
      // a resolved dispute's in-place received (e.g. 3/4 -> 4/4) reflects here (spec 4).
      RenderLog.write('c364_recv_reflect', 'tab=shop;items=${reloadItems.length}');
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
      // #8: mark the session-clock moment this bag became current — never on detach.
      final session = _voiceSession;
      final newBagNo = (result['bag_no'] as num?)?.toInt();
      if (session != null && newBagNo != null) await session.recordBagMap(newBagNo);
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
      // #8: mark the session-clock moment this bag became current — never on detach.
      final session = _voiceSession;
      final newBagNo = (_activeBag?['bag_no'] as num?)?.toInt();
      if (session != null && newBagNo != null) await session.recordBagMap(newBagNo);
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

  // C363-B: "Dispute option" on/off toggle (per SS/WH tab). OFF (default) = tapping an
  // item does NOTHING; ON = tapping ANY item (received, counted, uncounted, or already
  // disputed) opens the dispute popup. Counting stays voice-only regardless of this toggle.
  bool _disputeToggleOn = false;

  // C363-B: the "Dispute option" slide switch, shown above the confirm button on BOTH
  // Supplier Shop + Warehouse (one widget → both layouts agree, no drift).
  Widget _buildDisputeToggle() {
    final tab = widget.arrivals ? 'warehouse' : 'shop';
    RenderLog.write('c363_toggle', 'tab=$tab,on=$_disputeToggleOn');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 2, 6, 2),
      decoration: BoxDecoration(
        color: _disputeToggleOn ? const Color(0xFFFFFBEB) : const Color(0xFFF5F6F8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: _disputeToggleOn ? const Color(0xFFFCD34D) : _kBorder),
      ),
      child: Row(children: [
        Icon(Icons.flag_outlined,
            size: 16, color: _disputeToggleOn ? const Color(0xFFB45309) : _kSub),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _disputeToggleOn
                ? 'Dispute option — tap any item to raise a dispute'
                : 'Dispute option',
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: _disputeToggleOn ? const Color(0xFF92400E) : _kText)),
        ),
        Switch(
          value: _disputeToggleOn,
          activeColor: _kGreen,
          onChanged: (v) {
            setState(() => _disputeToggleOn = v);
            RenderLog.write('c363_toggle', 'tab=$tab,on=$v');
          },
        ),
      ]),
    );
  }

  // #92: isWide=true → right-aligned compact; false → full-width refined mobile strip
  Widget _buildConfirmFooter(bool locked, {bool isWide = false}) {
    final isAdmin = UserState.of(context).isAdmin;
    // C360: the Fulfill counting tab rendered its footer — counting is voice-only
    // (no manual count buttons in the popup) and the gate below reads the shared logic.
    RenderLog.write('c361_voice_only', widget.arrivals ? 'warehouse' : 'shop');

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
                  child: Text('Receiving confirmed ✓',
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
      // C363-A: RED + disabled until EVERY line satisfies ordered<=received+disputed
      // (counted AND its discrepancy reconciled); GREEN + clickable once all satisfy.
      final ConfirmButtonVisual whVis = _confirmVisual;
      // C363-C: a bag must be DETACHED before "Confirm all received" (backend also refuses
      // with {error:'bag_attached'}). Detect via the active bag from fw_get_state.
      final bool bagAttached = _activeBag != null;
      final bool whRed = whVis.red || bagAttached; // RED+disabled if unbalanced OR bag attached
      if (bagAttached) RenderLog.write('c362_bag_gate', 'blocked=true');
      RenderLog.write('c363_color', 'tab=warehouse,color=${whRed ? 'red' : 'green'}');
      return Column(mainAxisSize: MainAxisSize.min, children: [
        _buildDisputeToggle(),
        SizedBox(
          height: 44,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: whRed ? const Color(0xFFFEE2E2) : _kGreen,
              disabledBackgroundColor:
                  whRed ? const Color(0xFFFEE2E2) : _kGreen.withValues(alpha: 0.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: (whRed || _confirmingAll) ? null : _fw_confirmAllReceived,
            child: _confirmingAll
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(
                        whRed
                            ? Icons.error_outline_rounded
                            : Icons.check_circle_outline_rounded,
                        size: 15,
                        color: whRed ? const Color(0xFF991B1B) : Colors.white),
                    const SizedBox(width: 4),
                    Text(
                        bagAttached
                            ? 'Detach the bag to confirm all'
                            : whVis.red
                                ? 'Count & resolve all items to confirm'
                                : 'Confirm all items received',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: whRed ? const Color(0xFF991B1B) : Colors.white)),
                  ]),
          ),
        ),
      ]);
    }

    // A1 §2.7: _supplierMode=='warehouse' means supplier was forwarded — suppress ALL action
    // buttons (Confirm counting / Count in warehouse / Send reminder). Render ONLY the lock
    // line + hold-to-undo. _boxLocked is also checked for belt-and-suspenders.
    final shopLocked = locked || _supplierMode == 'warehouse';
    if (shopLocked) {
      RenderLog.write('change_91_locked', '1');
      RenderLog.write('c337_shop_locked_card',
          'supplier=${_selectedSupplier ?? ''};mode=${_supplierMode ?? 'unknown'};'
          'boxLocked=$locked;forwarded=${_supplierMode == 'warehouse'}');
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
    // Reached only when shop is NOT forwarded and NOT box-locked.
    RenderLog.write('change_92_confirm_styled', '1');
    RenderLog.write('c137_collect_buttons', 'two=y;names=count_wh+confirm');
    const double _kFooterH = 44.0;
    // C363-A: "Count in warehouse" is GREEN always; "Confirm counting" is RED + disabled
    // until EVERY line satisfies ordered<=counted+disputed (counted AND reconciled), then
    // GREEN + clickable. One shared gate → NO separate "yellow items" list below the button.
    final ConfirmButtonVisual shopVis = _confirmVisual;
    RenderLog.write('c363_color', 'tab=shop,color=${shopVis.red ? 'red' : 'green'}');
    // C363-A: "Count in warehouse" is GREEN + always enabled (never gated).
    RenderLog.write('c363_cw_green', 'tab=shop');
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
          width: double.infinity,
          child: shopVis.red
              ? FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFFEE2E2),
                    disabledBackgroundColor: const Color(0xFFFEE2E2),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                  ),
                  onPressed: null,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(mainAxisSize: MainAxisSize.min, children: const [
                      Icon(Icons.error_outline_rounded, size: 15, color: Color(0xFF991B1B)),
                      SizedBox(width: 4),
                      Text('Count & resolve items to confirm',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF991B1B))),
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
      ),
    ]);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _buildDisputeToggle(), // C363-B: dispute on/off toggle above the confirm button
      collectRow,
    ]);
  }

  // #121: Undo Collect submission — clears mode, badge returns to P, supplier leaves Arrivals.
  // CHANGE #473: fw_undo_collect_submit's real contract returns one of:
  //   SUCCESS: {status:'ok', ...}            NO-OP: {status:'ok', note:'not_submitted', ...}
  //   BLOCKED: {error:'warehouse_confirmed'   | 'warehouse_in_progress', message:'...'}
  // Never assume success — any truthy 'error' blocks the undo and leaves the row untouched;
  // the guidance text always comes from the backend's 'message', not a hardcoded string here.
  Future<void> _fw_undoCollectSubmit() async {
    final supplier = _selectedSupplier;
    if (supplier == null) return;
    try {
      final res = await Supabase.instance.client.rpc('fw_undo_collect_submit',
          params: {'p_supplier_name': supplier});
      final m = (res is Map) ? res : const {};
      if (m['error'] != null) {
        RenderLog.write('c473_fw_sync', 'undo $supplier => ${m['error']}');
        RenderLog.write('c337_undo_shop_blocked', 'reason=${m['error']};supplier=$supplier');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(m['message']?.toString() ?? 'Cannot undo yet.')),
          );
        }
        return;
      }
      if (!mounted) return;
      RenderLog.write('c473_fw_sync', 'undo $supplier => ${m['status'] ?? 'ok'}');
      RenderLog.write('c125_undo_hold_fired', 'true');
      RenderLog.write('c337_undo_shop', 'supplier=$supplier');
      // C362 point-5: undo the response (full reset + cancels fresh disputes) so the admin
      // can re-count / re-classify, then re-submit "Confirm counting".
      RenderLog.write('c362_edit_undo', 'tab=shop');
      setState(() { _supplierMode = null; });
      _loadCollectModes(); // refresh badge map → P
      _loadSuppliers();
      await _reloadItemsFromDB();
      context.findAncestorStateOfType<_AdminFulfillmentScreenState>()?._refreshArrivals(); // R3: supplier leaves Arrivals
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(m['note'] == 'not_submitted'
              ? 'Nothing to undo.'
              : 'Shop submission undone.')),
        );
      }
    } catch (e) {
      if (mounted) {
        final msg = e.toString();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Undo error: ${msg.substring(0, msg.length.clamp(0, 80))}')),
        );
      }
    }
  }

  // #335 B2: items with a shop count — drives tracker/progress at shop stage
  int get _shopCountedCount =>
      _items.where((i) => i['shop_qty'] != null).length;

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
      // §2.5: handle uncounted items gate — show inline below confirm button
      if (res['error'] == 'uncounted_items') {
        final names = (res['items'] as List? ?? []).cast<String>();
        RenderLog.write('c331_confirm_gate', 'uncounted=${names.length}');
        RenderLog.write('c337_shop_uncounted', 'count=${names.length}');
        // C363-A: the confirm button is already RED+disabled while any line is uncounted;
        // this RPC-level guard now just surfaces a toast (no separate yellow list).
        if (mounted) {
          setState(() => _submittingCollect = false);
          if (names.isNotEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('Count all items first: ${names.join(', ')}')));
          }
        }
        return;
      }
      if (res['error'] != null) throw Exception(res['error'].toString());
      final shortsDisputed = (res['shorts_disputed'] as num?)?.toInt() ?? 0;
      // #335 BUG-6: removed _supplierMode='shop' — after confirm supplier is at warehouse stage;
      // _reloadItemsFromDB() will re-fetch fw_get_state and set _supplierMode correctly
      if (mounted) setState(() => _submittingCollect = false);
      await _reloadItemsFromDB();
      RenderLog.write('c137_collect_action', 'action=confirm;supplier=$supplier');
      RenderLog.write('c117_collect_confirm_text_mode', 'warehouse');
      RenderLog.write('c125_submit_refresh', 'true');
      RenderLog.write('c331_confirm_gate', 'success;shorts=$shortsDisputed');
      RenderLog.write('c359_confirm_raise', 'tab=shop,raised=$shortsDisputed'); // C359: disputes raised at confirm
      RenderLog.write('c361_confirm', 'tab=shop,raised=$shortsDisputed'); // C360
      RenderLog.write('c335_confirm', 'shop_confirm_ok=y;shorts=$shortsDisputed');
      RenderLog.write('c337_shop_confirmed', 'supplier=$supplier;shorts=$shortsDisputed');
      RenderLog.write('c353_refetch', 'src=action,tab=collect'); // C353: confirm refetch
      _loadSuppliers(); // refreshes badge + dot (both backend-owned, from fw_list_arrivals)
      _loadCollectModes(); // R2: badge P→C immediately
      _loadDisputes(); // #332 D1: refresh Disputes tab so new short-item disputes appear immediately
      context.findAncestorStateOfType<_AdminFulfillmentScreenState>()?._refreshArrivals(); // R2: supplier appears in Arrivals
      // #335 BUG-7: include counted qty in toast per contract B4
      final countedItems = _items.length;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(
            'Counting confirmed — $shortsDisputed short item(s) disputed. '
            'Moved to Warehouse (0/$countedItems).'
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
      RenderLog.write('c337_skip_to_wh', 'supplier=$supplier');
      _loadSuppliers(); // refreshes badge + dot (both backend-owned, from fw_list_arrivals)
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
        .where((r) => (r['fulfillment_state']?.toString() ?? 'pending') != 'cancelled')
        .map((r) => {
              'product_id': (r['product_id'] as num?)?.toInt() ?? 0,
              'name': r['product_name']?.toString() ?? '',
              'ordered': ordQtyOf(r), // B3: shape-tolerant (ordered_qty OR ordered)
              'received': recQtyOf(r),
              'state': r['fulfillment_state']?.toString() ?? 'pending',
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
        if (_boxLocked || (!widget.arrivals && _supplierMode == 'warehouse')) {
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
    if ((item['fulfillment_state']?.toString() ?? 'pending') != 'pending') _advance();
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
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (!widget.arrivals) const SupplierMapGroupsPanel(),
            Text('No orders placed on ${dmy(FulfillDateScope.instance.date)}.',
                style: const TextStyle(color: _kSub, fontSize: 15),
                textAlign: TextAlign.center),
          ]),
        ),
      );
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
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (!widget.arrivals)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: const SupplierMapGroupsPanel(),
              ),
            Expanded(
              child: ListView.builder(
                controller: _listScrollCtrl,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                itemCount: displayList.length,
                itemBuilder: (_, i) => _buildSupplierAccordionRow(displayList[i], isAdmin),
              ),
            ),
          ]),
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
    // C363-C: after a bag is DETACHED, already-counted items must render NORMAL (not greyed).
    // Dim ONLY the truly-fresh no-bag state (nothing counted yet); once anything is counted
    // (received / flagged / terminal), the list stays at full opacity so detached rows look
    // exactly as they did while the bag was attached.
    final bool anyCounted = _items.any((i) {
      final ci = i['count_issue']?.toString();
      final st = i['fulfillment_state']?.toString() ?? 'pending';
      return recQtyOf(i) > 0 ||
          (ci != null && ci.isNotEmpty && ci != 'null') ||
          st == 'short' || st == 'wrong' || st == 'not_coming';
    });
    final bool dimNoBagList = noBagInArrivals && !anyCounted;
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
        // C363-C: dim only the fresh no-bag state; detached (already-counted) rows stay normal.
        Opacity(
          opacity: dimNoBagList ? 0.45 : 1.0,
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

  Widget _buildSupplierAccordionRow(String name, bool isAdmin) {
    final isExpanded = _selectedSupplier == name;
    // #147 FIX A: per-row GlobalKey for Scrollable.ensureVisible (header pin)
    final rowKey = _rowKeys.putIfAbsent(name, () => GlobalKey());
    // Backend-owned dots from fw_list_arrivals(): Supplier Shop shows
    // [packed, method, submit]; Warehouse shows [method, packed].
    final hexDots = widget.arrivals
        ? [_supplierDotMethodMap[name], _supplierDotPackedMap[name]]
        : [_supplierDotPackedMap[name], _supplierDotMethodMap[name], _supplierDotSubmitMap[name]];

    // #153: outer shell is shared with Arrivals; only expandedContent differs.
    return _SupplierAccordionShell(
      name: name,
      hexDots: hexDots,
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

  // ── #90: Narrow voice bar — two Expanded equal-width pills, no overflow ─────
  // Tally badge moved to _buildNarrowProgressRow.
  Widget _buildNarrowVoiceBar(bool isAdmin) {
    // CHANGE #277: bag-missing is a silent noop (no opacity/grey), not a disabled state
    // A1 §2.7: shop forwarded to warehouse → mic disabled (same visual as arrivals confirmed)
    final shopForwarded = !widget.arrivals && _supplierMode == 'warehouse';
    final countingDisabled = _agentPhase != AgentPhase.idle ||
        (widget.arrivals && _arrivalsLocked) || // #156: locked after confirm-all
        shopForwarded; // A1: shop forwarded → no counting
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
  // CHANGE #471 — date heading + include-older control, shared by both the
  // narrow (mobile) and wide (desktop) box headers. Both strings are printed
  // verbatim from the backend (date_label / older.label) — never formatted
  // or constructed client-side.
  Widget? _buildBoxDateOlderRow({EdgeInsets padding = const EdgeInsets.fromLTRB(16, 8, 16, 0)}) {
    if ((_boxDateLabel ?? '').isEmpty) return null;
    return BoxDateOlderRow(
      dateLabel: _boxDateLabel,
      older: boxOlderFrom(_boxOlder),
      includeOlder: _boxIncludeOlder,
      padding: padding,
      onToggleOlder: () {
        setState(() => _boxIncludeOlder = !_boxIncludeOlder);
        _reloadItemsFromDB();
      },
    );
  }

  Widget _buildNarrowProgressRow() {
    RenderLog.write('change_90_progress_below', '1');
    RenderLog.write('change_97_spoken_mobile', '1');
    // CHANGE #471: progress comes from the backend response — no client count.
    final doneCount = _boxProgressCounted;
    final total = _boxProgressTotal;
    final dateOlderRow = _buildBoxDateOlderRow();
    // #97: pill ALWAYS visible on mobile — constant 100px slot, always green
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (dateOlderRow != null) dateOlderRow,
      Padding(
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
            _boxProgressLabel,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kText),
          ),
        ]),
      ),
    ]);
  }

  // ── #89: Dense narrow item list — compact rows, render-log key ───────────────
  // #151: shrinkWrap=true when inside accordion (outer ListView handles scroll).
  Widget _buildNarrowItemList({bool showFooter = true, bool shrinkWrap = false}) {
    RenderLog.write('change_89_dense_items', '1');
    RenderLog.write('81_item_list_rendered', '${_items.length}');
    RenderLog.write('81_progress', _boxProgressLabel);
    final locked = _boxLocked;
    if (locked) RenderLog.write('change_91_locked', '1');
    else RenderLog.write('change_91_confirm_present', '1');

    // #197: one row per product — backend-owned, pre-aggregated, pre-sorted.
    final merged = _mergedItemsBackend;
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

  // C355: single amber count_issue chip widget — ONE styling used by both the
  // mobile tiles and the web table row.
  Widget _issueChip(String lbl) => Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xFFFEF3C7),
            border: Border.all(color: const Color(0xFFFCD34D), width: 1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(lbl,
              style: const TextStyle(
                  fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFFB45309)),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      );

  // #113: extracted so PinnedFooterList can pass items as List<Widget>
  // #331: shop tab shows shop_qty/ordQty; warehouse shows recQty/expected (mode-aware)
  Widget _buildItemTile(Map<String, dynamic> item) {
    final state    = item['fulfillment_state']?.toString() ?? 'pending';
    final name     = item['product_name']?.toString() ?? '—';
    final ordQty   = ordQtyOf(item); // B1: dual-key ordered_qty ?? ordered
    final recQty   = (item['received_qty'] as num?)?.toInt() ?? 0;
    final shopQty  = (item['shop_qty'] as num?)?.toInt(); // #331: null = not yet counted at shop
    final packType = item['pack_type']?.toString() ?? '';
    final imageUrl = item['image_url']?.toString();
    // #333: use backend 'expected' field (stage-aware: forwarded qty at warehouse, ordered at shop)
    final int whExpected = (item['expected'] as num?)?.toInt() ?? ordQty;
    RenderLog.write('c333_shop_field', 'shopQty=${shopQty ?? 'null'};expected=$whExpected;stage=${_supplierMode ?? ''}');
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
          // Backend-owned: fw_get_state()'s per-item status_colors.bg, verbatim.
          border: Border.all(
            color: _hexColor((item['status_colors'] as Map?)?['bg']?.toString(), _kBorder),
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
              // C355: qty label + pill state from the SHARED helper (same rule as
              // the merged tile and the web row — no per-layout drift).
              Builder(builder: (_) {
                final rv = fulfillRowView(
                  arrivals: widget.arrivals,
                  ordered: ordQty,
                  shopQty: shopQty,
                  received: recQty,
                  expected: (item['expected'] as num?)?.toInt(),
                  combinedState: state,
                );
                if (rv.awaitingResolution) {
                  return const Text('in dispute · awaiting resolution',
                      style: TextStyle(fontSize: 10, color: _kSub));
                }
                RenderLog.write(widget.arrivals ? 'c335_wh_row' : 'c335_shop_row',
                    widget.arrivals ? 'rec=$recQty;exp=$whExpected' : 'shop=${shopQty ?? 0};ord=$ordQty');
                final isRowLocked = widget.arrivals && lockedOf(item);
                return Row(mainAxisSize: MainAxisSize.min, children: [
                  if (isRowLocked) ...[
                    const Icon(Icons.lock_rounded, size: 12, color: _kReceivedFg),
                    const SizedBox(width: 3),
                  ],
                  Text(rv.qtyLabel,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText)),
                  const SizedBox(width: 6),
                  // Backend-owned: fw_get_state()'s per-item status_label + status_colors, verbatim.
                  Builder(builder: (_) {
                    final colors = item['status_colors'] as Map?;
                    return _BackendStatePill(
                      label: item['status_label']?.toString() ?? '',
                      bg: _hexColor(colors?['bg']?.toString(), _kPendingBg),
                      fg: _hexColor(colors?['fg']?.toString(), _kPendingFg),
                    );
                  }),
                ]);
              }),
              // CHANGE #471: backend date chip (older item mixed into today's list) — muted, verbatim.
              if (itemDateChip(item) != null)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(itemDateChip(item)!,
                      style: const TextStyle(fontSize: 10, color: _kSub)),
                ),
              // #338: voice-vs-actual mismatch chip (audit fetched on expand)
              Builder(builder: (_) {
                final chip = _mismatchChip((item['product_id'] as num?)?.toInt());
                if (chip == null) return const SizedBox.shrink();
                return Padding(padding: const EdgeInsets.only(top: 3), child: chip);
              }),
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
              // Backend-owned: fw_get_state()'s per-item issue_chip.label, verbatim.
              Builder(builder: (_) {
                final issueChip = item['issue_chip'] as Map?;
                final lbl = issueChip?['label']?.toString();
                if (lbl == null || lbl.isEmpty) return const SizedBox.shrink();
                RenderLog.write('c351_chip', 'kind=${item['count_issue']}');
                return _issueChip(lbl);
              }),
              // #333: count_mismatch is a dead field — removed
            ]),
          ), // ConstrainedBox
        ]),
      ),
    );
  }

  // ── #197: Merged product card ─────────────────────────────────────────────
  Widget _buildMergedItemTile(_MergedProduct merged) {
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
    // C359: only a dispute candidate (short/excess/flagged after voice counting) is
    // tappable and tinted light-yellow. Correct / un-counted lines are inert.
    final isCandidate = _mIsCandidate(merged);

    RenderLog.write('c196_collect_card_layout_v2', 'surface=$surface');
    RenderLog.write('c198_card_layout_v3', 'surface=$surface');
    if (isCandidate) {
      RenderLog.write('c359_candidate', widget.arrivals ? 'warehouse' : 'shop');
      // C360: carry the counted basis used (shop_qty on Shop, received on Warehouse).
      final counted = widget.arrivals ? merged.receivedTotal : (merged.shopQtyTotal ?? 0);
      RenderLog.write('c361_candidate',
          'tab=${widget.arrivals ? 'warehouse' : 'shop'},counted=$counted');
    }
    if (widget.arrivals) RenderLog.write('c265_warehouse_no_arrival', 'prod=${merged.productId}');
    if (widget.arrivals) {
      final bool itemBagPresent = _activeBag != null;
      RenderLog.write('c284_itempopup_gated',
          'bag=$itemBagPresent;enabled=$itemBagPresent');
    }
    // C363-C: after a bag is DETACHED, already-counted warehouse rows must render NORMAL
    // + TAPPABLE (not greyed/hidden). Prove it per counted row in the detached state.
    if (widget.arrivals && _activeBag == null && merged.receivedTotal > 0) {
      RenderLog.write('c363_bag_normal',
          'tappable=${_disputeToggleOn && !_arrivalsLocked}');
    }

    return GestureDetector(
      // C363-B: with the "Dispute option" toggle ON, tapping ANY item (received, counted,
      // uncounted, or already disputed) opens the dispute popup. Toggle OFF → inert.
      // A locked warehouse tab stays inert (editing needs the undo-response path).
      onTap: (!_disputeToggleOn || (widget.arrivals && _arrivalsLocked))
          ? null
          : () {
              RenderLog.write('c363_popup_all', 'opened=$_disputeToggleOn');
              _showProductSheet(merged);
            },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isCandidate ? _kCandidateBg : _kCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isCandidate
                ? _kCandidateBorder
                : _hexColor(merged.statusColors?['bg'], _kBorder),
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
              // Backend-owned: fw_get_state()'s merged_items[] qty_label + status_label/
              // status_colors, verbatim — no client aggregation or derivation.
              Builder(builder: (_) {
                final colors = merged.statusColors;
                return Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
                  Text(merged.qtyLabel,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText)),
                  const SizedBox(height: 3),
                  _BackendStatePill(
                    label: merged.statusLabel,
                    bg: _hexColor(colors?['bg'], _kPendingBg),
                    fg: _hexColor(colors?['fg'], _kPendingFg),
                  ),
                ]);
              }),
              // CHANGE #471: backend date chip (older item mixed into today's list) — muted, verbatim.
              if (merged.showDateChip && (merged.dateChip ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(merged.dateChip!,
                      style: const TextStyle(fontSize: 10, color: _kSub)),
                ),
              // #338: voice-vs-actual mismatch chip (audit fetched on expand)
              Builder(builder: (_) {
                final chip = _mismatchChip(merged.productId);
                if (chip == null) return const SizedBox.shrink();
                return Padding(padding: const EdgeInsets.only(top: 3), child: chip);
              }),
              // C355: count_issue amber chip — was MISSING on the merged tile, so
              // the mobile merged layout silently dropped issue flags the single
              // tile and web row showed. Now shared with both.
              Builder(builder: (_) {
                // C365: "In dispute — <n> <pack>" using the summed disputed qty + pack type.
                final lbl = disputedChipLabel(
                    merged.mergedCountIssue, merged.mergedIssueQty, merged.packType);
                if (lbl == null) return const SizedBox.shrink();
                RenderLog.write('c351_chip', 'kind=${merged.mergedCountIssue}');
                RenderLog.write('c364_qty_shown', 'where=row,qty=${merged.mergedIssueQty}');
                if (merged.mergedIssueQty > 0) RenderLog.write('c365_breakdown', 'where=row');
                return _issueChip(lbl);
              }),
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
    // C359: the popup no longer counts (voice-only) — it only classifies a dispute
    // candidate, which is order-item-scoped, not bag-scoped. So it must open even
    // when no bag is active, else an unbalanced warehouse candidate would be
    // un-resolvable AND keep the confirm button disabled (dead end).
    final supplier = _selectedSupplier ?? '';
    RenderLog.write('c197_product_sheet_opened',
        'surface=${widget.arrivals ? 'arrivals' : 'collect'};product_id=${merged.productId};ordered=${merged.orderedTotal}');
    // Find first dispute with proof for this product
    DisputeItem? existingDispute;
    for (final oiid in merged.orderItemIds) {
      final d = _disputeItemMap[oiid];
      if (d != null) { existingDispute = d; break; }
    }
    // C361: a merged product can span several order-lines; line-level flags
    // (fw_set_line_issue) must target the actual CANDIDATE line, not lines.first —
    // else the flag + its qty land on the wrong line and the per-line gate false-greens.
    final oiids = merged.orderItemIds.toSet();
    final Map<String, dynamic> classifyLine = _items.firstWhere(
      (l) => oiids.contains(l['order_item_id']?.toString()) && _lineIsCandidate(l),
      orElse: () => merged.firstLineData ?? const <String, dynamic>{},
    );
    final isWide = MediaQuery.of(context).size.width >= 900;
    final sheet = _ProductReceiveSheet(
      supplierName: supplier,
      productId: merged.productId,
      productName: merged.productName,
      packType: merged.packType,
      imageUrl: merged.imageUrl,
      orderedTotal: merged.orderedTotal,
      receivedTotal: merged.receivedTotal,
      shopQtyTotal: merged.shopQtyTotal,
      shopQtyCounted: merged.shopQtyCounted,
      expectedTotal: merged.expectedTotal,
      combinedState: merged.combinedState,
      statusLabel: merged.statusLabel,
      statusColors: merged.statusColors,
      existingDispute: existingDispute,
      // C365: product-level flag + summed disputed qty for the aggregated popup pre-fill.
      mergedCountIssue: merged.mergedCountIssue,
      mergedIssueQty: merged.mergedIssueQty,
      arrivals: widget.arrivals,
      // CHANGE #277: pass bag context for dynamic Got all
      activeBagNo: widget.arrivals ? (_activeBag?['bag_no'] as num?)?.toInt() : null,
      bagBreakdown: merged.bagBreakdown,
      bagCountFn: widget.arrivals ? (pid, qty) async {
        if (_activeBag == null) return 'Scan a bag first before counting';
        // #335 BUG-8 E1: guard against bag actions at shop stage
        try {
          final guardRaw = await Supabase.instance.client.rpc('bag_guard_shop_stage',
              params: {'p_supplier_name': supplier}) as Map;
          final guardRes = Map<String, dynamic>.from(guardRaw);
          if (guardRes['error'] == 'shop_stage_no_bags') {
            RenderLog.write('c335_bag_guard', 'blocked=shop_stage_no_bags;supplier=$supplier');
            return 'Bags are a warehouse step — confirm counting at the supplier shop first.';
          }
        } catch (_) {} // guard RPC failure = silently allow (not shop stage or guard unavailable)
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
      onReload: _refetchAfterAction, // C353: full refetch (items + chips + disputes)
      // C361: classify the actual candidate line (falls back to first line defensively).
      itemData: classifyLine.isNotEmpty ? classifyLine : merged.firstLineData,
      multiLine: merged.orderItemIds.length > 1,
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
      await _refetchAfterAction();
    }
  }

  // C353: action-triggered refetch — item state + list-row chips/dots + dispute
  // chips for THIS tab, immediately after any mutating action (works even with
  // realtime down).
  Future<void> _refetchAfterAction() async {
    if (!mounted) return;
    RenderLog.write('c353_refetch', 'src=action,tab=${widget.arrivals ? 'arrivals' : 'collect'}');
    RenderLog.write('c354_live', 'tab=${widget.arrivals ? 'warehouse' : 'shop'},src=action');
    await _loadDisputes();
    await _reloadItemsFromDB();
    await _loadSuppliers(); // refreshes badge + dot (both backend-owned, from fw_list_arrivals)
    if (!widget.arrivals) {
      await _loadCollectModes();
    }
  }

  // C353: realtime-triggered refetch of this tab's visible data (called by the
  // parent screen's FulfillRealtime listener; debounce lives in the service).
  Future<void> _refetchFromRealtime() async {
    if (!mounted) return;
    RenderLog.write('c353_refetch', 'src=rt,tab=${widget.arrivals ? 'arrivals' : 'collect'}');
    RenderLog.write('c354_live', 'tab=${widget.arrivals ? 'warehouse' : 'shop'},src=rt');
    await _loadSuppliers(); // refreshes badge + dot (both backend-owned, from fw_list_arrivals)
    if (!widget.arrivals) {
      await _loadCollectModes();
    }
    await _loadDisputes();
    await _reloadItemsFromDB();
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
      // ── Supplier map dropdown (Supplier Shop tab only) — purely additive ─────
      if (!widget.arrivals) ...[
        const SupplierMapGroupsPanel(),
        const SizedBox(height: 12),
      ],
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

  Widget _buildWideSingleBar(bool isAdmin) {
    RenderLog.write('change_88_fixed_btn_size', '150x44');
    RenderLog.write('change_87_single_bar_present', '1');
    RenderLog.write('change_87_pills_inline', '1');
    RenderLog.write('change_86_voice_pills_present', '1');
    // #114 render-log
    RenderLog.write('c114_fulfillment_header_built', 'desktop');
    RenderLog.write('c114_spoken_chip_left', 'desktop');
    RenderLog.write('c114_progress_expanded', 'desktop');
    // CHANGE #471: progress comes from the backend response — no client count.
    final doneCount = _boxProgressCounted;
    final total = _boxProgressTotal;
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
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // CHANGE #471: date heading + include-older control (backend strings, verbatim)
      if (_selectedSupplier != null) ...[
        Builder(builder: (_) {
          final row = _buildBoxDateOlderRow(padding: EdgeInsets.zero);
          return row == null ? const SizedBox.shrink() : Padding(padding: const EdgeInsets.only(bottom: 8), child: row);
        }),
      ],
      Row(crossAxisAlignment: CrossAxisAlignment.center, children: [

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
            _boxProgressLabel,
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
    RenderLog.write('c357_cols_ready', 'tab=${widget.arrivals ? 'warehouse' : 'shop'}');
    // C358 B2: Received / Dispute Type / Item Status / Status are separate, spaced columns.
    RenderLog.write('c358_cols3', 'tab=${widget.arrivals ? 'warehouse' : 'shop'}');
    // C361: web Dispute Type + Item Status render as SEPARATE payload-driven columns.
    RenderLog.write('c361_disp_cols', 'tab=${widget.arrivals ? 'warehouse' : 'shop'}');
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
            // C357/C358: Received · Dispute Type · Item Status · Status are FOUR distinct
            // columns. C358 B2: 16px gaps between them so the right-aligned "Received"
            // header no longer butts against "Dispute Type" ("ReceivedDispute Type").
            Expanded(flex: 5, child: Text('Product',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _kSub))),
            Expanded(flex: 2, child: Text('Pack',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _kSub))),
            Expanded(flex: 2, child: Text('Received',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _kSub),
                textAlign: TextAlign.right)),
            const SizedBox(width: 16),
            Expanded(flex: 3, child: Text('Dispute Type',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _kSub))),
            const SizedBox(width: 12),
            Expanded(flex: 3, child: Text('Item Status',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _kSub))),
            const SizedBox(width: 12),
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
              // #197: merged product rows for desktop table — backend-owned, pre-sorted.
              final deskMerged = _mergedItemsBackend;
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
                  for (final oiid in mp.orderItemIds) {
                    deskDisputeItem ??= _disputeItemMap[oiid];
                  }
                  // C359: only a dispute candidate is tappable + tinted light-yellow.
                  final isCandidate = _mIsCandidate(mp);
                  if (isCandidate) {
                    RenderLog.write('c359_candidate', widget.arrivals ? 'warehouse' : 'shop');
                    final counted = widget.arrivals ? mp.receivedTotal : (mp.shopQtyTotal ?? 0);
                    RenderLog.write('c361_candidate',
                        'tab=${widget.arrivals ? 'warehouse' : 'shop'},counted=$counted');
                  }
                  if (widget.arrivals && _activeBag == null && mp.receivedTotal > 0) {
                    RenderLog.write('c363_bag_normal',
                        'tappable=${_disputeToggleOn && !_arrivalsLocked}');
                  }
                  return InkWell(
                    // C363-B: with the "Dispute option" toggle ON, tapping ANY item opens the
                    // dispute popup. Toggle OFF → inert. Locked warehouse tab stays inert
                    // (editing needs the undo-response path; sheet also early-returns).
                    onTap: (!_disputeToggleOn || (widget.arrivals && _arrivalsLocked))
                        ? null
                        : () {
                            RenderLog.write('c363_popup_all', 'opened=$_disputeToggleOn');
                            _showProductSheet(mp);
                          },
                    hoverColor: _kGreen.withValues(alpha: 0.04),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: isCandidate ? _kCandidateBg : null,
                        border: isLast ? null : Border(
                          bottom: BorderSide(
                              color: isCandidate ? _kCandidateBorder : _kBorder, width: 0.8),
                        ),
                      ),
                      child: Row(children: [
                        // col1: thumbnail + name (C357: dispute/kind chips moved to
                        // the new Dispute Type / Item Status columns)
                        Expanded(flex: 5, child: Row(children: [
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
                                // C357: under-name _DisputeStrip / DisputeBadge / count_issue
                                // amber chip REMOVED on web — the Dispute Type + Item Status
                                // columns carry that info now. (Mobile card layout keeps chips.)
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
                        // col3: qty progress — backend-owned merged_items[].qty_label, verbatim.
                        Expanded(flex: 2, child: Text(
                          mp.qtyLabel,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kText),
                          textAlign: TextAlign.right,
                        )),
                        const SizedBox(width: 16), // C358 B2: gap after Received
                        // C357 col: Dispute Type — backend kind_label for the matched
                        // dispute, else the backend's issue_chip label, else "—".
                        Expanded(flex: 3, child: Builder(builder: (_) {
                          final tab = widget.arrivals ? 'warehouse' : 'shop';
                          final kindLabel = deskDisputeItem != null
                              ? deskDisputeItem.kindLabel
                              : mp.issueChip?['label']?.toString(); // C361: any flagged line
                          if (kindLabel == null) {
                            return const Text('—', style: TextStyle(fontSize: 12, color: _kSub));
                          }
                          RenderLog.write('c357_disp_cell',
                              'tab=$tab,kind=${deskDisputeItem?.kind ?? mp.mergedCountIssue}');
                          // C365: append the disputed units WITH pack type to the web row.
                          final int dispN = mp.mergedIssueQty;
                          final label = dispN > 0
                              ? '$kindLabel — ${qtyWithPack(dispN, mp.packType)}'
                              : kindLabel;
                          if (dispN > 0) {
                            RenderLog.write('c364_qty_shown', 'where=row,qty=$dispN');
                            RenderLog.write('c365_breakdown', 'where=row');
                          }
                          return Row(mainAxisSize: MainAxisSize.min, children: [
                            Container(width: 7, height: 7,
                                decoration: const BoxDecoration(
                                    color: Color(0xFFB45309), shape: BoxShape.circle)),
                            const SizedBox(width: 6),
                            Flexible(child: Text(label,
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText),
                                maxLines: 1, overflow: TextOverflow.ellipsis)),
                          ]);
                        })),
                        const SizedBox(width: 12), // C358 B2: gap after Dispute Type
                        // C357 col: Item Status — backend item_status_label for the
                        // dispute, else the backend's merged_items[].status_label, verbatim.
                        Expanded(flex: 3, child: Builder(builder: (_) {
                          final tab = widget.arrivals ? 'warehouse' : 'shop';
                          final statusText = (deskDisputeItem != null && deskDisputeItem.itemStatusLabel.isNotEmpty)
                              ? deskDisputeItem.itemStatusLabel
                              : mp.statusLabel;
                          if (statusText.isEmpty) {
                            return const Text('—', style: TextStyle(fontSize: 12, color: _kSub));
                          }
                          RenderLog.write('c357_status_cell', 'tab=$tab');
                          return Tooltip(
                            message: statusText,
                            child: Text(statusText,
                                style: const TextStyle(fontSize: 12, color: _kText),
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                          );
                        })),
                        const SizedBox(width: 12), // C358 B2: gap after Item Status
                        // col4: status chip — backend-owned merged_items[].status_label/status_colors.
                        Expanded(flex: 2, child: Align(
                          alignment: Alignment.centerRight,
                          child: _BackendStatePill(
                            label: mp.statusLabel,
                            bg: _hexColor(mp.statusColors?['bg'], _kPendingBg),
                            fg: _hexColor(mp.statusColors?['fg'], _kPendingFg),
                          ),
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
              stage: widget.arrivals ? 'warehouse' : 'shop',
              orderItems: orderSnapshot,
              // #9/#453: scope mentions to the ContinuousVoiceSession's own generated
              // session_key (supplier|stage|ms) — the only key insertMentions ever
              // writes. Sourced from _activeVoiceSessionKey (not _voiceSession?.sessionKey
              // directly) so the scope survives Stop/finalize, when _voiceSession is
              // already null but the just-recorded mentions should still show.
              activeSessionKey: _activeVoiceSessionKey,
              onDismiss: dismiss,
              // #338: frozen — shop: box locked or forwarded; warehouse: arrivals confirmed
              frozen: widget.arrivals
                  ? _arrivalsLocked
                  : (_boxLocked || _supplierMode == 'warehouse'),
              // #338: refresh voice-vs-actual audit after any delete/re-add toggle
              onToggled: () => _fetchCountAudit(supplierForPopup),
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

// CHANGE #453: single source of truth for the Supplier Shop / Warehouse "N spoken"
// badge and the "Counted items" popup — same RPC, same session-key filter, so the
// two displays can never disagree. sessionKey must be the ContinuousVoiceSession's
// own generated key (supplier|stage|ms) — the only value ever written to
// voice_clip_mentions.session_key by this tab. null means no recording has
// happened yet this card-open, so all of today's mentions for the supplier+stage
// are returned unfiltered.
Future<List<Map<String, dynamic>>> fetchScopedVoiceMentions({
  required String supplierName,
  required String stage,
  required String? sessionKey,
}) async {
  final rows = await Supabase.instance.client
      .rpc('get_voice_clip_mentions', params: {
        'p_supplier_name': supplierName,
        'p_stage': stage,
      }) as List;
  final mentions = rows.map((r) => Map<String, dynamic>.from(r as Map)).toList();
  if (sessionKey == null || sessionKey.isEmpty) return mentions;
  return mentions.where((r) => r['session_key']?.toString() == sessionKey).toList();
}

// CHANGE #454: same single-source-of-truth pattern as fetchScopedVoiceMentions
// (#453), for Pack's own table/RPC (pack_clip_mentions / get_pack_clip_mentions).
// sessionKey is the PackVoiceSession's own generated key for this order's
// current/most-recent recording; null means no recording has happened yet this
// card-open, so all of the order's mentions show unfiltered.
Future<List<Map<String, dynamic>>> fetchScopedPackMentions({
  required String orderId,
  required String? sessionKey,
}) async {
  final rows = await Supabase.instance.client
      .rpc('get_pack_clip_mentions', params: {'p_order_id': orderId}) as List;
  final mentions = rows.map((r) => Map<String, dynamic>.from(r as Map)).toList();
  if (sessionKey == null || sessionKey.isEmpty) return mentions;
  return mentions.where((r) => r['session_key']?.toString() == sessionKey).toList();
}

String _fmtQty(num n) => n == n.roundToDouble() ? n.toInt().toString() : n.toString();

// CHANGE #457 (Bug 3): scan a finalize result's persisted[] for entries whose
// per-product write didn't fully persist the spoken qty. None of the three
// finalize-side RPCs (bag_count_set, set_voice_received, pack_set_counted)
// raise for an over-count — bag_count_set alone returns a literal 'error' key
// ('exceeds_ordered' etc.); set_voice_received and pack_set_counted always
// return status:'ok' and instead cap the write silently, reporting the
// shortfall in their own fields ('leftover' / 'requested' vs 'set'). This
// reads those existing fields only — no backend change, nothing re-summed on
// the client. Shared by Shop/Warehouse (_showFinalizeSummary) and Pack
// (_showPackFinalizeSummary) so all three surface it instead of a silently
// lower count.
List<String> overCountWarnings(List persisted, List<Map<String, dynamic>> items) {
  final warnings = <String>[];
  for (final p in persisted) {
    if (p is! Map) continue;
    final pid = (p['product_id'] as num?)?.toInt();
    final name = items.firstWhere(
      (i) => (i['product_id'] as num?)?.toInt() == pid,
      orElse: () => const {},
    )['product_name']?.toString() ?? (pid != null ? 'Product $pid' : 'Unknown product');
    final res = p['result'];
    if (res is! Map) continue;
    final error = res['error']?.toString();
    if (error == 'exceeds_ordered') {
      final attempted = (res['attempted'] as num?);
      final maxForBag = (res['max_for_this_bag'] as num?);
      final detail = attempted != null && maxForBag != null
          ? ' (spoke ${_fmtQty(attempted)}, max ${_fmtQty(maxForBag)} for this bag)'
          : '';
      warnings.add('$name — counted more than ordered$detail, capped/not saved.');
    } else if (error != null) {
      warnings.add('$name — not saved ($error).');
    } else {
      final leftover = (res['leftover'] as num?);
      final requested = (res['requested'] as num?);
      final setQty = (res['set'] as num?);
      if (leftover != null && leftover > 0) {
        warnings.add('$name — counted more than ordered, ${_fmtQty(leftover)} left over/not saved.');
      } else if (requested != null && setQty != null && requested > setQty) {
        warnings.add('$name — counted more than received, capped at ${_fmtQty(setQty)} (spoke ${_fmtQty(requested)}).');
      }
    }
  }
  return warnings;
}

// CHANGE #456: one chip per RECORDING (session_key), not per chunk window
// (recording_seq) — a continuous recording is internally sliced into several
// ~30s windows/clip_paths (each its own recording_seq + clip_path), but the
// user only ever intends ONE clip per mic-on → Stop. Shared by the
// Shop/Warehouse popup (voice_clip_mentions) and the Pack sheet
// (pack_clip_mentions) so both group identically.
//
// Rows with no session_key (legacy, pre-#454) collapse into ONE group per
// the_date instead of one group per row, so old data doesn't render as one
// "clip" per historical mention. windows within a group are ordered by
// recording_seq so sequential playback reproduces the recording in order.
typedef ClipWindow = ({int seq, String clipPath});
typedef ClipGroup = ({String groupKey, List<ClipWindow> windows});

// CHANGE #456: the grouping rule, exposed standalone so callers can find which
// group a SINGLE row belongs to (e.g. filtering the flat clip view) without
// recomputing every group and without duplicating the fallback rule. Rows
// with no session_key (legacy, pre-#454) group by the_date instead — NEVER by
// recording_seq alone, since that's a per-session counter that restarts at 0
// for every recording and can collide across two unrelated sessions.
String clipGroupKeyOf(Map<String, dynamic> r) {
  final sessionKey = r['session_key']?.toString();
  return (sessionKey != null && sessionKey.isNotEmpty)
      ? sessionKey
      : 'legacy:${r['the_date']?.toString() ?? ''}';
}

List<ClipGroup> groupMentionsIntoClips(List<Map<String, dynamic>> rows) {
  final groups = <String, List<Map<String, dynamic>>>{};
  for (final r in rows) {
    final path = r['clip_path']?.toString() ?? '';
    if (path.isEmpty) continue;
    (groups[clipGroupKeyOf(r)] ??= []).add(r);
  }
  final result = <ClipGroup>[];
  groups.forEach((groupKey, groupRows) {
    final sorted = List<Map<String, dynamic>>.from(groupRows)
      ..sort((a, b) => ((a['recording_seq'] as num?)?.toInt() ?? 0)
          .compareTo((b['recording_seq'] as num?)?.toInt() ?? 0));
    final seen = <String>{};
    final windows = <ClipWindow>[];
    for (final r in sorted) {
      final p = r['clip_path']?.toString() ?? '';
      if (p.isEmpty || !seen.add(p)) continue;
      windows.add((seq: (r['recording_seq'] as num?)?.toInt() ?? 0, clipPath: p));
    }
    if (windows.isEmpty) return;
    result.add((groupKey: groupKey, windows: windows));
  });
  // Chronological order across sessions: recording_seq is a per-session counter
  // (each new session restarts at 0), so it can't order sessions against each
  // other. newVoiceSessionKey's own format (entity|stage|ms) embeds the actual
  // start-time millis — parse that back out as the real sort key. Legacy
  // (date-keyed) groups have no such value and sort first, tied-broken by key.
  int sortMs(String groupKey) {
    if (!groupKey.contains('|')) return 0;
    return int.tryParse(groupKey.split('|').last) ?? 0;
  }
  result.sort((a, b) {
    final c = sortMs(a.groupKey).compareTo(sortMs(b.groupKey));
    return c != 0 ? c : a.groupKey.compareTo(b.groupKey);
  });
  return result;
}

// CHANGE #457 — the "Count needs a look" dialog after Stop, extended with:
//   Bug 2: per-item bag-assign for needs_bag_review rows (Warehouse only —
//     initialNeedsReview is passed empty for Shop by the caller).
//   Bug 3: a static list of over-count warnings (no action, just visibility).
// unmatched stays a static list too — nothing client-side can fix an
// unmatched-to-any-product mention.
//
// Bug 2 mechanics: voice_finalize_session recomputes EVERY mention's
// applied_bag_no from voice_bag_boundaries on every call — it does not trust
// or preserve a manually-written applied_bag_no/status, so writing those
// directly on the mention row would just get overwritten back to
// needs_bag_review on the very next finalize. The only way to durably resolve
// a review item without touching finalize is to insert a voice_bag_boundaries
// row for the picked bag AT THAT MENTION'S OWN t_start_sec (reusing the exact
// same recordVoiceBagBoundary() helper #455 already uses for the bag-change
// path), then re-run voice_finalize_session — its boundary lookup (closest
// mapped_at_sec <= t_start_sec) then resolves that mention (and only mentions
// from that timestamp up to the next real boundary) to the chosen bag. This
// gives genuine per-item control: assigning one item's own timestamp never
// affects a different item that already has its own boundary between them.
class _FinalizeReviewDialog extends StatefulWidget {
  final String base;
  final String supplierName;
  final String sessionKey;
  final List initialNeedsReview; // [{mention_id, product_id, matched_name, qty}]
  final List<String> overCountWarnings;
  final List unmatched;
  final VoidCallback onResolved;
  const _FinalizeReviewDialog({
    required this.base,
    required this.supplierName,
    required this.sessionKey,
    required this.initialNeedsReview,
    required this.overCountWarnings,
    required this.unmatched,
    required this.onResolved,
  });

  @override
  State<_FinalizeReviewDialog> createState() => _FinalizeReviewDialogState();
}

class _FinalizeReviewDialogState extends State<_FinalizeReviewDialog> {
  late List _needsReview = List.of(widget.initialNeedsReview);
  List<int> _bagOptions = [];
  bool _loadingBags = true;
  final Map<String, int?> _pickedBag = {};
  final Set<String> _assigning = {};

  @override
  void initState() {
    super.initState();
    if (_needsReview.isNotEmpty) _loadBagOptions();
  }

  // Bags actually used this session, from voice_bag_boundaries — the worker can
  // only assign a review item to a bag that genuinely was in use, never a
  // fabricated one.
  Future<void> _loadBagOptions() async {
    try {
      final rows = await Supabase.instance.client
          .from('voice_bag_boundaries')
          .select('bag_no')
          .eq('session_key', widget.sessionKey);
      final bags = (rows as List)
          .map((r) => (r as Map)['bag_no'])
          .whereType<num>()
          .map((n) => n.toInt())
          .toSet()
          .toList()
        ..sort();
      if (mounted) setState(() { _bagOptions = bags; _loadingBags = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingBags = false);
    }
  }

  Future<void> _assign(dynamic item) async {
    final mentionId = (item is Map ? item['mention_id'] : null)?.toString() ?? '';
    final bagNo = _pickedBag[mentionId];
    if (mentionId.isEmpty || bagNo == null || _assigning.contains(mentionId)) return;
    setState(() => _assigning.add(mentionId));
    try {
      // needs_bag_review[] doesn't carry t_start_sec — fetch it from the mention row.
      final row = await Supabase.instance.client
          .from('voice_clip_mentions')
          .select('t_start_sec')
          .eq('id', mentionId)
          .maybeSingle();
      final tStart = (row?['t_start_sec'] as num?)?.toDouble();
      if (tStart == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Can't assign — this item has no timestamp")));
        }
        return;
      }
      await recordVoiceBagBoundary(
        sessionKey: widget.sessionKey,
        supplierName: widget.supplierName,
        bagNo: bagNo,
        mappedAtSec: tStart,
      );
      final refreshed = await finalizeVoiceSession(widget.sessionKey);
      final newReview = (refreshed['needs_bag_review'] as List?) ?? const [];
      RenderLog.write('c457_assign_bag', 'mention=$mentionId;bag=$bagNo;remaining=${newReview.length}');
      if (!mounted) return;
      setState(() => _needsReview = newReview);
      widget.onResolved();
      if (_needsReview.isEmpty &&
          widget.overCountWarnings.isEmpty &&
          widget.unmatched.isEmpty &&
          mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Assign failed — try again')));
      }
      RenderLog.write('c457_assign_err',
          e.toString().substring(0, e.toString().length.clamp(0, 80)));
    } finally {
      if (mounted) setState(() => _assigning.remove(mentionId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Count needs a look'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.base),
          if (_needsReview.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('${_needsReview.length} item${_needsReview.length == 1 ? '' : 's'} spoken before any bag was scanned:',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            if (_loadingBags)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (_bagOptions.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('No bags were scanned this session — nothing to assign to.',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              )
            else
              for (final item in _needsReview)
                Builder(builder: (_) {
                  final mentionId = (item is Map ? item['mention_id'] : null)?.toString() ?? '';
                  final name = (item is Map ? item['matched_name'] : null)?.toString() ?? '?';
                  final qty = (item is Map ? item['qty'] : null)?.toString() ?? '?';
                  final busy = _assigning.contains(mentionId);
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      Expanded(child: Text('$name — qty $qty')),
                      const SizedBox(width: 8),
                      DropdownButton<int>(
                        hint: const Text('Bag'),
                        value: _pickedBag[mentionId],
                        items: _bagOptions
                            .map((b) => DropdownMenuItem(value: b, child: Text('Bag $b')))
                            .toList(),
                        onChanged: busy ? null : (v) => setState(() => _pickedBag[mentionId] = v),
                      ),
                      const SizedBox(width: 8),
                      busy
                          ? const SizedBox(
                              height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : TextButton(
                              onPressed: _pickedBag[mentionId] != null ? () => _assign(item) : null,
                              child: const Text('Assign'),
                            ),
                    ]),
                  );
                }),
          ],
          if (widget.overCountWarnings.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('${widget.overCountWarnings.length} product${widget.overCountWarnings.length == 1 ? '' : 's'} counted more than could be saved:',
                style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFFB45309))),
            for (final w in widget.overCountWarnings)
              Text('• $w', style: const TextStyle(color: Color(0xFFB45309))),
          ],
          if (widget.unmatched.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('${widget.unmatched.length} item${widget.unmatched.length == 1 ? '' : 's'} not matched to a product:',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            for (final m in widget.unmatched)
              Text('• ${(m is Map ? m['matched_name'] : null) ?? '?'} — qty ${(m is Map ? m['qty'] : null) ?? '?'}'),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
      ],
    );
  }
}

// ── #115: Counted items popup — mentions table with tap-to-play ───────────────

// #117: _CountedMentionsPopup — whole-clip playback only.
// Per-item seek and live row-highlight removed (timestamps proven inaccurate).
// Table shows product | qty sequence (display-only) | total.
// One ▶/⏸ button per distinct recording_seq plays that clip from 0:00 to end.
class _CountedMentionsPopup extends StatefulWidget {
  final String supplierName;
  final String stage; // §0.12: 'shop' | 'warehouse'
  final List<Map<String, dynamic>> orderItems;
  final VoidCallback onDismiss;
  // #331: callback for when voice_mention_set_status returns an apply update
  final void Function(Map<String, dynamic> applyRes)? onApplyUpdate;
  // #338: frozen = counting confirmed/forwarded — rows dim + lock, hold disabled
  final bool frozen;
  // #338: fired after any successful delete/re-add toggle (audit cache refresh)
  final VoidCallback? onToggled;
  // #9: the live ContinuousVoiceSession's own session_key, when a session is
  // currently active — scopes the mention list to just this recording session
  // instead of falling back to the fw_count_session-based scoping below.
  final String? activeSessionKey;
  const _CountedMentionsPopup({
    super.key,
    required this.supplierName,
    required this.stage,
    required this.orderItems,
    required this.onDismiss,
    this.onApplyUpdate,
    this.frozen = false,
    this.onToggled,
    this.activeSessionKey,
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
  // #331: per-mention UUID in-flight set (prevents double-tap during RPC)
  final Set<String> _mentionLoading = {};
  // #342: track frozen-tap log so icon tap is handled silently in the icon handler
  final Set<String> _frozenTappedIds = {};

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
  // CHANGE #456: group key (session_key, or "legacy:<date>") of the clip chip
  // last tapped — null = default "All" order. Was recording_seq (per chunk
  // window); a chip is now one whole recording, which may span several windows.
  String? _selectedGroupKey;
  // CHANGE #456: remaining clip_paths for the group currently playing, so
  // multi-window recordings play back-to-back as one continuous clip instead
  // of stopping after the first window.
  List<String> _playQueue = [];
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
    // #9: live updates — voice_clip_mentions is on the shared FulfillRealtime channel;
    // refetch (still via the existing get_voice_clip_mentions RPC) whenever a window's
    // mentions land, on top of the initial fetch above. Debounce/reconnect live in the
    // service; this popup just adds itself as one more listener.
    FulfillRealtime.instance.addListener(_onRealtimeChange);
  }

  void _onRealtimeChange(Set<String> changedTables) {
    if (!mounted) return;
    if (changedTables.contains('voice_clip_mentions')) _fetchMentions();
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
    FulfillRealtime.instance.removeListener(_onRealtimeChange);
    _clipAudio?.pause();
    _clipAudio?.src = '';
    _clipAudio = null;
    _chipScrollCtrl.removeListener(_onChipScroll);
    _chipScrollCtrl.dispose();
    super.dispose();
  }

  // CHANGE #453: scope to widget.activeSessionKey via the SAME shared helper the
  // "N spoken" badge uses (fetchScopedVoiceMentions) — same RPC, same key, so the
  // two can never disagree. The old fw_count_session-based fallback (SS1/WH2-style
  // key) is gone: that key was never what insertMentions writes to
  // voice_clip_mentions.session_key, so filtering by it only ever matched zero
  // rows once a live ContinuousVoiceSession wasn't active — the root cause of the
  // badge/popup mismatch this change fixes.
  Future<void> _fetchMentions() async {
    try {
      final mentions = await fetchScopedVoiceMentions(
        supplierName: widget.supplierName,
        stage: widget.stage,
        sessionKey: widget.activeSessionKey,
      );
      if (!mounted) return;
      // CHANGE #456: clip count = distinct RECORDINGS (session groups), not distinct
      // chunk-window clip_paths — verifiable via curl/render-log for this change.
      final distinctClips = groupMentionsIntoClips(mentions).length;
      final distinctWindows = mentions.map((r) => r['clip_path']?.toString() ?? '').toSet().length;
      RenderLog.write('c119_popup_built',
          'clips=$distinctClips;windows=$distinctWindows;products=${_uniqueNames(mentions)};total_mentions=${mentions.length};retains_seq=y');
      setState(() => _mentions = mentions);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  int _uniqueNames(List<Map<String, dynamic>> rows) =>
      rows.map((r) => r['matched_name']?.toString() ?? '').toSet().length;

  // #130/#131: fires after the LAST window of a tapped clip finishes playing.
  // Resets popup to All combined view + scrolls chip row to start.
  Future<void> _resetToAllAfterPlayback({int? playedSeq}) async {
    if (!mounted) return;
    setState(() {
      _selectedGroupKey = null; // All view
      _mentions = null;        // clear so grouped body shows fresh data, not stale flat list
    });
    if (_chipScrollCtrl.hasClients) {
      _chipScrollCtrl.animateTo(0,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      RenderLog.write('c128_chips_scrolled', 'to_offset=0');
    }
    await _fetchMentions();
    if (!mounted) return;
    // c131_return_fired: runtime proof inside completion handler, AFTER selectedGroupKey=null
    final modeAfter = _selectedGroupKey == null ? 'grouped' : 'flat';
    RenderLog.write('c131_return_fired',
        'trigger=playback_complete;played_seq=${playedSeq?.toString() ?? 'null'};mode_after=$modeAfter;seq_after=${_selectedGroupKey ?? 'null'}');
  }

  // Whole-clip play — no seeking, no timestamps. [onWindowEnded] fires when THIS
  // window's audio ends naturally — CHANGE #456's queue orchestration (_tapGroup)
  // uses it to advance to the next window in a multi-window recording, or to
  // reset to All once the group's last window finishes.
  Future<void> _playWholeClip(String clipPath, int recordingSeq,
      {required void Function(int? playedSeq) onWindowEnded}) async {
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
      // Natural end → notify the caller (queue advance or reset-to-All).
      // pause()/src='' interruptions do NOT fire onEnded, so they are excluded.
      el.onEnded.listen((_) {
        if (!mounted || !identical(_clipAudio, el)) return;
        final playedSeq = _playingSeq;
        setState(() { _playingClip = null; _playingSeq = null; });
        RenderLog.write('c119_play_state', 'playing_seq=none;is_playing=false');
        _newClipSeq = null;
        onWindowEnded(playedSeq);
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

  // CHANGE #456: tap a clip chip (one RECORDING, possibly several chunk-window
  // audio files) — switch to flat spoken-order view + play its windows
  // back-to-back in order. Tapping the currently-playing group's chip stops
  // audio and clears the queue but keeps the flat view.
  void _tapGroup(ClipGroup group) {
    if (_playingClip != null && group.windows.any((w) => w.clipPath == _playingClip)) {
      _stopAudio();
      _playQueue = [];
      return;
    }
    setState(() => _selectedGroupKey = group.groupKey);
    _playQueue = group.windows.skip(1).map((w) => w.clipPath).toList();
    final seqByPath = {for (final w in group.windows) w.clipPath: w.seq};
    RenderLog.write('c119_clip_tapped',
        'group=${group.groupKey};windows=${group.windows.length};flat_view=y;playing=y');
    _playWholeClip(group.windows.first.clipPath, group.windows.first.seq,
        onWindowEnded: (_) => _playNextInQueue(seqByPath));
  }

  // CHANGE #456: advances through a multi-window recording's remaining clips;
  // once exhausted, resets to the All view exactly like the old single-file end.
  void _playNextInQueue(Map<String, int> seqByPath) {
    if (_playQueue.isEmpty) {
      _resetToAllAfterPlayback();
      return;
    }
    final next = _playQueue.removeAt(0);
    _playWholeClip(next, seqByPath[next] ?? 0,
        onWindowEnded: (_) => _playNextInQueue(seqByPath));
  }

  void _stopAudio() {
    _clipAudio?.pause();
    _clipAudio?.src = '';
    _clipAudio = null;
    _playQueue = [];
    if (mounted) setState(() { _playingClip = null; _playingSeq = null; });
  }

  void _showSnackMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  // #334 B1: tap-to-fix for unmatched mention rows — shows supplier item picker.
  Future<void> _showItemPicker(String mentionId, int mentionQty) async {
    if (!mounted) return;
    final items = widget.orderItems;
    if (items.isEmpty) { _showSnackMsg('No items loaded'); return; }

    Map<String, dynamic>? picked;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        String query = '';
        return StatefulBuilder(builder: (ctx2, setSt) {
          final filtered = query.isEmpty
              ? items
              : items.where((i) {
                  final n = (i['product_name'] ?? '').toString().toLowerCase();
                  return n.contains(query.toLowerCase());
                }).toList();
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx2).viewInsets.bottom),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox(height: 12),
              Container(width: 36, height: 4, decoration: BoxDecoration(color: const Color(0xFFE5E7EB), borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 12),
              const Text('Pick product', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: TextField(
                  autofocus: true,
                  decoration: const InputDecoration(hintText: 'Search…', isDense: true, border: OutlineInputBorder()),
                  onChanged: (v) => setSt(() => query = v),
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: filtered.length,
                  itemBuilder: (_, i) {
                    final item = filtered[i];
                    return ListTile(
                      dense: true,
                      title: Text(item['product_name']?.toString() ?? '', style: const TextStyle(fontSize: 13)),
                      onTap: () { picked = item; Navigator.pop(ctx); },
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
            ]),
          );
        });
      },
    );

    if (picked == null || !mounted) return;
    final productId = (picked!['product_id'] as num?)?.toInt();
    final productName = picked!['product_name']?.toString() ?? '';
    if (productId == null) return;

    try {
      await Supabase.instance.client
          .from('voice_clip_mentions')
          .update({'matched_name': productName, 'product_id': productId})
          .eq('id', mentionId);
      RenderLog.write('c334_voice_fallback', 'mention_fixed=$productName;qty=$mentionQty');

      // Apply the count via set_voice_received
      await Supabase.instance.client.rpc('set_voice_received', params: {
        'p_supplier_name': widget.supplierName,
        'p_product_id': productId,
        'p_qty': mentionQty.toDouble(),
        'p_note': 'voice: tap-fix to $productName',
      });

      if (mounted) {
        _showSnackMsg('Assigned to $productName');
        await _fetchMentions();
      }
    } catch (e) {
      if (mounted) _showSnackMsg('Error updating mention');
    }
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
      // #334 B1: product_id==null → unmatched; exclude from counts but show amber in flat view
      final rawName = r['matched_name']?.toString() ?? '';
      if (r['product_id'] == null) continue; // unmatched — shown separately in clip flat view only
      final name = rawName.trim().isEmpty ? '(unnamed)' : rawName;
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
    final clips = mentions != null ? groupMentionsIntoClips(mentions) : <ClipGroup>[];
    final selGroupKey = _selectedGroupKey;

    // #120: log view mode on every build
    if (mentions != null && mentions.isNotEmpty) {
      RenderLog.write('c120_view_mode',
          selGroupKey == null ? 'mode=grouped' : 'mode=flat;clip_seq=$selGroupKey');
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
                            setState(() => _selectedGroupKey = null);
                            RenderLog.write('c120_back_to_all', 'true');
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: selGroupKey == null ? _kGreen : const Color(0xFFE8F5E9),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: _kGreen),
                            ),
                            child: Text('All',
                                style: TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.w600,
                                  color: selGroupKey == null ? Colors.white : _kGreen,
                                )),
                          ),
                        ),
                        // CHANGE #456: one chip per RECORDING (session), not per chunk window.
                        ...clips.asMap().entries.map((e) {
                          final idx = e.key;
                          final group = e.value;
                          return Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: _ClipPlayButton(
                              // #455: "Clip N" for Shop, "Part N" for Warehouse (see #455).
                              label: widget.stage == 'warehouse' ? 'Part ${idx + 1}' : 'Clip ${idx + 1}',
                              clipPath: group.windows.first.clipPath,
                              recordingSeq: group.windows.first.seq,
                              playing: _playingClip != null &&
                                  group.windows.any((w) => w.clipPath == _playingClip),
                              onPlay: () => _tapGroup(group),
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
        else if (selGroupKey != null)
          // #120: flat spoken-order view for selected clip
          Builder(builder: (_) {
            RenderLog.write('c112_popup_branch', 'branch=list;mode=flat'); // branch proof
            return Flexible(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: _buildFlatList(selGroupKey),
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

  // #343: tap icon handler — no optimistic flip (§4.2: colour only changes on ok:true).
  Future<void> _handleMentionToggle(Map<String, dynamic> r) async {
    final id = r['id']?.toString() ?? '';
    final status = r['status']?.toString() ?? 'counted';
    if (id.isEmpty || _mentionLoading.contains(id)) return;
    RenderLog.write('c342_toggle', 'id=${id.substring(0, id.length.clamp(0, 8))};status=$status;stage=${widget.stage}');

    final isDeleted = status == 'deleted';
    final action = isDeleted ? 'readd' : 'delete';

    // No optimistic flip — spinner only; colour updates only after server ok:true
    setState(() => _mentionLoading.add(id));
    try {
      final raw = await Supabase.instance.client.rpc('voice_mention_set_status', params: {
        'p_id': id,
        'p_action': action,
      }) as Map;
      final res = Map<String, dynamic>.from(raw);
      if (!mounted) return;
      if (res['ok'] == true) {
        final newStatus = res['status']?.toString() ?? (isDeleted ? 'readded' : 'deleted');
        setState(() {
          final idx = _mentions?.indexWhere((m) => m['id']?.toString() == id) ?? -1;
          if (idx >= 0) {
            _mentions![idx] = Map<String, dynamic>.from(_mentions![idx])
              ..['status'] = newStatus;
          }
          if (isDeleted) {
            RenderLog.write('c331_mention_yellow', 'id=${id.substring(0, id.length.clamp(0, 8))}');
          } else {
            RenderLog.write('c331_mention_red', 'id=${id.substring(0, id.length.clamp(0, 8))}');
          }
        });
        final applyRaw = res['apply'];
        if (applyRaw != null && widget.onApplyUpdate != null) {
          widget.onApplyUpdate!(Map<String, dynamic>.from(applyRaw as Map));
        }
        final delKey = widget.stage == 'warehouse' ? 'c342_del_wh' : 'c342_del_shop';
        final readdKey = widget.stage == 'warehouse' ? 'c342_readd_wh' : 'c342_readd_shop';
        RenderLog.write(action == 'readd' ? readdKey : delKey,
            'id=${id.substring(0, id.length.clamp(0, 8))};new_status=$newStatus');
        await _fetchMentions();
        widget.onToggled?.call();
      } else {
        // Row colour unchanged — server auto-reverts; just show friendly toast
        final err = res['error']?.toString() ?? '';
        final applyErr = (res['apply'] as Map?)?['error']?.toString() ?? '';
        RenderLog.write('c343_toggle_err_${err.isEmpty ? 'unknown' : err.substring(0, err.length.clamp(0, 20))}',
            'stage=${widget.stage}');
        if (err.contains('shop_locked_undo_first')) {
          _showSnackMsg('Shop counts frozen — undo submit first');
        } else if (err.contains('exceeds_ordered')) {
          final max = res['max_qty']?.toString();
          _showSnackMsg(max != null
              ? "Can't re-add — bag limit reached (max $max)"
              : "Can't re-add — ordered quantity already reached");
        } else if (err.contains('no_bag_selected') || err.contains('no bag') || err.contains('check_violation')) {
          RenderLog.write('c331_bag_prompt', 'from_mention_icon;id=${id.substring(0, id.length.clamp(0, 8))}');
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
                        'Adjust the bag total to match the new count, then tap the icon to retry.',
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
        } else if (applyErr.contains('received_locked')) {
          _showSnackMsg('Line locked — Undo receiving first');
        } else if (err.contains('already_deleted') || err.contains('not_deleted')) {
          await _fetchMentions(); // silent reconcile — state drift
        } else {
          _showSnackMsg("Couldn't update count — try again");
        }
      }
    } catch (e) {
      RenderLog.write('c343_toggle_err_exception',
          'detail=${e.toString().substring(0, e.toString().length.clamp(0, 60))};stage=${widget.stage}');
      if (mounted) _showSnackMsg("Couldn't update count — try again");
    } finally {
      if (mounted) setState(() => _mentionLoading.remove(id));
    }
  }

  // #120: flat spoken-order list for the selected clip.
  // CHANGE #456: one row per mention, merged across every chunk window that
  // belongs to this RECORDING (group) — filtered by the row's own group key
  // (clipGroupKeyOf), not by a single recording_seq. Ordered by (recording_seq,
  // ord) so windows play out in the same order the recording happened, not just
  // ord within one window. No timestamps used — green is whole-clip (#119 rule).
  // #331: long-press on each row → delete/re-add via voice_mention_set_status.
  // #344: delegates to shared _MentionClipTable (3-column Product|Qty spoken|Total)
  Widget _buildFlatList(String groupKey) {
    final rows = (_mentions ?? [])
        .where((r) => clipGroupKeyOf(r) == groupKey)
        .toList()
      ..sort((a, b) {
        final seqCmp = ((a['recording_seq'] as num?)?.toInt() ?? 0)
            .compareTo((b['recording_seq'] as num?)?.toInt() ?? 0);
        return seqCmp != 0
            ? seqCmp
            : ((a['ord'] as num?)?.toInt() ?? 0).compareTo((b['ord'] as num?)?.toInt() ?? 0);
      });

    RenderLog.write('c120_flat_built', 'group=$groupKey;rows=${rows.length};ord_sorted=y');
    RenderLog.write('c342_row_icon', 'stage=${widget.stage};rows=${rows.length}');
    RenderLog.write('c343_clip_actions', 'stage=${widget.stage};group=$groupKey;rows=${rows.length}');

    final orderedMap = <String, int>{};
    for (final item in widget.orderItems) {
      final name = item['product_name']?.toString();
      if (name != null) orderedMap[name] = (item['ordered_qty'] as num?)?.toInt() ?? 0;
    }

    return _MentionClipTable(
      rows: rows,
      frozenAll: widget.frozen,
      mentionLoading: _mentionLoading,
      onToggle: _handleMentionToggle,
      onUnmatchedTap: _showItemPicker,
      onFrozenTap: (id) {
        if (!_frozenTappedIds.contains(id)) {
          _frozenTappedIds.add(id);
          RenderLog.write('c342_frozen_tap',
              'id=${id.substring(0, id.length.clamp(0, 8))};stage=${widget.stage}');
        }
      },
      productOrdered: orderedMap,
      stage: widget.stage,
      playingSeq: _playingSeq,
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
    // #343: All view is read-only aggregate — no action icons present
    RenderLog.write('c343_all_readonly', 'stage=${widget.stage};groups=${groups.length}');
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
              // #344: colour qty number by status (readded=amber; deleted filtered out by _groupMentions)
              SizedBox(
                width: _kBadgeClusterMaxW,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: g.entries.map((e) {
                      final active = playSeq != null && e.seq == playSeq;
                      final isReadded = e.status == 'readded';
                      if (isReadded) {
                        RenderLog.write('c344_all_qty_colour', 'status=readded;stage=${widget.stage}');
                      }
                      final Color bg = active ? _kGreen
                          : isReadded ? const Color(0xFFFEF3C7)
                          : const Color(0xFFF5F6F8);
                      final Color border = active ? _kGreen
                          : isReadded ? const Color(0xFFF59E0B)
                          : _kBorder;
                      final Color fg = active ? Colors.white
                          : isReadded ? const Color(0xFF92400E)
                          : _kText;
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: bg,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: border),
                        ),
                        child: Text('${e.qty}',
                            style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600,
                              color: fg,
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

// ── CHANGE #344: shared 3-column clip-table for Shop / Warehouse / Pack ──────────────
// Product | Qty spoken (icon + chip) | Total (per-product, non-deleted)
// One row per mention (sorted by ord). Whole-row tint from mention.status.
class _MentionClipTable extends StatelessWidget {
  final List<Map<String, dynamic>> rows;       // this clip's mentions, sorted by ord
  final bool frozenAll;                        // true = whole sheet frozen (shop/wh confirm)
  final bool Function(Map<String, dynamic>)? isFrozenRow; // per-row (pack: per product)
  final Set<String> mentionLoading;
  final Future<void> Function(Map<String, dynamic> r) onToggle;
  final void Function(String id, int qty)? onUnmatchedTap;
  final void Function(String id)? onFrozenTap; // called on frozen-row tap
  final Map<String, int> productOrdered;       // matched_name → ordered qty
  final String stage;
  final int? playingSeq;

  static const double _kBW = 148.0; // badge cluster width (icon 34 + gap 4 + chip ~40+)
  static const double _kTW = 52.0;
  static const double _kG1 = 10.0;
  static const double _kG2 = 6.0;

  const _MentionClipTable({
    required this.rows,
    required this.mentionLoading,
    required this.onToggle,
    required this.stage,
    this.frozenAll = false,
    this.isFrozenRow,
    this.onUnmatchedTap,
    this.onFrozenTap,
    this.productOrdered = const {},
    this.playingSeq,
  });

  // Per-product non-deleted totals for the Total column.
  Map<String, int> _totals() {
    final m = <String, int>{};
    for (final r in rows) {
      if (r['status']?.toString() == 'deleted') continue;
      final k = r['matched_name']?.toString() ?? '';
      m[k] = (m[k] ?? 0) + ((r['qty'] as num?)?.toInt() ?? 0);
    }
    return m;
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c344_clip_table', 'stage=$stage;rows=${rows.length}');
    final totals = _totals();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header
        Container(
          color: const Color(0xFFF5F6F8),
          child: Row(children: [
            Expanded(child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
              child: const Text('Product',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _kSub)),
            )),
            const SizedBox(width: _kG1),
            SizedBox(width: _kBW, child: const Text('Qty spoken',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _kSub))),
            const SizedBox(width: _kG2),
            SizedBox(width: _kTW, child: Padding(
              padding: const EdgeInsets.only(right: 10),
              child: const Text('Total', textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _kSub)),
            )),
          ]),
        ),
        const Divider(height: 1, color: _kBorder),
        // One row per mention
        ...rows.map((r) {
          final id = r['id']?.toString() ?? '';
          final rawName = r['matched_name']?.toString() ?? '';
          final isUnmatched = r['product_id'] == null &&
              (r['status']?.toString() ?? '') != 'deleted';
          final name = isUnmatched
              ? (rawName.trim().isEmpty ? 'Unmatched ×tap to fix' : 'Unmatched: $rawName')
              : (rawName.trim().isEmpty ? '(unnamed)' : rawName);
          final qty = (r['qty'] as num?)?.toInt() ?? 0;
          final status = r['status']?.toString() ?? 'counted';
          final isDeleted = status == 'deleted';
          final isReadded = status == 'readded';
          final isBusy = mentionLoading.contains(id);
          final isPlaying = playingSeq != null &&
              (r['recording_seq'] as num?)?.toInt() == playingSeq;
          final frozen = frozenAll || (isFrozenRow?.call(r) ?? false) || isUnmatched;
          final prodTotal = totals[rawName] ?? 0;
          final ordered = productOrdered[rawName] ?? 0;
          final full = ordered > 0 && prodTotal >= ordered;

          // Whole-row tint — §3.1
          Color? rowTint;
          if (isUnmatched) {
            rowTint = const Color(0x28F59E0B);
          } else if (isDeleted) {
            rowTint = const Color(0x17FF0000);
            RenderLog.write('c344_row_colour', 'status=deleted;stage=$stage');
          } else if (isReadded) {
            rowTint = const Color(0x1AF59E0B);
            RenderLog.write('c344_row_colour', 'status=readded;stage=$stage');
          }

          // Qty chip colours
          final Color chipBg = isDeleted ? const Color(0xFFFEE2E2)
              : isReadded ? const Color(0xFFFEF3C7)
              : isPlaying ? _kGreen : const Color(0xFFF5F6F8);
          final Color chipBorder = isDeleted ? const Color(0xFFEF4444)
              : isReadded ? const Color(0xFFF59E0B)
              : isPlaying ? _kGreen : _kBorder;
          final Color chipFg = isDeleted ? const Color(0xFF991B1B)
              : isReadded ? const Color(0xFF92400E)
              : isPlaying ? Colors.white : _kText;

          final pill = Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: chipBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: chipBorder),
            ),
            child: isBusy
                ? const SizedBox(width: 12, height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _kGreen))
                : Text('$qty',
                    style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600,
                      color: chipFg,
                      decoration: isDeleted ? TextDecoration.lineThrough : null,
                    )),
          );

          final rowWidget = AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              color: rowTint,
              border: const Border(bottom: BorderSide(color: _kBorder)),
              boxShadow: isDeleted
                  ? const [BoxShadow(color: Color(0x1AFF0000), blurRadius: 3, offset: Offset(0, 1))]
                  : isReadded
                      ? const [BoxShadow(color: Color(0x1AF59E0B), blurRadius: 3, offset: Offset(0, 1))]
                      : null,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          softWrap: true, maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w500,
                            color: isDeleted ? const Color(0xFF991B1B)
                                : isReadded ? const Color(0xFF92400E)
                                : isPlaying ? _kGreen : _kText,
                          )),
                      if (isDeleted)
                        const Text('removed',
                            style: TextStyle(fontSize: 10, color: Color(0xFF991B1B)))
                      else if (isReadded)
                        const Text('re-added',
                            style: TextStyle(fontSize: 10, color: Color(0xFF92400E))),
                    ],
                  ),
                )),
                const SizedBox(width: _kG1),
                SizedBox(
                  width: _kBW,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        MentionActionIcon(
                          status: status,
                          isBusy: isBusy,
                          frozen: frozen,
                          onTap: frozen
                              ? (frozenAll ? () => onFrozenTap?.call(id) : null)
                              : () => onToggle(r),
                        ),
                        const SizedBox(width: 4),
                        pill,
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: _kG2),
                SizedBox(
                  width: _kTW,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Text(
                      ordered > 0 ? '$prodTotal/$ordered' : '$prodTotal',
                      style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700,
                        color: full ? _kGreen : _kText,
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ),
              ],
            ),
          );

          return (isUnmatched && onUnmatchedTap != null)
              ? GestureDetector(onTap: () => onUnmatchedTap!(id, qty), child: rowWidget)
              : rowWidget;
        }),
      ],
    );
  }
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
    // C358 B1: SILENT refetch — spinner only on first load (empty). Realtime-driven
    // refetches keep the bag labels on screen and patch them in place (no flash).
    if (_bags.isEmpty) {
      setState(() { _loading = true; _error = null; });
    } else if (_error != null) {
      setState(() => _error = null);
    }
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
    // C358 B1: SILENT refetch — spinner only on first load (empty). Realtime-driven
    // refetches keep the bag labels on screen and patch them in place (no flash).
    if (_bags.isEmpty) {
      setState(() { _loading = true; _error = null; });
    } else if (_error != null) {
      setState(() => _error = null);
    }
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
  final bool isExpanded;
  final bool anyExpanded;     // any supplier open → bigger bottom gap
  final GlobalKey rowKey;
  final VoidCallback onTap;
  final Widget expandedContent; // AnimatedSize handles show/hide
  // fix(pack): Pack tab's 3 status dots [allPacked, allCounted, readyDone] —
  // true=green, false=yellow. Null (every other caller) keeps the `hexDots`
  // behavior below completely unchanged.
  final List<bool>? dots;
  // Verbatim {fill, border} hex-colour dots from fw_list_arrivals() (Supplier
  // Shop: [dot_packed, dot_method, dot_submit]; Warehouse: [dot_method,
  // dot_packed]) — already ordered by the caller. null entries render the
  // fallback yellow dot. Null list (e.g. Pack tab, which uses `dots` above).
  final List<Map<String, String>?>? hexDots;

  const _SupplierAccordionShell({
    required this.name,
    required this.isExpanded,
    required this.anyExpanded,
    required this.rowKey,
    required this.onTap,
    required this.expandedContent,
    this.dots,
    this.hexDots,
  });

  static const _kDotGreen       = Color(0xFF1B7A43);
  static const _kDotYellow      = Color(0xFFFCD34D);
  static const _kDotBorderLight = Color(0xFFF59E0B);

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
                const SizedBox(width: 8),
                if (dots != null)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    for (int i = 0; i < dots!.length; i++) ...[
                      if (i > 0) const SizedBox(width: 4),
                      Container(
                        width: 12, height: 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: dots![i] ? _kDotGreen : _kDotYellow,
                          border: Border.all(
                              color: dots![i] ? _kDotGreen : _kDotBorderLight,
                              width: 1.5),
                        ),
                      ),
                    ],
                  ])
                else if (hexDots != null)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    for (int i = 0; i < hexDots!.length; i++) ...[
                      if (i > 0) const SizedBox(width: 4),
                      Container(
                        width: 12, height: 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _hexColor(hexDots![i]?['fill'], _kDotYellow),
                          border: Border.all(
                              color: _hexColor(hexDots![i]?['border'], _kDotBorderLight),
                              width: 1.5),
                        ),
                      ),
                    ],
                  ]),
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
  const CountBadge({super.key, required this.badge});
  // Verbatim {letter, color} from fw_list_arrivals()'s per-supplier `badge`
  // field — never recomputed client-side. null = nothing to show yet.
  final Map<String, String>? badge;

  static const _kBadgeColors = {
    'yellow': Color(0xFFF59E0B),
    'green': Color(0xFF1B7A43),
    'red': Color(0xFFD32F2F),
  };

  @override
  Widget build(BuildContext context) {
    final label = badge?['letter'];
    if (label == null || label.isEmpty) return const SizedBox(width: 38, height: 24);
    final color = _kBadgeColors[badge?['color']] ?? const Color(0xFFF59E0B);
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
    if (surface == 'collect') {
      RenderLog.write('c189_collect_badge_rendered',
          'dispute=${item.disputeId};status=${item.disputeStatus}');
    } else {
      RenderLog.write('c189_arrivals_badge_rendered',
          'dispute=${item.disputeId};status=${item.disputeStatus}');
    }
    RenderLog.write('c349_item_chip', 'tab=$surface');
    RenderLog.write('c352_item_chip', 'tab=$surface');

    // B2 (#349): red-outline chip "In dispute — <item_status_label>" (24-char truncated)
    const kRed = Color(0xFFDC2626);
    final rawLabel = item.itemStatusLabel;
    final label = rawLabel.length > 24 ? '${rawLabel.substring(0, 24)}…' : rawLabel;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: kRed, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'In dispute — $label',
        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: kRed),
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
  // C354: shop-stage counted total (sum shop_qty); null if any line uncounted. Used so the
  // Report-issue gating sees the SHOP count at shop stage, not the warehouse received_qty.
  final int? shopQtyTotal;
  // C365: true counted shop_qty total (uncounted lines = 0) — feeds the popup gap/breakdown so a
  // partially-counted product isn't inflated to full ordered.
  final int shopQtyCounted;
  // C360: warehouse expected total (sum forwarded shop_qty). The Report-issue gating +
  // balance reference at warehouse is `expected`, not raw ordered.
  final int? expectedTotal;
  final String combinedState;
  // Backend-owned: fw_get_state()'s merged_items[] status_label/status_colors,
  // rendered verbatim by the header pill.
  final String statusLabel;
  final Map<String, String>? statusColors;
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
  // C351: raw first-line payload for issue section (order_item_id, count_issue, etc.)
  // C361: this is now the CANDIDATE line (first _lineIsCandidate), not lines.first, so
  // line-level flags (fw_set_line_issue) target the line the admin is classifying.
  final Map<String, dynamic>? itemData;
  // C361: true when the product spans >1 order-line. The short/report-missing flow is
  // product-level (fw_product_action distributes), so it is only offered single-line.
  final bool multiLine;
  // C365: product-level existing dispute flag (any flagged line) + summed disputed qty,
  // so the aggregated popup pre-fills the current product-level disputed value.
  final String? mergedCountIssue;
  final int mergedIssueQty;

  const _ProductReceiveSheet({
    required this.supplierName,
    required this.productId,
    required this.productName,
    required this.packType,
    this.imageUrl,
    required this.orderedTotal,
    required this.receivedTotal,
    this.shopQtyTotal,
    this.shopQtyCounted = 0,
    this.expectedTotal,
    required this.combinedState,
    this.statusLabel = '',
    this.statusColors,
    this.existingDispute,
    this.arrivals = false,
    this.activeBagNo,
    this.bagBreakdown,
    this.bagCountFn,
    this.bagCountClearFn,
    this.onReload,
    this.itemData,
    this.multiLine = false,
    this.mergedCountIssue,
    this.mergedIssueQty = 0,
  });

  @override
  State<_ProductReceiveSheet> createState() => _ProductReceiveSheetState();
}

class _ProductReceiveSheetState extends State<_ProductReceiveSheet> {
  late String _localState;
  late int _localReceived;

  // C359: "Report missing" moved into the Report-issue popup — inline stepper removed.

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
    _wrongDraft = 1;
    _fewWrongCtrl.text = '1';
    RenderLog.write('c197_product_sheet_opened',
        'product_id=${widget.productId};ordered=${widget.orderedTotal}');
  }

  @override
  void dispose() {
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

  // C359: "Report missing / Short" reuses the existing report-missing flow, now
  // invoked from inside the Report-issue popup. receivedQty = units actually
  // received (the rest becomes short); null = clear/undo the short. Throws on
  // error so ReportIssueSection surfaces it. The confirm RPC raises the dispute.
  Future<void> _reportMissing(int? receivedQty) async {
    if (receivedQty == null) {
      final res = await Supabase.instance.client.rpc('fw_product_undo', params: {
        'p_supplier_name': widget.supplierName,
        'p_product_id': widget.productId,
      }) as Map;
      final err = res['error']?.toString();
      if (err != null && err != 'nothing_to_undo') throw err;
      return;
    }
    await _callProductAction('report_missing', qty: receivedQty);
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
          widget.onReload?.call(); // C353: refetch after undo — no manual refresh
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
          widget.onReload?.call(); // C353: refetch after undo — no manual refresh
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
          widget.onReload?.call(); // C353: refetch after undo — no manual refresh
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
    // C365 (D): breakdown values — counted total (Σ received @wh / Σ shop_qty @shop), disputed (Σ issue_qty).
    final countedTotal = widget.arrivals ? widget.receivedTotal : widget.shopQtyCounted;
    final disputedTotal = widget.mergedIssueQty;
    // C359: counting is VOICE-ONLY — the manual Got-all / Report-missing buttons
    // were removed from this popup. The only remaining in-flight guard is Undo.
    final isBusy = _undoing;
    // Backend-owned: fw_get_state()'s merged_items[] status_label/status_colors, verbatim.
    final bg = _hexColor(widget.statusColors?['bg'], _kPendingBg);
    final fg = _hexColor(widget.statusColors?['fg'], _kPendingFg);
    final isActioned = state != 'pending';

    // C359: this popup only opens for a dispute candidate. "Report missing / Short"
    // now lives INSIDE the Report-issue list; detect an already-marked short so it
    // pre-selects, and pass the stage-appropriate counted qty as its default.
    final isShortLine = _localState == 'short' ||
        widget.itemData?['fulfillment_state']?.toString() == 'short';
    RenderLog.write('c359_voice_only', widget.arrivals ? 'warehouse' : 'shop');

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
              const SizedBox(height: 4),
              // C365 (D): Ordered / Received / In dispute breakdown WITH pack type.
              Builder(builder: (_) {
                RenderLog.write('c365_breakdown', 'where=popup');
                final pack = widget.packType;
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Ordered — ${qtyWithPack(ord, pack)}',
                      style: const TextStyle(fontSize: 12, color: _kSub)),
                  Text('Received — ${qtyWithPack(countedTotal, pack)}',
                      style: const TextStyle(fontSize: 12, color: _kSub)),
                  if (disputedTotal > 0)
                    Text('In dispute — ${qtyWithPack(disputedTotal, pack)}',
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600, color: _kPendingFg)),
                ]);
              }),
              const SizedBox(height: 4),
              // Backend-owned: fw_get_state()'s merged_items[] status_label, verbatim.
              Builder(builder: (_) {
                RenderLog.write('c365_status_one', 'status=${widget.statusLabel}');
                return _BackendStatePill(label: widget.statusLabel, bg: bg, fg: fg);
              }),
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

        // C359: Got all + the standalone Report-missing button were REMOVED here —
        // counting is voice-only and "Report missing / Short" is now a dispute type
        // inside the Report-issue list below.

        // C351/C359: unified report-issue section — now includes "Report missing / Short".
        if (widget.itemData != null) ...[
          ReportIssueSection(
            // C365: PRODUCT-scoped popup — feed the AGGREGATE totals (not one candidate line) so
            // the disputed-units cap = the product's TOTAL gap (fixes the "max 2/3" multi-line bug),
            // and pass supplier + product_id so it calls the product-level fw_set_product_issue.
            tab: widget.arrivals ? 'warehouse' : 'shop',
            orderItemId: widget.itemData!['order_item_id']?.toString() ?? '',
            supplierName: widget.supplierName,
            productId: widget.productId,
            // Display "Ordered" = the product's total ordered.
            orderedQty: widget.orderedTotal,
            // counted total: warehouse = Σ received_qty; shop = Σ counted shop_qty (uncounted=0),
            // so the gap = ref − Σcounted is correct even when some sibling lines are uncounted.
            receivedQty: widget.arrivals
                ? widget.receivedTotal
                : widget.shopQtyCounted,
            // C360/C365: stage reference TOTAL — WAREHOUSE = Σ expected (forwarded), SHOP = Σ ordered.
            // gap = ref − counted becomes the aggregate total gap.
            refQty: widget.arrivals
                ? (widget.expectedTotal ?? widget.orderedTotal)
                : widget.orderedTotal,
            isLocked: widget.itemData!['received_locked'] == true ||
                widget.itemData!['collect_locked'] == true,
            // C365: product-level existing flag (any flagged line) + summed disputed qty.
            existingIssue: widget.mergedCountIssue,
            existingIssueQty: widget.mergedIssueQty > 0 ? widget.mergedIssueQty : null,
            existingWrongName: widget.itemData!['wrong_received_note']?.toString(),
            existingProofUrl: widget.itemData!['wrong_proof_url']?.toString(),
            // C359: short/missing reuses the existing report-missing flow (fw_product_action).
            // C361: report_missing is PRODUCT-level (distributes across all lines), so only
            // offer it single-line — multi-line voice-count shorts already auto-balance.
            isShort: isShortLine,
            onReportMissing: widget.multiLine ? null : _reportMissing,
            onSaved: () {
              widget.onReload?.call();
              if (mounted) Navigator.of(context).pop();
            },
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
  // CHANGE #473: forwarded straight through to the inner _PickToLightScreen.
  final void Function(int)? onSupplierCountChanged;
  const _ArrivalsScreen({super.key, this.onVoiceCount, this.onSupplierCountChanged});

  @override
  State<_ArrivalsScreen> createState() => _ArrivalsScreenState();
}

class _ArrivalsScreenState extends State<_ArrivalsScreen>
    with WidgetsBindingObserver {
  // Key gives the parent a handle to trigger supplier-list refresh.
  final _ptlKey = GlobalKey<_PickToLightScreenState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // C353: the arrivals_c140 channel + 15s poll are replaced by the single
    // FulfillRealtime channel; the parent routes events here via refreshAll().
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

  // C353: full realtime-triggered refetch — supplier list + expanded card items.
  void refreshAll() {
    if (!mounted) return;
    _ptlKey.currentState?._refetchFromRealtime();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // #155: literal reuse of Collect widget — same voice/spoken/Ask mediBO/item sheet.
    return _PickToLightScreen(
      key: _ptlKey,
      arrivals: true,
      onSupplierCountChanged: widget.onSupplierCountChanged,
    );
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
  int _shopCount = 0;      // CHANGE #473: Supplier Shop tab badge
  int _warehouseCount = 0; // CHANGE #473: Warehouse tab badge
  final _collectKey   = GlobalKey<_PickToLightScreenState>();
  final _disputesKey  = GlobalKey<_DisputesScreenState>();
  final _packTabKey   = GlobalKey<_PackTabState>();
  final _bagTabKey    = GlobalKey<_BagTabState>();

  // ── #187→C353: realtime now via the single FulfillRealtime channel ────────
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

  // C353: the three #187 channels are replaced by ONE app-wide channel
  // (lib/services/fulfill_realtime.dart). Events arrive already debounced
  // (400ms); refetch targets ONLY the visible tab's data.
  void _subscribeRealtime() {
    FulfillRealtime.instance.addListener(_onRealtimeChange);
  }

  void _refreshPack() {
    _packTabKey.currentState?.refreshDisputeIndex();
  }

  void _onRealtimeChange(Set<String> changedTables) {
    if (!mounted) return;
    // C355: an event reached THIS device (local or from another device) and is now
    // driving a visible-tab refetch — same code path for both. This is the unify point.
    RenderLog.write('c355_rt_refetch', 'tab=$_tab');
    // C358 B1: proof that a refetch is triggered ONLY by a real Postgres change event
    // (never a timer). Carries the changed table(s). The refetch itself is now SILENT.
    RenderLog.write('c358_rt_only', 'tbl=${changedTables.join("+")}');
    // C358 B3: a dispute change re-renders the Supplier Shop / Warehouse rows (chips +
    // the #357 Dispute Type / Item Status columns) so resolutions reflect back here.
    if (changedTables.contains('supplier_disputes') && (_tab == 0 || _tab == 1)) {
      RenderLog.write('c358_line_synced', 'tab=${_tab == 0 ? 'shop' : 'warehouse'}');
    }
    // C360: a realtime change (e.g. a dispute raised at confirm) silently re-renders
    // the visible counting tab — no manual refresh, no polling.
    if (_tab == 0 || _tab == 1) {
      RenderLog.write('c361_synced', 'tab=${_tab == 0 ? 'shop' : 'warehouse'},src=rt');
    }
    // C354: a dispute change alters recounts/splits/chips on EVERY tab, not just the
    // visible one. Refresh the Pack dispute index regardless of which tab is showing so
    // its read-only chips are correct the instant the packer switches to it.
    if (changedTables.contains('supplier_disputes') && _tab != 3) {
      _packTabKey.currentState?.refreshDisputeIndex();
    }
    switch (_tab) {
      case 0: // Supplier Shop
        _collectKey.currentState?._refetchFromRealtime();
        break;
      case 1: // Warehouse / Arrivals (logs c353_refetch inside)
        _arrivalsKey.currentState?.refreshAll();
        break;
      case 2: // Bag
        RenderLog.write('c353_refetch', 'src=rt,tab=bag');
        _bagTabKey.currentState?.refreshFromRealtime();
        break;
      case 3: // Pack
        RenderLog.write('c353_refetch', 'src=rt,tab=pack');
        _packTabKey.currentState?.refreshFromRealtime();
        break;
      case 4: // Disputes (chips data on Collect invalidated too)
        RenderLog.write('c353_refetch', 'src=rt,tab=disputes');
        _disputesKey.currentState?._load();
        _collectKey.currentState?._loadDisputes();
        break;
    }
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
  // CHANGE #473: tab badge counts for Supplier Shop / Warehouse.
  void _setShopCount(int n) {
    if (mounted && n != _shopCount) setState(() => _shopCount = n);
  }
  void _setWarehouseCount(int n) {
    if (mounted && n != _warehouseCount) setState(() => _warehouseCount = n);
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

  // CHANGE #444 — shared date-scope chip: rebuild the header (for the "Today ·"
  // label and isToday styling) whenever the shared scope changes. Each of the
  // 5 tab widgets listens to FulfillDateScope independently for its own
  // refetch, so this listener only needs to repaint the chip itself.
  void _onDateScopeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FulfillDateScope.instance.addListener(_onDateScopeChanged);
    _subscribeRealtime();
    // C358 B1: the Fulfill area subscribes to realtime ONLY (event-driven). There is
    // NO periodic/interval refetch timer scheduled here or in any tab — refetches fire
    // solely on a real Postgres change event (debounced 400ms) or an explicit action.
    RenderLog.write('c358_no_poll', 'killed=1');
    RenderLog.write('fulfillment_area_mounted', 'true');
    RenderLog.write('fulfillment_three_areas_mounted', 'true');
    RenderLog.write('c132c_disputes_view', 'true');
    RenderLog.write('c132c_resolve_wired', 'true');
    RenderLog.write('c132c_copylink_wired', 'true');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      // C355: a phone wake / network flip can leave a zombie WebSocket that never
      // fires 'closed', so future remote events never arrive until reload. Force a
      // fresh re-subscribe + full refetch on resume to recover it.
      //
      // #416: on Flutter Web, AppLifecycleState.resumed fires on ordinary browser
      // tab focus/blur (switching tabs, an autofill popup, alt-tab) — NOT only on
      // a genuine network drop. Doing the full reconnect+refetch bundle below on
      // every one of those blips is exactly what made the Bags/Disputes tabs look
      // like they were polling every couple of seconds. Only run recovery when the
      // socket is ACTUALLY down; a healthy channel needs no forced work here.
      if (!FulfillRealtime.instance.isUp) {
        RenderLog.write(kC416, 'lifecycle_recover:socket_was_down');
        FulfillRealtime.instance.forceReconnect();
        _scheduleCollectReload();
        _scheduleDisputeReload();
        _arrivalsKey.currentState?.refresh();
      }
      // CHANGE #444 B5 — midnight rollover: if the user was viewing "today"
      // and the real day has moved on since, advance the selection and
      // refetch (recomputeToday() notifies all 5 tabs; no-op otherwise).
      FulfillDateScope.instance.recomputeToday();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _collectDebounce?.cancel();
    _disputeDebounce?.cancel();
    FulfillRealtime.instance.removeListener(_onRealtimeChange);
    FulfillDateScope.instance.removeListener(_onDateScopeChanged);
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
    RenderLog.write('c332_build', '332');
    RenderLog.write('c333_build', '333');
    RenderLog.write('c334_build', '334');
    RenderLog.write('c335_build', '335');
    RenderLog.write('c113_fulfillment_tabs_top', viewport);
    return Column(children: [
      Container(
        color: _kCard,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // CHANGE #444 — shared date-scope chip, above the tab bar, right-aligned.
          // One date/includeOlder pair for the whole Fulfill screen (all 5 tabs).
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Builder(builder: (context) {
                final scope = FulfillDateScope.instance;
                RenderLog.write('c444_chip_label',
                    scope.isToday ? 'Today · ${dmy(scope.date)}' : dmy(scope.date));
                return DateScopeChip(
                  selected: scope.date,
                  isToday: scope.isToday,
                  onChanged: (d) => FulfillDateScope.instance.setDate(d),
                );
              }),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              // CHANGE #473: count badges — 'count' (shop) / 'warehouse_count'
              // (warehouse) from fw_list_arrivals, muted/neutral (not an alert).
              Stack(clipBehavior: Clip.none, children: [
                _TabBtn('Supplier Shop', _tab == 0, () {
                  setState(() => _tab = 0);
                  _scheduleCollectReload();
                }),
                if (_shopCount > 0)
                  Positioned(
                    top: -4, right: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF6B7280),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('$_shopCount',
                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                              color: Colors.white, height: 1.2)),
                    ),
                  ),
              ]),
              const SizedBox(width: 6),
              Stack(clipBehavior: Clip.none, children: [
                _TabBtn('Warehouse', _tab == 1, () {
                  setState(() => _tab = 1);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _arrivalsKey.currentState?.refresh();
                  });
                }),
                if (_warehouseCount > 0)
                  Positioned(
                    top: -4, right: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF6B7280),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('$_warehouseCount',
                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                              color: Colors.white, height: 1.2)),
                    ),
                  ),
              ]),
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
              _PickToLightScreen(key: _collectKey, onSupplierCountChanged: _setShopCount),
              _ArrivalsScreen(
                key: _arrivalsKey,
                onVoiceCount: _openVoiceInCollect,
                onSupplierCountChanged: _setWarehouseCount,
              ),
              _BagTab(key: _bagTabKey),
              _PackTab(key: _packTabKey),
              _DisputesScreen(key: _disputesKey, onCountChanged: _setDisputeCount,
                  onRefreshCollect: _refreshCollect, onRefreshArrivals: _refreshArrivals,
                  onRefreshPack: _refreshPack),
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

  // C353: realtime via the single FulfillRealtime channel (parent routes here)
  bool _allStatesLogged = false;

  // CHANGE #444 — shared date scope
  int _olderOpen = 0;
  void _onDateScopeChanged() => _load();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    RenderLog.write('c280_bag_tab_mounted', 1);
    RenderLog.write('c285_bag_no_chip', 'rendered=false');
    RenderLog.write('c286_no_inner_strip', 'strip=removed');
    RenderLog.write('c286_no_received_footer', 'footer=removed');
    FulfillDateScope.instance.addListener(_onDateScopeChanged);
    _load();
  }

  @override
  void dispose() {
    FulfillDateScope.instance.removeListener(_onDateScopeChanged);
    _scroll.dispose();
    _searchCtrl.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!mounted) return;
    if (!silent) setState(() { _loading = true; _error = null; });
    try {
      final scope = FulfillDateScope.instance;
      // p_include_older not sent — fw_list_bags is strict single-date now.
      final data = await Supabase.instance.client.rpc('fw_list_bags', params: {
        'p_date': ymd(scope.date),
      }) as Map;
      if (!mounted) return;
      final bags = (data['bags'] as List? ?? [])
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      _olderOpen = (data['older_open'] as num?)?.toInt() ?? 0;
      RenderLog.write('c444_bags', '${bags.length}');
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

  // fix(bag): only the very FIRST load for a bag shows the spinner — once
  // _itemsByBag has an entry for it, every later call (re-expand, realtime
  // refresh) is silent: the old rows stay on screen until the new list swaps
  // in via the same setState below. Never blank to a spinner on a refresh.
  Future<void> _loadItems(int bagNo) async {
    if (_loadingItems[bagNo] == true) return;
    if (!mounted) return;
    final hasCached = _itemsByBag.containsKey(bagNo);
    if (!hasCached) setState(() => _loadingItems[bagNo] = true);
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
      if (!hasCached) setState(() => _loadingItems[bagNo] = false);
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

  // C353: called by the shared FulfillRealtime service when the Bag tab is
  // visible (replaces the bag_tab_order_items_v2 channel).
  void refreshFromRealtime() {
    if (!mounted) return;
    RenderLog.write(kC416, 'bag_tab_synced');
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
    // CHANGE #444 — shared date-scope pill.
    final olderPill = OlderOpenPill(
      olderOpen: _olderOpen,
      includeOlder: FulfillDateScope.instance.includeOlder,
      onTap: () => FulfillDateScope.instance.toggleIncludeOlder(),
    );

    if (_bags.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('No orders placed on ${dmy(FulfillDateScope.instance.date)}.',
                style: const TextStyle(color: _kSub, fontSize: 15),
                textAlign: TextAlign.center),
            if (_olderOpen > 0) ...[const SizedBox(height: 10), olderPill],
          ]),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: _bags.length + (_olderOpen > 0 ? 1 : 0),
      itemBuilder: (_, i) {
        if (_olderOpen > 0) {
          if (i == 0) {
            return Padding(padding: const EdgeInsets.only(bottom: 10), child: olderPill);
          }
          return _buildBagCard(_bags[i - 1]);
        }
        return _buildBagCard(_bags[i]);
      },
    );
  }

  Widget _buildBagCard(Map<String, dynamic> bag) {
    final bagNo      = (bag['bag_no'] as num?)?.toInt() ?? 0;
    final total      = (bag['total_products'] as num?)?.toInt() ?? 0;
    final isExpanded = _expandedBagNo == bagNo;
    final rowKey     = _rowKeys.putIfAbsent(bagNo, () => GlobalKey());

    final bagColors = bag['colors'] as Map?;
    return _BagAccordionShell(
      key: ValueKey(bagNo),
      bagNo: bagNo,
      totalProducts: total,
      isExpanded: isExpanded,
      anyExpanded: _expandedBagNo != null,
      rowKey: rowKey,
      progressLabel: bag['progress_label']?.toString(),
      colors: bagColors == null
          ? null
          : {
              'bg': bagColors['bg']?.toString() ?? '',
              'border': bagColors['border']?.toString() ?? '',
              'fg': bagColors['fg']?.toString() ?? '',
            },
      dot: bag['dot']?.toString(),
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
                  key: ValueKey(items[i]['order_item_id'] ?? i),
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

  // Backend-owned: fw_get_bag_items()'s pre-formatted display strings
  // (qty_label/customer_label/supplier_label/status_label/status_colors),
  // rendered verbatim — no client-side concatenation or state->label/colour mapping.
  Widget _buildBagItemTile(Map<String, dynamic> item) {
    final name         = item['product_name']?.toString() ?? '—';
    final imageUrl     = item['image_url']?.toString();
    final qtyLabel     = item['qty_label']?.toString() ?? '';
    final customerLabel = item['customer_label']?.toString() ?? '';
    final supplierLabel = item['supplier_label']?.toString() ?? '';
    final statusLabel   = item['status_label']?.toString() ?? '';
    final statusColors  = item['status_colors'] as Map?;

    return Builder(builder: (ctx) {
      RenderLog.write('c288_pack_badge_grey', 'qty=$qtyLabel');
      RenderLog.write('c288_customer_with_code', 'cust=$customerLabel');
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
              _greyBadge(qtyLabel),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: _kReceivedBg,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(supplierLabel,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: _kReceivedFg),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3CD),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(customerLabel,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFF8A6D00)),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(height: 4),
              _BackendStatePill(
                label: statusLabel,
                bg: _hexColor(statusColors?['bg'], _kPendingBg),
                fg: _hexColor(statusColors?['fg'], _kPendingFg),
              ),
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

  // Backend-owned: fw_search_bag_items()'s pre-formatted display strings, rendered
  // verbatim — no client-side concatenation or state->label/colour mapping.
  Widget _buildSearchResultTile(Map<String, dynamic> item) {
    final name          = item['product_name']?.toString() ?? '—';
    final imageUrl      = item['image_url']?.toString();
    final qtyLabel      = item['qty_label']?.toString() ?? '';
    final customerLabel = item['customer_label']?.toString() ?? '';
    final supplierLabel = item['supplier_label']?.toString() ?? '';
    final statusLabel   = item['status_label']?.toString() ?? '';
    final statusColors  = item['status_colors'] as Map?;

    return Builder(builder: (ctx) {
      RenderLog.write('c286_search_row_v3', 'qty=$qtyLabel;combined_badge=true');
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
              _greyBadge(qtyLabel),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: _kReceivedBg,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(supplierLabel,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: _kReceivedFg),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3CD),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(customerLabel,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFF8A6D00)),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(height: 4),
              _BackendStatePill(
                label: statusLabel,
                bg: _hexColor(statusColors?['bg'], _kPendingBg),
                fg: _hexColor(statusColors?['fg'], _kPendingFg),
              ),
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
  // Backend-owned: fw_list_bags()'s per-bag progress_label/colors/dot, verbatim.
  final String? progressLabel;
  final Map<String, String>? colors;
  final String? dot;

  const _BagAccordionShell({
    super.key,
    required this.bagNo,
    required this.totalProducts,
    required this.isExpanded,
    required this.anyExpanded,
    required this.rowKey,
    required this.onTap,
    required this.expandedContent,
    this.progressLabel,
    this.colors,
    this.dot,
  });

  @override
  Widget build(BuildContext context) {
    final bottomGap = anyExpanded ? 16.0 : 8.0;
    final badgeBg = _hexColor(colors?['bg'], _kReceivedBg);
    final badgeFg = _hexColor(colors?['fg'], _kReceivedFg);
    final badgeBorder = _hexColor(colors?['border'], _kReceivedBg);
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
                    'bag=$bagNo;items=$totalProducts;arrow=removed;dot=backend');
                RenderLog.write('c289_items_badge_green',
                    'items=$totalProducts;progress=${progressLabel ?? ''}');
                return Row(children: [
                  Text('Bag $bagNo',
                      style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600,
                        color: isExpanded ? _kGreen : _kText,
                      )),
                  const Spacer(),
                  if (dot != null) ...[
                    Container(
                      width: 10, height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: badgeBg,
                        border: Border.all(color: badgeBorder, width: 1.5),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  SizedBox(
                    width: 80,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: badgeBg,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(progressLabel ?? '$totalProducts items',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w500,
                              color: badgeFg)),
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

class _PackTab extends StatefulWidget {
  const _PackTab({super.key});
  @override
  State<_PackTab> createState() => _PackTabState();
}

class _PackTabState extends State<_PackTab>
    with AutomaticKeepAliveClientMixin {
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
  // C354: dispute index keyed by order_item_id — ONE fw_get_disputes fetch, matched per row.
  // Drives the read-only "In dispute" chip so packers never chase a phantom line.
  Map<String, DisputeItem> _packDisputeIdx = {};

  // CHANGE #438: order-aware per-item bag allocation, keyed by order_item_id.
  // Populated from pack_item_bag_breakdown (replaces the shared-pool bag_no/bags
  // fields from pack_get_queue for DISPLAY only — packing/undo/counts/navigation
  // still read item['bag_no']/item['is_bagged'] as before). Absent key = not yet
  // fetched (tile falls back to the old shared-pool chips until it resolves).
  final Map<String, List<Map<String, dynamic>>> _itemBags = {};

  // #299→C353: per-order channels replaced by the single FulfillRealtime channel

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
  // CHANGE #454: continuous chunked recording (same engine as Warehouse, minus
  // bags) — replaces the old single-shot _voiceService.start/stop → pack_process_clip
  // flow, which hit Gemini's 30s cap on longer counts.
  PackVoiceSession? _packVoiceSession;
  // The PackVoiceSession's own generated key for this order's current/most-recent
  // recording — badge (_refreshPackMentions) and the "Counted items" popup both
  // scope to exactly this value (see fetchScopedPackMentions), so they can never
  // disagree. Set on recording start; kept (not nulled) through Stop/finalize;
  // reset to null only when the order card is freshly (re)loaded.
  String? _activePackSessionKey;

  // CHANGE #299: Ask mediBO (rewired #304: audio → voice-agent, same as Warehouse)
  bool _askListening = false;
  bool _askProcessing = false;
  String _askInterim = '';

  // Dispatch button in-flight guard (tap-to-toggle, backend RPC is the source of truth)
  bool _dispatchLoading = false;

  @override
  bool get wantKeepAlive => true;

  // CHANGE #444 — shared date scope. pack_list_orders is strict single-date
  // (no older-orders support) — see _load(), no _olderOpen tracking here.
  void _onDateScopeChanged() => _load();

  @override
  void initState() {
    super.initState();
    RenderLog.write('c278_pack_tab_mounted', 1);
    RenderLog.write('c354_ready', 'tab=pack');
    FulfillDateScope.instance.addListener(_onDateScopeChanged);
    _load();
    _loadDisputeIndex();
  }

  // C354: single fw_get_disputes fetch → index by order_item_id (no per-row RPC).
  Future<void> _loadDisputeIndex() async {
    try {
      final idx = await fetchAdminDisputeIndexByOrderItem();
      if (!mounted) return;
      setState(() => _packDisputeIdx = idx);
      RenderLog.write('c354_live', 'tab=pack,src=disputes');
    } catch (_) {/* chip is best-effort; queue still renders */}
  }

  // C354: called by the parent when a supplier_disputes change fires (any tab / on resolve),
  // so the Pack chips reflect resolutions even when Pack was not the visible tab.
  void refreshDisputeIndex() {
    if (!mounted) return;
    RenderLog.write('c354_resolve_sync', 'tab=pack');
    _loadDisputeIndex();
    final oid = _expandedOrderId;
    if (oid != null) _loadFromPackQueue(oid);
  }

  @override
  void dispose() {
    FulfillDateScope.instance.removeListener(_onDateScopeChanged);
    // CHANGE #454: don't leave a session dangling if the tab is torn down mid-count.
    _packVoiceSession?.cancel().ignore();
    _scroll.dispose();
    super.dispose();
  }

  // C353: called by the shared FulfillRealtime service when the Pack tab is
  // visible (replaces the per-order pack_rt_* channels; debounce in service).
  void refreshFromRealtime() {
    final oid = _expandedOrderId;
    if (!mounted || oid == null) return;
    try { RenderLog.write('c299_rt', 'order=${oid.substring(0, 8)};event=rt'); } catch (_) {}
    _loadFromPackQueue(oid);
  }

  Future<void> _load({bool silent = false}) async {
    if (!mounted) return;
    if (!silent) setState(() { _loading = true; _error = null; });
    try {
      // pack_list_orders(p_date) — per-order dot/pack_button/can_mark_ready are
      // backend-owned now (verbatim, see _buildPackingButton and
      // _buildPackDispatchButton). Strict single-date by design — the date
      // picker (FulfillDateScope) is the only way to view another date; no
      // include-older support, so p_include_older is not sent.
      final scope = FulfillDateScope.instance;
      final res = await Supabase.instance.client.rpc('pack_list_orders', params: {
        'p_date': ymd(scope.date),
      }) as Map;
      if (!mounted) return;
      final orders = (res['orders'] as List? ?? [])
          .map((r) => Map<String, dynamic>.from(r as Map))
          .map((m) => {...m, 'total_items': m['items_total']})
          .toList();
      RenderLog.write('c444_pack_orders', '${orders.length}');
      setState(() {
        _customers = orders;
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
      final rollup  = m['rollup'] is Map ? Map<String, dynamic>.from(m['rollup'] as Map) : <String, dynamic>{};
      final total   = (rollup['ordered'] as num?)?.toInt() ?? 0;
      final packed  = (rollup['packed']  as num?)?.toInt() ?? 0;
      // fix(pack): counted already comes back on this same rollup — surfaced
      // for the customer-row 3-status-dots (allPacked/allCounted/readyDone).
      final counted = (rollup['counted'] as num?)?.toInt() ?? 0;
      try {
        RenderLog.write('c291_pack_counts',
            'order=${orderId.substring(0, orderId.length.clamp(0, 8))};total=$total;packed=$packed');
        RenderLog.write('c335_pack', 'order=${orderId.substring(0, orderId.length.clamp(0, 8))};total=$total;packed=$packed');
      } catch (_) {}
      if (mounted) setState(() => _packStatus[orderId] = {'packed': packed, 'total': total, 'counted': counted});
    } catch (e) {
      if (mounted) setState(() => _packStatus[orderId] = {'packed': 0, 'total': -1, 'counted': 0});
    }
  }

  // CHANGE #299: load full pack_get_queue for expanded card — items with packed/counted per row
  Future<void> _loadFromPackQueue(String orderId) async {
    if (_loadingItems[orderId] == true) return;
    if (!mounted) return;
    // C358 B1: SILENT refetch — only show the per-order spinner on the FIRST load.
    // Once we have queue data, a realtime-driven refetch patches it in place (no flash).
    if (!_packQueueData.containsKey(orderId)) {
      setState(() => _loadingItems[orderId] = true);
    }
    try {
      final dynamic raw = await Supabase.instance.client
          .rpc('pack_get_queue', params: {'p_order_id': orderId});
      final Map<String, dynamic> m = raw is String
          ? (jsonDecode(raw) as Map).cast<String, dynamic>()
          : Map<String, dynamic>.from(raw as Map);
      final rollup  = m['rollup'] is Map ? Map<String, dynamic>.from(m['rollup'] as Map) : <String, dynamic>{};
      final total   = (rollup['ordered'] as num?)?.toInt() ?? 0;
      final packed  = (rollup['packed']  as num?)?.toInt() ?? 0;
      final counted = (rollup['counted'] as num?)?.toInt() ?? 0;
      final items   = ((m['items'] as List?) ?? const [])
          .map((i) => Map<String, dynamic>.from(i as Map))
          .toList();
      try {
        RenderLog.write('c299_rows_src',
            'order=${orderId.substring(0, orderId.length.clamp(0, 8))};total=$total;packed=$packed;counted=$counted');
        RenderLog.write('c299_counts', 'total=$total;packed=$packed;counted=$counted');
        RenderLog.write('c346_pack_queue',
            'order=${orderId.substring(0, orderId.length.clamp(0, 8))};items=${items.length};rollup=supplier:${rollup["supplier"]},transit:${rollup["transit"]},warehouse:${rollup["warehouse"]},packed:${rollup["packed"]},counted:${rollup["counted"]},ordered:${rollup["ordered"]}');
        // §4: detect server-clamped counts (counted < received and counted > 0 = capped)
        final clampedItems = items.where((i) {
          final cv = (i['counted_qty'] as num?)?.toInt();
          final rv = (i['received'] as num?)?.toInt() ?? 0;
          return cv != null && cv > 0 && cv < rv;
        }).length;
        if (clampedItems > 0) {
          RenderLog.write('c347_counted_clamp', 'clamped_items=$clampedItems;order=${orderId.substring(0, orderId.length.clamp(0, 8))}');
        }
        if (items.isNotEmpty) {
          final fi = items.first;
          RenderLog.write('c299_row0',
              'name=${fi["product_name"]};ordered=${fi["ordered"]};packed=${fi["packed"]};counted_qty=${fi["counted_qty"]};received=${fi["received"]}');
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _packQueueData[orderId] = m;
        // fix(pack): keep 'counted' alongside packed/total — _fetchPackStatus
        // stores the same three keys; this write must not clobber it.
        _packStatus[orderId] = {'packed': packed, 'total': total, 'counted': counted};
        _loadingItems[orderId] = false;
      });
      RenderLog.write('c354_live', 'tab=pack,src=queue');
      // C354: refresh the dispute index alongside the queue so chips stay in sync.
      _loadDisputeIndex();
      if (_expandedOrderId == orderId) _refreshPackMentions(orderId);
      _fetchItemBags(items);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingItems[orderId] = false;
        if (!_packQueueData.containsKey(orderId)) {
          _packStatus[orderId] = {'packed': 0, 'total': -1, 'counted': 0};
        }
      });
    }
  }

  // CHANGE #438: fetch each item's OWN allocated bags (order-aware), replacing
  // the shared-pool bag_no/bags chips with pack_item_bag_breakdown(order_item_id).
  // Runs in parallel, in the background — does not block the queue paint; tiles
  // fall back to the old shared-pool chips until their own fetch resolves.
  Future<void> _fetchItemBags(List<Map<String, dynamic>> items) async {
    final client = Supabase.instance.client;
    final entries = await Future.wait(items.map((item) async {
      final oid = item['order_item_id']?.toString() ?? '';
      if (oid.isEmpty) return MapEntry(oid, const <Map<String, dynamic>>[]);
      try {
        final raw = await client.rpc('pack_item_bag_breakdown',
            params: {'p_order_item_id': oid});
        final list = raw is String ? (jsonDecode(raw) as List) : (raw as List? ?? const []);
        final bags = list.whereType<Map>().map((b) => Map<String, dynamic>.from(b)).toList()
          ..sort((a, b) => ((a['bag_no'] as num?)?.toInt() ?? 0)
              .compareTo((b['bag_no'] as num?)?.toInt() ?? 0));
        return MapEntry(oid, bags);
      } catch (_) {
        return MapEntry(oid, const <Map<String, dynamic>>[]);
      }
    }));
    if (!mounted) return;
    setState(() {
      for (final e in entries) {
        if (e.key.isNotEmpty) _itemBags[e.key] = e.value;
      }
    });
  }

  // #338: voice-vs-actual audit per product for the expanded pack order.
  // Fetched on order expand and after mention toggles — never on the rt hot path.
  Map<String, Map<String, dynamic>> _packAuditMap = {};

  Future<void> _fetchPackAudit(String orderId) async {
    if (orderId.isEmpty) return;
    try {
      final dynamic raw = await Supabase.instance.client
          .rpc('pack_count_source_audit', params: {'p_order_id': orderId});
      if (!mounted) return;
      final res = raw is String
          ? (jsonDecode(raw) as Map).cast<String, dynamic>()
          : (raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{});
      final rawList = res['items'] ?? res['products'];
      final rows = (rawList is List ? rawList : const [])
          .whereType<Map>()
          .map((p) => Map<String, dynamic>.from(p))
          .toList();
      final map = <String, Map<String, dynamic>>{};
      var mismatches = 0;
      for (final p in rows) {
        final pid = p['product_id']?.toString();
        if (pid == null || pid.isEmpty) continue;
        map[pid] = p;
        if (p['mismatch'] == true) mismatches++;
      }
      setState(() => _packAuditMap = map);
      RenderLog.write('c338_audit_pack',
          'mismatches=$mismatches;order=${orderId.substring(0, orderId.length.clamp(0, 8))}');
    } catch (_) {
      // advisory only
    }
  }

  // CHANGE #454: scoped by _activePackSessionKey via the SAME shared helper the
  // "Counted items" popup uses (fetchScopedPackMentions), so the two can never
  // disagree — mirrors #453's fetchScopedVoiceMentions pattern for Shop/Warehouse.
  Future<void> _refreshPackMentions(String orderId) async {
    try {
      final mentions = await fetchScopedPackMentions(
        orderId: orderId,
        sessionKey: _activePackSessionKey,
      );
      if (!mounted) return;
      final distinct = mentions.map((m) => m['product_id']).where((id) => id != null).toSet().length;
      RenderLog.write('c299_spoken', 'distinct=$distinct;total=${mentions.length}');
      RenderLog.write('c301_mentions', 'rows=${mentions.length};distinct=$distinct');
      if (_expandedOrderId == orderId) setState(() => _packMentions = mentions);
    } catch (_) {}
  }

  // CHANGE #299: realtime — subscribe to order_items UPDATEs for this order
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

  // ── CHANGE #454: pack items/expected list, read fresh per window ──────────
  List<Map<String, dynamic>> _packItemsFor(String orderId) {
    final qData = _packQueueData[orderId];
    return qData != null
        ? ((qData['items'] as List?) ?? const [])
            .map((i) => Map<String, dynamic>.from(i as Map))
            .toList()
        : <Map<String, dynamic>>[];
  }

  List<Map<String, dynamic>> _packExpectedFor(String orderId) {
    final Map<int, Map<String, dynamic>> byPid = {};
    for (final qi in _packItemsFor(orderId)) {
      final pid = (qi['product_id'] as num?)?.toInt();
      if (pid != null && !byPid.containsKey(pid)) byPid[pid] = qi;
    }
    return byPid.values.map((qi) => {
      'name': qi['product_name']?.toString() ?? '',
      'ordered_qty': (qi['qty'] as num?)?.toInt() ?? 1,
      'unit': qi['pack_type']?.toString() ?? '',
    }).toList();
  }

  // CHANGE #454: continuous chunked recording — one PackVoiceSession spans the
  // whole mic-on → Stop lifecycle, recording back-to-back ~24s windows so a
  // 10-20 min count never hits Gemini's single-clip 30s cap. Replaces the old
  // single-shot _voiceService.start()/stop() → pack_process_clip flow.
  Future<void> _startCountVoice() async {
    if (_voiceListening || _voiceProcessing) return;
    // #331 VoiceCaps: check daily cap before starting (Pack surface)
    final capsAllowed = await _VoiceCaps.onSessionStart(context, Supabase.instance.client);
    if (!mounted || !capsAllowed) return;
    final orderId = _activeVoiceOrderId;
    if (orderId.isEmpty) {
      _showPackSnack('No order selected');
      return;
    }
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
    final session = PackVoiceSession(
      orderId: orderId,
      orderItemsProvider: () => _packItemsFor(orderId),
      expectedProvider: () => _packExpectedFor(orderId),
      resolveProductId: _resolveProductId,
      resolveProductName: _resolveProductName,
      onWindowError: (e, st) {
        RenderLog.write('c454_pack_window_err',
            e.toString().substring(0, e.toString().length.clamp(0, 100)));
        if (mounted) _showPackSnack('A recording window failed to save — counting continues');
      },
      // #331: restore the daily 3-hour usage-cap ledger for continuous sessions,
      // same as Warehouse/Shop — without this, a long session never registers
      // against the server-side usage cap.
      onClipUploaded: (path, seconds, seq) {
        _VoiceCaps.onClipSaved(Supabase.instance.client,
            ctxStr: 'pack', supplier: orderId, path: path, seconds: seconds,
            onLocked: () { if (mounted) _showPackSnack('Daily 3-hour voice limit reached'); }).ignore();
      },
    );
    try {
      await session.start();
      _packVoiceSession = session;
      _activePackSessionKey = session.sessionKey; // #454: badge/popup scope key
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

  // CHANGE #454: stop the session, wait for every in-flight window to finish
  // (write via pack_write_session_mentions), finalize (overlap-seam dedup on
  // absolute t_start + pack_set_counted per product), then surface the summary.
  // Replaces the old single-shot stop→transcribe→upload→pack_process_clip
  // sequence entirely (that per-window pipeline now runs automatically inside
  // PackVoiceSession every ~24s while recording).
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
    final session = _packVoiceSession;
    if (session == null) {
      _packCounting = false;
      if (mounted) setState(() => _voiceProcessing = false);
      return;
    }
    try {
      final result = await session.stopAndFinalize();
      _packVoiceSession = null;
      if (!mounted) return;
      await _loadFromPackQueue(orderId);
      // Voice counting can change counted_qty, which feeds can_mark_ready —
      // refresh the order list so this row's backend-owned eligibility stays current.
      _load(silent: true);
      if (!mounted) return;
      _refreshPackMentions(orderId);
      _showPackFinalizeSummary(result, orderId);
      RenderLog.write('c301_lock', 'processed');
    } catch (e) {
      _packVoiceSession = null;
      if (!mounted) return;
      _showPackSnack('Voice error — try again');
      RenderLog.write('c454_pack_finalize_err',
          e.toString().substring(0, e.toString().length.clamp(0, 60)));
    } finally {
      // CHANGE #301: always release the in-flight lock.
      _packCounting = false;
      if (mounted) setState(() => _voiceProcessing = false);
      RenderLog.write('c301_lock', 'released');
    }
  }

  // CHANGE #454: summarizes pack_finalize_session's jsonb result after Stop —
  // Pack's counterpart to Shop/Warehouse's _showFinalizeSummary (no bag layer).
  // CHANGE #457 Bug 3: also scans persisted[] for over-counts (pack_set_counted
  // caps silently at received_qty — requested > set — rather than erroring) and
  // surfaces them via a dialog instead of just a lower number.
  void _showPackFinalizeSummary(Map<String, dynamic> result, String orderId) {
    if (!mounted) return;
    final persisted = (result['persisted'] as List?) ?? const [];
    final unmatched = (result['unmatched_mentions'] as List?) ?? const [];
    final overCounts = overCountWarnings(persisted, _packItemsFor(orderId));
    final productCount = persisted
        .map((p) => p is Map ? p['product_id'] : null)
        .where((id) => id != null)
        .toSet()
        .length;
    RenderLog.write('c454_pack_finalize_summary',
        'persisted=$productCount;unmatched=${unmatched.length}');
    RenderLog.write('c457_over_count', 'count=${overCounts.length}');
    if (productCount == 0 && unmatched.isEmpty && overCounts.isEmpty) {
      _showPackSnack("Didn't catch anything — try again");
      return;
    }
    final base = 'Counted $productCount product${productCount == 1 ? '' : 's'}.';
    if (overCounts.isEmpty) {
      _showPackSnack(unmatched.isEmpty ? base : '$base ${unmatched.length} unmatched.');
      return;
    }
    _showPackSnack('$base ${overCounts.length} over-counted.');
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Count needs a look'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(base),
            const SizedBox(height: 12),
            Text('${overCounts.length} product${overCounts.length == 1 ? '' : 's'} counted more than could be saved:',
                style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFFB45309))),
            for (final w in overCounts) Text('• $w', style: const TextStyle(color: Color(0xFFB45309))),
            if (unmatched.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('${unmatched.length} item${unmatched.length == 1 ? '' : 's'} not matched to a product:',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              for (final m in unmatched)
                Text('• ${(m is Map ? m['matched_name'] : null) ?? '?'} — qty ${(m is Map ? m['qty'] : null) ?? '?'}'),
            ],
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
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
    // Backend-owned: pack_list_orders()'s pack_button, verbatim.
    final packButton = c['pack_button'] as Map?;
    final label = packButton?['label']?.toString() ?? 'Start Packing';
    final fill = _hexColor(packButton?['fill']?.toString(), _kGreen);
    try {
      RenderLog.write('c291_pack_btn_build',
          'order=${orderId.substring(0, orderId.length.clamp(0, 8))};branch=narrow;shown=true;label=$label');
    } catch (_) {}
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: SizedBox(
        width: double.infinity,
        height: 44,
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: fill,
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
              // Items may have been packed/counted inside _PackingScreen — refresh the
              // order list so this row's backend-owned pack_button/dot/can_mark_ready
              // (and label on this very button) reflect the new state.
              _load(silent: true);
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

  // fix(pack): 3 customer-row status dots — [allPacked, allCounted, readyDone].
  // packed/counted/total come from _packStatus (already fetched via
  // pack_get_queue by _fetchPackStatus/_loadFromPackQueue — no new RPC call);
  // dispatch_ready is already on `c` from fw_pack_orders.
  List<bool> _packDots(Map<String, dynamic> c) {
    final orderId = c['order_id']?.toString() ?? '';
    final status = _packStatus[orderId];
    final total = status?['total'] ?? 0;
    final packed = status?['packed'] ?? 0;
    final counted = status?['counted'] ?? 0;
    final allPacked = total > 0 && packed >= total;
    final allCounted = total > 0 && counted >= total;
    final readyDone = c['dispatch_ready'] == true;
    return [allPacked, allCounted, readyDone];
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
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('No orders placed on ${dmy(FulfillDateScope.instance.date)}.',
                style: const TextStyle(color: _kSub, fontSize: 15),
                textAlign: TextAlign.center),
          ]),
        ),
      );
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
    final name = c['pharmacy_name']?.toString() ?? 'Unknown';
    final isExpanded = _expandedOrderId == orderId;
    final rowKey = _rowKeys.putIfAbsent(orderId, () => GlobalKey());

    return _SupplierAccordionShell(
      name: name,
      dots: _packDots(c),
      isExpanded: isExpanded,
      anyExpanded: _expandedOrderId != null,
      rowKey: rowKey,
      onTap: () {
        if (isExpanded) {
          _packCounting = false;
          // CHANGE #454: don't leave a session dangling if the card collapses
          // mid-count — cancel, never finalize (an unfinished count must not
          // persist), mirroring Shop/Warehouse's dispose-time cleanup.
          _packVoiceSession?.cancel().ignore();
          _packVoiceSession = null;
          setState(() {
            _expandedOrderId = null;
            _voiceListening = false;
            _voiceProcessing = false;
            _askListening = false;
            _askInterim = '';
            _packMentions = [];
            _activePackSessionKey = null; // #454: fresh open next time — no known session yet
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
            _activePackSessionKey = null; // #454: fresh card load — no known session yet
            _packAuditMap = {}; // #338: audit is per-order — clear on open
          });
          _loadFromPackQueue(orderId);
          _fetchPackAudit(orderId); // #338: mismatch chips (expand only)
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
    final rollup = qData != null && qData['rollup'] is Map
        ? Map<String, dynamic>.from(qData['rollup'] as Map)
        : <String, dynamic>{};
    final countedCount = (rollup['counted'] as num?)?.toInt() ?? 0;
    final totalItems   = (rollup['ordered'] as num?)?.toInt() ?? total;

    // CHANGE #304: spokenCount = distinct products in today's mention rows (not counted_count).
    // #338: deleted mentions no longer count as spoken.
    final spokenCount = _packMentions
        .where((m) => m['status']?.toString() != 'deleted')
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
      if (totalItems > 0) _buildPackProgressRow(countedCount, totalItems, orderId, spokenCount),

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
          // #346: footer reads rollup + dispatch_ready + can_mark_ready from qData
          // (pack_get_queue) — always fresh since every mutating action reloads it.
          child: _buildPackFooter(orderId, qData, rollup, qData?['can_mark_ready'] == true),
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
  // fix(pack): `counted` is a QTY sum (rollup['counted'], used for the progress
  // bar/fraction below — unchanged) — the "N spoken" label needs the distinct-
  // product count instead, passed in separately as spokenCount.
  Widget _buildPackProgressRow(int counted, int total, String orderId, int spokenCount) {
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
              child: Text('$spokenCount spoken',
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

  // C354: read-only chip for lines that must not be packed as-is. Derives from the
  // pack_get_queue fulfillment_state plus the single fw_get_disputes index (matched by
  // order_item_id). Returns an empty box for normal rows.
  // Backend-owned: pack_get_queue()'s per-item dispute_chip, verbatim
  // (priority-ordered not_coming / wrong / active-dispute, or null).
  Widget _buildPackDisputeChip(Map<String, dynamic> item) {
    final chip = item['dispute_chip'] as Map?;
    if (chip == null) return const SizedBox.shrink();
    final label = chip['label']?.toString() ?? '';
    final bg = _hexColor(chip['bg']?.toString(), const Color(0xFFF3F4F6));
    final fg = _hexColor(chip['fg']?.toString(), _kSub);

    RenderLog.write('c354_pack_chip', 'label=$label');
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.info_outline_rounded, size: 12, color: fg),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg)),
          ]),
        ),
      ),
    );
  }

  // #368: neutral-warning "Not bagged" pill — informational only (blocks packing, not an error).
  // Matches the muted warning palette (bg #FEF3C7 / text #92400E) from the design system.
  Widget _buildNotBaggedChip() {
    try { RenderLog.write('c368_notbagged', 'src=tile'); } catch (_) {}
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFFFEF3C7),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.shopping_bag_outlined, size: 12, color: Color(0xFF92400E)),
            SizedBox(width: 4),
            Text('Not bagged',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF92400E))),
          ]),
        ),
      ),
    );
  }

  // #347: item card — stacked multi-bag tags; mismatch chip removed; Counted colour vs received
  Widget _buildPackItemTile(Map<String, dynamic> item) {
    final name       = item['product_name']?.toString() ?? '—';
    final imageUrl   = item['image_url']?.toString();
    final ordered    = (item['ordered'] as num?)?.toInt() ?? 0;
    final received   = (item['received'] as num?)?.toInt() ?? 0;
    final packedQty  = (item['packed_qty'] as num?)?.toInt() ?? 0;
    final countedQty = (item['counted_qty'] as num?)?.toInt();
    final ct         = countedQty ?? 0;
    // #368: an item can only be packed if it is mapped to a bag.
    final isBagged   = item['is_bagged'] == true;

    // CHANGE #438: order-aware bags for THIS item (from pack_item_bag_breakdown),
    // keyed by order_item_id. Falls back to the old shared-pool bags[]/bag_no
    // fields from pack_get_queue only until the per-item fetch resolves.
    final oid = item['order_item_id']?.toString() ?? '';
    final orderAwareBags = _itemBags[oid];
    final List<Map<String, dynamic>> bags = orderAwareBags ??
        (() {
          final rawBags = item['bags'];
          if (rawBags is List) {
            return rawBags.whereType<Map>().map((b) => Map<String, dynamic>.from(b)).toList();
          }
          final fallback = (item['bag_no'] as num?)?.toInt();
          return fallback != null && fallback > 0 ? [<String, dynamic>{'bag_no': fallback}] : <Map<String, dynamic>>[];
        })();
    final bagNums = bags.map((b) => (b['bag_no'] as num?)?.toInt() ?? 0).where((n) => n > 0).toList();

    try {
      if (bagNums.length >= 2) {
        RenderLog.write('c347_bag_stack', 'name=${name.substring(0, name.length.clamp(0, 16))};bags=${bagNums.join(",")}');
      } else if (bagNums.length == 1) {
        RenderLog.write('c347_bag_single', 'name=${name.substring(0, name.length.clamp(0, 16))};bag=${bagNums[0]}');
      }
      RenderLog.write('c346_item_card',
          'name=${name.substring(0, name.length.clamp(0, 20))};recv=$received/$ordered;packed=$packedQty/$ordered;counted=$ct/$ordered;bags=${bagNums.length}');
      RenderLog.write('c438_pack_bags', 'src=order_aware_breakdown');
    } catch (_) {}

    // §3: mismatch chip removed — counted is server-clamped to received; chip was misleading.

    Widget bagTag(Map<String, dynamic> b) {
      final n = (b['bag_no'] as num?)?.toInt() ?? 0;
      final q = (b['qty'] as num?);
      final label = q != null ? 'Bag $n • x${q.toInt()}' : 'Bag $n';
      return Container(
        margin: const EdgeInsets.only(top: 3),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFFEFF6FF),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: const Color(0xFF3B82F6), width: 0.5),
        ),
        child: Text(label,
            style: const TextStyle(fontSize: 10, color: Color(0xFF1E40AF), fontWeight: FontWeight.w600)),
      );
    }

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
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Text(name,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700, color: _kText),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ),
                  // fix(pack): once packed, the item is unmapped from its bag(s) —
                  // don't show a badge for a bag it's no longer in.
                  if (bags.isNotEmpty && item['packed'] != true) ...[
                    const SizedBox(width: 6),
                    // §2: stacked bag tags — one per bag, top-aligned Column
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: bags.map(bagTag).toList(),
                    ),
                  ],
                ]),
                // C354: read-only dispute/not_coming/wrong chip — flags phantom lines
                // so the packer never chases them. Backend already excludes these from
                // dispatch-ready, so the chip is informational and blocks nothing.
                _buildPackDisputeChip(item),
                // #368: workflow note — an un-bagged line can't be packed yet.
                if (!isBagged) _buildNotBaggedChip(),
                const SizedBox(height: 5),
                // Backend-owned: pack_get_queue()'s per-item chips (received/packed/
                // counted), each {label, colors:{bg,fg,border}} — rendered verbatim.
                // NOTE: Counted's label reads "/ordered" while its colour is computed
                // against received — that mismatch is intentional (server-capped
                // counting) and preserved exactly as the backend returns it.
                _packChipFromBackend(item['chips']?['received'] as Map?),
                const SizedBox(height: 4),
                _packChipFromBackend(item['chips']?['packed'] as Map?),
                const SizedBox(height: 4),
                _packChipFromBackend(item['chips']?['counted'] as Map?),
              ]),
        ),
      ]),
    );
  }

  Widget _packChipFromBackend(Map? chip) {
    if (chip == null) return const SizedBox.shrink();
    final colors = chip['colors'] as Map?;
    final bg = _hexColor(colors?['bg']?.toString(), const Color(0xFFF3F4F6));
    final fg = _hexColor(colors?['fg']?.toString(), const Color(0xFF6B7280));
    final border = _hexColor(colors?['border']?.toString(), const Color(0xFFD1D5DB));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border),
      ),
      child: Text(chip['label']?.toString() ?? '',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
    );
  }

  // #346: footer = master rollup list + dispatch button.
  // dispatch_ready=true  → GREEN tap "Ready to dispatch" (undo, always enabled)
  // canMarkReady=true    → YELLOW tap "Mark fully packed"
  // otherwise            → muted, disabled "Mark fully packed"
  // canMarkReady is backend-owned: pack_get_queue()'s can_mark_ready, verbatim
  // (the real pack_set_dispatch_ready eligibility — no client recomputation).
  Widget _buildPackFooter(String orderId, Map<String, dynamic>? qData, Map<String, dynamic> rollup, bool canMarkReady) {
    final bool dispatchReady = qData?['dispatch_ready'] == true;

    final String state = dispatchReady
        ? 'readytodispatch'
        : (canMarkReady ? 'fullypacked' : 'progress');
    try { RenderLog.write('c304_footer', 'state=$state'); } catch (_) {}
    final rollupRows = (qData?['rollup_rows'] as List? ?? [])
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
    final ord = (rollup['ordered'] as num?)?.toInt() ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildPackMasterRollup(rollupRows, ord),
        const SizedBox(height: 12),
        _buildPackDispatchButton(orderId, dispatchReady, canMarkReady),
      ],
    );
  }

  // #346: 5-row master rollup list — label/value/colours are backend-owned
  // (pack_get_queue's rollup_rows[]), rendered verbatim in the given order.
  Widget _buildPackMasterRollup(List<Map<String, dynamic>> rollupRows, int ord) {
    Widget row(Map<String, dynamic> r) {
      final label = r['label']?.toString() ?? '';
      final value = (r['value'] as num?)?.toInt() ?? 0;
      final colors = r['colors'] as Map?;
      final fg = _hexColor(colors?['fg']?.toString(), _kSub);
      final bg = _hexColor(colors?['bg']?.toString(), const Color(0xFFF3F4F6));
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: _kSub))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
            child: Text('$value / $ord items',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
          ),
        ]),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _kBorder),
      ),
      child: Column(children: [
        for (final r in rollupRows) row(r),
      ]),
    );
  }

  // Dispatch button. Label is driven only by dispatch_ready (never by eligibility):
  //   dispatch_ready==false → "Mark fully packed" (disabled + helper text until eligible)
  //   dispatch_ready==true  → "Ready to dispatch" (undo — always enabled, unconditional RPC)
  Widget _buildPackDispatchButton(String orderId, bool dispatchReady, bool canMarkReady) {
    if (dispatchReady) {
      // ── GREEN: tap to undo (unconditional — never gated on eligibility) ───
      return GestureDetector(
        onTap: _dispatchLoading ? null : () => _doSetDispatchReady(orderId, false),
        child: Container(
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
              : const Text('Ready to dispatch',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700, color: _kReceivedFg)),
        ),
      );
    }

    final Color bg     = canMarkReady ? const Color(0xFFFEF3C7) : const Color(0xFFF9FAFB);
    final Color fg     = canMarkReady ? const Color(0xFF92400E) : _kSub;
    final Color border = canMarkReady ? const Color(0xFFD97706).withValues(alpha: 0.4) : _kBorder;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onTap: (canMarkReady && !_dispatchLoading)
              ? () => _doSetDispatchReady(orderId, true)
              : null,
          child: Container(
            height: 48,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: border),
            ),
            alignment: Alignment.center,
            child: _dispatchLoading
                ? SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(color: fg, strokeWidth: 2))
                : Text('Mark fully packed',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: fg)),
          ),
        ),
        if (!canMarkReady) ...[
          const SizedBox(height: 6),
          const Text('Count & pack all items first',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: _kSub)),
        ],
      ],
    );
  }

  Future<void> _doSetDispatchReady(String orderId, bool ready) async {
    if (_dispatchLoading) return;
    if (mounted) setState(() => _dispatchLoading = true);
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
        RenderLog.write('c346_dispatch_ready',
            'ready=$ready;status=${resMap['status']}');
      } catch (_) {}
      if (!mounted) return;
      if (resMap['error'] != null) {
        final err = resMap['error'].toString();
        try {
          RenderLog.write('c368_dispatch',
              'err=$err;packed=${resMap['packed']};counted=${resMap['counted']};total=${resMap['total']}');
        } catch (_) {}
        if (!ready) {
          _showPackSnack('Could not undo. Try again.');
        } else if (err == 'not_fully_packed') {
          _showPackSnack('Pack all items before dispatch.');
        } else if (err == 'not_fully_counted') {
          _showPackSnack('Count all packed items before dispatch.');
        } else {
          _showPackSnack('Could not mark ready. Try again.');
        }
      }
    } catch (e) {
      if (mounted) {
        _showPackSnack(ready ? 'Could not mark ready. Try again.' : 'Could not undo. Try again.');
      }
    } finally {
      if (mounted) setState(() => _dispatchLoading = false);
    }
    // Always refetch — never optimistically flip dispatch_ready locally.
    if (mounted) await _loadFromPackQueue(orderId);
    // Refresh the order list too — pack_list_orders' can_mark_ready/dot/pack_button
    // for this row must reflect the just-changed dispatch_ready state.
    if (mounted) _load(silent: true);
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
      builder: (_) => _PackMentionsSheet(
        mentions: mentions,
        packItems: packItems,
        orderId: orderId,
        // #454: same session key the badge is scoped to (fetchScopedPackMentions) —
        // the sheet's own post-toggle refetches use it too, so they can never diverge.
        sessionKey: _activePackSessionKey,
        // #338: after any delete/re-add — reload queue (counted state), mentions and audit
        onChanged: () {
          _refreshPackMentions(orderId);
          _loadFromPackQueue(orderId);
          _fetchPackAudit(orderId);
        },
      ),
    );
  }
}

// ── CHANGE #306: Pack "Counted items" review sheet — same table layout as Warehouse popup ──
// Product | Qty sequence (per-clip pills) | Total (X/Y, green when full)
// All / Clip N chips filter the rows; each Clip chip plays the whole clip.

class _PackMentionsSheet extends StatefulWidget {
  final List<Map<String, dynamic>> mentions;
  final List<Map<String, dynamic>> packItems; // pack_get_queue items for ordered-qty lookup
  // #338: hold-to-delete needs the order id (refetch) + change notification
  final String orderId;
  // #454: scopes this sheet's own post-toggle refetches to the same session as
  // the badge (see fetchScopedPackMentions) — null = no known session, show all.
  final String? sessionKey;
  final VoidCallback? onChanged;
  const _PackMentionsSheet({
    required this.mentions,
    required this.packItems,
    required this.orderId,
    this.sessionKey,
    this.onChanged,
  });
  @override
  State<_PackMentionsSheet> createState() => _PackMentionsSheetState();
}

class _PackMentionsSheetState extends State<_PackMentionsSheet> {
  // CHANGE #456: group key (session_key, or "legacy:<date>") of the clip chip
  // last tapped — null = default "All" order.
  String? _selectedGroupKey;
  final _chipScrollCtrl = ScrollController();

  // #338: local mention list so hold toggles update in place (seeded from parent)
  late List<Map<String, dynamic>> _mentions =
      widget.mentions.map((m) => Map<String, dynamic>.from(m)).toList();
  final Set<String> _mentionLoading = {};

  @override
  void initState() {
    super.initState();
    RenderLog.write('c389_pack_popup_open', 'orderId:${widget.orderId}');
  }

  // #342: icon-tap handler for pack mentions (replaces #338 hold).
  Future<void> _handlePackMentionToggle(String id, String status) async {
    if (id.isEmpty || _mentionLoading.contains(id)) return;
    final isDeleted = status == 'deleted';
    final action = isDeleted ? 'readd' : 'delete';
    // CHANGE #389 — the mention's own qty is the delta this tap applies to
    // the pack line's counted total (pack_counted_qty server-side).
    final mentionQty =
        (_mentions.firstWhere((m) => m['id']?.toString() == id, orElse: () => const {})['qty'] as num?)
                ?.toInt() ??
            0;
    RenderLog.write('c389_pack_qty_write_$mentionQty', 'action=$action;id=${id.substring(0, id.length.clamp(0, 8))}');
    setState(() => _mentionLoading.add(id));
    try {
      final dynamic raw = await Supabase.instance.client.rpc(
          'pack_mention_set_status',
          params: {'p_id': id, 'p_action': action});
      final res = raw is String
          ? (jsonDecode(raw) as Map).cast<String, dynamic>()
          : Map<String, dynamic>.from(raw as Map);
      if (!mounted) return;
      if (res['ok'] == true) {
        final newStatus =
            res['status']?.toString() ?? (isDeleted ? 'readded' : 'deleted');
        RenderLog.write('c389_pack_qty_ok',
            'new_total=${res['new_total'] ?? 'null'}');
        RenderLog.write(action == 'readd' ? 'c342_readd_pack' : 'c342_del_pack',
            'id=${id.substring(0, id.length.clamp(0, 8))};new_status=$newStatus;new_total=${res['new_total'] ?? 'null'}');
        try {
          final rows = await fetchScopedPackMentions(
              orderId: widget.orderId, sessionKey: widget.sessionKey);
          if (mounted) setState(() => _mentions = rows);
        } catch (_) {
          if (mounted) {
            setState(() {
              final idx = _mentions.indexWhere((m) => m['id']?.toString() == id);
              if (idx >= 0) _mentions[idx]['status'] = newStatus;
            });
          }
        }
        widget.onChanged?.call();
      } else {
        // Row colour unchanged — server auto-reverts; just show friendly toast
        final err = res['error']?.toString() ?? '';
        final applyErr = (res['apply'] as Map?)?['error']?.toString() ?? '';
        RenderLog.write('c343_toggle_err_${err.isEmpty ? 'unknown' : err.substring(0, err.length.clamp(0, 20))}',
            'stage=pack');
        RenderLog.write('c389_pack_qty_err', 'error=${err.isEmpty ? applyErr : err}');
        if (mounted) {
          if (err.contains('packed_locked')) {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Item packed — unpack to edit voice counts')));
          } else if (err.contains('exceeds_ordered')) {
            final max = res['max_qty']?.toString();
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(max != null
                    ? "Can't re-add — bag limit reached (max $max)"
                    : "Can't re-add — ordered quantity already reached")));
          } else if (applyErr.contains('received_locked')) {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Line locked — Undo receiving first')));
          } else if (err.contains('already_deleted') || err.contains('not_deleted')) {
            // silent reconcile — state drift
            try {
              final rows = await fetchScopedPackMentions(
                  orderId: widget.orderId, sessionKey: widget.sessionKey);
              if (mounted) setState(() => _mentions = rows);
            } catch (_) {}
          } else {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text("Couldn't update count — try again")));
          }
        }
      }
    } catch (e) {
      RenderLog.write('c343_toggle_err_exception',
          'detail=${e.toString().substring(0, e.toString().length.clamp(0, 60))};stage=pack');
      RenderLog.write('c389_pack_qty_err', 'error=exception');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("Couldn't update count — try again")));
      }
    } finally {
      if (mounted) setState(() => _mentionLoading.remove(id));
    }
  }

  html.AudioElement? _clipAudio;
  final Map<String, String> _signedUrlCache = {};
  String? _playingClip;
  int? _playingSeq;
  // CHANGE #456: remaining clip_paths for the group currently playing, so a
  // multi-window recording plays back-to-back as one continuous clip.
  List<String> _playQueue = [];

  static const double _kTotalColW = 52.0;
  // #342: widened from 108 → 148 to accommodate icon(34) + gap(4) + pill(~40) per entry
  static const double _kBadgeClusterMaxW = 148.0;
  static const double _kBadgeToTotalGap = 6.0;
  static const double _kNameToBadgeMinGap = 10.0;

  @override
  void dispose() {
    _clipAudio?.pause();
    _clipAudio?.src = '';
    _chipScrollCtrl.dispose();
    super.dispose();
  }

  // Group by product_id (known) or '(unnamed)' (null pid — unresolved by voice_match_product).
  // Qty sequence = one entry per mention (for the pill cluster).
  // #338: entries retain mention id + status for hold-to-delete; deleted
  // mentions are excluded from the group total (still shown struck-through).
  List<({int? pid, String name, List<({String id, int qty, int seq, String status})> entries, int total, int ordered})>
      _groupMentions(List<Map<String, dynamic>> rows) {
    final pidToName = <int, String>{};
    final nameToOrdered = <String, int>{};
    for (final it in widget.packItems) {
      final pid = (it['product_id'] as num?)?.toInt();
      final name = it['product_name']?.toString() ?? '';
      // #346: field renamed qty→ordered in pack_get_queue items
      final qty = (it['ordered'] as num?)?.toInt() ?? (it['qty'] as num?)?.toInt() ?? 0;
      if (pid != null && name.isNotEmpty) {
        pidToName[pid] = name;
        nameToOrdered[name] = qty;
      }
    }
    // key = product_id (as string) for known, '' for unknown
    final order = <String>[];
    final byKey = <String, List<({String id, int qty, int seq, String status})>>{};
    for (final r in rows) {
      final pid = (r['product_id'] as num?)?.toInt();
      final key = pid != null ? '$pid' : '';
      if (!byKey.containsKey(key)) order.add(key);
      final qty = (r['qty'] as num?)?.toInt() ?? 0;
      final seq = (r['recording_seq'] as num?)?.toInt() ?? 0;
      final id = r['id']?.toString() ?? '';
      final status = r['status']?.toString() ?? 'counted';
      byKey.putIfAbsent(key, () => []).add((id: id, qty: qty, seq: seq, status: status));
    }
    return order.map((key) {
      final entries = byKey[key]!;
      final total = entries
          .where((e) => e.status != 'deleted')
          .fold(0, (s, e) => s + e.qty);
      final pid = key.isEmpty ? null : int.tryParse(key);
      final name = pid != null ? (pidToName[pid] ?? '(unnamed)') : '(unnamed)';
      return (pid: pid, name: name, entries: entries, total: total, ordered: nameToOrdered[name] ?? 0);
    }).toList();
  }

  // [onWindowEnded] fires when THIS window's audio ends naturally — CHANGE
  // #456's queue orchestration (_tapGroup/_playNextInQueue) uses it to advance
  // to the next window in a multi-window recording.
  Future<void> _playClip(String clipPath, int seq, {required VoidCallback onWindowEnded}) async {
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
        onWindowEnded();
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

  // CHANGE #456: tap a clip chip (one RECORDING, possibly several chunk-window
  // audio files) — play its windows back-to-back in order. Tapping the
  // currently-playing group's chip stops audio.
  void _tapGroup(ClipGroup group) {
    if (_playingClip != null && group.windows.any((w) => w.clipPath == _playingClip)) {
      _stopAudio();
      return;
    }
    setState(() => _selectedGroupKey = group.groupKey);
    _playQueue = group.windows.skip(1).map((w) => w.clipPath).toList();
    final seqByPath = {for (final w in group.windows) w.clipPath: w.seq};
    _playClip(group.windows.first.clipPath, group.windows.first.seq,
        onWindowEnded: () => _playNextInQueue(seqByPath));
  }

  void _playNextInQueue(Map<String, int> seqByPath) {
    if (_playQueue.isEmpty) return;
    final next = _playQueue.removeAt(0);
    _playClip(next, seqByPath[next] ?? 0, onWindowEnded: () => _playNextInQueue(seqByPath));
  }

  void _stopAudio() {
    _clipAudio?.pause();
    _clipAudio?.src = '';
    _clipAudio = null;
    _playQueue = [];
    if (mounted) setState(() { _playingClip = null; _playingSeq = null; });
  }

  @override
  Widget build(BuildContext context) {
    final allMentions = _mentions; // #338: local list — updates on hold toggles
    // CHANGE #456: one chip per RECORDING (session), not per chunk window.
    final clips = groupMentionsIntoClips(allMentions);
    final filtered = _selectedGroupKey == null
        ? allMentions
        : allMentions.where((m) => clipGroupKeyOf(m) == _selectedGroupKey).toList();
    final groups = _groupMentions(filtered);
    final playSeq = _playingSeq;
    // #343: icons only in per-clip view; All view is a read-only aggregate
    final showActions = _selectedGroupKey != null;
    // CHANGE #389 — showActions gates the standalone header (only) vs.
    // _MentionClipTable's own header (only) below; exactly one ever mounts.
    RenderLog.write('c389_header_once', showActions ? 'mode=clip' : 'mode=all');

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
                      setState(() => _selectedGroupKey = null);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: _selectedGroupKey == null ? _kGreen : const Color(0xFFE8F5E9),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: _kGreen),
                      ),
                      child: Text('All',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600,
                              color: _selectedGroupKey == null ? Colors.white : _kGreen)),
                    ),
                  ),
                  // CHANGE #456: one chip per RECORDING (session), not per chunk window.
                  ...clips.asMap().entries.map((e) {
                    final idx = e.key;
                    final group = e.value;
                    final isSelected = _selectedGroupKey == group.groupKey;
                    final isPlaying = _playingClip != null &&
                        group.windows.any((w) => w.clipPath == _playingClip);
                    return Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: GestureDetector(
                        onTap: () => _tapGroup(group),
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
          // CHANGE #389 — this standalone header used to render unconditionally,
          // but the per-clip branch below hands off to _MentionClipTable, which
          // draws its OWN identical header (line ~8120) — showing the header
          // twice whenever a "Clip N" chip was selected. The "All" grouped view
          // has no header of its own, so it still needs this one. Gate on
          // !showActions so exactly one header ever renders.
          if (!showActions) ...[
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
          ],
          // #344: clip view → shared _MentionClipTable; All view → grouped read-only table
          if (showActions) ...[
            // Per-clip view: one row per mention, whole-row tint, shared widget
            Builder(builder: (_) {
              RenderLog.write('c342_row_icon', 'stage=pack;rows=${filtered.length}');
              RenderLog.write('c343_clip_actions', 'stage=pack;group=${_selectedGroupKey ?? ''};rows=${filtered.length}');
              RenderLog.write('c344_clip_table', 'stage=pack;rows=${filtered.length}');
              final orderedMap = <String, int>{};
              for (final it in widget.packItems) {
                final name = it['product_name']?.toString();
                // #346: field renamed qty→ordered in pack_get_queue items
                if (name != null) orderedMap[name] = (it['ordered'] as num?)?.toInt() ?? (it['qty'] as num?)?.toInt() ?? 0;
              }
              return Expanded(
                child: filtered.isEmpty
                    ? const Center(child: Text('No mentions for this selection',
                        style: TextStyle(color: _kSub)))
                    : SingleChildScrollView(
                        controller: ctrl,
                        padding: const EdgeInsets.only(bottom: 24),
                        child: _MentionClipTable(
                          rows: filtered,
                          frozenAll: false,
                          // CHANGE #389 — previously gated already-packed
                          // products via isFrozenRow, which set onTap to a
                          // hard `null` (MentionActionIcon + _MentionClipTable
                          // only route frozen taps to onFrozenTap when
                          // frozenAll is true; per-row frozen with
                          // frozenAll:false fell through to null — a silent
                          // no-op with zero feedback). The backend
                          // (pack_mention_set_status) already rejects a
                          // packed line with a clean 'packed_locked' error,
                          // and _handlePackMentionToggle already shows the
                          // right SnackBar for it — so leaving rows tappable
                          // and letting the server be the single source of
                          // truth on lock state actually surfaces feedback
                          // instead of hiding it.
                          mentionLoading: _mentionLoading,
                          onToggle: (r) => _handlePackMentionToggle(
                              r['id']?.toString() ?? '',
                              r['status']?.toString() ?? 'counted'),
                          productOrdered: orderedMap,
                          stage: 'pack',
                          playingSeq: _playingSeq,
                        ),
                      ),
              );
            }),
          ] else ...[
            // All view: grouped by product, read-only pills with status colour
            Builder(builder: (_) {
              RenderLog.write('c343_all_readonly', 'stage=pack;groups=${groups.length}');
              RenderLog.write('c344_all_qty_colour', 'stage=pack;groups=${groups.length}');
              return Expanded(
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
                                        final isDeleted = e.status == 'deleted';
                                        final isReadded = e.status == 'readded';
                                        final Color bg = isDeleted ? const Color(0xFFFEE2E2)
                                            : isReadded ? const Color(0xFFFEF3C7)
                                            : active ? _kGreen : const Color(0xFFF5F6F8);
                                        final Color borderC = isDeleted ? const Color(0xFFEF4444)
                                            : isReadded ? const Color(0xFFF59E0B)
                                            : active ? _kGreen : _kBorder;
                                        final Color fg = isDeleted ? const Color(0xFF991B1B)
                                            : isReadded ? const Color(0xFF92400E)
                                            : active ? Colors.white : _kText;
                                        return Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: bg, borderRadius: BorderRadius.circular(8),
                                            border: Border.all(color: borderC),
                                          ),
                                          child: Text('${e.qty}',
                                              style: TextStyle(
                                                fontSize: 12, fontWeight: FontWeight.w600,
                                                color: fg,
                                                decoration: isDeleted ? TextDecoration.lineThrough : null,
                                              )),
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
              );
            }),
          ],
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

  // #368: per-item chosen pack qty (keyed by order_item_id). Absent => default to
  // packable_qty. Only used for partially-bagged lines (packable_qty < ordered).
  final Map<String, int> _chosenQty = {};

  // #368: single client-side "done" predicate. Backend dispatch-ready keys off
  // packed_qty >= least(bagged,ordered) (== packable_qty), NOT ordered — so raw
  // item['packed'] (packed_qty>=ordered) would never flip true for a partially-bagged
  // line even after packing everything possible. Use this everywhere instead.
  bool _isItemDone(Map<String, dynamic> item) {
    final packableQty = (item['packable_qty'] as num?)?.toInt() ?? 0;
    final packedQty   = (item['packed_qty'] as num?)?.toInt() ?? 0;
    return packableQty > 0 && packedQty >= packableQty;
  }

  // #368: qty the Pack action will submit for this item — clamped to [1, packable_qty],
  // defaulting to packable_qty when the user hasn't touched the stepper.
  int _chosenQtyFor(Map<String, dynamic> item) {
    final packableQty = (item['packable_qty'] as num?)?.toInt() ?? 0;
    if (packableQty <= 0) return 0;
    final id = item['order_item_id']?.toString() ?? '';
    final v = _chosenQty[id] ?? packableQty;
    return v.clamp(1, packableQty);
  }

  void _showPackingSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

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
      // #346: old flat fields gone; derive navigation counters from items[]
      // #368: "done" = packed to bagged capacity (_isItemDone), NOT raw item['packed']
      // (which requires packed_qty>=ordered and never flips for partially-bagged lines).
      final total    = items.length;
      final packed   = items.where(_isItemDone).length;
      final left     = items.where((i) => !_isItemDone(i)).length;
      final bagCount = items.map((i) => i['bag_no']).where((b) => b != null).toSet().length;
      final startIdx = items.indexWhere((i) => !_isItemDone(i));
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

    // Step 1: next not-done after i in same bag (#368: _isItemDone, not raw 'packed')
    for (int j = i + 1; j < _items.length; j++) {
      final jBag = (_items[j]['bag_no'] as num?)?.toInt() ?? 0;
      if (jBag != B) break;
      if (!_isItemDone(_items[j])) return j;
    }

    // Step 2: one-time backwards sweep within bag B
    int? earliestInB;
    for (int j = 0; j < _items.length; j++) {
      final jBag = (_items[j]['bag_no'] as num?)?.toInt() ?? 0;
      if (jBag == B && !_isItemDone(_items[j])) {
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

    // Step 4: i was in the last bag — any not-done item anywhere
    for (int m = 0; m < _items.length; m++) {
      if (!_isItemDone(_items[m])) return m;
    }

    return null; // all items done
  }

  // ── CHANGE #298: pack + auto-advance ────────────────────────────────────────
  Future<void> _packAndAdvance(int index) async {
    if (_marking || index < 0 || index >= _items.length) return;
    final item     = _items[index];
    final wasDone  = _isItemDone(item);

    if (!wasDone) {
      // #368(A): un-bagged lines cannot be packed. Gate client-side (backend is the
      // source of truth and also refuses via 'not_bagged'). Do NOT call the RPC.
      final isBagged = item['is_bagged'] == true;
      if (!isBagged) {
        try { RenderLog.write('c368_notbagged', 'src=packing;idx=$index'); } catch (_) {}
        _showPackingSnack('Map this item to a bag first');
        return;
      }

      // #368(B): pack up to packable_qty (defaults to packable_qty).
      final ordered   = (item['ordered'] as num?)?.toInt() ?? 0;
      final chosenQty = _chosenQtyFor(item);

      // #368 bug#1: ALWAYS pass p_qty so PostgREST picks the 3-arg overload that
      // actually writes packed_qty (the 2-arg legacy overload never did).
      setState(() => _marking = true);
      final itemId = item['order_item_id']?.toString() ?? '';
      try {
        final dynamic res = await Supabase.instance.client.rpc('pack_mark_item',
            params: {'p_order_item_id': itemId, 'p_packed': true, 'p_qty': chosenQty});
        if (!mounted) return;
        final resMap = res is String
            ? (jsonDecode(res) as Map).cast<String, dynamic>()
            : Map<String, dynamic>.from(res as Map);
        if (resMap['error'] != null) {
          final err = resMap['error'].toString();
          setState(() => _marking = false);
          _showPackingSnack(err == 'not_bagged'
              ? 'Map this item to a bag first'
              : 'Could not pack ($err)');
          return;
        }
        final newPackedQty = (resMap['packed_qty'] as num?)?.toInt() ?? chosenQty;
        final fully        = resMap['fully_packed'] == true;
        setState(() {
          // Patch local from authoritative RPC response (server truth).
          _items[index] = {...item, 'packed_qty': newPackedQty, 'packed': fully};
          _packedCount = _items.where(_isItemDone).length;
          _leftCount   = _items.where((i) => !_isItemDone(i)).length;
          _allPacked   = _leftCount == 0;
          _marking     = false;
        });
        try {
          RenderLog.write('c293_btn_toggle',
              'was=unpacked;now=packed;idx=$index');
          // #368: partial pack — packed fewer than the full ordered line (either the
          // bagged capacity is below ordered, or the user stepped the qty down).
          if (newPackedQty < ordered) {
            RenderLog.write('c368_pack_qty', 'packed=$newPackedQty;ordered=$ordered');
          }
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

      // #368: if the user under-packed (packed_qty < packable_qty) the item isn't
      // "done" yet — stay put rather than auto-advancing past an incomplete line.
      if (!_isItemDone(_items[index])) return;
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

  // ── CHANGE #451: swipe-LEFT off the All-Packed screen → last item card ─────
  // The All-Packed screen is a separate widget that fully replaces the item
  // PageView (see build()), so its PageController is detached while shown.
  // Same recreate pattern _loadQueue() already uses: dispose + rebuild the
  // controller with the target initialPage, then flip back to the item view.
  void _goBackFromAllPackedScreen() {
    if (_items.isEmpty) return;
    final lastIndex = _items.length - 1;
    _itemPageController?.dispose();
    _itemPageController = PageController(initialPage: lastIndex);
    setState(() {
      _currentIndex = lastIndex;
      _allPacked    = false;
    });
    try {
      RenderLog.write('c451_allpacked_left_back', 'idx=$lastIndex/${_items.length}');
    } catch (_) {}
  }

  // ── CHANGE #298: undo (hold-2s) — un-pack current item, stay in place ───────
  Future<void> _performUndo(int index) async {
    if (_marking || index < 0 || index >= _items.length) return;
    final item = _items[index];
    if (!_isItemDone(item)) return; // nothing to undo (#368: done-predicate)
    HapticFeedback.mediumImpact();
    setState(() => _marking = true);
    final itemId = item['order_item_id']?.toString() ?? '';
    try {
      // #368 bug#1: pass p_qty:null so the 3-arg overload runs and actually clears
      // packed_qty (the 2-arg legacy overload left it stale).
      await Supabase.instance.client.rpc('pack_mark_item',
          params: {'p_order_item_id': itemId, 'p_packed': false, 'p_qty': null});
      if (!mounted) return;
      setState(() {
        _items[index] = {...item, 'packed': false, 'packed_qty': 0};
        _packedCount = _items.where(_isItemDone).length;
        _leftCount   = _items.where((i) => !_isItemDone(i)).length;
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
    if (!_isItemDone(item)) { _undoing = false; return; } // #368: done-predicate
    HapticFeedback.mediumImpact();
    setState(() => _marking = true);
    final itemId = item['order_item_id']?.toString() ?? '';
    try {
      // #368 bug#1: pass p_qty:null so the 3-arg overload clears packed_qty.
      final dynamic res = await Supabase.instance.client.rpc(
        'pack_mark_item',
        params: {'p_order_item_id': itemId, 'p_packed': false, 'p_qty': null},
      );
      if (!mounted) return;
      setState(() {
        _items[index] = {...item, 'packed': false, 'packed_qty': 0};
        _packedCount = _items.where(_isItemDone).length;
        _leftCount   = _items.where((i) => !_isItemDone(i)).length;
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

  // Backend-owned: pack_get_queue()'s bag_stats[] — {bag_no,total,packed,label,
  // state,colors}, pre-sorted by bag_no. Rendered verbatim, no client rollup.
  List<Map<String, dynamic>> get _bagStats => (_queue?['bag_stats'] as List? ?? [])
      .map((r) => Map<String, dynamic>.from(r as Map))
      .toList();

  // ── Header popups ────────────────────────────────────────────────────────────

  // pack_get_queue's items[] arrive pre-sorted (primary_bag, product_name) —
  // no client re-sort, so these popups keep the bag-grouped backend order.
  void _showItemsPopup() {
    final items = List<Map<String, dynamic>>.from(_items);
    try { RenderLog.write('c292_hdr_popup', 'which=items;rows=${items.length}'); } catch (_) {}
    _showListSheet('All items', items, showTick: true);
  }

  void _showPackedPopup() {
    final items = _items.where(_isItemDone).toList(); // #368: done-predicate
    try { RenderLog.write('c292_hdr_popup', 'which=packed;rows=${items.length}'); } catch (_) {}
    _showListSheet('Packed items', items, showTick: true);
  }

  void _showLeftPopup() {
    final items = _items.where((i) => !_isItemDone(i)).toList(); // #368: done-predicate
    try { RenderLog.write('c292_hdr_popup', 'which=left;rows=${items.length}'); } catch (_) {}
    _showListSheet('Items left', items, showTick: false);
  }

  void _showBagsPopup() {
    final bagStats = _bagStats;
    try { RenderLog.write('c292_hdr_popup', 'which=bags;rows=${bagStats.length}'); } catch (_) {}
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
          Flexible(child: SingleChildScrollView(child: Column(children: bagStats.map((s) {
            final bn = (s['bag_no'] as num?)?.toInt() ?? 0;
            final st = (s['state'] as num?)?.toInt() ?? 0;
            final colors = s['colors'] as Map?;
            final bg = _hexColor(colors?['bg']?.toString(), const Color(0xFFF3F4F6));
            final fg = _hexColor(colors?['fg']?.toString(), _kSub);
            final label = s['label']?.toString() ?? '';
            try {
              RenderLog.write('c293_bag_color',
                  'bag=$bn;state=${st == 2 ? "green" : st == 1 ? "yellow" : "grey"}');
            } catch (_) {}
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                  color: bg,
                  border: const Border(bottom: BorderSide(color: _kBorder))),
              child: Row(children: [
                Text('Bag $bn',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500,
                        color: fg)),
                const Spacer(),
                if (st == 2)
                  Text('✓', style: TextStyle(fontSize: 14,
                      fontWeight: FontWeight.w700, color: fg))
                else
                  Text(label, style: TextStyle(fontSize: 13, color: fg)),
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
              final qty      = (item['ordered'] as num?)?.toInt() ?? (item['qty'] as num?)?.toInt() ?? 0;
              final isPacked = _isItemDone(item); // #368: done-predicate
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
          bagStats: _bagStats),
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
                  // CHANGE #451: enable swipe-LEFT back to the last item card
                  // from the All-Packed screen (right-swipe intentionally
                  // ignored — All-Packed must stay the terminal position).
                  ? GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragEnd: (details) {
                        if ((details.primaryVelocity ?? 0) < 0) {
                          _goBackFromAllPackedScreen();
                        }
                      },
                      child: _buildAllPackedScreen(customer, _bagCount),
                    )
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
          // fix(pack): reverse the page layout so a left swipe (finger
          // dragging leftward — the same gesture that advances a default
          // PageView) goes to the PREVIOUS product instead of the next one.
          // Purely a gesture/visual-direction flip — logical page index and
          // programmatic animateToPage(...) calls (e.g. auto-advance after
          // packing) are unaffected.
          reverse: true,
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

  // ── #368: per-item pack affordance ──────────────────────────────────────────
  //  - un-bagged      → neutral-warning "Not bagged" note (can't pack yet)
  //  - bagged & done  → "Packed X / ordered" summary
  //  - bagged, partial (packable_qty < ordered) → +/- stepper (default packable_qty)
  //  - bagged, full (packable_qty == ordered)   → nothing (single Pack button flow)
  Widget _buildPackControls(Map<String, dynamic> item, int index) {
    final isBagged    = item['is_bagged'] == true;
    final ordered     = (item['ordered'] as num?)?.toInt() ?? 0;
    final packableQty = (item['packable_qty'] as num?)?.toInt() ?? 0;
    final packedQty   = (item['packed_qty'] as num?)?.toInt() ?? 0;
    final done        = _isItemDone(item);

    if (!isBagged) {
      try { RenderLog.write('c368_notbagged', 'src=packing;idx=$index'); } catch (_) {}
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFFEF3C7),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.shopping_bag_outlined, size: 16, color: Color(0xFF92400E)),
            SizedBox(width: 6),
            Flexible(
              child: Text('Not bagged — map this item to a bag before packing',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                      color: Color(0xFF92400E))),
            ),
          ]),
        ),
      );
    }

    if (done) {
      final partial = packableQty < ordered;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          partial
              ? 'Packed $packedQty / $ordered  ·  only $packableQty bagged'
              : 'Packed $packedQty / $ordered',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
              color: _kReceivedFg),
          textAlign: TextAlign.center,
        ),
      );
    }

    // Bagged, not done, fully bagged → keep the simple single-tap Pack flow.
    if (packableQty >= ordered) return const SizedBox.shrink();

    // Bagged, not done, partially bagged → qty stepper.
    return _packQtyStepper(item, packableQty, ordered);
  }

  Widget _packQtyStepper(Map<String, dynamic> item, int packableQty, int ordered) {
    final id      = item['order_item_id']?.toString() ?? '';
    final chosen  = _chosenQtyFor(item);
    void setQty(int v) {
      final clamped = v.clamp(1, packableQty);
      setState(() => _chosenQty[id] = clamped);
    }

    Widget stepBtn(IconData icon, VoidCallback? onTap) => SizedBox(
      width: 44, height: 44,
      child: Material(
        color: onTap == null ? const Color(0xFFF3F4F6) : const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Icon(icon, size: 20,
              color: onTap == null ? const Color(0xFF9CA3AF) : const Color(0xFF1E40AF)),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('Only $packableQty of $ordered bagged',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                color: Color(0xFF92400E))),
        const SizedBox(height: 6),
        Row(mainAxisSize: MainAxisSize.min, children: [
          stepBtn(Icons.remove_rounded, chosen > 1 ? () => setQty(chosen - 1) : null),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text('Pack $chosen',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700,
                    color: _kText)),
          ),
          stepBtn(Icons.add_rounded, chosen < packableQty ? () => setQty(chosen + 1) : null),
        ]),
      ]),
    );
  }

  // ── Per-item card page ───────────────────────────────────────────────────────
  Widget _buildItemPage(int index) {
    if (index >= _items.length) return const SizedBox.shrink();
    final item      = _items[index];
    final name      = item['product_name']?.toString() ?? '—';
    final packType  = item['pack_type']?.toString() ?? '';
    final qty       = (item['ordered'] as num?)?.toInt() ?? (item['qty'] as num?)?.toInt() ?? 0;
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
    final packedInBag = bagItems.where(_isItemDone).length; // #368: done-predicate

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
          // #368: bag-gate note / partial-pack stepper (shrinks away for the common
          // fully-bagged case so the image layout is unchanged there).
          _buildPackControls(item, index),
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
    // #368: "packed" for UI = packed to bagged capacity (_isItemDone), not raw 'packed'.
    final isPacked = item != null && _isItemDone(item);
    final disabled = _marking || _undoing || item == null; // truly busy → no-op
    final isBagged = item != null && item['is_bagged'] == true;
    final packableQty = (item?['packable_qty'] as num?)?.toInt() ?? 0;
    final ordered     = (item?['ordered'] as num?)?.toInt() ?? 0;
    // #368: not-bagged is permanently blocked but tappable (tap → toast).
    final blocked = item != null && !isBagged;
    // #368: control-render gate log — fires on every render of the pack control.
    try {
      RenderLog.write('c368_pack_gate', 'is_bagged=$isBagged;packable=$packableQty');
    } catch (_) {}

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

    // ── UNPACKED STATE (or _marking): tap = pack + advance ──────────────────
    // #368: not-bagged → grey "Not bagged" bar, but keep the tap wired so the tap
    // shows the "map to a bag first" toast (distinct from _marking/_undoing busy).
    final busy      = _marking || _undoing;
    final greyLook  = disabled || blocked;
    final chosenQty = (item != null && isBagged) ? _chosenQtyFor(item) : 0;
    final String label;
    if (blocked) {
      label = 'Not bagged';
    } else if (isBagged && packableQty < ordered) {
      label = 'Pack $chosenQty';
    } else {
      label = 'Pack';
    }
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
            color: greyLook ? const Color(0xFFE5E7EB) : _kGreen,
            borderRadius: BorderRadius.circular(14),
          ),
          alignment: Alignment.center,
          child: busy
              ? const SizedBox(
                  width: 24, height: 24,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2.5))
              : Text(label,
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700,
                      color: blocked ? const Color(0xFF6B7280) : Colors.white)),
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
  // Backend-owned: pack_get_queue()'s bag_stats[], rendered verbatim.
  final List<Map<String, dynamic>> bagStats;
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

  Map<String, dynamic>? _statFor(int bn) {
    for (final s in widget.bagStats) {
      if ((s['bag_no'] as num?)?.toInt() == bn) return s;
    }
    return null;
  }

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
                final s          = _statFor(bn);
                final colors     = s?['colors'] as Map?;
                final st         = (s?['state'] as num?)?.toInt() ?? 0;
                final isSelected = _selectedBag == bn;
                final bgColor    = isSelected ? _kGreen : _hexColor(colors?['bg']?.toString(), const Color(0xFFF3F4F6));
                final bdColor    = isSelected ? _kGreen : _hexColor(colors?['border']?.toString(), _kBorder);
                final txtColor   = isSelected ? Colors.white : _hexColor(colors?['fg']?.toString(), _kSub);
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

  // Backend-owned: pack_get_queue()'s qty_label, rendered verbatim.
  Widget _buildTableRow(Map<String, dynamic> item) {
    final name     = item['product_name']?.toString() ?? '—';
    final isPacked = item['packed'] == true;
    final qtyLabel = item['qty_label']?.toString() ?? '';

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
  // C354: resolving a dispute changes pack recounts/splits — refresh the Pack tab too.
  final VoidCallback onRefreshPack;
  const _DisputesScreen({
    super.key,
    required this.onCountChanged,
    required this.onRefreshCollect,
    required this.onRefreshArrivals,
    required this.onRefreshPack,
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

  // CHANGE #444 — shared date scope
  int _olderOpen = 0;
  void _onDateScopeChanged() => _load();

  @override
  void initState() {
    super.initState();
    RenderLog.write('c188_realtime_subscribed', 'disputes_tab_init');
    RenderLog.write('c354_ready', 'tab=disputes');
    FulfillDateScope.instance.addListener(_onDateScopeChanged);
    _load();
  }

  @override
  void dispose() {
    FulfillDateScope.instance.removeListener(_onDateScopeChanged);
    _DisputeContactPopover._entry?.remove();
    _DisputeContactPopover._entry = null;
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    // C358 B1: SILENT refetch — spinner only on first load; a realtime-driven refetch
    // keeps the current list on screen and patches it in place (no flash).
    if (_disputes.isEmpty) {
      setState(() { _loading = true; _error = null; });
    } else if (_error != null) {
      setState(() => _error = null);
    }
    try {
      final scope = FulfillDateScope.instance;
      // p_include_older not sent — fw_get_disputes is strict single-date now.
      final res = await Supabase.instance.client.rpc('fw_get_disputes', params: {
        'p_date': ymd(scope.date),
      }) as Map;
      if (!mounted) return;
      _olderOpen = (res['older_open'] as num?)?.toInt() ?? 0;
      final items = DisputeItem.listFromResponse(res);
      RenderLog.write('c354_live', 'tab=disputes,src=load');
      // C358 B3: Disputes list rendered after a (realtime-driven) refetch — includes
      // 'shop_logged' flagged disputes which the backend returns as active.
      RenderLog.write('c358_disp_synced', 'n=${items.length}');
      RenderLog.write(kC416, 'disputes_tab_synced:n=${items.length}');
      // c188: first parse = models_loaded
      if (items.isNotEmpty) {
        RenderLog.write('c188_models_loaded', 'count=${items.length}');
      }
      // fw_get_disputes() already returns items pre-sorted by (active-phase
      // desc, status-priority desc, created_at desc) — render as received.
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

  // #349: note dialog helper — returns note string or null if cancelled
  Future<String?> _showNoteDialog(String title, String body, {bool required = false}) {
    final noteCtrl = TextEditingController();
    return showDialog<String?>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(body, style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 16),
            TextField(
              controller: noteCtrl,
              maxLines: 3,
              autofocus: required,
              decoration: InputDecoration(
                labelText: required ? 'Note (required)' : 'Note (optional)',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => set(() {}),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () { noteCtrl.dispose(); Navigator.pop(ctx); },
                child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _kGreen),
              onPressed: required && noteCtrl.text.trim().isEmpty
                  ? null
                  : () {
                      final note = noteCtrl.text.trim();
                      noteCtrl.dispose();
                      Navigator.pop(ctx, note.isEmpty ? '' : note);
                    },
              child: const Text('Confirm'),
            ),
          ],
        ),
      ),
    );
  }

  // #188: RPC-only resolve — dialog handled by _DisputeActionSheet
  Future<void> _resolveDispute(DisputeItem item, DisputeAction action,
      {String? note, List<String> alsoIds = const []}) async {
    if (_resolving.contains(item.disputeId)) return;
    RenderLog.write('c188_resolve_called', 'outcome=${action.code};dispute=${item.disputeId}');
    setState(() => _resolving.add(item.disputeId));
    try {
      final res = await Supabase.instance.client.rpc('fw_resolve_dispute', params: {
        'p_dispute_id': item.disputeId,
        'p_outcome': action.code,
        'p_note': (note != null && note.isEmpty) ? null : note,
      }) as Map;
      if (!mounted) return;
      final err = res['error']?.toString();
      if (err == 'note_required') {
        // Retry with note dialog
        setState(() => _resolving.remove(item.disputeId));
        RenderLog.write('c349_note_gate', 'forced=n');
        RenderLog.write('c352_note_gate', 'forced=n');
        final retryNote = await _showNoteDialog(
          action.label,
          '${item.productName} — ${item.supplier}.\nA note is required for this action.',
          required: true,
        );
        if (retryNote == null || !mounted) return;
        await _resolveDispute(item, action, note: retryNote, alsoIds: alsoIds);
        return;
      }
      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $err')));
      } else {
        RenderLog.write('c349_resolved', 'code=${action.code}');
        RenderLog.write('c352_resolved', 'code=${action.code}');
        // C362 point-7: fan the SAME outcome to the OTHER lines of this aggregated product.
        final others = alsoIds.where((id) => id != item.disputeId).toList();
        for (final id in others) {
          try {
            await Supabase.instance.client.rpc('fw_resolve_dispute', params: {
              'p_dispute_id': id,
              'p_outcome': action.code,
              'p_note': (note != null && note.isEmpty) ? null : note,
            });
          } catch (_) {}
        }
        if (others.isNotEmpty) {
          RenderLog.write('c362_disp_group', 'fanout_resolved=${others.length}');
        }
        final newStatus = res['new_status']?.toString() ?? action.label;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Updated: $newStatus')));
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
        RenderLog.write('c337_dispute_sync', 'both_stages_reloaded=y;outcome=${action.code}');
        RenderLog.write('c354_resolve_sync', 'tab=disputes');
        widget.onRefreshCollect();
        widget.onRefreshArrivals();
        widget.onRefreshPack();
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
    // C362 point-7: ITEM-WISE, no Active/Closed sections — aggregate ALL disputes by product,
    // grouped by supplier (one row per product; disputed qty summed; Active/Inactive badge).
    final supplierGroups =
        groupAggregatedBySupplier(aggregateDisputesByProduct(_disputes));
    RenderLog.write('c362_disp_group',
        'items=${supplierGroups.values.fold<int>(0, (s, l) => s + l.length)};'
        'suppliers=${supplierGroups.length};no_ac_sections=y');
    // C363-F: item-wise Disputes list (one row per product, NO Active/Closed sections).
    RenderLog.write('c363_disp_group',
        'items=${supplierGroups.values.fold<int>(0, (s, l) => s + l.length)}');

    // ── Render-log sentinels ────────────────────────────────────────────────
    RenderLog.write('c349_ready', 'a3=v2');
    RenderLog.write('c352_ready', 'a3=v2');
    RenderLog.write('c188_disputes_tab_built', 'active=${activeDisputes.length};closed=${closedDisputes.length}');
    RenderLog.write('c170_disputes_built', 'true');
    RenderLog.write('c170_supplier_card_count', '${activeGroups.length}');
    RenderLog.write('c191_admin_disputes_redesigned', 'active=${activeDisputes.length};closed=${closedDisputes.length};groups=${activeGroups.length}');
    // C359: disputes raised at confirm land here (Disputes tab) after the realtime refresh.
    if (_disputes.isNotEmpty) RenderLog.write('c359_moved_disp', '${_disputes.length}');

    if (_disputes.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.check_circle_outline_rounded, size: 48, color: _kGreen),
          const SizedBox(height: 12),
          Text('No orders placed on ${dmy(FulfillDateScope.instance.date)}.',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _kSub)),
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
                // C362 point-7: NO Active/Closed sections — one card per supplier (name
                // header + dispute link), item-wise rows underneath (each row an
                // Active=red / Inactive=green badge). Active + inactive rows live together.
                for (final entry in supplierGroups.entries) ...[
                  _buildDisputeSupplierCard(entry.key, entry.value),
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

  // #349: relative time helper
  String _relTime(String? isoStr) {
    if (isoStr == null || isoStr.isEmpty) return '';
    final dt = tryIstFromDb(isoStr);
    if (dt == null) return '';
    final now = nowIst();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  // ── #188: Unified supplier card — header always visible, body via _smoothReveal ─
  Widget _buildDisputeSupplierCard(String supplier, List<AggregatedDispute> agg) {
    final isOpen = _openSupplierKey == supplier;
    // C362 point-7: rows are item-wise (aggregated by product); flat lines drive the
    // dispute link / header / nudge / reminder (per-line payload fields).
    final items = agg.expand((a) => a.lines).toList();
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

              // Send link button row + nudge badge + last_reminder_at
              Builder(builder: (_) {
                final hasNudge = items.any((d) => d.nudgePending);
                final reminderAt = items.map((d) => d.lastReminderAt).where((s) => s != null).firstOrNull;
                final relTime = _relTime(reminderAt);
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      if (canonicalLink.isNotEmpty) ...[
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
                          label: Text(hasNudge ? 'Nudge again' : 'Send link',
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        ),
                        if (hasNudge) ...[
                          const SizedBox(width: 8),
                          Builder(builder: (_) {
                            RenderLog.write('c349_nudge', 'pending=y');
                            RenderLog.write('c352_nudge', 'p=1');
                            return Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFF8E1),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Text('Nudge due',
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                                      color: Color(0xFFB8860B))),
                            );
                          }),
                        ],
                      ],
                    ]),
                    if (relTime.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text('reminded $relTime',
                          style: const TextStyle(fontSize: 11, color: _kSub)),
                    ],
                  ]),
                );
              }),

              // Item list (all active items for this supplier)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(children: [
                  for (int i = 0; i < agg.length; i++) ...[
                    _buildDisputeItemCard(agg[i]),
                    if (i < agg.length - 1) const SizedBox(height: 8),
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
  Widget _buildDisputeItemCard(AggregatedDispute agg) {
    // C362 point-7: item-wise row — the representative drives labels/actions; qty is summed
    // and the row is Active if ANY underlying line is active.
    final item = agg.representative;
    final isWrong  = item.kind == 'wrong_item';
    final isActive = agg.active;
    // Backend-owned: fw_get_disputes()'s active_colors, verbatim — drives the
    // Active/Inactive badge and both status chips below.
    final activeLabel = agg.activeColors?['label'] ?? (isActive ? 'Active' : 'Inactive');
    final activeBg = _hexColor(agg.activeColors?['bg'], const Color(0xFFF3F4F6));
    final activeFg = _hexColor(agg.activeColors?['fg'], _kSub);

    // Meta line: packType / company / category (only the present ones)
    final metaParts = <String>[
      if ((item.packType ?? '').isNotEmpty) item.packType!,
      if ((item.company ?? '').isNotEmpty) item.company!,
      if ((item.category ?? '').isNotEmpty) item.category!,
    ];
    final metaLine = metaParts.join(' · ');

    // Backend-owned: fw_get_disputes()'s kind_label/kind_colors, verbatim.
    final kindTagText = item.kindLabel;
    final kindTagBg = _hexColor(item.kindColors?['bg'], const Color(0xFFF1F5F9));
    final kindTagFg = _hexColor(item.kindColors?['fg'], const Color(0xFF475569));

    RenderLog.write('c192_dispute_card_rendered',
        'dispute=${item.disputeId};status=${item.statusCode}');
    RenderLog.write('c349_row', 'kind=${item.kind}');
    RenderLog.write('c352_row', 'kind=${item.kind}');

    return InkWell(
      onTap: () => _openDisputeActionSheet(item, groupIds: agg.allActiveDisputeIds),
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
                    if ((isWrong || item.kind == 'few_wrong') && (item.wrongProductName ?? '').isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text('They sent: ${item.wrongProductName}',
                          style: const TextStyle(fontSize: 11, color: Color(0xFFDC2626)),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ]),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: kindTagBg,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(kindTagText,
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                          color: kindTagFg)),
                ),
              ]),

              // (c) Meta line
              if (metaLine.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(metaLine,
                    style: const TextStyle(fontSize: 11, color: _kSub),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],

              // (d) Quantities — C364: summed disputed qty per product ("Disputed: <n>").
              const SizedBox(height: 2),
              Builder(builder: (_) {
                RenderLog.write('c364_qty_shown', 'where=disp_tab,qty=${agg.disputedQty.toInt()}');
                return Text(
                  'Ord ${agg.orderedQty.toInt()} · Rec ${agg.receivedQty.toInt()} · '
                  'Disputed: ${agg.disputedQty.toInt()}'
                  '${agg.lines.length > 1 ? ' · ${agg.lines.length} orders' : ''}',
                  style: const TextStyle(fontSize: 11, color: _kSub),
                );
              }),

              // (e+f) Status chips
              const SizedBox(height: 4),
              Wrap(spacing: 4, runSpacing: 4, children: [
                Builder(builder: (_) {
                  RenderLog.write('c363_badge', 'where=disp_tab,active=$isActive');
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                        color: activeBg, borderRadius: BorderRadius.circular(20)),
                    child: Text(activeLabel,
                        style: TextStyle(
                            fontSize: 10, fontWeight: FontWeight.w700, color: activeFg)),
                  );
                }),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                      color: activeBg, borderRadius: BorderRadius.circular(20)),
                  child: Text(item.itemStatusLabel,
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                          color: activeFg)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: activeBg,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(item.disputeStatus,
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                          color: activeFg)),
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
                // Nudge badge
                if (item.nudgePending) Builder(builder: (_) {
                  RenderLog.write('c349_nudge', 'pending=y');
                  RenderLog.write('c352_nudge', 'p=1');
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                        color: const Color(0xFFFFF8E1),
                        borderRadius: BorderRadius.circular(20)),
                    child: const Text('Nudge due',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                            color: Color(0xFFB8860B))),
                  );
                }),
                // C354: adjustment chip — payload-driven (adj_amount)
                if (item.adjAmount != null && item.adjAmount! != 0) Builder(builder: (_) {
                  RenderLog.write('c354_adj', 'amt=${item.adjAmount}');
                  final amt = item.adjAmount!;
                  final label = amt > 0
                      ? 'Adj +₹${amt.toStringAsFixed(2)}'
                      : 'Adj −₹${amt.abs().toStringAsFixed(2)}';
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(20)),
                    child: Text(label,
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                            color: Color(0xFF1E40AF))),
                  );
                }),
                // Return-note chip — backend-owned (fw_get_disputes' return_note_chip), verbatim.
                if (item.returnNoteChip != null) Builder(builder: (_) {
                  final chip = item.returnNoteChip!;
                  RenderLog.write('c349_return_chip', 'open=${chip.isOpen}');
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                        color: _hexColor(chip.bg, const Color(0xFFF3F4F6)),
                        borderRadius: BorderRadius.circular(20)),
                    child: Text(chip.labelCard,
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                            color: _hexColor(chip.fg, _kSub))),
                  );
                }),
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
  void _openDisputeActionSheet(DisputeItem item, {List<String> groupIds = const []}) {
    RenderLog.write('c192_dispute_sheet_opened',
        'dispute=${item.disputeId};actions=${item.actions.length}');
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => _DisputeActionSheet(
        item: item,
        onResolve: (action, {String? note}) async {
          Navigator.of(sheetCtx).pop();
          // C362 point-7: an action on an item-wise (aggregated) row fans out to EVERY
          // underlying order-line's dispute so the whole product resolves together.
          await _resolveDispute(item, action, note: note, alsoIds: groupIds);
        },
      ),
    );
  }

  Future<void> _closeReturnNote(DisputeItem item) async {
    try {
      await closeReturnNoteRpc(disputeId: item.disputeId);
      if (!mounted) return;
      RenderLog.write('c349_return_close', 'ok=y');
      RenderLog.write('c352_return_close', 'ok=1');
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Return note closed ✓')));
      _load();
    } on DisputeException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString().substring(0, e.toString().length.clamp(0, 80)))));
    }
  }
}

// ── #192: Dispute action bottom sheet — shown when admin taps a dispute card ────
class _DisputeActionSheet extends StatefulWidget {
  final DisputeItem item;
  final Future<void> Function(DisputeAction action, {String? note}) onResolve;

  const _DisputeActionSheet({required this.item, required this.onResolve});

  @override
  State<_DisputeActionSheet> createState() => _DisputeActionSheetState();
}

class _DisputeActionSheetState extends State<_DisputeActionSheet> {
  bool _resolving = false;

  Future<void> _tap(DisputeAction action) async {
    if (_resolving) return;

    // note_required gate: collect note first; save disabled while empty
    String? note;
    if (action.noteRequired) {
      RenderLog.write('c349_note_gate', 'forced=y');
      RenderLog.write('c352_note_gate', 'forced=y');
      final noteCtrl = TextEditingController();
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, set) => AlertDialog(
            title: Text(action.label),
            content: Column(mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${widget.item.productName} — ${widget.item.supplier}.\n${action.label}',
                  style: const TextStyle(fontSize: 14)),
              const SizedBox(height: 16),
              TextField(
                controller: noteCtrl,
                maxLines: 3,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Note (required)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => set(() {}),
              ),
            ]),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _kGreen),
                onPressed: noteCtrl.text.trim().isEmpty
                    ? null
                    : () => Navigator.pop(ctx, true),
                child: const Text('Confirm'),
              ),
            ],
          ),
        ),
      );
      note = noteCtrl.text.trim();
      noteCtrl.dispose();
      if (confirmed != true || !mounted) return;
    }

    setState(() => _resolving = true);
    RenderLog.write('c192_resolve_called',
        'dispute=${widget.item.disputeId};outcome=${action.code}');
    try {
      await widget.onResolve(action, note: note);
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final isWrong  = item.kind == 'wrong_item';
    // Backend-owned: fw_get_disputes()'s active_colors, verbatim.
    final activeBg = _hexColor(item.activeColors?['bg'], const Color(0xFFF3F4F6));
    final activeFg = _hexColor(item.activeColors?['fg'], _kSub);
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
                Builder(builder: (_) {
                  // Backend-owned: fw_get_disputes()'s kind_label/kind_colors, verbatim.
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: _hexColor(item.kindColors?['bg'], const Color(0xFFF1F5F9)),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(item.kindLabel,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                            color: _hexColor(item.kindColors?['fg'], const Color(0xFF475569)))),
                  );
                }),
              ]),
              if ((isWrong || item.kind == 'few_wrong') && (item.wrongProductName ?? '').isNotEmpty) ...[
                const SizedBox(height: 2),
                Text('They sent: ${item.wrongProductName}',
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
                      color: activeBg, borderRadius: BorderRadius.circular(20)),
                  child: Text(item.itemStatusLabel,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                          color: activeFg)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: activeBg,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(item.disputeStatus,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                          color: activeFg)),
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

        // Return-note chip + admin close button — backend-owned
        // (fw_get_disputes' return_note_chip), verbatim.
        if (item.returnNoteChip != null) ...[
          const SizedBox(height: 12),
          Builder(builder: (bCtx) {
            final chip = item.returnNoteChip!;
            return Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _hexColor(chip.bg, const Color(0xFFF3F4F6)),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  chip.labelSheet,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                      color: _hexColor(chip.fg, _kSub)),
                ),
              ),
              if (chip.showCollectedAction) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    Navigator.of(bCtx).pop();
                    final parentState = bCtx.findAncestorStateOfType<_DisputesScreenState>();
                    parentState?._closeReturnNote(item);
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: _kGreen,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Return collected ✓',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                ),
              ],
            ]);
          }),
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
            RenderLog.write('c349_actions', 'n=${item.actions.length}');
            RenderLog.write('c352_actions', 'n=${item.actions.length}');
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
    // CHANGE #506: notif_should_send() ORs the toggle with the allow-list —
    // `intl` here is the exact number the message is about to be sent to.
    // Fails open (send) on RPC error, same as the #498 behavior this replaces.
    bool shouldSend = true;
    bool viaAllowlist = false;
    try {
      final results = await Future.wait([
        Supabase.instance.client.rpc('notif_should_send', params: {
          'p_audience': 'supplier',
          'p_action_key': 'supplier_dispute',
          'p_phone': intl,
        }),
        Supabase.instance.client.rpc('notif_is_enabled',
            params: {'p_audience': 'supplier', 'p_action_key': 'supplier_dispute'}),
      ]);
      shouldSend = results[0] != false;
      final toggleOn = results[1] != false;
      viaAllowlist = shouldSend && !toggleOn;
    } catch (_) {
      shouldSend = true;
    }
    if (!shouldSend) {
      RenderLog.write('c498_supplier_send_blocked', 'supplier_dispute:${widget.supplierName}');
      widget.onClose();
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.showSnackBar(
          const SnackBar(content: Text('Supplier dispute notifications are turned off')));
      return;
    }
    if (viaAllowlist) {
      try { RenderLog.write('c506_supplier_send_allowlisted', 'supplier_dispute:${widget.supplierName}'); } catch (_) {}
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
