import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import '../../widgets/order_item_card.dart';
import '../../widgets/sup_pay_panel.dart';

// ── Screen ────────────────────────────────────────────────────────────────────

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
  RealtimeChannel? _rt;

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
    final ts = DateTime.now().millisecondsSinceEpoch;
    _rt = Supabase.instance.client
        .channel('sup_orders_rt_$ts')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'supplier_orders',
          callback: (_) => _fetch(source: 'realtime', silent: true),
        )
        .subscribe();
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
        return const Center(
          child: CircularProgressIndicator(color: Color(0xFF1B7A43)),
        );
      }

      if (_orders.isEmpty && !_loading) {
        return Center(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.receipt_long_outlined, size: 56, color: Color(0xFFD1D5DB)),
            const SizedBox(height: 12),
            const Text('No orders yet.',
                style: TextStyle(fontSize: 15, color: Color(0xFF6B7280))),
          ]),
        );
      }

      return ListView.builder(
        padding: EdgeInsets.all(constraints.maxWidth >= 900 ? 24 : 12),
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

  const _OrderCard({
    required this.order,
    required this.supplierName,
    required this.isOpen,
    required this.onToggle,
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

  String get _orderId => widget.order['order_id'] as String? ?? '';

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
      if (mounted) showToast(context, 'File too large (max 15 MB)', isError: true);
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
        if (mounted) showToast(context, 'Upload failed — try again', isError: true);
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
        if (mounted) showToast(context, 'Bill uploaded ✓');
      } catch (e) {
        if (mounted) {
          showToast(context,
            'Bill saved but not registered — contact mediBO', isError: true);
        }
        return;
      }

      // step 7: refresh panel if open
      if (_payOpen && mounted) {
        await _loadPanel(refresh: true);
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final orderNo   = widget.order['order_no']?.toString() ?? '';
    final orderCode = (widget.order['order_code'] as String?)?.trim() ?? '';
    final totalAmount = (widget.order['total_amount'] as num?)?.toDouble();
    final itemCount = (widget.order['item_count'] as num?)?.toInt() ?? 0;
    final createdAt = widget.order['created_at'] != null
        ? DateTime.tryParse(widget.order['created_at'] as String)?.toLocal()
        : null;
    final items = (widget.order['items'] as List<dynamic>? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final status = widget.order['status'] as String? ?? '';

    // c328_sup_row fires on every card render (list-time, not tap-gated)
    RenderLog.write('c328_sup_row', 'order=${orderCode.isNotEmpty ? orderCode : _orderId.substring(0, 8)}');

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB), width: 0.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──────────────────────────────────────────────────────────
          InkWell(
            borderRadius: (widget.isOpen || _payOpen)
                ? const BorderRadius.vertical(top: Radius.circular(12))
                : BorderRadius.circular(12),
            onTap: widget.onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        orderNo.isNotEmpty ? 'Order $orderNo' : 'Order',
                        style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111827),
                        ),
                      ),
                      if (orderCode.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Builder(builder: (_) {
                          RenderLog.write('c317_order_id_shown', orderCode);
                          return Text(
                            orderCode,
                            style: const TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w500,
                              color: Color(0xFF9CA3AF), letterSpacing: 0.3,
                            ),
                          );
                        }),
                      ],
                      if (createdAt != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          _formatDate(createdAt),
                          style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                        ),
                      ],
                    ],
                  ),
                ),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  if (totalAmount != null && totalAmount > 0) ...[
                    Text(
                      '₹${totalAmount % 1 == 0 ? totalAmount.toInt() : totalAmount.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (itemCount > 0) ...[
                    Text(
                      '$itemCount item${itemCount == 1 ? '' : 's'}',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (status.isNotEmpty) ...[
                    _StatusBadge(status: status),
                    const SizedBox(width: 8),
                  ],
                  Icon(
                    widget.isOpen
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: const Color(0xFF6B7280),
                    size: 22,
                  ),
                ]),
              ]),
            ),
          ),

          // ── Upload Bill / View Payment button row ────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Row(children: [
              // Upload Bill (left)
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _uploading ? null : _uploadSupplierBill,
                  icon: _uploading
                      ? const SizedBox(
                          width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43)),
                        )
                      : const Icon(Icons.upload_outlined, size: 14),
                  label: Text(_uploading ? 'Uploading…' : 'Upload Bill',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    side: const BorderSide(color: Color(0xFFD1D5DB)),
                    foregroundColor: const Color(0xFF374151),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    minimumSize: const Size(0, 36),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // View Payment (right)
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    setState(() => _payOpen = !_payOpen);
                    if (!_payOpen) return;
                    _loadPanel();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: _payOpen ? const Color(0xFFEFF6FF) : const Color(0xFFF5F6F8),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _payOpen
                            ? const Color(0xFF1E40AF).withValues(alpha: 0.4)
                            : const Color(0xFFE5E7EB),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            'View Payment',
                            style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600,
                              color: _payOpen ? const Color(0xFF1E40AF) : const Color(0xFF374151),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        AnimatedRotation(
                          turns: _payOpen ? 0.5 : 0.0,
                          duration: const Duration(milliseconds: 150),
                          child: Icon(
                            Icons.expand_more,
                            size: 14,
                            color: _payOpen ? const Color(0xFF1E40AF) : const Color(0xFF6B7280),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ]),
          ),

          // ── View Payment panel ───────────────────────────────────────────────
          if (_payOpen) _buildPayPanel(),

          // ── Expanded order items body ────────────────────────────────────────
          if (widget.isOpen) ...[
            const Divider(height: 1, color: Color(0xFFF3F4F6)),
            Padding(
              padding: const EdgeInsets.all(12),
              child: items.isEmpty
                  ? const Text('No items.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)))
                  : Builder(builder: (_) {
                      RenderLog.write('c189_supplier_tab_shared_card', 'true');
                      return Column(
                        children: items.map((item) => OrderItemCard(item: item)).toList(),
                      );
                    }),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPayPanel() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFF3F4F6))),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Text('Payment Summary',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              const Spacer(),
              GestureDetector(
                onTap: () => _loadPanel(refresh: true),
                child: const Icon(Icons.refresh, size: 16, color: Color(0xFF6B7280)),
              ),
            ]),
            const SizedBox(height: 8),
            if (_panelLoading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(color: Color(0xFF1B7A43)),
                ),
              )
            else if (_panelError != null)
              _PanelError(onRetry: () => _loadPanel(refresh: true))
            else if (_panelData == null || _panelData!['found'] != true)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Payment details unavailable.',
                    style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
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

  String _formatDate(DateTime dt) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    var h = dt.hour % 12;
    if (h == 0) h = 12;
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    final m = dt.minute.toString().padLeft(2, '0');
    return '${dt.day} ${months[dt.month - 1]}, $h:$m $ampm';
  }
}

// ── Panel error / retry ───────────────────────────────────────────────────────

class _PanelError extends StatelessWidget {
  final VoidCallback onRetry;
  const _PanelError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        const Text('Failed to load.', style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: onRetry,
          child: const Text('Retry', style: TextStyle(fontSize: 13, color: Color(0xFF1B7A43), fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

// ── Status badge ──────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    Color bg, fg;
    switch (status.toLowerCase()) {
      case 'pending':   bg = const Color(0xFFFEF3C7); fg = const Color(0xFF92400E); break;
      case 'accepted':  bg = const Color(0xFFD1FAE5); fg = const Color(0xFF065F46); break;
      case 'rejected':  bg = const Color(0xFFFEE2E2); fg = const Color(0xFF991B1B); break;
      case 'completed': bg = const Color(0xFFEFF6FF); fg = const Color(0xFF1E40AF); break;
      default:          bg = const Color(0xFFF3F4F6); fg = const Color(0xFF6B7280);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(
        status,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }
}

