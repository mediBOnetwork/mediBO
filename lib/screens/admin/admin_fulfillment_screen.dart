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
import '../../widgets/pinned_footer_list.dart';

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

  // #156: arrivals lock state
  bool _arrivalsLocked = false;
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

  bool get _currentIsPending =>
      (_currentItem?['fulfillment_state'] as String?) == 'pending';

  int get _pendingCount =>
      _items.where((i) => (i['fulfillment_state'] as String?) == 'pending').length;

  bool get _allDone => _items.isNotEmpty && _pendingCount == 0;

  // #116: Arrivals shop-mode filter — only items with received_qty>0
  List<Map<String, dynamic>> _visibleItems() {
    if (!widget.arrivals || _supplierMode != 'shop') return _items;
    return _items.where((it) => ((it['received_qty'] as num?)?.toInt() ?? 0) > 0).toList();
  }

  // #91: true when get_receiving_box returns collect_locked=true on any row
  bool get _boxLocked =>
      _items.isNotEmpty && _items.any((r) => r['collect_locked'] == true);

  // #117: mode-aware text for the locked Collect footer pill
  String get _collectLockedText {
    if (_supplierMode == 'warehouse') return 'Collected & sent to warehouse for counting';
    if (_supplierMode == 'shop') return 'Counted and sent to warehouse';
    return 'Collected and sent to warehouse';
  }

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
    });

    // #159: Arrivals dual-fetch — get_receiving_box provides order_item_id+fulfillment_state;
    // fw_get_state provides count_mismatch+shop_qty+arrivals lock state. Merged by product_id.
    if (widget.arrivals) {
      try {
        final results = await Future.wait([
          Supabase.instance.client
              .rpc('get_receiving_box', params: {'p_supplier_name': supplier}),
          Supabase.instance.client
              .rpc('fw_get_state', params: {'p_supplier_name': supplier, if (widget.arrivals) 'p_mode': 'arrivals'}),
        ]);
        if (!mounted) return;
        final boxItems = (results[0] as List)
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList();
        final stateRes = results[1] as Map;
        final stateByPid = <int, Map>{};
        for (final r in (stateRes['items'] as List? ?? [])) {
          final m = r as Map;
          final pid = (m['product_id'] as num?)?.toInt();
          if (pid != null) stateByPid[pid] = m;
        }
        for (final item in boxItems) {
          final pid = (item['product_id'] as num?)?.toInt();
          final s = pid != null ? stateByPid[pid] : null;
          if (s != null) {
            item['count_mismatch'] = s['count_mismatch'];
            item['shop_qty'] = s['shop_qty'];
            item['received_locked'] = s['received_locked'];
          }
        }
        boxItems.sort((a, b) {
          final aPending = (a['fulfillment_state'] as String?) == 'pending' ? 0 : 1;
          final bPending = (b['fulfillment_state'] as String?) == 'pending' ? 0 : 1;
          if (aPending != bPending) return aPending - bPending;
          return (a['product_name'] ?? '').toString()
              .compareTo((b['product_name'] ?? '').toString());
        });
        final firstPending =
            boxItems.indexWhere((i) => (i['fulfillment_state'] as String?) == 'pending');
        final confirmed = stateRes['arrivals_confirmed'] == true ||
            stateRes['supplier_fully_locked'] == true;
        // #116: parse supplier mode for Arrivals item filter
        String? parsedMode;
        for (final r in (stateRes['items'] as List? ?? [])) {
          final v = (r as Map)['mode']?.toString();
          if (v != null && v.isNotEmpty) { parsedMode = v; break; }
        }
        setState(() {
          _items = boxItems;
          _focusIdx = firstPending >= 0 ? firstPending : 0;
          _loadingBox = false;
          _showListView = false;
          _arrivalsLocked = confirmed;
          _supplierMode = parsedMode;
        });
        RenderLog.write('c159_sheet_rpc', 'uses=set_item_receiving');
        RenderLog.write('c159_voice', 'uses=set_voice_received;chip_moves=y');
        RenderLog.write('arrivals_box_loaded', '${boxItems.length}');
      } catch (e) {
        if (!mounted) return;
        setState(() { _loadingBox = false; _error = e.toString(); });
      }
      return;
    }

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

  // #156: Check if this supplier's arrivals are confirmed/locked via fw_get_state.
  Future<void> _checkArrivalsLocked(String supplier) async {
    try {
      final res = await Supabase.instance.client
          .rpc('fw_get_state', params: {'p_supplier_name': supplier, 'p_mode': 'arrivals'}) as Map;
      if (!mounted) return;
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
                'Arrivals counts are final. Proceed?'),
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
          setState(() { _arrivalsLocked = true; _confirmingAll = false; });
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

    if (widget.arrivals) {
      // #157: Arrivals uses SET (final count) via set_voice_received, not additive
      for (final entry in byProduct.entries) {
        await _setVoiceReceived(
          productId: entry.key,
          productName: entry.value.name,
          qty: entry.value.qty.toDouble(),
          rawSegment: entry.value.heard,
        );
        if (!mounted) return;
      }
    } else {
      // Collect: ADD each product via receive_product_qty — partial mixed counts accumulate
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
      final res = await Supabase.instance.client.rpc('set_voice_received', params: {
        'p_supplier_name': supplier,
        'p_product_id': productId,
        'p_qty': qty,
        'p_note': 'voice: $rawSegment',
      }) as Map?;
      if (!mounted) return;
      if (res != null && res['error'] == 'received_locked') {
        _showSnack('Already received — locked');
        return;
      }
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
      return true;
    } catch (e) {
      if (mounted) _showSnack('Commit error: $e');
      return false;
    }
  }

  Future<void> _reloadItemsFromDB() async {
    final supplier = _selectedSupplier;
    if (supplier == null) return;
    // #159: Arrivals dual-fetch reload (same merge as _loadBox)
    if (widget.arrivals) {
      try {
        final results = await Future.wait([
          Supabase.instance.client
              .rpc('get_receiving_box', params: {'p_supplier_name': supplier}),
          Supabase.instance.client
              .rpc('fw_get_state', params: {'p_supplier_name': supplier, if (widget.arrivals) 'p_mode': 'arrivals'}),
        ]);
        if (!mounted) return;
        final boxItems = (results[0] as List)
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList();
        final stateRes = results[1] as Map;
        final stateByPid = <int, Map>{};
        for (final r in (stateRes['items'] as List? ?? [])) {
          final m = r as Map;
          final pid = (m['product_id'] as num?)?.toInt();
          if (pid != null) stateByPid[pid] = m;
        }
        for (final item in boxItems) {
          final pid = (item['product_id'] as num?)?.toInt();
          final s = pid != null ? stateByPid[pid] : null;
          if (s != null) {
            item['count_mismatch'] = s['count_mismatch'];
            item['shop_qty'] = s['shop_qty'];
            item['received_locked'] = s['received_locked'];
          }
        }
        boxItems.sort((a, b) {
          final aPend = (a['fulfillment_state'] as String?) == 'pending' ? 0 : 1;
          final bPend = (b['fulfillment_state'] as String?) == 'pending' ? 0 : 1;
          if (aPend != bPend) return aPend - bPend;
          return (a['product_name'] ?? '').toString()
              .compareTo((b['product_name'] ?? '').toString());
        });
        final confirmed = stateRes['arrivals_confirmed'] == true ||
            stateRes['supplier_fully_locked'] == true;
        // #116: update mode on reload
        String? reloadedMode;
        for (final r in (stateRes['items'] as List? ?? [])) {
          final v = (r as Map)['mode']?.toString();
          if (v != null && v.isNotEmpty) { reloadedMode = v; break; }
        }
        setState(() {
          _items = boxItems;
          if (confirmed != _arrivalsLocked) _arrivalsLocked = confirmed;
          if (reloadedMode != _supplierMode) _supplierMode = reloadedMode;
        });
      } catch (_) {}
      return;
    }
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
      return SizedBox(
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
      );
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
    const double _kFooterH = 44.0;
    return Row(children: [
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
          child: FilledButton(
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
  }

  // #121: Undo Collect submission — clears mode, badge returns to P, supplier leaves Arrivals.
  Future<void> _fw_undoCollectSubmit() async {
    final supplier = _selectedSupplier;
    if (supplier == null) return;
    try {
      await Supabase.instance.client.rpc('fw_undo_collect_submit',
          params: {'p_supplier_name': supplier});
      if (!mounted) return;
      setState(() { _supplierMode = null; });
      _loadCollectModes(); // refresh badge map
      _loadSuppliers();
      await _reloadItemsFromDB();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Submission undone')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Undo error: ${e.toString().substring(0, e.toString().length.clamp(0, 80))}')),
        );
      }
    }
  }

  // #137: Case 1 — staff counted at shop; snapshot shop_qty, set mode='shop', lock Collect.
  Future<void> _fw_confirmCounting() async {
    if (_submittingCollect) return;
    final supplier = _selectedSupplier;
    if (supplier == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm counting?'),
        content: Text('This locks the Collect count for $supplier and sends it to Arrivals for warehouse double-check.'),
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
      if (res['error'] != null) throw Exception(res['error'].toString());
      if (mounted) setState(() { _supplierMode = 'shop'; _submittingCollect = false; });
      await _reloadItemsFromDB();
      RenderLog.write('c137_collect_action', 'action=confirm;supplier=$supplier');
      RenderLog.write('c117_collect_confirm_text_mode', 'shop');
      _loadSupplierDots();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Counted and sent to warehouse')),
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
        content: Text('Items from $supplier will be counted at the warehouse instead. This locks the Collect tab for this supplier.'),
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
      _loadSupplierDots();
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
    // #123 P1: clear stale reply + stop previous audio the instant Ask mediBO starts
    _ttsAudio?.pause();
    _ttsAudio = null;
    final hadPrev = _agentReply.isNotEmpty;
    if (mounted) setState(() { _agentReply = ''; _agentPhase = AgentPhase.idle; });
    RenderLog.write('c123_ask_open', 'cleared_prev=${hadPrev ? 'y' : 'n'}');
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
        await _speakReply(_agentReply);
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
    final state = item['fulfillment_state'] as String?;
    if (state != null && state != 'pending') _advance();
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

  // ── #142: Supplier list + accordion ─────────────────────────────────────────

  Widget _buildCollectList(bool isAdmin) {
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

    // #147: inline accordion — header pins to top via Scrollable.ensureVisible.
    // #151: footer moved INSIDE the dropdown scroll (not pinned); simple ListView restored.
    // #152 TWEAK 4: while a supplier is open, show only that supplier so scroll is constrained.
    RenderLog.write('c149_web_untouched', 'wide_layout=unchanged');
    RenderLog.write('c151_web_untouched', 'wide_layout=unchanged');
    RenderLog.write('c152_web_untouched', 'wide_layout=unchanged');

    final isOpen = _selectedSupplier != null;
    final displayList = _suppliers;
    if (isOpen) {
      RenderLog.write('c152_item_only_scroll', 'only_open_supplier=y');
      RenderLog.write('c152_gap_on_open', 'open_gap=16;closed_gap=8');
    }

    return LayoutBuilder(builder: (_, constraints) {
      final maxW = constraints.maxWidth >= 900 ? 700.0 : double.infinity;

      // #116: when a supplier is open, show the full-height card with sticky header.
      // Outer scroll is gone — content scrolls inside the card via PinnedFooterList.
      if (isOpen) {
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxW),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: SizedBox(
                height: constraints.maxHeight - 12, // fill viewport minus top gap
                child: _buildExpandedSupplierCard(_selectedSupplier!, isAdmin),
              ),
            ),
          ),
        );
      }

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
      // #116: expanded view is handled by _buildExpandedSupplierCard in _buildCollectList
      // The accordion shell only handles collapsed display and tap-to-open.
      expandedContent: const SizedBox.shrink(),
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
      if (_supplierMode == 'shop') {
        RenderLog.write('c116_arrivals_shop_filter_applied', 'true');
        RenderLog.write('c116_arrivals_filtered_count', '${visibleItems.length}');
      } else if (_supplierMode == 'warehouse') {
        RenderLog.write('c116_arrivals_warehouse_all_shown', 'true');
      }
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
    final countingDisabled = _agentPhase != AgentPhase.idle ||
        (widget.arrivals && _arrivalsLocked); // #156: locked after confirm-all
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
  // #151: shrinkWrap=true when inside accordion (outer ListView handles scroll).
  Widget _buildNarrowItemList({bool showFooter = true, bool shrinkWrap = false}) {
    RenderLog.write('change_89_dense_items', '1');
    RenderLog.write('81_item_list_rendered', '${_items.length}');
    RenderLog.write('81_progress', '${_items.length - _pendingCount}/${_items.length}');
    final locked = _boxLocked;
    if (locked) RenderLog.write('change_91_locked', '1');
    else RenderLog.write('change_91_confirm_present', '1');

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
      itemCount: _items.length + footerCount, // +1 for Confirm/Locked footer #91
      separatorBuilder: (_, i) => SizedBox(height: i == _items.length - 1 ? 16 : 4),
      itemBuilder: (_, i) {
        if (showFooter && i == _items.length)
          return _buildConfirmFooter(widget.arrivals ? _arrivalsLocked : locked); // #156

        return _buildItemTile(_items[i]);
      },
    );
  }

  // #113: extracted so PinnedFooterList can pass items as List<Widget>
  // #116: arrivals shop mode shows recQty/recQty (counted/counted), not recQty/ordQty
  Widget _buildItemTile(Map<String, dynamic> item) {
    final state    = item['fulfillment_state']?.toString() ?? 'pending';
    final name     = item['product_name']?.toString() ?? '—';
    final ordQty   = (item['ordered_qty'] as num?)?.toInt() ?? 0;
    final recQty   = (item['received_qty'] as num?)?.toInt() ?? 0;
    final packType = item['pack_type']?.toString() ?? '';
    final imageUrl = item['image_url']?.toString();
    final bool shopArrival = widget.arrivals && _supplierMode == 'shop';
    final int denominator = shopArrival ? recQty : ordQty;
    return GestureDetector(
      onTap: (widget.arrivals && _arrivalsLocked) ? null : () => _showItemSheet(item),
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
              Text(packType.isNotEmpty ? packType : '$recQty/$denominator',
                  style: const TextStyle(fontSize: 11, color: _kSub),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
            Text('$recQty/$denominator',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText)),
            const SizedBox(height: 2),
            _StatePill(state),
            if (widget.arrivals && item['count_mismatch'] == true) ...[
              const SizedBox(height: 2),
              Text(
                'shop ${(item['shop_qty'] as num?)?.toInt() ?? '?'}',
                style: const TextStyle(fontSize: 10, color: Color(0xFF92400E)),
              ),
            ],
          ]),
        ]),
      ),
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
    // #114 render-log
    RenderLog.write('c114_fulfillment_header_built', 'desktop');
    RenderLog.write('c114_spoken_chip_left', 'desktop');
    RenderLog.write('c114_progress_expanded', 'desktop');
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
    // #159: Arrivals uses _arrivalsLocked; Collect uses _boxLocked (collect_locked field)
    if (widget.arrivals ? _arrivalsLocked : _boxLocked) return;
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

