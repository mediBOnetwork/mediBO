// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../utils/render_log.dart';

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
  'received':   _kReceivedBg, 'short':      _kShortBg,
  'wrong':      _kWrongBg,    'not_coming': _kNotComingBg,
  'packed':     _kShippedBg,  'shipped':    _kShippedBg,
  'pending':    _kPendingBg,
};
const _stateFgMap = <String, Color>{
  'received':   _kReceivedFg, 'short':      _kShortFg,
  'wrong':      _kWrongFg,    'not_coming': _kNotComingFg,
  'packed':     _kShippedFg,  'shipped':    _kShippedFg,
  'pending':    _kPendingFg,
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
        child: Text('$value', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _kText)),
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
        child: Icon(icon, size: 18, color: onTap != null ? Colors.white : const Color(0xFF9CA3AF)),
      ),
    );
  }
}

// ── _BagScannerDialog — camera QR scan overlay ──────────────────────────────

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
                      Text(error.errorCode.name,
                          style: const TextStyle(fontSize: 12, color: _kSub)),
                      const SizedBox(height: 16),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
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

// ── PICK-TO-LIGHT SCREEN ────────────────────────────────────────────────────

class _PickToLightScreen extends StatefulWidget {
  const _PickToLightScreen({super.key});

  @override
  State<_PickToLightScreen> createState() => _PickToLightScreenState();
}

class _PickToLightScreenState extends State<_PickToLightScreen> {
  // Supplier
  List<String> _suppliers = [];
  String? _selectedSupplier;
  bool _loadingSuppliers = true;

  // Box
  List<Map<String, dynamic>> _items = [];
  bool _loadingBox = false;
  String? _error;

  // Navigation: _focusIdx = actual index into _items
  int _focusIdx = 0;
  bool _recording = false;
  bool _showListView = false;

  // Short qty panel
  bool _showShortPanel = false;
  int _shortQtyDraft = 1;

  // Feature flags
  bool _bagConfirmEnabled = false;
  bool _barcodeEnabled = false;
  bool _settingsLoaded = false;

  // Bag confirm state (reset on advance)
  bool _bagConfirmed = false;
  bool? _bagScanMatch;      // null=not tried, true=ok, false=mismatch
  String? _bagScanMsg;      // error detail on mismatch
  bool _bagConfirming = false;

  // Computed helpers
  Map<String, dynamic>? get _currentItem =>
      (_items.isNotEmpty && _focusIdx < _items.length) ? _items[_focusIdx] : null;

  bool get _currentIsPending =>
      (_currentItem?['fulfillment_state'] as String?) == 'pending';

  int get _pendingCount =>
      _items.where((i) => (i['fulfillment_state'] as String?) == 'pending').length;

  bool get _allDone => _items.isNotEmpty && _pendingCount == 0;

