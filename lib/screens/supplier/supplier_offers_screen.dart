import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';

class SupplierOffersScreen extends StatefulWidget {
  const SupplierOffersScreen({super.key});

  @override
  State<SupplierOffersScreen> createState() => _SupplierOffersScreenState();
}

class _SupplierOffersScreenState extends State<SupplierOffersScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    RenderLog.write('supplier_offers_screen', 'init');
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final raw = await Supabase.instance.client.rpc('supplier_offers_mine');
      final data = Map<String, dynamic>.from((raw is List ? raw.first : raw) as Map);
      if (!(data['ok'] as bool? ?? false)) {
        if (mounted) setState(() { _error = data['error']?.toString(); _loading = false; });
        return;
      }
      final rows = List<Map<String, dynamic>>.from(
        (data['rows'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)));
      if (mounted) setState(() { _rows = rows; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface, elevation: 0,
        title: Text(c('supplier_offers_title'), style: Ds.t.title),
        actions: [IconButton(icon: const Icon(Icons.add), color: Ds.c.brand,
          onPressed: () => _openForm(context, null))],
      ),
      body: RefreshIndicator(color: Ds.c.brand, onRefresh: _load, child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(_error!, style: Ds.t.caption.copyWith(color: Ds.c.danger)),
      TextButton(onPressed: _load, child: const Text('Retry')),
    ]));
    if (_rows.isEmpty) return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.inventory_2_outlined, size: 48, color: Ds.c.textSecondary),
      SizedBox(height: Ds.space.x12),
      Text(c('supplier_offers_empty'), style: Ds.t.body.copyWith(color: Ds.c.textSecondary)),
      SizedBox(height: Ds.space.x16),
      ElevatedButton.icon(
        style: ElevatedButton.styleFrom(backgroundColor: Ds.c.brand, foregroundColor: Colors.white),
        icon: const Icon(Icons.add),
        label: Text(c('offer_list_btn')),
        onPressed: () => _openForm(context, null),
      ),
    ]));
    return ListView.separated(
      padding: EdgeInsets.all(Ds.space.x16),
      itemCount: _rows.length,
      separatorBuilder: (_, __) => SizedBox(height: Ds.space.x12),
      itemBuilder: (ctx, i) => _SupplierListingCard(
        row: _rows[i],
        onEdit: () => _openForm(ctx, _rows[i]),
        onStatusChange: _load),
    );
  }

  void _openForm(BuildContext context, Map<String, dynamic>? existing) {
    showModalBottomSheet(
      context: context, isScrollControlled: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
      builder: (_) => _OfferForm(existing: existing, onSaved: _load),
    );
  }
}

class _SupplierListingCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback onEdit;
  final VoidCallback onStatusChange;
  const _SupplierListingCard({required this.row, required this.onEdit, required this.onStatusChange});

  @override
  Widget build(BuildContext context) {
    final badge = row['status_badge'] as Map? ?? {};
    final bgHex = badge['bg'] as String? ?? '#F3F4F6';
    final fgHex = badge['fg'] as String? ?? '#374151';
    final bgColor = Color(int.parse(bgHex.replaceFirst('#', 'FF'), radix: 16));
    final fgColor = Color(int.parse(fgHex.replaceFirst('#', 'FF'), radix: 16));
    final status = row['status'] as String? ?? '';

    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface, borderRadius: Ds.r.rCard, boxShadow: Ds.elevation.e1),
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(row['product_name'] as String? ?? '',
            style: Ds.t.body.copyWith(fontWeight: FontWeight.w600))),
          Container(
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: Ds.space.x4),
            decoration: BoxDecoration(color: bgColor, borderRadius: Ds.r.rChip),
            child: Text(badge['label'] as String? ?? '',
              style: Ds.t.caption.copyWith(color: fgColor, fontWeight: FontWeight.w600)),
          ),
        ]),
        Text(row['company'] as String? ?? '', style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
        SizedBox(height: Ds.space.x8),
        Row(children: [
          Text(row['type_label'] as String? ?? '', style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          const Spacer(),
          if ((row['scheme_text'] as String? ?? '').isNotEmpty)
            Text(row['scheme_text'] as String,
              style: Ds.t.caption.copyWith(color: Ds.c.brand, fontWeight: FontWeight.w600)),
          if ((row['discount_label'] as String? ?? '').isNotEmpty)
            Text(row['discount_label'] as String,
              style: Ds.t.caption.copyWith(color: Ds.c.brand, fontWeight: FontWeight.w600)),
          if ((row['net_price_display'] as String? ?? '').isNotEmpty)
            Text(row['net_price_display'] as String,
              style: Ds.t.caption.copyWith(color: Ds.c.brand, fontWeight: FontWeight.w600)),
        ]),
        SizedBox(height: Ds.space.x4),
        Row(children: [
          Text('Avail: ${row['available_qty'] ?? 0}  Sold: ${row['sold_qty'] ?? 0}',
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          const Spacer(),
          if ((row['expiry_display'] as String? ?? '').isNotEmpty)
            Text('Exp: ${row['expiry_display']}',
              style: Ds.t.caption.copyWith(color: Ds.c.warning)),
        ]),
        SizedBox(height: Ds.space.x12),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(onPressed: onEdit,
            child: Text(c('offer_edit_title'), style: TextStyle(color: Ds.c.brand))),
          SizedBox(width: Ds.space.x8),
          if (status == 'active')
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Ds.c.warning, side: BorderSide(color: Ds.c.warning)),
              onPressed: () => _updateStatus(context, row['id'], 'paused'),
              child: Text(c('offer_pause_btn')),
            )
          else if (status == 'paused')
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Ds.c.brand, side: BorderSide(color: Ds.c.brand)),
              onPressed: () => _updateStatus(context, row['id'], 'active'),
              child: const Text('Activate'),
            ),
        ]),
      ]),
    );
  }

  Future<void> _updateStatus(BuildContext context, dynamic id, String status) async {
    try {
      await Supabase.instance.client.rpc('supplier_offer_update', params: {'p_id': id, 'p_status': status});
      onStatusChange();
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }
}

