// CMD #413 — Expiry watch: the money still sitting on the shelf.
//
// A pharmacy's expiry loss is not caused by not knowing the expiry date. It is
// caused by not knowing the SUPPLIER'S RETURN WINDOW, which closes months
// earlier. So the headline number is "₹4,491.00 of your stock expires within 90
// days" and the actionable list underneath is "these windows close soon" —
// sorted by how few days are left, never by expiry.
//
// THIS FILE ADDS UP NOTHING. Every rupee, every "closes in 3 days", every "1
// item" / "12 items", every tone name and every refusal sentence arrives
// finished from `pharmacy_expiry_home()` / `_items()` / `_return_*()`. There is
// no day arithmetic here, no plural rule, no currency format and no decision
// about which rows belong on the return list — the backend scopes that to an
// OPEN window, because an open window 120 days out is actionable and a closed
// one inside 30 days is money already lost.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/pharmacy_shield_api.dart';
import '../../utils/render_log.dart';
import 'pharmacy_variance_screen.dart';

String _s(Object? v) => v == null ? '' : v.toString();
Map<String, dynamic> _m(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

/// The payload's tone name → a token colour. The BACKEND decides the tone; this
/// map only says which token paints it, and an unknown tone falls back to the
/// neutral text colour rather than throwing.
Color toneColor(String tone) {
  switch (tone) {
    case 'danger':
      return Ds.c.danger;
    case 'warning':
      return Ds.c.warning;
    case 'success':
      return Ds.c.success;
    case 'info':
      return Ds.c.info;
    default:
      return Ds.c.textSecondary;
  }
}

Color toneSoft(String tone) {
  switch (tone) {
    case 'danger':
      return Ds.c.dangerSoft;
    case 'warning':
      return Ds.c.warningSoft;
    case 'success':
      return Ds.c.successSoft;
    case 'info':
      return Ds.c.infoSoft;
    default:
      return Ds.c.bg;
  }
}

class PharmacyExpiryScreen extends StatefulWidget {
  /// Test seam. Null in production → the real RPCs.
  final ShieldRpc? rpc;
  const PharmacyExpiryScreen({super.key, this.rpc});

  @override
  State<PharmacyExpiryScreen> createState() => _PharmacyExpiryScreenState();
}

class _PharmacyExpiryScreenState extends State<PharmacyExpiryScreen> {
  Map<String, dynamic>? _home;

  /// The backend's own refusal copy. Permanent — a retry cannot change it.
  String? _refusal;

  /// The request never landed. THAT is retryable, and it must never put a Dart
  /// exception string on screen.
  bool _failed = false;
  bool _building = false;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : PharmacyShieldApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    setState(() {
      _failed = false;
      _refusal = null;
    });
    try {
      final r = await _call('pharmacy_expiry_home', const {});
      if (!mounted) return;
      if (r['ok'] != true) {
        setState(() => _refusal = _s(r['message']));
        return;
      }
      setState(() => _home = r);
      RenderLog.write('c413_expiry_home', 1);
      RenderLog.write('c413_expiry_buckets', _rows(r['buckets']).length);
      RenderLog.write('c413_expiry_windows', _rows(r['windows']).length);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _buildList() async {
    setState(() => _building = true);
    Map<String, dynamic> r;
    try {
      r = await _call('pharmacy_expiry_return_build', const {});
    } catch (_) {
      if (mounted) setState(() => _building = false);
      return;
    }
    if (!mounted) return;
    setState(() => _building = false);
    if (r['ok'] != true) {
      _toast(_s(r['message']));
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => PharmacyReturnListSheet(list: r, rpc: widget.rpc),
    );
    if (mounted) _boot();
  }

  void _toast(String msg) {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final h = _home;
    if (_refusal != null) return ShieldRefusal(message: _refusal!);
    if (_failed) {
      return ShieldRefusal(
        message: _s(_m(h)['boot_failed']).isNotEmpty
            ? _s(_m(h)['boot_failed'])
            : '',
        retryLabel: 'Retry',
        onRetry: _boot,
      );
    }
    if (h == null) return const ShieldSkeleton();

    final buckets = _rows(h['buckets']);
    final windows = _rows(h['windows']);

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        surfaceTintColor: Ds.c.surface,
        title: Text(_s(h['title']), style: Ds.t.subtitle),
      ),
      body: RefreshIndicator(
        onRefresh: _boot,
        child: ListView(
          padding: EdgeInsets.all(Ds.space.x16),
          children: [
            // The one focal element: the money.
            ShieldCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_s(h['headline']), style: Ds.t.title),
                  SizedBox(height: Ds.space.x8),
                  Text(_s(h['cost_note']), style: Ds.t.caption),
                ],
              ),
            ),
            SizedBox(height: Ds.space.x24),

            for (final b in buckets) ...[
              _BucketRow(
                bucket: b,
                onTap: _s(b['bucket_key']).isEmpty || b['has'] != true
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => PharmacyExpiryBucketScreen(
                            bucketKey: _s(b['bucket_key']),
                            title: _s(b['label']),
                            rpc: widget.rpc,
                          ),
                        ),
                      ),
              ),
              SizedBox(height: Ds.space.x12),
            ],

            SizedBox(height: Ds.space.x24),
            Text(_s(h['window_title']), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x8),
            Text(_s(h['window_note']), style: Ds.t.caption),
            SizedBox(height: Ds.space.x12),

            if (windows.isEmpty)
              ShieldCard(
                child: Text(_s(h['window_empty']), style: Ds.t.bodySecondary),
              )
            else
              for (final w in windows) ...[
                _WindowRow(row: w),
                SizedBox(height: Ds.space.x12),
              ],

            SizedBox(height: Ds.space.x24),
            SizedBox(
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: _building ? null : _buildList,
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                child: Text(_s(h['build_button'])),
              ),
            ),
            SizedBox(height: Ds.space.x32),
          ],
        ),
      ),
    );
  }
}

