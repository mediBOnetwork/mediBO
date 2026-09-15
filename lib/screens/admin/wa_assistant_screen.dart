import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';

/// CHANGE #714 — the WhatsApp assistant console.
///
/// Three things on one screen, all of them the payload's: the master switch,
/// which questions the assistant may answer, and the last fifty replies with
/// the intent, the confidence and what actually happened to each one.
///
/// The screen decides nothing. Every label, every outcome word and its tone,
/// the confidence percentage and the timestamps are strings from
/// `wa_assistant_console()`; a toggle sends the backend's own key back through
/// one verb, `wa_assistant_set()`, and re-renders whatever it returns.
class WaAssistantScreen extends StatefulWidget {
  const WaAssistantScreen({super.key});

  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  @override
  State<WaAssistantScreen> createState() => _WaAssistantScreenState();
}

class _WaAssistantScreenState extends State<WaAssistantScreen> {
  Map<String, dynamic> _p = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await WaAssistantScreen.rpc('wa_assistant_console', {'p_limit': 50});
      if (!mounted) return;
      setState(() {
        _p = res is Map ? Map<String, dynamic>.from(res) : const {};
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _set(Map<String, dynamic> patch) async {
    final res = await WaAssistantScreen.rpc('wa_assistant_set', {'p_patch': patch});
    if (res is! Map || !mounted) return;
    final m = Map<String, dynamic>.from(res);
    final msg = (m['message'] ?? '').toString();
    if (msg.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: m['ok'] == true ? Ds.c.brand : Ds.c.danger,
      ));
    }
    final state = m['state'];
    if (state is Map) setState(() => _p = Map<String, dynamic>.from(state));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
          title: Text((_p['title'] ?? '').toString(), style: Ds.t.subtitle)),
      body: SafeArea(
        child: _loading
            ? WaAssistantView.skeleton()
            : RefreshIndicator(
                onRefresh: _load,
                child: WaAssistantView(payload: _p, onSet: _set),
              ),
      ),
    );
  }
}

/// The rendered console, split out so a protected test can pump a payload with
/// no Supabase and no timers.
class WaAssistantView extends StatelessWidget {
  const WaAssistantView({super.key, required this.payload, this.onSet});

  final Map<String, dynamic> payload;
  final Future<void> Function(Map<String, dynamic> patch)? onSet;

  static String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

  static List<Map<String, dynamic>> _list(Map<String, dynamic> m, String k) =>
      ((m[k] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);

  static Widget skeleton() => Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < 5; i++)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: Container(
                    height: Ds.space.x48,
                    decoration: BoxDecoration(
                        color: Ds.c.surface, borderRadius: Ds.r.rCard)),
              ),
          ],
        ),
      );

  Color _tone(String tone) => switch (tone) {
        'success' => Ds.c.success,
        'warning' => Ds.c.warning,
        'danger' => Ds.c.danger,
        _ => Ds.c.textSecondary,
      };

  /// A card. The Material inside it is not decoration: a ListTile paints its
  /// background and its ink splash on the nearest Material ancestor, and a
  /// card that is only a DecoratedBox hides both — so every switch on this
  /// screen would have looked dead when tapped. Flutter says so out loud in a
  /// test and says nothing at all in release, which is why it is here.
  Widget _card({required Widget child}) => Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Padding(
            padding: EdgeInsets.all(Ds.space.x16),
            child: child,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (payload['ok'] != true) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Text(_s(payload, 'message'),
              textAlign: TextAlign.center, style: Ds.t.body),
        ),
      );
    }

    final on = payload['enabled'] == true;
    final rows = _list(payload, 'rows');
    final intents = _list(payload, 'intents');
    final zones = _list(payload, 'zones');

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(_s(payload, 'subtitle'), style: Ds.t.body),
        SizedBox(height: Ds.space.x16),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                value: on,
                onChanged: onSet == null
                    ? null
                    : (v) => onSet!(<String, dynamic>{'enabled': v}),
                title: Text(_s(payload, 'switch_label'), style: Ds.t.body),
                contentPadding: EdgeInsets.zero,
              ),
              // The backend's own sentence about what "off" means — this side
              // never explains the switch in its own words.
              if (!on && _s(payload, 'switch_off_note').isNotEmpty)
                Text(_s(payload, 'switch_off_note'), style: Ds.t.caption),
            ],
          ),
        ),
        SizedBox(height: Ds.space.x24),
        Text(_s(payload, 'intents_heading'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x12),
        _card(
          child: Column(
            children: [
              for (final i in intents)
                SwitchListTile(
                  value: i['enabled'] == true,
                  onChanged: onSet == null
                      ? null
                      : (v) => onSet!(<String, dynamic>{
                            'intent_key': _s(i, 'key'),
                            'enabled': v,
                          }),
                  title: Text(_s(i, 'label'), style: Ds.t.body),
                  // CHANGE #714 (D) — whatever this row has to say about
                  // itself is ONE backend string. The version that shipped
                  // first chose between two sentences here and got both wrong:
                  // it printed the raw defer_to key (`reorder_wa_inbound`) at
                  // an admin, and it borrowed the MASTER switch's "Off — every
                  // message goes straight to a person" for always_handoff
                  // intents, so a row whose toggle was plainly ON read as off.
                  // The screen no longer picks; `note` is empty when there is
                  // nothing to say.
                  subtitle: _s(i, 'note').isEmpty
                      ? null
                      : Text(_s(i, 'note'), style: Ds.t.caption),
                  contentPadding: EdgeInsets.zero,
                ),
            ],
          ),
        ),
        if (zones.isNotEmpty) ...[
          SizedBox(height: Ds.space.x24),
          Text(_s(payload, 'zone_heading'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          _card(
            child: Column(
              children: [
                for (final z in zones)
                  SwitchListTile(
                    value: z['enabled'] == true,
                    onChanged: onSet == null
                        ? null
                        : (v) => onSet!(<String, dynamic>{
                              'zone_id': z['zone_id'],
                              'enabled': v,
                            }),
                    title: Text(_s(z, 'zone_name'), style: Ds.t.body),
                    contentPadding: EdgeInsets.zero,
                  ),
              ],
            ),
          ),
        ],
        SizedBox(height: Ds.space.x24),
        Text(_s(payload, 'replies_heading'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x12),
        if (rows.isEmpty)
          Text(_s(payload, 'empty_note'), style: Ds.t.caption)
        else
          for (final r in rows) ...[
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(_s(r, 'intent'), style: Ds.t.body),
                      ),
                      SizedBox(width: Ds.space.x8),
                      Text(_s(r, 'outcome_label'),
                          style: Ds.t.caption
                              .copyWith(color: _tone(_s(r, 'outcome_tone')))),
                    ],
                  ),
                  SizedBox(height: Ds.space.x4),
                  Text(_s(r, 'inbound'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Ds.t.caption),
                  if (_s(r, 'reply').isNotEmpty) ...[
                    SizedBox(height: Ds.space.x8),
                    Text(_s(r, 'reply'), style: Ds.t.body),
                  ],
                  SizedBox(height: Ds.space.x8),
                  Row(
                    children: [
                      Text(_s(r, 'confidence_label'), style: Ds.t.caption),
                      SizedBox(width: Ds.space.x12),
                      if (_s(r, 'reason').isNotEmpty)
                        Expanded(
                          child: Text(_s(r, 'reason'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Ds.t.caption),
                        ),
                      Text(_s(r, 'at'), style: Ds.t.caption),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(height: Ds.space.x12),
          ],
      ],
    );
  }
}
