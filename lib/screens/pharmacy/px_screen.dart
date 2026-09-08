// CMD #420 — the pharmacy exchange: dead stock out, emergency borrow in.
//
// Two tabs over one movement layer. What makes this legal rather than a grey
// resale is that both parties are licensed establishments and every movement
// produces a document — so the screen's job is to make the DISCLOSURE
// impossible to miss: batch and expiry are on the row itself, not behind a tap,
// and the sentence the buyer accepts is the backend's, recorded verbatim.
//
// THIS FILE COMPUTES NOTHING. Every rupee, every "75 days to expiry", every
// distance, ETA and promise sentence is a finished string. In particular the
// screen never decides that a batch is "close to expiry" — the payload's own
// `tone` and `days_label` say so, because that judgement has legal weight.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_tokens.dart';
import '../../services/px_api.dart';
import '../../utils/render_log.dart';

String _s(Object? v) => v == null ? '' : v.toString();
Map<String, dynamic> _m(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

String _newActionId() {
  final r = Random.secure();
  String h(int n) =>
      List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
  return '${h(8)}-${h(4)}-4${h(3)}-'
      '${(8 + r.nextInt(4)).toRadixString(16)}${h(3)}-${h(12)}';
}

Color _toneColor(String tone) {
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

Color _toneSoft(String tone) {
  switch (tone) {
    case 'success':
      return Ds.c.successSoft;
    case 'warning':
      return Ds.c.warningSoft;
    case 'danger':
      return Ds.c.dangerSoft;
    default:
      return Ds.c.infoSoft;
  }
}

BoxDecoration _card() => BoxDecoration(
  color: Ds.c.surface,
  borderRadius: Ds.r.rCard,
  boxShadow: Ds.elevation.e1,
);

class PxScreen extends StatefulWidget {
  const PxScreen({super.key, this.rpc});

  final PxRpc? rpc;

  @override
  State<PxScreen> createState() => _PxScreenState();
}

class _PxScreenState extends State<PxScreen> with SingleTickerProviderStateMixin {
  Map<String, dynamic> _home = const {};
  Map<String, dynamic> _browse = const {};
  bool _loading = true;
  bool _failed = false;
  String _refusal = '';
  late final TabController _tabs = TabController(length: 3, vsync: this);

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : PxApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final home = await _call('px_home', const {});
      if (!mounted) return;
      if (home['ok'] != true) {
        setState(() {
          _refusal = _s(home['message']);
          _loading = false;
        });
        RenderLog.write('c420_px_denied', 1);
        return;
      }
      final browse = await _call('px_browse', const {});
      if (!mounted) return;
      setState(() {
        _home = home;
        _browse = browse['ok'] == true ? browse : const {};
        _loading = false;
        _failed = false;
      });
      RenderLog.write('c420_px_home', 1);
      RenderLog.write('c420_px_listings', _rows(browse['rows']).length);
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  void _toast(String msg) {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final labels = _m(_home['labels']);
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(
          _s(labels['title']).isEmpty ? _s(_home['shop_name']) : _s(labels['title']),
        ),
        bottom: _home.isEmpty
            ? null
            : TabBar(
                controller: _tabs,
                tabs: [
                  Tab(text: _s(labels['browse'])),
                  Tab(text: _s(labels['borrow'])),
                  Tab(text: _s(labels['deals'])),
                ],
              ),
      ),
      body: _body(labels),
    );
  }

  Widget _body(Map<String, dynamic> labels) {
    if (_loading) return const _Skeleton();
    if (_refusal.isNotEmpty) return _Refusal(message: _refusal);
    if (_failed) {
      return _Refusal(
        message: _s(labels['load_failed']),
        retryLabel: _s(labels['retry']),
        onRetry: () {
          setState(() => _loading = true);
          _boot();
        },
      );
    }
    // The backend decides eligibility (approved, active, zoned) and says so in
    // its own words; the screen never works it out from a role.
    if (_home['eligible'] != true) {
      return _Refusal(message: _s(_home['not_eligible_message']));
    }

    return TabBarView(
      controller: _tabs,
      children: [
        _browseTab(labels),
        _BorrowTab(call: _call, onToast: _toast, onChanged: _boot),
        _dealsTab(labels),
      ],
    );
  }

  Widget _browseTab(Map<String, dynamic> labels) {
    final rows = _rows(_browse['rows']);
    final empty = _m(_browse['empty']);
    final bLabels = _m(_browse['labels']);

    return RefreshIndicator(
      onRefresh: _boot,
      child: ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          if (_s(_browse['disclosure_note']).isNotEmpty)
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(Ds.space.x12),
              decoration: BoxDecoration(
                color: Ds.c.infoSoft,
                borderRadius: Ds.r.rChip,
              ),
              child: Text(
                _s(_browse['disclosure_note']),
                style: Ds.t.caption.copyWith(color: Ds.c.info),
              ),
            ),
          SizedBox(height: Ds.space.x8),
          Text(_s(_browse['fee_note']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x16),
          if (rows.isEmpty)
            _EmptyState(title: _s(empty['title']), hint: _s(empty['hint']))
          else
            ...rows.map((r) => _listingCard(r, bLabels)),
        ],
      ),
    );
  }

  /// Batch and expiry sit ON the card, at the same weight as the price. That is
  /// deliberate: this is a near-expiry sale, and the disclosure is what makes it
  /// a legitimate trade rather than something offloaded onto a neighbour.
  Widget _listingCard(Map<String, dynamic> r, Map<String, dynamic> labels) {
    final tone = _s(r['tone']);
    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x12),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: _card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_s(r['product_name']), style: Ds.t.bodyStrong),
                    if (_s(r['pack_label']).isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(_s(r['pack_label']), style: Ds.t.caption),
                    ],
                  ],
                ),
              ),
              SizedBox(width: Ds.space.x8),
              Text(_s(r['price_display']), style: Ds.t.subtitle),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x4,
            children: [
              _chip(_s(r['batch_label']), 'info'),
              _chip(_s(r['expiry_label']), 'info'),
              _chip(_s(r['days_label']), tone),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Text(
            [
              _s(r['seller_name']),
              if (_s(r['distance_hint']).isNotEmpty) _s(r['distance_hint']),
              _s(r['qty_label']),
            ].where((e) => e.isNotEmpty).join(' · '),
            style: Ds.t.caption,
          ),
          SizedBox(height: Ds.space.x12),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Ds.c.brand,
                foregroundColor: Ds.c.surface,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              onPressed: () => _openBuy(r, labels),
              child: Text(_s(labels['buy'])),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String text, String tone) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Ds.space.x8,
        vertical: Ds.space.x4,
      ),
      decoration: BoxDecoration(
        color: _toneSoft(tone),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(text, style: Ds.t.caption.copyWith(color: _toneColor(tone))),
    );
  }

  Future<void> _openBuy(
    Map<String, dynamic> r,
    Map<String, dynamic> labels,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => _BuySheet(
        listing: r,
        labels: labels,
        call: _call,
        onDone: (msg) {
          _toast(msg);
          _boot();
        },
      ),
    );
  }

  Widget _dealsTab(Map<String, dynamic> labels) {
    final rows = _rows(_home['deals']);
    final empty = _m(_home['empty_deals']);
    return RefreshIndicator(
      onRefresh: _boot,
      child: ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          if (_s(_home['pending_label']).isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(Ds.space.x12),
              decoration: BoxDecoration(
                color: Ds.c.warningSoft,
                borderRadius: Ds.r.rChip,
              ),
              child: Text(
                _s(_home['pending_label']),
                style: Ds.t.caption.copyWith(color: Ds.c.warning),
              ),
            ),
            SizedBox(height: Ds.space.x16),
          ],
          if (rows.isEmpty)
            _EmptyState(title: _s(empty['title']), hint: '')
          else
            ...rows.map(_dealRow),
        ],
      ),
    );
  }

  Widget _dealRow(Map<String, dynamic> d) {
    final tone = _s(d['status_tone']);
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Material(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        child: InkWell(
          borderRadius: Ds.r.rCard,
          onTap: () => _openDeal(_s(d['deal_id'])),
          child: Container(
            constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
            padding: EdgeInsets.all(Ds.space.x16),
            decoration: _card(),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_s(d['product_name']), style: Ds.t.bodyStrong),
                      SizedBox(height: Ds.space.x4),
                      Text(
                        [
                          _s(d['kind_label']),
                          _s(d['side_label']),
                          _s(d['counterparty']),
                        ].where((e) => e.isNotEmpty).join(' · '),
                        style: Ds.t.caption,
                      ),
                      SizedBox(height: Ds.space.x4),
                      Text(
                        _s(d['status_label']),
                        style: Ds.t.caption.copyWith(color: _toneColor(tone)),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: Ds.space.x8),
                Text(_s(d['total_display']), style: Ds.t.bodyStrong),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openDeal(String id) async {
    if (id.isEmpty) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PxDealScreen(dealId: id, rpc: widget.rpc),
      ),
    );
    if (mounted) _boot();
  }
}

