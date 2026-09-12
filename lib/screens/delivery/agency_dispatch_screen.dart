// lib/screens/delivery/agency_dispatch_screen.dart — CHANGE #704
//
// The agency dispatcher's board. mediBO hands an ORDER to an AGENCY (the
// delivery lands as agency_id set / partner_id NULL / status 'agency_pending')
// and this screen is where the agency owner turns that into a rider.
//
// It computes NOTHING. The promised window, the distance, the bag count, the
// countdown sentence, every chip tone, every button label and the empty states
// all arrive from agency_dispatch_board() already worded and already decided —
// including whether a rider may be offered at all (can_take). The SLA countdown
// in particular is a BACKEND sentence re-fetched on a timer, never a clock run
// in Dart: the deadline belongs to the server that will enforce it, and a
// device with a wrong clock must not be able to disagree with it.
//
// Writing is one RPC, agency_dispatch_assign(), for both "pick a rider" and
// "change rider" — the backend decides which of the two happened and returns
// the sentence to print. The rider then follows the ordinary accept -> run ->
// track flow, unchanged.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';

/// How often the board is re-asked so the backend's countdown stays truthful.
const Duration kAgencyBoardRefresh = Duration(seconds: 30);

Future<void> openAgencyDispatchScreen(BuildContext context) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => const AgencyDispatchScreen()),
  );
}

class AgencyDispatchScreen extends StatefulWidget {
  const AgencyDispatchScreen({super.key});

  @override
  State<AgencyDispatchScreen> createState() => _AgencyDispatchScreenState();
}

class _AgencyDispatchScreenState extends State<AgencyDispatchScreen> {
  Map<String, dynamic> _board = const {};
  bool _loading = true;
  bool _failed = false;
  bool _busy = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _load();
    _tick = Timer.periodic(kAgencyBoardRefresh, (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.rpc('agency_dispatch_board');
      if (!mounted) return;
      final m = res is Map ? Map<String, dynamic>.from(res) : const <String, dynamic>{};
      setState(() {
        _board = m;
        _loading = false;
        _failed = false;
      });
      RenderLog.write(
          'c704_agency_dispatch',
          'allowed=${m['allowed'] == true};waiting=${AgencyBoard.rows(m, 'waiting').length};'
          'running=${AgencyBoard.rows(m, 'running').length};'
          'riders=${AgencyBoard.rows(m, 'riders').length}');
    } catch (e) {
      if (!mounted) return;
      // The payload never arrived, so there is no payload to print. The words
      // for THAT are already on the device (ui_copy, cached at boot) — the
      // screen still says nothing of its own.
      setState(() {
        _loading = false;
        _failed = true;
      });
      RenderLog.write('c704_agency_dispatch_err', e.toString());
    }
  }

  void _toast(String msg) {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _assign(Map<String, dynamic> stop, String partnerId) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await Supabase.instance.client.rpc('agency_dispatch_assign', params: {
        'p_delivery_id': _s(stop['delivery_id']),
        'p_partner_id': partnerId,
      });
      if (!mounted) return;
      final m = res is Map ? Map<String, dynamic>.from(res) : const <String, dynamic>{};
      RenderLog.write('c704_agency_dispatch_assign',
          'ok=${m['ok'] == true};reassign=${m['was_reassign'] == true}');
      await _load(silent: true);
      // Success and refusal are printed the same way: whatever the backend said.
      _toast(_s(m['message']));
    } catch (_) {
      // A thrown call is not a refusal — the backend never got to answer. Say
      // so with the backend's own sentence rather than leaving a tap that
      // looks like it did nothing.
      _toast(UiCopy.t('agency.assign_error'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s(_board['title']))),
      body: _loading
          ? const AgencyDispatchSkeleton()
          : RefreshIndicator(
              onRefresh: _load,
              child: _failed
                  ? AgencyDispatchFailure(onRetry: _load)
                  : AgencyDispatchBoardBody(
                      board: _board,
                      busy: _busy,
                      onAssign: _assign,
                    ),
            ),
    );
  }
}

/// The board itself: a payload in, a picked rider out. It holds no RPC and no
/// clock, so the protected test renders exactly what production renders.
class AgencyDispatchBoardBody extends StatelessWidget {
  final Map<String, dynamic> board;
  final bool busy;

  /// (stop, partner_id) — the ONE write this screen makes.
  final Future<void> Function(Map<String, dynamic> stop, String partnerId) onAssign;

