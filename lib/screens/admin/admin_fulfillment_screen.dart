import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../utils/render_log.dart';

// ── Color tokens ────────────────────────────────────────────────────────────
const _kGreen        = Color(0xFF1B7A43);
const _kBg           = Color(0xFFF5F6F8);
const _kCard         = Colors.white;
const _kBorder       = Color(0xFFE5E7EB);
const _kText         = Color(0xFF111827);
const _kSub          = Color(0xFF6B7280);

// fulfillment_state colors
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

Map<String, Color> _stateBg = {
  'received':    _kReceivedBg,
  'short':       _kShortBg,
  'wrong':       _kWrongBg,
  'not_coming':  _kNotComingBg,
  'packed':      _kShippedBg,
  'shipped':     _kShippedBg,
  'pending':     _kPendingBg,
};
Map<String, Color> _stateFg = {
  'received':    _kReceivedFg,
  'short':       _kShortFg,
  'wrong':       _kWrongFg,
  'not_coming':  _kNotComingFg,
  'packed':      _kShippedFg,
  'shipped':     _kShippedFg,
  'pending':     _kPendingFg,
};

// ── Shared micro-widgets ────────────────────────────────────────────────────

class _StatePill extends StatelessWidget {
  final String state;
  const _StatePill(this.state);

  @override
  Widget build(BuildContext context) {
    final bg = _stateBg[state] ?? _kPendingBg;
    final fg = _stateFg[state] ?? _kPendingFg;
    final label = state.replaceAll('_', ' ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
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
      case 'shipped':          bg = _kShippedBg;  fg = _kShippedFg;  break;
      case 'partially_shipped':bg = _kShippedBg;  fg = _kShippedFg;  break;
      case 'ready':            bg = _kReceivedBg; fg = _kReceivedFg; break;
      case 'partial_ready':    bg = _kPendingBg;  fg = _kPendingFg;  break;
      case 'waiting':          bg = _kShortBg;    fg = _kShortFg;    break;
      default:                 bg = _kPendingBg;  fg = _kPendingFg;
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
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.medication_outlined, size: 24, color: Color(0xFFD1D5DB)),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        imageUrl!,
        width: size, height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: size, height: size,
          color: const Color(0xFFF3F4F6),
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
        width: 40,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _kBg,
          border: Border.all(color: _kBorder),
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
        width: 36, height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: onTap != null ? _kGreen : const Color(0xFFE5E7EB),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(icon, size: 18, color: onTap != null ? Colors.white : const Color(0xFF9CA3AF)),
      ),
    );
  }
}

// ── _ItemOverlay — transient per-item UI state ──────────────────────────────
class _ItemOverlay {
  String state;
  int receivedQty;
  bool showQtyPanel;
  int qtyDraft;
  bool loading;

  _ItemOverlay({
    required this.state,
    required this.receivedQty,
    this.showQtyPanel = false,
    this.qtyDraft = 1,
    this.loading = false,
  });
}

// ── RECEIVE SCREEN ──────────────────────────────────────────────────────────

class _ReceiveScreen extends StatefulWidget {
  const _ReceiveScreen({super.key});

  @override
  State<_ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<_ReceiveScreen> {
  List<String> _suppliers = [];
  String? _selectedSupplier;
  List<Map<String, dynamic>> _items = [];
  final Map<String, _ItemOverlay> _overlay = {};
  bool _loadingSuppliers = true;
  bool _loadingBox = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSuppliers();
    RenderLog.write('fulfillment_receive_screen', 'true');
  }

  Future<void> _loadSuppliers() async {
    try {
      final res = await Supabase.instance.client
          .rpc('get_fulfillment_suppliers') as List;
      if (!mounted) return;
      setState(() {
        _suppliers = res.map((r) => (r as Map)['supplier_name'].toString()).toList();
        _loadingSuppliers = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loadingSuppliers = false; _error = e.toString(); });
    }
  }

