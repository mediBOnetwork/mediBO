import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_state.dart';
import '../design_tokens.dart';
import '../services/ui_copy.dart';
import '../utils/render_log.dart';
import '../utils/toast.dart';

class WishlistScreen extends StatefulWidget {
  const WishlistScreen({super.key});

  @override
  State<WishlistScreen> createState() => _WishlistScreenState();
}

class _WishlistScreenState extends State<WishlistScreen> {
  Map<String, dynamic>? _payload;
  bool _loading = true;
  bool _error = false;
  final Set<String> _removing = {};
  final Set<String> _adding = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = false; });
    try {
      final raw = await Supabase.instance.client.rpc('wishlist_get');
      final p = raw is Map
          ? Map<String, dynamic>.from(raw)
          : (raw is List && raw.isNotEmpty
              ? Map<String, dynamic>.from(raw.first as Map)
              : <String, dynamic>{});
      if (mounted) setState(() { _payload = p; _loading = false; });
      RenderLog.write('wishlist_screen', 'loaded:${_items(p).length}');
    } catch (_) {
      if (mounted) setState(() { _error = true; _loading = false; });
    }
  }

  List<Map<String, dynamic>> _items(Map<String, dynamic>? p) {
    final raw = p?['items'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  String _s(Map<String, dynamic>? p, String key) =>
      (p?[key] ?? '').toString();

  Future<void> _remove(String productId) async {
    if (_removing.contains(productId)) return;
    setState(() => _removing.add(productId));
    try {
      await Supabase.instance.client
          .rpc('wishlist_remove', params: {'p_product_id': int.parse(productId)});
      if (mounted) {
        showToast(context, c('wishlist.remove_toast'));
        await _load();
      }
    } catch (_) {
      if (mounted) setState(() => _removing.remove(productId));
    }
  }

  void _addToCart(String productId) {
    if (_adding.contains(productId)) return;
    setState(() => _adding.add(productId));
    try {
      AppState.of(context).addId(productId);
      showToast(context, c('wishlist.cart_toast'));
    } finally {
      if (mounted) setState(() => _adding.remove(productId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload;
    final items = _items(p);

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new, size: 20, color: Ds.c.brand),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          _loading || p == null ? c('wishlist.title') : _s(p, 'title'),
          style: Ds.t.title,
        ),
        centerTitle: false,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: Ds.c.divider),
        ),
      ),
      body: _buildBody(p, items),
    );
  }

  Widget _buildBody(Map<String, dynamic>? p, List<Map<String, dynamic>> items) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Ds.c.brand, strokeWidth: 2.5),
            SizedBox(height: Ds.space.x12),
            Text(c('wishlist.loading'), style: Ds.t.caption),
          ],
        ),
      );
    }

    if (_error) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi_off_rounded, size: 48, color: Ds.c.textSecondary),
              SizedBox(height: Ds.space.x16),
              Text(c('wishlist.error_title'),
                  style: Ds.t.subtitle, textAlign: TextAlign.center),
              SizedBox(height: Ds.space.x8),
              TextButton(
                onPressed: _load,
                child: Text(c('wishlist.retry_btn'),
                    style: TextStyle(color: Ds.c.brand,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      );
    }

    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.favorite_border_rounded,
                  size: 56, color: Ds.c.textSecondary),
              SizedBox(height: Ds.space.x16),
              Text(
                _s(p, 'empty_title'),
                style: Ds.t.subtitle,
                textAlign: TextAlign.center,
              ),
              SizedBox(height: Ds.space.x8),
              Text(
                _s(p, 'empty_body'),
                style: Ds.t.caption,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final countLabel = _s(p, 'count_label');

    return RefreshIndicator(
      color: Ds.c.brand,
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16, vertical: Ds.space.x16),
        children: [
          if (countLabel.isNotEmpty) ...[
            Text(countLabel,
                style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
            SizedBox(height: Ds.space.x12),
          ],
          ...items.map((item) => _WishlistCard(
                item: item,
                removing: _removing.contains(item['product_id']?.toString() ?? ''),
                adding: _adding.contains(item['product_id']?.toString() ?? ''),
                onRemove: () => _remove(item['product_id']?.toString() ?? ''),
                onAddToCart: () => _addToCart(item['product_id']?.toString() ?? ''),
              )),
        ],
      ),
    );
  }
}

class _WishlistCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool removing;
  final bool adding;
  final VoidCallback onRemove;
  final VoidCallback onAddToCart;

  const _WishlistCard({
    required this.item,
    required this.removing,
    required this.adding,
    required this.onRemove,
    required this.onAddToCart,
  });

  String _s(String key) => (item[key] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final canAdd = item['can_add'] == true;
    final ctaLabel = _s('cta_label').isNotEmpty ? _s('cta_label') : c('wishlist.add_cart_btn');

    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x12),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _thumbnail(),
            SizedBox(width: Ds.space.x12),
            Expanded(child: _info(canAdd, ctaLabel)),
          ],
        ),
      ),
    );
  }

  Widget _thumbnail() {
    final url = _s('image_url');
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        color: Ds.c.bg,
        borderRadius: BorderRadius.circular(Ds.r.button),
      ),
      clipBehavior: Clip.antiAlias,
      child: url.isNotEmpty
          ? Image.network(url, fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => _placeholderIcon())
          : _placeholderIcon(),
    );
  }

  Widget _placeholderIcon() => Center(
        child: Icon(Icons.medication_outlined,
            size: 28, color: Ds.c.textSecondary),
      );

  Widget _info(bool canAdd, String ctaLabel) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _s('name'),
          style: Ds.t.body.copyWith(fontWeight: FontWeight.w600),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (_s('company').isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(_s('company'), style: Ds.t.caption, maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ],
        if (_s('pack_label').isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(_s('pack_label'), style: Ds.t.caption),
        ],
        if (_s('price_display').isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(_s('price_display'),
              style: Ds.t.body.copyWith(
                  color: Ds.c.brand, fontWeight: FontWeight.w700)),
        ],
        SizedBox(height: Ds.space.x12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: removing ? null : onRemove,
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Ds.c.divider),
                  shape: RoundedRectangleBorder(
                      borderRadius: Ds.r.rButton),
                  padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
                  minimumSize: const Size(0, 40),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: removing
                    ? SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Ds.c.textSecondary))
                    : Text(c('wishlist.remove_btn'),
                        style: TextStyle(
                            color: Ds.c.textSecondary,
                            fontSize: Ds.t.captionSize,
                            fontWeight: FontWeight.w600)),
              ),
            ),
            SizedBox(width: Ds.space.x8),
            Expanded(
              flex: 2,
              child: ElevatedButton(
                onPressed: (canAdd && !adding) ? onAddToCart : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  disabledBackgroundColor: Ds.c.divider,
                  foregroundColor: Ds.c.surface,
                  shape: RoundedRectangleBorder(
                      borderRadius: Ds.r.rButton),
                  padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
                  elevation: 0,
                  minimumSize: const Size(0, 40),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: adding
                    ? SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Ds.c.surface))
                    : Text(ctaLabel,
                        style: TextStyle(
                            fontSize: Ds.t.captionSize,
                            fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
