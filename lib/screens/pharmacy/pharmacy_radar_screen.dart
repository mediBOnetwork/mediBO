// CMD #425 — Expiry radar: the money you are about to throw away, worst first.
//
// #413 showed value at cost, which treats ₹40 of paracetamol and ₹1,800 of a
// dead Montikop lot as the same kind of news. This screen shows EXPECTED LOSS —
// what is left times what it cost, minus what will still sell before the date —
// and the backend does every part of that arithmetic. Nothing on this screen is
// computed here: not a rupee, not a "likely ~4 left", not the quick-reply
// numbers on a correction (they arrive as `options` on the ask, the SAME list
// the WhatsApp buttons carry, so the two channels can never drift apart).
//
// The whole feature is a WhatsApp feature for a shop with no desktop. This
// screen is the glass over the same four loops: the ranked list, the one-tap
// correction, the month card, and the switch that turns the WhatsApp side on.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/pharmacy_radar_api.dart';
import '../../services/pharmacy_shield_api.dart' show ShieldRpc;
import '../../utils/render_log.dart';
import 'pharmacy_variance_screen.dart'
    show ShieldCard, ShieldChip, ShieldRefusal, ShieldSkeleton;

String _s(Object? v) => v == null ? '' : v.toString();
Map<String, dynamic> _m(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

class PharmacyRadarScreen extends StatefulWidget {
  /// Test seam. Null in production → the real RPCs.
  final ShieldRpc? rpc;
  const PharmacyRadarScreen({super.key, this.rpc});

  @override
  State<PharmacyRadarScreen> createState() => _PharmacyRadarScreenState();
}

class _PharmacyRadarScreenState extends State<PharmacyRadarScreen> {
  Map<String, dynamic>? _home;
  String? _refusal;
  bool _failed = false;
  bool _busy = false;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : PharmacyRadarApi.call(fn, p);

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
      final r = await _call('pharmacy_radar_home', const {});
      if (!mounted) return;
      if (r['ok'] != true) {
        setState(() => _refusal = _s(r['message']));
        return;
      }
      setState(() => _home = r);
      RenderLog.write('c425_radar_home', 1);
      RenderLog.write('c425_radar_items', _rows(r['items']).length);
      RenderLog.write('c425_radar_asks', _rows(r['asks']).length);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _toast(String msg) {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// One tap on a backend-supplied option. The screen sends the number it was
  /// given and prints whatever comes back.
  Future<void> _answer(String askId, num qty) async {
    if (askId.isEmpty || _busy) return;
    setState(() => _busy = true);
    Map<String, dynamic> r;
    try {
      r = await _call('pharmacy_radar_answer', {
        'p_ask_id': askId,
        'p_qty': qty,
      });
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(_s(r['message']));
    if (r['ok'] == true) await _boot();
  }

  /// "Other" — the only number this screen ever originates, and it is typed by
  /// the owner, not guessed by the app.
  Future<void> _answerOther(Map<String, dynamic> ask) async {
    final controller = TextEditingController();
    final qty = await showModalBottomSheet<num>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          left: Ds.space.x16,
          right: Ds.space.x16,
          top: Ds.space.x24,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + Ds.space.x24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_s(ask['question']), style: Ds.t.bodyStrong),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                hintText: _s(ask['other_hint']),
                filled: true,
                fillColor: Ds.c.bg,
                border: OutlineInputBorder(borderRadius: Ds.r.rButton),
              ),
            ),
            SizedBox(height: Ds.space.x24),
            SizedBox(
              height: Ds.touch.minTarget,
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                onPressed: () {
                  final n = num.tryParse(controller.text.trim());
                  Navigator.pop(sheetContext, n);
                },
                child: Text(_s(ask['other_label'])),
              ),
            ),
          ],
        ),
      ),
    );
    if (qty != null) await _answer(_s(ask['ask_id']), qty);
  }

  /// A ranked row's "how many left?" — raise the ask, then show its own chips.
  Future<void> _askFor(Map<String, dynamic> item) async {
    if (_busy) return;
    setState(() => _busy = true);
    Map<String, dynamic> r;
    try {
      r = await _call('pharmacy_radar_ask_open', {
        'p_stock_id': _s(item['stock_id']),
      });
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (r['ok'] != true) {
      _toast(_s(r['message']));
      return;
    }
    await _boot();
  }

  Future<void> _toggleOptIn(Map<String, dynamic> optin) async {
    if (_busy) return;
    if (optin['can_enable'] != true && optin['on'] != true) {
      _toast(_s(optin['blocked_message']));
      return;
    }
    setState(() => _busy = true);
    Map<String, dynamic> r;
    try {
      r = await _call('pharmacy_radar_config_set', {
        'p_patch': {'opt_in': optin['on'] != true},
      });
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r['ok'] == true) _home = r;
    });
    RenderLog.write('c425_radar_optin', 1);
  }

  @override
  Widget build(BuildContext context) {
    final h = _home;
    if (_refusal != null) return ShieldRefusal(message: _refusal!);
    if (_failed) {
      return ShieldRefusal(message: '', retryLabel: 'Retry', onRetry: _boot);
    }
    if (h == null) return const ShieldSkeleton();

    final items = _rows(h['items']);
    final asks = _rows(h['asks']);
    final digest = _m(h['digest']);
    final optin = _m(h['optin']);
    final intake = _m(h['intake']);

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
            // The one focal element: the money that is going to be lost.
            ShieldCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_s(h['headline']), style: Ds.t.title),
                  SizedBox(height: Ds.space.x8),
                  Text(_s(h['headline_note']), style: Ds.t.caption),
                  SizedBox(height: Ds.space.x8),
                  Text(_s(h['subtitle']), style: Ds.t.caption),
                ],
              ),
            ),

            if (asks.isNotEmpty) ...[
              SizedBox(height: Ds.space.x24),
              Text(_s(h['asks_title']), style: Ds.t.bodyStrong),
              SizedBox(height: Ds.space.x4),
              Text(_s(h['asks_note']), style: Ds.t.caption),
              SizedBox(height: Ds.space.x12),
              for (final a in asks) ...[
                _AskCard(
                  ask: a,
                  busy: _busy,
                  onPick: (q) => _answer(_s(a['ask_id']), q),
                  onOther: () => _answerOther(a),
                ),
                SizedBox(height: Ds.space.x12),
              ],
            ],

            SizedBox(height: Ds.space.x24),
            Text(_s(h['list_title']), style: Ds.t.bodyStrong),
            SizedBox(height: Ds.space.x12),
            if (items.isEmpty)
              ShieldCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_s(h['empty']), style: Ds.t.bodyStrong),
                    SizedBox(height: Ds.space.x4),
                    Text(_s(h['empty_hint']), style: Ds.t.caption),
                  ],
                ),
              )
            else
              for (final it in items) ...[
                _RadarRow(
                  item: it,
                  busy: _busy,
                  askLabel: _s(h['asks_title']),
                  onAsk: () => _askFor(it),
                ),
                SizedBox(height: Ds.space.x12),
              ],

            SizedBox(height: Ds.space.x24),
            ShieldCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_s(digest['title']), style: Ds.t.bodyStrong),
                  SizedBox(height: Ds.space.x12),
                  for (final row in _rows(digest['rows']))
                    Padding(
                      padding: EdgeInsets.only(bottom: Ds.space.x8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _s(row['label']),
                              style: Ds.t.bodySecondary,
                            ),
                          ),
                          Text(_s(row['value']), style: Ds.t.bodyStrong),
                        ],
                      ),
                    ),
                ],
              ),
            ),

            SizedBox(height: Ds.space.x24),
            ShieldCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_s(optin['title']), style: Ds.t.bodyStrong),
                  SizedBox(height: Ds.space.x8),
                  Text(_s(optin['body']), style: Ds.t.caption),
                  SizedBox(height: Ds.space.x12),
                  ShieldChip(
                    label: _s(optin['state_label']),
                    tone: optin['on'] == true ? 'success' : 'neutral',
                  ),
                  SizedBox(height: Ds.space.x16),
                  SizedBox(
                    height: Ds.touch.minTarget,
                    width: double.infinity,
                    child: optin['on'] == true
                        ? OutlinedButton(
                            onPressed: _busy ? null : () => _toggleOptIn(optin),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Ds.c.brand,
                              side: BorderSide(color: Ds.c.brand),
                              shape: RoundedRectangleBorder(
                                borderRadius: Ds.r.rButton,
                              ),
                            ),
                            child: Text(_s(optin['button'])),
                          )
                        : FilledButton(
                            onPressed: _busy ? null : () => _toggleOptIn(optin),
                            style: FilledButton.styleFrom(
                              backgroundColor: Ds.c.brand,
                              shape: RoundedRectangleBorder(
                                borderRadius: Ds.r.rButton,
                              ),
                            ),
                            child: Text(_s(optin['button'])),
                          ),
                  ),
                ],
              ),
            ),

            SizedBox(height: Ds.space.x24),
            ShieldCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_s(intake['title']), style: Ds.t.bodyStrong),
                  SizedBox(height: Ds.space.x8),
                  Text(_s(intake['body']), style: Ds.t.caption),
                  SizedBox(height: Ds.space.x12),
                  ShieldChip(
                    label: _s(intake['count_label']),
                    tone: intake['on'] == true ? 'info' : 'neutral',
                  ),
                ],
              ),
            ),
            SizedBox(height: Ds.space.x32),
          ],
        ),
      ),
    );
  }
}

