import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/date_labels.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/live_feed.dart';

import '../../services/ui_copy.dart';
import '../../utils/bill_mime.dart';
import '../../utils/download_bytes.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import '../../widgets/bill_actions_row.dart' show BillActionButton;
import '../../widgets/bill_viewer.dart';
import '../../widgets/ds_tone.dart';
import '../../widgets/order_item_card.dart';
import '../../widgets/po_pricing.dart';
import '../../widgets/response_deadline.dart';
import '../../widgets/sup_pay_panel.dart';
import '../../widgets/supplier_po_ack.dart';

// CHANGE #671 gap 51: the private hex parser is gone — a backend-supplied
// "#RRGGBB" is read by Ds.hex, the same parser the token layer itself uses.

// ── Screen ────────────────────────────────────────────────────────────────────

/// CHANGE #464 gap 45 — the supplier order total, decided entirely by the
/// backend. `po_pricing_block` sends `payable_display` (already rupee-formatted
/// by `inr_money`) and `show_payable`; this class only carries them. The screen
/// used to interpolate the rupee sign and pick its own rounding branch off the
/// raw numeric, which put the rounding rule for a supplier's money in Flutter.
class SupplierOrderTotal {
  final bool show;
  final String display;
  const SupplierOrderTotal({required this.show, required this.display});

  static SupplierOrderTotal from(Map<String, dynamic>? pricing) {
    final display = (pricing?['payable_display'] as String?) ?? '';
    return SupplierOrderTotal(
      show: pricing?['show_payable'] == true && display.isNotEmpty,
      display: display,
    );
  }
}

class SupplierOrdersScreen extends StatefulWidget {
  final String? viewAsSupplierId;
  final String supplierName;

  const SupplierOrdersScreen({
    super.key,
    this.viewAsSupplierId,
    this.supplierName = 'Supplier',
  });

  @override
  State<SupplierOrdersScreen> createState() => _SupplierOrdersScreenState();
}

class _SupplierOrdersScreenState extends State<SupplierOrdersScreen> {
  List<Map<String, dynamic>> _orders = [];
  bool _loading = false;
  bool _firstLoad = true;
  String? _expandedOrderId;
  LiveFeedHandle? _rt;

  @override
  void initState() {
    super.initState();
    _fetch(source: 'init');
    _subscribeRealtime();
  }

  @override
  void dispose() {
    _rt?.unsubscribe();
    super.dispose();
  }

  void _subscribeRealtime() {
    // CHANGE #643: transport chosen by realtime_plan(); the refetch is the same.
    LiveFeed.instance
        .watch(
          channelPrefix: 'sup_orders_rt',
          tables: const ['supplier_orders'],
          onChange: (_) => _fetch(source: 'realtime', silent: true),
        )
        .then((h) {
      if (!mounted) {
        h.dispose();
        return;
      }
      _rt?.unsubscribe();
      _rt = h;
    });
  }

