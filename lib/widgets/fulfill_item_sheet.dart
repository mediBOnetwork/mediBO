// ignore_for_file: avoid_web_libraries_in_flutter
import 'package:file_picker/file_picker.dart';
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
  // CHANGE #276 — Warehouse hides got-all/mark-received; all counting via voice+bag only
  bool arrivals = false,
  // CHANGE #277 — active bag_no for dynamic Got all visibility
  int? activeBagNo,
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
              arrivals: arrivals,
              activeBagNo: activeBagNo,
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
              arrivals: arrivals,
              activeBagNo: activeBagNo,
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
  // CHANGE #276 — Warehouse mode: hide got-all/mark-received; count via voice+bag only
  final bool arrivals;
  // CHANGE #277 — active bag_no; null = no bag or Collect mode
  final int? activeBagNo;

  const FulfillItemSheet({
    super.key,
    required this.item,
    required this.supplierName,
    required this.recording,
    required this.existingDispute,
    required this.onRecord,
    required this.onDisputeCreated,
    required this.onViewDispute,
    this.arrivals = false,
    this.activeBagNo,
  });

  @override
  State<FulfillItemSheet> createState() => _FulfillItemSheetState();
}

class _FulfillItemSheetState extends State<FulfillItemSheet> {
  late String _localFsState;
  late int _localRecQty;
  late Map<String, dynamic>? _dispute;

  // CHANGE #277: Got all loading state
  bool _gotAllLoading = false;

  // #193: Report missing inline (unchanged)
  bool _showMissingInline = false;
  late int _missingDraft;
  bool _confirmingMissing = false;
  final TextEditingController _missingQtyCtrl = TextEditingController();

  // #194: Few item wrong — dropdown panel (replaces #193 two-half)
  bool _showFewWrongPanel = false;
  late int _fewWrongCountedDraft;       // counted correct qty; clamped to [0, ordered-1]
  bool _fewWrongConfirming = false;
  String? _fewWrongProofUrl;
  bool _fewWrongUploading = false;
  String? _fewWrongUploadError;
  final TextEditingController _fewWrongCountedCtrl = TextEditingController();
  final TextEditingController _fewWrongNameCtrl = TextEditingController();

  // C173/C194: wrong-item dialog
  bool _flaggingWrong = false;
  bool _flaggingWrongLoading = false;
  String? _wrongProofUrl;
  bool _wrongUploading = false;
  String? _wrongUploadError;
  final TextEditingController _wrongNameCtrl = TextEditingController();

  // C351: unified report-issue section
  String? _selectedIssue;   // 'wrong'|'few_wrong'|'damaged'|'excess'|'not_coming'
  int _issueQty = 1;
  bool _issueSaving = false;
  String? _issueProofUrl;
  bool _issueProofUploading = false;
  String? _issueUploadError;
  bool _initiallyLocked = false;
  bool _issueExpanded = false;
  final TextEditingController _issueNameCtrl = TextEditingController();

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
    _fewWrongCountedDraft = (ordQty > 1 ? ordQty - 1 : 0).clamp(0, safeOrd - 1 < 0 ? 0 : safeOrd - 1);

    // C347: preselect existing issue
    _initiallyLocked = widget.item['collect_locked'] == true || widget.item['received_locked'] == true;
    final existingIssue = widget.item['count_issue']?.toString();
    if (existingIssue != null && existingIssue.isNotEmpty && existingIssue != 'null') {
      _selectedIssue = existingIssue;
      _issueQty = (widget.item['issue_qty'] as num?)?.toInt() ?? 1;
      final savedName = widget.item['wrong_received_note']?.toString() ?? '';
      if (savedName.isNotEmpty) _issueNameCtrl.text = savedName;
      _issueProofUrl = widget.item['wrong_proof_url']?.toString();
    } else if (_localFsState == 'not_coming') {
      _selectedIssue = 'not_coming';
    }
    if (_selectedIssue != null) _issueExpanded = true;

