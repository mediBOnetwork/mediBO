import 'supplier_shop_entries.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import 'supplier_schemes_screen.dart';
import 'supplier_scorecard_inbox.dart'; // #465 rows 64/65

class SupplierHomeScreen extends StatefulWidget {
  final String? viewAsSupplierId;
  const SupplierHomeScreen({super.key, this.viewAsSupplierId});

  @override
  State<SupplierHomeScreen> createState() => _SupplierHomeScreenState();
}

class _SupplierHomeScreenState extends State<SupplierHomeScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  List<Map<String, dynamic>> _items = [];
  bool _loading = false;
  bool _hasMore = true;
  String _currentSearch = '';
  Timer? _debounce;
  static const int _pageSize = 24;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollCtrl.position.pixels >= _scrollCtrl.position.maxScrollExtent - 200) {
      if (_hasMore && !_loading) _load();
    }
  }

  void _onSearchChanged(String val) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (val != _currentSearch) {
        _currentSearch = val;
        _load(reset: true);
      }
    });
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    if (reset) {
      setState(() { _items = []; _hasMore = true; });
    }
    if (!_hasMore) return;
    setState(() => _loading = true);
    try {
      final offset = reset ? 0 : _items.length;
      final viewAsSupplierId = widget.viewAsSupplierId;
      final res = await Supabase.instance.client.rpc(
        viewAsSupplierId != null
            ? 'admin_preview_supplier_medicines'
            : 'supplier_home_medicines',
        params: {
          if (viewAsSupplierId != null) 'p_supplier_id': viewAsSupplierId,
          'p_search': _currentSearch,
          'p_limit':  _pageSize,
          'p_offset': offset,
        },
      ) as List;
      if (mounted) {
        setState(() {
          if (reset) {
            _items = res.map((r) => Map<String, dynamic>.from(r as Map)).toList();
          } else {
            _items.addAll(res.map((r) => Map<String, dynamic>.from(r as Map)));
          }
          _hasMore = res.length == _pageSize;
        });
        RenderLog.write('supplier_home_rows', _items.length);
      }
    } catch (e) {
      RenderLog.write('supplier_home_error', e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 900;
    return Column(children: [
      // cmd #401 — the two "about my shop" entry points, above the search bar
      // so a shop left marked closed is visible on the tab he lands on.
      const SupplierShopEntries(),
      // CHANGE #465 · register row 64 — the supplier's OWN number. SPN decides
      // whether this supplier is asked first or never, and until now every SPN
      // RPC was admin-side, so the one number that governs their business was
      // the one thing they could not see. Read-only: supplier_scorecard()
      // resolves my_supplier_id() itself and takes no argument, and the card
      // draws nothing at all for a login that is not a supplier.
      if (widget.viewAsSupplierId == null) const SupplierScorecardCard(),
      // CHANGE #461 / feature_gaps #169 — the way in to the scheme book.
      // supplier_schemes had zero rows and no filing surface at all, so the
      // scheme fields every buyer card already reads had never carried data.
      // The entry sits here rather than in SupplierShell because the shell is
      // owned by another in-flight command; the home tab is the supplier's
      // landing screen, so this is still one tap from sign-in.
      if (widget.viewAsSupplierId == null)
        Container(
          width: double.infinity,
          color: Colors.white,
          padding: EdgeInsets.fromLTRB(
            isDesktop ? 24 : 16, 12, isDesktop ? 24 : 16, 0,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('c461_schemes_entry'),
              onPressed: () {
                RenderLog.write('c461_schemes_open', '1');
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const SupplierSchemesScreen(),
                ));
              },
              icon: const Icon(Icons.local_offer_outlined),
              label: Text(c('supplier_home.schemes_cta')),
            ),
          ),
        ),
      // Search bar
      Container(
        padding: EdgeInsets.fromLTRB(
          isDesktop ? Ds.space.x24 : Ds.space.x16, Ds.space.x12,
          isDesktop ? Ds.space.x24 : Ds.space.x16, Ds.space.x8,
        ),
        color: Ds.c.surface,
        child: TextField(
          controller: _searchCtrl,
          onChanged: _onSearchChanged,
          decoration: InputDecoration(
            hintText: c('supplier_home.search_hint'),
            hintStyle: Ds.t.bodySecondary,
            prefixIcon: Icon(Icons.search, color: Ds.c.textSecondary, size: 20),
            suffixIcon: _currentSearch.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      _searchCtrl.clear();
                      _onSearchChanged('');
                    },
                  )
                : null,
            filled: true,
            fillColor: Ds.c.bg,
            contentPadding: EdgeInsets.symmetric(
                horizontal: Ds.space.x12, vertical: Ds.space.x8),
            border: OutlineInputBorder(
              borderRadius: Ds.r.rButton,
              borderSide: BorderSide(color: Ds.c.divider),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: Ds.r.rButton,
              borderSide: BorderSide(color: Ds.c.divider),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: Ds.r.rButton,
              borderSide: BorderSide(color: Ds.c.brand),
            ),
          ),
        ),
      ),
      // Content
      Expanded(
        child: _items.isEmpty && !_loading
            ? _emptyState()
            : GridView.builder(
                controller: _scrollCtrl,
                padding: EdgeInsets.all(
                    isDesktop ? Ds.space.x16 : Ds.space.x12),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: isDesktop ? 4 : 2,
                  crossAxisSpacing: Ds.space.x8,
                  mainAxisSpacing: Ds.space.x8,
                  childAspectRatio: isDesktop ? 0.78 : 0.72,
                ),
                itemCount: _items.length + (_loading ? 2 : 0),
                itemBuilder: (ctx, i) {
                  if (i >= _items.length) {
                    return const _SkeletonCard();
                  }
                  return _SupplierMedicineCard(item: _items[i]);
                },
              ),
      ),
    ]);
  }

  Widget _emptyState() {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.store_outlined, size: 56, color: Ds.c.divider),
        SizedBox(height: Ds.space.x12),
        Text(
          _currentSearch.isNotEmpty
              ? cf('supplier_home.empty_search', {'query': _currentSearch})
              : c('supplier_home.empty_no_companies'),
          textAlign: TextAlign.center,
          style: Ds.t.bodySecondary,
        ),
        if (_currentSearch.isEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(
            c('supplier_home.empty_no_companies_hint'),
            textAlign: TextAlign.center,
            style: Ds.t.caption,
          ),
        ],
      ]),
    );
  }
}