  Future<void> _fetch({String source = 'manual', bool silent = false}) async {
    if (!mounted) return;
    if (!silent) setState(() => _loading = true);
    try {
      final sid = widget.viewAsSupplierId;
      final params = sid != null
          ? <String, dynamic>{'p_supplier_id': sid}
          : <String, dynamic>{};
      final rows = await Supabase.instance.client
          .rpc('supplier_my_orders', params: params);
      if (!mounted) return;

      final list = (rows as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      String? newExpanded = _expandedOrderId;
      if (_firstLoad) {
        newExpanded = list.isNotEmpty ? (list.first['order_id'] as String?) : null;
      } else if (list.isNotEmpty) {
        final topId = list.first['order_id'] as String?;
        final existingIds = _orders.map((o) => o['order_id'] as String?).toSet();
        if (topId != null && !existingIds.contains(topId)) {
          newExpanded = topId;
        }
      }

      setState(() {
        _orders = list;
        _expandedOrderId = newExpanded;
        _firstLoad = false;
        _loading = false;
      });

      RenderLog.write('supplier_orders_rows', list.length);
      RenderLog.write('supplier_orders_src', source);
      if (list.isNotEmpty) {
        RenderLog.write('supplier_orders_first_no', list.first['order_no']?.toString() ?? '?');
      }
      if (newExpanded != null) RenderLog.write('supplier_orders_expanded', 'yes');
    } catch (e) {
      final msg = e.toString();
      RenderLog.write('supplier_orders_error', msg.length > 80 ? msg.substring(0, 80) : msg);
      if (mounted) setState(() { _loading = false; });
    }
  }

  void _toggleOrder(String orderId) {
    setState(() {
      _expandedOrderId = _expandedOrderId == orderId ? null : orderId;
    });
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('supplier_orders_screen_built', 1);

    return LayoutBuilder(builder: (context, constraints) {
      RenderLog.write('supplier_orders_vp_w', constraints.maxWidth.toInt());

      if (_loading && _firstLoad) {
        return Center(
          child: CircularProgressIndicator(color: Ds.c.brand),
        );
      }

      if (_orders.isEmpty && !_loading) {
        return Center(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.receipt_long_outlined, size: 56, color: Ds.c.divider),
            SizedBox(height: Ds.space.x12),
            Text(c('supplier_orders.empty'), style: Ds.t.bodySecondary),
          ]),
        );
      }

      return ListView.builder(
        padding: EdgeInsets.all(
            constraints.maxWidth >= 900 ? Ds.space.x24 : Ds.space.x12),
        itemCount: _orders.length,
        itemBuilder: (context, i) {
          final order = _orders[i];
          final orderId = order['order_id'] as String? ?? '';
          final isOpen = _expandedOrderId == orderId;
          return _OrderCard(
            order: order,
            supplierName: widget.supplierName,
            isOpen: isOpen,
            onToggle: () => _toggleOrder(orderId),
            onReload: () => _fetch(source: 'pack_toggle', silent: true),
          );
        },
      );
    });
  }
}

// ── Order card (collapsible, manages bill/payment panel state) ─────────────────

class _OrderCard extends StatefulWidget {
  final Map<String, dynamic> order;
  final String supplierName;
  final bool isOpen;
  final VoidCallback onToggle;
  final VoidCallback onReload;

  const _OrderCard({
    required this.order,
    required this.supplierName,
    required this.isOpen,
    required this.onToggle,
    required this.onReload,
  });

  @override
  State<_OrderCard> createState() => _OrderCardState();
}

class _OrderCardState extends State<_OrderCard> {
  bool _payOpen = false;
  bool _uploading = false;
  Map<String, dynamic>? _panelData;
  bool _panelLoading = false;
  String? _panelError;

  // CHANGE #471: supplier's own bill view/delete state — separate from the
  // payment panel above. Loaded eagerly (not lazily on tap) since has_file
  // gates whether the "View Bill" button even shows.
  Map<String, dynamic>? _billInfo;
  bool _billLoading = false;
  bool _billViewOpen = false;
  bool _deletingBill = false;
  bool _downloadingBill = false;
  bool _sharingBill = false;
  bool _togglingPacked = false;

  String get _orderId => widget.order['order_id'] as String? ?? '';

  @override
  void initState() {
    super.initState();
    _loadBillInfo();
  }

  Future<void> _loadBillInfo({bool refresh = false}) async {
    if (_billLoading) return;
    if (_billInfo != null && !refresh) return;
    if (!mounted) return;
    setState(() => _billLoading = true);
    try {
      final result = await Supabase.instance.client
          .rpc('sup_bill_file', params: {'p_supplier_order_id': _orderId});
      if (!mounted) return;
      setState(() {
        _billInfo = result is Map ? Map<String, dynamic>.from(result) : <String, dynamic>{};
        _billLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _billInfo = null;
        _billLoading = false;
      });
    }
  }