// ── the borrow tab ──────────────────────────────────────────────────────────
class _BorrowTab extends StatefulWidget {
  const _BorrowTab({
    required this.call,
    required this.onToast,
    required this.onChanged,
  });

  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) call;
  final void Function(String) onToast;
  final Future<void> Function() onChanged;

  @override
  State<_BorrowTab> createState() => _BorrowTabState();
}

class _BorrowTabState extends State<_BorrowTab> {
  final TextEditingController _q = TextEditingController();
  Map<String, dynamic> _res = const {};
  Timer? _debounce;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Ask once with an empty term so the PRIVACY PROMISE and the search hint
    // are on screen before anyone types. The shop being searched is owed that
    // guarantee up front, not after the searching has started.
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(v));
  }

  Future<void> _search(String v) async {
    setState(() => _busy = true);
    try {
      final r = await widget.call('px_borrow_search', {'p_q': v.trim(), 'p_qty': 1});
      if (!mounted) return;
      setState(() {
        _res = r;
        _busy = false;
      });
      RenderLog.write('c420_px_borrow', _rows(r['rows']).length);
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final labels = _m(_res['labels']);
    final rows = _rows(_res['rows']);
    final empty = _m(_res['empty']);

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        TextField(
          controller: _q,
          onChanged: _onChanged,
          decoration: InputDecoration(
            hintText: _s(labels['search_hint']),
            prefixIcon: const Icon(Icons.search),
            isDense: true,
          ),
        ),
        SizedBox(height: Ds.space.x12),
        // The privacy promise is the backend's sentence, shown before any
        // result — the shop being searched has a right to it too.
        if (_s(_res['privacy_note']).isNotEmpty)
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(Ds.space.x12),
            decoration: BoxDecoration(
              color: Ds.c.infoSoft,
              borderRadius: Ds.r.rChip,
            ),
            child: Text(
              _s(_res['privacy_note']),
              style: Ds.t.caption.copyWith(color: Ds.c.info),
            ),
          ),
        SizedBox(height: Ds.space.x16),
        if (_busy)
          const _Skeleton(inline: true)
        else if (_s(_res['hint']).isNotEmpty)
          _EmptyState(title: _s(_res['hint']), hint: '')
        else if (rows.isEmpty && _res.isNotEmpty)
          _EmptyState(title: _s(empty['title']), hint: _s(empty['hint']))
        else
          ...rows.map((r) => _row(r, labels)),
      ],
    );
  }

  Widget _row(Map<String, dynamic> r, Map<String, dynamic> labels) {
    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x12),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: _card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_s(r['seller_name']), style: Ds.t.bodyStrong),
              ),
              SizedBox(width: Ds.space.x8),
              Text(_s(r['price_display']), style: Ds.t.subtitle),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Text(_s(r['product_name']), style: Ds.t.body),
          SizedBox(height: Ds.space.x8),
          Text(
            [
              _s(r['distance_hint']),
              _s(r['promise_label']),
              _s(r['price_basis']),
            ].where((e) => e.isNotEmpty).join(' · '),
            style: Ds.t.caption,
          ),
          SizedBox(height: Ds.space.x12),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Ds.c.brand,
                foregroundColor: Ds.c.surface,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              onPressed: r['has_enough'] == true ? () => _request(r) : null,
              child: Text(_s(labels['request'])),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _request(Map<String, dynamic> r) async {
    final res = await widget.call('px_borrow_request', {
      'p_stock_id': _s(r['stock_id']),
      'p_qty': 1,
      'p_client_action_id': _newActionId(),
    });
    if (!mounted) return;
    widget.onToast(_s(res['message']));
    await widget.onChanged();
  }
}