/// The correction card. Its numbers are the payload's `options` — the same list
/// the WhatsApp quick replies carry — so a tap here and a tap there are the
/// same answer.
class _AskCard extends StatelessWidget {
  final Map<String, dynamic> ask;
  final bool busy;
  final void Function(num) onPick;
  final VoidCallback onOther;
  const _AskCard({
    required this.ask,
    required this.busy,
    required this.onPick,
    required this.onOther,
  });

  @override
  Widget build(BuildContext context) {
    final options = _rows(ask['options']);
    return ShieldCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(ask['question']), style: Ds.t.body),
          SizedBox(height: Ds.space.x16),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              for (final o in options)
                _OptionButton(
                  label: _s(o['label']),
                  onTap: busy
                      ? null
                      : () {
                          final v = o['value'];
                          final n = v is num ? v : num.tryParse(_s(v));
                          if (n != null) onPick(n);
                        },
                ),
              _OptionButton(
                label: _s(ask['other_label']),
                onTap: busy ? null : onOther,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OptionButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  const _OptionButton({required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: Ds.touch.minTarget,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: Ds.c.brand,
          side: BorderSide(color: Ds.c.divider),
          shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
        ),
        child: Text(label, style: Ds.t.body),
      ),
    );
  }
}

/// One ranked lot. The rupee on the right is the expected LOSS, already
/// formatted; the caption under it names what the number is, so the screen
/// never has to explain a figure it did not compute.
class _RadarRow extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool busy;
  final String askLabel;
  final VoidCallback onAsk;
  const _RadarRow({
    required this.item,
    required this.busy,
    required this.askLabel,
    required this.onAsk,
  });

  @override
  Widget build(BuildContext context) {
    final hasAsk = _m(item['ask']).isNotEmpty;
    return ShieldCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  _s(item['product_name']),
                  style: Ds.t.bodyStrong,
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(_s(item['value_display']), style: Ds.t.bodyStrong),
                  Text(_s(item['value_caption']), style: Ds.t.caption),
                ],
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Text(
            '${_s(item['batch_label'])} · ${_s(item['expiry_label'])}',
            style: Ds.t.caption,
          ),
          SizedBox(height: Ds.space.x4),
          Text(
            '${_s(item['qty_label'])} · ${_s(item['basis_label'])}',
            style: Ds.t.caption,
          ),
          SizedBox(height: Ds.space.x12),
          Row(
            children: [
              Expanded(
                child: ShieldChip(
                  label: _s(item['window_label']),
                  tone: _s(item['window_tone']),
                ),
              ),
              if (!hasAsk)
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: TextButton(
                    onPressed: busy ? null : onAsk,
                    style: TextButton.styleFrom(foregroundColor: Ds.c.brand),
                    child: Text(askLabel, style: Ds.t.body),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The way into the radar, drawn from `pharmacy_radar_entry()` and nowhere
/// else: the label, the sub-label and the rupee badge are all the backend's.
/// `show:false` — or a call that never lands — draws nothing at all, so a shop
/// with no shelf never sees a dead tile.
class RadarEntryCard extends StatefulWidget {
  final ShieldRpc? rpc;
  const RadarEntryCard({super.key, this.rpc});

  @override
  State<RadarEntryCard> createState() => _RadarEntryCardState();
}

class _RadarEntryCardState extends State<RadarEntryCard> {
  Map<String, dynamic> _entry = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = widget.rpc != null
          ? await widget.rpc!('pharmacy_radar_entry', const {})
          : await PharmacyRadarApi.entry();
      if (!mounted) return;
      setState(() => _entry = r);
      if (r['show'] == true) RenderLog.write('c425_radar_entry', 1);
    } catch (_) {
      // A dead tile is worse than no tile.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_entry['show'] != true) return const SizedBox.shrink();
    final badge = _s(_entry['badge']);
    return InkWell(
      borderRadius: Ds.r.rCard,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => PharmacyRadarScreen(rpc: widget.rpc),
        ),
      ),
      child: ShieldCard(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_s(_entry['label']), style: Ds.t.bodyStrong),
                  SizedBox(height: Ds.space.x4),
                  Text(_s(_entry['sub_label']), style: Ds.t.caption),
                ],
              ),
            ),
            if (badge.isNotEmpty) ...[
              SizedBox(width: Ds.space.x12),
              ShieldChip(label: badge, tone: 'warning'),
            ],
            SizedBox(width: Ds.space.x8),
            Icon(
              Icons.chevron_right,
              size: Ds.t.subtitleSize,
              color: Ds.c.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