  Future<void> _loadBox(String supplierName) async {
    setState(() { _loadingBox = true; _error = null; });
    try {
      final res = await Supabase.instance.client
          .rpc('get_receiving_box', params: {'p_supplier_name': supplierName}) as List;
      if (!mounted) return;
      final items = res.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      final overlay = <String, _ItemOverlay>{};
      for (final item in items) {
        final id = item['id'].toString();
        overlay[id] = _ItemOverlay(
          state: item['fulfillment_state']?.toString() ?? 'pending',
          receivedQty: (item['received_qty'] as num?)?.toInt() ?? 0,
          qtyDraft: (item['quantity'] as num?)?.toInt() ?? 1,
        );
      }
      setState(() {
        _items = items;
        _overlay.clear();
        _overlay.addAll(overlay);
        _loadingBox = false;
      });
      for (var i = 0; i < items.length; i++) {
        RenderLog.write('fulfillment_receive_card_$i', items[i]['product_name']?.toString() ?? '');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _loadingBox = false; _error = e.toString(); });
    }
  }

  Future<void> _setState(String itemId, String state, {int? qty}) async {
    final ov = _overlay[itemId];
    if (ov == null) return;
    setState(() => ov.loading = true);
    try {
      await Supabase.instance.client.rpc('set_item_receiving', params: {
        'p_item_id': itemId,
        'p_state': state,
        if (qty != null) 'p_qty': qty,
      });
      RenderLog.write('fulfillment_set_state_ok', '$itemId:$state');
      setState(() {
        ov.state = state;
        if (qty != null) ov.receivedQty = qty;
        ov.showQtyPanel = false;
        ov.loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => ov.loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: const Color(0xFFDC2626)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingSuppliers) {
      return const Center(child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2));
    }
    if (_error != null && _suppliers.isEmpty) {
      return Center(child: Text('Error: $_error', style: const TextStyle(color: Color(0xFFDC2626))));
    }

    return Column(children: [
      // Supplier picker
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: _kBg,
            border: Border.all(color: _kBorder),
            borderRadius: BorderRadius.circular(8),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              isExpanded: true,
              hint: const Text('Select supplier…', style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 15)),
              value: _selectedSupplier,
              items: _suppliers.map((s) => DropdownMenuItem(value: s, child: Text(s, style: const TextStyle(fontSize: 15, color: _kText)))).toList(),
              onChanged: (v) {
                if (v == null) return;
                setState(() { _selectedSupplier = v; _items = []; _overlay.clear(); });
                _loadBox(v);
              },
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),

      if (_loadingBox)
        const Expanded(child: Center(child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2)))
      else if (_selectedSupplier == null)
        const Expanded(child: Center(child: Text('Choose a supplier to see their box', style: TextStyle(color: _kSub, fontSize: 15))))
      else if (_items.isEmpty)
        const Expanded(child: Center(child: Text('No pending items for this supplier', style: TextStyle(color: _kSub, fontSize: 15))))
      else
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            itemCount: _items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) => _buildItemCard(_items[i]),
          ),
        ),
    ]);
  }

  Widget _buildItemCard(Map<String, dynamic> item) {
    final id = item['id'].toString();
    final ov = _overlay[id];
    if (ov == null) return const SizedBox.shrink();
    final name = item['product_name']?.toString() ?? '—';
    final qty = (item['quantity'] as num?)?.toInt() ?? 0;
    final company = item['company_name']?.toString() ?? '';
    final imageUrl = item['image_url']?.toString();
    final isDone = ov.state != 'pending';

    return Container(
      decoration: BoxDecoration(
        color: _kCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isDone ? (_stateBg[ov.state] ?? _kBorder) : _kBorder),
        boxShadow: const [BoxShadow(color: Color(0x0F000000), blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _FulfilImageTile(imageUrl, size: 52),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _kText), maxLines: 2, overflow: TextOverflow.ellipsis),
                if (company.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(company, style: const TextStyle(fontSize: 12, color: _kSub)),
                ],
                const SizedBox(height: 6),
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: _kBg, borderRadius: BorderRadius.circular(6), border: Border.all(color: _kBorder)),
                    child: Text('Qty: $qty', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText)),
                  ),
                  const SizedBox(width: 8),
                  _StatePill(ov.state),
                  if (ov.state == 'short' && ov.receivedQty > 0) ...[
                    const SizedBox(width: 6),
                    Text('Got ${ov.receivedQty}', style: const TextStyle(fontSize: 12, color: _kShortFg, fontWeight: FontWeight.w600)),
                  ],
                ]),
              ]),
            ),
            if (ov.loading)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2)),
              ),
          ]),
        ),

        // Action buttons
        if (!isDone) ...[
          const Divider(height: 1, color: _kBorder),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(children: [
              Row(children: [
                Expanded(child: _ActionBtn('Got All', _kGreen, Icons.check_rounded, () => _setState(id, 'received', qty: qty))),
                const SizedBox(width: 8),
                Expanded(child: _ActionBtn('Enter Qty', const Color(0xFF993C1D), Icons.edit_outlined, () {
                  setState(() {
                    ov.showQtyPanel = !ov.showQtyPanel;
                    ov.qtyDraft = (ov.receivedQty > 0 ? ov.receivedQty : (qty > 1 ? qty - 1 : 1));
                  });
                })),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: _ActionBtn('Wrong Item', const Color(0xFFB42318), Icons.close_rounded, () => _setState(id, 'wrong'))),
                const SizedBox(width: 8),
                Expanded(child: _ActionBtn('Not Coming', const Color(0xFF5A5A57), Icons.block_outlined, () => _setState(id, 'not_coming'))),
              ]),
              if (ov.showQtyPanel) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: _kBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: _kBorder)),
                  child: Column(children: [
                    const Text('How many did you receive?', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _kText)),
                    const SizedBox(height: 10),
                    _QtyStepper(
                      value: ov.qtyDraft,
                      max: qty - 1,
                      onChanged: (v) => setState(() => ov.qtyDraft = v),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      height: 40,
                      child: FilledButton(
                        onPressed: () => _setState(id, 'short', qty: ov.qtyDraft),
                        style: FilledButton.styleFrom(backgroundColor: const Color(0xFF993C1D), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                        child: Text('Confirm Short (${ov.qtyDraft}/$qty)', style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ]),
                ),
              ],
            ]),
          ),
        ] else if (ov.state != 'not_coming' && ov.state != 'wrong') ...[
          // Allow undo on received
          const Divider(height: 1, color: _kBorder),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              const Spacer(),
              TextButton.icon(
                onPressed: () => _setState(id, 'pending'),
                icon: const Icon(Icons.undo_rounded, size: 15),
                label: const Text('Undo', style: TextStyle(fontSize: 13)),
                style: TextButton.styleFrom(foregroundColor: _kSub),
              ),
            ]),
          ),
        ],
      ]),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;
  final VoidCallback onTap;
  const _ActionBtn(this.label, this.color, this.icon, this.onTap);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color)),
        ]),
      ),
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
        title: const Text('Ship Order', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _kText)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Bag ${bag['bag_no'] ?? ''} — ${bag['pharmacy_name'] ?? ''}', style: const TextStyle(fontSize: 14, color: _kSub)),
          const SizedBox(height: 12),
          if (canPartial)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: _kPendingBg, borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                const Icon(Icons.warning_amber_rounded, size: 16, color: _kPendingFg),
                const SizedBox(width: 8),
                const Expanded(child: Text('Some items are short or not coming.', style: TextStyle(fontSize: 13, color: _kPendingFg))),
              ]),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: _kSub))),
          if (canPartial)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'partial'),
              child: const Text('Ship Partial', style: TextStyle(color: Color(0xFF993C1D), fontWeight: FontWeight.w700)),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'full'),
            style: FilledButton.styleFrom(backgroundColor: _kGreen, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
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
        Text('Error loading bags', style: const TextStyle(color: Color(0xFFDC2626))),
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
        // Header row
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
                decoration: BoxDecoration(color: _kBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: _kBorder)),
                alignment: Alignment.center,
                child: Text('B$bagNo', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _kGreen)),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(pharmacyName, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _kText), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Row(children: [
                  _OrderStatusBadge(status),
                  const SizedBox(width: 8),
                  Text('$receivedCount/$totalCount ready', style: const TextStyle(fontSize: 12, color: _kSub)),
                  if (shortCount > 0) ...[
                    const SizedBox(width: 6),
                    Text('$shortCount short', style: const TextStyle(fontSize: 12, color: _kShortFg, fontWeight: FontWeight.w600)),
                  ],
                  if (notComingCount > 0) ...[
                    const SizedBox(width: 6),
                    Text('$notComingCount N/A', style: const TextStyle(fontSize: 12, color: _kNotComingFg, fontWeight: FontWeight.w600)),
                  ],
                ]),
              ])),
              Icon(isExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded, color: _kSub),
            ]),
          ),
        ),

        // Ship button
        if (!isShipped && canShip) ...[
          const Divider(height: 1, color: _kBorder),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: SizedBox(
              width: double.infinity,
              height: 44,
              child: FilledButton.icon(
                onPressed: isShipping ? null : () => _showShipDialog(bag),
                icon: isShipping
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.local_shipping_outlined, size: 18),
                label: Text(isShipping ? 'Shipping…' : 'Ship Order', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                style: FilledButton.styleFrom(
                  backgroundColor: _kGreen,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ),
        ],

        // Expanded pick list
        if (isExpanded) ...[
          const Divider(height: 1, color: _kBorder),
          if (_loadingBag[orderId] == true)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2)),
            )
          else if (_bagItems[orderId]?.isEmpty ?? true)
            const Padding(padding: EdgeInsets.all(16), child: Text('No items', style: TextStyle(color: _kSub, fontSize: 13)))
          else
            ...(_bagItems[orderId]!.map((item) => _buildPickItem(item))),
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
          Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _kText), maxLines: 1, overflow: TextOverflow.ellipsis),
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
  final _receiveKey = GlobalKey<_ReceiveScreenState>();
  final _packKey = GlobalKey<_PackScreenState>();

  @override
  void initState() {
    super.initState();
    RenderLog.write('fulfillment_area_mounted', 'true');
  }

  void _onFocus() {
    // Called when admin nav routes to this screen; no-op needed (IndexedStack keeps both alive).
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      // Header + segmented control
      Container(
        color: _kCard,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Fulfillment', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: _kText)),
          const SizedBox(height: 12),
          Row(children: [
            _TabBtn('Receive', _tab == 0, () => setState(() => _tab = 0)),
            const SizedBox(width: 8),
            _TabBtn('Pack & Ship', _tab == 1, () => setState(() => _tab = 1)),
          ]),
          const SizedBox(height: 1),
          const Divider(height: 1, color: _kBorder),
        ]),
      ),

      // Both screens always mounted (IndexedStack keeps keys firing on admin page load)
      Expanded(
        child: IndexedStack(
          index: _tab,
          children: [
            _ReceiveScreen(key: _receiveKey),
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
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : _kSub,
          ),
        ),
      ),
    );
  }
}