    _dispute = widget.existingDispute;
    _logOpen();
  }

  @override
  void dispose() {
    _missingQtyCtrl.dispose();
    _fewWrongCountedCtrl.dispose();
    _fewWrongNameCtrl.dispose();
    _wrongNameCtrl.dispose();
    _issueNameCtrl.dispose();
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

  // #193: Confirm missing — unchanged
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

  // #194: Confirm few-wrong — calls fw_mark_few_wrong (deferred dispute)
  Future<void> _doFewWrongConfirm() async {
    if (_fewWrongConfirming) return;
    final id = _itemId;
    if (id == null || id.isEmpty) return;
    setState(() => _fewWrongConfirming = true);
    RenderLog.write('c194_fewwrong_confirmed',
        'item=$id;counted=$_fewWrongCountedDraft;hasProof=${_fewWrongProofUrl != null}');
    try {
      final name = _fewWrongNameCtrl.text.trim();
      final res = await Supabase.instance.client.rpc('fw_mark_few_wrong', params: {
        'p_order_item_id': id,
        'p_counted_qty': _fewWrongCountedDraft,
        'p_wrong_product_name': name.isNotEmpty ? name : null,
        'p_proof_url': _fewWrongProofUrl,
      }) as Map;
      if (!mounted) return;
      final err = res['error']?.toString();
      if (err != null) {
        setState(() => _fewWrongConfirming = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $err'), backgroundColor: const Color(0xFFDC2626)));
        return;
      }
      final wQty = (res['wrong_qty'] as num?)?.toInt()
          ?? ((_ordQty - _fewWrongCountedDraft).clamp(1, _ordQty));
      final unitLabel = _unit.isNotEmpty ? ' $_unit' : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved · $wQty$unitLabel flagged wrong')));
      setState(() { _fewWrongConfirming = false; _showFewWrongPanel = false; });
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _fewWrongConfirming = false);
      final msg = e.toString().substring(0, e.toString().length.clamp(0, 80));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $msg'), backgroundColor: const Color(0xFFDC2626)));
    }
  }

  // #194: Wrong item — calls fw_flag_wrong_item (immediate dispute, 3-arg with proof)
  Future<void> _fw_flagWrongItem() async {
    final id = _itemId;
    if (id == null || id.isEmpty) return;
    final wrongName = _wrongNameCtrl.text.trim();
    setState(() => _flaggingWrongLoading = true);
    RenderLog.write('c194_wrongitem_proof',
        'item=$id;proofAttached=${_wrongProofUrl != null}');
    try {
      final res = await Supabase.instance.client.rpc('fw_flag_wrong_item', params: {
        'p_order_item_id': id,
        'p_wrong_product_name': wrongName.isNotEmpty ? wrongName : null,
        'p_proof_url': _wrongProofUrl,
      }) as Map;
      if (!mounted) return;
      final err = res['error']?.toString();
      if (err != null) {
        setState(() => _flaggingWrongLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $err'), backgroundColor: const Color(0xFFDC2626)));
        return;
      }
      final disputeId = res['dispute_id']?.toString() ?? '';
      setState(() {
        _flaggingWrongLoading = false;
        _localFsState = 'wrong';
      });
      final newDispute = <String, dynamic>{
        'dispute_id': disputeId,
        'kind': 'wrong_item',
        'status': 'shop_logged',
        'order_item_id': id,
        'product_name': _name,
        'wrong_product_name': wrongName.isNotEmpty ? wrongName : null,
      };
      widget.onDisputeCreated(id, newDispute);
      RenderLog.write('c173_wrong_flagged', 'order_item_id=$id');
      RenderLog.write('c177_action',
          'action=wrong_item;rpc=fw_flag_wrong_item;ok=true');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Marked wrong item — include it when you send the supplier reminder'),
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
      RenderLog.write('c177_action',
          'action=wrong_item;rpc=fw_flag_wrong_item;ok=false');
    }
  }

  // ── C347: Unified set-line-issue ──────────────────────────────────────────

  Future<void> _doSetLineIssue({bool clear = false}) async {
    final id = _itemId;
    if (id == null || id.isEmpty) return;
    if (_issueSaving) return;
    setState(() => _issueSaving = true);
    try {
      if (clear) {
        final res = await Supabase.instance.client.rpc('fw_set_line_issue', params: {
          'p_order_item_id': id,
          'p_issue': 'clear',
        }) as Map;
        if (!mounted) return;
        final err = res['error']?.toString();
        if (err != null) {
          setState(() => _issueSaving = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $err'), backgroundColor: const Color(0xFFDC2626)));
          return;
        }
        RenderLog.write('c351_flag_cleared', 'ok=1');
        if (mounted) Navigator.of(context).pop();
        return;
      }
      final issue = _selectedIssue;
      if (issue == null) return;
      final qty = _issueQty;
      final name = _issueNameCtrl.text.trim();
      final proofUrl = _issueProofUrl;

      if (_initiallyLocked) {
        // B7: line is locked — raise typed dispute directly
        final kind = issue == 'wrong' ? 'wrong_item' : issue;
        final res = await Supabase.instance.client.rpc('fw_raise_typed_dispute', params: {
          'p_order_item_id': id,
          'p_kind': kind,
          if (qty > 0 && issue != 'wrong' && issue != 'not_coming') 'p_qty': qty,
          if (name.isNotEmpty) 'p_wrong_name': name,
          if (proofUrl != null) 'p_proof_url': proofUrl,
        }) as Map;
        if (!mounted) return;
        final err = res['error']?.toString();
        if (err != null) {
          setState(() => _issueSaving = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $err'), backgroundColor: const Color(0xFFDC2626)));
          return;
        }
        RenderLog.write('c351_typed', 'kind=$kind');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Dispute raised')));
        if (mounted) Navigator.of(context).pop();
        return;
      }

      final params = <String, dynamic>{
        'p_order_item_id': id,
        'p_issue': issue,
      };
      if ((issue == 'few_wrong' || issue == 'damaged' || issue == 'excess') && qty > 0) {
        params['p_qty'] = qty;
      }
      if (name.isNotEmpty && (issue == 'wrong' || issue == 'few_wrong')) {
        params['p_wrong_name'] = name;
      }
      if (proofUrl != null) params['p_proof_url'] = proofUrl;

      final res = await Supabase.instance.client.rpc('fw_set_line_issue', params: params) as Map;
      if (!mounted) return;
      final err = res['error']?.toString();
      if (err != null) {
        setState(() => _issueSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $err'), backgroundColor: const Color(0xFFDC2626)));
        return;
      }
      RenderLog.write('c351_flag_saved', 'issue=$issue,qty=$qty');
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _issueSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: const Color(0xFFDC2626)));
    }
  }

  // ── #194: Proof photo pick + upload helper ─────────────────────────────────

  Future<void> _pickAndUpload({
    required void Function(bool) setUploading,
    required void Function(String?) setError,
    required void Function(String) onUploaded,
  }) async {
    final id = _itemId;
    if (id == null || id.isEmpty) return;

    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        type: FileType.image,
        withData: true,
      );
    } catch (_) {
      return;
    }
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) return;

    RenderLog.write('c194_proof_picked', 'item=$id;name=${file.name}');

    final ext = file.name.split('.').last.toLowerCase();
    final mime = ext == 'png'  ? 'image/png'
               : ext == 'webp' ? 'image/webp'
               : 'image/jpeg';

    if (!mounted) return;
    setState(() {
      setUploading(true);
      setError(null);
    });

    try {
      final safeName =
          file.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final ts = DateTime.now().millisecondsSinceEpoch;
      final path = '$id/${ts}_$safeName';
      await Supabase.instance.client.storage
          .from('dispute-proofs')
          .uploadBinary(path, bytes,
              fileOptions: FileOptions(upsert: true, contentType: mime));
      final publicUrl = Supabase.instance.client.storage
          .from('dispute-proofs')
          .getPublicUrl(path);
      if (!mounted) return;
      setState(() {
        setUploading(false);
        onUploaded(publicUrl);
      });
      RenderLog.write('c194_proof_uploaded', 'item=$id;path=$path');
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      setState(() {
        setUploading(false);
        setError(msg.substring(0, msg.length.clamp(0, 60)));
      });
    }
  }

  // ── #194: Proof full-screen viewer ─────────────────────────────────────────

  void _showProofFullscreen(BuildContext ctx, String url) {
    showDialog<void>(
      context: ctx,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(children: [
          SizedBox.expand(
            child: InteractiveViewer(
              child: Image.network(
                url,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Center(
                  child: Icon(Icons.broken_image_outlined,
                      color: Colors.white, size: 48),
                ),
              ),
            ),
          ),
          Positioned(
            top: 8, right: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ),
        ]),
      ),
    );
  }

  // ── #194: Proof attach control ─────────────────────────────────────────────

  Widget _buildProofAttach({
    required String? proofUrl,
    required bool uploading,
    required String? uploadError,
    required VoidCallback? onPick,
    required VoidCallback? onRemove,
  }) {
    if (uploading) {
      return const Row(children: [
        SizedBox(
          width: 16, height: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: _kPartialFg),
        ),
        SizedBox(width: 8),
        Text('Uploading...', style: TextStyle(fontSize: 13, color: _kSub)),
      ]);
    }
    if (proofUrl != null && proofUrl.isNotEmpty) {
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Builder(builder: (ctx) {
          RenderLog.write('c194_proof_preview_shown',
              'url=${proofUrl.length > 60 ? proofUrl.substring(0, 60) : proofUrl}');
          return GestureDetector(
            onTap: () => _showProofFullscreen(ctx, proofUrl),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.network(
                proofUrl, width: 72, height: 72, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  width: 72, height: 72, color: const Color(0xFFF3F4F6),
                  child: const Icon(Icons.broken_image_outlined, color: _kSub),
                ),
              ),
            ),
          );
        }),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Photo attached',
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600, color: _kText)),
              const SizedBox(height: 2),
              const Text('Tap to zoom',
                  style: TextStyle(fontSize: 11, color: _kSub)),
              const SizedBox(height: 4),
              GestureDetector(
                onTap: onRemove,
                child: const Text('Remove',
                    style: TextStyle(fontSize: 12, color: Color(0xFFDC2626))),
              ),
            ],
          ),
        ),
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          onPressed: onPick,
          icon: const Icon(Icons.add_a_photo_outlined, size: 16),
          label: const Text('Add photo',
              style: TextStyle(fontSize: 13)),
          style: OutlinedButton.styleFrom(
            foregroundColor: _kSub,
            side: const BorderSide(color: _kBorder),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        if (uploadError != null) ...[
          const SizedBox(height: 4),
          Text('Upload failed: $uploadError',
              style: const TextStyle(fontSize: 11, color: Color(0xFFDC2626))),
        ],
      ],
    );
  }

  // ── #193: Inline two-half row — Report missing (unchanged) ───────────────

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

  // ── #194: Few item wrong dropdown panel ───────────────────────────────────

  Widget _buildFewWrongPanel() {
    final ordQty = _ordQty;
    final maxCounted = ordQty > 1 ? ordQty - 1 : 0;  // at least 1 wrong → counted ≤ ordered-1
    final wrongQty = (ordQty - _fewWrongCountedDraft).clamp(1, ordQty);
    final unitLabel = _unit.isNotEmpty ? ' $_unit' : '';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _kPartialFg.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _kPartialFg.withValues(alpha: 0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

        // (a) Counted-qty stepper + live "Wrong: N unit" derivation
        Row(children: [
          const Text('Counted:',
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: _kText)),
          const SizedBox(width: 6),
          _InlineStepBtn(
            icon: Icons.remove,
            enabled: !_fewWrongConfirming && _fewWrongCountedDraft > 0,
            color: _kPartialFg,
            onTap: () => setState(() {
              _fewWrongCountedDraft =
                  (_fewWrongCountedDraft - 1).clamp(0, maxCounted);
              _fewWrongCountedCtrl.text = '$_fewWrongCountedDraft';
            }),
          ),
          SizedBox(
            width: 44,
            child: TextField(
              controller: _fewWrongCountedCtrl,
              enabled: !_fewWrongConfirming,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700, color: _kText),
              decoration: const InputDecoration.collapsed(hintText: '0'),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (v) {
                final n = int.tryParse(v) ?? 0;
                final clamped = n.clamp(0, maxCounted);
                setState(() => _fewWrongCountedDraft = clamped);
                if (v.isNotEmpty && v != '$clamped') {
                  _fewWrongCountedCtrl.value =
                      _fewWrongCountedCtrl.value.copyWith(
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
            enabled: !_fewWrongConfirming &&
                _fewWrongCountedDraft < maxCounted,
            color: _kPartialFg,
            onTap: () => setState(() {
              _fewWrongCountedDraft =
                  (_fewWrongCountedDraft + 1).clamp(0, maxCounted);
              _fewWrongCountedCtrl.text = '$_fewWrongCountedDraft';
            }),
          ),
          const Spacer(),
          Text('Wrong: $wrongQty$unitLabel',
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _kPartialFg)),
        ]),
        const SizedBox(height: 10),

        // (b) Wrong product name field
        TextField(
          controller: _fewWrongNameCtrl,
          enabled: !_fewWrongConfirming,
          decoration: InputDecoration(
            labelText: 'What did they send instead? (optional)',
            hintText: 'e.g. Paracetamol 500mg instead',
            hintStyle: const TextStyle(fontSize: 13, color: _kSub),
            labelStyle: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w500, color: _kSub),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(
                    color: _kPartialFg.withValues(alpha: 0.4))),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(
                    color: _kPartialFg.withValues(alpha: 0.4))),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide:
                    const BorderSide(color: _kPartialFg, width: 1.5)),
          ),
          style: const TextStyle(fontSize: 13),
          textCapitalization: TextCapitalization.sentences,
        ),
        const SizedBox(height: 10),

        // (c) Proof attach control
        const Text('Attach photo proof (optional)',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: _kSub)),
        const SizedBox(height: 6),
        _buildProofAttach(
          proofUrl: _fewWrongProofUrl,
          uploading: _fewWrongUploading,
          uploadError: _fewWrongUploadError,
          onPick: _fewWrongConfirming
              ? null
              : () => _pickAndUpload(
                    setUploading: (v) => _fewWrongUploading = v,
                    setError: (v) => _fewWrongUploadError = v,
                    onUploaded: (url) => _fewWrongProofUrl = url,
                  ),
          onRemove: _fewWrongConfirming
              ? null
              : () => setState(() {
                    _fewWrongProofUrl = null;
                    _fewWrongUploadError = null;
                  }),
        ),
        const SizedBox(height: 10),

        // (d) Confirm + Cancel
        Row(children: [
          Expanded(
            child: SizedBox(
              height: 40,
              child: FilledButton(
                onPressed: _fewWrongConfirming ? null : _doFewWrongConfirm,
                style: FilledButton.styleFrom(
                  backgroundColor: _kPartialFg,
                  disabledBackgroundColor:
                      _kPartialFg.withValues(alpha: 0.4),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                child: _fewWrongConfirming
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Text('Confirm',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              height: 40,
              child: OutlinedButton(
                onPressed: _fewWrongConfirming
                    ? null
                    : () => setState(() {
                          _showFewWrongPanel = false;
                          _fewWrongProofUrl = null;
                          _fewWrongUploadError = null;
                          _fewWrongNameCtrl.clear();
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

            // CHANGE #277: Got all — dynamic in Warehouse based on bag + itemCounted
            if (!widget.arrivals) ...[
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
            ] else if (widget.activeBagNo != null) ...[
              // Warehouse with active bag: show Got all only if item not yet counted into this bag
              Builder(builder: (_) {
                final bagNo = widget.activeBagNo!;
                final rawBd = widget.item['bag_breakdown'];
                final itemCounted = rawBd is List && (rawBd as List).any((b) {
                  final bm = b as Map;
                  return (bm['bag_no'] as num?)?.toInt() == bagNo &&
                      ((bm['qty'] as num?)?.toDouble() ?? 0.0) > 0;
                });
                if (itemCounted) {
                  RenderLog.write('c277_got_all_hidden', 'bag=$bagNo;item=${widget.item['product_name'] ?? ''}');
                  return const SizedBox.shrink();
                }
                RenderLog.write('c277_got_all_shown', 'bag=$bagNo;item=${widget.item['product_name'] ?? ''}');
                return Column(children: [
                  _ActionRow(
                    label: 'Got all ($_ordQty)',
                    color: _kGreen,
                    icon: Icons.check_rounded,
                    filled: true,
                    loading: _gotAllLoading,
                    onTap: (_gotAllLoading || widget.recording) ? null : () async {
                      setState(() => _gotAllLoading = true);
                      RenderLog.write('c277_got_all_action', 'bag=$bagNo;qty=$_ordQty;item=${widget.item['product_name'] ?? ''}');
                      try {
                        await _doRecord('received', qty: _ordQty);
                        if (mounted) Navigator.of(context).pop();
                      } catch (e) {
                        if (mounted) {
                          setState(() => _gotAllLoading = false);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(e.toString().substring(0, e.toString().length.clamp(0, 120)))),
                          );
                        }
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                ]);
              }),
            ] else ...[
              // Safety: no bag in Warehouse — should not happen (rows gated), show nothing
              Builder(builder: (_) {
                RenderLog.write('c276_no_getall_warehouse', 'arrivals_sheet_no_bag;item=${widget.item['product_name'] ?? ''}');
                return const SizedBox.shrink();
              }),
            ],

            // Report missing (#193 two-half, unchanged)
            if (!_showMissingInline)
              _ActionRow(
                label: 'Report missing',
                color: _kShortFg,
                icon: Icons.content_cut_rounded,
                filled: false,
                loading: false,
                onTap: () => setState(() {
                  _showMissingInline = true;
                  _showFewWrongPanel = false;
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

            // C351: unified 5-option report-issue section
            _buildReportIssueSection(),
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
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFF92400E)),
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
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
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
                  icon: const Icon(Icons.copy_rounded,
                      size: 16, color: _kPurple),
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
            // Mark received — hidden in Warehouse (arrivals); count via voice+bag only (#276)
            if (disputeStatus == 'accepted_missing' && !widget.arrivals) ...[
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
                  child: Text(
                      'Dispute resolved — no further action needed.',
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

  int _bodyRowCount(
      _ItemSheetState state, bool oiidPresent, String token) {
    switch (state) {
      case _ItemSheetState.pending:
        return 3; // Got all / Report missing / Report issue section
      case _ItemSheetState.receivedFull:   return 2;
      case _ItemSheetState.shortfall:      return 2;
      case _ItemSheetState.disputeActive:  return token.isNotEmpty ? 3 : 2;
      case _ItemSheetState.disputeResolved: return 1;
      case _ItemSheetState.wrongItem:
      case _ItemSheetState.notComing:      return 2;
      case _ItemSheetState.fallback:       return 2;
    }
  }

  // ── C351: Unified 5-option report-issue section ───────────────────────────

  static const _kIssueOptions = [
    ('wrong',      'Wrong item (whole line)',    Icons.swap_horiz_rounded),
    ('few_wrong',  'Few units wrong',            Icons.remove_circle_outline_rounded),
    ('damaged',    'Damaged / expired units',    Icons.broken_image_outlined),
    ('excess',     'Excess received',            Icons.add_circle_outline_rounded),
    ('not_coming', 'Not coming',                 Icons.block_outlined),
  ];

  Widget _buildReportIssueSection() {
    final hasExisting = _selectedIssue != null;
    const kAmber = Color(0xFFD97706);

    // ── Collapsed entry ────────────────────────────────────────────────────
    if (!_issueExpanded) {
      return _ActionRow(
        label: 'Report issue',
        color: kAmber,
        icon: Icons.flag_outlined,
        filled: false,
        loading: false,
        onTap: widget.recording ? null : () => setState(() {
          _issueExpanded = true;
          _issueQty = 1;
          _issueProofUrl = null;
          _issueUploadError = null;
        }),
      );
    }

    // ── Expanded section ───────────────────────────────────────────────────
    final ordQty = _ordQty;
    final recQty = _localRecQty;
    final maxQty = (ordQty - recQty).clamp(1, ordQty > 0 ? ordQty : 999);

    return Builder(builder: (ctx) {
      RenderLog.write('c351_section', 'n=5');
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFBEB),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFFCD34D)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Header row
          Row(children: [
            const Icon(Icons.flag_outlined, size: 15, color: kAmber),
            const SizedBox(width: 6),
            const Expanded(
              child: Text('Report issue',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: kAmber)),
            ),
            if (!hasExisting)
              GestureDetector(
                onTap: () => setState(() {
                  _issueExpanded = false;
                  _selectedIssue = null;
                }),
                child: const Icon(Icons.close, size: 18, color: _kSub),
              ),
          ]),

          // Clear issue (if existing flag)
          if (hasExisting) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _issueSaving ? null : () => _doSetLineIssue(clear: true),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEE2E2),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFFFCA5A5)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.close, size: 13, color: Color(0xFFDC2626)),
                  const SizedBox(width: 4),
                  Text(
                    _issueSaving ? 'Clearing…' : 'Clear issue',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFDC2626)),
                  ),
                ]),
              ),
            ),
          ],

          const SizedBox(height: 10),

          // 5 option buttons
          for (final (code, label, icon) in _kIssueOptions) ...[
            GestureDetector(
              onTap: () => setState(() {
                _selectedIssue = _selectedIssue == code ? null : code;
                if (_selectedIssue != null) {
                  _issueQty = 1;
                  _issueProofUrl = null;
                  _issueUploadError = null;
                  if (_selectedIssue != 'few_wrong' && _selectedIssue != 'wrong') {
                    _issueNameCtrl.clear();
                  }
                }
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                margin: const EdgeInsets.only(bottom: 4),
                decoration: BoxDecoration(
                  color: _selectedIssue == code
                      ? kAmber.withValues(alpha: 0.12)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _selectedIssue == code ? kAmber : _kBorder,
                    width: _selectedIssue == code ? 1.5 : 1.0,
                  ),
                ),
                child: Row(children: [
                  Icon(icon, size: 16,
                      color: _selectedIssue == code ? kAmber : _kSub),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(label,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: _selectedIssue == code
                                ? FontWeight.w700 : FontWeight.w500,
                            color: _selectedIssue == code ? kAmber : _kText)),
                  ),
                  if (_selectedIssue == code)
                    const Icon(Icons.check_circle_rounded,
                        size: 16, color: kAmber),
                ]),
              ),
            ),

            // Conditional inputs for selected option
            if (_selectedIssue == code) ...[
              const SizedBox(height: 4),
              _buildIssueInputs(code, ordQty, maxQty),
              const SizedBox(height: 8),
            ],
          ],

          // Save button
          if (_selectedIssue != null) ...[
            const SizedBox(height: 4),
            Builder(builder: (_) {
              final canSave = _issueCanSave();
              return SizedBox(
                height: 44,
                child: FilledButton(
                  onPressed: (_issueSaving || !canSave) ? null : () => _doSetLineIssue(),
                  style: FilledButton.styleFrom(
                    backgroundColor: kAmber,
                    disabledBackgroundColor: kAmber.withValues(alpha: 0.4),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: _issueSaving
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : Text(
                          _initiallyLocked ? 'Save (raises dispute)' : 'Save issue',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                ),
              );
            }),
          ],
        ]),
      );
    });
  }

  bool _issueCanSave() {
    final issue = _selectedIssue;
    if (issue == null) return false;
    if (issue == 'few_wrong') {
      return _issueQty >= 1 && _issueNameCtrl.text.trim().isNotEmpty;
    }
    return true;
  }

  Widget _buildIssueInputs(String code, int ordQty, int maxQty) {
    const kAmber = Color(0xFFD97706);
    final unit = _unit.isNotEmpty ? ' $_unit' : '';

    if (code == 'not_coming') {
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
        child: Text(
          'Item will leave the counting list.',
          style: const TextStyle(fontSize: 12, color: _kSub),
        ),
      );
    }

    // Stepper needed for few_wrong, damaged, excess
    final needsStepper = code == 'few_wrong' || code == 'damaged' || code == 'excess';
    // Name field needed for few_wrong (required) and wrong (optional)
    final needsName = code == 'few_wrong' || code == 'wrong';
    final nameRequired = code == 'few_wrong';
    // Photo always optional
    final stepperLabel = code == 'few_wrong' ? 'Wrong units'
                       : code == 'damaged'   ? 'Damaged units'
                       : 'Excess units';
    final stepperMax = code == 'excess' ? 999 : maxQty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (needsStepper) ...[
          Row(children: [
            Text('$stepperLabel (max $stepperMax):',
                style: const TextStyle(fontSize: 12, color: _kSub)),
            const SizedBox(width: 8),
            _InlineStepBtn(
              icon: Icons.remove,
              enabled: _issueQty > 1,
              color: kAmber,
              onTap: () => setState(() => _issueQty = (_issueQty - 1).clamp(1, stepperMax)),
            ),
            Container(
              width: 36,
              alignment: Alignment.center,
              child: Text('$_issueQty',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kText)),
            ),
            _InlineStepBtn(
              icon: Icons.add,
              enabled: _issueQty < stepperMax,
              color: kAmber,
              onTap: () => setState(() => _issueQty = (_issueQty + 1).clamp(1, stepperMax)),
            ),
          ]),
          const SizedBox(height: 8),
        ],
        if (needsName) ...[
          TextField(
            controller: _issueNameCtrl,
            decoration: InputDecoration(
              hintText: nameRequired
                  ? 'What item did they send? (required)'
                  : 'What item did they send? (optional)',
              hintStyle: const TextStyle(fontSize: 12, color: _kSub),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: _kBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: _kBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: kAmber, width: 1.5),
              ),
            ),
            style: const TextStyle(fontSize: 13),
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
        ],
        // Photo (optional for all except not_coming)
        _buildProofAttach(
          proofUrl: _issueProofUrl,
          uploading: _issueProofUploading,
          uploadError: _issueUploadError,
          onPick: _issueSaving ? null : () => _pickAndUpload(
            setUploading: (v) => _issueProofUploading = v,
            setError: (v) => _issueUploadError = v,
            onUploaded: (url) => _issueProofUrl = url,
          ),
          onRemove: _issueSaving ? null : () => setState(() {
            _issueProofUrl = null;
            _issueUploadError = null;
          }),
        ),
      ]),
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
      case _ItemSheetState.disputeResolved:
        bg = const Color(0xFFF3F4F6); fg = _kSub; label = 'resolved'; break;
      case _ItemSheetState.wrongItem:
        bg = const Color(0xFFFEE2E2); fg = _kWrongFg; label = 'wrong'; break;
      case _ItemSheetState.notComing:
        bg = const Color(0xFFEFEEE9); fg = _kNotComingFg; label = 'not coming'; break;
      case _ItemSheetState.fallback:
        bg = const Color(0xFFF3F4F6); fg = _kSub; label = fsState; break;
      default:
        bg = const Color(0xFFFEF3C7);
        fg = const Color(0xFF92400E);
        label = 'pending';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(20)),
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

