// CMD #426 — the consumer surface: medibo.in/near.
//
// The one screen in mediBO that is not for a business. No login, no app store,
// no account: a person with a prescription in their hand asks which pharmacy
// nearby is likely to have it. That question has no honest answer anywhere in
// India today, and the reason is that nobody will publish stock they are not
// certain of. mediBO can, because it says out loud how certain it is.
//
// So the discipline here is stricter than "render the payload verbatim", which
// it also does. This screen must never make availability look MORE certain
// than the backend said:
//   * the sentence on a card is `tier.label`, never a Dart string, and its
//     colour is `tier.tone` — a card cannot be green unless SQL said 'success';
//   * the confidence NUMBER never reaches this file, so no widget can round it,
//     bucket it or draw a bar from it;
//   * the disclaimer is not decoration — it renders on every result set, from
//     the same payload as the results;
//   * an empty result is the backend's own sentence, never "0 results".
//
// It computes exactly two things, both of them geometry: whether the viewport
// is wide, and where the cards go.
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_tokens.dart';
import '../../services/device_location.dart';
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

Future<void> _open(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

// ═══════════════════════════════════════════════════════════════════════════
// The search page
// ═══════════════════════════════════════════════════════════════════════════

class NearScreen extends StatefulWidget {
  final NearRpc? rpc;
  const NearScreen({super.key, this.rpc});

  @override
  State<NearScreen> createState() => _NearScreenState();
}

class _NearScreenState extends State<NearScreen> {
  final _q = TextEditingController();
  final _pin = TextEditingController();

  Map<String, dynamic> _boot = const {};
  Map<String, dynamic>? _result;
  bool _loadingBoot = true;
  bool _searching = false;
  bool _locating = false;
  double? _lat;
  double? _lng;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : NearApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _loadBoot();
  }

  @override
  void dispose() {
    _q.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _loadBoot() async {
    final r = await _call('near_boot', const {});
    if (!mounted) return;
    setState(() {
      _boot = r;
      _loadingBoot = false;
    });
    RenderLog.write('c426_near', r['enabled'] == true ? 1 : 0);
  }

  Map<String, dynamic> get _copy => _m(_boot['copy']);
  String _c(String k) => _s(_copy[k]);

  Future<void> _locate() async {
    setState(() => _locating = true);
    final fix = await DeviceLocation.current();
    if (!mounted) return;
    setState(() {
      _locating = false;
      _lat = fix?.lat;
      _lng = fix?.lng;
    });
    // A denied permission is not an error here — the pincode row below is the
    // whole point of having a fallback. Just search with what we have and let
    // the backend say `need_origin` if it still cannot place the caller.
    if (_q.text.trim().isNotEmpty) await _search();
  }

  Future<void> _search() async {
    if (_searching) return;
    setState(() => _searching = true);
    final pin = _pin.text.trim();
    final r = await _call('near_search', {
      'p_q': _q.text.trim(),
      if (_lat != null) 'p_lat': _lat,
      if (_lng != null) 'p_lng': _lng,
      if (pin.isNotEmpty) 'p_pincode': pin,
    });
    if (!mounted) return;
    setState(() {
      _result = r;
      _searching = false;
    });
    RenderLog.write('c426_near_search', _rows(r['rows']).length);
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingBoot) return const _NearSkeleton();
    if (_boot['enabled'] == false) {
      return _NearShell(
        child: _NearNotice(text: _c('disabled'), tone: 'info'),
      );
    }
    return _NearShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_c('title'), style: Ds.t.display, textAlign: TextAlign.left),
          SizedBox(height: Ds.space.x8),
          Text(_c('subtitle'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x24),
          _searchBar(),
          SizedBox(height: Ds.space.x12),
          _originRow(),
          SizedBox(height: Ds.space.x24),
          Expanded(child: _results()),
        ],
      ),
    );
  }

  Widget _searchBar() => Row(
    children: [
      Expanded(
        child: TextField(
          controller: _q,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
          decoration: InputDecoration(hintText: _c('search_hint')),
        ),
      ),
      SizedBox(width: Ds.space.x8),
      SizedBox(
        height: 48,
        child: FilledButton(
          onPressed: _searching ? null : _search,
          child: Text(_c('search_button')),
        ),
      ),
    ],
  );

  Widget _originRow() => Wrap(
    spacing: Ds.space.x8,
    runSpacing: Ds.space.x8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      SizedBox(
        height: 44,
        child: OutlinedButton.icon(
          onPressed: _locating ? null : _locate,
          icon: const Icon(Icons.my_location, size: 18),
          label: Text(_locating ? _c('locating') : _c('locate_button')),
        ),
      ),
      SizedBox(
        width: 180,
        child: TextField(
          controller: _pin,
          keyboardType: TextInputType.number,
          onSubmitted: (_) => _search(),
          decoration: InputDecoration(hintText: _c('pincode_hint')),
        ),
      ),
    ],
  );

  Widget _results() {
    final r = _result;
    if (_searching) return const _NearSkeleton(compact: true);
    if (r == null) return _NearNotice(text: _c('empty'), tone: 'info');

    // Every refusal — rate limited, no origin, too short, switched off — is the
    // BACKEND's sentence. There is no Dart fallback wording anywhere here,
    // because a fallback is how a page ends up lying about why it is empty.
    if (r['ok'] != true) {
      return _NearNotice(text: _s(r['message']), tone: _s(r['tone']));
    }

    final rows = _rows(r['rows']);
    if (rows.isEmpty) {
      return _NearNotice(
        text: _s(r['empty_label']),
        hint: _s(r['empty_hint']),
        tone: 'info',
      );
    }

    return ListView.separated(
      padding: EdgeInsets.only(bottom: Ds.space.x32),
      itemCount: rows.length + 2,
      separatorBuilder: (_, __) => SizedBox(height: Ds.space.x12),
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x4),
            child: Text(_s(r['count_label']), style: Ds.t.subtitle),
          );
        }
        if (i == rows.length + 1) return _Disclaimer(result: r);
        return _NearCard(row: rows[i - 1]);
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// One pharmacy card
// ═══════════════════════════════════════════════════════════════════════════