// ── Medicine card ─────────────────────────────────────────────────────────────

class _SupplierMedicineCard extends StatelessWidget {
  final Map<String, dynamic> item;
  const _SupplierMedicineCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final name       = item['product_name'] as String? ?? '';
    final marketer   = item['marketer']     as String? ?? '';
    final mrp        = item['mrp']          as String? ?? '';
    final schemeLabel = item['scheme_label'] as String?;

    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Scheme badge
          if (schemeLabel != null)
            Container(
              margin: EdgeInsets.only(bottom: Ds.space.x4),
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x8, vertical: Ds.space.x4),
              decoration: BoxDecoration(
                color: Ds.c.successSoft,
                borderRadius: Ds.r.rChip,
              ),
              child: Text(schemeLabel,
                style: Ds.t.caption.copyWith(
                  color: Ds.c.success, fontWeight: FontWeight.w600,
                ),
              ),
            ),
          // Product name
          Expanded(
            child: Text(name,
              style: Ds.t.caption.copyWith(
                fontWeight: FontWeight.w500, color: Ds.c.text,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(height: Ds.space.x8),
          // Marketer
          Text(marketer,
            style: Ds.t.caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          SizedBox(height: Ds.space.x4),
          // MRP
          if (mrp.isNotEmpty)
            Text(cf('supplier_home.mrp', {'mrp': mrp}),
              style: Ds.t.caption.copyWith(
                color: Ds.c.text, fontWeight: FontWeight.w600,
              ),
            ),
        ]),
      ),
    );
  }
}

// ── Skeleton placeholder ──────────────────────────────────────────────────────

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
      ),
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(height: 14, width: double.infinity, decoration: BoxDecoration(
            color: Ds.c.bg, borderRadius: BorderRadius.circular(Ds.space.x4),
          )),
          SizedBox(height: Ds.space.x8),
          Container(height: 12, width: 100, decoration: BoxDecoration(
            color: Ds.c.bg, borderRadius: BorderRadius.circular(Ds.space.x4),
          )),
        ]),
      ),
    );
  }
}