// ── one movement ────────────────────────────────────────────────────────────
class PxDealScreen extends StatefulWidget {
  const PxDealScreen({super.key, required this.dealId, this.rpc});

  final String dealId;
  final PxRpc? rpc;

  @override
  State<PxDealScreen> createState() => _PxDealScreenState();
}

class _PxDealScreenState extends State<PxDealScreen> {
  Map<String, dynamic> _d = const {};
  bool _loading = true;
  bool _busy = false;
  String _refusal = '';

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : PxApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _call('px_deal_detail', {'p_deal_id': widget.dealId});
      if (!mounted) return;
      if (r['ok'] != true) {
        setState(() {
          _refusal = _s(r['message']);
          _loading = false;
        });
        return;
      }
      setState(() {
        _d = r;
        _loading = false;
      });
      RenderLog.write('c420_px_deal', 1);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(String m) {
    if (m.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final labels = _m(_d['labels']);
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s(_d['product_name']))),
      body: _loading
          ? const _Skeleton()
          : _refusal.isNotEmpty
              ? _Refusal(message: _refusal)
              : _body(labels),
    );
  }

  Widget _body(Map<String, dynamic> labels) {
    final tone = _s(_d['status_tone']);
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Container(
          width: double.infinity,
          padding: EdgeInsets.all(Ds.space.x16),
          decoration: _card(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _s(_d['status_label']),
                style: Ds.t.subtitle.copyWith(color: _toneColor(tone)),
              ),
              SizedBox(height: Ds.space.x4),
              Text(
                [
                  _s(_d['kind_label']),
                  _s(_d['side_label']),
                  _s(_d['counterparty']),
                ].where((e) => e.isNotEmpty).join(' · '),
                style: Ds.t.caption,
              ),
              if (_s(_d['promise_label']).isNotEmpty) ...[
                SizedBox(height: Ds.space.x8),
                Text(
                  [
                    _s(_d['distance_label']),
                    _s(_d['eta_label']),
                    _s(_d['promise_label']),
                  ].where((e) => e.isNotEmpty).join(' · '),
                  style: Ds.t.caption,
                ),
              ],
            ],
          ),
        ),
        SizedBox(height: Ds.space.x16),
        // The disclosure, in full, on the record of the deal. It is the reason
        // a near-expiry trade between two licensed shops is legitimate.
        if (_s(_d['disclosure']).isNotEmpty)
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(Ds.space.x16),
            decoration: BoxDecoration(
              color: Ds.c.infoSoft,
              borderRadius: Ds.r.rCard,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _s(_d['disclosure']),
                  style: Ds.t.body.copyWith(color: Ds.c.info),
                ),
                if (_s(_d['disclosure_accepted_label']).isNotEmpty) ...[
                  SizedBox(height: Ds.space.x8),
                  Text(
                    _s(_d['disclosure_accepted_label']),
                    style: Ds.t.caption.copyWith(color: Ds.c.info),
                  ),
                ],
              ],
            ),
          ),
        SizedBox(height: Ds.space.x16),
        Container(
          width: double.infinity,
          padding: EdgeInsets.all(Ds.space.x16),
          decoration: _card(),
          child: Column(
            children: [
              _line(_s(_d['qty_label']), _s(_d['price_display'])),
              _line(_s(_d['batch_label']), _s(_d['expiry_label'])),
              _line(_s(_d['gst_label']),
                  '${_s(_d['cgst_display'])} + ${_s(_d['sgst_display'])}'),
              _line(_s(labels['invoice']), _s(_d['invoice_no'])),
              Divider(color: Ds.c.divider),
              _line(_s(_d['fee_display']), _s(_d['total_display']), strong: true),
            ],
          ),
        ),
        SizedBox(height: Ds.space.x16),
        if (_d['can_decide'] == true)
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    onPressed: _busy ? null : () => _decide(false),
                    child: Text(_s(labels['decline'])),
                  ),
                ),
              ),
              SizedBox(width: Ds.space.x8),
              Expanded(
                child: SizedBox(
                  height: Ds.touch.minTarget,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Ds.c.brand,
                      foregroundColor: Ds.c.surface,
                      shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                    ),
                    onPressed: _busy ? null : () => _decide(true),
                    child: Text(_s(labels['accept'])),
                  ),
                ),
              ),
            ],
          ),
        if (_s(_d['invoice_no']).isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: OutlinedButton(
              onPressed: _busy ? null : _openInvoice,
              child: Text(_s(labels['invoice'])),
            ),
          ),
        ],
      ],
    );
  }

  Widget _line(String left, String right, {bool strong = false}) {
    if (left.isEmpty && right.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.symmetric(vertical: Ds.space.x4),
      child: Row(
        children: [
          Expanded(child: Text(left, style: Ds.t.caption)),
          Text(right, style: strong ? Ds.t.subtitle : Ds.t.body),
        ],
      ),
    );
  }

  Future<void> _decide(bool accept) async {
    setState(() => _busy = true);
    try {
      final r = await _call('px_decide', {
        'p_deal_id': widget.dealId,
        'p_accept': accept,
      });
      if (!mounted) return;
      _toast(_s(r['message']));
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Polls on the BACKEND's own poll_ms and opens the bucket + path it names —
  /// the screen never builds a URL and never invents a timeout.
  Future<void> _openInvoice() async {
    setState(() => _busy = true);
    try {
      var r = await _call('px_invoice_request', {'p_deal_id': widget.dealId});
      var guard = 0;
      while (_s(r['status']) == 'building' && guard < 20 && mounted) {
        final ms = (r['poll_ms'] is num) ? (r['poll_ms'] as num).toInt() : 1500;
        await Future<void>.delayed(Duration(milliseconds: ms));
        r = await _call('px_invoice_request', {'p_deal_id': widget.dealId});
        guard++;
      }
      if (!mounted) return;
      if (_s(r['status']) != 'ready') {
        _toast(_s(r['message']));
        return;
      }
      final url = await PxApi.signedUrl(_s(r['bucket']), _s(r['path']));
      if (url.isNotEmpty) {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      _toast(_s(_m(_d['labels'])['load_failed']));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

// ── buy sheet ───────────────────────────────────────────────────────────────
class _BuySheet extends StatefulWidget {
  const _BuySheet({
    required this.listing,
    required this.labels,
    required this.call,
    required this.onDone,
  });

  final Map<String, dynamic> listing;
  final Map<String, dynamic> labels;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) call;
  final void Function(String) onDone;

  @override
  State<_BuySheet> createState() => _BuySheetState();
}

class _BuySheetState extends State<_BuySheet> {
  final TextEditingController _qty = TextEditingController(text: '1');
  bool _busy = false;
  String _error = '';
  late final String _actionId = _newActionId();

  @override
  void dispose() {
    _qty.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final q = num.tryParse(_qty.text.trim());
    if (q == null) return;
    setState(() => _busy = true);
    try {
      final r = await widget.call('px_accept_listing', {
        'p_listing_id': _s(widget.listing['listing_id']),
        'p_qty': q,
        'p_client_action_id': _actionId,
      });
      if (!mounted) return;
      if (r['ok'] != true) {
        setState(() {
          _error = _s(r['message']);
          _busy = false;
        });
        return;
      }
      Navigator.pop(context);
      widget.onDone(_s(r['message']));
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Ds.space.x16,
        Ds.space.x16,
        Ds.space.x16,
        MediaQuery.of(context).viewInsets.bottom + Ds.space.x16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(widget.listing['product_name']), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          // The disclosure is repeated at the moment of committing, not just on
          // the browse row — this is the sentence being accepted.
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(Ds.space.x12),
            decoration: BoxDecoration(
              color: Ds.c.warningSoft,
              borderRadius: Ds.r.rChip,
            ),
            child: Text(
              _s(widget.listing['disclosure']),
              style: Ds.t.caption.copyWith(color: Ds.c.warning),
            ),
          ),
          SizedBox(height: Ds.space.x16),
          TextField(
            controller: _qty,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            autofocus: true,
            decoration: InputDecoration(
              labelText: _s(widget.labels['qty']),
              isDense: true,
            ),
          ),
          if (_error.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(_error, style: Ds.t.caption.copyWith(color: Ds.c.danger)),
          ],
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Ds.c.brand,
                foregroundColor: Ds.c.surface,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              onPressed: _busy ? null : _confirm,
              child: Text(_s(widget.labels['confirm'])),
            ),
          ),
        ],
      ),
    );
  }
}

