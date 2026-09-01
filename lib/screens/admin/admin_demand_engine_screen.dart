// CMD #427 — THE DEMAND ENGINE. Om's buying desk: what a zone actually buys,
// at what rate, and from whom — learned from every bill sitting in every
// pharmacy's vault, including the ones mediBO never supplied.
//
// THIS FILE AGGREGATES NOTHING. Top movers, risers, the rate spread and the
// seasonal shape are four lists that arrive finished from
// `admin_demand_engine()`. Every rupee, unit count, percentage, cohort line and
// "x1.5 this month" factor is a backend string. There is no sort here, no
// median, no growth calculation and no threshold for what counts as "rising" —
// those live next to the cohort floor that makes them legal to show at all.
//
// AND IT NAMES NO PHARMACY, because the payload names none. Every row carries
// the number of pharmacies behind it and nothing that identifies one. The
// supplier column is a supplier, never a buyer.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/demand_engine_api.dart';
import '../../utils/render_log.dart';
import '../pharmacy/pharmacy_expiry_screen.dart' show toneColor, toneSoft;

String _s(Object? v) => v == null ? '' : v.toString();
List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

class AdminDemandEngineScreen extends StatefulWidget {
  const AdminDemandEngineScreen({super.key, this.rpc, this.onOpenRoute});

  final DemandRpc? rpc;
  final void Function(String route)? onOpenRoute;

  @override
  State<AdminDemandEngineScreen> createState() =>
      _AdminDemandEngineScreenState();
}

class _AdminDemandEngineScreenState extends State<AdminDemandEngineScreen> {
  Map<String, dynamic> _payload = const {};
  bool _loading = true;
  int? _zone;
  String? _month;
  String _tab = '';

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : DemandEngineApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    Map<String, dynamic> res;
    try {
      res = await _call('admin_demand_engine', {
        if (_zone != null) 'p_zone': _zone,
        if (_month != null) 'p_month': _month,
      });
    } catch (_) {
      res = const {};
    }
    if (!mounted) return;
    final tabs = _rows(res['tabs']);
    setState(() {
      _payload = res;
      _loading = false;
      // The tab list is the BACKEND's. A key this build has never heard of is
      // still selectable; it just renders the list the payload sent for it.
      if (_tab.isEmpty && tabs.isNotEmpty) _tab = _s(tabs.first['key']);
    });
    RenderLog.write('demand_movers', _rows(res['movers']).length);
    RenderLog.write('demand_engine_screen', 1);
  }

  List<Map<String, dynamic>> get _current => _rows(_payload[_tab]);

  @override
  Widget build(BuildContext context) {
    final ok = _payload['ok'] == true;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(_s(_payload['title'])),
        backgroundColor: Ds.c.surface,
        elevation: 0,
      ),
      body: _loading
          ? const _DemandSkeleton()
          : !ok
          ? _Refusal(message: _s(_payload['message']), onRetry: _load)
          : RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    final rows = _current;
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(_s(_payload['subtitle']), style: Ds.t.caption),
        SizedBox(height: Ds.space.x16),
        _Picker(
          options: _rows(_payload['zones']),
          selected: _payload['zone_id']?.toString() ?? '',
          onPick: (k) {
            _zone = int.tryParse(k);
            _load();
          },
        ),
        SizedBox(height: Ds.space.x8),
        _Picker(
          options: _rows(_payload['months']),
          selected: _s(_payload['month_key']),
          onPick: (k) {
            _month = k;
            _load();
          },
        ),
        SizedBox(height: Ds.space.x24),
        _Tiles(tiles: _rows(_payload['tiles'])),
        SizedBox(height: Ds.space.x24),
        _Picker(
          options: _rows(_payload['tabs']),
          selected: _tab,
          onPick: (k) => setState(() => _tab = k),
        ),
        SizedBox(height: Ds.space.x16),
        if (rows.isEmpty)
          _Empty(text: _s(_payload['empty']))
        else
          ...rows.map(
            (r) => Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: _DemandRow(
                row: r,
                onOpen: () {
                  final route = _s(r['route']);
                  if (route.isEmpty) return;
                  if (widget.onOpenRoute != null) {
                    widget.onOpenRoute!(route);
                  } else {
                    Navigator.of(context).pushNamed(route);
                  }
                },
              ),
            ),
          ),
        SizedBox(height: Ds.space.x24),
        _Privacy(text: _s(_payload['privacy'])),
      ],
    );
  }
}

/// One chip strip. Zones, months and tabs are all the same shape — a list of
/// {key,label} the backend sent — so they are all drawn by the same widget and
/// none of them is a Dart list of options.
class _Picker extends StatelessWidget {
  const _Picker({
    required this.options,
    required this.selected,
    required this.onPick,
  });

