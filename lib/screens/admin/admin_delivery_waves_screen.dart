// lib/screens/admin/admin_delivery_waves_screen.dart — CHANGE #405
//
// Delivery waves: the admin face of the auto-assignment engine. A wave is one
// zone's packed, eligible orders for one time window, distributed across the
// riders who are actually on shift.
//
// THIS FILE DECIDES NOTHING. admin_delivery_waves() answers the whole screen in
// one payload and every word on it was written in SQL — the title, the mode
// help text, each status label, each chip, each rider's "3 stops", the reason
// sentence under every stop, and the label on every button. The only thing
// computed in Dart is layout, plus the tone -> Ds token lookup, and a tone this
// build has never heard of falls back to neutral rather than throwing.
//
// WHY IT IS ITS OWN SCREEN. The delivery queue answers "assign this order"; a
// wave answers "who is carrying what this afternoon". They are different
// questions with different rhythms, and folding the second into the first is
// what made the queue screen unreadable the last time it was tried.
//
// Reachability: registered in feature_registry with deep_link
// '/admin/delivery-waves' (CHANGE #395 — a registry row whose deep_link is a
// real named route is pushed straight onto the navigator), plus the entry card
// on the admin Delivery tab.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';

/// A single RPC call. Injectable so the widget test can drive the screen with
/// real-shaped payloads and no Supabase — the same seam the supplier records
/// screen uses.
typedef WaveRpc = Future<Map<String, dynamic>> Function(
    String fn, Map<String, dynamic> params);

class AdminDeliveryWavesScreen extends StatefulWidget {
  final WaveRpc? rpc;

  const AdminDeliveryWavesScreen({super.key, this.rpc});

  @override
  State<AdminDeliveryWavesScreen> createState() =>
      _AdminDeliveryWavesScreenState();
}

