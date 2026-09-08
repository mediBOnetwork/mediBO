// CHANGE #573 — Test mode: the one place the synthetic lane is visible.
//
// The platform now has a single synthetic lane every subsystem understands.
// `is_synthetic` sits on the root entities and is INHERITED down every child by
// trigger; the outbound queues drop a synthetic message unless it is addressed
// to Om's own test number; the ledgers refuse a synthetic write outright; and
// the reporting functions read a `books` schema that cannot see one. None of
// that is decided here.
//
// THE APP RENDERS. IT NEVER DECIDES. Every visible word on this screen —
// title, subtitle, the kill-switch sentence, the Razorpay verdict, each
// fixture's label, each count, each run's status label, the confirm text on a
// destructive button, the empty states, even the red TEST badge's caption —
// arrives inside `test_mode_screen()`. There is no display string in this
// file, no status→label switch, no date formatting, and no rule about what may
// run: the backend sends the actions and their confirmations, and this file
// draws them in payload order.
//
// The one thing chosen locally is the same thing every screen chooses locally:
// a backend TONE NAME resolved to the fixed design palette.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/test_session.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// Resolves a backend tone name to the design palette. The server decides
/// which colour a chip wears; the app only knows what the names mean.
({Color bg, Color fg}) _tone(String name) {
  switch (name) {
    case 'success':
      return (bg: Ds.c.successSoft, fg: Ds.c.success);
    case 'warning':
      return (bg: Ds.c.warningSoft, fg: Ds.c.warning);
    case 'danger':
      return (bg: Ds.c.dangerSoft, fg: Ds.c.danger);
    case 'brand':
      return (bg: Ds.c.brandSoft, fg: Ds.c.brand);
    case 'info':
      return (bg: Ds.c.infoSoft, fg: Ds.c.info);
    default:
      return (bg: Ds.c.bg, fg: Ds.c.textSecondary);
  }
}

/// The red TEST badge. It exists only when the backend sent one — a payload
/// with no `badge` key draws nothing, which is how a real row stays unmarked.
class SyntheticBadge extends StatelessWidget {
  const SyntheticBadge({super.key, required this.badge});

  /// `synthetic_badge(is_synthetic)` — null for a real row.
  final Map<String, dynamic>? badge;

  @override
  Widget build(BuildContext context) {
    final b = badge;
    if (b == null) return const SizedBox.shrink();
    final label = (b['label'] ?? '').toString();
    if (label.isEmpty) return const SizedBox.shrink();
    final t = _tone((b['tone'] ?? 'danger').toString());
    final hint = (b['hint'] ?? '').toString();
    final chip = Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration: BoxDecoration(color: t.bg, borderRadius: Ds.r.rChip),
      child: Text(label,
          style: Ds.t.caption.copyWith(color: t.fg, fontWeight: FontWeight.w600)),
    );
    return hint.isEmpty ? chip : Tooltip(message: hint, child: chip);
  }
}

/// Thin RPC layer — one call per method, payload returned untouched.
class TestModeService {
  TestModeService({SupabaseClient? client})
      : _c = client ?? Supabase.instance.client;

  final SupabaseClient _c;

  Map<String, dynamic> _asMap(dynamic raw) {
    final v = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  }

  Future<Map<String, dynamic>> screen() async =>
      _asMap(await _c.rpc('test_mode_screen'));

  Future<Map<String, dynamic>> set(Map<String, dynamic> patch) async =>
      _asMap(await _c.rpc('test_mode_set', params: {'p_patch': patch}));

  /// CHANGE #573 — ONE door for every button on this screen. The payload sends
  /// the action keys; this posts the key back. No Dart switch decides what a
  /// button does, so a new action is a backend row and never a deploy.
  Future<Map<String, dynamic>> act(String key,
      {Map<String, dynamic> arg = const {}}) async {
    final raw = _asMap(await _c
        .rpc('test_mode_action', params: {'p_key': key, 'p_arg': arg}));
    final r = raw['result'];
    return r is Map ? Map<String, dynamic>.from(r) : raw;
  }
}

