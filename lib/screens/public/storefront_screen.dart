// CMD #417 — the pharmacy's public WhatsApp storefront, reached from the link
// or QR the shop shares: `/shop/<token>`. No auth: the token in the URL is the
// authorisation, exactly the way `/stock-update/<token>` already works.
//
// The patient side of the fence. Everything on this page comes from
// `wa_storefront_page()`, which returns product name, pack, availability and
// MRP — and nothing else. There is no unit cost, no PTR, no supplier and no
// margin in the payload, so there is none on the screen. The cart count
// sentence and every button caption are backend strings; this file formats no
// text and prices nothing.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/pharmacy_refill_api.dart';
import '../../utils/render_log.dart';

String _s(Object? v) => v == null ? '' : v.toString();
List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

class StorefrontScreen extends StatefulWidget {
  const StorefrontScreen({super.key, required this.token, this.rpc});

  final String token;

  /// Tests hand a payload instead of a network.
  final RefillRpc? rpc;

  @override
  State<StorefrontScreen> createState() => _StorefrontScreenState();
}

class _StorefrontScreenState extends State<StorefrontScreen> {
  Map<String, dynamic> _page = const {};
  final Map<String, Map<String, dynamic>> _cart = {};
  String _refusal = '';
  bool _loading = true;
  bool _busy = false;
  bool _sent = false;
  Map<String, dynamic> _thanks = const {};
  String _query = '';
  Timer? _debounce;
  final TextEditingController _search = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _note = TextEditingController();

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : RefillApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _name.dispose();
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final res = await _call('wa_storefront_page', {
        'p_token': widget.token,
        if (_query.isNotEmpty) 'p_q': _query,
        'p_limit': 40,
        'p_offset': 0,
      });
      if (!mounted) return;
      if (res['ok'] != true) {
        setState(() {
          _refusal = _s(res['message']);
          _loading = false;
        });
        RenderLog.write('c417_storefront_closed', 1);
        return;
      }
      setState(() {
        _page = res;
        _loading = false;
      });
      RenderLog.write('c417_storefront_page', 1);
      RenderLog.write('c417_storefront_items', _rows(res['items']).length);
    } catch (_) {
      if (mounted) {
        setState(() {
          _refusal = _s(_page['empty_label']);
          _loading = false;
        });
      }
    }
  }

  void _onSearch(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _query = q.trim();
      _boot();
    });
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await _call('storefront_request_submit', {
        'p_token': widget.token,
        'p_name': _name.text.trim(),
        'p_phone': _phone.text.trim(),
        'p_items': _cart.values
            .map(
              (e) => {
                if (e['medicine_id'] != null) 'medicine_id': e['medicine_id'],
                'product_name': e['product_name'],
                'qty': 1,
              },
            )
            .toList(),
        if (_note.text.trim().isNotEmpty) 'p_note': _note.text.trim(),
      });
      if (!mounted) return;
      if (res['ok'] == true) {
        setState(() {
          _sent = true;
          _thanks = res;
        });
        RenderLog.write('c417_storefront_request', 1);
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_s(res['message']))));
      }
    } catch (_) {
      // a failed submit leaves the cart intact so the patient can retry
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s(_page['shop']))),
      body: _body(),
      bottomNavigationBar: (_sent || _cart.isEmpty) ? null : _cartBar(),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(
        child: SizedBox(
          width: Ds.space.x32,
          height: Ds.space.x32,
          child: const CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_refusal.isNotEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Text(
            _refusal,
            style: Ds.t.bodySecondary,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_sent) return _thanksView();

    final items = _rows(_page['items']);
    return ListView(
      padding: EdgeInsets.fromLTRB(
        Ds.space.x16,
        Ds.space.x16,
        Ds.space.x16,
        Ds.space.x48,
      ),
      children: [
        Text(_s(_page['greeting']), style: Ds.t.body),
        SizedBox(height: Ds.space.x16),
        TextField(
          controller: _search,
          onChanged: _onSearch,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: _s(_page['search_hint']),
          ),
        ),
        SizedBox(height: Ds.space.x16),
        if (items.isEmpty)
          Text(_s(_page['empty_label']), style: Ds.t.bodySecondary)
        else
          for (final it in items)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: _itemTile(it),
            ),
      ],
    );
  }

  Widget _itemTile(Map<String, dynamic> it) {
    final key = _s(it['key']);
    final inCart = _cart.containsKey(key);
    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      padding: EdgeInsets.all(Ds.space.x16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_s(it['product_name']), style: Ds.t.bodyStrong),
                SizedBox(height: Ds.space.x4),
                Text(
                  _s(it['pack_label']),
                  style: Ds.t.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: Ds.space.x4),
                Row(
                  children: [
                    if (it['has_mrp'] == true)
                      Text(_s(it['mrp_display']), style: Ds.t.bodyStrong),
                    if (it['has_mrp'] == true) SizedBox(width: Ds.space.x8),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: Ds.space.x8,
                        vertical: Ds.space.x4,
                      ),
                      decoration: BoxDecoration(
                        color: Ds.c.successSoft,
                        borderRadius: Ds.r.rChip,
                      ),
                      child: Text(
                        _s(it['stock_label']),
                        style: Ds.t.caption.copyWith(color: Ds.c.success),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(width: Ds.space.x12),
          SizedBox(
            height: Ds.space.x48,
            child: inCart
                ? OutlinedButton(
                    onPressed: () => setState(() => _cart.remove(key)),
                    child: Text(_s(it['added_label'])),
                  )
                : FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
                    onPressed: () => setState(() => _cart[key] = it),
                    child: Text(_s(it['add_label'])),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _cartBar() => SafeArea(
    child: Padding(
      padding: EdgeInsets.all(Ds.space.x16),
      child: SizedBox(
        width: double.infinity,
        height: Ds.space.x48,
        child: FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
          onPressed: _busy ? null : _openRequestSheet,
          child: Text(_s(_page['submit_label'])),
        ),
      ),
    ),
  );

  Future<void> _openRequestSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          Ds.space.x16,
          Ds.space.x16,
          Ds.space.x16,
          Ds.space.x16 + MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final e in _cart.values)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x4),
                child: Text(_s(e['product_name']), style: Ds.t.body),
              ),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: _name,
              decoration: InputDecoration(hintText: _s(_page['name_hint'])),
            ),
            SizedBox(height: Ds.space.x12),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(hintText: _s(_page['phone_hint'])),
            ),
            SizedBox(height: Ds.space.x12),
            TextField(
              controller: _note,
              decoration: InputDecoration(hintText: _s(_page['note_hint'])),
            ),
            SizedBox(height: Ds.space.x24),
            SizedBox(
              width: double.infinity,
              height: Ds.space.x48,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
                onPressed: () {
                  Navigator.pop(ctx);
                  _submit();
                },
                child: Text(_s(_page['submit_label'])),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _thanksView() => Center(
    child: Padding(
      padding: EdgeInsets.all(Ds.space.x24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_outline, color: Ds.c.success),
          SizedBox(height: Ds.space.x16),
          Text(_s(_thanks['title']), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x8),
          Text(
            _s(_thanks['message']),
            style: Ds.t.bodySecondary,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}