class _AdminDeliveryWavesScreenState extends State<AdminDeliveryWavesScreen> {
  Map<String, dynamic> _data = const {};
  bool _loading = true;
  bool _failed = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) async {
    if (widget.rpc != null) return widget.rpc!(fn, p);
    final res = await Supabase.instance.client.rpc(fn, params: p);
    return res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final res = await _call('admin_delivery_waves', const {});
      if (!mounted) return;
      setState(() {
        _data = res;
        _loading = false;
      });
      RenderLog.write('c405_waves_screen', _waves.length);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  List<Map<String, dynamic>> _list(dynamic raw) {
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Map<String, dynamic> _map(dynamic raw) =>
      raw is Map ? Map<String, dynamic>.from(raw) : const {};

  List<Map<String, dynamic>> get _waves => _list(_data['waves']);

  String _s(Map<String, dynamic> m, String k) => m[k]?.toString() ?? '';

  /// The backend names a tone; this picks the token for it. An unknown tone is
  /// neutral — a payload from a newer build must never crash an older screen.
  Color _toneFg(String tone) => switch (tone) {
        'success' => Ds.c.success,
        'warning' => Ds.c.warning,
        'danger' => Ds.c.danger,
        'brand' => Ds.c.brand,
        'info' => Ds.c.info,
        _ => Ds.c.textSecondary,
      };

  Color _toneBg(String tone) => switch (tone) {
        'success' => Ds.c.successSoft,
        'warning' => Ds.c.warningSoft,
        'danger' => Ds.c.dangerSoft,
        'brand' => Ds.c.infoSoft,
        'info' => Ds.c.infoSoft,
        _ => Ds.c.bg,
      };

  /// Every write goes through the same door: fire the RPC, print the backend's
  /// own message, refetch. The refusals ("That run has already started —
  /// reassign the stop instead") are sentences the server wrote.
  Future<void> _act(String fn, Map<String, dynamic> params) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final m = await _call(fn, params);
      final msg = _s(m, 'message');
      if (mounted && msg.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (_) {
      // A failed write leaves the screen on its last good payload; the refetch
      // below is what tells the truth about what actually landed.
    }
    if (mounted) setState(() => _busy = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_data['allowed'] == false) {
      return Scaffold(
        backgroundColor: Ds.c.bg,
        appBar: AppBar(backgroundColor: Ds.c.surface, elevation: 0),
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(Ds.space.x24),
            child: Text(
                _s(_data, 'message').isNotEmpty
                    ? _s(_data, 'message')
                    : c('admin.delivery.waves_denied'),
                textAlign: TextAlign.center,
                style: Ds.t.body),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(_s(_data, 'title'), style: Ds.t.title),
        backgroundColor: Ds.c.surface,
        elevation: 0,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? _skeleton()
            : _failed
                ? _error()
                : ListView(
                    padding: EdgeInsets.all(Ds.space.x16),
                    children: [
                      Text(_s(_data, 'subtitle'), style: Ds.t.caption),
                      SizedBox(height: Ds.space.x4),
                      Text(_s(_data, 'riders_line'), style: Ds.t.caption),
                      SizedBox(height: Ds.space.x24),
                      _modeCard(),
                      SizedBox(height: Ds.space.x24),
                      _windowsCard(),
                      SizedBox(height: Ds.space.x24),
                      Text(_s(_data, 'waves_heading'), style: Ds.t.subtitle),
                      SizedBox(height: Ds.space.x12),
                      if (_waves.isEmpty)
                        _card(child: Text(_s(_data, 'empty_hint'),
                            style: Ds.t.caption))
                      else
                        for (final w in _waves) ...[
                          _waveCard(w),
                          SizedBox(height: Ds.space.x16),
                        ],
                      SizedBox(height: Ds.space.x32),
                    ],
                  ),
      ),
    );
  }

  Widget _card({required Widget child}) => Container(
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        padding: EdgeInsets.all(Ds.space.x16),
        child: child,
      );

  // ── Mode toggle (spec 3) ───────────────────────────────────────────────────
  // The three options and their hints are the payload's; this file does not
  // know that "suggest" is the default, only that the server sent it first.
  Widget _modeCard() {
    final card = _map(_data['mode_card']);
    final options = _list(card['options']);
    final value = _s(card, 'value');

    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_s(card, 'heading'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x4),
        Text(_s(card, 'value_label'), style: Ds.t.body),
        SizedBox(height: Ds.space.x12),
        for (final o in options)
          InkWell(
            onTap: _busy || _s(o, 'key') == value
                ? null
                : () => _act('delivery_wave_mode_set', {
                      'p_zone_id': _data['zone_id'],
                      'p_mode': _s(o, 'key'),
                    }),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: Ds.space.x48),
              child: Row(children: [
                Icon(
                  _s(o, 'key') == value
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: Ds.space.x24,
                  color: _s(o, 'key') == value ? Ds.c.brand : Ds.c.textSecondary,
                ),
                SizedBox(width: Ds.space.x12),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(_s(o, 'label'), style: Ds.t.body),
                        Text(_s(o, 'hint'), style: Ds.t.caption),
                      ]),
                ),
              ]),
            ),
          ),
        SizedBox(height: Ds.space.x8),
        Text(_s(card, 'help'), style: Ds.t.caption),
      ]),
    );
  }

  // ── Cut-off windows (spec 1) ───────────────────────────────────────────────
  Widget _windowsCard() {
    final windows = _list(_data['windows']);
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_s(_data, 'windows_heading'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x8),
        for (final w in windows)
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: Ds.space.x48),
            child: Row(children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(_s(w, 'label'), style: Ds.t.body),
                      Text(_s(w, 'cutoff_label'), style: Ds.t.caption),
                    ]),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _act('delivery_wave_cut_now', {
                          'p_zone_id': _data['zone_id'],
                          'p_window_key': _s(w, 'key'),
                        }),
                child: Text(_s(w, 'action_label')),
              ),
            ]),
          ),
      ]),
    );
  }

  // ── One wave ───────────────────────────────────────────────────────────────
  Widget _waveCard(Map<String, dynamic> w) {
    final chips = _list(w['chips']);
    final riders = _list(w['riders']);
    final stops = _list(w['stops']);
    final decisions = _list(w['decisions']);
    final actions = _list(w['actions']);

    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(_s(w, 'title'), style: Ds.t.subtitle)),
          _chip(_s(w, 'status_label'), _s(w, 'status_tone')),
        ]),
        SizedBox(height: Ds.space.x4),
        Text(_s(w, 'subtitle'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x12),
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [for (final c in chips) _chip(_s(c, 'label'), _s(c, 'tone'))],
        ),

        if (riders.isNotEmpty) ...[
          SizedBox(height: Ds.space.x24),
          Text(_s(w, 'riders_heading'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          for (final r in riders)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x4),
              child: Row(children: [
                Expanded(child: Text(_s(r, 'name'), style: Ds.t.body)),
                // A count is a number: right-aligned, and it is the backend's
                // own "3 stops" — never pluralised here.
                Text(_s(r, 'count_label'), style: Ds.t.body),
              ]),
            ),
        ],

        if (stops.isNotEmpty) ...[
          SizedBox(height: Ds.space.x24),
          Text(_s(w, 'stops_heading'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          for (final s in stops) ...[
            _stopRow(s),
            Divider(height: Ds.space.x24, color: Ds.c.divider),
          ],
        ],

        if (decisions.isNotEmpty) ...[
          Text(_s(w, 'decisions_heading'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          for (final d in decisions)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x8),
              child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Text(_s(d, 'label'), style: Ds.t.caption)),
                    SizedBox(width: Ds.space.x8),
                    Text(_s(d, 'at_label'), style: Ds.t.caption),
                  ]),
            ),
        ],

        if (actions.isNotEmpty) ...[
          SizedBox(height: Ds.space.x16),
          for (final a in actions)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x8),
              child: SizedBox(
                width: double.infinity,
                height: Ds.space.x48,
                child: _s(a, 'tone') == 'brand'
                    ? ElevatedButton(
                        onPressed: _busy ? null : () => _waveAction(w, a),
                        child: Text(_s(a, 'label')),
                      )
                    : OutlinedButton(
                        onPressed: _busy ? null : () => _waveAction(w, a),
                        style: OutlinedButton.styleFrom(
                            foregroundColor: _toneFg(_s(a, 'tone'))),
                        child: Text(_s(a, 'label')),
                      ),
              ),
            ),
        ],
      ]),
    );
  }

  Future<void> _waveAction(Map<String, dynamic> w, Map<String, dynamic> a) =>
      _act('delivery_wave_action', {
        'p_wave_id': _s(w, 'wave_id'),
        'p_action': _s(a, 'key'),
      });

  Widget _stopRow(Map<String, dynamic> s) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_s(s, 'label'), style: Ds.t.body),
                  if (_s(s, 'sub_label').isNotEmpty)
                    Text(_s(s, 'sub_label'), style: Ds.t.caption),
                  SizedBox(height: Ds.space.x4),
                  Text(_s(s, 'rider_label'), style: Ds.t.caption),
                  // Spec 4: every auto decision is logged and readable. The
                  // reason under a stop is the engine's own sentence.
                  if (_s(s, 'reason').isNotEmpty)
                    Text(_s(s, 'reason'), style: Ds.t.caption),
                  if (_s(s, 'attempt_label').isNotEmpty)
                    Text(_s(s, 'attempt_label'), style: Ds.t.caption),
                ]),
          ),
          SizedBox(width: Ds.space.x8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            _chip(_s(s, 'status_label'), _s(s, 'status_tone')),
            if (s['can_pull'] == true)
              SizedBox(
                height: Ds.space.x48,
                child: TextButton(
                  onPressed: _busy
                      ? null
                      : () => _act('delivery_wave_stop_pull',
                          {'p_stop_id': _s(s, 'stop_id')}),
                  child: Text(_s(s, 'pull_label')),
                ),
              ),
          ]),
        ],
      );

  Widget _chip(String text, String tone) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration: BoxDecoration(color: _toneBg(tone), borderRadius: Ds.r.rChip),
      child: Text(text,
          style: Ds.t.caption.copyWith(
              fontWeight: FontWeight.w500, color: _toneFg(tone))),
    );
  }

  // Loading is a skeleton, not a bare spinner.
  Widget _skeleton() => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x16),
              child: Container(
                height: Ds.space.x48 * 2,
                decoration: BoxDecoration(
                    color: Ds.c.surface, borderRadius: Ds.r.rCard),
              ),
            ),
        ],
      );

  // When the fetch itself failed there is no payload to read a message out of,
  // so the copy comes from ui_copy — still the backend's words, just fetched at
  // boot instead of in the failed call.
  Widget _error() => ListView(
        padding: EdgeInsets.all(Ds.space.x24),
        children: [
          Text(
              _s(_data, 'message').isNotEmpty
                  ? _s(_data, 'message')
                  : c('admin.delivery.waves_load_failed'),
              style: Ds.t.body),
          SizedBox(height: Ds.space.x16),
          SizedBox(
            height: Ds.space.x48,
            child: OutlinedButton(
              onPressed: _load,
              child: Text(_s(_data, 'retry_label').isNotEmpty
                  ? _s(_data, 'retry_label')
                  : c('admin.delivery.waves_retry')),
            ),
          ),
        ],
      );
}
