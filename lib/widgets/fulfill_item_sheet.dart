// ignore_for_file: avoid_web_libraries_in_flutter
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

// ── Colours (match admin_fulfillment_screen tokens) ─────────────────────────
const _kGreen        = Color(0xFF1B7A43);
const _kBg           = Color(0xFFF5F6F8);
const _kCard         = Colors.white;
const _kBorder       = Color(0xFFE5E7EB);
const _kText         = Color(0xFF111827);
const _kSub          = Color(0xFF6B7280);
const _kShortFg      = Color(0xFF993C1D);
const _kPartialFg    = Color(0xFFD97706); // amber for "Few item wrong"
const _kWrongFg      = Color(0xFFB42318);
const _kNotComingFg  = Color(0xFF5A5A57);
const _kReceivedFg   = Color(0xFF0F6E56);
const _kPurple       = Color(0xFF7C3AED);
const _kPurpleBg     = Color(0xFFEDE9FE);
const _kPurpleBorder = Color(0xFFDDD6FE);

// ── State enum ───────────────────────────────────────────────────────────────
enum _ItemSheetState {
  pending,
  shortfall,
  receivedFull,
  disputeActive,
  disputeResolved,
  wrongItem,
  notComing,
  fallback,
}

// ── Main entry points ─────────────────────────────────────────────────────────

/// Show the unified item action sheet. On desktop (≥900px) uses Dialog; on
/// mobile uses ModalBottomSheet. Both render the same [FulfillItemSheet] body.
Future<void> showFulfillItemSheet({
  required BuildContext context,
  required Map<String, dynamic> item,
  required String supplierName,
  required bool recording,
  required Map<String, dynamic>? existingDispute,
  required Future<void> Function(String state, {int? qty, String? note}) onRecord,
  required void Function(String itemId, Map<String, dynamic> dispute) onDisputeCreated,
  required void Function() onViewDispute,
}) {
  final isDesktop = MediaQuery.of(context).size.width >= 900;

  if (isDesktop) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: SingleChildScrollView(
            child: FulfillItemSheet(
              item: item,
              supplierName: supplierName,
              recording: recording,
              existingDispute: existingDispute,
              onRecord: onRecord,
              onDisputeCreated: onDisputeCreated,
              onViewDispute: onViewDispute,
            ),
          ),
        ),
      ),
    );
  }

  // Mobile — content-height bottom sheet
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    backgroundColor: _kCard,
    builder: (ctx) {
      final bottomPad = MediaQuery.of(ctx).viewInsets.bottom
          + MediaQuery.of(ctx).viewPadding.bottom;
      return Padding(
        padding: EdgeInsets.only(bottom: bottomPad),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FulfillItemSheet(
              item: item,
              supplierName: supplierName,
              recording: recording,
              existingDispute: existingDispute,
              onRecord: onRecord,
              onDisputeCreated: onDisputeCreated,
              onViewDispute: onViewDispute,
            ),
          ],
        ),
      );
    },
  );
}

// ── Widget ───────────────────────────────────────────────────────────────────

class FulfillItemSheet extends StatefulWidget {
  final Map<String, dynamic> item;
  final String supplierName;
  final bool recording;
  final Map<String, dynamic>? existingDispute;
  final Future<void> Function(String state, {int? qty, String? note}) onRecord;
  final void Function(String itemId, Map<String, dynamic> dispute) onDisputeCreated;
  final void Function() onViewDispute;

  const FulfillItemSheet({
    super.key,
    required this.item,
    required this.supplierName,
    required this.recording,
    required this.existingDispute,
    required this.onRecord,
    required this.onDisputeCreated,
    required this.onViewDispute,
  });

  @override
  State<FulfillItemSheet> createState() => _FulfillItemSheetState();
}

class _FulfillItemSheetState extends State<FulfillItemSheet> {
  late String _localFsState;
  late int _localRecQty;
  late Map<String, dynamic>? _dispute;

  // #193: inline expanders (replaces old _showStepper / _StepperBlock)
  bool _showMissingInline = false;
  bool _showWrongPartialInline = false;
  late int _missingDraft;      // counted received qty (for "Report missing")
  int _wrongPartialDraft = 1;  // wrong-qty (for "Few item wrong")
  bool _confirmingMissing = false;
  bool _confirmingWrongPartial = false;
  final TextEditingController _missingQtyCtrl = TextEditingController();
  final TextEditingController _wrongPartialQtyCtrl = TextEditingController();

  // C173: wrong-item inline capture (unchanged)
  bool _flaggingWrong = false;
  bool _flaggingWrongLoading = false;
  final TextEditingController _wrongNameCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();

