import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/render_log.dart';

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
      // Search bar
      Container(
        padding: EdgeInsets.fromLTRB(
          isDesktop ? 24 : 16, 12, isDesktop ? 24 : 16, 8,
        ),
        color: Colors.white,
        child: TextField(
          controller: _searchCtrl,
          onChanged: _onSearchChanged,
          decoration: InputDecoration(
            hintText: 'Search medicines from your companies…',
            hintStyle: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 14),
            prefixIcon: const Icon(Icons.search, color: Color(0xFF6B7280), size: 20),
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
            fillColor: const Color(0xFFF5F6F8),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFF1B7A43)),
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
                padding: EdgeInsets.all(isDesktop ? 20 : 12),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: isDesktop ? 4 : 2,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
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
        const Icon(Icons.store_outlined, size: 56, color: Color(0xFFD1D5DB)),
        const SizedBox(height: 12),
        Text(
          _currentSearch.isNotEmpty
              ? 'No medicines match "$_currentSearch"'
              : 'No medicines from your stocked companies yet.',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
        ),
        if (_currentSearch.isEmpty) ...[
          const SizedBox(height: 6),
          const Text(
            'Ask your admin to link companies to your profile.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)),
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: const [BoxShadow(
          color: Color(0x0F000000), blurRadius: 6, offset: Offset(0, 2),
        )],
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Scheme badge
          if (schemeLabel != null)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFD1FAE5),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(schemeLabel,
                style: const TextStyle(
                  fontSize: 11, color: Color(0xFF065F46), fontWeight: FontWeight.w600,
                ),
              ),
            ),
          // Product name
          Expanded(
            child: Text(name,
              style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF111827),
                height: 1.3,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 8),
          // Marketer
          Text(marketer,
            style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          // MRP
          if (mrp.isNotEmpty)
            Text('MRP ₹$mrp',
              style: const TextStyle(
                fontSize: 13, color: Color(0xFF111827), fontWeight: FontWeight.w600,
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(height: 14, width: double.infinity, decoration: BoxDecoration(
            color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(4),
          )),
          const SizedBox(height: 8),
          Container(height: 12, width: 100, decoration: BoxDecoration(
            color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(4),
          )),
        ]),
      ),
    );
  }
}
