import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';

class OffersScreen extends StatefulWidget {
  const OffersScreen({super.key});

  @override
  State<OffersScreen> createState() => _OffersScreenState();
}

class _OffersScreenState extends State<OffersScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;
  bool _hasMore = false;
  int _offset = 0;
  static const _limit = 20;

  @override
  void initState() {
    super.initState();
    _load();
    RenderLog.write('offers_screen', 'init');
  }

  Future<void> _load({bool append = false}) async {
    if (!append) setState(() { _loading = true; _error = null; });
    try {
      final raw = await Supabase.instance.client.rpc('offers_feed', params: {
        'p_offset': append ? _offset : 0,
        'p_limit': _limit,
      });
      final data = Map<String, dynamic>.from((raw is List ? raw.first : raw) as Map);
      if (!(data['ok'] as bool? ?? false)) {
        if (mounted) setState(() { _error = data['error']?.toString(); _loading = false; });
        return;
      }
      final rows = List<Map<String, dynamic>>.from(
        (data['rows'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)));
      if (mounted) setState(() {
        _rows = append ? [..._rows, ...rows] : rows;
        _hasMore = data['has_more'] == true;
        _offset = (append ? _offset : 0) + rows.length;
        _loading = false;
      });
      RenderLog.write('offers_rows', _rows.length);
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      body: RefreshIndicator(
        color: Ds.c.brand,
        onRefresh: () async { _offset = 0; await _load(); },
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _rows.isEmpty) {
      return ListView(children: [
        SizedBox(height: MediaQuery.sizeOf(context).height * 0.35),
        const Center(child: CircularProgressIndicator()),
      ]);
    }
    if (_error != null && _rows.isEmpty) {
      return ListView(children: [
        SizedBox(height: MediaQuery.sizeOf(context).height * 0.3),
        Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.error_outline, color: Ds.c.danger, size: 40),
          SizedBox(height: Ds.space.x12),
          Text(_error!, style: Ds.t.caption.copyWith(color: Ds.c.danger), textAlign: TextAlign.center),
          SizedBox(height: Ds.space.x16),
          TextButton(onPressed: () => _load(), child: const Text('Retry')),
        ])),
      ]);
    }
    if (_rows.isEmpty) {
      return ListView(children: [
        SizedBox(height: MediaQuery.sizeOf(context).height * 0.3),
        Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.local_offer_outlined, color: Ds.c.textSecondary, size: 48),
          SizedBox(height: Ds.space.x12),
          Text(c('offers_feed_empty'), style: Ds.t.body.copyWith(color: Ds.c.textSecondary)),
        ])),
      ]);
    }
    return ListView.separated(
      padding: EdgeInsets.all(Ds.space.x16),
      itemCount: _rows.length + (_hasMore ? 1 : 0),
      separatorBuilder: (_, __) => SizedBox(height: Ds.space.x12),
      itemBuilder: (context, i) {
        if (i == _rows.length) {
          return Padding(
            padding: EdgeInsets.symmetric(vertical: Ds.space.x16),
            child: Center(
              child: TextButton(
                onPressed: () => _load(append: true),
                child: Text('Load more', style: TextStyle(color: Ds.c.brand)),
              ),
            ),
          );
        }
        return _OfferCard(row: _rows[i], onAdded: () => _load());
      },
    );
  }
}

class _OfferCard extends StatefulWidget {
  final Map<String, dynamic> row;
  final VoidCallback onAdded;
  const _OfferCard({required this.row, required this.onAdded});

  @override
  State<_OfferCard> createState() => _OfferCardState();
}

class _OfferCardState extends State<_OfferCard> {
  bool _adding = false;