  // Actions blocked until bag confirmed (when flag on AND item is pending)
  bool get _blocked => _bagConfirmEnabled && _currentIsPending && !_bagConfirmed;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadSuppliers();
    RenderLog.write('fulfillment_pick_to_light', 'screen_mounted');
  }

  Future<void> _loadSettings() async {
    try {
      final bagRes = await Supabase.instance.client
          .rpc('get_app_setting', params: {'p_key': 'stage1_bag_confirm'});
      final barRes = await Supabase.instance.client
          .rpc('get_app_setting', params: {'p_key': 'stage1_barcode_scan'});
      if (!mounted) return;
      setState(() {
        _bagConfirmEnabled = bagRes == true;
        _barcodeEnabled = barRes == true;
        _settingsLoaded = true;
      });
      if (!_barcodeEnabled) {
        RenderLog.write('barcode_scan_hook_dormant', 'true');
      }
    } catch (_) {
      if (mounted) setState(() => _settingsLoaded = true);
    }
  }

  Future<void> _loadSuppliers() async {
    try {
      final res = await Supabase.instance.client
          .from('order_items')
          .select('assigned_supplier')
          .not('assigned_supplier', 'is', null)
          .neq('fulfillment_state', 'shipped')
          .neq('fulfillment_state', 'cancelled') as List;
      if (!mounted) return;
      final seen = <String>{};
      final names = <String>[];
      for (final r in res) {
        final s = (r as Map)['assigned_supplier']?.toString();
        if (s != null && seen.add(s)) names.add(s);
      }
      names.sort();
      setState(() { _suppliers = names; _loadingSuppliers = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loadingSuppliers = false; _error = e.toString(); });
    }
  }

  Future<void> _loadBox(String supplier) async {
    setState(() { _loadingBox = true; _error = null; _items = []; _focusIdx = 0; });
    try {
      final res = await Supabase.instance.client
          .rpc('get_receiving_box', params: {'p_supplier_name': supplier}) as List;
      if (!mounted) return;
      final items = res.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      // Sort: pending first, then by bag_no, then product_name
      items.sort((a, b) {
        final aPending = (a['fulfillment_state'] as String?) == 'pending' ? 0 : 1;
        final bPending = (b['fulfillment_state'] as String?) == 'pending' ? 0 : 1;
        if (aPending != bPending) return aPending - bPending;
        final bagA = (a['bag_no'] as num?)?.toInt() ?? 0;
        final bagB = (b['bag_no'] as num?)?.toInt() ?? 0;
        if (bagA != bagB) return bagA - bagB;
        return (a['product_name'] ?? '').toString().compareTo((b['product_name'] ?? '').toString());
      });
      final firstPending = items.indexWhere((i) => (i['fulfillment_state'] as String?) == 'pending');
      setState(() {
        _items = items;
        _focusIdx = firstPending >= 0 ? firstPending : 0;
        _loadingBox = false;
        _showListView = false;
      });
      RenderLog.write('fulfillment_ptl_loaded_${items.length}', supplier);
    } catch (e) {
      if (!mounted) return;
      setState(() { _loadingBox = false; _error = e.toString(); });
    }
  }

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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: const Color(0xFFDC2626)),
      );
    }
  }

  void _advance() {
    final nextPending = _items.indexWhere(
      (i) => (i['fulfillment_state'] as String?) == 'pending',
      _focusIdx + 1,
    );
    setState(() {
      _bagConfirmed = false;
      _bagScanMatch = null;
      _bagScanMsg = null;
      _showShortPanel = false;
      _shortQtyDraft = 1;
      if (nextPending >= 0) {
        _focusIdx = nextPending;
      } else {
        // Wrap: find any remaining pending from start
        final firstPending = _items.indexWhere(
          (i) => (i['fulfillment_state'] as String?) == 'pending',
        );
        if (firstPending >= 0) _focusIdx = firstPending;
      }
    });
  }

  void _goBack() {
    setState(() {
      if (_focusIdx > 0) _focusIdx--;
      _bagConfirmed = false;
      _bagScanMatch = null;
      _bagScanMsg = null;
      _showShortPanel = false;
      _shortQtyDraft = 1;
    });
  }

  void _skip() {
    final pending = <int>[];
    for (var i = 0; i < _items.length; i++) {
      if ((_items[i]['fulfillment_state'] as String?) == 'pending') pending.add(i);
    }
    if (pending.length <= 1) return;
    final pos = pending.indexOf(_focusIdx);
    final nextPos = (pos + 1) % pending.length;
    setState(() {
      _focusIdx = pending[nextPos];
      _bagConfirmed = false;
      _bagScanMatch = null;
      _bagScanMsg = null;
      _showShortPanel = false;
      _shortQtyDraft = 1;
    });
  }

  void _focusItem(int idx) {
    setState(() {
      _focusIdx = idx;
      _showListView = false;
      _bagConfirmed = false;
      _bagScanMatch = null;
      _bagScanMsg = null;
      _showShortPanel = false;
      _shortQtyDraft = 1;
    });
  }

  Future<void> _handleBagScan(String code) async {
    final item = _currentItem;
    if (item == null) return;
    setState(() => _bagConfirming = true);
    try {
      final res = await Supabase.instance.client
          .rpc('resolve_bag_code', params: {'p_code': code}) as List;
      if (!mounted) return;
      if (res.isEmpty) {
        setState(() {
          _bagScanMatch = false;
          _bagScanMsg = 'Unknown QR code';
          _bagConfirming = false;
        });
        return;
      }
      final row = Map<String, dynamic>.from(res.first as Map);
      final scannedOrderId = row['order_id']?.toString() ?? '';
      final currentOrderId = item['order_id']?.toString() ?? '';
      if (scannedOrderId == currentOrderId) {
        setState(() {
          _bagConfirmed = true;
          _bagScanMatch = true;
          _bagScanMsg = null;
          _bagConfirming = false;
        });
        RenderLog.write('bag_confirm_ok', 'scan:${item['bag_no']}');
      } else {
        final wrongBagNo = row['bag_no']?.toString() ?? '?';
        final wrongCustomer = row['customer']?.toString() ?? '';
        setState(() {
          _bagScanMatch = false;
          _bagScanMsg = 'Wrong bag — this is Bag $wrongBagNo ($wrongCustomer)';
          _bagConfirming = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _bagScanMatch = false;
        _bagScanMsg = 'Scan error: $e';
        _bagConfirming = false;
      });
    }
  }

  void _manualBagConfirm() {
    final item = _currentItem;
    if (item == null) return;
    setState(() { _bagConfirmed = true; _bagScanMatch = true; _bagScanMsg = null; });
    RenderLog.write('bag_confirm_ok', 'manual:${item['bag_no']}');
  }

  void _openBagScanner() {
    showDialog(
      context: context,
      builder: (_) => _BagScannerDialog(
        title: 'Scan Bag QR',
        onScanned: _handleBagScan,
      ),
    );
  }

  // Dormant barcode learn hook (only active when stage1_barcode_scan=true)
  Future<void> _handleItemScan(String code) async {
    if (!_barcodeEnabled) {
      RenderLog.write('barcode_scan_hook_dormant', 'scan_ignored');
      return;
    }
    // When flag is on: try to learn the barcode
    final item = _currentItem;
    if (item == null) return;
    try {
      await Supabase.instance.client.rpc('learn_barcode', params: {
        'p_order_item_id': item['order_item_id'],
        'p_code': code,
      });
      if (mounted) RenderLog.write('barcode_learn_ok', '${item['order_item_id']}:$code');
    } catch (_) {
      // Dormant — silently ignore errors too
    }
  }

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
      if (_loadingBox)
        const Expanded(child: Center(child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2)))
      else if (_selectedSupplier == null)
        const Expanded(child: Center(child: Text('Choose a supplier to begin',
            style: TextStyle(color: _kSub, fontSize: 15))))
      else if (_items.isEmpty)
        const Expanded(child: Center(child: Text('No items in this box',
            style: TextStyle(color: _kSub, fontSize: 15))))
      else if (_showListView)
        Expanded(child: _buildListView())
      else if (_allDone)
        Expanded(child: _buildDoneState())
      else
        Expanded(child: _buildFocusedCard()),
    ]);
  }

  Widget _buildSupplierPicker() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_items.isNotEmpty && !_showListView && !_allDone) ...[
          // Progress bar
          Row(children: [
            Expanded(
              child: LinearProgressIndicator(
                value: _items.isEmpty ? 0 : (_items.length - _pendingCount) / _items.length,
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
                            child: Text(s, style: const TextStyle(fontSize: 15, color: _kText)),
                          ))
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _selectedSupplier = v);
                    _loadBox(v);
                  },
                ),
              ),
            ),
            if (_items.isNotEmpty) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => setState(() => _showListView = !_showListView),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: _showListView ? _kGreen : _kBg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: _showListView ? _kGreen : _kBorder),
                  ),
                  child: Icon(
                    _showListView ? Icons.view_agenda_outlined : Icons.list_rounded,
                    size: 18,
                    color: _showListView ? Colors.white : _kSub,
                  ),
                ),
              ),
            ],
          ]),
        ),
      ]),
    );
  }

  Widget _buildFocusedCard() {
    final item = _currentItem;
    if (item == null) return const SizedBox.shrink();

    final name = item['product_name']?.toString() ?? '—';
    final company = item['company_name']?.toString() ?? '';
    final bagNo = item['bag_no']?.toString() ?? '?';
    final customer = item['customer']?.toString() ?? '';
    final orderedQty = (item['ordered_qty'] as num?)?.toInt() ?? 0;
    final imageUrl = item['image_url']?.toString();
    final isPending = _currentIsPending;
    final state = item['fulfillment_state']?.toString() ?? 'pending';
    final pending = _pendingCount;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(children: [
        // ── Focused item card ──
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: _kCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isPending ? _kGreen.withValues(alpha: 0.4) : (_stateBgMap[state] ?? _kBorder),
              width: isPending ? 2 : 1,
            ),
            boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 4))],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _FulfilImageTile(imageUrl, size: 80),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // Item position chip
                    if (pending > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: _kBg,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: _kBorder),
                        ),
                        child: Text(
                          'Item ${_focusIdx + 1} of ${_items.length}  ·  $pending pending',
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: _kSub),
                        ),
                      ),
                    // Product name — BIG
                    Text(
                      name,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _kText),
                    ),
                    if (company.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(company, style: const TextStyle(fontSize: 13, color: _kSub)),
                    ],
                    const SizedBox(height: 8),
                    // Qty ordered
                    Row(children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: _kBg,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: _kBorder),
                        ),
                        child: Text(
                          'Qty: $orderedQty',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _kText),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (!isPending) _StatePill(state),
                    ]),
                  ]),
                ),
              ]),
            ),

            // ── Bag destination — big green ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: _kReceivedBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _kReceivedFg.withValues(alpha: 0.3)),
                ),
                child: Row(children: [
                  const Icon(Icons.shopping_bag_outlined, color: _kReceivedFg, size: 22),
                  const SizedBox(width: 10),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      '→ Bag $bagNo',
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w900, color: _kReceivedFg),
                    ),
                    if (customer.isNotEmpty)
                      Text(customer,
                          style: const TextStyle(fontSize: 13, color: _kReceivedFg,
                              fontWeight: FontWeight.w500)),
                  ]),
                ]),
              ),
            ),

            // ── Bag confirm section ──
            if (_bagConfirmEnabled && isPending) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: _buildBagConfirmSection(bagNo, customer),
              ),
            ],

            // ── Barcode scan button (dormant hook) ──
            if (_barcodeEnabled && isPending) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: OutlinedButton.icon(
                  onPressed: () => showDialog(
                    context: context,
                    builder: (_) => _BagScannerDialog(
                      title: 'Scan Item Barcode',
                      onScanned: _handleItemScan,
                    ),
                  ),
                  icon: const Icon(Icons.barcode_reader, size: 16),
                  label: const Text('Scan item barcode'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _kSub,
                    side: const BorderSide(color: _kBorder),
                  ),
                ),
              ),
            ],

            // ── Action buttons ──
            if (isPending) ...[
              const SizedBox(height: 14),
              const Divider(height: 1, color: _kBorder),
              Padding(
                padding: const EdgeInsets.all(14),
                child: _buildActionButtons(orderedQty),
              ),
            ] else ...[
              // Re-edit controls for done item
              const SizedBox(height: 12),
              const Divider(height: 1, color: _kBorder),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(children: [
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _recording ? null : () => _record('pending'),
                    icon: const Icon(Icons.undo_rounded, size: 15),
                    label: const Text('Reset to pending'),
                    style: TextButton.styleFrom(foregroundColor: _kSub),
                  ),
                ]),
              ),
            ],
          ]),
        ),

        const SizedBox(height: 16),

        // ── Navigation row ──
        Row(children: [
          OutlinedButton.icon(
            onPressed: _focusIdx > 0 ? _goBack : null,
            icon: const Icon(Icons.arrow_back_rounded, size: 16),
            label: const Text('Back'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _kSub,
              side: const BorderSide(color: _kBorder),
            ),
          ),
          const Spacer(),
          if (isPending && _pendingCount > 1)
            OutlinedButton.icon(
              onPressed: _skip,
              icon: const Icon(Icons.skip_next_rounded, size: 16),
              label: const Text('Skip'),
              style: OutlinedButton.styleFrom(
                foregroundColor: _kSub,
                side: const BorderSide(color: _kBorder),
              ),
            ),
        ]),
      ]),
    );
  }

  Widget _buildBagConfirmSection(String bagNo, String customer) {
    if (_bagConfirming) {
      return const Row(children: [
        SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2)),
        SizedBox(width: 8),
        Text('Resolving bag…', style: TextStyle(fontSize: 13, color: _kSub)),
      ]);
    }
    if (_bagConfirmed) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: _kReceivedBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _kReceivedFg.withValues(alpha: 0.3)),
        ),
        child: Row(children: [
          const Icon(Icons.check_circle_rounded, color: _kReceivedFg, size: 16),
          const SizedBox(width: 8),
          Text('Bag $bagNo confirmed', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _kReceivedFg)),
          if (customer.isNotEmpty) ...[
            const SizedBox(width: 4),
            Text('· $customer', style: const TextStyle(fontSize: 12, color: _kReceivedFg)),
          ],
        ]),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Scan button
      SizedBox(
        width: double.infinity,
        height: 44,
        child: OutlinedButton.icon(
          onPressed: _openBagScanner,
          icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
          label: Text('Scan Bag $bagNo'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _kGreen,
            side: const BorderSide(color: _kGreen),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
      const SizedBox(height: 6),
      // Manual confirm link
      Center(
        child: GestureDetector(
          onTap: _manualBagConfirm,
          child: Text(
            'Confirm Bag $bagNo manually',
            style: const TextStyle(
                fontSize: 13, color: _kSub,
                decoration: TextDecoration.underline,
                decorationColor: _kSub),
          ),
        ),
      ),
      // Mismatch error
      if (_bagScanMatch == false && _bagScanMsg != null) ...[
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _kWrongBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _kWrongFg.withValues(alpha: 0.3)),
          ),
          child: Row(children: [
            const Icon(Icons.warning_amber_rounded, color: _kWrongFg, size: 16),
            const SizedBox(width: 8),
            Expanded(child: Text(_bagScanMsg!,
                style: const TextStyle(fontSize: 13, color: _kWrongFg))),
          ]),
        ),
      ],
    ]);
  }

  Widget _buildActionButtons(int orderedQty) {
    final blocked = _blocked;

    return Column(children: [
      // Got all + Short row
      Row(children: [
        Expanded(
          child: _ActionBtn(
            'Got all $orderedQty',
            _kGreen,
            Icons.check_rounded,
            blocked ? null : () => _record('received', qty: orderedQty),
            loading: _recording,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ActionBtn(
            _showShortPanel ? 'Hide short' : 'Short',
            _kShortFg,
            Icons.content_cut_rounded,
            blocked ? null : () => setState(() {
              _showShortPanel = !_showShortPanel;
              if (_showShortPanel) {
                _shortQtyDraft = (orderedQty - 1).clamp(1, orderedQty - 1);
              }
            }),
          ),
        ),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: _ActionBtn(
            'Wrong item',
            _kWrongFg,
            Icons.close_rounded,
            _recording ? null : () => _record('wrong'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ActionBtn(
            'Not coming',
            _kNotComingFg,
            Icons.block_outlined,
            _recording ? null : () => _record('not_coming'),
          ),
        ),
      ]),

      if (blocked)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: _kPendingBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(children: [
              Icon(Icons.lock_outlined, size: 14, color: _kPendingFg),
              SizedBox(width: 6),
              Text('Confirm the bag first (scan or manual)',
                  style: TextStyle(fontSize: 12, color: _kPendingFg)),
            ]),
          ),
        ),

      if (_showShortPanel) ...[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _kBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _kBorder),
          ),
          child: Column(children: [
            const Text('How many did you receive?',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _kText)),
            const SizedBox(height: 12),
            _QtyStepper(
              value: _shortQtyDraft,
              max: orderedQty - 1,
              onChanged: (v) => setState(() => _shortQtyDraft = v),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: FilledButton(
                onPressed: _recording ? null : () => _record('short', qty: _shortQtyDraft),
                style: FilledButton.styleFrom(
                  backgroundColor: _kShortFg,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: Text(
                  'Save Short ($_shortQtyDraft/$orderedQty)',
                  style: const TextStyle(fontSize: 14, color: Colors.white, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ]),
        ),
      ],
    ]);
  }

  Widget _buildDoneState() {
    final total = _items.length;
    final received = _items.where((i) => (i['fulfillment_state'] as String?) == 'received').length;
    final short = _items.where((i) => (i['fulfillment_state'] as String?) == 'short').length;
    final wrong = _items.where((i) => (i['fulfillment_state'] as String?) == 'wrong').length;
    final notComing = _items.where((i) => (i['fulfillment_state'] as String?) == 'not_coming').length;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _kReceivedBg,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check_circle_rounded, color: _kReceivedFg, size: 48),
          ),
          const SizedBox(height: 16),
          const Text('All done!', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: _kText)),
          const SizedBox(height: 4),
          Text('$total items processed', style: const TextStyle(fontSize: 14, color: _kSub)),
          const SizedBox(height: 20),
          Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
            _SummaryChip('$received received', _kReceivedBg, _kReceivedFg),
            if (short > 0) _SummaryChip('$short short', _kShortBg, _kShortFg),
            if (wrong > 0) _SummaryChip('$wrong wrong', _kWrongBg, _kWrongFg),
            if (notComing > 0) _SummaryChip('$notComing N/A', _kNotComingBg, _kNotComingFg),
          ]),
          const SizedBox(height: 24),
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

  Widget _buildListView() {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: _items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (_, i) {
        final item = _items[i];
        final state = item['fulfillment_state']?.toString() ?? 'pending';
        final isPending = state == 'pending';
        final isFocused = i == _focusIdx;
        final name = item['product_name']?.toString() ?? '—';
        final bagNo = item['bag_no']?.toString() ?? '?';
        final orderedQty = (item['ordered_qty'] as num?)?.toInt() ?? 0;
        final imageUrl = item['image_url']?.toString();

        return GestureDetector(
          onTap: () => _focusItem(i),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isFocused ? _kGreen.withValues(alpha: 0.05) : _kCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isFocused
                    ? _kGreen
                    : (isPending ? _kBorder : (_stateBgMap[state] ?? _kBorder)),
                width: isFocused ? 2 : 1,
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
                  Text('Bag $bagNo  ·  Qty $orderedQty',
                      style: const TextStyle(fontSize: 12, color: _kSub)),
                ]),
              ),
              const SizedBox(width: 8),
              _StatePill(state),
            ]),
          ),
        );
      },
    );
  }
}

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
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? color.withValues(alpha: 0.08) : _kBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: enabled ? color.withValues(alpha: 0.4) : _kBorder),
        ),
        child: loading
            ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: color, strokeWidth: 2))
            : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, size: 16, color: enabled ? color : _kSub),
                const SizedBox(width: 6),
                Text(label,
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700,
                        color: enabled ? color : _kSub)),
              ]),
      ),
    );
  }
}