class TestModeScreen extends StatefulWidget {
  const TestModeScreen({super.key, this.service});

  final TestModeService? service;

  @override
  State<TestModeScreen> createState() => _TestModeScreenState();
}

class _TestModeScreenState extends State<TestModeScreen> {
  late final TestModeService _svc = widget.service ?? TestModeService();

  Map<String, dynamic> _s = const {};
  bool _loading = true;
  bool _busy = false;
  String? _error;

  final _phone = TextEditingController();
  bool _phoneTouched = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final s = await _svc.screen();
      if (!mounted) return;
      final sw = (s['switch'] as Map?) ?? const {};
      // An edit Om has already made wins until he leaves, so a refresh never
      // eats his typing.
      if (!_phoneTouched) _phone.text = (sw['test_phone'] ?? '').toString();
      // A canvas app cannot be clicked by any tool, so the render log is the
      // only proof this screen actually painted with a real payload.
      RenderLog.write('c573_test_mode', 1);
      RenderLog.write(
          'c573_test_mode_fixtures',
          (((s['fixtures'] as Map?)?['rows'] as List?) ?? const []).length);
      RenderLog.write('c573_test_mode_enabled', sw['enabled'] == true ? 1 : 0);
      setState(() {
        _s = s;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Every button is the same three moves: call the one RPC, show whatever
  /// sentence came back, reload.
  Future<void> _run(Future<Map<String, dynamic>> Function() call) async {
    setState(() => _busy = true);
    try {
      final res = await call();
      if (!mounted) return;
      final msg = (res['message'] ?? res['error'] ?? '').toString();
      if (msg.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
      _phoneTouched = false;
      // The platform-wide strip is driven by its own poll; refresh it now so
      // switching the session on or off is visible immediately, everywhere.
      unawaited(TestSessionState.instance.refresh());
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fire(Map<String, dynamic> action) async {
    final confirm = (action['confirm'] ?? '').toString();
    if (confirm.isNotEmpty) {
      final ok = await showModalBottomSheet<bool>(
        context: context,
        backgroundColor: Ds.c.surface,
        shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
        builder: (ctx) => Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(confirm, style: Ds.t.body),
              SizedBox(height: Ds.space.x24),
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Ds.c.danger,
                    shape:
                        RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text((action['label'] ?? '').toString(),
                      style: Ds.t.body.copyWith(color: Ds.c.surface)),
                ),
              ),
            ],
          ),
        ),
      );
      if (ok != true) return;
    }

    final key = (action['key'] ?? '').toString();
    if (key.isEmpty) return;
    final arg = action['arg'];
    final params = arg is Map ? Map<String, dynamic>.from(arg) : <String, dynamic>{};
    await _run(() async {
      var res = await _svc.act(key, arg: params);
      // A purge is BOUNDED on the server so it can never blow the statement
      // timeout. `done:false` is the backend saying "call me again" — the
      // screen obeys that flag, it does not decide when the wipe is finished.
      var rounds = 0;
      while (res['done'] == false && rounds < 30) {
        rounds++;
        res = await _svc.act(key, arg: params);
      }
      // CMD #1848 — the session token is the backend's to give and take:
      // `token` puts THIS install into test mode, `clear_token` takes it out.
      await TestSessionState.instance.absorb(res);
      // CMD #1851 — ending a session OFFERS the walkthrough as a journey. The
      // offer, its wording, its default name and its area are all in the reply;
      // this screen only asks the question the backend wrote.
      final offer = res['recording_offer'];
      if (offer is Map && offer['has'] == true) {
        _pendingOffer = Map<String, dynamic>.from(offer);
      }
      return res;
    });
    final offer = _pendingOffer;
    _pendingOffer = null;
    if (offer != null && mounted) await _offerJourney(offer);
  }

  Map<String, dynamic>? _pendingOffer;