class _OfferForm extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final VoidCallback onSaved;
  const _OfferForm({this.existing, required this.onSaved});

  @override
  State<_OfferForm> createState() => _OfferFormState();
}

class _OfferFormState extends State<_OfferForm> {
  final _productIdCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController();
  final _minQtyCtrl = TextEditingController();
  final _ptrCtrl = TextEditingController();
  final _discountCtrl = TextEditingController();
  final _netPriceCtrl = TextEditingController();
  final _buyQtyCtrl = TextEditingController();
  final _freeQtyCtrl = TextEditingController();
  DateTime? _expiryDate;
  DateTime? _endDate;
  String _type = 'discount';
  bool _saving = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _productIdCtrl.text = e['product_id']?.toString() ?? '';
      _qtyCtrl.text = e['available_qty']?.toString() ?? '';
      _minQtyCtrl.text = e['min_order_qty']?.toString() ?? '';
      _ptrCtrl.text = e['offer_ptr']?.toString() ?? '';
      _discountCtrl.text = e['discount_pct']?.toString() ?? '';
      _netPriceCtrl.text = e['net_price']?.toString() ?? '';
      _buyQtyCtrl.text = e['scheme_buy_qty']?.toString() ?? '';
      _freeQtyCtrl.text = e['scheme_free_qty']?.toString() ?? '';
      _type = e['listing_type'] as String? ?? 'discount';
    }
  }

  @override
  void dispose() {
    _productIdCtrl.dispose(); _qtyCtrl.dispose(); _minQtyCtrl.dispose();
    _ptrCtrl.dispose(); _discountCtrl.dispose(); _netPriceCtrl.dispose();
    _buyQtyCtrl.dispose(); _freeQtyCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() { _saving = true; _err = null; });
    try {
      final isEdit = widget.existing != null;
      dynamic raw;
      if (isEdit) {
        raw = await Supabase.instance.client.rpc('supplier_offer_update', params: {
          'p_id': widget.existing!['id'],
          'p_available_qty': double.tryParse(_qtyCtrl.text),
          'p_offer_ptr': _ptrCtrl.text.isNotEmpty ? double.tryParse(_ptrCtrl.text) : null,
          'p_discount_pct': _discountCtrl.text.isNotEmpty ? double.tryParse(_discountCtrl.text) : null,
          'p_net_price': _netPriceCtrl.text.isNotEmpty ? double.tryParse(_netPriceCtrl.text) : null,
          'p_min_order_qty': _minQtyCtrl.text.isNotEmpty ? double.tryParse(_minQtyCtrl.text) : null,
          'p_end_date': _endDate?.toIso8601String().substring(0, 10),
        });
      } else {
        raw = await Supabase.instance.client.rpc('supplier_offer_create', params: {
          'p_product_id': int.tryParse(_productIdCtrl.text),
          'p_listing_type': _type,
          'p_available_qty': double.tryParse(_qtyCtrl.text) ?? 0,
          'p_offer_ptr': _ptrCtrl.text.isNotEmpty ? double.tryParse(_ptrCtrl.text) : null,
          'p_discount_pct': _discountCtrl.text.isNotEmpty ? double.tryParse(_discountCtrl.text) : null,
          'p_net_price': _netPriceCtrl.text.isNotEmpty ? double.tryParse(_netPriceCtrl.text) : null,
          'p_scheme_buy_qty': _buyQtyCtrl.text.isNotEmpty ? double.tryParse(_buyQtyCtrl.text) : null,
          'p_scheme_free_qty': _freeQtyCtrl.text.isNotEmpty ? double.tryParse(_freeQtyCtrl.text) : null,
          'p_batch_expiry_date': _expiryDate?.toIso8601String().substring(0, 10),
          'p_min_order_qty': _minQtyCtrl.text.isNotEmpty ? double.tryParse(_minQtyCtrl.text) : null,
          'p_end_date': _endDate?.toIso8601String().substring(0, 10),
        });
      }
      final data = Map<String, dynamic>.from((raw is List ? raw.first : raw) as Map);
      if (!mounted) return;
      if (data['ok'] == true) {
        widget.onSaved();
        Navigator.pop(context);
      } else {
        setState(() { _err = data['error']?.toString(); _saving = false; });
      }
    } catch (e) {
      if (mounted) setState(() { _err = e.toString(); _saving = false; });
    }
  }

  Widget _field(String label, TextEditingController ctrl, {TextInputType? keyboard}) => Padding(
    padding: EdgeInsets.only(bottom: Ds.space.x12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
      SizedBox(height: Ds.space.x4),
      TextField(
        controller: ctrl,
        keyboardType: keyboard ?? TextInputType.text,
        decoration: InputDecoration(
          filled: true, fillColor: Ds.c.bg,
          contentPadding: EdgeInsets.symmetric(horizontal: Ds.space.x12, vertical: Ds.space.x12),
          border: OutlineInputBorder(borderRadius: Ds.r.rButton, borderSide: BorderSide(color: Ds.c.divider)),
          enabledBorder: OutlineInputBorder(borderRadius: Ds.r.rButton, borderSide: BorderSide(color: Ds.c.divider)),
          focusedBorder: OutlineInputBorder(borderRadius: Ds.r.rButton, borderSide: BorderSide(color: Ds.c.brand)),
        ),
      ),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(c(isEdit ? 'offer_edit_title' : 'offer_create_title'), style: Ds.t.title),
          SizedBox(height: Ds.space.x16),
          if (!isEdit) ...[
            _field(c('offer_type_select'), _productIdCtrl),
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: DropdownButtonFormField<String>(
                value: _type,
                decoration: InputDecoration(
                  labelText: c('offer_type_select'),
                  filled: true, fillColor: Ds.c.bg,
                  border: OutlineInputBorder(borderRadius: Ds.r.rButton),
                ),
                items: const [
                  DropdownMenuItem(value: 'discount', child: Text('Discount')),
                  DropdownMenuItem(value: 'scheme', child: Text('Scheme')),
                  DropdownMenuItem(value: 'near_expiry', child: Text('Near Expiry')),
                ],
                onChanged: (v) => setState(() => _type = v ?? 'discount'),
              ),
            ),
          ],
          _field(c('offer_qty_label'), _qtyCtrl, keyboard: TextInputType.number),
          _field(c('offer_min_qty_label'), _minQtyCtrl, keyboard: TextInputType.number),
          _field(c('offer_ptr_label'), _ptrCtrl, keyboard: TextInputType.number),
          _field(c('offer_discount_label'), _discountCtrl, keyboard: TextInputType.number),
          if (_type == 'scheme') ...[
            _field(c('offer_scheme_buy_label'), _buyQtyCtrl, keyboard: TextInputType.number),
            _field(c('offer_scheme_free_label'), _freeQtyCtrl, keyboard: TextInputType.number),
          ],
          if (_type == 'near_expiry' && !isEdit)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: Row(children: [
                Text(c('offer_expiry_date_label'), style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
                const Spacer(),
                TextButton(
                  onPressed: () async {
                    final d = await showDatePicker(context: context,
                      initialDate: DateTime.now().add(const Duration(days: 30)),
                      firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
                    if (d != null) setState(() => _expiryDate = d);
                  },
                  child: Text(_expiryDate == null
                    ? 'Pick date' : '${_expiryDate!.day}/${_expiryDate!.month}/${_expiryDate!.year}'),
                ),
              ]),
            ),
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x12),
            child: Row(children: [
              Text(c('offer_end_date_label'), style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
              const Spacer(),
              TextButton(
                onPressed: () async {
                  final d = await showDatePicker(context: context,
                    initialDate: DateTime.now().add(const Duration(days: 7)),
                    firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
                  if (d != null) setState(() => _endDate = d);
                },
                child: Text(_endDate == null
                  ? 'No end date' : '${_endDate!.day}/${_endDate!.month}/${_endDate!.year}'),
              ),
            ]),
          ),
          if (_err != null)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: Text(_err!, style: Ds.t.caption.copyWith(color: Ds.c.danger)),
            ),
          SizedBox(
            width: double.infinity, height: 48,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Ds.c.brand, foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton)),
              onPressed: _saving ? null : _save,
              child: _saving
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : Text(c(isEdit ? 'offer_save_btn' : 'offer_submit_btn')),
            ),
          ),
          SizedBox(height: Ds.space.x24),
        ]),
      ),
    );
  }
}
