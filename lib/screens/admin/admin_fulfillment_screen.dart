// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../utils/render_log.dart';
import '../../utils/responsive.dart';
import '../../services/voice_receive_service.dart';
import 'voice_receive.dart';

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
        state.replaceAll('_', ' '),
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

// ── _BagScannerDialog — camera QR scan ────────────────────────────────────────

class _BagScannerDialog extends StatefulWidget {
  final String title;
  final void Function(String code) onScanned;
  const _BagScannerDialog({required this.title, required this.onScanned});

  @override
  State<_BagScannerDialog> createState() => _BagScannerDialogState();
}

class _BagScannerDialogState extends State<_BagScannerDialog> {
  late final MobileScannerController _ctrl;
  bool _detected = false;

  @override
  void initState() {
    super.initState();
    _ctrl = MobileScannerController(detectionSpeed: DetectionSpeed.normal);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 320, height: 400,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
            child: Row(children: [
              Expanded(child: Text(widget.title,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _kText))),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded, size: 20, color: _kSub),
              ),
            ]),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text('Point camera at the bag QR code',
                style: TextStyle(fontSize: 13, color: _kSub)),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
              child: MobileScanner(
                controller: _ctrl,
                errorBuilder: (context, error, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.camera_alt_outlined, size: 48, color: Color(0xFFD1D5DB)),
                      const SizedBox(height: 12),
                      const Text('Camera unavailable', style: TextStyle(color: _kSub, fontSize: 14)),
                      const SizedBox(height: 4),
                      Text(error.errorCode.name, style: const TextStyle(fontSize: 12, color: _kSub)),
                      const SizedBox(height: 16),
                      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
                    ]),
                  ),
                ),
                onDetect: (capture) {
                  if (_detected) return;
                  final code = capture.barcodes.isEmpty ? null : capture.barcodes.first.rawValue;
                  if (code != null && code.isNotEmpty) {
                    _detected = true;
                    _ctrl.stop();
                    Navigator.pop(context);
                    widget.onScanned(code);
                  }
                },
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ── Voice echo data ──────────────────────────────────────────────────────────

class _VoiceEcho {
  final String productName;
  final num allocated;
  final num leftover;
  final List<Map<String, dynamic>> rows; // from receive_product_qty

  _VoiceEcho({
    required this.productName,
    required this.allocated,
    required this.leftover,
    required this.rows,
  });
}


// ── PICK-TO-LIGHT SCREEN ─────────────────────────────────────────────────────

class _PickToLightScreen extends StatefulWidget {
  const _PickToLightScreen({super.key});

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
  bool _showVoiceText = false;
  final _voiceTextCtrl = TextEditingController();

  // ── Voice results ──
  _VoiceEcho? _lastEcho;
  Timer? _echoTimer;
  Timer? _idleTimer;
  Timer? _segmentTimer;          // fires every 3s to process realtime segments
  int _segmentCount = 0;
  final Set<String> _segmentSeenKeys = {};  // "$productId:$qty" dedup within one recording
  DateTime? _recStartTime;
  final List<List<Map<String, dynamic>>> _undoStack = [];
  final Map<int, num> _tally = {};

  // ── supplier_orders items for reconciliation expected list ──
  List<Map<String, dynamic>> _supplierOrderItems = [];

  // ── Computed ──
  Map<String, dynamic>? get _currentItem =>
      (_items.isNotEmpty && _focusIdx < _items.length) ? _items[_focusIdx] : null;

  bool get _currentIsPending =>
      (_currentItem?['fulfillment_state'] as String?) == 'pending';

  int get _pendingCount =>
      _items.where((i) => (i['fulfillment_state'] as String?) == 'pending').length;

