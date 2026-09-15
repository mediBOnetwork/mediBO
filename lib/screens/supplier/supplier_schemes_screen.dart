import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';

/// CHANGE #461 / feature_gaps #169 — the supplier's scheme book.
///
/// `supplier_schemes` had zero rows and no way to file one, while
/// `cart_apply_schemes()`, `cart_scheme_nudge()` and the card fields
/// `has_scheme` / `scheme_badge` / `scheme_text` / `scheme_expiry` /
/// `scheme_effective` were all live and all empty — so no buyer had ever seen
/// a scheme. Free goods (10+2, 5+1) are the primary commercial lever in pharma
/// distribution, and this is the surface that files them.
///
/// The screen computes nothing. Every row, every label, every state chip and
/// both of its tone colours come from `supplier_schemes_list()`; saving is
/// `supplier_scheme_save()`, which validates the window and the quantities and
/// syncs the live scheme onto the product the card reads.
class SupplierSchemesScreen extends StatefulWidget {
  const SupplierSchemesScreen({super.key});

  @override
  State<SupplierSchemesScreen> createState() => _SupplierSchemesScreenState();
}

class _SupplierSchemesScreenState extends State<SupplierSchemesScreen> {
  Map<String, dynamic> _payload = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.rpc('supplier_schemes_list');
      final map = (res is List ? (res.isEmpty ? null : res.first) : res);
      if (!mounted) return;
      setState(() {
        _payload = map is Map ? map.cast<String, dynamic>() : const {};
        _loading = false;
      });
      RenderLog.write('c461_scheme_rows', _rows.length);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _rows =>
      ((_payload['rows'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();

  Future<void> _delete(Map<String, dynamic> row) async {
    try {
      final res = await Supabase.instance.client
          .rpc('supplier_scheme_delete', params: {'p_id': row['id']});
      final map = (res is List ? (res.isEmpty ? null : res.first) : res);
      final m = map is Map ? map.cast<String, dynamic>() : const {};
      if (!mounted) return;
      final toast = (m['toast'] ?? m['error'] ?? '').toString();
      if (toast.isNotEmpty) showToast(context, toast, isError: m['ok'] != true);
      await _load();
    } catch (_) {/* the list reload is the only feedback that matters */}
  }

  Future<void> _openEditor([Map<String, dynamic>? row]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => _SchemeEditorSheet(row: row),
    );
    if (saved == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final title = (_payload['title'] ?? '').toString();
    final emptyNote = (_payload['empty_note'] ?? '').toString();

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(title), backgroundColor: Ds.c.surface),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Ds.c.brand,
        onPressed: () => _openEditor(),
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const _SchemeSkeleton()
          : _rows.isEmpty
              ? Center(
                  child: Padding(
                    padding: EdgeInsets.all(Ds.space.x24),
                    child: Text(emptyNote,
                        textAlign: TextAlign.center, style: Ds.t.bodySecondary),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: EdgeInsets.all(Ds.space.x16),
                    itemCount: _rows.length,
                    separatorBuilder: (_, __) => SizedBox(height: Ds.space.x12),
                    itemBuilder: (_, i) => _SchemeCard(
                      row: _rows[i],
                      onEdit: () => _openEditor(_rows[i]),
                      onDelete: () => _delete(_rows[i]),
                    ),
                  ),
                ),
    );
  }
}

class _SchemeSkeleton extends StatelessWidget {
  const _SchemeSkeleton();

