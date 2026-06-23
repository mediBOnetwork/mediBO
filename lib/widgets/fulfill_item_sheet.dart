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
  wrongItem,
  notComing,
}

// ── Main entry points (called by _PickToLightScreenState) ─────────────────────

/// Show the unified item action sheet. On desktop (≥900px) uses Dialog; on
/// mobile uses ModalBottomSheet. Both render the same [FulfillItemSheet] body.
Future<void> showFulfillItemSheet({
  required BuildContext context,
  required Map<String, dynamic> item,
  required String supplierName,
  required bool recording,
  required Map<String, dynamic>? existingDispute,
  required Future<void> Function(String state, {int? qty}) onRecord,
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

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    backgroundColor: _kCard,
    builder: (ctx) {
      final mq = MediaQuery.of(ctx);
      final maxH = mq.size.height * 0.90;
      final bottomPad = mq.viewInsets.bottom + mq.viewPadding.bottom;
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(bottom: bottomPad),
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
  final Future<void> Function(String state, {int? qty}) onRecord;
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
  // Local state — updated in-place without closing the popup
  late String _localFsState;
  late int _localRecQty;
  late Map<String, dynamic>? _dispute;

  bool _showStepper = false;
  late int _shortDraft;
  bool _confirmingShort = false;
  bool _reminderSending = false;
  String? _reminderError;

  @override
  void initState() {
    super.initState();
    _localFsState = widget.item['fulfillment_state']?.toString() ?? 'pending';
    final ordQty = _ordQty;
    _localRecQty = (widget.item['received_qty'] as num?)?.toInt() ?? 0;
    _shortDraft = _localRecQty.clamp(1, ordQty.clamp(1, ordQty));
    _dispute = widget.existingDispute;
    _logOpen();
  }

  @override
  void didUpdateWidget(FulfillItemSheet old) {
    super.didUpdateWidget(old);
    // Sync dispute if parent pushes a new one in
    if (widget.existingDispute != null && _dispute == null) {
      _dispute = widget.existingDispute;
    }
  }

  void _logOpen() {
    final itemId = widget.item['order_item_id']?.toString() ?? '';
    final state = _deriveState().name;
    RenderLog.write('c162_sheet_opened', 'state=$state;order_item_id=$itemId');
    RenderLog.write('c162_state_rendered', state);
  }

  // ── Derived properties ─────────────────────────────────────────────────────

  int get _ordQty => (widget.item['ordered_qty'] as num?)?.toInt() ?? 0;
  String get _name => widget.item['product_name']?.toString() ?? '—';
  String get _unit => widget.item['pack_type']?.toString() ?? '';
  String? get _imageUrl => widget.item['image_url']?.toString();
  String? get _itemId => widget.item['order_item_id']?.toString();

  int get _shortQty => _ordQty - _localRecQty;

  _ItemSheetState _deriveState() {
    if (_dispute != null) {
      final dStatus = _dispute!['status']?.toString() ?? '';
      if (dStatus == 'reminder_sent' || dStatus == 'responded' ||
          dStatus == 'accepted_missing' || dStatus == 'denied') {
        return _ItemSheetState.disputeActive;
      }
    }
    switch (_localFsState) {
      case 'received':  return _ItemSheetState.receivedFull;
      case 'short':     return _ItemSheetState.shortfall;
      case 'wrong':     return _ItemSheetState.wrongItem;
      case 'not_coming': return _ItemSheetState.notComing;
      default:          return _ItemSheetState.pending;
    }
  }

  // ── Backend calls ──────────────────────────────────────────────────────────

  Future<void> _doRecord(String state, {int? qty}) async {
    await widget.onRecord(state, qty: qty);
    if (!mounted) return;
    setState(() {
      _localFsState = state;
      if (qty != null) _localRecQty = qty;
      if (state == 'short' && qty != null) {
        _shortDraft = qty;
        _showStepper = false;
      }
    });
    RenderLog.write('c162_state_rendered', _deriveState().name);
  }

  Future<void> _sendReminder() async {
    final id = _itemId;
    if (id == null) return;
    setState(() { _reminderSending = true; _reminderError = null; });
    try {
      final res = await Supabase.instance.client
          .rpc('fw_send_missing_reminder', params: {'p_order_item_id': id});
      if (!mounted) return;
      final resMap = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      if (resMap['status'] == 'ok') {
        final newDispute = <String, dynamic>{
          'dispute_id':    resMap['dispute_id']?.toString() ?? '',
          'token':         resMap['token']?.toString() ?? '',
          'status':        'reminder_sent',
          'order_item_id': id,
          'product_name':  _name,
          'short_qty':     resMap['short_qty'],
        };
        setState(() {
          _dispute = newDispute;
          _reminderSending = false;
        });
        widget.onDisputeCreated(id, newDispute);
        RenderLog.write('c162_reminder_sent',
            'order_item_id=$id;dispute_id=${newDispute['dispute_id']};short_qty=${resMap['short_qty']}');
        RenderLog.write('c162_state_rendered', _deriveState().name);
      } else {
        final errMsg = resMap['error']?.toString() ?? 'Unknown error';
        setState(() { _reminderError = errMsg; _reminderSending = false; });
        RenderLog.write('c162_reminder_error', 'message=$errMsg');
      }
    } catch (e) {
      if (!mounted) return;
      final errMsg = e.toString();
      setState(() { _reminderError = errMsg; _reminderSending = false; });
      RenderLog.write('c162_reminder_error', 'message=${errMsg.substring(0, errMsg.length.clamp(0, 100))}');
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final sheetState = _deriveState();
    final dispute = _dispute;
    final disputeStatus = dispute?['status']?.toString() ?? '';
    final disputeToken  = dispute?['token']?.toString() ?? '';
    final disputeId     = dispute?['dispute_id']?.toString() ?? '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ────────────────────────────────────────────────────────
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

          // ── Body — one state per vertical stack ────────────────────────────

          if (sheetState == _ItemSheetState.pending) ...[
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
            _ActionRow(
              label: 'Short${_unit.isNotEmpty ? ' (enter count)' : ''}',
              color: _kShortFg,
              icon: Icons.content_cut_rounded,
              filled: false,
              loading: false,
              onTap: () => setState(() {
                _showStepper = !_showStepper;
                if (_showStepper) {
                  _shortDraft = (_ordQty - 1).clamp(1, _ordQty);
                }
              }),
            ),
            if (_showStepper) ...[
              const SizedBox(height: 12),
              _StepperBlock(
                value: _shortDraft,
                max: _ordQty,
                confirming: _confirmingShort,
                onChanged: (v) => setState(() => _shortDraft = v),
                onConfirm: widget.recording ? null : () async {
                  setState(() => _confirmingShort = true);
                  await _doRecord('short', qty: _shortDraft);
                  if (mounted) setState(() => _confirmingShort = false);
                  // Popup stays open — now shows SHORTFALL state
                },
              ),
            ],
            const SizedBox(height: 8),
            _ActionRow(
              label: 'Wrong item',
              color: _kWrongFg,
              icon: Icons.close_rounded,
              filled: false,
              loading: false,
              onTap: widget.recording ? null : () async {
                await _doRecord('wrong');
                if (mounted) Navigator.of(context).pop();
              },
            ),
            const SizedBox(height: 8),
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

          else if (sheetState == _ItemSheetState.shortfall) ...[
            _StatusLine(
              'Received $_localRecQty / $_ordQty — $_shortQty short',
              _kShortFg,
            ),
            const SizedBox(height: 12),
            if (_itemId != null) ...[
              if (_reminderError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('Error: $_reminderError',
                      style: const TextStyle(fontSize: 12, color: _kWrongFg)),
                ),
              _ActionRow(
                label: _reminderSending
                    ? 'Sending…'
                    : 'Send reminder to supplier (missing $_shortQty${_unit.isNotEmpty ? ' $_unit' : ''})',
                color: _kPurple,
                icon: Icons.notifications_active_rounded,
                filled: true,
                loading: _reminderSending,
                onTap: _reminderSending ? null : _sendReminder,
              ),
              const SizedBox(height: 8),
            ],
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
          ]

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
          ]

          else if (sheetState == _ItemSheetState.disputeActive) ...[
            // Dispute status banner
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
                    : disputeStatus == 'accepted_missing'
                        ? 'Supplier accepted — awaiting missing stock'
                        : disputeStatus == 'denied'
                            ? 'Supplier denied — re-sourcing + flagged disputed'
                            : disputeStatus == 'responded'
                                ? 'Supplier has responded'
                                : 'Dispute: $disputeStatus',
                style: const TextStyle(fontSize: 13, color: _kPurple),
              ),
            ),
            // Dispute link
            if (disputeToken.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF9FAFB),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: _kBorder),
                    ),
                    child: Text(
                      'https://www.medibo.in/dispute?token=$disputeToken',
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
                    Clipboard.setData(ClipboardData(
                        text:
                            'https://www.medibo.in/dispute?token=$disputeToken'));
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
          ]

          else ...[
            // wrong / not_coming
            _StatusLine(
              _localFsState == 'wrong' ? 'Wrong item' : 'Not coming',
              _localFsState == 'wrong' ? _kWrongFg : _kNotComingFg,
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
          ],
        ],
      ),
    );
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
      case _ItemSheetState.wrongItem:
        bg = const Color(0xFFFEE2E2); fg = _kWrongFg; label = 'wrong'; break;
      case _ItemSheetState.notComing:
        bg = const Color(0xFFEFEEE9); fg = _kNotComingFg; label = 'not coming'; break;
      default:
        bg = const Color(0xFFFEF3C7); fg = const Color(0xFF92400E); label = 'pending';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
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
        style: TextStyle(
            fontSize: 14, fontWeight: FontWeight.w600, color: color),
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