  bool get _allDone => _items.isNotEmpty && _pendingCount == 0;

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadSuppliers();
    _initVoice();
    RenderLog.write('fulfillment_pick_to_light', 'screen_mounted');
  }

  @override
  void dispose() {
    _voiceService.dispose();
    _echoTimer?.cancel();
    _idleTimer?.cancel();
    _segmentTimer?.cancel();
    _voiceTextCtrl.dispose();
    super.dispose();
  }

  void _initVoice() {
    if (mounted) setState(() => _voiceSupported = true);
    RenderLog.write('77_voice_screen_mounted', 'true');
    RenderLog.write('voice_receive_rendered', 'true');
    RenderLog.write('82_result_cards_removed', 'true');
    RenderLog.write('82_bag_refs_removed', 'true');
    RenderLog.write('83_banners_removed', 'true');
    _probeRecorder();
  }

  Future<void> _probeRecorder() async {
    try {
      await _voiceService.probe();
      RenderLog.write('79_recorder_init_ok', 'true');
    } catch (e) {
      final msg = e.toString();
      RenderLog.write('79_recorder_error', msg.substring(0, msg.length.clamp(0, 80)));
      // Plugin missing — disable mic button so "Type instead" remains the only path.
      if (mounted) setState(() => _voiceSupported = false);
    }
  }

  // ── Settings / suppliers / box ─────────────────────────────────────────────

  Future<void> _loadSettings() async {} // bag/barcode settings removed in #82

  Future<void> _loadSuppliers() async {
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
    } catch (e) {
      if (!mounted) return;
      RenderLog.write('78_collect_query_error', e.toString().substring(0, e.toString().length.clamp(0, 80)));
      setState(() { _loadingSuppliers = false; _error = e.toString(); });
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
      _voiceListening = false; _voiceInterim = ''; _lastEcho = null;
      _supplierOrderItems = [];
      _undoStack.clear(); _tally.clear(); _segmentSeenKeys.clear();
    });
    try {
      final res = await Supabase.instance.client
          .rpc('get_receiving_box', params: {'p_supplier_name': supplier}) as List;
      if (!mounted) return;
      final items = res.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      items.sort((a, b) {
        final aPending = (a['fulfillment_state'] as String?) == 'pending' ? 0 : 1;
        final bPending = (b['fulfillment_state'] as String?) == 'pending' ? 0 : 1;
        if (aPending != bPending) return aPending - bPending;
        final bagA = (a['bag_no'] as num?)?.toInt() ?? 0;
        final bagB = (b['bag_no'] as num?)?.toInt() ?? 0;
        if (bagA != bagB) return bagA - bagB;
        return (a['product_name'] ?? '').toString().compareTo((b['product_name'] ?? '').toString());
      });
      final firstPending = items.indexWhere(
          (i) => (i['fulfillment_state'] as String?) == 'pending');
      setState(() {
        _items = items;
        _focusIdx = firstPending >= 0 ? firstPending : 0;
        _loadingBox = false;
        _showListView = false;
      });
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
      setState(() {
        _supplierOrderItems = raw
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      });
      RenderLog.write('77_supplier_order_items', '${_supplierOrderItems.length}');
      RenderLog.write('78_collect_items_loaded', '${_supplierOrderItems.length}');
    } catch (_) {
      if (mounted) setState(() => _supplierOrderItems = []);
    }
  }

  // ── Single-item record (tap path) ──────────────────────────────────────────

  Future<void> _record(String state, {int? qty}) async {
    final item = _currentItem;
    if (item == null) return;
    final itemId = item['order_item_id'] as String;
    setState(() => _recording = true);
    try {
      final res = await Supabase.instance.client.rpc('set_item_receiving', params: {
        'p_order_item_id': itemId,
        'p_state': state,
        if (qty != null) 'p_qty': qty,
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
      _advance();
    } catch (e) {
      if (!mounted) return;
      setState(() => _recording = false);
      _showSnack('Error: $e');
    }
  }

  // ── Navigation ─────────────────────────────────────────────────────────────

  void _advance() {
    final nextPending = _items.indexWhere(
        (i) => (i['fulfillment_state'] as String?) == 'pending', _focusIdx + 1);
    setState(() {
      if (nextPending >= 0) {
        _focusIdx = nextPending;
      } else {
        final firstPending = _items.indexWhere(
            (i) => (i['fulfillment_state'] as String?) == 'pending');
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

  // Tap-to-toggle: one tap = start, next tap = stop+send.
  Future<void> _toggleRecording() async {
    if (_voiceProcessing) return; // busy — ignore double-tap
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
    _segmentSeenKeys.clear();
    _segmentCount = 0;
    setState(() {
      _voiceListening = true; _voiceInterim = 'Recording…'; _voiceError = '';
    });
    RenderLog.write('77_rec_start', 'attempt');
    try {
      await _voiceService.start();
      _recStarted = true;
      RenderLog.write('79_rec_start_ok', 'true');
      // Kick off 3-second realtime segments
      _segmentTimer?.cancel();
      _segmentTimer = Timer.periodic(const Duration(seconds: 3), (_) => _processSegment());
    } catch (e) {
      _recStarted = false;
      if (!mounted) return;
      final msg = e.toString();
      if (e is MicPermissionException) {
        setState(() { _voiceListening = false; _voiceInterim = ''; _voiceSupported = false; });
        RenderLog.write('77_error', 'mic-denied');
        _showSnack('Allow microphone access to use voice receiving');
      } else {
        setState(() { _voiceListening = false; _voiceInterim = ''; _voiceError = msg; });
        RenderLog.write('77_error', msg);
        RenderLog.write('79_recorder_error', msg.substring(0, msg.length.clamp(0, 80)));
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) setState(() => _voiceError = '');
        });
      }
    }
  }

  // Fires every 3s during recording: stop current clip, send to voice-receive, restart.
  Future<void> _processSegment() async {
    if (!_voiceListening || !_recStarted) return;
    _recStarted = false;
    try {
      final result = await _voiceService.stop();
      // Restart recording immediately so the next segment captures while we process
      if (_voiceListening && mounted) {
        await _voiceService.start();
        _recStarted = true;
      }
      if (result == null || result.bytes.length < 5000) return; // silent / too short
      final expected = _buildExpectedList();
      final (:items, :transcript) = await _voiceService.transcribe(
        result.bytes, result.mime, expected: expected.isEmpty ? null : expected,
      );
      if (!mounted || items.isEmpty) return;
      _segmentCount++;
      RenderLog.write('82_segment_processed', '$_segmentCount');
      await _handleEdgeItemsRealtime(items);
    } catch (_) {
      // Segment errors are silent — continue recording
      if (_voiceListening && mounted && !_recStarted) {
        try { await _voiceService.start(); _recStarted = true; } catch (_) {}
      }
    }
  }

  Future<void> _stopAndTranscribe() async {
    _segmentTimer?.cancel();
    _segmentTimer = null;
    if (!_voiceListening) return;
    setState(() { _voiceListening = false; _voiceInterim = ''; });
    if (!_recStarted) return;
    _recStarted = false;
    setState(() => _voiceProcessing = true);
    try {
      final result = await _voiceService.stop();
      if (!mounted) { setState(() => _voiceProcessing = false); return; }
      if (result == null || result.bytes.length < 1500) {
        setState(() => _voiceProcessing = false);
        return; // trailing silence — nothing to do
      }
      RenderLog.write('77_rec_stop_bytes', '${result.bytes.length}');
      final expected = _buildExpectedList();
      RenderLog.write('77_invoke_sent', 'expected=${expected.length}');
      final (:items, :transcript) = await _voiceService.transcribe(
        result.bytes, result.mime, expected: expected.isEmpty ? null : expected,
      );
      if (!mounted) { setState(() => _voiceProcessing = false); return; }
      _segmentCount++;
      RenderLog.write('82_segment_processed', '$_segmentCount');
      if (items.isNotEmpty) await _handleEdgeItemsRealtime(items);
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      RenderLog.write('77_error', msg);
      setState(() { _voiceError = msg; });
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
        expected.add({'name': name, 'ordered_qty': (row['quantity'] as num?)?.toInt() ?? 1});
      }
    } else {
      final seenNames = <String>{};
      for (final row in _items) {
        final name = row['product_name']?.toString();
        if (name == null || !seenNames.add(name)) continue;
        final entry = <String, dynamic>{
          'name': name,
          'ordered_qty': (row['ordered_qty'] as num?)?.toInt() ?? 1,
        };
        final unit = row['pack_type']?.toString();
        if (unit != null && unit.isNotEmpty) entry['unit'] = unit;
        expected.add(entry);
        if (expected.length >= 200) break;
      }
    }
    return expected;
  }

  // Directly commit voice items — ONLY items the user actually spoke.
  // Guard: heardName must be non-empty; empty heard = Gemini guess from expected list, not speech.
  Future<void> _handleEdgeItemsRealtime(List<Map<dynamic, dynamic>> items) async {
    int matched = 0;
    int skipped = 0;
    for (final item in items) {
      final status = (item['status'] ?? 'not_on_order').toString();
      if (status == 'not_on_order') { skipped++; continue; }

      final matchedName = item['matched_name']?.toString();
      final heardName = (item['heard'] ?? item['name'] ?? '').toString().trim();
      final receivedQty = (item['received_qty'] as num?)?.toInt() ?? 1;

      // CRITICAL: skip if no actual speech was transcribed for this item.
      // voice-receive fills expected items with empty 'heard' when it guesses from context.
      if (heardName.isEmpty || heardName.length < 3) {
        skipped++;
        continue;
      }

      int? productId;
      if (matchedName != null) {
        for (final row in _items) {
          if (row['product_name']?.toString() == matchedName) {
            productId = (row['product_id'] as num?)?.toInt();
            break;
          }
        }
      }
      if (productId == null) { skipped++; continue; }

      // Dedup: skip same product+qty already committed this recording session
      final dedupeKey = '$productId:$receivedQty';
      if (_segmentSeenKeys.contains(dedupeKey)) continue;
      _segmentSeenKeys.add(dedupeKey);

      await _commitVoiceItem(
        productId: productId,
        productName: matchedName ?? heardName,
        qty: receivedQty.toDouble(),
        rawSegment: heardName,
      );
      if (!mounted) return;
      matched++;
      RenderLog.write('83_committed_from_speech', '${matchedName ?? heardName}:$receivedQty/${item['ordered_qty'] ?? '?'}');
    }
    RenderLog.write('83_segment_matched_count', '$matched');
    if (skipped > 0) RenderLog.write('83_skipped_unmatched', '$skipped');
    final done = _items.length - _pendingCount;
    RenderLog.write('83_progress', '$done/${_items.length}');
  }

  // Called from text fallback field only (typed text → local parse → match)
  Future<void> _handleVoiceTranscript(String transcript) async {
    setState(() => _voiceProcessing = true);

    final parsed = parseUtterance(transcript);
    if (parsed.isEmpty) {
      setState(() { _voiceProcessing = false; _voiceError = "Didn't catch that"; });
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _voiceError = '');
      });
      return;
    }

    // Process each segment sequentially
    for (final item in parsed) {
      // Command handling
      if (item.itemPhrase == 'undo') {
        await _voiceUndo();
        continue;
      }
      if ({'stop', 'done', 'finish', 'cancel'}.contains(item.itemPhrase)) {
        break;
      }
      if (item.itemPhrase == 'repeat' || item.itemPhrase == 'again') {
        _speakLastEcho();
        continue;
      }

      if (item.itemPhrase.isEmpty || item.itemPhrase.length < 3) {
        _showSnack("Didn't catch an item — try again or tap it");
        continue;
      }

      // Match against box
      final match = matchToBox(item.itemPhrase, _items);

      if (match is MatchNone) {
        _showSnack("'${item.itemPhrase}' not in this box — try again or tap it");
        continue;
      }

      if (match is MatchAmbiguous) {
        final chosen = await _showAmbiguityPicker(match.candidates);
        if (chosen == null) continue;
        await _voiceMarkProduct(
          productId: chosen.productId,
          productName: chosen.productName,
          qty: item.qty,
          unit: item.unit,
          rawSegment: item.rawSegment,
        );
        continue;
      }

      if (match is MatchConfident) {
        RenderLog.write('82_realtime_commit', match.productName);
        await _voiceMarkProduct(
          productId: match.productId,
          productName: match.productName,
          qty: item.qty,
          unit: item.unit,
          rawSegment: item.rawSegment,
        );
      }
    }

    if (mounted) setState(() => _voiceProcessing = false);
  }

  // Commits one item immediately (no _voiceProcessing toggle — used by auto-commit in _handleEdgeItems).
  Future<void> _commitVoiceItem({
    required int productId,
    required String productName,
    required double qty,
    required String rawSegment,
  }) async {
    final supplier = _selectedSupplier;
    if (supplier == null) return;
    try {
      final res = await Supabase.instance.client.rpc('receive_product_qty', params: {
        'p_supplier_name': supplier,
        'p_product_id': productId,
        'p_add_qty': qty,
        'p_note': 'voice: $rawSegment',
      });
      if (!mounted) return;
      final resMap = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      if (resMap['error'] != null) { _showSnack('Commit error: ${resMap['error']}'); return; }

      final allocated = (resMap['allocated'] as num?) ?? 0;
      final leftover  = (resMap['leftover']  as num?) ?? 0;
      final rawRows   = resMap['rows'] as List? ?? [];
      final rows      = rawRows.map((r) => Map<String, dynamic>.from(r as Map)).toList();

      for (final row in rows) {
        final oiid = row['order_item_id']?.toString();
        if (oiid == null) continue;
        final idx = _items.indexWhere((i) => i['order_item_id'] == oiid);
        if (idx >= 0) {
          final nowQty  = (row['now']     as num?) ?? 0;
          final ordered = (row['ordered'] as num?) ?? 0;
          setState(() {
            _items[idx]['received_qty']     = nowQty;
            _items[idx]['fulfillment_state'] = nowQty >= ordered ? 'received' : 'short';
          });
          RenderLog.write('82_row_marked_live', '$productName:${nowQty.toInt()}/${ordered.toInt()}');
        }
      }
      if (rows.isNotEmpty) _undoStack.add(rows);
      setState(() { _tally[productId] = (_tally[productId] ?? 0) + allocated; });

      final done = _items.length - _pendingCount;
      RenderLog.write('82_progress', '$done/${_items.length}');
      _speakEcho(productName, allocated, null, leftover);
    } catch (e) {
      if (mounted) _showSnack('Commit error: $e');
    }
  }

  Future<void> _voiceMarkProduct({
    required int productId,
    required String productName,
    required double? qty,
    required String? unit,
    required String rawSegment,
  }) async {
    if (qty == null) {
      // Qty not detected — show inline prompt
      final confirmed = await _showQtyPrompt(productName, productId);
      if (confirmed == null) return;
      qty = confirmed;
    }

    // Call receive_product_qty RPC
    final supplier = _selectedSupplier;
    if (supplier == null) return;

    setState(() => _voiceProcessing = true);
    try {
      final res = await Supabase.instance.client.rpc('receive_product_qty', params: {
        'p_supplier_name': supplier,
        'p_product_id': productId,
        'p_add_qty': qty,
        'p_note': 'voice: $rawSegment',
      });
      if (!mounted) return;

      final resMap = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      if (resMap['error'] != null) {
        _showSnack('Voice mark error: ${resMap['error']}');
        return;
      }

      final allocated = (resMap['allocated'] as num?) ?? 0;
      final leftover  = (resMap['leftover']  as num?) ?? 0;
      final rawRows   = resMap['rows'] as List? ?? [];
      final rows      = rawRows
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();

      // Update local _items
      for (final row in rows) {
        final oiid = row['order_item_id']?.toString();
        if (oiid == null) continue;
        final idx = _items.indexWhere((i) => i['order_item_id'] == oiid);
        if (idx >= 0) {
          final nowQty  = (row['now']     as num?) ?? 0;
          final ordered = (row['ordered'] as num?) ?? 0;
          setState(() {
            _items[idx]['received_qty']     = nowQty;
            _items[idx]['fulfillment_state'] = nowQty >= ordered ? 'received' : 'short';
          });
        }
      }

      // Push to undo stack
      if (rows.isNotEmpty) _undoStack.add(rows);

      // Update tally
      setState(() {
        _tally[productId] = (_tally[productId] ?? 0) + allocated;
      });

      // Show echo
      _showEcho(_VoiceEcho(
        productName: productName,
        allocated: allocated,
        leftover: leftover,
        rows: rows,
      ));

      RenderLog.write('voice_receive_ok', '$productName:$allocated');
      RenderLog.write('77_marked_received', '$productName');

      // Optional TTS
      _speakEcho(productName, allocated, unit, leftover);

      // Auto-advance PTL if focused item was just received
      _advanceIfReceived();
    } catch (e) {
      if (!mounted) return;
      _showSnack('Voice error: $e');
    } finally {
      if (mounted) setState(() => _voiceProcessing = false);
    }
  }

  Future<void> _voiceUndo() async {
    if (_undoStack.isEmpty) { _showSnack('Nothing to undo'); return; }
    final rows = _undoStack.removeLast();
    setState(() => _voiceProcessing = true);
    try {
      for (final row in rows) {
        final oiid = row['order_item_id']?.toString();
        final gave = (row['gave'] as num?) ?? 0;
        if (oiid == null || gave == 0) continue;
        final undoRes = await Supabase.instance.client.rpc('add_item_receiving', params: {
          'p_order_item_id': oiid,
          'p_delta': -gave,
          'p_note': 'voice undo',
        });
        if (!mounted) return;
        final resMap = undoRes is Map ? Map<String, dynamic>.from(undoRes) : <String, dynamic>{};
        if (resMap['status'] == 'ok') {
          final idx = _items.indexWhere((i) => i['order_item_id'] == oiid);
          if (idx >= 0) {
            setState(() {
              _items[idx]['received_qty']     = resMap['received_qty'];
              _items[idx]['fulfillment_state'] = resMap['state'];
            });
          }
        }
      }
      RenderLog.write('voice_receive_undo_ok', '${rows.length}_rows');
      _showSnack('↩ Undone', isGood: true);
    } catch (e) {
      if (!mounted) return;
      _showSnack('Undo failed: $e');
    } finally {
      if (mounted) setState(() => _voiceProcessing = false);
    }
  }

  void _advanceIfReceived() {
    final item = _currentItem;
    if (item == null) return;
    final state = item['fulfillment_state'] as String?;
    if (state != null && state != 'pending') _advance();
  }

  void _showEcho(_VoiceEcho echo) {
    _echoTimer?.cancel();
    setState(() => _lastEcho = echo);
    _echoTimer = Timer(const Duration(seconds: 7), () {
      if (mounted) setState(() => _lastEcho = null);
    });
  }

  void _speakEcho(String productName, num allocated, String? unit, num leftover) {
    final unitStr = unit != null ? ' ${unit}s' : '';
    final leftoverStr = leftover > 0 ? ', ${leftover.toInt()} extra' : '';
    speakText('$productName, ${allocated.toInt()}$unitStr, done$leftoverStr');
  }

  void _speakLastEcho() {
    final echo = _lastEcho;
    if (echo == null) return;
    speakText('${echo.productName}, ${echo.allocated.toInt()}, done');
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
                  0, (sum, r) => sum + ((r['ordered_qty'] as num?) ?? 0));
              final totalReceived = productRows.fold<num>(
                  0, (sum, r) => sum + ((r['received_qty'] as num?) ?? 0));
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
        0, (sum, r) => sum + ((r['ordered_qty'] as num?) ?? 0));
    final totalReceived = productRows.fold<num>(
        0, (sum, r) => sum + ((r['received_qty'] as num?) ?? 0));
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

    return Column(children: [
      _buildSupplierPicker(),
      if (_items.isNotEmpty) _buildVoicePanel(),
      if (_loadingBox)
        const Expanded(child: Center(child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2)))
      else if (_selectedSupplier == null)
        const Expanded(child: Center(
            child: Text('Choose a supplier to begin',
                style: TextStyle(color: _kSub, fontSize: 15))))
      else if (_items.isEmpty)
        const Expanded(child: Center(
            child: Text('No items in this box',
                style: TextStyle(color: _kSub, fontSize: 15))))
      else
        Expanded(child: _buildItemList()),
    ]);
  }

  // ── Voice panel ─────────────────────────────────────────────────────────────

  Widget _buildVoicePanel() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _voiceListening
            ? _kWrongFg.withValues(alpha: 0.05)
            : _voiceProcessing
                ? _kGreen.withValues(alpha: 0.06)
                : _kBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _voiceListening
              ? _kWrongFg.withValues(alpha: 0.35)
              : _voiceProcessing
                  ? _kGreen.withValues(alpha: 0.4)
                  : _kBorder,
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Top row: mic button + tally + type fallback ──
        Row(children: [
          if (!_voiceSupported) ...[
            const Icon(Icons.mic_off_rounded, size: 18, color: _kSub),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Voice unavailable — tap items below',
                  style: TextStyle(fontSize: 13, color: _kSub)),
            ),
          ] else ...[
            // Mic button — tap to start, tap again to stop
            GestureDetector(
              onTap: _toggleRecording,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 56, height: 56,
                decoration: BoxDecoration(
                  color: _voiceListening
                      ? _kWrongFg
                      : _voiceProcessing
                          ? _kSub
                          : _kGreen.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                  boxShadow: _voiceListening
                      ? [BoxShadow(color: _kWrongFg.withValues(alpha: 0.45), blurRadius: 16, spreadRadius: 3)]
                      : [],
                ),
                child: Icon(
                  _voiceListening
                      ? Icons.stop_rounded
                      : _voiceProcessing
                          ? Icons.hourglass_top_rounded
                          : Icons.mic_none_rounded,
                  color: (_voiceListening || _voiceProcessing) ? Colors.white : _kGreen,
                  size: 24,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _voiceListening
                  ? Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      const Text('● Recording… tap to stop',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _kWrongFg)),
                      if (_voiceInterim.isNotEmpty)
                        Text(_voiceInterim,
                            style: const TextStyle(fontSize: 12, color: _kSub),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                    ])
                  : _voiceProcessing
                      ? const Row(children: [
                          SizedBox(width: 16, height: 16,
                              child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2)),
                          SizedBox(width: 8),
                          Text('Processing…', style: TextStyle(fontSize: 13, color: _kSub)),
                        ])
                      : _voiceError.isNotEmpty
                          ? Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                              Text(_voiceError,
                                  style: const TextStyle(fontSize: 13, color: _kWrongFg)),
                              if (_lastTranscript.isNotEmpty)
                                Text('Heard: $_lastTranscript',
                                    style: const TextStyle(fontSize: 11, color: _kSub),
                                    maxLines: 1, overflow: TextOverflow.ellipsis),
                            ])
                          : const Text('Tap to start recording',
                              style: TextStyle(fontSize: 13, color: _kSub)),
            ),
            // Tally chip
            if (_tally.isNotEmpty) ...[
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () => _showTallySheet(),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _kReceivedBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _kReceivedFg.withValues(alpha: 0.3)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.check_rounded, size: 12, color: _kReceivedFg),
                    const SizedBox(width: 4),
                    Text('${_tally.length} spoken',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _kReceivedFg)),
                  ]),
                ),
              ),
            ],
            // Undo button
            if (_undoStack.isNotEmpty) ...[
              const SizedBox(width: 6),
              IconButton(
                onPressed: _voiceUndo,
                icon: const Icon(Icons.undo_rounded, size: 18, color: _kSub),
                tooltip: 'Undo last voice mark',
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ],
          ],
        ]),

        // ── Text type fallback ──
        if (_voiceSupported) ...[
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: AnimatedCrossFade(
                duration: const Duration(milliseconds: 200),
                crossFadeState: _showVoiceText
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                firstChild: GestureDetector(
                  onTap: () => setState(() => _showVoiceText = true),
                  child: const Text(
                    'Type instead',
                    style: TextStyle(fontSize: 12, color: _kSub,
                        decoration: TextDecoration.underline, decorationColor: _kSub),
                  ),
                ),
                secondChild: Row(children: [
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: TextField(
                        controller: _voiceTextCtrl,
                        decoration: InputDecoration(
                          hintText: 'e.g. "Amler 4 strip"',
                          hintStyle: const TextStyle(fontSize: 13, color: _kSub),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: const BorderSide(color: _kBorder),
                          ),
                          filled: true, fillColor: Colors.white,
                        ),
                        style: const TextStyle(fontSize: 13, color: _kText),
                        onSubmitted: (t) {
                          final text = t.trim();
                          if (text.isNotEmpty) {
                            _voiceTextCtrl.clear();
                            _handleVoiceTranscript(text);
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: () {
                      final text = _voiceTextCtrl.text.trim();
                      if (text.isNotEmpty) {
                        _voiceTextCtrl.clear();
                        _handleVoiceTranscript(text);
                      } else {
                        setState(() => _showVoiceText = false);
                      }
                    },
                    child: Container(
                      width: 36, height: 36, alignment: Alignment.center,
                      decoration: BoxDecoration(color: _kGreen, borderRadius: BorderRadius.circular(6)),
                      child: const Icon(Icons.send_rounded, size: 16, color: Colors.white),
                    ),
                  ),
                ]),
              ),
            ),
          ]),
        ],



        // ── Echo banner ──
        if (_lastEcho != null) _buildEchoBanner(_lastEcho!),
      ]),
    );
  }


  Widget _buildEchoBanner(_VoiceEcho echo) {
    final summary = echo.rows.map((r) {
      final bag  = r['bag_no']?.toString() ?? '?';
      final cust = (r['customer']?.toString() ?? '');
      final gave = (r['gave'] as num?)?.toInt() ?? 0;
      final ord  = (r['ordered'] as num?)?.toInt() ?? 0;
      return 'Bag $bag $cust $gave/$ord';
    }).join('  ·  ');

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _kReceivedBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _kReceivedFg.withValues(alpha: 0.3)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.check_circle_rounded, color: _kReceivedFg, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              '✓ ${echo.productName}  ·  ${echo.allocated.toInt()} allocated',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kReceivedFg),
            ),
            if (summary.isNotEmpty)
              Text(summary,
                  style: const TextStyle(fontSize: 12, color: _kReceivedFg)),
            if (echo.leftover > 0)
              Text('⚠ ${echo.leftover.toInt()} over-received (not placed)',
                  style: const TextStyle(fontSize: 11, color: _kShortFg, fontWeight: FontWeight.w600)),
          ]),
        ),
        GestureDetector(
          onTap: () => setState(() => _lastEcho = null),
          child: const Icon(Icons.close_rounded, size: 14, color: _kReceivedFg),
        ),
      ]),
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

  Widget _buildSupplierPicker() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_items.isNotEmpty) ...[
          Row(children: [
            Expanded(
              child: LinearProgressIndicator(
                value: _items.isEmpty
                    ? 0
                    : (_items.length - _pendingCount) / _items.length,
                backgroundColor: _kBorder,
                color: _kGreen,
                minHeight: 4,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '${_items.length - _pendingCount}/${_items.length}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kText),
            ),
          ]),
          const SizedBox(height: 8),
        ],
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
          child: Row(children: [
            Expanded(
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
        ),
      ]),
    );
  }

  // ── Focused item card ──────────────────────────────────────────────────────




  Widget _buildDoneState() {
    final total     = _items.length;
    final received  = _items.where((i) => (i['fulfillment_state'] as String?) == 'received').length;
    final short     = _items.where((i) => (i['fulfillment_state'] as String?) == 'short').length;
    final wrong     = _items.where((i) => (i['fulfillment_state'] as String?) == 'wrong').length;
    final notComing = _items.where((i) => (i['fulfillment_state'] as String?) == 'not_coming').length;

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
                'Collected — not yet at warehouse.\nGo to Arrivals tab to mark this box arrived.',
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

  void _showItemSheet(Map<String, dynamic> item) {
    final idx = _items.indexOf(item);
    if (idx >= 0) _focusItem(idx);
    final name   = item['product_name']?.toString() ?? '—';
    final ordQty = (item['ordered_qty'] as num?)?.toInt() ?? 0;
    final unit   = item['pack_type']?.toString() ?? '';
    // mutable sheet state: [showShort, shortDraft]
    final sheetState = <dynamic>[false, (ordQty - 1).clamp(1, ordQty)];
    showResponsiveSheet(
      context: context,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) {
          final showShort   = sheetState[0] as bool;
          final shortDraft  = sheetState[1] as int;
          final curState = (idx >= 0 && idx < _items.length)
              ? _items[idx]['fulfillment_state']?.toString() ?? 'pending'
              : 'pending';
          final isPending = curState == 'pending';
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _kText)),
              if (unit.isNotEmpty || ordQty > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 12),
                  child: Text('Ordered: $ordQty${unit.isNotEmpty ? ' $unit' : ''}',
                      style: const TextStyle(fontSize: 13, color: _kSub)),
                )
              else
                const SizedBox(height: 12),
              if (isPending) ...[
                Row(children: [
                  Expanded(child: _ActionBtn(
                    'Got all ($ordQty)', _kGreen, Icons.check_rounded,
                    _recording ? null : () async {
                      await _record('received', qty: ordQty);
                      RenderLog.write('82_sheet_commit', '$name:received');
                      if (mounted) Navigator.of(context).pop();
                    },
                    loading: _recording,
                  )),
                  const SizedBox(width: 8),
                  Expanded(child: _ActionBtn(
                    showShort ? 'Hide short' : 'Short',
                    _kShortFg, Icons.content_cut_rounded,
                    () => setS(() { sheetState[0] = !showShort;
                                   if (!showShort) sheetState[1] = (ordQty - 1).clamp(1, ordQty); }),
                  )),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: _ActionBtn('Wrong item', _kWrongFg, Icons.close_rounded,
                      _recording ? null : () async {
                        await _record('wrong');
                        RenderLog.write('82_sheet_commit', '$name:wrong');
                        if (mounted) Navigator.of(context).pop();
                      })),
                  const SizedBox(width: 8),
                  Expanded(child: _ActionBtn('Not coming', _kNotComingFg, Icons.block_outlined,
                      _recording ? null : () async {
                        await _record('not_coming');
                        RenderLog.write('82_sheet_commit', '$name:not_coming');
                        if (mounted) Navigator.of(context).pop();
                      })),
                ]),
                if (showShort) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _kBg, borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _kBorder),
                    ),
                    child: Column(children: [
                      const Text('How many received?',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _kText)),
                      const SizedBox(height: 12),
                      _QtyStepper(
                        value: shortDraft, max: ordQty,
                        onChanged: (v) {
                          setS(() { sheetState[1] = v; });
                          _record('short', qty: v).then((_) {
                            RenderLog.write('82_sheet_commit', '$name:short:$v');
                          });
                        },
                      ),
                    ]),
                  ),
                ],
              ] else ...[
                Row(children: [
                  _StatePill(curState),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: _recording ? null : () async {
                      await _record('pending');
                      if (mounted) Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.undo_rounded, size: 15),
                    label: const Text('Reset to pending'),
                    style: TextButton.styleFrom(foregroundColor: _kSub),
                  ),
                ]),
              ],
            ]),
          );
        },
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
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.qr_code_2_rounded, size: 48, color: Color(0xFFD1D5DB)),
        const SizedBox(height: 12),
        const Text('No customer bags yet', style: TextStyle(fontSize: 15, color: _kSub)),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _load, icon: const Icon(Icons.refresh, size: 16),
          label: const Text('Refresh'),
          style: OutlinedButton.styleFrom(
              foregroundColor: _kGreen, side: const BorderSide(color: _kGreen)),
        ),
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
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _load, icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('Refresh'),
            style: OutlinedButton.styleFrom(
                foregroundColor: _kSub, side: const BorderSide(color: _kBorder)),
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
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          OutlinedButton.icon(
            onPressed: _load, icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Refresh'),
            style: OutlinedButton.styleFrom(foregroundColor: _kGreen, side: const BorderSide(color: _kGreen)),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: () => setState(() => _showLabels = true),
            icon: const Icon(Icons.label_outline_rounded, size: 16),
            label: const Text('Bag Labels'),
            style: OutlinedButton.styleFrom(foregroundColor: _kSub, side: const BorderSide(color: _kBorder)),
          ),
        ]),
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
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 14),
            label: const Text('Refresh'),
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
                      ? 'Waiting on arrival — mark box arrived in the Arrivals tab'
                      : 'Still collecting — count stock in the Collect tab first',
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

