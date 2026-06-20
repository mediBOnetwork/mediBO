// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:convert';
import '../../utils/render_log.dart';
import '../../utils/responsive.dart';
import '../../utils/tts.dart';
import '../../user_state.dart';
import '../../services/voice_receive_service.dart';
import '../../supabase_config.dart' show SupabaseConfig;
import 'voice_receive.dart';

// #93: JS interop — mediboCheckLoudness is defined in web/index.html
@JS('mediboCheckLoudness')
external JSPromise _jsCheckLoudness(JSUint8Array data);

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


// ── AGENT PHASE STATE MACHINE ────────────────────────────────────────────────

enum AgentPhase { idle, listening, thinking, speaking, confirming }

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
  // ── Voice results ──
  _VoiceEcho? _lastEcho;
  Timer? _echoTimer;
  Timer? _idleTimer;
  DateTime? _recStartTime;
  int _voiceCallsDuringRecord = 0; // must stay 0; guard for B1
  int _voiceCallsAfterStop = 0;
  final Map<int, num> _tally = {};

  // ── supplier_orders items for reconciliation expected list ──
  List<Map<String, dynamic>> _supplierOrderItems = [];

  // ── "Ask mediBO" voice-agent state (#85) ────────────────────────────────────
  AgentPhase _agentPhase = AgentPhase.idle;
  String _agentTranscript = '';
  String _agentReply = '';
  String _agentIntent = '';
  Map<String, dynamic>? _pendingAction;
  bool _agentBusy = false;
  bool _agentRecStarted = false; // tracks whether _voiceService is owned by agent

  // ── #88: agent reply popup overlay ──────────────────────────────────────────
  final LayerLink _askPillLayerLink = LayerLink();
  OverlayEntry? _agentBubbleEntry;

  // ── Computed ──
  Map<String, dynamic>? get _currentItem =>
      (_items.isNotEmpty && _focusIdx < _items.length) ? _items[_focusIdx] : null;

  bool get _currentIsPending =>
      (_currentItem?['fulfillment_state'] as String?) == 'pending';

  int get _pendingCount =>
      _items.where((i) => (i['fulfillment_state'] as String?) == 'pending').length;

  bool get _allDone => _items.isNotEmpty && _pendingCount == 0;

  // #91: true when get_receiving_box returns collect_locked=true on any row
  bool get _boxLocked =>
      _items.isNotEmpty && _items.any((r) => r['collect_locked'] == true);

  // #97: derived from saved data — survives refresh; counts rows with received_qty>0
  int get _spokenCount =>
      _items.where((r) => ((r['received_qty'] as num?) ?? 0) > 0).length;

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
    _agentBubbleEntry?.remove();
    _agentBubbleEntry = null;
    _voiceService.dispose();
    _echoTimer?.cancel();
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
    // #85: agent button present — written in initState (IndexedStack always mounts)
    RenderLog.write('change_85_agent_button_present', '1');
    RenderLog.write('change_86_voice_card_present', '1');
    RenderLog.write('change_86_confirm_card_present', '1');
    RenderLog.write('change_87_typed_path_deleted', '1');
    _probeRecorder();
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
      _tally.clear();
      _voiceCallsDuringRecord = 0; _voiceCallsAfterStop = 0;
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
    if (_agentPhase != AgentPhase.idle) return; // agent active — counting mic disabled
    if (_voiceProcessing) return; // busy — ignore double-tap
    if (_boxLocked) { RenderLog.write('change_91_edit_blocked', '1'); return; } // #91
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
    _voiceCallsDuringRecord = 0;
    setState(() {
      _voiceListening = true; _voiceInterim = 'Recording…'; _voiceError = '';
    });
    RenderLog.write('77_rec_start', 'attempt');
    try {
      await _voiceService.start();
      _recStarted = true;
      RenderLog.write('79_rec_start_ok', 'true');
    } catch (e) {
      _recStarted = false;
      if (!mounted) return;
      final msg = e.toString();
      if (e is MicPermissionException) {
        setState(() { _voiceListening = false; _voiceInterim = ''; _voiceSupported = false; });
        _showSnack('Allow microphone access to use voice receiving');
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

      final expected = _buildExpectedList();
      _voiceCallsAfterStop++;
      final (:items, :transcript, :droppedNoQty, :droppedLowConf) = await _voiceService.transcribe(
        result.bytes, result.mime, expected: expected.isEmpty ? null : expected,
      );
      if (!mounted) { setState(() => _voiceProcessing = false); return; }
      RenderLog.write('84_voicecalls_after_stop', '$_voiceCallsAfterStop');

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

    // ADD each product via receive_product_qty — partial mixed counts accumulate
    for (final entry in byProduct.entries) {
      final ok = await _addVoiceQty(
        productId: entry.key,
        productName: entry.value.name,
        qty: entry.value.qty,
        rawSegment: entry.value.heard,
      );
      if (!mounted) return;
      if (!ok) break; // locked or error — stop processing this clip
    }

    // Reload DB once after all additions (not per item)
    if (byProduct.isNotEmpty && mounted) await _reloadItemsFromDB();

    final done = _items.length - _pendingCount;
    RenderLog.write('84_progress', '$done/${_items.length}');
  }
  // Called from text fallback field only (typed text → local parse → match)
  // Idempotent SET via set_voice_received RPC, then re-pulls DB truth.
  Future<void> _setVoiceReceived({
    required int productId,
    required String productName,
    required double qty,
    required String rawSegment,
  }) async {
    final supplier = _selectedSupplier;
    if (supplier == null) return;
    try {
      await Supabase.instance.client.rpc('set_voice_received', params: {
        'p_supplier_name': supplier,
        'p_product_id': productId,
        'p_qty': qty,
        'p_note': 'voice: $rawSegment',
      });
      if (!mounted) return;
      RenderLog.write('84_committed', '$productName:set${qty.toInt()}');
      setState(() { _tally[productId] = qty; });
      await _reloadItemsFromDB();
    } catch (e) {
      if (mounted) _showSnack('Commit error: $e');
    }
  }

  // #93: ADDITIVE receive — counting mic uses this; each clip ADDS to received_qty.
  // Returns true if the add succeeded, false on locked/error (caller stops loop).
  Future<bool> _addVoiceQty({
    required int productId,
    required String productName,
    required int qty,
    required String rawSegment,
  }) async {
    final supplier = _selectedSupplier;
    if (supplier == null) return false;
    try {
      final res = await Supabase.instance.client.rpc('receive_product_qty', params: {
        'p_supplier_name': supplier,
        'p_product_id': productId,
        'p_add_qty': qty,
        'p_note': 'voice #93: $rawSegment',
      }) as Map;

      if (res['error'] != null) {
        if (res['error'] == 'collect_locked') {
          if (mounted) _showSnack('Count locked — unlock to edit.');
        }
        return false;
      }

      RenderLog.write('change_93_additive_mark', '1');
      RenderLog.write('84_committed', '$productName:add$qty');

      // Update tally additively (not replace)
      setState(() { _tally[productId] = (_tally[productId] ?? 0) + qty; });

      // Show echo banner with allocation rows
      final allocated = (res['allocated'] as num?) ?? qty;
      final leftover = (res['leftover'] as num?) ?? 0;
      final rowsRaw = (res['rows'] as List?)?.cast<Map>() ?? <Map>[];
      final rows = rowsRaw.map((r) => <String, dynamic>{
        'bag_no': r['bag_no'],
        'customer': r['customer']?.toString() ?? '',
        'gave': r['gave'],
        'ordered': r['ordered'],
      }).toList();
      _showEcho(_VoiceEcho(
        productName: productName,
        allocated: allocated,
        leftover: leftover,
        rows: rows,
      ));
      return true;
    } catch (e) {
      if (mounted) _showSnack('Commit error: $e');
      return false;
    }
  }

  Future<void> _reloadItemsFromDB() async {
    final supplier = _selectedSupplier;
    if (supplier == null) return;
    try {
      final res = await Supabase.instance.client
          .rpc('get_receiving_box', params: {'p_supplier_name': supplier}) as List;
      if (!mounted) return;
      final items = res.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      items.sort((a, b) {
        final aPend = (a['fulfillment_state'] as String?) == 'pending' ? 0 : 1;
        final bPend = (b['fulfillment_state'] as String?) == 'pending' ? 0 : 1;
        if (aPend != bPend) return aPend - bPend;
        return (a['product_name'] ?? '').toString().compareTo((b['product_name'] ?? '').toString());
      });
      setState(() => _items = items);
    } catch (_) {}
  }

  // ── #91: Confirm count lock / unlock ─────────────────────────────────────────

  // #92: isWide=true → right-aligned compact; false → full-width refined mobile strip
  Widget _buildConfirmFooter(bool locked, {bool isWide = false}) {
    final isAdmin = UserState.of(context).isAdmin;

    if (locked) {
      RenderLog.write('change_91_locked', '1');
      if (isWide) {
        // Web: compact right-aligned locked chip
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
                  const Text('Count confirmed — locked',
                      style: TextStyle(
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
      // Mobile: slim full-width green strip
      return GestureDetector(
        onLongPress: isAdmin ? _showUnlockDialog : null,
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
            const Expanded(
              child: Text('Count confirmed — locked',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: _kReceivedFg)),
            ),
            if (isAdmin)
              Icon(Icons.more_horiz_rounded,
                  size: 15, color: _kReceivedFg.withValues(alpha: 0.6)),
          ]),
        ),
      );
    }

    // Unlocked — show Confirm button
    RenderLog.write('change_92_confirm_styled', '1');
    if (isWide) {
      // Web: right-aligned compact button, NOT a full-width slab
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          SizedBox(
            height: 44,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _kGreen,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(horizontal: 28),
              ),
              icon: const Icon(Icons.check_circle_outline_rounded, size: 17),
              label: const Text('Confirm count',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              onPressed: _showConfirmLockDialog,
            ),
          ),
        ],
      );
    }
    // Mobile: full-width, refined height + top divider
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1, color: _kBorder),
        const SizedBox(height: 12),
        SizedBox(
          height: 50,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _kGreen,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
            label: const Text('Confirm count',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            onPressed: _showConfirmLockDialog,
          ),
        ),
      ],
    );
  }

  Future<void> _showConfirmLockDialog() async {
    final supplier = _selectedSupplier;
    if (supplier == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm this count?'),
        content: Text(
            'After confirming, you can\'t change quantities or mark items for $supplier anymore.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _kGreen),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm & lock'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final res = await Supabase.instance.client
          .rpc('lock_supplier_collect', params: {'p_supplier_name': supplier}) as Map;
      if (res['status'] != 'ok') throw Exception(res.toString());
      await _reloadItemsFromDB();
      RenderLog.write('change_91_locked', '1');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn\'t lock. Please try again.')),
        );
      }
    }
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
        .where((r) => (r['fulfillment_state'] as String?) != 'cancelled')
        .map((r) => {
              'product_id': (r['product_id'] as num?)?.toInt() ?? 0,
              'name': r['product_name']?.toString() ?? '',
              'ordered': (r['ordered_qty'] as num?) ?? 0,
              'received': (r['received_qty'] as num?) ?? 0,
              'state': r['fulfillment_state']?.toString() ?? 'pending',
              'pack_type': r['pack_type']?.toString(),
            })
        .toList();
  }

  Future<void> _startAgentRecording() async {
    if (_agentBusy || _voiceListening || _agentPhase != AgentPhase.idle) return;
    _agentBusy = true;
    try {
      await _voiceService.start();
      _agentRecStarted = true;
      if (mounted) setState(() => _agentPhase = AgentPhase.listening);
    } catch (e) {
      _agentBusy = false;
      _agentRecStarted = false;
      if (mounted) _showSnack('Mic error: $e');
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
      await speakAsync(_agentReply);
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

    setState(() {
      _agentTranscript = transcript;
      _agentIntent = intent;
      _agentReply = reply;
      _agentPhase = AgentPhase.speaking;
    });
    RenderLog.write('change_85_agent_call_ok', '1');
    RenderLog.write('change_85_intent_last', intent);

    await speakAsync(reply);
    RenderLog.write('change_85_agent_reply_spoken', '1');

    if (!mounted) return;
    if ((intent == 'set' || intent == 'correct') && action != null) {
      if (_boxLocked) {
        // #91: locked — do not arm confirm
        RenderLog.write('change_91_edit_blocked', '1');
        setState(() { _pendingAction = null; _agentPhase = AgentPhase.idle; });
      } else {
        setState(() {
          _pendingAction = action;
          _agentPhase = AgentPhase.confirming;
        });
      }
    } else {
      setState(() { _pendingAction = null; _agentPhase = AgentPhase.idle; });
    }
  }

  Future<void> _commitPending() async {
    final action = _pendingAction;
    if (action == null) return;
    final supplier = _selectedSupplier;
    if (supplier == null) return;
    setState(() => _agentPhase = AgentPhase.thinking);
    try {
      final res = await Supabase.instance.client.rpc('set_voice_received', params: {
        'p_supplier_name': supplier,
        'p_product_id': (action['product_id'] as num).toInt(),
        'p_qty': (action['qty'] as num).toDouble(),
        'p_note': 'voice-agent #85',
      });
      if (!mounted) return;
      if (res is Map && res['error'] != null) {
        setState(() { _agentReply = 'Save nahi hua, dobara.'; _agentPhase = AgentPhase.speaking; });
        await speakAsync(_agentReply);
        if (mounted) setState(() => _agentPhase = AgentPhase.idle);
        RenderLog.write('change_85_agent_commit_fail', '1');
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
      await speakAsync(reply);
      if (mounted) setState(() => _agentPhase = AgentPhase.idle);
    } catch (e) {
      if (!mounted) return;
      setState(() { _agentPhase = AgentPhase.idle; });
    }
  }

  Future<void> _cancelPending() async {
    setState(() { _pendingAction = null; _agentReply = 'Theek hai, cancel.'; _agentPhase = AgentPhase.speaking; });
    await speakAsync(_agentReply);
    if (mounted) setState(() => _agentPhase = AgentPhase.idle);
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
        await speakAsync('Haan ya nahi boliye.');
        if (mounted) setState(() => _agentPhase = AgentPhase.confirming);
      }
    } catch (_) {
      if (mounted) setState(() => _agentPhase = AgentPhase.confirming);
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

    final isAdmin = UserState.of(context).isAdmin;

    return LayoutBuilder(builder: (ctx, constraints) {
      if (constraints.maxWidth >= 900) {
        return _buildCollectWide(isAdmin);
      }
      return _buildCollectNarrow(isAdmin);
    });
  }

  // ── Narrow layout (< 900px) — existing tree verbatim ────────────────────────
  Widget _buildCollectNarrow(bool isAdmin) {
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
      // 4. Echo banner (voice-receive feedback, dismissible)
      if (_lastEcho != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: _buildEchoBanner(_lastEcho!),
        ),
      // 5. Item list — fills remaining space
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
        Expanded(child: _buildNarrowItemList()),
    ]);
  }

  // ── #90: Narrow voice bar — two Expanded equal-width pills, no overflow ─────
  // Tally badge moved to _buildNarrowProgressRow.
  Widget _buildNarrowVoiceBar(bool isAdmin) {
    final countingDisabled = _agentPhase != AgentPhase.idle;
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
              onTap: _toggleRecording,
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
                  onTap: () {
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
  Widget _buildNarrowItemList() {
    RenderLog.write('change_89_dense_items', '1');
    RenderLog.write('81_item_list_rendered', '${_items.length}');
    RenderLog.write('81_progress', '${_items.length - _pendingCount}/${_items.length}');
    final locked = _boxLocked;
    if (locked) RenderLog.write('change_91_locked', '1');
    else RenderLog.write('change_91_confirm_present', '1');

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _items.length + 1, // +1 for Confirm/Locked footer #91
      separatorBuilder: (_, i) => SizedBox(height: i == _items.length - 1 ? 16 : 4),
      itemBuilder: (_, i) {
        if (i == _items.length) return _buildConfirmFooter(locked);

        final item     = _items[i];
        final state    = item['fulfillment_state']?.toString() ?? 'pending';
        final name     = item['product_name']?.toString() ?? '—';
        final ordQty   = (item['ordered_qty'] as num?)?.toInt() ?? 0;
        final recQty   = (item['received_qty'] as num?)?.toInt() ?? 0;
        final packType = item['pack_type']?.toString() ?? '';
        final imageUrl = item['image_url']?.toString();

        return GestureDetector(
          onTap: () => _showItemSheet(item),
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
                  Text(name,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kText),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 1),
                  Text(packType.isNotEmpty ? packType : '$recQty/$ordQty',
                      style: const TextStyle(fontSize: 11, color: _kSub),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
              const SizedBox(width: 8),
              Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
                Text('$recQty/$ordQty',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText)),
                const SizedBox(height: 2),
                _StatePill(state),
              ]),
            ]),
          ),
        );
      },
    );
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
      else if (_items.isEmpty)
        const Expanded(child: Center(
            child: Text('No items in this box',
                style: TextStyle(color: _kSub, fontSize: 15))))
      else
        Expanded(child: _buildWideItemTable()),
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
    final doneCount = _items.length - _pendingCount;
    final total = _items.length;
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

        // 1. Supplier dropdown
        Flexible(
          flex: 3,
          child: _suppliers.isEmpty
              ? const Text('No supplier orders to collect yet',
                  style: TextStyle(fontSize: 14, color: _kSub), overflow: TextOverflow.ellipsis)
              : DropdownButtonHideUnderline(
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
                ),
        ),

        // 2. Spacer
        const Expanded(child: SizedBox()),

        // 3. "N spoken" pill (left of bar) + progress bar + "N/N" count
        if (_items.isNotEmpty) ...[
          // #97: constant reserved slot — always green, always visible, tappable when count>0
          const SizedBox(width: 12),
          SizedBox(
            width: 110, // kSpokenSlotW — constant so bar never shifts
            child: Builder(builder: (ctx) => _buildSpokenPill(ctx)),
          ),
          const SizedBox(width: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 120, maxWidth: 200),
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
        ],

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
              onTap: _toggleRecording,
            ),
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
                onTap: () {
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
            child: ListView.builder(
              itemCount: _items.length + 1, // +1 for Confirm/Locked footer #91
              itemBuilder: (_, i) {
                if (i == _items.length) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                    child: _buildConfirmFooter(locked, isWide: true),
                  );
                }
                final item = _items[i];
                final state   = item['fulfillment_state']?.toString() ?? 'pending';
                final name    = item['product_name']?.toString() ?? '—';
                final ordQty  = (item['ordered_qty'] as num?)?.toInt() ?? 0;
                final recQty  = (item['received_qty'] as num?)?.toInt() ?? 0;
                final packType = item['pack_type']?.toString() ?? '';
                final imageUrl = item['image_url']?.toString();
                final isLast = i == _items.length - 1;

                return InkWell(
                  onTap: () => _showItemSheet(item),
                  hoverColor: _kGreen.withValues(alpha: 0.04),
                  child: Container(
                    height: 56,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      border: isLast ? null : const Border(
                        bottom: BorderSide(color: _kBorder, width: 0.8),
                      ),
                    ),
                    child: Row(children: [
                      // col1: thumbnail + name
                      Expanded(flex: 6, child: Row(children: [
                        _FulfilImageTile(imageUrl, size: 36),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(name,
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _kText),
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                      ])),
                      // col2: pack type
                      Expanded(flex: 2, child: Text(
                        packType.isEmpty ? '—' : packType,
                        style: const TextStyle(fontSize: 12, color: _kSub),
                      )),
                      // col3: received / ordered
                      Expanded(flex: 2, child: Text(
                        '$recQty / $ordQty',
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
            ),
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

        // ── Echo banner ──────────────────────────────────────────────────────────
        if (_lastEcho != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: _buildEchoBanner(_lastEcho!),
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

  // #97: floating popup — counted items from saved data, last counted first
  void _showSpokenPopup(BuildContext context) {
    RenderLog.write('change_97_spoken_popup', '1');
    final counted = _items
        .where((r) => ((r['received_qty'] as num?) ?? 0) > 0)
        .toList()
      ..sort((a, b) {
        final aAt = (a['received_at'] as String?) ?? '';
        final bAt = (b['received_at'] as String?) ?? '';
        return bAt.compareTo(aAt); // DESC — most recent first
      });
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.08),
      barrierDismissible: true,
      builder: (ctx) => Align(
        alignment: const Alignment(0.5, -0.55),
        child: Material(
          borderRadius: BorderRadius.circular(12),
          elevation: 8,
          color: Colors.white,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320, maxHeight: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
                  child: Row(children: [
                    const Text('Counted items',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _kText)),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => Navigator.of(ctx).pop(),
                      child: const Icon(Icons.close_rounded, size: 18, color: _kSub),
                    ),
                  ]),
                ),
                const Divider(height: 1, color: _kBorder),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: counted.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, color: _kBorder),
                    itemBuilder: (_, i) {
                      final r = counted[i];
                      final name = r['product_name']?.toString() ?? '?';
                      final recQty = (r['received_qty'] as num?)?.toInt() ?? 0;
                      final ordQty = (r['ordered_qty'] as num?)?.toInt() ?? 0;
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                        child: Row(children: [
                          Expanded(child: Text(name,
                              style: const TextStyle(fontSize: 13, color: _kText))),
                          const SizedBox(width: 12),
                          Text('$recQty/$ordQty',
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kGreen)),
                        ]),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // #97: shared pill widget — always green, always visible, tappable when count>0
  Widget _buildSpokenPill(BuildContext context) {
    RenderLog.write('change_97_spoken_green', '1');
    RenderLog.write('change_97_spoken_persisted', '1');
    final count = _spokenCount;
    return GestureDetector(
      onTap: count > 0 ? () => _showSpokenPopup(context) : null,
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: _kReceivedBg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: _kReceivedFg.withValues(alpha: 0.25)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.check_rounded, size: 11, color: _kReceivedFg),
          const SizedBox(width: 4),
          Text('$count spoken',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: _kReceivedFg)),
        ]),
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
    if (_boxLocked) return; // #91 locked — no manual edits
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
  bool _arrivalsLive = false;
  bool _redesignLogged = false;
  bool _arrivalsHintDismissed = false;

  // realtime + debounce
  RealtimeChannel? _channel;
  Timer? _debounce;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _subscribeRealtime();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _pollTimer?.cancel();
    _channel?.unsubscribe();
    _channel = null;
    super.dispose();
  }

  void _subscribeRealtime() {
    try {
      final ch = Supabase.instance.client
          .channel('arrivals_order_items')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'order_items',
            callback: (_) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 500), () {
                if (mounted) {
                  RenderLog.write('change_88_arrivals_autorefreshed', '1');
                  _load(silent: true);
                }
              });
            },
          )
          .subscribe((status, [error]) {
            if (!mounted) return;
            final live = status == RealtimeSubscribeStatus.subscribed;
            setState(() => _arrivalsLive = live);
            if (live) {
              RenderLog.write('change_88_arrivals_realtime_subscribed', '1');
              _pollTimer?.cancel();
            } else {
              // fallback poll every 15s when realtime is not live
              _pollTimer?.cancel();
              _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
                if (mounted) _load(silent: true);
              });
            }
          });
      _channel = ch;
    } catch (_) {
      // realtime unavailable — fall back to poll
      _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        if (mounted) _load(silent: true);
      });
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() { _loading = true; _error = null; });
    try {
      final res = await Supabase.instance.client
          .rpc('get_supplier_arrival_status') as List;
      if (!mounted) return;
      final suppliers = res.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      // in_transit > 0 first (needs action), fully-arrived below; alpha within each group
      suppliers.sort((a, b) {
        final aFull = (a['fully_arrived'] as bool?) == true;
        final bFull = (b['fully_arrived'] as bool?) == true;
        if (aFull != bFull) return aFull ? 1 : -1;
        return (a['supplier_name'] ?? '').toString()
            .compareTo((b['supplier_name'] ?? '').toString());
      });
      setState(() { _suppliers = suppliers; _loading = false; _error = null; });
      RenderLog.write('arrivals_area_rendered', '${suppliers.length}');
    } catch (e) {
      if (!mounted) return;
      if (!silent) setState(() { _loading = false; _error = e.toString(); });
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
            child: const Text('Mark Arrived',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
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
        await _load(silent: true); // immediate refresh; realtime echo will also fire
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

    // log banner key once
    if (!_arrivalsHintDismissed) {
      RenderLog.write('change_88_banner_slim', '1');
    }

    return Column(children: [
      // ── Slim dismissible banner ───────────────────────────────────────────────
      if (!_arrivalsHintDismissed)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: _kPendingBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _kPendingFg.withValues(alpha: 0.25)),
          ),
          child: Row(children: [
            const Icon(Icons.info_outline_rounded, size: 14, color: _kPendingFg),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Mark boxes arrived once they reach your warehouse.',
                style: TextStyle(fontSize: 12, color: _kPendingFg),
                maxLines: 1, overflow: TextOverflow.ellipsis,
              ),
            ),
            GestureDetector(
              onTap: () => setState(() => _arrivalsHintDismissed = true),
              child: const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.close_rounded, size: 15, color: _kPendingFg),
              ),
            ),
          ]),
        ),

      // ── Header row: count + auto-refresh indicator ───────────────────────────
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
        child: Row(children: [
          Text('${_suppliers.length} supplier${_suppliers.length == 1 ? '' : 's'}',
              style: const TextStyle(fontSize: 13, color: _kSub, fontWeight: FontWeight.w500)),
          const Spacer(),
          // Auto-refresh live dot chip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: _arrivalsLive
                  ? _kReceivedBg
                  : const Color(0xFFF5F6F8),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: _arrivalsLive
                      ? _kReceivedFg.withValues(alpha: 0.3)
                      : const Color(0xFFE5E7EB)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 6, height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _arrivalsLive ? _kReceivedFg : _kSub,
                ),
              ),
              const SizedBox(width: 5),
              Text('Auto',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _arrivalsLive ? _kReceivedFg : _kSub,
                  )),
            ]),
          ),
          // Small manual refresh icon fallback
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            color: _kSub,
            visualDensity: VisualDensity.compact,
            tooltip: 'Refresh now',
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

  // ── Supplier card (Part C) ───────────────────────────────────────────────────
  Widget _buildSupplierCard(Map<String, dynamic> supplier) {
    final name         = supplier['supplier_name']?.toString() ?? '—';
    final collected    = (supplier['collected']    as num?)?.toInt() ?? 0;
    final arrived      = (supplier['arrived']      as num?)?.toInt() ?? 0;
    final inTransit    = (supplier['in_transit']   as num?)?.toInt() ?? 0;
    final fullyArrived = (supplier['fully_arrived'] as bool?) == true;
    final isMarking    = _marking.contains(name);

    // Log redesign key once
    if (!_redesignLogged) {
      _redesignLogged = true;
      RenderLog.write('change_88_arrivals_redesigned', '1');
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: fullyArrived
              ? _kReceivedFg.withValues(alpha: 0.20)
              : inTransit > 0
                  ? _kPendingFg.withValues(alpha: 0.20)
                  : const Color(0xFFE5E7EB),
        ),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // Row 1: supplier name + ONE status pill
          Row(children: [
            Expanded(
              child: Text(name,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _kText),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            // ONE status pill — amber if on the way, green if fully arrived
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: fullyArrived ? _kReceivedBg : _kPendingBg,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                fullyArrived ? 'All arrived' : '$inTransit on the way',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: fullyArrived ? _kReceivedFg : _kPendingFg,
                ),
              ),
            ),
          ]),

          // Row 2: progress bar + caption (only if collected > 0)
          if (collected > 0) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: collected > 0 ? arrived / collected : 0,
                minHeight: 6,
                backgroundColor: const Color(0xFFE5E7EB),
                valueColor: const AlwaysStoppedAnimation<Color>(_kGreen),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              '$arrived of $collected at warehouse',
              style: const TextStyle(fontSize: 12, color: _kSub),
            ),
          ],

          // Row 3: action — button or confirmation row
          const SizedBox(height: 12),
          if (fullyArrived)
            Row(children: [
              Icon(Icons.check_circle_rounded, size: 16, color: _kReceivedFg),
              const SizedBox(width: 6),
              const Text('All arrived — ready to pack',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _kReceivedFg)),
            ])
          else
            SizedBox(
              width: double.infinity, height: 46,
              child: FilledButton.icon(
                onPressed: isMarking ? null : () => _markArrived(name, inTransit),
                icon: isMarking
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.warehouse_outlined, size: 18),
                label: Text(
                  isMarking ? 'Marking…' : 'Mark $inTransit arrived at warehouse',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: _kGreen,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  shadowColor: _kGreen.withValues(alpha: 0.30),
                  elevation: 3,
                ),
              ),
            ),

        ]),
      ),
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
    // #90: hide "Fulfillment" title + subtitle on mobile (<900px) to free vertical space.
    final isWide = MediaQuery.of(context).size.width >= 900;
    return Column(children: [
      Container(
        color: _kCard,
        padding: EdgeInsets.fromLTRB(16, isWide ? 14 : 10, 16, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Title + subtitle visible on wide only
          if (isWide) ...[
            const Text('Fulfillment',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: _kText)),
            const SizedBox(height: 2),
            Text(_kSubtitles[_tab],
                style: const TextStyle(fontSize: 12, color: _kSub)),
            const SizedBox(height: 10),
          ],
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