  Future<void> _addToCart() async {
    final row = widget.row;
    if (row['sold_out'] == true) return;
    if (row['requires_disclosure'] == true) {
      final accepted = await _showDisclosureModal();
      if (!accepted) return;
    }
    setState(() => _adding = true);
    try {
      final raw = await Supabase.instance.client.rpc('offer_add_to_cart', params: {
        'p_listing_id': row['id'],
        'p_qty': row['min_order_qty'] ?? 1,
      });
      final data = Map<String, dynamic>.from((raw is List ? raw.first : raw) as Map);
      if (!mounted) return;
      final ok = data['ok'] == true;
      final msg = data['message']?.toString() ?? (ok ? 'Added' : data['error']?.toString() ?? 'Error');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg), behavior: SnackBarBehavior.floating,
        backgroundColor: ok ? Ds.c.brand : Ds.c.danger));
      if (ok) widget.onAdded();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString()), behavior: SnackBarBehavior.floating));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<bool> _showDisclosureModal() async {
    return await showModalBottomSheet<bool>(
      context: context,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
      builder: (_) => Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c('offer_near_expiry_title'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          Text(c('offer_near_expiry_disclosure'), style: Ds.t.body.copyWith(color: Ds.c.textSecondary)),
          SizedBox(height: Ds.space.x24),
          SizedBox(
            width: double.infinity, height: 48,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Ds.c.brand, foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton)),
              onPressed: () => Navigator.pop(context, true),
              child: Text(c('offer_near_expiry_accept')),
            ),
          ),
          SizedBox(height: Ds.space.x8),
          SizedBox(width: double.infinity,
            child: TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel'))),
        ]),
      ),
    ) ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final badge = row['type_badge'] as Map? ?? {};
    final soldOut = row['sold_out'] == true;
    final qtyLow = row['qty_low'] == true;
    final bgHex = badge['bg'] as String? ?? '#EFF6FF';
    final fgHex = badge['fg'] as String? ?? '#1E40AF';
    final bgColor = Color(int.parse(bgHex.replaceFirst('#', 'FF'), radix: 16));
    final fgColor = Color(int.parse(fgHex.replaceFirst('#', 'FF'), radix: 16));

    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (badge.isNotEmpty)
            Container(
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: Ds.space.x4),
              decoration: BoxDecoration(color: bgColor, borderRadius: Ds.r.rChip),
              child: Text(badge['label'] as String? ?? '',
                style: Ds.t.caption.copyWith(color: fgColor, fontWeight: FontWeight.w600)),
            ),
          const Spacer(),
          if ((row['discount_label'] as String? ?? '').isNotEmpty)
            Text(row['discount_label'] as String,
              style: Ds.t.caption.copyWith(color: Ds.c.brand, fontWeight: FontWeight.w700)),
        ]),
        SizedBox(height: Ds.space.x8),
        Text(row['product_name'] as String? ?? '',
          style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
        if ((row['company'] as String? ?? '').isNotEmpty)
          Text(row['company'] as String, style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
        if ((row['pack'] as String? ?? '').isNotEmpty)
          Text(row['pack'] as String, style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
        SizedBox(height: Ds.space.x8),
        Row(children: [
          if ((row['price_display'] as String? ?? '').isNotEmpty)
            Text(row['price_display'] as String,
              style: Ds.t.subtitle.copyWith(color: Ds.c.brand, fontWeight: FontWeight.w700)),
          SizedBox(width: Ds.space.x8),
          if ((row['mrp_display'] as String? ?? '').isNotEmpty)
            Text(row['mrp_display'] as String,
              style: Ds.t.caption.copyWith(
                decoration: TextDecoration.lineThrough, color: Ds.c.textSecondary)),
        ]),
        if ((row['scheme_text'] as String? ?? '').isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x4),
            child: Text(row['scheme_text'] as String,
              style: Ds.t.caption.copyWith(color: Ds.c.brand, fontWeight: FontWeight.w600)),
          ),
        if ((row['near_expiry_label'] as String? ?? '').isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x4),
            child: Text(row['near_expiry_label'] as String,
              style: Ds.t.caption.copyWith(color: Ds.c.warning)),
          ),
        SizedBox(height: Ds.space.x12),
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(row['qty_display'] as String? ?? '',
              style: Ds.t.caption.copyWith(
                color: qtyLow ? Ds.c.warning : Ds.c.textSecondary)),
            if ((row['seller_display'] as String? ?? '').isNotEmpty)
              Text(row['seller_display'] as String,
                style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          ])),
          SizedBox(
            height: 44,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: soldOut ? Ds.c.divider : Ds.c.brand,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
              ),
              onPressed: soldOut || _adding ? null : _addToCart,
              child: _adding
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : Text(soldOut ? 'Sold Out' : 'Add to Cart'),
            ),
          ),
        ]),
      ]),
    );
  }
}