// ── BAG LABELS SCREEN ────────────────────────────────────────────────────────

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
      final res = await Supabase.instance.client
          .rpc('get_customer_pack_status') as List;
      if (!mounted) return;
      final bags = res.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      bags.sort((a, b) {
        final bagA = (a['bag_no'] as num?)?.toInt() ?? 0;
        final bagB = (b['bag_no'] as num?)?.toInt() ?? 0;
        return bagA - bagB;
      });
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
          onPressed: _load,
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('Refresh'),
          style: OutlinedButton.styleFrom(foregroundColor: _kGreen, side: const BorderSide(color: _kGreen)),
        ),
      ]));
    }

    return Column(children: [
      // Print button header
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Row(children: [
          Text('${_bags.length} bag labels', style: const TextStyle(fontSize: 14, color: _kSub)),
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
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('Refresh'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _kSub, side: const BorderSide(color: _kBorder),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 220,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            mainAxisExtent: 260,
          ),
          itemCount: _bags.length,
          itemBuilder: (_, i) => _buildLabel(_bags[i]),
        ),
      ),
    ]);
  }

  Widget _buildLabel(Map<String, dynamic> bag) {
    final orderId = bag['order_id']?.toString() ?? '';
    final bagNo = bag['bag_no']?.toString() ?? '?';
    final customer = bag['pharmacy_name']?.toString() ?? '—';
    final qrData = 'MEDIBO-BAG:$orderId';

    return Container(
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kBorder),
        boxShadow: const [BoxShadow(color: Color(0x0F000000), blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: _kGreen,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(
              'Bag $bagNo',
              style: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w900, color: Colors.white),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        QrImageView(
          data: qrData,
          version: QrVersions.auto,
          size: 130,
          eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: _kText),
          dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square, color: _kText),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            customer,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'medibo.in',
          style: const TextStyle(fontSize: 10, color: _kSub),
        ),
        const SizedBox(height: 10),
      ]),
    );
  }
}