class _NearCard extends StatelessWidget {
  final Map<String, dynamic> row;
  const _NearCard({required this.row});

  @override
  Widget build(BuildContext context) {
    final tier = _m(row['tier']);
    final call = _m(row['call']);
    final dir = _m(row['directions']);
    final tone = _s(tier['tone']);
    final area = _s(row['area_label']);

    return Container(
      decoration: _card(),
      padding: EdgeInsets.all(Ds.space.x16),
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
                    Text(_s(row['name']), style: Ds.t.subtitle),
                    if (area.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(area, style: Ds.t.caption),
                    ],
                  ],
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Text(_s(row['distance_label']), style: Ds.t.caption),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          // THE sentence. Its words and its colour are both the backend's.
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
              _s(tier['label']),
              style: Ds.t.caption.copyWith(color: _tone(tone)),
            ),
          ),
          if (_s(row['matched_label']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(_s(row['matched_label']), style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x16),
          Row(
            children: [
              if (call['has'] == true)
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: FilledButton.icon(
                      onPressed: () => _open('tel:${_s(call['tel'])}'),
                      icon: const Icon(Icons.call, size: 18),
                      label: Text(_s(call['label'])),
                    ),
                  ),
                ),
              if (call['has'] == true && dir['has'] == true)
                SizedBox(width: Ds.space.x8),
              if (dir['has'] == true)
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: OutlinedButton.icon(
                      onPressed: () => _open(_s(dir['url'])),
                      icon: const Icon(Icons.directions_outlined, size: 18),
                      label: Text(_s(dir['label'])),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Disclaimer extends StatelessWidget {
  final Map<String, dynamic> result;
  const _Disclaimer({required this.result});

  @override
  Widget build(BuildContext context) {
    final rx = _s(result['rx_note']);
    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(result['disclaimer']), style: Ds.t.caption),
          if (rx.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(rx, style: Ds.t.caption),
          ],
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// The QR landing page — one pharmacy, reached from its counter poster
// ═══════════════════════════════════════════════════════════════════════════

class NearPharmacyScreen extends StatefulWidget {
  final String token;
  final NearRpc? rpc;
  const NearPharmacyScreen({super.key, required this.token, this.rpc});

  @override
  State<NearPharmacyScreen> createState() => _NearPharmacyScreenState();
}

class _NearPharmacyScreenState extends State<NearPharmacyScreen> {
  Map<String, dynamic>? _p;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = widget.rpc != null
        ? await widget.rpc!('near_pharmacy', {'p_token': widget.token})
        : await NearApi.pharmacy(widget.token);
    if (!mounted) return;
    setState(() => _p = r);
    RenderLog.write('c426_near_pharmacy', r['ok'] == true ? 1 : 0);
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    if (p == null) return const _NearSkeleton();
    if (p['ok'] != true) {
      return _NearShell(
        child: _NearNotice(text: _s(p['message']), tone: _s(p['tone'])),
      );
    }
    final call = _m(p['call']);
    final dir = _m(p['directions']);
    final area = _s(p['area_label']);

    return _NearShell(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_s(p['name']), style: Ds.t.display),
            if (area.isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(area, style: Ds.t.caption),
            ],
            SizedBox(height: Ds.space.x12),
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x12,
                vertical: Ds.space.x8,
              ),
              decoration: BoxDecoration(
                color: Ds.c.successSoft,
                borderRadius: Ds.r.rChip,
              ),
              child: Text(
                _s(p['badge']),
                style: Ds.t.caption.copyWith(color: Ds.c.success),
              ),
            ),
            SizedBox(height: Ds.space.x24),
            Row(
              children: [
                if (call['has'] == true)
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        onPressed: () => _open('tel:${_s(call['tel'])}'),
                        icon: const Icon(Icons.call, size: 18),
                        label: Text(_s(call['label'])),
                      ),
                    ),
                  ),
                if (call['has'] == true && dir['has'] == true)
                  SizedBox(width: Ds.space.x8),
                if (dir['has'] == true)
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        onPressed: () => _open(_s(dir['url'])),
                        icon: const Icon(Icons.directions_outlined, size: 18),
                        label: Text(_s(dir['label'])),
                      ),
                    ),
                  ),
              ],
            ),
            SizedBox(height: Ds.space.x32),
            Text(_s(p['disclaimer']), style: Ds.t.caption),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Shared chrome