/// Inline stepper with Confirm button (separate from immediate-record).
class _StepperBlock extends StatelessWidget {
  final int value;
  final int max;
  final bool confirming;
  final ValueChanged<int> onChanged;
  final VoidCallback? onConfirm;

  const _StepperBlock({
    required this.value,
    required this.max,
    required this.confirming,
    required this.onChanged,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _kBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _kBorder),
      ),
      child: Column(children: [
        const Text('How many received?',
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600, color: _kText)),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _StepBtn(Icons.remove, value > 0 ? () => onChanged(value - 1) : null),
          const SizedBox(width: 4),
          Container(
            width: 48, height: 36, alignment: Alignment.center,
            decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: _kBorder),
                borderRadius: BorderRadius.circular(6)),
            child: Text('$value',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700, color: _kText)),
          ),
          const SizedBox(width: 4),
          _StepBtn(Icons.add, value < max ? () => onChanged(value + 1) : null),
        ]),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: onConfirm,
            style: FilledButton.styleFrom(
              backgroundColor: _kShortFg,
              disabledBackgroundColor: const Color(0xFFEFCFC7),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(vertical: 10),
            ),
            child: confirming
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : const Text('Confirm short count',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
    );
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
        width: 36, height: 36,
        decoration: BoxDecoration(
          color: onTap != null ? _kCard : _kBg,
          border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon,
            size: 18,
            color: onTap != null ? _kText : _kSub),
      ),
    );
  }
}
