import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../design_tokens.dart';
import '../../../../services/ui_copy.dart';
import '../../../../utils/toast.dart';
import 'runner_ops_view.dart';

/// CHANGE #1368 — the fetching half of the Runner policies card.
///
/// Split from [RunnerOpsView] for the same reason #1367 split its strip: the
/// renderer stays a pure function of one payload, and the protected suite can
/// drive it with no Supabase, no network and no timers.
///
/// This half does four things and no more: read `runner_ops_card()`, send a
/// toggle, send a one-shot, and re-read. It never decides which RPC a policy
/// means in the sense of inventing one — the mapping below is the contract the
/// migration published, and every refusal it shows is the backend's own words.
class RunnerOpsCard extends StatefulWidget {
  final SupabaseClient? client;

  /// The policies whose state changes cost real money or real availability sit
  /// behind the safety PIN in `runner_ops_set`; drain and the one-shots do not.
  final Duration refresh;

  const RunnerOpsCard({
    super.key,
    this.client,
    this.refresh = const Duration(seconds: 60),
  });

  @override
  State<RunnerOpsCard> createState() => _RunnerOpsCardState();
}

class _RunnerOpsCardState extends State<RunnerOpsCard> {
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
      final r = _asMap(await _c.rpc('runner_ops_card'));
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

  Future<String?> _askPin() async {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(c('dev_queue.gcp_pin_confirm')),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          obscureText: true,
          decoration: InputDecoration(hintText: c('dev_queue.gcp_pin_hint')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(c('dev_queue.btn_cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctl.text.trim()),
              style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
              child: Text(c('dev_queue.gcp_unlock'))),
        ],
      ),
    );
  }

  /// Draining is the one policy Om reaches for in a hurry — the VM is about to
  /// go, or a bad batch is running — so it is deliberately NOT behind the PIN.
  /// It cannot lose data and it undoes itself with the same tap. Everything
  /// else changes how much the fleet spends or what it is allowed to touch
  /// unattended, and those go through the PIN-gated editor.
  Future<void> _toggle(String key, bool on) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (key == 'drain') {
        await _c.rpc('runner_ops_drain_set',
            params: {'p_on': on, 'p_reason': ''});
      } else {
        final pin = await _askPin();
        if (pin == null || pin.isEmpty) return;
        await _c.rpc('runner_ops_set', params: {
          'p_patch': {
            key: {'enabled': on}
          },
          'p_pin': pin,
        });
      }
    } on PostgrestException catch (e) {
      // The backend's refusal, verbatim — "Policy changes need the safety PIN."
      // is a sentence it already owns.
      if (mounted) showToast(context, e.message, isError: true);
    } catch (_) {
      // Swallowed for the same reason the strip swallows: the re-read below
      // tells the truth about what actually happened.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _load();
  }

  Future<void> _action(String action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (action == 'boost') {
        await _c.rpc('runner_ops_boost', params: {'p_minutes': 30, 'p_workers': 2});
      } else if (action == 'drill_now') {
        final r = _asMap(await _c.rpc('runner_ops_cycle_start',
            params: {'p_reason': 'drill'}));
        // A drill refuses while anything is building, and says why. That
        // refusal is the useful half of the button.
        if ((r['ok'] ?? false) != true && mounted) {
          showToast(context, (r['reason'] ?? '').toString(), isError: true);
        }
      }
    } on PostgrestException catch (e) {
      if (mounted) showToast(context, e.message, isError: true);
    } catch (_) {
      // As above.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _load();
    // The supervisor picks a boost up on its own tick and a power cycle moves
    // one phase per minute, so the state on screen lags the tap by design.
    // Re-read once more rather than leave a stale row.
    Future.delayed(const Duration(seconds: 8), () {
      if (mounted) _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    return RunnerOpsView(
        data: _d, busy: _busy, onToggle: _toggle, onAction: _action);
  }
}
