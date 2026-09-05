import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'strip_v3_view.dart';

/// CHANGE #1367 — the fetching half of the runner strip.
///
/// Split from [StripV3View] so the renderer stays a pure function of its
/// payload and the protected suite can drive it with no Supabase, no network
/// and no timers. This half does three things and no more: read
/// `strip_v3_card()`, send a toggle back, and re-read.
///
/// It re-reads on a timer because the whole point of the card is the gap
/// between desired and actual, and that gap CLOSES asynchronously — the build
/// branch this change unblocked takes minutes to provision, during which the
/// honest answer is still "blocked". A card that only refreshed on a tap would
/// show a stale blocker long after the supervisor had fixed it, which is the
/// same class of lie as showing a green toggle for a dead capability.
class StripV3Card extends StatefulWidget {
  final SupabaseClient? client;

  /// How often to re-read while mounted. The backend does the work; this is
  /// one cheap RPC.
  final Duration refresh;

  const StripV3Card({
    super.key,
    this.client,
    this.refresh = const Duration(seconds: 60),
  });

  @override
  State<StripV3Card> createState() => _StripV3CardState();
}

class _StripV3CardState extends State<StripV3Card> {
  SupabaseClient get _c => widget.client ?? Supabase.instance.client;
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
      final r = _asMap(await _c.rpc('strip_v3_card'));
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
      await _c.rpc('dev_ctl_set',
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

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    return StripV3View(data: _d, busy: _busy, onToggle: _toggle);
  }
}