// ── ARRIVALS SCREEN ───────────────────────────────────────────────────────────

class _ArrivalsScreen extends StatefulWidget {
  const _ArrivalsScreen({super.key});

  @override
  State<_ArrivalsScreen> createState() => _ArrivalsScreenState();
}

class _ArrivalsScreenState extends State<_ArrivalsScreen> {
  List<Map<String, dynamic>> _suppliers = [];
  bool _loading = true;
  String? _error;
  final Set<String> _marking = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final res = await Supabase.instance.client
          .rpc('get_supplier_arrival_status') as List;
      if (!mounted) return;
      final suppliers = res.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      // In-transit suppliers first, fully-arrived below
      suppliers.sort((a, b) {
        final aFull = (a['fully_arrived'] as bool?) == true;
        final bFull = (b['fully_arrived'] as bool?) == true;
        if (aFull != bFull) return aFull ? 1 : -1;
        return (a['supplier_name'] ?? '').toString()
            .compareTo((b['supplier_name'] ?? '').toString());
      });
      setState(() { _suppliers = suppliers; _loading = false; });
      RenderLog.write('arrivals_area_rendered', '${suppliers.length}');
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  Future<void> _markArrived(String supplier, int inTransit) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Mark arrived?',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _kText)),
        content: Text(
          'Mark $inTransit item${inTransit == 1 ? '' : 's'} from $supplier '
          'as arrived at the warehouse?',
          style: const TextStyle(fontSize: 14, color: _kSub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: _kSub)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
                backgroundColor: _kGreen,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Mark Arrived', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _marking.add(supplier));
    try {
      final res = await Supabase.instance.client
          .rpc('mark_box_arrived', params: {'p_supplier_name': supplier});
      if (!mounted) return;
      final resMap = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      if (resMap['error'] != null) {
        _showSnack('Error: ${resMap['error']}');
      } else {
        final n = (resMap['items_arrived'] as num?)?.toInt() ?? 0;
        _showSnack('$n item${n == 1 ? '' : 's'} from $supplier arrived at warehouse',
            isGood: true);
        RenderLog.write('arrivals_mark_arrived_ok', '$supplier:$n');
        await _load();
      }
    } catch (e) {
      if (!mounted) return;
      _showSnack('Error: $e');
    } finally {
      if (mounted) setState(() => _marking.remove(supplier));
    }
  }