// ── PACK SCREEN ─────────────────────────────────────────────────────────────

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

  @override
  void initState() {
    super.initState();
    _load();
    RenderLog.write('fulfillment_pack_screen', 'true');
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final res = await Supabase.instance.client
          .rpc('get_customer_pack_status') as List;
      if (!mounted) return;
      final bags = res.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      setState(() { _bags = bags; _loading = false; });
      for (var i = 0; i < bags.length; i++) {
        RenderLog.write('fulfillment_pack_card_$i', bags[i]['pharmacy_name']?.toString() ?? '');
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
      await Supabase.instance.client.rpc('ship_order', params: {
        'p_order_id': orderId,
        'p_partial': partial,
      });
      RenderLog.write('fulfillment_ship_ok', '$orderId:${partial ? 'partial' : 'full'}');
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _shipping[orderId] = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: const Color(0xFFDC2626)),
      );
    }
  }

  Future<void> _showShipDialog(Map<String, dynamic> bag) async {
    final orderId = bag['order_id'].toString();
    final bool hasShort = ((bag['short_count'] as num?)?.toInt() ?? 0) > 0;
    final bool hasNotComing = ((bag['not_coming_count'] as num?)?.toInt() ?? 0) > 0;
    final bool canPartial = hasShort || hasNotComing;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Ship Order',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _kText)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Bag ${bag['bag_no'] ?? ''} — ${bag['pharmacy_name'] ?? ''}',
              style: const TextStyle(fontSize: 14, color: _kSub)),
          const SizedBox(height: 12),
          if (canPartial)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: _kPendingBg, borderRadius: BorderRadius.circular(8)),
              child: const Row(children: [
                Icon(Icons.warning_amber_rounded, size: 16, color: _kPendingFg),
                SizedBox(width: 8),
                Expanded(child: Text('Some items are short or not coming.',
                    style: TextStyle(fontSize: 13, color: _kPendingFg))),
              ]),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: _kSub))),
          if (canPartial)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'partial'),
              child: const Text('Ship Partial',
                  style: TextStyle(color: Color(0xFF993C1D), fontWeight: FontWeight.w700)),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'full'),
            style: FilledButton.styleFrom(backgroundColor: _kGreen,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: const Text('Ship', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (result == 'full') await _ship(orderId, partial: false);
    else if (result == 'partial') await _ship(orderId, partial: true);
  }

  @override
  Widget build(BuildContext context) {
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
          onPressed: _load,
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('Refresh'),
          style: OutlinedButton.styleFrom(foregroundColor: _kGreen, side: const BorderSide(color: _kGreen)),
        ),
      ]));
    }
    return RefreshIndicator(
      color: _kGreen,
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _bags.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) => _buildBagCard(_bags[i]),
      ),
    );
  }

  Widget _buildBagCard(Map<String, dynamic> bag) {
    final orderId = bag['order_id'].toString();
    final pharmacyName = bag['pharmacy_name']?.toString() ?? '—';
    final bagNo = bag['bag_no']?.toString() ?? '';
    final status = bag['fulfillment_status']?.toString() ?? 'open';
    final receivedCount = (bag['received_count'] as num?)?.toInt() ?? 0;
    final totalCount = (bag['total_count'] as num?)?.toInt() ?? 0;
    final shortCount = (bag['short_count'] as num?)?.toInt() ?? 0;
    final notComingCount = (bag['not_coming_count'] as num?)?.toInt() ?? 0;
    final isExpanded = _expanded.contains(orderId);
    final isShipping = _shipping[orderId] == true;
    final isShipped = status == 'shipped' || status == 'partially_shipped';
    final canShip = !isShipped && receivedCount > 0;

    return Container(
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isShipped ? _kShippedBg : _kBorder),
        boxShadow: const [BoxShadow(color: Color(0x0F000000), blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
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
                Text(pharmacyName,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _kText),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Row(children: [
                  _OrderStatusBadge(status),
                  const SizedBox(width: 8),
                  Text('$receivedCount/$totalCount ready',
                      style: const TextStyle(fontSize: 12, color: _kSub)),
                  if (shortCount > 0) ...[
                    const SizedBox(width: 6),
                    Text('$shortCount short',
                        style: const TextStyle(fontSize: 12, color: _kShortFg, fontWeight: FontWeight.w600)),
                  ],
                  if (notComingCount > 0) ...[
                    const SizedBox(width: 6),
                    Text('$notComingCount N/A',
                        style: const TextStyle(fontSize: 12, color: _kNotComingFg, fontWeight: FontWeight.w600)),
                  ],
                ]),
              ])),
              Icon(isExpanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded, color: _kSub),
            ]),
          ),
        ),
        if (!isShipped && canShip) ...[
          const Divider(height: 1, color: _kBorder),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: SizedBox(
              width: double.infinity, height: 44,
              child: FilledButton.icon(
                onPressed: isShipping ? null : () => _showShipDialog(bag),
                icon: isShipping
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.local_shipping_outlined, size: 18),
                label: Text(isShipping ? 'Shipping…' : 'Ship Order',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                style: FilledButton.styleFrom(
                  backgroundColor: _kGreen,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ),
        ],
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
    final name = item['product_name']?.toString() ?? '—';
    final qty = (item['quantity'] as num?)?.toInt() ?? 0;
    final state = item['fulfillment_state']?.toString() ?? 'pending';
    final imageUrl = item['image_url']?.toString();

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: _kBorder, width: 0.5))),
      child: Row(children: [
        _FulfilImageTile(imageUrl, size: 40),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _kText),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 3),
          Text('Qty: $qty', style: const TextStyle(fontSize: 12, color: _kSub)),
        ])),
        _StatePill(state),
      ]),
    );
  }
}