  final List<Map<String, dynamic>> options;
  final String selected;
  final void Function(String key) onPick;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: Ds.space.x8,
      runSpacing: Ds.space.x8,
      children: options.map((o) {
        final key = _s(o['key']);
        final on = key == selected;
        return InkWell(
          onTap: () => onPick(key),
          borderRadius: Ds.r.rChip,
          child: Container(
            constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
            padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x16,
              vertical: Ds.space.x8,
            ),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? toneSoft('success') : Ds.c.surface,
              borderRadius: Ds.r.rChip,
              border: Border.all(color: on ? Ds.c.brand : Ds.c.divider),
            ),
            child: Text(
              _s(o['label']),
              style: Ds.t.caption.copyWith(
                color: on ? Ds.c.brand : Ds.c.textSecondary,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _Tiles extends StatelessWidget {
  const _Tiles({required this.tiles});
  final List<Map<String, dynamic>> tiles;

  @override
  Widget build(BuildContext context) {
    if (tiles.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 560;
        final per = wide ? 3 : 2;
        return Wrap(
          spacing: Ds.space.x12,
          runSpacing: Ds.space.x12,
          children: tiles.map((t) {
            final w = (c.maxWidth - Ds.space.x12 * (per - 1)) / per;
            return SizedBox(
              width: w,
              child: Container(
                padding: EdgeInsets.all(Ds.space.x16),
                decoration: BoxDecoration(
                  color: Ds.c.surface,
                  borderRadius: Ds.r.rCard,
                  boxShadow: Ds.elevation.e1,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_s(t['value']), style: Ds.t.title),
                    SizedBox(height: Ds.space.x4),
                    Text(_s(t['label']), style: Ds.t.caption),
                  ],
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

/// One row in whichever list is on screen. Every optional line is drawn only
/// when the payload sent it — an absent supplier, spread or delta is an
/// ABSENCE, never a dash this file invented.
class _DemandRow extends StatelessWidget {
  const _DemandRow({required this.row, required this.onOpen});
  final Map<String, dynamic> row;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final tone = _s(row['tone']);
    final name = _s(row['label']).isNotEmpty ? _s(row['label']) : _s(row['name']);
    final supplier = _s(row['supplier']);
    final delta = _s(row['delta_label']);
    final factor = _s(row['factor_label']);
    final tappable = _s(row['route']).isNotEmpty;

    final card = Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(name, style: Ds.t.subtitle)),
              if (delta.isNotEmpty || factor.isNotEmpty)
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x8,
                    vertical: Ds.space.x4,
                  ),
                  decoration: BoxDecoration(
                    color: toneSoft(tone),
                    borderRadius: Ds.r.rChip,
                  ),
                  child: Text(
                    delta.isNotEmpty ? delta : factor,
                    style: Ds.t.caption.copyWith(color: toneColor(tone)),
                  ),
                ),
            ],
          ),
          if (supplier.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(supplier, style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x8),
          Wrap(
            spacing: Ds.space.x12,
            runSpacing: Ds.space.x4,
            children: [
              for (final k in const [
                'units_label',
                'rate_label',
                'spread_label',
                'range_label',
                'vs_label',
                'cohort_label',
              ])
                if (_s(row[k]).isNotEmpty)
                  Text(_s(row[k]), style: Ds.t.caption),
            ],
          ),
        ],
      ),
    );

    if (!tappable) return card;
    return InkWell(
      onTap: onOpen,
      borderRadius: Ds.r.rCard,
      child: card,
    );
  }
}

class _Privacy extends StatelessWidget {
  const _Privacy({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.infoSoft,
        borderRadius: Ds.r.rCard,
      ),
      child: Text(text, style: Ds.t.caption.copyWith(color: Ds.c.info)),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(vertical: Ds.space.x48),
    child: Text(text, textAlign: TextAlign.center, style: Ds.t.bodySecondary),
  );
}

class _Refusal extends StatelessWidget {
  const _Refusal({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: EdgeInsets.all(Ds.space.x24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center, style: Ds.t.body),
          SizedBox(height: Ds.space.x16),
          OutlinedButton(onPressed: onRetry, child: const Text('↻')),
        ],
      ),
    ),
  );
}

class _DemandSkeleton extends StatelessWidget {
  const _DemandSkeleton();

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.all(Ds.space.x16),
    children: List.generate(
      5,
      (_) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x12),
        child: Container(
          height: Ds.space.x48 + Ds.space.x24,
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
          ),
        ),
      ),
    ),
  );
}