class _BucketRow extends StatelessWidget {
  final Map<String, dynamic> bucket;
  final VoidCallback? onTap;
  const _BucketRow({required this.bucket, this.onTap});

  @override
  Widget build(BuildContext context) {
    final tone = _s(bucket['tone']);
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rCard,
      child: ShieldCard(
        child: Row(
          children: [
            Container(
              width: Ds.space.x4,
              height: Ds.space.x32,
              decoration: BoxDecoration(
                color: toneColor(tone),
                borderRadius: Ds.r.rChip,
              ),
            ),
            SizedBox(width: Ds.space.x12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_s(bucket['label']), style: Ds.t.bodyStrong),
                  Text(_s(bucket['count_label']), style: Ds.t.caption),
                ],
              ),
            ),
            Text(
              _s(bucket['value_display']),
              style: Ds.t.bodyStrong,
              textAlign: TextAlign.right,
            ),
            if (onTap != null) ...[
              SizedBox(width: Ds.space.x8),
              Icon(
                Icons.chevron_right,
                size: Ds.t.subtitleSize,
                color: Ds.c.textSecondary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WindowRow extends StatelessWidget {
  final Map<String, dynamic> row;
  const _WindowRow({required this.row});

  @override
  Widget build(BuildContext context) {
    final tone = _s(row['tone']);
    return ShieldCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_s(row['product_name']), style: Ds.t.bodyStrong),
              ),
              SizedBox(width: Ds.space.x8),
              Text(_s(row['value_display']), style: Ds.t.bodyStrong),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Text(
            '${_s(row['supplier_label'])} · ${_s(row['qty_label'])}',
            style: Ds.t.caption,
          ),
          SizedBox(height: Ds.space.x8),
          ShieldChip(label: _s(row['closes_label']), tone: tone),
        ],
      ),
    );
  }
}

/// One bucket's rows, paged on the BACKEND's `has_more` / `next_offset`.
class PharmacyExpiryBucketScreen extends StatefulWidget {
  final String bucketKey;
  final String title;
  final ShieldRpc? rpc;
  const PharmacyExpiryBucketScreen({
    super.key,
    required this.bucketKey,
    required this.title,
    this.rpc,
  });

  @override
  State<PharmacyExpiryBucketScreen> createState() =>
      _PharmacyExpiryBucketScreenState();
}

class _PharmacyExpiryBucketScreenState
    extends State<PharmacyExpiryBucketScreen> {
  final List<Map<String, dynamic>> _items = [];
  Map<String, dynamic>? _page;
  bool _loading = false;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : PharmacyShieldApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load(0);
  }

  Future<void> _load(int offset) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final r = await _call('pharmacy_expiry_items', {
        'p_bucket': widget.bucketKey,
        'p_limit': 50,
        'p_offset': offset,
      });
      if (!mounted) return;
      setState(() {
        _page = r;
        _items.addAll(_rows(r['items']));
        _loading = false;
      });
      RenderLog.write('c413_expiry_items', _items.length);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _page;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        surfaceTintColor: Ds.c.surface,
        title: Text(widget.title, style: Ds.t.subtitle),
      ),
      body: p == null
          ? const ShieldSkeleton()
          : ListView(
              padding: EdgeInsets.all(Ds.space.x16),
              children: [
                if (_items.isEmpty)
                  ShieldCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_s(p['empty']), style: Ds.t.bodyStrong),
                        SizedBox(height: Ds.space.x4),
                        Text(_s(p['empty_hint']), style: Ds.t.caption),
                      ],
                    ),
                  )
                else ...[
                  Text(_s(p['count_label']), style: Ds.t.caption),
                  SizedBox(height: Ds.space.x12),
                  for (final it in _items) ...[
                    _ItemRow(item: it),
                    SizedBox(height: Ds.space.x12),
                  ],
                  if (p['has_more'] == true)
                    SizedBox(
                      height: Ds.touch.minTarget,
                      child: OutlinedButton(
                        onPressed: _loading
                            ? null
                            : () => _load((p['next_offset'] as num).toInt()),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Ds.c.brand,
                          side: BorderSide(color: Ds.c.brand),
                          shape: RoundedRectangleBorder(
                            borderRadius: Ds.r.rButton,
                          ),
                        ),
                        child: Text(_s(p['count_label'])),
                      ),
                    ),
                ],
                SizedBox(height: Ds.space.x32),
              ],
            ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  final Map<String, dynamic> item;
  const _ItemRow({required this.item});

  @override
  Widget build(BuildContext context) => ShieldCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(_s(item['product_name']), style: Ds.t.bodyStrong),
            ),
            SizedBox(width: Ds.space.x8),
            Text(_s(item['value_display']), style: Ds.t.bodyStrong),
          ],
        ),
        SizedBox(height: Ds.space.x4),
        Text(
          '${_s(item['batch_label'])} · ${_s(item['expiry_label'])}',
          style: Ds.t.caption,
        ),
        Text(
          '${_s(item['supplier_label'])} · ${_s(item['qty_label'])}',
          style: Ds.t.caption,
        ),
        SizedBox(height: Ds.space.x8),
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [
            ShieldChip(
              label: _s(item['window_label']),
              tone: _s(item['window_tone']),
            ),
            ShieldChip(label: _s(item['source_label']), tone: 'neutral'),
          ],
        ),
      ],
    ),
  );
}