  @override
  Widget build(BuildContext context) => ListView.separated(
        padding: EdgeInsets.all(Ds.space.x16),
        itemCount: 4,
        separatorBuilder: (_, __) => SizedBox(height: Ds.space.x12),
        itemBuilder: (_, __) => Container(
          height: Ds.space.x48 + Ds.space.x24,
          decoration: BoxDecoration(
              color: Ds.c.surface, borderRadius: Ds.r.rCard),
        ),
      );
}

/// One filed scheme, printed verbatim.
class _SchemeCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _SchemeCard(
      {required this.row, required this.onEdit, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final tone = (row['state_tone'] as Map?)?.cast<String, dynamic>();
    final window = (row['window_label'] ?? '').toString();

    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text((row['product_name'] ?? '').toString(),
                    style: Ds.t.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ),
              SizedBox(width: Ds.space.x8),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x8, vertical: Ds.space.x4 / 2),
                decoration: BoxDecoration(
                  color: Ds.hex(tone?['bg'], Ds.c.infoSoft),
                  borderRadius: Ds.r.rChip,
                ),
                child: Text((row['state_label'] ?? '').toString(),
                    style: Ds.t.caption
                        .copyWith(color: Ds.hex(tone?['fg'], Ds.c.text))),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Text((row['text'] ?? '').toString(), style: Ds.t.body),
          if (window.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(window, style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: onEdit, child: const Icon(Icons.edit_outlined)),
              TextButton(
                onPressed: onDelete,
                child: Icon(Icons.delete_outline, color: Ds.c.danger),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The filing sheet. It sends what the supplier typed; every refusal
/// (`invalid_window`, `qty_required`, `product_required`) is decided and
/// worded by `supplier_scheme_save()`.
class _SchemeEditorSheet extends StatefulWidget {
  final Map<String, dynamic>? row;
  const _SchemeEditorSheet({this.row});

  @override
  State<_SchemeEditorSheet> createState() => _SchemeEditorSheetState();
}

class _SchemeEditorSheetState extends State<_SchemeEditorSheet> {
  late final TextEditingController _productId;
  late final TextEditingController _productName;
  late final TextEditingController _orderQty;
  late final TextEditingController _freeQty;
  late final TextEditingController _discountPct;
  late final TextEditingController _specialPrice;
  String _type = 'free_goods';
  DateTime? _from;
  DateTime? _to;
  bool _saving = false;

  String _v(Object? o) => o == null ? '' : o.toString();

  @override
  void initState() {
    super.initState();
    final r = widget.row ?? const {};
    _productId = TextEditingController(text: _v(r['product_id']));
    _productName = TextEditingController(text: _v(r['product_name']));
    _orderQty = TextEditingController(text: _v(r['order_qty']));
    _freeQty = TextEditingController(text: _v(r['free_qty']));
    _discountPct = TextEditingController(text: _v(r['discount_pct']));
    _specialPrice = TextEditingController(text: _v(r['special_price']));
    _type = _v(r['scheme_type']).isEmpty ? 'free_goods' : _v(r['scheme_type']);
    _from = DateTime.tryParse(_v(r['valid_from']));
    _to = DateTime.tryParse(_v(r['valid_to']));
  }

  @override
  void dispose() {
    _productId.dispose();
    _productName.dispose();
    _orderQty.dispose();
    _freeQty.dispose();
    _discountPct.dispose();
    _specialPrice.dispose();
    super.dispose();
  }

  String? _iso(DateTime? d) => d == null
      ? null
      : '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';

  Future<void> _pick(bool isFrom) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: (isFrom ? _from : _to) ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
    );
    if (picked != null) setState(() => isFrom ? _from = picked : _to = picked);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final res = await Supabase.instance.client.rpc(
        'supplier_scheme_save',
        params: {
          'p_id': widget.row?['id'],
          'p_product_id': int.tryParse(_productId.text.trim()),
          'p_product_name': _productName.text.trim(),
          'p_scheme_type': _type,
          'p_order_qty': num.tryParse(_orderQty.text.trim()),
          'p_free_qty': num.tryParse(_freeQty.text.trim()),
          'p_discount_pct': num.tryParse(_discountPct.text.trim()),
          'p_special_price': num.tryParse(_specialPrice.text.trim()),
          'p_valid_from': _iso(_from),
          'p_valid_to': _iso(_to),
          'p_active': true,
        },
      );
      final raw = (res is List ? (res.isEmpty ? null : res.first) : res);
      final m = raw is Map ? raw.cast<String, dynamic>() : const {};
      if (!mounted) return;
      if (m['ok'] == true) {
        final toast = (m['toast'] ?? '').toString();
        if (toast.isNotEmpty) showToast(context, toast);
        Navigator.of(context).pop(true);
      } else {
        setState(() => _saving = false);
        showToast(context, (m['error'] ?? '').toString(), isError: true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showToast(context, e.toString(), isError: true);
    }
  }

  Widget _field(TextEditingController c, String hint, {bool numeric = false}) =>
      Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x12),
        child: TextField(
          controller: c,
          keyboardType: numeric ? TextInputType.number : TextInputType.text,
          decoration: InputDecoration(
            labelText: hint,
            filled: true,
            fillColor: Ds.c.bg,
            border: OutlineInputBorder(borderRadius: Ds.r.rButton),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Ds.space.x16,
        Ds.space.x16,
        Ds.space.x16,
        Ds.space.x16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _field(_productId, 'Product id', numeric: true),
            _field(_productName, 'Product name'),
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: InputDecoration(
                filled: true,
                fillColor: Ds.c.bg,
                border: OutlineInputBorder(borderRadius: Ds.r.rButton),
              ),
              items: const [
                DropdownMenuItem(value: 'free_goods', child: Text('Free goods')),
                DropdownMenuItem(value: 'discount_pct', child: Text('Discount %')),
                DropdownMenuItem(value: 'special_price', child: Text('Special price')),
              ],
              onChanged: (v) => setState(() => _type = v ?? 'free_goods'),
            ),
            SizedBox(height: Ds.space.x12),
            if (_type == 'free_goods') ...[
              _field(_orderQty, 'Buy qty', numeric: true),
              _field(_freeQty, 'Free qty', numeric: true),
            ],
            if (_type == 'discount_pct') _field(_discountPct, 'Discount %', numeric: true),
            if (_type == 'special_price') _field(_specialPrice, 'Special price', numeric: true),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _pick(true),
                  child: Text(_iso(_from) ?? 'Valid from'),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _pick(false),
                  child: Text(_iso(_to) ?? 'Valid to'),
                ),
              ),
            ]),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              height: Ds.touch.minTarget,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
                onPressed: _saving ? null : _save,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