  const AgencyDispatchBoardBody({
    super.key,
    required this.board,
    required this.onAssign,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    if (board['allowed'] != true) {
      return ListView(
        padding: EdgeInsets.all(Ds.space.x24),
        children: [
          Text(_s(board['message']), textAlign: TextAlign.center, style: Ds.t.caption),
        ],
      );
    }

    final waiting = AgencyBoard.rows(board, 'waiting');
    final running = AgencyBoard.rows(board, 'running');

    return ListView(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x32),
      children: [
        if (_s(board['note']).isNotEmpty) ...[
          Text(_s(board['note']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x24),
        ],
        Text(_s(board['waiting_heading']), style: Ds.t.title),
        SizedBox(height: Ds.space.x12),
        if (waiting.isEmpty)
          Text(_s(board['empty']), style: Ds.t.caption)
        else
          for (final s in waiting) _stopCard(context, s),
        SizedBox(height: Ds.space.x32),
        Text(_s(board['running_heading']), style: Ds.t.title),
        SizedBox(height: Ds.space.x12),
        if (running.isEmpty)
          Text(_s(board['empty_running']), style: Ds.t.caption)
        else
          for (final s in running) _stopCard(context, s),
      ],
    );
  }

  Future<void> _pickRider(BuildContext context, Map<String, dynamic> stop) async {
    // can_take is the BACKEND's single answer to "has this rider room" — spare
    // capacity, documents and shift, decided once in SQL. This list never
    // re-derives it.
    final offered =
        AgencyBoard.rows(board, 'riders').where((r) => r['can_take'] == true).toList();

    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
      ),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.fromLTRB(
              Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x24),
          children: [
            Text(_s(board['sheet_title']), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x4),
            Text(_s(stop['pharmacy_name']), style: Ds.t.caption),
            SizedBox(height: Ds.space.x16),
            if (offered.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: Ds.space.x24),
                child: Text(_s(board['no_riders']), style: Ds.t.caption),
              )
            else
              for (final r in offered)
                Container(
                  margin: EdgeInsets.only(bottom: Ds.space.x8),
                  constraints: BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
                  decoration: BoxDecoration(
                    border: Border.all(color: Ds.c.divider),
                    borderRadius: BorderRadius.circular(Ds.r.card),
                  ),
                  child: ListTile(
                    onTap: () => Navigator.of(ctx).pop(_s(r['partner_id'])),
                    title: Text(_s(r['name']), style: Ds.t.body),
                    subtitle: Text(
                      [_s(r['status_label']), _s(r['vehicle'])]
                          .where((x) => x.isNotEmpty)
                          .join(' \u00b7 '),
                      style: Ds.t.caption,
                    ),
                    trailing: Text(_s(r['spare_label']), style: Ds.t.caption),
                  ),
                ),
          ],
        ),
      ),
    );
    if (picked == null || picked.isEmpty) return;
    await onAssign(stop, picked);
  }

  Widget _stopCard(BuildContext context, Map<String, dynamic> s) {
    final action = s['action'] is Map
        ? Map<String, dynamic>.from(s['action'] as Map)
        : const <String, dynamic>{};
    // Absence is a FLAG. A missing distance or bag count leaves the fact out
    // rather than printing a dash, an empty separator or a zero.
    final meta = [
      _s(s['window_label']),
      if (s['has_distance'] == true) _s(s['distance_label']),
      if (s['has_bags'] == true) _s(s['bags_label']),
    ].where((x) => x.isNotEmpty).join(' \u00b7 ');

    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x12),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: BorderRadius.circular(Ds.r.card),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(_s(s['pharmacy_name']), style: Ds.t.subtitle)),
          // The countdown is the backend's SENTENCE, re-fetched on a timer.
          _chip(_s(s['sla_label']), _s(s['sla_tone'])),
        ]),
        SizedBox(height: Ds.space.x4),
        Text(_s(s['order_code']), style: Ds.t.caption),
        if (_s(s['address']).isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(_s(s['address']), style: Ds.t.caption),
        ],
        if (meta.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(meta, style: Ds.t.caption),
        ],
        SizedBox(height: Ds.space.x12),
        Row(children: [
          _chip(_s(s['status_label']), _s(s['status_tone'])),
          SizedBox(width: Ds.space.x8),
          Expanded(
            child: Text(_s(s['chain_label']),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: Ds.t.caption),
          ),
        ]),
        if (action['has'] == true) ...[
          SizedBox(height: Ds.space.x12),
          SizedBox(
            width: double.infinity,
            // FilledButton, not ElevatedButton: the brand fill and the 48px
            // minimum live in buildTheme()'s filledButtonTheme, and only
            // FilledButton reads them. An ElevatedButton here paints Material's
            // own pale default — an off-brand primary action, decided by the
            // framework instead of by the design tokens.
            child: FilledButton(
              onPressed: busy ? null : () => _pickRider(context, s),
              child: Text(_s(action['label'])),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _chip(String label, String tone) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration: BoxDecoration(
        color: AgencyBoard.toneSoft(tone),
        borderRadius: BorderRadius.circular(Ds.r.chip),
      ),
      child: Text(label,
          style: Ds.t.caption.copyWith(color: AgencyBoard.toneColor(tone))),
    );
  }
}