    final ordQty = _ordQty;

    final rawFs = widget.item['fulfillment_state']?.toString();
    if (rawFs != null && rawFs.isNotEmpty) {
      _localFsState = rawFs;
    } else {
      final recLocked = widget.item['received_locked'];
      final recQty    = (widget.item['received_qty'] as num?)?.toInt() ?? 0;
      if (recLocked == true || recLocked == 'true') {
        _localFsState = 'received';
      } else if (recQty > 0 && ordQty > 0 && recQty < ordQty) {
        _localFsState = 'short';
      } else if (recQty > 0) {
        _localFsState = 'received';
      } else {
        _localFsState = 'pending';
      }
    }

    _localRecQty = (widget.item['received_qty'] as num?)?.toInt() ?? 0;
    final safeOrd = ordQty > 0 ? ordQty : 1;
    _missingDraft = _localRecQty.clamp(0, safeOrd);

    _dispute = widget.existingDispute;
    _logOpen();
  }

  @override
  void dispose() {
    _missingQtyCtrl.dispose();
    _wrongPartialQtyCtrl.dispose();
    _wrongNameCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(FulfillItemSheet old) {
    super.didUpdateWidget(old);
    if (widget.existingDispute != null && _dispute == null) {
      _dispute = widget.existingDispute;
    }
  }

  void _logOpen() {
    final itemId   = widget.item['order_item_id']?.toString() ?? '';
    final oiidOk   = itemId.isNotEmpty;
    final state    = _deriveState();
    final stateStr = state == _ItemSheetState.fallback ? 'FALLBACK' : state.name.toUpperCase();

    RenderLog.write('c163_sheet_state', stateStr);
    RenderLog.write('c163_oiid_present', '$oiidOk');
    RenderLog.write('c162_sheet_opened', 'state=$stateStr;order_item_id=$itemId');
    RenderLog.write('c162_state_rendered', stateStr);
  }

  // ── Derived properties ─────────────────────────────────────────────────────

  int get _ordQty {
    final v = widget.item['ordered_qty'] ?? widget.item['ordered'];
    return (v as num?)?.toInt() ?? 0;
  }
  String get _name     => widget.item['product_name']?.toString() ?? '—';
  String get _unit     => widget.item['pack_type']?.toString() ?? '';
  String? get _imageUrl => widget.item['image_url']?.toString();
  String? get _itemId  => widget.item['order_item_id']?.toString();

  int get _shortQty => (_ordQty - _localRecQty).clamp(0, _ordQty.clamp(0, 999999));

  _ItemSheetState _deriveState() {
    if (_dispute != null) {
      final dStatus = _dispute!['status']?.toString() ?? '';
      if (dStatus == 'resolved' || dStatus == 'cancelled') {
        return _ItemSheetState.disputeResolved;
      }
      if (dStatus == 'reminder_sent' || dStatus == 'shop_logged' ||
          dStatus == 'accepted_missing' || dStatus == 'denied') {
        return _ItemSheetState.disputeActive;
      }
    }
    switch (_localFsState) {
      case 'received':   return _ItemSheetState.receivedFull;
      case 'short':      return _ItemSheetState.shortfall;
      case 'wrong':      return _ItemSheetState.wrongItem;
      case 'not_coming': return _ItemSheetState.notComing;
      case 'pending':    return _ItemSheetState.pending;
      default:           return _ItemSheetState.fallback;
    }
  }

  // ── Backend calls ──────────────────────────────────────────────────────────

  Future<void> _doRecord(String state, {int? qty, String? note}) async {
    await widget.onRecord(state, qty: qty, note: note);
    if (!mounted) return;
    setState(() {
      _localFsState = state;
      if (qty != null) _localRecQty = qty;
      if (state == 'short' && qty != null) {
        _missingDraft = qty;
        _showMissingInline = false;
      }
    });
    final stateStr = _deriveState().name.toUpperCase();
    RenderLog.write('c163_sheet_state', stateStr);
    RenderLog.write('c162_state_rendered', stateStr);
  }

  // #193: Confirm missing — same short RPC, receives = counted (missing = ordered - counted)
  Future<void> _doConfirmMissing() async {
    if (_confirmingMissing) return;
    setState(() => _confirmingMissing = true);
    RenderLog.write('c193_missing_confirmed',
        'order_item_id=${_itemId ?? ''};counted=$_missingDraft');
    try {
      await _doRecord('short', qty: _missingDraft);
      if (mounted) {
        setState(() { _confirmingMissing = false; _showMissingInline = false; });
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _confirmingMissing = false);
      final msg = e.toString().substring(0, e.toString().length.clamp(0, 80));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $msg'), backgroundColor: const Color(0xFFDC2626)));
    }
  }

  // #193: Confirm wrong-partial — calls fw_flag_wrong_partial
  Future<void> _doWrongPartial() async {
    if (_confirmingWrongPartial) return;
    final id = _itemId;
    if (id == null || id.isEmpty) return;
    setState(() => _confirmingWrongPartial = true);
    RenderLog.write('c193_wrong_partial_called',
        'order_item_id=$id;wrong_qty=$_wrongPartialDraft');
    try {
      final res = await Supabase.instance.client.rpc('fw_flag_wrong_partial', params: {
        'p_order_item_id': id,
        'p_wrong_qty': _wrongPartialDraft,
        'p_wrong_product_name': null,
      }) as Map;
      if (!mounted) return;
      final err = res['error']?.toString();
      if (err != null) {
        setState(() => _confirmingWrongPartial = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $err'), backgroundColor: const Color(0xFFDC2626)));
        return;
      }
      final wQty = (res['wrong_qty'] as num?)?.toInt() ?? _wrongPartialDraft;
      final unitLabel = _unit.isNotEmpty ? ' $_unit' : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Marked $wQty$unitLabel wrong')));
      setState(() { _confirmingWrongPartial = false; _showWrongPartialInline = false; });
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _confirmingWrongPartial = false);
      final msg = e.toString().substring(0, e.toString().length.clamp(0, 80));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $msg'), backgroundColor: const Color(0xFFDC2626)));
    }
  }

  // ── C173: flag wrong item (whole line, unchanged) ─────────────────────────

  Future<void> _fw_flagWrongItem() async {
    final id = _itemId;
    if (id == null || id.isEmpty) return;
    final wrongName = _wrongNameCtrl.text.trim();
    setState(() => _flaggingWrongLoading = true);
    try {
      await _doRecord('wrong', note: wrongName.isNotEmpty ? wrongName : null);
      if (!mounted) return;
      setState(() => _flaggingWrongLoading = false);
      final newDispute = <String, dynamic>{
        'dispute_id': '',
        'kind': 'wrong_item',
        'status': 'shop_logged',
        'order_item_id': id,
        'product_name': _name,
        'wrong_product_name': wrongName.isNotEmpty ? wrongName : null,
      };
      widget.onDisputeCreated(id, newDispute);
      RenderLog.write('c173_wrong_flagged', 'order_item_id=$id');
      RenderLog.write('c177_action', 'action=wrong_item;rpc=set_item_receiving;ok=true');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Marked wrong item — include it when you send the supplier reminder'),
            duration: Duration(seconds: 4),
          ),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().substring(0, e.toString().length.clamp(0, 80));
      setState(() { _flaggingWrong = false; _flaggingWrongLoading = false; });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $msg'), backgroundColor: const Color(0xFFDC2626)),
      );
      RenderLog.write('c173_wrong_flag_error', 'order_item_id=$id;exception=$msg');
      RenderLog.write('c177_action', 'action=wrong_item;rpc=set_item_receiving;ok=false');
    }
  }

  // ── #193: Inline two-half row — Report missing ────────────────────────────

  Widget _buildMissingInlineRow() {
    final ordQty = _ordQty;
    final missing = (ordQty - _missingDraft).clamp(0, ordQty);
    final unitLabel = _unit.isNotEmpty ? ' $_unit' : '';
    final confirmLabel = 'Confirm missing · $missing$unitLabel';
    const borderColor = _kShortFg;

    return SizedBox(
      height: 52,
      child: Row(children: [
        // LEFT half: stepper
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: _kShortFg.withValues(alpha: 0.06),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(11),
                bottomLeft: Radius.circular(11),
              ),
              border: Border(
                top: BorderSide(color: _kShortFg.withValues(alpha: 0.4)),
                bottom: BorderSide(color: _kShortFg.withValues(alpha: 0.4)),
                left: BorderSide(color: _kShortFg.withValues(alpha: 0.4)),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _InlineStepBtn(
                  icon: Icons.remove,
                  enabled: !_confirmingMissing && _missingDraft > 0,
                  color: borderColor,
                  onTap: () => setState(() {
                    _missingDraft = (_missingDraft - 1).clamp(0, ordQty);
                    _missingQtyCtrl.text = '$_missingDraft';
                  }),
                ),
                SizedBox(
                  width: 48,
                  child: TextField(
                    controller: _missingQtyCtrl,
                    enabled: !_confirmingMissing,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                        color: _kText),
                    decoration: const InputDecoration.collapsed(hintText: '0'),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (v) {
                      final n = int.tryParse(v) ?? 0;
                      final clamped = n.clamp(0, ordQty);
                      setState(() => _missingDraft = clamped);
                      if (v.isNotEmpty && v != '$clamped') {
                        _missingQtyCtrl.value = _missingQtyCtrl.value.copyWith(
                          text: '$clamped',
                          selection: TextSelection.collapsed(
                              offset: '$clamped'.length),
                        );
                      }
                    },
                  ),
                ),
                if (_unit.isNotEmpty)
                  Text(' $_unit',
                      style: const TextStyle(fontSize: 10, color: _kSub)),
                _InlineStepBtn(
                  icon: Icons.add,
                  enabled: !_confirmingMissing && _missingDraft < ordQty,
                  color: borderColor,
                  onTap: () => setState(() {
                    _missingDraft = (_missingDraft + 1).clamp(0, ordQty);
                    _missingQtyCtrl.text = '$_missingDraft';
                  }),
                ),
              ],
            ),
          ),
        ),
        // RIGHT half: confirm button
        Expanded(
          child: GestureDetector(
            onTap: _confirmingMissing ? null : _doConfirmMissing,
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: _confirmingMissing
                    ? _kShortFg.withValues(alpha: 0.45)
                    : _kShortFg,
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(11),
                  bottomRight: Radius.circular(11),
                ),
                border: Border(
                  top: BorderSide(color: _kShortFg.withValues(alpha: 0.4)),
                  bottom: BorderSide(color: _kShortFg.withValues(alpha: 0.4)),
                  right: BorderSide(color: _kShortFg.withValues(alpha: 0.4)),
                ),
              ),
              child: _confirmingMissing
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : Text(confirmLabel,
                      style: const TextStyle(fontSize: 11,
                          fontWeight: FontWeight.w700, color: Colors.white),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
      ]),
    );
  }

  // ── #193: Inline two-half row — Few item wrong ────────────────────────────

  Widget _buildWrongPartialInlineRow() {
    final ordQty = _ordQty;
    final maxWrong = ordQty > 0 ? ordQty : 1;
    final keepQty = (ordQty - _wrongPartialDraft).clamp(0, ordQty);
    final unitLabel = _unit.isNotEmpty ? ' $_unit' : '';
    final confirmLabel = 'Confirm wrong · keep $keepQty$unitLabel';
    const borderColor = _kPartialFg;

    return SizedBox(
      height: 52,
      child: Row(children: [
        // LEFT half: stepper
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: _kPartialFg.withValues(alpha: 0.06),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(11),
                bottomLeft: Radius.circular(11),
              ),
              border: Border(
                top: BorderSide(color: _kPartialFg.withValues(alpha: 0.4)),
                bottom: BorderSide(color: _kPartialFg.withValues(alpha: 0.4)),
                left: BorderSide(color: _kPartialFg.withValues(alpha: 0.4)),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _InlineStepBtn(
                  icon: Icons.remove,
                  enabled: !_confirmingWrongPartial && _wrongPartialDraft > 1,
                  color: borderColor,
                  onTap: () => setState(() {
                    _wrongPartialDraft = (_wrongPartialDraft - 1).clamp(1, maxWrong);
                    _wrongPartialQtyCtrl.text = '$_wrongPartialDraft';
                  }),
                ),
                SizedBox(
                  width: 48,
                  child: TextField(
                    controller: _wrongPartialQtyCtrl,
                    enabled: !_confirmingWrongPartial,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                        color: _kText),
                    decoration: const InputDecoration.collapsed(hintText: '1'),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (v) {
                      final n = int.tryParse(v) ?? 1;
                      final clamped = n.clamp(1, maxWrong);
                      setState(() => _wrongPartialDraft = clamped);
                      if (v.isNotEmpty && v != '$clamped') {
                        _wrongPartialQtyCtrl.value = _wrongPartialQtyCtrl.value.copyWith(
                          text: '$clamped',
                          selection: TextSelection.collapsed(
                              offset: '$clamped'.length),
                        );
                      }
                    },
                  ),
                ),
                if (_unit.isNotEmpty)
                  Text(' $_unit',
                      style: const TextStyle(fontSize: 10, color: _kSub)),
                _InlineStepBtn(
                  icon: Icons.add,
                  enabled: !_confirmingWrongPartial && _wrongPartialDraft < maxWrong,
                  color: borderColor,
                  onTap: () => setState(() {
                    _wrongPartialDraft = (_wrongPartialDraft + 1).clamp(1, maxWrong);
                    _wrongPartialQtyCtrl.text = '$_wrongPartialDraft';
                  }),
                ),
              ],
            ),
          ),
        ),
        // RIGHT half: confirm button
        Expanded(
          child: GestureDetector(
            onTap: _confirmingWrongPartial ? null : _doWrongPartial,
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: _confirmingWrongPartial
                    ? _kPartialFg.withValues(alpha: 0.45)
                    : _kPartialFg,
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(11),
                  bottomRight: Radius.circular(11),
                ),
                border: Border(
                  top: BorderSide(color: _kPartialFg.withValues(alpha: 0.4)),
                  bottom: BorderSide(color: _kPartialFg.withValues(alpha: 0.4)),
                  right: BorderSide(color: _kPartialFg.withValues(alpha: 0.4)),
                ),
              ),
              child: _confirmingWrongPartial
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : Text(confirmLabel,
                      style: const TextStyle(fontSize: 11,
                          fontWeight: FontWeight.w700, color: Colors.white),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
      ]),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final sheetState  = _deriveState();
    final dispute     = _dispute;
    final disputeStatus = dispute?['status']?.toString() ?? '';
    final disputeToken  = dispute?['token']?.toString() ?? '';
    final canonicalLink = dispute?['canonical_link']?.toString() ?? '';
    final copyLink = canonicalLink.isNotEmpty
        ? canonicalLink
        : (disputeToken.isNotEmpty ? 'https://medibo.in/dispute?token=$disputeToken' : '');
    final oiidPresent   = (_itemId ?? '').isNotEmpty;
    final bodyRows      = _bodyRowCount(sheetState, oiidPresent, disputeToken);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ───────────────────────────────────────────────────────
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _ImageTile(_imageUrl, size: 52),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_name,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700, color: _kText),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                  'Ordered: $_ordQty${_unit.isNotEmpty ? ' $_unit' : ''}',
                  style: const TextStyle(fontSize: 12, color: _kSub),
                ),
              ]),
            ),
            const SizedBox(width: 8),
            _StatusBadge(sheetState, _localFsState),
          ]),
          const SizedBox(height: 14),
          const Divider(height: 1, color: _kBorder),
          const SizedBox(height: 16),

          // ── C174 render-log instrumentation ──────────────────────────────
          Builder(builder: (_) {
            RenderLog.write('c174_item_sheet_states',
                'state=${sheetState.name};body_row_count=$bodyRows');
            RenderLog.write('c174_no_dead_reminder', 'true');
            return const SizedBox.shrink();
          }),

          // ── PENDING ───────────────────────────────────────────────────────
          if (sheetState == _ItemSheetState.pending) ...[
            // #193 sentinel: new v2 action set
            Builder(builder: (_) {
              RenderLog.write('c193_sheet_actions_v2',
                  'report_missing=true;few_item_wrong=true;old_short_gone=true');
              return const SizedBox.shrink();
            }),

            // Got all (N) — unchanged
            _ActionRow(
              label: 'Got all ($_ordQty)',
              color: _kGreen,
              icon: Icons.check_rounded,
              filled: true,
              loading: false,
              onTap: widget.recording ? null : () async {
                await _doRecord('received', qty: _ordQty);
                if (mounted) Navigator.of(context).pop();
              },
            ),
            const SizedBox(height: 8),

            // Report missing (renamed from "Short (enter count)") + inline expander
            if (!_showMissingInline)
              _ActionRow(
                label: 'Report missing',
                color: _kShortFg,
                icon: Icons.content_cut_rounded,
                filled: false,
                loading: false,
                onTap: () => setState(() {
                  _showMissingInline = true;
                  _showWrongPartialInline = false;
                  final safeOrd = _ordQty > 0 ? _ordQty : 1;
                  _missingDraft = _localRecQty.clamp(0, safeOrd);
                  _missingQtyCtrl.text = '$_missingDraft';
                  RenderLog.write('c193_missing_inline_opened',
                      'order_item_id=${_itemId ?? ''};default=$_missingDraft');
                }),
              )
            else
              _buildMissingInlineRow(),
            const SizedBox(height: 8),

            // Few item wrong (new) + inline expander
            if (!_showWrongPartialInline)
              _ActionRow(
                label: 'Few item wrong',
                color: _kPartialFg,
                icon: Icons.remove_circle_outline_rounded,
                filled: false,
                loading: false,
                onTap: () => setState(() {
                  _showWrongPartialInline = true;
                  _showMissingInline = false;
                  final maxW = _ordQty > 0 ? _ordQty : 1;
                  _wrongPartialDraft = 1.clamp(1, maxW);
                  _wrongPartialQtyCtrl.text = '$_wrongPartialDraft';
                  RenderLog.write('c193_wrong_inline_opened',
                      'order_item_id=${_itemId ?? ''};default=$_wrongPartialDraft');
                }),
              )
            else
              _buildWrongPartialInlineRow(),
            const SizedBox(height: 8),

            // Wrong item — unchanged (whole-item wrong, inline name capture)
            if (!_flaggingWrong) ...[
              _ActionRow(
                label: 'Wrong item',
                color: _kWrongFg,
                icon: Icons.close_rounded,
                filled: false,
                loading: false,
                onTap: widget.recording ? null : () => setState(() {
                  _flaggingWrong = true;
                  _wrongNameCtrl.clear();
                }),
              ),
            ] else ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF2F2),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFFECACA)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text('What did they send instead? (optional)',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                          color: _kWrongFg)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _wrongNameCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'e.g. Paracetamol 500mg instead',
                      hintStyle: TextStyle(fontSize: 13, color: _kSub),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      filled: true,
                      fillColor: Color(0xFFFFF8F8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(8)),
                        borderSide: BorderSide(color: Color(0xFFFECACA)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(8)),
                        borderSide: BorderSide(color: Color(0xFFFECACA)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(8)),
                        borderSide: BorderSide(color: _kWrongFg, width: 1.5),
                      ),
                    ),
                    style: const TextStyle(fontSize: 13),
                    textCapitalization: TextCapitalization.sentences,
                    onSubmitted: (_) => _flaggingWrongLoading ? null : _fw_flagWrongItem(),
                  ),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: SizedBox(
                        height: 40,
                        child: FilledButton(
                          onPressed: _flaggingWrongLoading ? null : _fw_flagWrongItem,
                          style: FilledButton.styleFrom(
                            backgroundColor: _kWrongFg,
                            disabledBackgroundColor:
                                _kWrongFg.withValues(alpha: 0.4),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                          child: _flaggingWrongLoading
                              ? const SizedBox(width: 14, height: 14,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2))
                              : const Text('Confirm',
                                  style: TextStyle(fontSize: 13,
                                      fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SizedBox(
                        height: 40,
                        child: OutlinedButton(
                          onPressed: _flaggingWrongLoading
                              ? null
                              : () => setState(() {
                                    _flaggingWrong = false;
                                    _wrongNameCtrl.clear();
                                  }),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _kSub,
                            side: const BorderSide(color: _kBorder),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                          child: const Text('Cancel',
                              style: TextStyle(fontSize: 13)),
                        ),
                      ),
                    ),
                  ]),
                ]),
              ),
            ],
            const SizedBox(height: 8),

            // Not coming — unchanged
            _ActionRow(
              label: 'Not coming',
              color: _kNotComingFg,
              icon: Icons.block_outlined,
              filled: false,
              loading: false,
              onTap: widget.recording ? null : () async {
                await _doRecord('not_coming');
                if (mounted) Navigator.of(context).pop();
              },
            ),
          ]

          // ── RECEIVED FULL ─────────────────────────────────────────────────
          else if (sheetState == _ItemSheetState.receivedFull) ...[
            _StatusLine('Received $_localRecQty / $_ordQty', _kReceivedFg),
            const SizedBox(height: 12),
            _ActionRow(
              label: 'Reset to pending',
              color: _kSub,
              icon: Icons.undo_rounded,
              filled: false,
              loading: false,
              onTap: widget.recording ? null : () async {
                await _doRecord('pending');
                if (mounted) Navigator.of(context).pop();
              },
            ),
            Builder(builder: (_) {
              RenderLog.write('c163_arrivals_sheet_rows', '$bodyRows');
              return const SizedBox.shrink();
            }),
          ]

          // ── SHORTFALL ─────────────────────────────────────────────────────
          else if (sheetState == _ItemSheetState.shortfall) ...[
            _StatusLine(
              'Received $_localRecQty / $_ordQty — $_shortQty short',
              _kShortFg,
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7ED),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFCD34D)),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.info_outline_rounded,
                    size: 15, color: Color(0xFFD97706)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Short by $_shortQty. Use \'Send short reminder\' on this supplier to notify.',
                    style: const TextStyle(fontSize: 13, color: Color(0xFF92400E)),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 8),
            _ActionRow(
              label: 'Reset to pending',
              color: _kSub,
              icon: Icons.undo_rounded,
              filled: false,
              loading: false,
              onTap: widget.recording ? null : () async {
                await _doRecord('pending');
                if (mounted) Navigator.of(context).pop();
              },
            ),
            Builder(builder: (_) {
              RenderLog.write('c163_arrivals_sheet_rows', '$bodyRows');
              return const SizedBox.shrink();
            }),
          ]

          // ── DISPUTE ACTIVE ────────────────────────────────────────────────
          else if (sheetState == _ItemSheetState.disputeActive) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F3FF),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _kPurpleBorder),
              ),
              child: Text(
                disputeStatus == 'reminder_sent'
                    ? 'Reminder sent to supplier — awaiting reply'
                    : disputeStatus == 'shop_logged'
                        ? 'Flagged — send supplier reminder to notify them'
                        : disputeStatus == 'accepted_missing'
                            ? 'Supplier accepted — awaiting missing stock'
                            : disputeStatus == 'denied'
                                ? 'Supplier denied — re-sourcing + flagged disputed'
                                : 'Dispute: $disputeStatus',
                style: const TextStyle(fontSize: 13, color: _kPurple),
              ),
            ),
            if (copyLink.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF9FAFB),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: _kBorder),
                    ),
                    child: Text(
                      copyLink,
                      style: const TextStyle(fontSize: 11, color: _kSub),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy_rounded, size: 16, color: _kPurple),
                  tooltip: 'Copy link',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: copyLink));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Link copied'),
                          duration: Duration(seconds: 2)));
                  },
                ),
              ]),
            ],
            const SizedBox(height: 10),
            _ActionRow(
              label: 'View dispute',
              color: _kPurple,
              icon: Icons.open_in_new_rounded,
              filled: true,
              loading: false,
              onTap: () {
                Navigator.of(context).pop();
                widget.onViewDispute();
              },
            ),
            if (disputeStatus == 'accepted_missing') ...[
              const SizedBox(height: 8),
              _ActionRow(
                label: 'Mark received (stock arrived)',
                color: _kGreen,
                icon: Icons.check_rounded,
                filled: true,
                loading: false,
                onTap: widget.recording ? null : () async {
                  await _doRecord('received', qty: _ordQty);
                  if (mounted) Navigator.of(context).pop();
                },
              ),
            ],
            Builder(builder: (_) {
              RenderLog.write('c163_arrivals_sheet_rows', '$bodyRows');
              return const SizedBox.shrink();
            }),
          ]

          // ── DISPUTE RESOLVED ──────────────────────────────────────────────
          else if (sheetState == _ItemSheetState.disputeResolved) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _kBorder),
              ),
              child: Row(children: [
                const Icon(Icons.check_circle_outline_rounded,
                    size: 16, color: _kSub),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Dispute resolved — no further action needed.',
                      style: TextStyle(fontSize: 13, color: _kSub)),
                ),
              ]),
            ),
          ]

          // ── WRONG / NOT_COMING ────────────────────────────────────────────
          else if (sheetState == _ItemSheetState.wrongItem ||
                   sheetState == _ItemSheetState.notComing) ...[
            _StatusLine(
              sheetState == _ItemSheetState.wrongItem ? 'Wrong item' : 'Not coming',
              sheetState == _ItemSheetState.wrongItem ? _kWrongFg : _kNotComingFg,
            ),
            const SizedBox(height: 12),
            _ActionRow(
              label: 'Reset to pending',
              color: _kSub,
              icon: Icons.undo_rounded,
              filled: false,
              loading: false,
              onTap: widget.recording ? null : () async {
                await _doRecord('pending');
                if (mounted) Navigator.of(context).pop();
              },
            ),
            Builder(builder: (_) {
              RenderLog.write('c163_arrivals_sheet_rows', '$bodyRows');
              return const SizedBox.shrink();
            }),
          ]

          // ── FALLBACK ──────────────────────────────────────────────────────
          else ...[
            _StatusLine('Status: $_localFsState', _kSub),
            const SizedBox(height: 8),
            Text(
              'received: $_localRecQty / $_ordQty  locked: ${widget.item['received_locked']}',
              style: const TextStyle(fontSize: 12, color: _kSub),
            ),
            const SizedBox(height: 12),
            _ActionRow(
              label: 'Close',
              color: _kSub,
              icon: Icons.close_rounded,
              filled: false,
              loading: false,
              onTap: () => Navigator.of(context).pop(),
            ),
            Builder(builder: (_) {
              RenderLog.write('c163_fallback_rendered',
                  'status=$_localFsState;received_qty=$_localRecQty;ordered=$_ordQty;received_locked=${widget.item['received_locked']}');
              RenderLog.write('c163_arrivals_sheet_rows', '$bodyRows');
              return const SizedBox.shrink();
            }),
          ],
        ],
      ),
    );
  }

  int _bodyRowCount(_ItemSheetState state, bool oiidPresent, String token) {
    switch (state) {
      case _ItemSheetState.pending:
        return 5; // Got all / Report missing / Few item wrong / Wrong / Not coming
      case _ItemSheetState.receivedFull:  return 2;
      case _ItemSheetState.shortfall:     return 2;
      case _ItemSheetState.disputeActive: return token.isNotEmpty ? 3 : 2;
      case _ItemSheetState.disputeResolved: return 1;
      case _ItemSheetState.wrongItem:
      case _ItemSheetState.notComing:     return 2;
      case _ItemSheetState.fallback:      return 2;
    }
  }
}