// ── ENTRY POINT ─────────────────────────────────────────────────────────────

class AdminFulfillmentScreen extends StatefulWidget {
  static final _key = GlobalKey<_AdminFulfillmentScreenState>();
  AdminFulfillmentScreen() : super(key: _key);
  static void triggerFocus() => _key.currentState?._onFocus();

  @override
  State<AdminFulfillmentScreen> createState() => _AdminFulfillmentScreenState();
}

class _AdminFulfillmentScreenState extends State<AdminFulfillmentScreen> {
  int _tab = 0;
  final _ptlKey    = GlobalKey<_PickToLightScreenState>();
  final _packKey   = GlobalKey<_PackScreenState>();
  final _labelsKey = GlobalKey<_BagLabelsScreenState>();

  @override
  void initState() {
    super.initState();
    RenderLog.write('fulfillment_area_mounted', 'true');
  }

  void _onFocus() {
    // No-op — IndexedStack keeps all screens alive.
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Container(
        color: _kCard,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Fulfillment',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: _kText)),
          const SizedBox(height: 12),
          Row(children: [
            _TabBtn('Receive', _tab == 0, () => setState(() => _tab = 0)),
            const SizedBox(width: 8),
            _TabBtn('Pack & Ship', _tab == 1, () => setState(() => _tab = 1)),
            const SizedBox(width: 8),
            _TabBtn('Bag Labels', _tab == 2, () => setState(() => _tab = 2)),
          ]),
          const SizedBox(height: 1),
          const Divider(height: 1, color: _kBorder),
        ]),
      ),
      Expanded(
        child: IndexedStack(
          index: _tab,
          children: [
            _PickToLightScreen(key: _ptlKey),
            _PackScreen(key: _packKey),
            _BagLabelsScreen(key: _labelsKey),
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
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14, fontWeight: FontWeight.w700,
            color: selected ? Colors.white : _kSub,
          ),
        ),
      ),
    );
  }
}
