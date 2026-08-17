import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import '../../widgets/offer_card.dart';

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
  int? _busyListingId;
  // Chrome served by offers_feed — never a Dart literal.
  String _loadMoreLabel = '';
  String _retryLabel = '';
  String _emptyLabel = '';
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
        if (mounted) setState(() {
          _error = (data['message'] ?? data['error'])?.toString();
          _loading = false;
        });
        return;
      }
      final rows = List<Map<String, dynamic>>.from(
        (data['rows'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)));
      if (mounted) setState(() {
        _rows = append ? [..._rows, ...rows] : rows;
        _hasMore = data['has_more'] == true;
        _offset = (append ? _offset : 0) + rows.length;
        _loadMoreLabel = data['load_more_label'] as String? ?? '';
        _retryLabel = data['retry_label'] as String? ?? '';
        _emptyLabel = data['empty'] as String? ?? _emptyLabel;
        _loading = false;
      });
      RenderLog.write('offers_rows', _rows.length);
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  void _toast(String message, {bool ok = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      backgroundColor: ok ? Ds.c.brand : Ds.c.danger));
  }

  /// The short-dated opt-in. The sheet's words and the accept label come from
  /// the backend; the answer is sent back as p_disclosure_seen so the SERVER
  /// records the acceptance — the tick alone proves nothing.
  Future<bool> _confirmDisclosure() async {
    return await showModalBottomSheet<bool>(
      context: context,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
      builder: (_) => Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c('offer_near_expiry_title'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          Text(c('offer_near_expiry_disclosure'),
            style: Ds.t.body.copyWith(color: Ds.c.textSecondary)),
          SizedBox(height: Ds.space.x24),
          SizedBox(
            width: double.infinity, height: 48,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Ds.c.brand, foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton)),
              onPressed: () => Navigator.pop(context, true),
              child: Text(c('offer_near_expiry_accept')),
            ),
          ),
          SizedBox(height: Ds.space.x8),
          SizedBox(width: double.infinity,
            child: TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(c('offer_cancel_btn')))),
        ]),
      ),
    ) ?? false;
  }

  Future<void> _add(Map<String, dynamic> row) async {
    var accepted = true;
    if (row['requires_disclosure'] == true) accepted = await _confirmDisclosure();
    if (!accepted) return;
    setState(() => _busyListingId = row['id'] as int?);
    try {
      final raw = await Supabase.instance.client.rpc('offer_add_to_cart', params: {
        'p_listing_id': row['id'],
        'p_qty': row['min_order_qty'] ?? 1,
        'p_disclosure_seen': accepted,
      });
      final data = Map<String, dynamic>.from((raw is List ? raw.first : raw) as Map);
      final ok = data['ok'] == true;
      _toast((data['message'] ?? data['error'] ?? '').toString(), ok: ok);
      if (ok) await _load();
    } catch (e) {
      _toast(e.toString(), ok: false);
    } finally {
      if (mounted) setState(() => _busyListingId = null);
    }
  }

  Future<void> _waitlist(Map<String, dynamic> row) async {
    setState(() => _busyListingId = row['id'] as int?);
    try {
      final raw = await Supabase.instance.client.rpc('offer_waitlist_join',
        params: {'p_listing_id': row['id']});
      final data = Map<String, dynamic>.from((raw is List ? raw.first : raw) as Map);
      final ok = data['ok'] == true;
      _toast((data['message'] ?? data['error'] ?? '').toString(), ok: ok);
      if (ok) await _load();
    } catch (e) {
      _toast(e.toString(), ok: false);
    } finally {
      if (mounted) setState(() => _busyListingId = null);
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
          Text(_error!, style: Ds.t.caption.copyWith(color: Ds.c.danger),
            textAlign: TextAlign.center),
          SizedBox(height: Ds.space.x16),
          TextButton(onPressed: () => _load(),
            child: Text(_retryLabel.isEmpty ? c('offer_retry') : _retryLabel)),
        ])),
      ]);
    }
    if (_rows.isEmpty) {
      return ListView(children: [
        SizedBox(height: MediaQuery.sizeOf(context).height * 0.3),
        Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.local_offer_outlined, color: Ds.c.textSecondary, size: 48),
          SizedBox(height: Ds.space.x12),
          Text(_emptyLabel.isEmpty ? c('offers_feed_empty') : _emptyLabel,
            style: Ds.t.body.copyWith(color: Ds.c.textSecondary)),
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
                child: Text(_loadMoreLabel, style: TextStyle(color: Ds.c.brand)),
              ),
            ),
          );
        }
        final row = _rows[i];
        return OfferCard(
          row: row,
          busy: _busyListingId == row['id'],
          onAdd: () => _add(row),
          onWaitlist: () => _waitlist(row),
        );
      },
    );
  }
}
