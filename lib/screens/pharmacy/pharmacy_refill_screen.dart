// CMD #417 — the refill console: reminders, the WhatsApp storefront and the
// AI counter, on one screen the pharmacy already knows how to read.
//
// THIS FILE DECIDES NOTHING. Every date sentence ("Runs out 04 Sep"), every
// tone, every cap sentence, every plural, every empty state and every button
// caption is a finished string from `refill_home()`. The screen renders four
// tabs the BACKEND named, in the order the backend sent them.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design_tokens.dart';
import '../../services/pharmacy_refill_api.dart';
import '../../utils/render_log.dart';

String _s(Object? v) => v == null ? '' : v.toString();
Map<String, dynamic> _m(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

/// The backend names a tone; this maps the NAME to the theme. It never decides
/// which tone a row gets.
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

class PharmacyRefillScreen extends StatefulWidget {
  const PharmacyRefillScreen({super.key, this.rpc});

  /// Tests hand a payload instead of a network.
  final RefillRpc? rpc;

  @override
  State<PharmacyRefillScreen> createState() => _PharmacyRefillScreenState();
}

class _PharmacyRefillScreenState extends State<PharmacyRefillScreen> {
  Map<String, dynamic> _home = const {};
  String _refusal = '';
  bool _failed = false;
  bool _loading = true;
  bool _busy = false;
  String _tab = '';
  String _query = '';
  Timer? _debounce;
  final TextEditingController _search = TextEditingController();

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
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final res = await _call('refill_home', {
        if (_query.isNotEmpty) 'p_q': _query,
      });
      if (!mounted) return;
      if (res['ok'] != true) {
        setState(() {
          _refusal = _s(res['message']);
          _loading = false;
        });
        RenderLog.write('c417_refill_denied', 1);
        return;
      }
      _apply(res);
      RenderLog.write('c417_refill_home', 1);
      RenderLog.write('c417_refill_due', _rows(_m(res['due'])['rows']).length);
      RenderLog.write(
        'c417_refill_requests',
        _rows(_m(res['requests'])['rows']).length,
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  void _apply(Map<String, dynamic> res) {
    final tabs = _rows(res['tabs']);
    setState(() {
      _home = res;
      _loading = false;
      _failed = false;
      if (_tab.isEmpty && tabs.isNotEmpty) _tab = _s(tabs.first['key']);
    });
  }

  void _onSearch(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      _query = q.trim();
      _boot();
    });
  }

  void _toast(String msg) {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _run(
    String fn,
    Map<String, dynamic> params, {
    bool reload = true,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await _call(fn, params);
      if (!mounted) return;
      _toast(_s(res['message']));
      if (res['ok'] == true && res.containsKey('tabs')) {
        _apply(res);
      } else if (reload) {
        await _boot();
      }
    } catch (_) {
      // a failed action leaves the screen exactly as it was
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s(_home['title']))),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const _Skeleton();
    if (_refusal.isNotEmpty) return _Refusal(message: _refusal);
    if (_failed) {
      return _Refusal(
        message: '',
        onRetry: () {
          setState(() => _loading = true);
          _boot();
        },
      );
    }

    return RefreshIndicator(
      onRefresh: _boot,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          Ds.space.x16,
          Ds.space.x16,
          Ds.space.x16,
          Ds.space.x48,
        ),
        children: [
          _engineCard(),
          SizedBox(height: Ds.space.x24),
          _storefrontCard(),
          SizedBox(height: Ds.space.x24),
          _searchField(),
          SizedBox(height: Ds.space.x12),
          _tabRow(),
          SizedBox(height: Ds.space.x16),
          ..._tabBody(),
        ],
      ),
    );
  }

  // ── the engine: the shop's own switch, and the caps it runs under ────────
  Widget _engineCard() {
    final e = _m(_home['engine']);
    final tone = _s(e['status_tone']);
    return Container(
      decoration: _card(),
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(_s(e['title']), style: Ds.t.subtitle)),
              Switch(
                value: e['enabled'] == true,
                activeThumbColor: Ds.c.brand,
                onChanged: _busy
                    ? null
                    : (v) => _run('refill_settings_save', {
                        'p_patch': {'enabled': v},
                      }),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x12,
              vertical: Ds.space.x8,
            ),
            decoration: BoxDecoration(
              color: _toneSoft(tone),
              borderRadius: Ds.r.rChip,
            ),
            child: Text(
              _s(e['status_label']),
              style: Ds.t.caption.copyWith(color: _toneColor(tone)),
            ),
          ),
          SizedBox(height: Ds.space.x12),
          Text(_s(e['cap_label']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Text(_s(e['daily_label']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Text(_s(e['quiet_label']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x12),
          Row(
            children: [
              Expanded(
                child: Text(_s(e['sent_today_label']), style: Ds.t.caption),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _run('refill_scan', {'p_days': 180}),
                child: Text(_s(e['scan_label'])),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── the storefront: the link, the QR-able URL, and the AI switch ─────────
  Widget _storefrontCard() {
    final sf = _m(_home['storefront']);
    final url = _s(sf['url']);
    return Container(
      decoration: _card(),
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(_s(sf['title']), style: Ds.t.subtitle)),
              Switch(
                value: sf['is_active'] == true,
                activeThumbColor: Ds.c.brand,
                onChanged: _busy
                    ? null
                    : (v) => _run('storefront_save', {
                        'p_patch': {'is_active': v},
                      }),
              ),
            ],
          ),
          Text(_s(sf['hint']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x12),
          if (url.isNotEmpty)
            Container(
              padding: EdgeInsets.all(Ds.space.x12),
              decoration: BoxDecoration(
                color: Ds.c.bg,
                borderRadius: Ds.r.rChip,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      url,
                      style: Ds.t.caption,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  SizedBox(width: Ds.space.x8),
                  TextButton(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: url));
                      _toast(_s(sf['copy_label']));
                    },
                    child: Text(_s(sf['copy_label'])),
                  ),
                ],
              ),
            ),
          SizedBox(height: Ds.space.x12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_s(sf['ai_label']), style: Ds.t.body),
                    Text(_s(sf['ai_hint']), style: Ds.t.caption),
                  ],
                ),
              ),
              Switch(
                value: sf['ai_enabled'] == true,
                activeThumbColor: Ds.c.brand,
                onChanged: _busy
                    ? null
                    : (v) => _run('refill_settings_save', {
                        'p_patch': {'ai_enabled': v},
                      }),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _searchField() => TextField(
    controller: _search,
    onChanged: _onSearch,
    decoration: InputDecoration(
      prefixIcon: const Icon(Icons.search),
      hintText: _s(_m(_home['storefront'])['search_hint']),
    ),
  );

  /// The tab LIST is the backend's, including its counts. An unknown key
  /// renders an empty body rather than throwing.
  Widget _tabRow() {
    final tabs = _rows(_home['tabs']);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final t in tabs)
            Padding(
              padding: EdgeInsets.only(right: Ds.space.x8),
              child: ChoiceChip(
                label: Text(
                  '${_s(t['label'])} (${_s(t['count'])})',
                  style: Ds.t.caption,
                ),
                selected: _tab == _s(t['key']),
                selectedColor: Ds.c.brandSoft,
                onSelected: (_) => setState(() => _tab = _s(t['key'])),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _tabBody() {
    switch (_tab) {
      case 'due':
        return _list(_m(_home['due']), _dueTile);
      case 'patients':
        return _list(_m(_home['patients']), _patientTile);
      case 'requests':
        return _list(_m(_home['requests']), _requestTile);
      case 'counter':
        return _list(_m(_home['counter']), _conversationTile);
      default:
        return const [];
    }
  }

  List<Widget> _list(
    Map<String, dynamic> block,
    Widget Function(Map<String, dynamic>) tile,
  ) {
    final rows = _rows(block['rows']);
    if (rows.isEmpty) return [_Empty(message: _s(block['empty_label']))];
    return [
      for (final r in rows)
        Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x12),
          child: tile(r),
        ),
    ];
  }

  Widget _dueTile(Map<String, dynamic> r) {
    final tone = _s(r['tone']);
    return Container(
      decoration: _card(),
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_s(r['product_name']), style: Ds.t.bodyStrong),
              ),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x8,
                  vertical: Ds.space.x4,
                ),
                decoration: BoxDecoration(
                  color: _toneSoft(tone),
                  borderRadius: Ds.r.rChip,
                ),
                child: Text(
                  _s(r['runs_out_label']),
                  style: Ds.t.caption.copyWith(color: _toneColor(tone)),
                ),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Text(_s(r['patient_name']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Text(
            '${_s(r['dose_label'])} · ${_s(r['pack_units_label'])} · '
            '${_s(r['last_bought_label'])}',
            style: Ds.t.caption,
          ),
          SizedBox(height: Ds.space.x12),
          Row(
            children: [
              TextButton(
                onPressed: _busy ? null : () => _openDoseSheet(r),
                child: Text(_s(r['dose_label'])),
              ),
              const Spacer(),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  minimumSize: Size(Ds.space.x48 * 2, Ds.space.x48),
                ),
                onPressed: (_busy || r['can_nudge'] != true)
                    ? null
                    : () => _run('refill_nudge_now', {
                        'p_schedule_id': _s(r['id']),
                      }),
                child: Text(_s(r['nudge_label'])),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _patientTile(Map<String, dynamic> r) => Container(
    decoration: _card(),
    padding: EdgeInsets.all(Ds.space.x16),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_s(r['name']), style: Ds.t.bodyStrong),
              SizedBox(height: Ds.space.x4),
              Text(_s(r['items_label']), style: Ds.t.caption),
              SizedBox(height: Ds.space.x4),
              Text(_s(r['optin_hint']), style: Ds.t.caption),
            ],
          ),
        ),
        Switch(
          value: r['opted_in'] == true,
          activeThumbColor: Ds.c.brand,
          onChanged: _busy
              ? null
              : (v) => _run('refill_patient_optin', {
                  'p_patient_id': _s(r['id']),
                  'p_on': v,
                }),
        ),
      ],
    ),
  );

  Widget _requestTile(Map<String, dynamic> r) => Container(
    decoration: _card(),
    padding: EdgeInsets.all(Ds.space.x16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(_s(r['patient_name']), style: Ds.t.bodyStrong),
            ),
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x8,
                vertical: Ds.space.x4,
              ),
              decoration: BoxDecoration(
                color: Ds.c.infoSoft,
                borderRadius: Ds.r.rChip,
              ),
              child: Text(
                _s(r['source_label']),
                style: Ds.t.caption.copyWith(color: Ds.c.info),
              ),
            ),
          ],
        ),
        SizedBox(height: Ds.space.x4),
        Text(_s(r['items_label']), style: Ds.t.body),
        SizedBox(height: Ds.space.x4),
        Text(_s(r['created_label']), style: Ds.t.caption),
        SizedBox(height: Ds.space.x12),
        Row(
          children: [
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run('pos_reservation_close', {
                      'p_id': _s(r['id']),
                      'p_status': 'cancelled',
                    }),
              child: Text(_s(r['cancel_label'])),
            ),
            const Spacer(),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Ds.c.brand,
                minimumSize: Size(Ds.space.x48 * 2, Ds.space.x48),
              ),
              onPressed: _busy
                  ? null
                  : () => _run('pos_reservation_close', {
                      'p_id': _s(r['id']),
                      'p_status': 'billed',
                    }),
              child: Text(_s(r['bill_label'])),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _conversationTile(Map<String, dynamic> r) {
    final tone = _s(r['state_tone']);
    return Container(
      decoration: _card(),
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(_s(r['phone']), style: Ds.t.bodyStrong)),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x8,
                  vertical: Ds.space.x4,
                ),
                decoration: BoxDecoration(
                  color: _toneSoft(tone),
                  borderRadius: Ds.r.rChip,
                ),
                child: Text(
                  _s(r['state_label']),
                  style: Ds.t.caption.copyWith(color: _toneColor(tone)),
                ),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Text(_s(r['last_message']), style: Ds.t.body),
          SizedBox(height: Ds.space.x4),
          Text(
            '${_s(r['count_label'])} · ${_s(r['last_label'])}',
            style: Ds.t.caption,
          ),
        ],
      ),
    );
  }

  /// The dose assumption, edited by the pharmacy. The screen sends the two
  /// numbers; the BACKEND recomputes days_supply and the run-out date.
  Future<void> _openDoseSheet(Map<String, dynamic> r) async {
    final dose = TextEditingController(text: _s(r['dose_per_day']));
    final pack = TextEditingController(text: _s(r['pack_units']));
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
            Text(_s(r['product_name']), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: dose,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: _s(r['dose_label'])),
            ),
            SizedBox(height: Ds.space.x12),
            TextField(
              controller: pack,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: _s(r['pack_units_label']),
              ),
            ),
            SizedBox(height: Ds.space.x24),
            SizedBox(
              width: double.infinity,
              height: Ds.space.x48,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
                onPressed: () {
                  Navigator.pop(ctx);
                  _run('refill_schedule_set', {
                    'p_id': _s(r['id']),
                    'p_patch': {
                      'dose_per_day': num.tryParse(dose.text.trim()),
                      'pack_units': num.tryParse(pack.text.trim()),
                    },
                  });
                },
                child: Text(_s(r['nudge_label'])),
              ),
            ),
          ],
        ),
      ),
    );
    dose.dispose();
    pack.dispose();
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Container(
    decoration: _card(),
    padding: EdgeInsets.all(Ds.space.x24),
    child: Text(message, style: Ds.t.bodySecondary),
  );
}

class _Refusal extends StatelessWidget {
  const _Refusal({required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: EdgeInsets.all(Ds.space.x24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, style: Ds.t.bodySecondary, textAlign: TextAlign.center),
          if (onRetry != null) ...[
            SizedBox(height: Ds.space.x16),
            OutlinedButton(
              onPressed: onRetry,
              child: const Icon(Icons.refresh),
            ),
          ],
        ],
      ),
    ),
  );
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.all(Ds.space.x16),
    children: [
      for (var i = 0; i < 4; i++)
        Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x12),
          child: Container(
            height: Ds.space.x48 * 2,
            decoration: BoxDecoration(
              color: Ds.c.surface,
              borderRadius: Ds.r.rCard,
            ),
          ),
        ),
    ],
  );
}
