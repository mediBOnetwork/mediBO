import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../services/ui_copy.dart';
import '../../../../utils/toast.dart';
import '../dev_queue_service.dart';
import 'strip_v3_view.dart';

/// CHANGE #1367 — the fetching half of the runner strip.
///
/// Split from [StripV3View] so the renderer stays a pure function of its
/// payload and the protected suite can drive it with no Supabase, no network
/// and no timers. This half does three things and no more: read
/// `strip_v3_card()`, send a toggle back, and re-read.
///
/// CMD #1862 — it reads through [DevQueueService], NOT `Supabase.instance`.
/// #1761 moved the whole dev-queue control plane onto its own project; this
/// card kept calling production, where `strip_v3_card` and `dev_ctl_set` do not
/// exist (PGRST202, every time). The RPC threw on every tick, `_d` stayed
/// empty, `StripV3View.shows` was false — and the three toggles Om used to
/// start the fleet with vanished from Dev Queue, silently, because a card that
/// swallows its own errors has no way to say it is talking to the wrong
/// database. One client, the same one every other Dev Queue RPC uses.
///
/// It re-reads on a timer because the whole point of the card is the gap
/// between desired and actual, and that gap CLOSES asynchronously — the build
/// branch this change unblocked takes minutes to provision, during which the
/// honest answer is still "blocked". A card that only refreshed on a tap would
/// show a stale blocker long after the supervisor had fixed it, which is the
/// same class of lie as showing a green toggle for a dead capability.
/// CMD #1862 — who draws the three switches.
///
/// The rule is one line long and it is the whole fix: the FOOTER draws them
/// whenever this card did not. Not "whenever the footer is embedded" — that is
/// what #1570 wrote, and it was true only for as long as the strip could read
/// its payload. Kept pure so the protected suite can hold it down with no
/// client, no network and no timers.
class StripToggleOwner {
  /// True when the strip itself has toggles on screen. An empty payload — the
  /// shape a failed or 404'd `strip_v3_card` leaves behind — is false, and so
  /// is a payload that arrived with an empty `toggles` list.
  static bool stripDraws(Map<String, dynamic> data) =>
      StripV3View.shows(data) &&
      ((data['toggles'] as List?) ?? const []).isNotEmpty;
}

class StripV3Card extends StatefulWidget {
  /// Pins the client (tests). Production routing goes through [service].
  final SupabaseClient? client;

  /// The control-plane router every other Dev Queue card already uses.
  final DevQueueService? service;

  /// CHANGE #1570 — what used to be the second runner card, rendered inside
  /// this one. See [StripV3View.footer].
  ///
  /// CMD #1862 — built with one argument: whether THIS card managed to draw
  /// the three toggles. When the strip has nothing to say, the footer draws
  /// them instead, so there is no build in which Dev Queue has no way to
  /// start the fleet.
  final Widget Function(bool stripHasToggles)? footer;

  /// How often to re-read while mounted. The backend does the work; this is
  /// one cheap RPC.
  final Duration refresh;

  const StripV3Card({
    super.key,
    this.client,
    this.service,
    this.footer,
    this.refresh = const Duration(seconds: 60),
  });

  @override
  State<StripV3Card> createState() => _StripV3CardState();
}

class _StripV3CardState extends State<StripV3Card> {
  late final DevQueueService _svc =
      widget.service ?? DevQueueService(client: widget.client);

  /// The control-plane client. A pinned [client] wins so the protected suite
  /// never reaches for `Supabase.instance`.
  Future<SupabaseClient> _client() async =>
      widget.client ?? await _svc.rpcClient();

  Map<String, dynamic> _d = const {};
  bool _busy = false;
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(widget.refresh, (_) => _load());
  }

  @override
  void dispose() {
    // A live Timer that outlives the screen keeps hitting the database from a
    // page nobody is looking at.
    _timer?.cancel();
    super.dispose();
  }

  Map<String, dynamic> _asMap(dynamic raw) {
    final v = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  }

  Future<void> _load() async {
    try {
      final r = _asMap(await (await _client()).rpc('strip_v3_card'));
      if (!mounted) return;
      setState(() {
        _d = r;
        _loading = false;
      });
    } catch (_) {
      // A panel, never the page — and the last good payload stays on screen
      // rather than flashing an empty card at every hiccup.
      if (mounted) setState(() => _loading = false);
    }
  }

  /// The backend owns the switch. This asks, then re-reads what actually
  /// happened — it never sets the toggle locally, because "what Om asked for"
  /// being painted as "what is true" is the bug this whole change is about.
  Future<void> _toggle(String key, bool on) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // dev_ctl_set takes the VALUE as text ('on'/'off'), matching what
      // desired_state stores — not a boolean.
      await (await _client()).rpc('dev_ctl_set',
          params: {'p_key': key, 'p_value': on ? 'on' : 'off'});
    } catch (_) {
      // Swallowed for the same reason; the re-read below tells the truth.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _load();
    // The supervisor reconciles on its own tick, so the gap may take a few
    // seconds to close. Re-read once more rather than leave a stale blocker.
    Future.delayed(const Duration(seconds: 8), () {
      if (mounted) _load();
    });
  }

  /// CHANGE #1570 — Stop / Restart on one worker.
  ///
  /// The strip cannot reach tmux, so the tap is a ROW: `runner_action_request`
  /// queues it and the supervisor executes it on its next tick. The toast is
  /// the backend's sentence, including its refusal when an action is already
  /// pending for that worker — nothing here decides whether the tap was
  /// allowed, and nothing here paints the worker as stopped before it is.
  Future<void> _workerAction(String agent, String action) async {
    if (_busy) return;
    final confirmed = await _confirm(agent, action);
    if (confirmed != true) return;
    setState(() => _busy = true);
    String? toast;
    try {
      final r = _asMap(await (await _client()).rpc('runner_action_request',
          params: {'p_agent': agent, 'p_action': action}));
      toast = (r['toast'] ?? '').toString();
    } catch (_) {
      // Same rule as the toggle: the re-read below is what tells the truth.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && toast != null && toast.isNotEmpty) {
      showToast(context, toast);
    }
    await _load();
    Future.delayed(const Duration(seconds: 8), () {
      if (mounted) _load();
    });
  }

  /// The confirmation sentence is the payload's too — a build that has never
  /// heard of an action still asks the right question about it.
  Future<bool?> _confirm(String agent, String action) async {
    String text = '';
    for (final w in (_d['workers'] as List?) ?? const []) {
      if (w is! Map || (w['agent'] ?? '').toString() != agent) continue;
      for (final a in (w['actions'] as List?) ?? const []) {
        if (a is Map && (a['key'] ?? '').toString() == action) {
          text = (a['confirm'] ?? '').toString();
        }
      }
    }
    if (text.isEmpty) return true;
    if (!mounted) return false;
    return showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        content: Text(text),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text(c('dev_queue.cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: Text(c('dev_queue.v3_action_go'))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // A card that hosts the runner controls must not disappear while its own
    // RPC is in flight — the footer is the whole control surface now.
    // While the first read is in flight the strip has drawn no toggles yet, so
    // the footer is asked to draw its own — the panel is never toggle-less.
    if (_loading) {
      return widget.footer == null
          ? const SizedBox.shrink()
          : StripV3View(data: const {}, footer: widget.footer!(false));
    }
    final stripHasToggles = StripToggleOwner.stripDraws(_d);
    return StripV3View(
      data: _d,
      busy: _busy,
      onToggle: _toggle,
      onWorkerAction: _workerAction,
      footer: widget.footer == null ? null : widget.footer!(stripHasToggles),
    );
  }
}