// ═══════════════════════════════════════════════════════════════════════════

class _NearShell extends StatelessWidget {
  final Widget child;
  const _NearShell({required this.child});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Ds.c.bg,
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 720;
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: wide ? Ds.space.x32 : Ds.space.x16,
                  vertical: Ds.space.x24,
                ),
                child: child,
              ),
            ),
          );
        },
      ),
    ),
  );
}

class _NearNotice extends StatelessWidget {
  final String text;
  final String hint;
  final String tone;
  const _NearNotice({required this.text, this.hint = '', this.tone = 'info'});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    decoration: _card(),
    padding: EdgeInsets.all(Ds.space.x24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text, style: Ds.t.body.copyWith(color: _tone(tone))),
        if (hint.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(hint, style: Ds.t.caption),
        ],
      ],
    ),
  );
}

class _NearSkeleton extends StatelessWidget {
  final bool compact;
  const _NearSkeleton({this.compact = false});

  Widget _bar(double w, double h) => Container(
    width: w,
    height: h,
    decoration: BoxDecoration(
      color: Ds.c.divider,
      borderRadius: Ds.r.rChip,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!compact) ...[
          _bar(220, 24),
          SizedBox(height: Ds.space.x12),
          _bar(300, 14),
          SizedBox(height: Ds.space.x24),
        ],
        for (var i = 0; i < 3; i++) ...[
          Container(
            width: double.infinity,
            height: 132,
            decoration: _card(),
          ),
          SizedBox(height: Ds.space.x12),
        ],
      ],
    );
    return compact ? body : _NearShell(child: body);
  }
}