  void _showSnack(String msg, {bool isGood = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isGood ? _kGreen : const Color(0xFFDC2626),
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2));
    }
    if (_error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.error_outline_rounded, size: 40, color: Color(0xFFD1D5DB)),
        const SizedBox(height: 12),
        Text('Error: $_error', style: const TextStyle(color: Color(0xFFDC2626), fontSize: 13)),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _load, icon: const Icon(Icons.refresh, size: 16),
          label: const Text('Retry'),
          style: OutlinedButton.styleFrom(foregroundColor: _kGreen, side: const BorderSide(color: _kGreen)),
        ),
      ]));
    }
    if (_suppliers.isEmpty) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.inventory_2_outlined, size: 48, color: Color(0xFFD1D5DB)),
          const SizedBox(height: 16),
          const Text('Nothing collected yet',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _kText)),
          const SizedBox(height: 6),
          const Text('Count stock in the Collect tab first.',
              style: TextStyle(fontSize: 13, color: _kSub), textAlign: TextAlign.center),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: _load, icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Refresh'),
            style: OutlinedButton.styleFrom(foregroundColor: _kGreen, side: const BorderSide(color: _kGreen)),
          ),
        ]),
      ));
    }

    return Column(children: [
      // Helper banner
      Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _kPendingBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _kPendingFg.withValues(alpha: 0.3)),
        ),
        child: Row(children: [
          const Icon(Icons.info_outline_rounded, size: 16, color: _kPendingFg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Collected stock becomes packable only after you mark it arrived here.',
              style: const TextStyle(fontSize: 12, color: _kPendingFg),
            ),
          ),
        ]),
      ),
      // Refresh + count row
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Row(children: [
          Text('${_suppliers.length} supplier${_suppliers.length == 1 ? '' : 's'}',
              style: const TextStyle(fontSize: 13, color: _kSub)),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 14),
            label: const Text('Refresh'),
            style: OutlinedButton.styleFrom(
                foregroundColor: _kSub, side: const BorderSide(color: _kBorder),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                visualDensity: VisualDensity.compact),
          ),
        ]),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          itemCount: _suppliers.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (_, i) => _buildSupplierCard(_suppliers[i]),
        ),
      ),
    ]);
  }

  Widget _buildSupplierCard(Map<String, dynamic> supplier) {
    final name       = supplier['supplier_name']?.toString() ?? '—';
    final collected  = (supplier['collected']   as num?)?.toInt() ?? 0;
    final arrived    = (supplier['arrived']     as num?)?.toInt() ?? 0;
    final inTransit  = (supplier['in_transit']  as num?)?.toInt() ?? 0;
    final fullyArrived = (supplier['fully_arrived'] as bool?) == true;
    final isMarking  = _marking.contains(name);

    return Container(
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: fullyArrived
              ? _kReceivedFg.withValues(alpha: 0.25)
              : inTransit > 0
                  ? _kPendingFg.withValues(alpha: 0.25)
                  : _kBorder,
        ),
        boxShadow: const [BoxShadow(color: Color(0x0F000000), blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Supplier name + status badge row
          Row(children: [
            Expanded(
              child: Text(name,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _kText),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            if (fullyArrived)
              _ArrivalBadge(label: 'All arrived', bg: _kReceivedBg, fg: _kReceivedFg)
            else if (inTransit > 0)
              _ArrivalBadge(label: 'In transit ($inTransit)', bg: _kPendingBg, fg: _kPendingFg),
          ]),
          const SizedBox(height: 8),
          // Count chips
          Wrap(spacing: 10, runSpacing: 6, children: [
            _CountChip('Collected $collected', _kSub, _kBg),
            _CountChip('Arrived $arrived', _kReceivedFg, _kReceivedBg),
            if (inTransit > 0)
              _CountChip('In transit $inTransit', _kPendingFg, _kPendingBg),
          ]),
          // Mark arrived button (only when there's something in transit)
          if (!fullyArrived && inTransit > 0) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity, height: 44,
              child: FilledButton.icon(
                onPressed: isMarking ? null : () => _markArrived(name, inTransit),
                icon: isMarking
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.warehouse_outlined, size: 18),
                label: Text(isMarking ? 'Marking…' : 'Mark arrived at warehouse',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                style: FilledButton.styleFrom(
                  backgroundColor: _kGreen,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

class _ArrivalBadge extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;
  const _ArrivalBadge({required this.label, required this.bg, required this.fg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg)),
    );
  }
}

class _CountChip extends StatelessWidget {
  final String label;
  final Color fg;
  final Color bg;
  const _CountChip(this.label, this.fg, this.bg);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
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

class _AdminFulfillmentScreenState extends State<AdminFulfillmentScreen> {
  int _tab = 0;
  final _collectKey  = GlobalKey<_PickToLightScreenState>();
  final _arrivalsKey = GlobalKey<_ArrivalsScreenState>();
  final _packKey     = GlobalKey<_PackScreenState>();

  @override
  void initState() {
    super.initState();
    RenderLog.write('fulfillment_area_mounted', 'true');
    RenderLog.write('fulfillment_three_areas_mounted', 'true');
  }

  void _onFocus() {}

  static const _kSubtitles = [
    'Count stock at the supplier',
    'Mark boxes arrived at warehouse',
    'Pack & ship customer bags',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Container(
        color: _kCard,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Fulfillment',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: _kText)),
          const SizedBox(height: 2),
          Text(_kSubtitles[_tab],
              style: const TextStyle(fontSize: 12, color: _kSub)),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              _TabBtn('Collect',   _tab == 0, () => setState(() => _tab = 0)),
              const SizedBox(width: 6),
              _TabBtn('Arrivals',  _tab == 1, () => setState(() => _tab = 1)),
              const SizedBox(width: 6),
              _TabBtn('Pack',      _tab == 2, () => setState(() => _tab = 2)),
            ]),
          ),
          const SizedBox(height: 1),
          const Divider(height: 1, color: _kBorder),
        ]),
      ),
      Expanded(
        child: IndexedStack(
          index: _tab,
          children: [
            _PickToLightScreen(key: _collectKey),
            _ArrivalsScreen(key: _arrivalsKey),
            _PackScreen(key: _packKey),
          ],
        ),
      ),
    ]);
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