/// The return list: grouped by supplier, because that is how the stock
/// physically leaves the shop.
class PharmacyReturnListSheet extends StatefulWidget {
  final Map<String, dynamic> list;
  final ShieldRpc? rpc;
  const PharmacyReturnListSheet({super.key, required this.list, this.rpc});

  @override
  State<PharmacyReturnListSheet> createState() =>
      _PharmacyReturnListSheetState();
}

class _PharmacyReturnListSheetState extends State<PharmacyReturnListSheet> {
  late Map<String, dynamic> _list = widget.list;
  bool _sending = false;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : PharmacyShieldApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    RenderLog.write('c413_return_list', _rows(_list['groups']).length);
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    try {
      final r = await _call('pharmacy_expiry_return_send', {
        'p_list_id': _s(_list['list_id']),
      });
      if (!mounted) return;
      setState(() {
        _sending = false;
        if (r['ok'] == true) _list = r;
      });
      final msg = _s(r['toast']).isNotEmpty ? _s(r['toast']) : _s(r['message']);
      if (msg.isNotEmpty && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (_) {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = _rows(_list['groups']);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(_s(_list['title']), style: Ds.t.subtitle),
                ),
                Text(_s(_list['value_display']), style: Ds.t.subtitle),
              ],
            ),
            SizedBox(height: Ds.space.x4),
            Text(
              '${_s(_list['count_label'])} · ${_s(_list['cost_note'])}',
              style: Ds.t.caption,
            ),
            SizedBox(height: Ds.space.x16),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (groups.isEmpty)
                    Text(_s(_list['empty']), style: Ds.t.bodySecondary),
                  for (final g in groups) ...[
                    Text(
                      '${_s(g['supplier_label'])} · ${_s(g['count_label'])} · ${_s(g['value_display'])}',
                      style: Ds.t.bodyStrong,
                    ),
                    SizedBox(height: Ds.space.x8),
                    for (final it in _rows(g['items'])) ...[
                      _ReturnItemRow(item: it),
                      SizedBox(height: Ds.space.x8),
                    ],
                    SizedBox(height: Ds.space.x16),
                  ],
                ],
              ),
            ),
            if (_s(_list['pending_note']).isNotEmpty) ...[
              Text(_s(_list['pending_note']), style: Ds.t.caption),
              SizedBox(height: Ds.space.x12),
            ],
            if (_list['can_send'] == true)
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: FilledButton(
                  onPressed: _sending ? null : _send,
                  style: FilledButton.styleFrom(
                    backgroundColor: Ds.c.brand,
                    shape: RoundedRectangleBorder(
                      borderRadius: Ds.r.rButton,
                    ),
                  ),
                  child: Text(
                    _sending ? _s(_list['sending']) : _s(_list['send_button']),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ReturnItemRow extends StatelessWidget {
  final Map<String, dynamic> item;
  const _ReturnItemRow({required this.item});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: EdgeInsets.all(Ds.space.x12),
    decoration: BoxDecoration(
      color: Ds.c.bg,
      borderRadius: Ds.r.rCard,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(_s(item['product_name']), style: Ds.t.body),
            ),
            Text(_s(item['value_display']), style: Ds.t.bodyStrong),
          ],
        ),
        Text(
          '${_s(item['batch_label'])} · ${_s(item['expiry_label'])} · ${_s(item['qty_label'])}',
          style: Ds.t.caption,
        ),
        if (_s(item['medibo_qty_label']).isNotEmpty)
          Text(_s(item['medibo_qty_label']), style: Ds.t.caption),
        if (_s(item['source_hint']).isNotEmpty)
          Text(_s(item['source_hint']), style: Ds.t.caption),
        if (_s(item['medibo_message']).isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          ShieldChip(
            label: _s(item['medibo_message']),
            tone: _s(item['medibo_status']) == 'raised' ? 'success' : 'warning',
          ),
        ],
      ],
    ),
  );
}