// ── shared states ───────────────────────────────────────────────────────────
/// A skeleton, not a bare spinner: the shape of the answer arrives first.
///
/// [inline] matters — this is drawn both as a whole page AND inside the borrow
/// tab's own ListView, and a scrollable nested in a scrollable is given
/// unbounded height and throws. Inline renders a plain Column instead.
class _Skeleton extends StatelessWidget {
  const _Skeleton({this.inline = false});

  final bool inline;

  @override
  Widget build(BuildContext context) {
    final bars = List.generate(
      inline ? 3 : 4,
      (_) => Container(
        height: Ds.space.x48 + Ds.space.x32,
        margin: EdgeInsets.only(bottom: Ds.space.x12),
        decoration: BoxDecoration(
          color: Ds.c.divider,
          borderRadius: Ds.r.rCard,
        ),
      ),
    );
    if (inline) {
      return Column(mainAxisSize: MainAxisSize.min, children: bars);
    }
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: bars,
    );
  }
}

class _Refusal extends StatelessWidget {
  const _Refusal({required this.message, this.onRetry, this.retryLabel = ''});

  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center, style: Ds.t.body),
            if (onRetry != null) ...[
              SizedBox(height: Ds.space.x16),
              SizedBox(
                height: Ds.touch.minTarget,
                child: OutlinedButton(
                  onPressed: onRetry,
                  child: Text(retryLabel),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x24),
      decoration: _card(),
      child: Column(
        children: [
          Text(title, style: Ds.t.bodyStrong, textAlign: TextAlign.center),
          if (hint.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(hint, style: Ds.t.caption, textAlign: TextAlign.center),
          ],
        ],
      ),
    );
  }
}
