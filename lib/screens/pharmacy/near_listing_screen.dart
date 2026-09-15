// CMD #426 — the pharmacy's side of the consumer listing.
//
// The whole /near product rests on this screen being HONEST about what opting
// in exposes, because a pharmacy that feels tricked will opt out and tell every
// other pharmacy in the zone. So the consequence sentence is not fine print at
// the bottom: it sits under the toggle, it is the backend's own words, and it
// names what is NOT shared (quantities, purchase prices, suppliers, bills) as
// plainly as what is.
//
// Opt-in is strictly a decision, never a default: `is_listed` arrives false
// for a pharmacy that has never touched this screen, and nothing in this file
// can flip it on their behalf.
//
// Computes nothing. The tier sentence beside each item is the same backend
// string a consumer would see — so the owner reads exactly the claim being
// made about their shelf, which is the only way "mark unavailable" is a fair
// control to offer.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_tokens.dart';
import '../../services/near_api.dart';
import '../../utils/render_log.dart';

String _s(Object? v) => v == null ? '' : v.toString();
Map<String, dynamic> _m(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

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

class NearListingScreen extends StatefulWidget {
  final NearRpc? rpc;
  const NearListingScreen({super.key, this.rpc});

  @override
  State<NearListingScreen> createState() => _NearListingScreenState();
}

class _NearListingScreenState extends State<NearListingScreen> {
  Map<String, dynamic>? _p;
  bool _busy = false;
  Timer? _poll;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : NearApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final r = await _call('near_listing_get', const {});
    if (!mounted) return;
    setState(() => _p = r);
    RenderLog.write('c426_near_own', r['ok'] == true ? 1 : 0);
    _syncPoll(r);
  }

  /// The poster is asked for and then polled on the BACKEND's own `poll_ms` —
  /// this screen never invents an interval or a timeout of its own.
  void _syncPoll(Map<String, dynamic> r) {
    final poster = _m(r['poster']);
    final building = _s(poster['status']) == 'building';
    _poll?.cancel();
    if (!building) return;
    final ms = (poster['poll_ms'] is num)
        ? (poster['poll_ms'] as num).toInt()
        : 3000;
    _poll = Timer(Duration(milliseconds: ms), _load);
  }

  Future<void> _apply(Future<Map<String, dynamic>> future) async {
    if (_busy) return;
    setState(() => _busy = true);
    final r = await future;
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r['ok'] == true) _p = r;
    });
    final toast = _s(r['toast']).isNotEmpty ? _s(r['toast']) : _s(r['message']);
    if (toast.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(toast)));
    }
    _syncPoll(_m(_p));
  }

  Future<void> _makePoster() async {
    if (_busy) return;
    setState(() => _busy = true);
    final r = await _call('near_poster_request', const {});
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r['ok'] == true) _p = r;
    });
    final token = _s(r['token']);
    if (token.isNotEmpty) {
      unawaited(NearApi.posterRender(token).then((_) => _load()));
    }
    _syncPoll(_m(_p));
  }

  Future<void> _openPoster(Map<String, dynamic> poster) async {
    final url = await NearApi.posterUrl(
      _s(poster['bucket']),
      _s(poster['path']),
    );
    if (url == null) return;
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s(p?['title']))),
      body: p == null
          ? const _OwnSkeleton()
          : p['ok'] != true
              ? Padding(
                  padding: EdgeInsets.all(Ds.space.x16),
                  child: Text(_s(p['message']), style: Ds.t.body),
                )
              : ListView(
                  padding: EdgeInsets.all(Ds.space.x16),
                  children: [
                    _toggleCard(p),
                    SizedBox(height: Ds.space.x24),
                    _posterCard(_m(p['poster'])),
                    SizedBox(height: Ds.space.x24),
                    Text(_s(p['items_title']), style: Ds.t.subtitle),
                    SizedBox(height: Ds.space.x12),
                    ..._itemRows(p),
                  ],
                ),
    );
  }

  Widget _toggleCard(Map<String, dynamic> p) {
    final listed = p['is_listed'] == true;
    final url = _s(p['public_url']);
    return Container(
      decoration: _card(),
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_s(p['opt_in_label']), style: Ds.t.subtitle),
              ),
              Switch(
                value: listed,
                onChanged: _busy
                    ? null
                    : (v) => _apply(_call('near_listing_set', {'p_opt_in': v})),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Text(_s(p['opt_in_note']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x16),
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(Ds.space.x12),
            decoration: BoxDecoration(
              color: _toneSoft(_s(p['state_tone'])),
              borderRadius: Ds.r.rChip,
            ),
            child: Text(
              _s(p['state_label']),
              style: Ds.t.caption.copyWith(color: _tone(_s(p['state_tone']))),
            ),
          ),
          if (listed) ...[
            SizedBox(height: Ds.space.x16),
            Row(
              children: [
                Expanded(
                  child: Text(_s(p['phone_label']), style: Ds.t.body),
                ),
                Switch(
                  value: p['show_phone'] == true,
                  onChanged: _busy
                      ? null
                      : (v) => _apply(
                            _call('near_listing_set', {'p_show_phone': v}),
                          ),
                ),
              ],
            ),
            if (url.isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(url, style: Ds.t.caption),
            ],
          ],
        ],
      ),
    );
  }

  Widget _posterCard(Map<String, dynamic> poster) {
    final ready = poster['ready'] == true;
    return Container(
      decoration: _card(),
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(poster['title']), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x8),
          Text(_s(poster['note']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ready
                ? OutlinedButton(
                    onPressed: () => _openPoster(poster),
                    child: Text(_s(poster['button'])),
                  )
                : FilledButton(
                    onPressed: (_busy || poster['can_request'] != true)
                        ? null
                        : _makePoster,
                    child: Text(_s(poster['button'])),
                  ),
          ),
        ],
      ),
    );
  }

  List<Widget> _itemRows(Map<String, dynamic> p) {
    final items = _rows(p['items']);
    if (items.isEmpty) {
      return [
        Container(
          decoration: _card(),
          padding: EdgeInsets.all(Ds.space.x24),
          child: Text(_s(p['items_empty']), style: Ds.t.caption),
        ),
      ];
    }
    return [
      for (final it in items) ...[
        _itemRow(it),
        SizedBox(height: Ds.space.x8),
      ],
    ];
  }

  Widget _itemRow(Map<String, dynamic> it) {
    final tier = _m(it['tier']);
    final hidden = it['hidden'] == true;
    final id = (it['medicine_id'] is num)
        ? (it['medicine_id'] as num).toInt()
        : null;
    return Container(
      decoration: _card(),
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(it['name']), style: Ds.t.body),
          SizedBox(height: Ds.space.x8),
          Text(
            hidden ? _s(it['hidden_label']) : _s(tier['label']),
            style: Ds.t.caption.copyWith(
              color: hidden ? Ds.c.textSecondary : _tone(_s(tier['tone'])),
            ),
          ),
          SizedBox(height: Ds.space.x12),
          SizedBox(
            height: 44,
            child: OutlinedButton(
              onPressed: (_busy || id == null)
                  ? null
                  : () => _apply(
                        hidden
                            ? _call('near_mark_available', {'p_medicine_id': id})
                            : _call('near_mark_unavailable',
                                {'p_medicine_id': id, 'p_hours': 24}),
                      ),
              child: Text(
                hidden ? _s(it['undo_label']) : _s(it['mark_label']),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OwnSkeleton extends StatelessWidget {
  const _OwnSkeleton();

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.all(Ds.space.x16),
    children: [
      for (var i = 0; i < 4; i++) ...[
        Container(
          width: double.infinity,
          height: 132,
          decoration: _card(),
        ),
        SizedBox(height: Ds.space.x12),
      ],
    ],
  );
}