// ── Private helper widgets ────────────────────────────────────────────────────

class _ImageTile extends StatelessWidget {
  final String? imageUrl;
  final double size;
  const _ImageTile(this.imageUrl, {this.size = 52});

  @override
  Widget build(BuildContext context) {
    if (imageUrl == null || imageUrl!.isEmpty) {
      return Container(
        width: size, height: size,
        decoration: BoxDecoration(
            color: const Color(0xFFF3F4F6),
            borderRadius: BorderRadius.circular(8)),
        child: const Icon(Icons.medication_outlined,
            size: 24, color: Color(0xFFD1D5DB)),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        imageUrl!, width: size, height: size, fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: size, height: size, color: const Color(0xFFF3F4F6),
          child: const Icon(Icons.medication_outlined,
              size: 24, color: Color(0xFFD1D5DB)),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final _ItemSheetState sheetState;
  final String fsState;
  const _StatusBadge(this.sheetState, this.fsState);

  @override
  Widget build(BuildContext context) {
    Color bg; Color fg; String label;
    switch (sheetState) {
      case _ItemSheetState.receivedFull:
        bg = const Color(0xFFD1FAE5); fg = _kReceivedFg; label = 'received'; break;
      case _ItemSheetState.shortfall:
        bg = const Color(0xFFFAECE7); fg = _kShortFg; label = 'short'; break;
      case _ItemSheetState.disputeActive:
        bg = _kPurpleBg; fg = _kPurple; label = 'dispute'; break;
      case _ItemSheetState.disputeResolved:
        bg = const Color(0xFFF3F4F6); fg = _kSub; label = 'resolved'; break;
      case _ItemSheetState.wrongItem:
        bg = const Color(0xFFFEE2E2); fg = _kWrongFg; label = 'wrong'; break;
      case _ItemSheetState.notComing:
        bg = const Color(0xFFEFEEE9); fg = _kNotComingFg; label = 'not coming'; break;
      case _ItemSheetState.fallback:
        bg = const Color(0xFFF3F4F6); fg = _kSub; label = fsState; break;
      default:
        bg = const Color(0xFFFEF3C7); fg = const Color(0xFF92400E); label = 'pending';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
    );
  }
}

class _StatusLine extends StatelessWidget {
  final String text;
  final Color color;
  const _StatusLine(this.text, this.color);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color),
      );
}

/// Full-width vertical action row: icon + label, ~52px height, rounded 12px.
class _ActionRow extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;
  final bool filled;
  final bool loading;
  final VoidCallback? onTap;

  const _ActionRow({
    required this.label,
    required this.color,
    required this.icon,
    required this.filled,
    required this.loading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !loading;
    final bg     = filled ? (enabled ? color : color.withValues(alpha: 0.4))
                          : (enabled ? color.withValues(alpha: 0.06) : _kBg);
    final fgColor = filled ? Colors.white
                           : (enabled ? color : _kSub);
    final border  = filled ? Colors.transparent
                           : (enabled ? color.withValues(alpha: 0.35) : _kBorder);

    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        width: double.infinity,
        height: 52,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: border),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          if (loading)
            SizedBox(
              width: 18, height: 18,
              child: CircularProgressIndicator(
                  color: filled ? Colors.white : color, strokeWidth: 2),
            )
          else
            Icon(icon, size: 17, color: fgColor),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: fgColor,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
      ),
    );
  }
}

/// Compact tap target for inline stepper [-] / [+] buttons.
class _InlineStepBtn extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final Color color;
  final VoidCallback onTap;
  const _InlineStepBtn({
    required this.icon,
    required this.enabled,
    required this.color,
    required this.onTap,
  });

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
