import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';

class AdminOffersScreen extends StatefulWidget {
  const AdminOffersScreen({super.key});

  @override
  State<AdminOffersScreen> createState() => _AdminOffersScreenState();
}

class _AdminOffersScreenState extends State<AdminOffersScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;
  final _marginCtrl = TextEditingController();
  bool _savingMargin = false;

  @override
  void initState() {
    super.initState();
    _load();
    RenderLog.write('admin_offers_screen', 'init');
  }

  @override
  void dispose() {
    _marginCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final raw = await Supabase.instance.client.rpc('admin_offers_list');
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

  Future<void> _moderate(int listingId, String action, {String? note}) async {
    try {
      await Supabase.instance.client.rpc('admin_offer_moderate', params: {
        'p_listing_id': listingId, 'p_action': action, 'p_note': note,
      });
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _saveMargin() async {
    final pct = double.tryParse(_marginCtrl.text);
    if (pct == null) return;
    setState(() => _savingMargin = true);
    try {
      await Supabase.instance.client.rpc('admin_offer_margin_set', params: {'p_margin_pct': pct});
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: const Text('Margin updated'), backgroundColor: Ds.c.brand, behavior: SnackBarBehavior.floating));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _savingMargin = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface, elevation: 0,
        title: Text(c('admin_offers_title'), style: Ds.t.title),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(_error!, style: Ds.t.caption.copyWith(color: Ds.c.danger)),
              TextButton(onPressed: _load, child: const Text('Retry')),
            ]))
          : Column(children: [
              _MarginBar(ctrl: _marginCtrl, saving: _savingMargin, onSave: _saveMargin),
              Expanded(
                child: _rows.isEmpty
                  ? Center(child: Text('No listings', style: Ds.t.body.copyWith(color: Ds.c.textSecondary)))
                  : ListView.separated(
                      padding: EdgeInsets.all(Ds.space.x16),
                      itemCount: _rows.length,
                      separatorBuilder: (_, __) => SizedBox(height: Ds.space.x12),
                      itemBuilder: (ctx, i) => _AdminOfferCard(
                        row: _rows[i],
                        onModerate: (action, note) => _moderate(_rows[i]['id'] as int, action, note: note),
                      ),
                    ),
              ),
            ]),
    );
  }
}

class _MarginBar extends StatelessWidget {
  final TextEditingController ctrl;
  final bool saving;
  final VoidCallback onSave;
  const _MarginBar({required this.ctrl, required this.saving, required this.onSave});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Ds.c.surface,
      padding: EdgeInsets.all(Ds.space.x16),
      child: Row(children: [
        Text(c('admin_offer_margin_label'), style: Ds.t.body),
        SizedBox(width: Ds.space.x12),
        SizedBox(
          width: 80,
          child: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              suffixText: '%', isDense: true,
              filled: true, fillColor: Ds.c.bg,
              contentPadding: EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: Ds.space.x8),
              border: OutlineInputBorder(borderRadius: Ds.r.rButton, borderSide: BorderSide(color: Ds.c.divider)),
              enabledBorder: OutlineInputBorder(borderRadius: Ds.r.rButton, borderSide: BorderSide(color: Ds.c.divider)),
              focusedBorder: OutlineInputBorder(borderRadius: Ds.r.rButton, borderSide: BorderSide(color: Ds.c.brand)),
            ),
          ),
        ),
        SizedBox(width: Ds.space.x8),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Ds.c.brand, foregroundColor: Colors.white),
          onPressed: saving ? null : onSave,
          child: saving
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : const Text('Save'),
        ),
      ]),
    );
  }
}

class _AdminOfferCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final Function(String action, String? note) onModerate;
  const _AdminOfferCard({required this.row, required this.onModerate});

  @override
  Widget build(BuildContext context) {
    final statusBg = row['status_bg'] as String? ?? '#F3F4F6';
    final statusFg = row['status_fg'] as String? ?? '#374151';
    final status = row['status'] as String? ?? '';
    final bgColor = Color(int.parse(statusBg.replaceFirst('#', 'FF'), radix: 16));
    final fgColor = Color(int.parse(statusFg.replaceFirst('#', 'FF'), radix: 16));

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
            child: Text(status.toUpperCase(),
              style: Ds.t.caption.copyWith(color: fgColor, fontWeight: FontWeight.w600)),
          ),
        ]),
        Text(row['company'] as String? ?? '', style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
        SizedBox(height: Ds.space.x4),
        Text('Supplier: ${row['supplier_name'] ?? '—'}',
          style: Ds.t.caption.copyWith(color: Ds.c.textSecondary, fontStyle: FontStyle.italic)),
        SizedBox(height: Ds.space.x8),
        Row(children: [
          Text('${row['listing_type'] ?? ''}', style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          const Spacer(),
          Text('Avail: ${row['available_qty'] ?? 0}  Sold: ${row['sold_qty'] ?? 0}', style: Ds.t.caption),
        ]),
        Row(children: [
          if ((row['discount_pct'] as num? ?? 0) > 0)
            Text('${row['discount_pct']}% OFF',
              style: Ds.t.caption.copyWith(color: Ds.c.brand, fontWeight: FontWeight.w600)),
          const Spacer(),
          Text('Margin: ${row['margin_pct'] ?? 0}%', style: Ds.t.caption),
        ]),
        if ((row['moderation_note'] as String? ?? '').isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x4),
            child: Text('Note: ${row['moderation_note']}',
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          ),
        SizedBox(height: Ds.space.x12),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          if (status == 'active')
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Ds.c.danger, side: BorderSide(color: Ds.c.danger)),
              onPressed: () => onModerate('remove', null),
              child: Text(c('admin_offer_remove_btn')),
            )
          else if (status == 'delisted')
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Ds.c.brand, side: BorderSide(color: Ds.c.brand)),
              onPressed: () => onModerate('restore', null),
              child: Text(c('admin_offer_restore_btn')),
            ),
        ]),
      ]),
    );
  }
}