  /// The save-as-journey sheet. Every word is [offer]'s; the two fields start
  /// on the backend's own defaults and the save is one call.
  Future<void> _offerJourney(Map<String, dynamic> offer) async {
    final id = offer['recording_id'];
    if (id is! int) return;
    final name = TextEditingController(
        text: (offer['default_name'] ?? '').toString());
    final area = TextEditingController(
        text: (offer['default_area'] ?? '').toString());
    final save = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(Ds.space.x24, Ds.space.x24, Ds.space.x24,
            Ds.space.x24 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text((offer['title'] ?? '').toString(), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x8),
            Text((offer['count_label'] ?? '').toString(),
                style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
            SizedBox(height: Ds.space.x12),
            Text((offer['body'] ?? '').toString(),
                style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
            SizedBox(height: Ds.space.x24),
            TextField(
              controller: name,
              decoration: InputDecoration(
                  labelText: (offer['name_label'] ?? '').toString()),
            ),
            SizedBox(height: Ds.space.x12),
            TextField(
              controller: area,
              decoration: InputDecoration(
                  labelText: (offer['area_label'] ?? '').toString()),
            ),
            SizedBox(height: Ds.space.x24),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text((offer['save'] ?? '').toString(),
                    style: Ds.t.body.copyWith(color: Ds.c.surface)),
              ),
            ),
            SizedBox(height: Ds.space.x8),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text((offer['discard'] ?? '').toString()),
              ),
            ),
          ],
        ),
      ),
    );
    if (save != true || !mounted) return;
    await _run(() async => _asMapPublic(await Supabase.instance.client.rpc(
          'recording_promote',
          params: {
            'p_recording': id,
            'p_title': name.text,
            'p_area': area.text,
          },
        )));
  }

  static Map<String, dynamic> _asMapPublic(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  String _s2(String key) => (_s[key] ?? '').toString();

  Map<String, dynamic>? _badge(Map<String, dynamic> row) {
    final b = row['badge'];
    return b is Map ? Map<String, dynamic>.from(b) : null;
  }

  @override
  Widget build(BuildContext context) {
    final sw = (_s['switch'] as Map?) ?? const {};
    final rzp = (_s['razorpay'] as Map?) ?? const {};
    final fixtures = (_s['fixtures'] as Map?) ?? const {};
    final counts = (_s['counts'] as Map?) ?? const {};
    final runs = (_s['runs'] as Map?) ?? const {};
    final sessions = (_s['sessions'] as Map?) ?? const {};
    final proof = (_s['proof'] as Map?) ?? const {};
    final actions = (_s['actions'] as List?) ?? const [];

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        elevation: 0,
        iconTheme: IconThemeData(color: Ds.c.brand),
        title: Row(
          children: [
            Flexible(child: Text(_s2('title'), style: Ds.t.subtitle)),
            SizedBox(width: Ds.space.x8),
            SyntheticBadge(badge: _badge(_s)),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh, color: Ds.c.brand),
            onPressed: _busy ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? _skeleton()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: EdgeInsets.all(Ds.space.x16),
                children: [
                  if (_error != null) ...[
                    _errorCard(_error!),
                    SizedBox(height: Ds.space.x24),
                  ],
                  Text(_s2('subtitle'), style: Ds.t.caption),
                  SizedBox(height: Ds.space.x24),
                  _switchCard(Map<String, dynamic>.from(sw),
                      Map<String, dynamic>.from(rzp)),
                  SizedBox(height: Ds.space.x24),
                  _sessionsCard(Map<String, dynamic>.from(sessions)),
                  SizedBox(height: Ds.space.x24),
                  _proofCard(Map<String, dynamic>.from(proof)),
                  SizedBox(height: Ds.space.x24),
                  _fixturesCard(Map<String, dynamic>.from(fixtures)),
                  SizedBox(height: Ds.space.x24),
                  _countsCard(Map<String, dynamic>.from(counts)),
                  SizedBox(height: Ds.space.x24),
                  _runsCard(Map<String, dynamic>.from(runs)),
                  SizedBox(height: Ds.space.x32),
                  ...actions.map((a) => Padding(
                        padding: EdgeInsets.only(bottom: Ds.space.x12),
                        child: _actionButton(
                            Map<String, dynamic>.from(a as Map)),
                      )),
                  SizedBox(height: Ds.space.x48),
                ],
              ),
            ),
    );
  }

  // ── pieces ────────────────────────────────────────────────────────────────

  /// CHANGE #573 — the session list. One row per manual incognito run, with
  /// what it is still holding and, once purged, the backend's own verdict on
  /// whether the wipe was clean. Every word, tone and count is payload.
  Widget _sessionsCard(Map<String, dynamic> s) {
    final rows = (s['rows'] as List?) ?? const [];
    RenderLog.write('c573_session_rows', rows.length);
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text((s['title'] ?? '').toString(), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x4),
          Text((s['subtitle'] ?? '').toString(), style: Ds.t.caption),
          SizedBox(height: Ds.space.x16),
          if (rows.isEmpty)
            Text((s['empty'] ?? '').toString(), style: Ds.t.caption)
          else
            ...rows.map((r) => _sessionRow(
                Map<String, dynamic>.from(r as Map),
                Map<String, dynamic>.from(s))),
        ],
      ),
    );
  }

  Widget _sessionRow(Map<String, dynamic> r, Map<String, dynamic> s) {
    final residue = (r['residue'] as Map?) ?? const {};
    final proof = (r['proof'] as Map?) ?? const {};
    final tone = _tone((r['status_tone'] ?? '').toString());
    final originTone = _tone((r['origin_tone'] ?? '').toString());
    final held = (residue['total'] ?? 0).toString();
    final files = (residue['files'] ?? 0).toString();
    final hasProof = proof.containsKey('clean');
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text((r['label'] ?? '').toString(),
                    style: Ds.t.body, maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              SizedBox(width: Ds.space.x8),
              // CHANGE #1821 — WHO started it, and whether it could ever have
              // raised the platform banner. Five "autotest smoke" rows looked
              // exactly like Om's own runs on this list, which is why the
              // reopening loop was invisible for a whole day. Both words are
              // the backend's (origin_label / banner_label).
              if ((r['origin_label'] ?? '').toString().isNotEmpty) ...[
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x8, vertical: Ds.space.x4),
                  decoration: BoxDecoration(
                      color: originTone.bg, borderRadius: Ds.r.rChip),
                  child: Text((r['origin_label'] ?? '').toString(),
                      style: Ds.t.caption.copyWith(color: originTone.fg)),
                ),
                SizedBox(width: Ds.space.x8),
              ],
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x8, vertical: Ds.space.x4),
                decoration: BoxDecoration(
                    color: tone.bg, borderRadius: Ds.r.rChip),
                child: Text((r['status_label'] ?? '').toString(),
                    style: Ds.t.caption.copyWith(color: tone.fg)),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Text(
            [
              (r['started_label'] ?? '').toString(),
              (r['by'] ?? '').toString(),
              (r['banner_label'] ?? '').toString(),
              '${(s['residue_label'] ?? '').toString()} $held',
              '${(s['files_label'] ?? '').toString()} $files',
            ].where((t) => t.trim().isNotEmpty).join('  ·  '),
            style: Ds.t.caption,
          ),
          if (hasProof) ...[
            SizedBox(height: Ds.space.x4),
            Text(
              proof['clean'] == true
                  ? (s['proof_clean'] ?? '').toString()
                  : (s['proof_dirty'] ?? '').toString(),
              style: Ds.t.caption.copyWith(
                  color: proof['clean'] == true ? Ds.c.success : Ds.c.danger),
            ),
          ],
          if (r['can_purge'] == true) ...[
            SizedBox(height: Ds.space.x8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _busy
                    ? null
                    : () => _fire({
                          'key': 'session_purge',
                          'label': '',
                          'confirm': (s['confirm_purge'] ?? '').toString(),
                          'arg': {'session_id': (r['id'] ?? '').toString()},
                        }),
                child: Text((s['purge_row_label'] ?? '').toString(),
                    style: Ds.t.body.copyWith(color: Ds.c.danger)),
              ),
            ),
          ],
        ],
      ),
    );
  }


  Widget _card({required Widget child, Color? accent}) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
          border: accent == null
              ? null
              : Border(left: BorderSide(color: accent, width: Ds.space.x4)),
        ),
        child: child,
      );

  Widget _errorCard(String message) => _card(
        accent: Ds.c.danger,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message, style: Ds.t.body),
            SizedBox(height: Ds.space.x12),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Ds.c.brand,
                  side: BorderSide(color: Ds.c.brand),
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                onPressed: _load,
                child: Text(_s2('title'), style: Ds.t.body),
              ),
            ),
          ],
        ),
      );

  Widget _skeleton() => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: List.generate(
          4,
          (_) => Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x12),
            child: Container(
              height: Ds.space.x48 + Ds.space.x32,
              decoration: BoxDecoration(
                color: Ds.c.divider,
                borderRadius: Ds.r.rCard,
              ),
            ),
          ),
        ),
      );

  Widget _chip(String label, String toneName) {
    if (label.isEmpty) return const SizedBox.shrink();
    final t = _tone(toneName);
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(color: t.bg, borderRadius: Ds.r.rChip),
      child: Text(label,
          style: Ds.t.caption.copyWith(color: t.fg, fontWeight: FontWeight.w600)),
    );
  }

  /// The kill switch, the outbound allowance and the one number a synthetic row
  /// may ever reach. Empty number means nothing goes out at all — the backend
  /// says so in `phone_display`, this file does not.
  Widget _switchCard(Map<String, dynamic> sw, Map<String, dynamic> rzp) => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text((sw['title'] ?? '').toString(), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x12),
            Row(
              children: [
                Expanded(
                  child: Text((sw['enabled_label'] ?? '').toString(),
                      style: Ds.t.body),
                ),
                Switch(
                  value: sw['enabled'] == true,
                  activeTrackColor: Ds.c.brand,
                  onChanged: _busy
                      ? null
                      : (v) => _run(() => _svc.set({'enabled': v})),
                ),
              ],
            ),
            Text((sw['enabled_hint'] ?? '').toString(), style: Ds.t.caption),
            SizedBox(height: Ds.space.x16),
            Row(
              children: [
                Expanded(
                  child: Text((sw['outbound_label'] ?? '').toString(),
                      style: Ds.t.body),
                ),
                Switch(
                  value: sw['allow_outbound'] == true,
                  activeTrackColor: Ds.c.brand,
                  onChanged: _busy
                      ? null
                      : (v) => _run(() => _svc.set({'allow_outbound': v})),
                ),
              ],
            ),
            SizedBox(height: Ds.space.x16),
            Text((sw['phone_label'] ?? '').toString(), style: Ds.t.caption),
            SizedBox(height: Ds.space.x4),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              style: Ds.t.body,
              onChanged: (_) => _phoneTouched = true,
              decoration: InputDecoration(
                hintText: (sw['phone_display'] ?? '').toString(),
                hintStyle: Ds.t.caption,
                filled: true,
                fillColor: Ds.c.bg,
                border: OutlineInputBorder(borderRadius: Ds.r.rButton),
                suffixIcon: IconButton(
                  icon: Icon(Icons.check, color: Ds.c.brand),
                  onPressed: _busy
                      ? null
                      : () => _run(() => _svc.set({'test_phone': _phone.text})),
                ),
              ),
            ),
            SizedBox(height: Ds.space.x4),
            Text((sw['phone_hint'] ?? '').toString(), style: Ds.t.caption),
            SizedBox(height: Ds.space.x16),
            _chip((rzp['label'] ?? '').toString(),
                (rzp['tone'] ?? 'neutral').toString()),
          ],
        ),
      );

  /// The verdict the whole feature exists to earn: nothing sent, nothing
  /// booked. Both numbers and the sentence come from the backend.
  Widget _proofCard(Map<String, dynamic> p) {
    final outbound = (p['outbound'] as Map?) ?? const {};
    final books = (p['books'] as Map?) ?? const {};
    return _card(
      accent: _tone((p['tone'] ?? 'neutral').toString()).fg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text((p['title'] ?? '').toString(), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x8),
          _chip((p['verdict'] ?? '').toString(),
              (p['tone'] ?? 'neutral').toString()),
          SizedBox(height: Ds.space.x16),
          Text((p['outbound_label'] ?? '').toString(), style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          ...outbound.entries.map((e) => _kv(e.key, '${e.value}')),
          SizedBox(height: Ds.space.x12),
          Text((p['books_label'] ?? '').toString(), style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          ...books.entries.map((e) => _kv(e.key, '${e.value}')),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x4),
        child: Row(
          children: [
            Expanded(child: Text(k, style: Ds.t.body)),
            Text(v, style: Ds.t.bodyStrong),
          ],
        ),
      );

  Widget _fixturesCard(Map<String, dynamic> f) {
    final rows = (f['rows'] as List?) ?? const [];
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text((f['title'] ?? '').toString(), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          ...rows.map((raw) {
            final r = Map<String, dynamic>.from(raw as Map);
            return Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text((r['label'] ?? '').toString(), style: Ds.t.body),
                        SizedBox(height: Ds.space.x4),
                        Text((r['id_label'] ?? '').toString(),
                            style: Ds.t.caption),
                      ],
                    ),
                  ),
                  SizedBox(width: Ds.space.x8),
                  SyntheticBadge(badge: _badge(r)),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _countsCard(Map<String, dynamic> c) {
    final rows = (c['rows'] as List?) ?? const [];
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text((c['title'] ?? '').toString(), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          if (rows.isEmpty)
            Text((c['empty_label'] ?? '').toString(), style: Ds.t.caption)
          else
            ...rows.map((raw) {
              final r = Map<String, dynamic>.from(raw as Map);
              return _kv((r['label'] ?? '').toString(),
                  (r['count_label'] ?? '').toString());
            }),
        ],
      ),
    );
  }

  Widget _runsCard(Map<String, dynamic> r) {
    final rows = (r['rows'] as List?) ?? const [];
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text((r['title'] ?? '').toString(), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          if (rows.isEmpty)
            Text((r['empty_label'] ?? '').toString(), style: Ds.t.caption)
          else
            ...rows.map((raw) {
              final row = Map<String, dynamic>.from(raw as Map);
              return Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text((row['label'] ?? '').toString(),
                              style: Ds.t.body),
                          SizedBox(height: Ds.space.x4),
                          Text(
                            [
                              (row['started_label'] ?? '').toString(),
                              (row['order_code'] ?? '').toString(),
                            ].where((s) => s.isNotEmpty).join('  ·  '),
                            style: Ds.t.caption,
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: Ds.space.x8),
                    _chip((row['status_label'] ?? '').toString(),
                        (row['tone'] ?? 'neutral').toString()),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  /// One filled brand button (the run), everything destructive outlined in
  /// danger — the tone is the payload's, not this file's.
  Widget _actionButton(Map<String, dynamic> a) {
    final label = (a['label'] ?? '').toString();
    final toneName = (a['tone'] ?? 'brand').toString();
    final t = _tone(toneName);
    final onTap = _busy ? null : () => _fire(a);

    if (toneName == 'brand') {
      return SizedBox(
        width: double.infinity,
        height: Ds.touch.minTarget,
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Ds.c.brand,
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
          ),
          onPressed: onTap,
          child: Text(label, style: Ds.t.body.copyWith(color: Ds.c.surface)),
        ),
      );
    }
    return SizedBox(
      width: double.infinity,
      height: Ds.touch.minTarget,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: t.fg,
          side: BorderSide(color: _busy ? Ds.c.divider : t.fg),
          shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
        ),
        onPressed: onTap,
        child: Text(label, style: Ds.t.body.copyWith(color: t.fg)),
      ),
    );
  }
}