// ── Proof thumbnail widget — shared between dispute surfaces ──────────────────

/// Shows a tappable proof thumbnail. Opens a full-screen viewer on tap.
/// Emits c194_dispute_proof_rendered to render-log.
class ProofThumbnail extends StatelessWidget {
  final String proofUrl;
  final double size;
  const ProofThumbnail({super.key, required this.proofUrl, this.size = 72});

  @override
  Widget build(BuildContext context) {
    return Builder(builder: (ctx) {
      RenderLog.write('c194_dispute_proof_rendered',
          'url=${proofUrl.length > 60 ? proofUrl.substring(0, 60) : proofUrl}');
      return GestureDetector(
        onTap: () => showDialog<void>(
          context: ctx,
          builder: (_) => Dialog(
            backgroundColor: Colors.black,
            insetPadding: EdgeInsets.zero,
            child: Stack(children: [
              SizedBox.expand(
                child: InteractiveViewer(
                  child: Image.network(
                    proofUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Center(
                      child: Icon(Icons.broken_image_outlined,
                          color: Colors.white, size: 48),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 8, right: 8,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ]),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.network(
                proofUrl,
                width: size, height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  width: size, height: size,
                  color: const Color(0xFFF3F4F6),
                  child: const Icon(Icons.broken_image_outlined,
                      color: Color(0xFF6B7280)),
                ),
              ),
            ),
            const SizedBox(height: 3),
            const Text('Tap to zoom',
                style: TextStyle(fontSize: 10, color: Color(0xFF6B7280))),
          ],
        ),
      );
    });
  }
}
