import 'dart:async';

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

  /// CMD #410 — `wishlist_alerts()`: what has changed on these products since
  /// the customer saved them. The same events the daily digest reports, shown
  /// in the app so the alert has somewhere to land when the push is dismissed.
  /// Every chip, tone and figure in it is the backend's; an unentitled viewer
  /// gets the fact that a rate moved with NO number, because a trade rate is
  /// gated the same way here as it is on a product card.
  Map<String, dynamic>? _alerts;

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
      unawaited(_loadAlerts());
    } catch (_) {
      if (mounted) setState(() { _error = true; _loading = false; });
    }
  }

  /// A failure here leaves the wishlist itself untouched: the alert strip is
  /// an addition to the page, never a gate on it.
  Future<void> _loadAlerts() async {
    try {
      final raw = await Supabase.instance.client.rpc('wishlist_alerts');
      if (raw is! Map) return;
      if (!mounted) return;
      setState(() => _alerts = Map<String, dynamic>.from(raw));
      RenderLog.write('c410_wishlist_alerts',
          '${(Map<String, dynamic>.from(raw)['items'] as List?)?.length ?? 0}');
    } catch (_) {
      // Keep the wishlist on screen.
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
          // CMD #410 — the price/stock alert strip. `has` is the backend's
          // verdict; with nothing to report there is no strip at all, not an
          // empty box.
          if (_alerts?['has'] == true) ...[
            _AlertStrip(payload: _alerts!),
            SizedBox(height: Ds.space.x24),
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


/// CMD #410 — the wishlist's price and stock alerts.
///
/// One card, one line per event, every string out of `wishlist_alerts()`: the
/// heading, the footnote about the once-a-day digest, each chip's label and
/// the "from X to Y" detail. The widget picks the colour from the backend's
/// own `tone` word and prints the rest.
///
/// `has_detail` is why there is no formatting here: a viewer who is not
/// entitled to trade prices is told a rate CHANGED and shown no figure, and
/// that decision is made once, in SQL, next to the price block that makes the
/// same decision for every card in the app.
class _AlertStrip extends StatelessWidget {
  final Map<String, dynamic> payload;
  const _AlertStrip({required this.payload});

  static String _s(Object? v) => v?.toString() ?? '';

  Color _tone(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.success;
      case 'warning':
        return Ds.c.warning;
      case 'danger':
        return Ds.c.danger;
      default:
        return Ds.c.info;
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = (payload['items'] as List?)
            ?.whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList() ??
        const <Map<String, dynamic>>[];

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(payload['title']), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          for (final a in items) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x8, vertical: Ds.space.x4),
                  decoration: BoxDecoration(
                    color: _tone(_s(a['tone'])).withValues(alpha: 0.12),
                    borderRadius: Ds.r.rChip,
                  ),
                  child: Text(
                    _s(a['label']),
                    style: Ds.t.caption.copyWith(
                        color: _tone(_s(a['tone'])),
                        fontWeight: FontWeight.w500),
                  ),
                ),
                SizedBox(width: Ds.space.x8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_s(a['name']),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Ds.t.body),
                      // Absent unless the backend said this viewer may see the
                      // figure. There is no Dart fallback that prints it anyway.
                      if (a['has_detail'] == true)
                        Text(_s(a['detail']), style: Ds.t.caption),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: Ds.space.x12),
          ],
          Text(_s(payload['note']), style: Ds.t.caption),
        ],
      ),
    );
  }
}