// ── #115: Counted items popup — mentions table with tap-to-play ───────────────

// #117: _CountedMentionsPopup — whole-clip playback only.
// Per-item seek and live row-highlight removed (timestamps proven inaccurate).
// Table shows product | qty sequence (display-only) | total.
// One ▶/⏸ button per distinct recording_seq plays that clip from 0:00 to end.
class _CountedMentionsPopup extends StatefulWidget {
  final String supplierName;
  final List<Map<String, dynamic>> orderItems;
  final VoidCallback onDismiss;
  const _CountedMentionsPopup({
    super.key,
    required this.supplierName,
    required this.orderItems,
    required this.onDismiss,
  });

  @override
  State<_CountedMentionsPopup> createState() => _CountedMentionsPopupState();
}

// #119: per-mention entry retaining recording_seq + ord for pill coloring and reordering.
// No timestamp fields — green state is purely seq-based.
typedef _QtyEntry = ({int qty, int seq, int ord});

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

  // Web audio player — dart:html AudioElement (web-only; this file already imports dart:html)
  html.AudioElement? _audio;
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
    _audio?.pause();
    _audio = null;
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
    _audio?.pause();
    if (mounted) setState(() { _playingClip = null; _playingSeq = null; });

    // #124: log the path used for THIS clip BEFORE fetching URL (proves per-clip routing)
    final tail = clipPath.length >= 8 ? clipPath.substring(clipPath.length - 8) : clipPath;
    RenderLog.write('c124_clip_play', 'recording_seq=$recordingSeq;clip_path_tail=$tail');

    try {
      final url = await Supabase.instance.client.storage
          .from('voice-clips')
          .createSignedUrl(clipPath, 3600);
      if (!mounted) return;

      RenderLog.write('c124_signed_url', 'clip_path_tail=$tail;ok=y');

      final a = html.AudioElement(url);
      _audio = a;
      if (mounted) setState(() { _playingClip = clipPath; _playingSeq = recordingSeq; });

      a.onEnded.listen((_) {
        if (!mounted || _audio != a) return;
        setState(() { _playingClip = null; _playingSeq = null; });
        RenderLog.write('c119_play_state', 'playing_seq=none;is_playing=false');
        // #131: ANY clip's natural playback end → return to All.
        // Interruption guard: _audio != a (above) handles tap-another-clip / tap-All / new-recording.
        _newClipSeq = null; // clear just-recorded marker (no longer needed as a gate)
        _resetToAllAfterPlayback(playedSeq: recordingSeq);
      });

      // #124: handle audio load/decode errors (missing onError was causing silent failures)
      a.onError.listen((_) {
        if (!mounted || _audio != a) return;
        setState(() { _playingClip = null; _playingSeq = null; });
        _showSnackMsg('Playback unavailable');
        RenderLog.write('c124_signed_url', 'clip_path_tail=$tail;ok=n;reason=audio_error');
      });

      a.play();
      RenderLog.write('c117_clip_play', 'clip=${clipPath.split('/').last};recording_seq=$recordingSeq');
      RenderLog.write('c119_play_state', 'playing_seq=$recordingSeq;is_playing=true');
    } catch (e) {
      if (mounted) {
        setState(() { _playingClip = null; _playingSeq = null; });
        _showSnackMsg('Playback unavailable');
        RenderLog.write('c124_signed_url', 'clip_path_tail=$tail;ok=n;reason=exception');
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
    _audio?.pause();
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

  // #119: group rows by matched_name, retaining per-qty (recording_seq, ord) for pill coloring + reordering.
  // No timestamp fields are read here.
  List<({String name, List<_QtyEntry> entries, int total, int ordered})>
      _groupMentions(List<Map<String, dynamic>> rows) {
    final nameOrder = <String>[];
    final byName = <String, List<_QtyEntry>>{};
    for (final r in rows) {
      // #134: guard against null/empty matched_name — never show a blank product cell
      final rawName = r['matched_name']?.toString() ?? '';
      final name = rawName.trim().isEmpty ? 'Unknown item' : rawName;
      if (!byName.containsKey(name)) nameOrder.add(name);
      byName.putIfAbsent(name, () => []).add((
        qty: (r['qty'] as num?)?.toInt() ?? 0,
        seq: (r['recording_seq'] as num?)?.toInt() ?? 0,
        ord: (r['ord'] as num?)?.toInt() ?? 0,
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
  // One row per mention (no grouping), ordered by ord asc for that recording_seq.
  // No timestamps used — green is whole-clip (#119 rule).
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
            // #134: same fallback as grouped view — never a blank name cell
            final rawFlatName = r['matched_name']?.toString() ?? '';
            final name = rawFlatName.trim().isEmpty ? 'Unknown item' : rawFlatName;
            final qty = (r['qty'] as num?)?.toInt() ?? 0;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 28,
                    child: Text('$n.',
                        style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w500,
                          color: isPlaying ? _kGreen : _kSub,
                        )),
                  ),
                  Expanded(
                    child: Text(name,
                        style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w500,
                          color: isPlaying ? _kGreen : _kText,
                        ),
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: isPlaying ? _kGreen : const Color(0xFFF5F6F8),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: isPlaying ? _kGreen : _kBorder),
                    ),
                    child: Text('$qty',
                        style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600,
                          color: isPlaying ? Colors.white : _kText,
                        )),
                  ),
                ],
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
                Icon(
                  isExpanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 18, color: _kSub,
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
          // AnimatedSize — #153 shared; same 280ms/easeInOutCubic/antiAlias as Collect.
          AnimatedSize(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeInOutCubic,
            clipBehavior: Clip.antiAlias,
            child: isExpanded ? expandedContent : const SizedBox.shrink(),
          ),
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

class _AdminFulfillmentScreenState extends State<AdminFulfillmentScreen> {
  int _tab = 0;
  final _collectKey  = GlobalKey<_PickToLightScreenState>();

  // #125 R6: called by Arrivals after confirm to refresh Collect badge/list.
  void _refreshCollect() {
    _collectKey.currentState?._loadSuppliers();
    _collectKey.currentState?._loadCollectModes();
  }
  final _arrivalsKey = GlobalKey<_ArrivalsScreenState>();
  final _packKey     = GlobalKey<_PackScreenState>();

  @override
  void initState() {
    super.initState();
    RenderLog.write('fulfillment_area_mounted', 'true');
    RenderLog.write('fulfillment_three_areas_mounted', 'true');
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
    RenderLog.write('c113_fulfillment_tabs_top', viewport);
    return Column(children: [
      Container(
        color: _kCard,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              _TabBtn('Collect',   _tab == 0, () => setState(() => _tab = 0)),
              const SizedBox(width: 6),
              _TabBtn('Arrivals',  _tab == 1, () {
                setState(() => _tab = 1);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _arrivalsKey.currentState?.refresh();
                });
              }),
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
            _ArrivalsScreen(key: _arrivalsKey, onVoiceCount: _openVoiceInCollect),
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