  Future<void> _confirmDeleteBill() async {
    if (_deletingBill) return;
    final pendingBillId = _billInfo?['pending_bill_id']?.toString();
    if (pendingBillId == null || pendingBillId.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(c('supplier_orders.delete_bill_title')),
        content: Text(c('supplier_orders.delete_bill_body')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(c('supplier_orders.cancel'))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(c('supplier_orders.delete'),
                style: Ds.t.body.copyWith(color: Ds.c.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _deleteBill(pendingBillId);
  }

  Future<void> _deleteBill(String pendingBillId) async {
    if (_deletingBill) return;
    setState(() => _deletingBill = true);
    try {
      final raw = await Supabase.instance.client
          .rpc('sup_delete_bill', params: {'p_pending_bill_id': pendingBillId});
      final res = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      if (res['ok'] == true) {
        if (mounted) {
          showToast(context, c('supplier_orders.toast_bill_deleted'));
          setState(() => _billViewOpen = false);
        }
        await _loadBillInfo(refresh: true);
      } else if (res['error'] == 'already_imported') {
        if (mounted) {
          showToast(
            context,
            res['message']?.toString() ??
                c('supplier_orders.toast_bill_already_imported'),
            isError: true,
          );
        }
        await _loadBillInfo(refresh: true);
      } else {
        if (mounted) {
          showToast(context, c('supplier_orders.toast_delete_failed'), isError: true);
        }
      }
    } catch (_) {
      if (mounted) {
        showToast(context, c('supplier_orders.toast_delete_failed'), isError: true);
      }
    } finally {
      if (mounted) setState(() => _deletingBill = false);
    }
  }

  Future<({List<int> bytes, String filename})?> _fetchBillFile(String bucket, String path, String name) async {
    try {
      final bytes = await Supabase.instance.client.storage.from(bucket).download(path);
      return (bytes: bytes, filename: name);
    } catch (_) {
      if (mounted) {
        showToast(context, c('supplier_orders.toast_bill_load_failed'), isError: true);
      }
      return null;
    }
  }

  Future<void> _downloadBill(String bucket, String path, String name) async {
    if (_downloadingBill) return;
    setState(() => _downloadingBill = true);
    final file = await _fetchBillFile(bucket, path, name);
    if (mounted) setState(() => _downloadingBill = false);
    if (file == null) return;
    downloadBytes(file.bytes, file.filename, mimeFromBillName(file.filename));
  }

  Future<void> _shareBill(String bucket, String path, String name) async {
    if (_sharingBill) return;
    setState(() => _sharingBill = true);
    final file = await _fetchBillFile(bucket, path, name);
    if (file == null) {
      if (mounted) setState(() => _sharingBill = false);
      return;
    }
    final mime = mimeFromBillName(file.filename);
    final result = await shareBytes(file.bytes, file.filename, mime);
    if (mounted) setState(() => _sharingBill = false);
    if (result == null) downloadBytes(file.bytes, file.filename, mime);
  }

  Future<void> _loadPanel({bool refresh = false}) async {
    if (_panelLoading) return;
    if (_panelData != null && !refresh) return;
    if (!mounted) return;
    setState(() { _panelLoading = true; _panelError = null; });
    try {
      final result = await Supabase.instance.client
          .rpc('sup_order_bill_panel', params: {'p_supplier_order_id': _orderId});
      if (!mounted) return;
      setState(() {
        _panelData = Map<String, dynamic>.from(result as Map? ?? {});
        _panelLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _panelError = e.toString();
        _panelLoading = false;
      });
    }
  }

  Future<void> _uploadSupplierBill() async {
    // step 1: pick file
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'pdf'],
        allowMultiple: false,
        withData: true,
      );
    } catch (_) {
      return;
    }
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) return;

    // step 2: size guard
    if (bytes.length > 15 * 1024 * 1024) {
      if (mounted) {
        showToast(context, c('supplier_orders.toast_file_too_large'), isError: true);
      }
      return;
    }

    setState(() => _uploading = true);
    try {
      // step 3: build path
      final ext = (file.extension ?? 'jpg').toLowerCase();
      final orderCode = (widget.order['order_code'] as String?)?.trim() ?? _orderId.substring(0, 8);
      final path = 'sup/${orderCode}_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final contentType = switch (ext) {
        'pdf'  => 'application/pdf',
        'png'  => 'image/png',
        'webp' => 'image/webp',
        _      => 'image/jpeg',
      };

      // step 4: upload to storage
      try {
        await Supabase.instance.client.storage
            .from('supplier-bills')
            .uploadBinary(path, bytes, fileOptions: FileOptions(contentType: contentType));
      } catch (e) {
        if (mounted) {
          showToast(context, c('supplier_orders.toast_upload_failed'), isError: true);
        }
        return;
      }

      // step 5: register bill
      RenderLog.write('c328_sup_upload', 'order=$orderCode;file=${file.name}');
      try {
        await Supabase.instance.client.rpc('sup_register_bill', params: {
          'p_supplier_name': widget.supplierName,
          'p_file_path': path,
          'p_file_name': file.name,
          'p_bucket': 'supplier-bills',
        });
        if (mounted) showToast(context, c('supplier_orders.toast_bill_uploaded'));
      } catch (e) {
        if (mounted) {
          showToast(context,
            c('supplier_orders.toast_bill_not_registered'), isError: true);
        }
        return;
      }

      // step 6: refresh bill state so "View Bill" appears
      if (mounted) await _loadBillInfo(refresh: true);

      // step 7: refresh panel if open
      if (_payOpen && mounted) {
        await _loadPanel(refresh: true);
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  // CMD #467 row 52 — supplier_set_packed answers with a payload, not an
  // exception. It used to be awaited and thrown away: a refusal (`not_found`,
  // `not_authorized`) came back HTTP 200 as a bare slug, so the screen called
  // onReload() as though the order had been packed and the supplier saw
  // nothing at all. Every branch now renders the backend's own `message` —
  // this file never decides what a refusal says.
  Future<void> _setPacked(String orderCode, bool nextPacked) async {
    if (_togglingPacked || orderCode.isEmpty) return;
    setState(() => _togglingPacked = true);
    try {
      final raw = await Supabase.instance.client.rpc('supplier_set_packed', params: {
        'p_order_code': orderCode,
        'p_packed': nextPacked,
        'p_via': 'order_tab',
      });
      final res = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      final message = (res['message'] ?? '').toString();
      RenderLog.write('c467_sup_packed',
          'ok=${res['ok'] == true},error=${(res['error'] ?? '').toString()},msg=${message.isNotEmpty}');
      if (res['ok'] == true) {
        if (mounted && message.isNotEmpty) showToast(context, message);
        widget.onReload();
      } else {
        if (mounted) {
          showToast(
            context,
            message.isNotEmpty
                ? message
                : c('supplier_orders.toast_pack_failed'),
            isError: true,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        showToast(context, c('supplier_orders.toast_pack_failed'), isError: true);
      }
    } finally {
      if (mounted) setState(() => _togglingPacked = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final orderNo   = widget.order['order_no']?.toString() ?? '';
    final orderCode = (widget.order['order_code'] as String?)?.trim() ?? '';
    // CHANGE #464 gap 45: the order total is a BACKEND string. Dart no longer
    // owns the rupee sign or the rounding rule — po_pricing_block sends
    // payable_display, and show_payable decides whether it appears at all.
    final pricing = widget.order['pricing'] is Map
        ? Map<String, dynamic>.from(widget.order['pricing'] as Map)
        : const <String, dynamic>{};
    final total = SupplierOrderTotal.from(pricing);
    final itemCount = (widget.order['item_count'] as num?)?.toInt() ?? 0;
    // CHANGE #548: raw backend timestamp, rendered via ist_fmt.
    final createdAt = widget.order['created_at']?.toString();
    final items = (widget.order['items'] as List<dynamic>? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final statusLabel = (widget.order['status_label'] as String?)?.trim().isNotEmpty == true
        ? (widget.order['status_label'] as String).trim()
        : (widget.order['status'] as String? ?? '');
    final statusTone = widget.order['status_tone'] as String?;

    // c328_sup_row fires on every card render (list-time, not tap-gated)
    RenderLog.write('c328_sup_row', 'order=${orderCode.isNotEmpty ? orderCode : _orderId.substring(0, 8)}');

    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x8),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider, width: 0.5),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──────────────────────────────────────────────────────────
          InkWell(
            borderRadius: (widget.isOpen || _payOpen)
                ? BorderRadius.vertical(top: Radius.circular(Ds.r.card))
                : Ds.r.rCard,
            onTap: widget.onToggle,
            child: Padding(
              padding: EdgeInsets.all(Ds.space.x12),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        orderNo.isNotEmpty
                            ? cf('supplier_orders.order_no', {'no': orderNo})
                            : c('supplier_orders.order'),
                        style: Ds.t.body.copyWith(fontWeight: FontWeight.w700),
                      ),
                      if (orderCode.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Builder(builder: (_) {
                          RenderLog.write('c317_order_id_shown', orderCode);
                          return Text(
                            orderCode,
                            style: Ds.t.caption.copyWith(
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.3,
                            ),
                          );
                        }),
                      ],
                      if (createdAt != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          _formatDate(createdAt),
                          style: Ds.t.caption,
                        ),
                      ],
                    ],
                  ),
                ),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  if (total.show) ...[
                    Text(
                      total.display,
                      style: Ds.t.body.copyWith(fontWeight: FontWeight.w700),
                    ),
                    SizedBox(width: Ds.space.x8),
                  ],
                  if (itemCount > 0) ...[
                    Text(
                      cf(
                        itemCount == 1
                            ? 'supplier_orders.item_count_one'
                            : 'supplier_orders.item_count_many',
                        {'count': '$itemCount'},
                      ),
                      style: Ds.t.caption,
                    ),
                    SizedBox(width: Ds.space.x8),
                  ],
                  // CHANGE #671: the word AND the tone are the backend's
                  // (supplier_my_orders.status_label / .status_tone). Pre-#671
                  // payloads still carry only `status`, so it is the fallback
                  // and the chip can never go blank.
                  if (statusLabel.isNotEmpty) ...[
                    _StatusBadge(label: statusLabel, tone: statusTone),
                    SizedBox(width: Ds.space.x8),
                  ],
                  Icon(
                    widget.isOpen
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: Ds.c.textSecondary,
                    size: 22,
                  ),
                ]),
              ]),
            ),
          ),

          // ── Upload Bill / View Payment button row ────────────────────────────
          Padding(
            padding: EdgeInsets.fromLTRB(
                Ds.space.x12, 0, Ds.space.x12, Ds.space.x8),
            child: Row(children: [
              // Upload Bill (left)
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _uploading ? null : _uploadSupplierBill,
                  icon: _uploading
                      ? SizedBox(
                          width: 14, height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Ds.c.brand),
                        )
                      : const Icon(Icons.upload_outlined, size: 14),
                  label: Text(
                      _uploading
                          ? c('supplier_orders.uploading')
                          : c('supplier_orders.upload_bill'),
                      style: Ds.t.caption.copyWith(fontWeight: FontWeight.w600)),
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.symmetric(vertical: Ds.space.x4),
                    side: BorderSide(color: Ds.c.divider),
                    foregroundColor: Ds.c.text,
                    shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                    minimumSize: Size(0, Ds.touch.minTarget),
                  ),
                ),
              ),
              SizedBox(width: Ds.space.x8),
              // View Payment (right)
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    setState(() => _payOpen = !_payOpen);
                    if (!_payOpen) return;
                    _loadPanel();
                  },
                  child: Container(
                    padding: EdgeInsets.symmetric(
                        horizontal: Ds.space.x8, vertical: Ds.space.x12),
                    decoration: BoxDecoration(
                      color: _payOpen ? Ds.c.infoSoft : Ds.c.bg,
                      borderRadius: Ds.r.rButton,
                      border: Border.all(
                        color: _payOpen
                            ? Ds.c.info.withValues(alpha: 0.4)
                            : Ds.c.divider,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            c('supplier_orders.view_payment'),
                            style: Ds.t.caption.copyWith(
                              fontWeight: FontWeight.w600,
                              color: _payOpen ? Ds.c.info : Ds.c.text,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        SizedBox(width: Ds.space.x4),
                        AnimatedRotation(
                          turns: _payOpen ? 0.5 : 0.0,
                          duration: Ds.motion.standard,
                          child: Icon(
                            Icons.expand_more,
                            size: 14,
                            color: _payOpen ? Ds.c.info : Ds.c.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ]),
          ),

          // ── CHANGE #687 (#68) — the clock the supplier is racing. It sits
          // directly above the Accept / Decline buttons because that is the
          // decision it bounds. has:false (already answered, or an order from
          // before this change and therefore without a clock) renders nothing.
          if (widget.order['accept'] is Map)
            ResponseDeadline(
              block: deadlineOf(widget.order['accept']),
              renderKey: 'c687_po_deadline',
              onRefresh: () async => widget.onReload(),
            ),

          // ── CHANGE #527 (#50) — accept / part-accept / decline, and (#61)
          // the batch, expiry and HSN he acknowledges with it. Both blocks are
          // the backend's: absent payload => nothing renders, exactly as before.
          if (widget.order['accept'] is Map)
            SupplierPoAck(
              accept: Map<String, dynamic>.from(widget.order['accept'] as Map),
              items: (widget.order['items'] as List<dynamic>? ?? const [])
                  .whereType<Map>()
                  .map((e) => Map<String, dynamic>.from(e))
                  .toList(),
              orderCode: orderCode,
              onAnswered: () async => widget.onReload(),
            ),
          if (widget.order['line_details'] is Map)
            SupplierPoLineDetails(
              block: Map<String, dynamic>.from(widget.order['line_details'] as Map),
              items: (widget.order['items'] as List<dynamic>? ?? const [])
                  .whereType<Map>()
                  .map((e) => Map<String, dynamic>.from(e))
                  .toList(),
              orderCode: orderCode,
              onSaved: () async => widget.onReload(),
            ),

          // ── Pack button ─────────────────────────────────────────────────────
          if (widget.order['pack_button'] is Map) ...[
            Builder(builder: (_) {
              final packButton = Map<String, dynamic>.from(widget.order['pack_button'] as Map);
              final label = packButton['label']?.toString() ?? '';
              final bg = Ds.hex(packButton['bg']?.toString(), Ds.c.brand);
              final fg = Ds.hex(packButton['fg']?.toString(), Ds.c.surface);
              final nextPacked = packButton['next_packed'] == true;
              // #527 (#50): 'enabled' absent => the pre-change behaviour.
              final packEnabled = PoPackGate.enabled(packButton);
              final blockedReason = PoPackGate.blockedReason(packButton);
              return Padding(
                padding: EdgeInsets.fromLTRB(
                    Ds.space.x12, 0, Ds.space.x12, Ds.space.x8),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _togglingPacked
                        ? null
                        : !packEnabled
                            ? (blockedReason.isEmpty
                                ? null
                                : () => showToast(context, blockedReason,
                                    isError: true))
                            : () => _setPacked(orderCode, nextPacked),
                    style: FilledButton.styleFrom(
                      backgroundColor: bg,
                      shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                      padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
                    ),
                    child: _togglingPacked
                        ? SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                          )
                        : Text(label,
                            style: Ds.t.caption
                                .copyWith(fontWeight: FontWeight.w700, color: fg)),
                  ),
                ),
              );
            }),
          ],

          // ── View Payment panel ───────────────────────────────────────────────
          if (_payOpen) _buildPayPanel(),

          // ── View Bill row (#471) — only once sup_bill_file confirms a file exists ──
          if (_billInfo != null && _billInfo!['has_file'] == true) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(
                  Ds.space.x12, 0, Ds.space.x12, Ds.space.x8),
              child: Row(children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _billViewOpen = !_billViewOpen),
                    child: Container(
                      padding: EdgeInsets.symmetric(
                          horizontal: Ds.space.x8, vertical: Ds.space.x12),
                      decoration: BoxDecoration(
                        color: _billViewOpen ? Ds.c.infoSoft : Ds.c.bg,
                        borderRadius: Ds.r.rButton,
                        border: Border.all(
                          color: _billViewOpen
                              ? Ds.c.info.withValues(alpha: 0.4)
                              : Ds.c.divider,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.receipt_long_outlined,
                              size: 14,
                              color: _billViewOpen ? Ds.c.info : Ds.c.text),
                          SizedBox(width: Ds.space.x4),
                          Flexible(
                            child: Text(
                              c('supplier_orders.view_bill'),
                              style: Ds.t.caption.copyWith(
                                fontWeight: FontWeight.w600,
                                color: _billViewOpen ? Ds.c.info : Ds.c.text,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          SizedBox(width: Ds.space.x4),
                          AnimatedRotation(
                            turns: _billViewOpen ? 0.5 : 0.0,
                            duration: Ds.motion.standard,
                            child: Icon(
                              Icons.expand_more,
                              size: 14,
                              color: _billViewOpen ? Ds.c.info : Ds.c.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_billInfo!['imported'] == true) ...[
                  SizedBox(width: Ds.space.x8),
                  Container(
                    padding: EdgeInsets.symmetric(
                        horizontal: Ds.space.x8, vertical: Ds.space.x4),
                    decoration: BoxDecoration(
                        color: Ds.c.successSoft, borderRadius: Ds.r.rChip),
                    child: Text(c('supplier_orders.imported'),
                        style: Ds.t.caption.copyWith(
                            fontWeight: FontWeight.w600, color: Ds.c.success)),
                  ),
                ],
              ]),
            ),
          ],

          // ── View Bill panel ──────────────────────────────────────────────────
          if (_billViewOpen) _buildBillPanel(),

          // ── Expanded order items body ────────────────────────────────────────
          if (widget.isOpen) ...[
            Divider(height: 1, color: Ds.c.divider),
            Padding(
              padding: EdgeInsets.all(Ds.space.x12),
              child: items.isEmpty
                  ? Text(c('supplier_orders.no_items'), style: Ds.t.caption)
                  : Builder(builder: (_) {
                      RenderLog.write('c189_supplier_tab_shared_card', 'true');
                      return Column(children: [
                        PoPricingBanner(
                            pricing: pricing.isEmpty ? null : pricing),
                        ...items.map((item) => Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                OrderItemCard(item: item),
                                PoRateLine(item: item),
                              ],
                            )),
                      ]);
                    }),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPayPanel() {
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Ds.c.divider)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            Ds.space.x12, Ds.space.x8, Ds.space.x12, Ds.space.x12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text(c('supplier_orders.payment_summary'),
                  style: Ds.t.caption.copyWith(
                      fontWeight: FontWeight.w700, color: Ds.c.text)),
              const Spacer(),
              GestureDetector(
                onTap: () => _loadPanel(refresh: true),
                child: Icon(Icons.refresh, size: 16, color: Ds.c.textSecondary),
              ),
            ]),
            SizedBox(height: Ds.space.x8),
            if (_panelLoading)
              Center(
                child: Padding(
                  padding: EdgeInsets.all(Ds.space.x16),
                  child: CircularProgressIndicator(color: Ds.c.brand),
                ),
              )
            else if (_panelError != null)
              _PanelError(onRetry: () => _loadPanel(refresh: true))
            else if (_panelData == null || _panelData!['found'] != true)
              Padding(
                padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
                child: Text(c('supplier_orders.payment_unavailable'),
                    style: Ds.t.caption),
              )
            else
              SupPayPanel(
                data: _panelData!,
                orderId: _orderId,
                onReload: () => _loadPanel(refresh: true),
                isReadOnly: true,
              ),
          ],
        ),
      ),
    );
  }

  // CHANGE #471: supplier's own uploaded bill — preview + Download/Share +
  // Delete (while pending). Reuses the #469 bill viewer (BillFilePreview /
  // showBillViewer) pointed at the supplier-bills bucket.
  Widget _buildBillPanel() {
    final info = _billInfo ?? const <String, dynamic>{};
    final bucket = info['bucket']?.toString() ?? 'supplier-bills';
    final path = info['path']?.toString() ?? '';
    final name = info['name']?.toString() ?? c('supplier_orders.bill_default_name');
    final canDelete = info['can_delete'] == true;
    if (path.isNotEmpty) RenderLog.write('c479_bill_bucket_resolved', bucket);

    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Ds.c.divider)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            Ds.space.x12, Ds.space.x8, Ds.space.x12, Ds.space.x12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (path.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
                child: Text(c('supplier_orders.bill_unavailable'),
                    style: Ds.t.caption),
              )
            else ...[
              BillFilePreview(key: ValueKey('$bucket/$path'), bucket: bucket, path: path, name: name),
              SizedBox(height: Ds.space.x12),
              Row(children: [
                Expanded(
                  child: BillActionButton(
                    icon: Icons.download_outlined,
                    label: _downloadingBill
                        ? c('supplier_orders.downloading')
                        : c('supplier_orders.download'),
                    enabled: !_downloadingBill,
                    loading: _downloadingBill,
                    onTap: () => _downloadBill(bucket, path, name),
                  ),
                ),
                SizedBox(width: Ds.space.x8),
                Expanded(
                  child: BillActionButton(
                    icon: Icons.share_outlined,
                    label: _sharingBill
                        ? c('supplier_orders.sharing')
                        : c('supplier_orders.share'),
                    enabled: !_sharingBill,
                    loading: _sharingBill,
                    onTap: () => _shareBill(bucket, path, name),
                  ),
                ),
              ]),
              if (canDelete) ...[
                SizedBox(height: Ds.space.x8),
                GestureDetector(
                  onTap: _deletingBill ? null : _confirmDeleteBill,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (_deletingBill)
                      SizedBox(
                          width: 14, height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Ds.c.danger))
                    else
                      Icon(Icons.delete_outline, size: 15, color: Ds.c.danger),
                    SizedBox(width: Ds.space.x4),
                    Text(_deletingBill
                            ? c('supplier_orders.deleting')
                            : c('supplier_orders.delete_bill'),
                        style: Ds.t.caption.copyWith(
                            fontWeight: FontWeight.w600, color: Ds.c.danger)),
                  ]),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  // CHANGE #548: backend-formatted (ist_fmt 'day_mon_time12'); the hardcoded
  // months array and 12-hour math are deleted.
  String _formatDate(String? ts) {
    return DateLabels.instance.label(ts, DateStyle.dayMonTime12) ?? '';
  }
}