/// What the board looks like while it is being asked for — the same card
/// rhythm the real list uses, so the page does not jump when the payload
/// lands. A skeleton, deliberately, not a spinner: a spinner says "wait", a
/// skeleton says what is coming.
class AgencyDispatchSkeleton extends StatelessWidget {
  const AgencyDispatchSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x32),
      children: [
        for (var i = 0; i < 3; i++)
          Container(
            margin: EdgeInsets.only(bottom: Ds.space.x12),
            padding: EdgeInsets.all(Ds.space.x16),
            decoration: BoxDecoration(
              color: Ds.c.surface,
              borderRadius: BorderRadius.circular(Ds.r.card),
              boxShadow: Ds.elevation.e1,
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _bar(widthFactor: 0.55, height: Ds.space.x16),
              SizedBox(height: Ds.space.x8),
              _bar(widthFactor: 0.35, height: Ds.space.x12),
              SizedBox(height: Ds.space.x12),
              _bar(widthFactor: 0.8, height: Ds.space.x12),
              SizedBox(height: Ds.space.x16),
              _bar(widthFactor: 1, height: Ds.touch.minTarget),
            ]),
          ),
      ],
    );
  }

  Widget _bar({required double widthFactor, required double height}) =>
      FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: widthFactor,
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: Ds.c.bg,
            borderRadius: BorderRadius.circular(Ds.r.chip),
          ),
        ),
      );
}

/// The board could not be asked at all. The one state with no payload behind
/// it, so both sentences come from ui_copy — cached at boot, which is exactly
/// why they are still readable when the network is not.
class AgencyDispatchFailure extends StatelessWidget {
  final Future<void> Function() onRetry;

  const AgencyDispatchFailure({super.key, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(Ds.space.x24),
      children: [
        SizedBox(height: Ds.space.x32),
        Text(UiCopy.t('agency.load_error'),
            textAlign: TextAlign.center, style: Ds.t.body),
        SizedBox(height: Ds.space.x24),
        SizedBox(
          height: Ds.touch.minTarget,
          child: OutlinedButton(
            onPressed: () => onRetry(),
            child: Text(UiCopy.t('agency.retry')),
          ),
        ),
      ],
    );
  }
}

String _s(dynamic v) => v?.toString() ?? '';

/// The board's two pure decisions, lifted out so they can be tested without a
/// widget tree — and so the screen keeps none of its own.
class AgencyBoard {
  const AgencyBoard._();

  /// A list the payload sent, in PAYLOAD ORDER. A key this build has never
  /// heard of, or a payload that is not a list, is an empty section rather
  /// than a crash.
  static List<Map<String, dynamic>> rows(Map<String, dynamic> board, String key) {
    final v = board[key];
    if (v is! List) return const [];
    return v
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
  }

  /// Tones are the BACKEND's words; this maps them onto the token layer and
  /// nothing else. An unknown tone reads as neutral text, never as an error.
  static Color toneColor(String tone) {
    switch (tone) {
      case 'good':
        return Ds.c.success;
      case 'warn':
        return Ds.c.warning;
      case 'bad':
        return Ds.c.danger;
      case 'info':
        return Ds.c.info;
      default:
        return Ds.c.textSecondary;
    }
  }

  static Color toneSoft(String tone) {
    switch (tone) {
      case 'good':
        return Ds.c.successSoft;
      case 'warn':
        return Ds.c.warningSoft;
      case 'bad':
        return Ds.c.dangerSoft;
      case 'info':
        return Ds.c.infoSoft;
      default:
        return Ds.c.bg;
    }
  }
}