// ── Panel error / retry ───────────────────────────────────────────────────────

class _PanelError extends StatelessWidget {
  final VoidCallback onRetry;
  const _PanelError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
      child: Row(children: [
        Text(c('supplier_orders.panel_failed'), style: Ds.t.caption),
        SizedBox(width: Ds.space.x8),
        GestureDetector(
          onTap: onRetry,
          child: Text(c('supplier_orders.retry'),
              style: Ds.t.caption.copyWith(
                  color: Ds.c.brand, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

// ── Status badge ──────────────────────────────────────────────────────────────

/// CHANGE #671 gap 51 — the status chip is a PRINTER.
///
/// It used to switch on the status STRING to pick one of five hardcoded hex
/// pairs, which meant 'accepted' was green because Dart said so and any status
/// this build had not been taught fell into a grey default nobody chose. Both
/// the word and the tone NAME now come from supplier_my_orders
/// (status_label / status_tone); the chip performs one tone -> token lookup and
/// decides nothing.
class _StatusBadge extends StatelessWidget {
  final String label;
  final String? tone;
  const _StatusBadge({required this.label, this.tone});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration:
          BoxDecoration(color: dsToneBg(tone), borderRadius: Ds.r.rChip),
      child: Text(
        label,
        style: Ds.t.caption
            .copyWith(fontWeight: FontWeight.w600, color: dsToneFg(tone)),
      ),
    );
  }
}

